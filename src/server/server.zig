const std = @import("std");

const Mux = @import("IoMux");
const Socket = @import("Socket").Socket;

const Options = @import("options.zig").Options;
const Session = @import("session.zig").Session;
const Protocol = @import("../protocol/mod.zig");
const Messages = Protocol.Messages;

const Handler = @import("handler.zig");

pub fn generateGUID() u64 {
    return std.crypto.random.int(u64);
}

/// `Server` represents a RakNet-style UDP server.
/// It manages multiple sessions, handles incoming packets, and allows
/// user-defined callbacks for connection and disconnection events.
pub const Server = struct {
    /// Server configuration options such as port, protocol version, advertisement.
    options: Options,

    /// Allocator used for creating sessions, maps, and temporary buffers.
    allocator: std.mem.Allocator,

    /// Map of active sessions keyed by hashed client addresses.
    sessions: std.AutoHashMap(u64, Session),

    /// Globally unique identifier for this server, generated on startup.
    guid: u64,

    /// Whether the server is currently running/listening.
    running: bool,

    /// UDP socket used for sending/receiving packets.
    socket: Socket,

    /// Reusable packet buffer for serializing messages.
    packetBuf: Protocol.PacketBuffer,

    /// I/O multiplexer used for asynchronous socket operations.
    ioMux: Mux.IoMux,

    /// True if the server owns the IoMux instance and should deinit it.
    ownsMux: bool,

    // Handler for server events
    handler: Handler.Handler,

    /// Initialize a new server with its own `IoMux` and socket.
    ///
    /// The server GUID is automatically generated.
    pub fn init(options: Options, handler: Handler.Handler, allocator: std.mem.Allocator) !Server {
        var server = Server{
            .options = options,
            .allocator = allocator,
            .sessions = std.AutoHashMap(u64, Session).init(allocator),
            .guid = generateGUID(),
            .running = false,
            .socket = try Socket.init(options.address, options.port),
            .packetBuf = Protocol.PacketBuffer.init(),
            .ioMux = try Mux.IoMux.init(allocator),
            .ownsMux = true,
            .handler = handler,
        };

        if (options.maxSessions > 0) {
            try server.sessions.ensureTotalCapacity(@intCast(options.maxSessions));
        }

        return server;
    }

    /// Initialize a new server using an existing IoMux.
    ///
    /// Useful if you want to share an IoMux across multiple servers.
    pub fn initWithMux(options: Options, handler: Handler.Handler, allocator: std.mem.Allocator, ioMux: Mux.IoMux) Server {
        var server = Server{
            .options = options,
            .allocator = allocator,
            .sessions = std.AutoHashMap(u64, Session).init(allocator),
            .guid = generateGUID(),
            .running = false,
            .packetBuf = Protocol.PacketBuffer.init(),
            .ioMux = ioMux,
            .ownsMux = false,
            .handler = handler,
        };

        if (options.maxSessions > 0) {
            try server.sessions.ensureTotalCapacity(@intCast(options.maxSessions));
        }

        return server;
    }

    /// Clean up the server and all active sessions.
    ///
    /// Frees packet buffer, deinitializes the socket, and deinitializes
    /// IoMux if the server owns it.
    pub fn deinit(self: *Server) void {
        var iter = self.sessions.valueIterator();
        while (iter.next()) |sess| {
            sess.deinit();
        }
        self.sessions.deinit();

        self.socket.deinit();
        self.packetBuf.reset(true);
        if (self.ownsMux) {
            self.ioMux.deinit();
        }
    }

    /// Tick the server.
    ///
    /// Processes active sessions, removes inactive sessions, and calls
    /// `Session.tick()` for each active session.
    fn tick(self: *Server) void {
        // Skip if no sessions
        if (self.sessions.count() == 0) {
            return;
        }

        var sessions = self.allocator.alloc(*Session, self.sessions.count()) catch |err| {
            std.debug.print("Error ticking server: {any}\n", .{err});
            return;
        };
        defer self.allocator.free(sessions);

        var count: usize = 0;
        var toRemove = self.allocator.alloc(u64, self.sessions.count()) catch |err| {
            std.debug.print("Error ticking server: {any}\n", .{err});
            return;
        };
        defer self.allocator.free(toRemove);
        var removeCount: usize = 0;

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.active) {
                if (count < sessions.len) {
                    sessions[count] = entry.value_ptr;
                    count += 1;
                }
            } else {
                toRemove[removeCount] = entry.key_ptr.*;
                removeCount += 1;
            }
        }

        for (sessions[0..count]) |session| {
            session.tick();
        }

        for (toRemove[0..removeCount]) |key| {
            if (self.sessions.getPtr(key)) |conn| {
                conn.deinit();
                _ = self.sessions.remove(key);
            }
        }
    }

    /// Handle an incoming packet from a client.
    ///
    /// - `payload`: The raw packet bytes received.
    /// - `address`: The client address the packet came from.
    ///
    /// Routes the packet to the appropriate session if it exists,
    /// otherwise handles unconnected messages such as pings or connection requests.
    fn handlePacket(self: *Server, payload: []u8, address: std.net.Address) void {
        const key = hashAddress(address);

        var _id = payload[0];
        if (_id & 0xF0 == 0x80) _id = 0x80;

        const packetID = Protocol.PacketID.fromU8(_id) orelse {
            std.debug.print("Unknown packetId: {d}", .{_id});
            return;
        };

        const sess = self.sessions.getPtr(key);

        if (sess) |session| {
            switch (packetID) {
                .FrameSet => session.handleFrameSet(payload) catch |err| {
                    std.debug.print("FrameSet error: {any}\n", .{err});
                },
                .ACK => session.handleAck(payload) catch |err| {
                    std.debug.print("ACK error: {any}\n", .{err});
                },
                .NACK => session.handleNack(payload) catch |err| {
                    std.debug.print("ACK error: {any}\n", .{err});
                },
                else => {},
            }
        } else {
            switch (packetID) {
                .UnconnectedPing => {
                    self.packetBuf.reset(false);
                    var writer = self.packetBuf.writer;

                    var pong = Messages.UnconnectedPong.init(std.time.milliTimestamp(), self.guid, self.options.advertisement);
                    const pongData = pong.serialize(&writer) catch |err| {
                        std.debug.print("Serialize error: {any}\n", .{err});
                        return;
                    };

                    self.send(pongData, address);
                },
                .OpenConnectionRequest1 => {
                    const request = Messages.ConnectionRequest1.deserialize(payload) catch {
                        return;
                    };

                    if (request.protocol != self.options.protocolVersion) {
                        self.packetBuf.reset(false);
                        var writer = self.packetBuf.writer;

                        var incompatible = Messages.IncompatibleProtocolVersion.init(self.options.protocolVersion, self.guid);
                        const incompatibleData = incompatible.serialize(&writer) catch {
                            return;
                        };

                        self.send(incompatibleData, address);
                        return;
                    }

                    self.packetBuf.reset(false);
                    var writer = self.packetBuf.writer;

                    var reply = Messages.ConnectionReply1.init(self.guid, false, 0, Protocol.Constants.MAX_MTU_SIZE);
                    const replyData = reply.serialize(&writer) catch |err| {
                        std.debug.print("Serialize error: {any}\n", .{err});
                        return;
                    };
                    self.send(replyData, address);
                },
                .OpenConnectionRequest2 => {
                    const request = Messages.ConnectionRequest2.deserialize(payload) catch |err| {
                        std.debug.print("Deserialize error: {any}\n", .{err});
                        return;
                    };

                    const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);

                    self.packetBuf.reset(false);
                    var writer = self.packetBuf.writer;

                    var reply = Messages.ConnectionReply2.init(self.guid, addr, request.mtuSize, false);
                    const replyData = reply.serialize(&writer) catch |err| {
                        std.debug.print("Serialize error: {any}\n", .{err});
                        return;
                    };
                    self.send(replyData, address);

                    if (!self.sessions.contains(key)) {
                        if (self.options.maxSessions > 0 and self.sessions.count() == @as(u32, @intCast(self.options.maxSessions))) {
                            self.send(&[1]u8{@intFromEnum(Protocol.PacketID.ConnectionAttemptFailed)}, address);

                            return;
                        }

                        const session = Session.init(self, address, request.mtuSize, request.clientGUID) catch |err| {
                            std.debug.print("Session init error: {any}\n", .{err});
                            return;
                        };
                        self.sessions.put(key, session) catch |err| {
                            std.debug.print("Session put error: {any}\n", .{err});
                            return;
                        };
                    }
                },
                else => {},
            }
        }
    }

    /// Start listening for packets and process events in a blocking loop.
    ///
    /// - `maxEvents`: Optional maximum number of events to process per poll loop.
    pub fn listen(self: *Server, comptime maxEvents: ?usize) !void {
        if (self.running) {
            return error.ServerAlreadyListening;
        }

        const eventCount = maxEvents orelse 512;

        try self.ioMux.add(self.socket.handle);
        self.running = true;

        var buf: [1500]u8 = undefined;

        var nextTick = std.time.milliTimestamp() + self.options.tickRate;

        while (true) {
            const now = std.time.milliTimestamp();

            var waitMs: i64 = 0;
            if (nextTick > now) {
                waitMs = nextTick - now;
            } else {
                waitMs = 0;
            }

            var events: [eventCount]Mux.IoEvent = undefined;
            const n = try self.ioMux.wait(events[0..], @intCast(waitMs));

            for (events[0..n]) |event| {
                if (event.fd == self.socket.handle and event.readable) {
                    while (true) {
                        const result = self.socket.receiveFrom(buf[0..]) catch |err| {
                            std.debug.print("Error handling packet: {any}\n", .{err});
                            break;
                        } orelse break;
                        self.handlePacket(buf[0..result.len], result.addr);
                    }
                }
            }

            const end = std.time.milliTimestamp();
            if (end >= nextTick) {
                self.tick();
                nextTick += self.options.tickRate;

                if (nextTick < end) {
                    nextTick = end + self.options.tickRate;
                }
            }
        }
    }

    /// Send a packet to a specific client address.
    ///
    /// - `payload`: Serialized packet data to send.
    /// - `addr`: Client address to send the packet to.
    pub fn send(self: *Server, payload: []const u8, addr: std.net.Address) void {
        self.socket.sendTo(payload, addr) catch |err| {
            std.debug.print("Failed to send: {any}", .{err});
            return;
        };
    }

    /// Hash a client address to a unique 64-bit key for storing sessions.
    ///
    /// Supports both IPv4 and IPv6 addresses.
    pub fn hashAddress(address: std.net.Address) u64 {
        return switch (address.any.family) {
            std.posix.AF.INET => {
                const ip = @as(u32, address.in.sa.addr);
                const port = @as(u32, address.in.sa.port);
                return (@as(u64, port) << 32) | @as(u64, ip);
            },
            std.posix.AF.INET6 => {
                var hash: u64 = 0xcbf29ce484222325;
                for (address.in6.sa.addr) |b| {
                    hash ^= @as(u64, b);
                    hash *= 0x100000001b3;
                }
                hash ^= @as(u64, address.in6.sa.port);
                hash *= 0x100000001b3;
                return hash;
            },
            else => 0,
        };
    }
};
