const std = @import("std");

const Server = @import("server.zig").Server;

const Protocol = @import("../protocol/mod.zig");
const Frame = Protocol.Frame;
const PacketID = Protocol.PacketID;
const Messages = Protocol.Messages;
const Priority = Protocol.Priority;
const Constants = Protocol.Constants;

// Little util
fn arrayContains(list: []const u24, value: u24) bool {
    for (list) |item| {
        if (item == value) return true;
    }
    return false;
}

fn arrayRemove(list: *std.ArrayList(u24), value: u24) void {
    var i: usize = 0;
    while (i < list.items.len) : (i += 1) {
        if (list.items[i] == value) {
            // Shift everything after i down by 1
            var j: usize = i;
            while (j + 1 < list.items.len) : (j += 1) {
                list.items[j] = list.items[j + 1];
            }
            // shrink length
            list.items = list.items[0 .. list.items.len - 1];
            return;
        }
    }
}

/// Represents a client connection session.
/// This struct is mostly managed internally by the server.
/// It handles packet processing, sequencing, fragmentation, and timeouts.
pub const Session = struct {
    /// Reference to the server that owns this session.
    server: *Server,
    /// Remote client address.
    address: std.net.Address,
    /// Hashed version of the address for lookup in server's session map.
    key: u64,
    /// Maximum Transmission Unit for this session (largest packet size allowed).
    mtuSize: u16,
    /// Client unique identifier.
    guid: u64,
    /// True if session has completed the connection handshake.
    connected: bool,
    /// True if session is currently active; becomes false on timeout or disconnect.
    active: bool,
    /// Internal state: output queues, received sequences, ordering queues, and fragment queues.
    state: SessionState,
    /// Allocator used for session-local memory (frames, packet copies).
    allocator: std.mem.Allocator,
    /// Timestamp (ms) of last received packet from client.
    lastReceive: i64,
    /// Timestamp of the last ping sent to client.
    lastPing: i64 = 0,
    /// Interval in milliseconds between automatic pings.
    pingInterval: u64 = 5000,

    ackBuffer: []u24,
    nackBuffer: []u24,

    /// Initializes a new session.
    /// Allocates internal state and sets up an arena.
    pub fn init(server: *Server, address: std.net.Address, mtuSize: u16, guid: u64) !Session {
        return .{
            .server = server,
            .address = address,
            .key = Server.hashAddress(address),
            .mtuSize = mtuSize,
            .guid = guid,
            .connected = false,
            .active = true,
            .lastReceive = std.time.milliTimestamp(),
            .allocator = server.allocator,
            .state = try SessionState.init(server.allocator),
            .ackBuffer = try server.allocator.alloc(u24, Constants.MAX_SEQUENCES),
            .nackBuffer = try server.allocator.alloc(u24, Constants.MAX_SEQUENCES),
        };
    }

    /// Deinitializes a session, freeing all allocated memory in the arena.
    pub fn deinit(self: *Session) void {
        _ = self.state.deinit(self.allocator);
        self.allocator.free(self.ackBuffer);
        self.allocator.free(self.nackBuffer);
    }

    /// Performs a tick/update for the session.
    /// - Checks for timeouts and disconnects
    /// - Sends ACKs and NACKs for sequences
    /// - Sends queued frames
    /// - Sends pings to keep connection alive
    pub fn tick(self: *Session) void {
        if (!self.active) return;

        if (self.lastReceive + self.server.options.timeout < std.time.milliTimestamp()) {
            self.active = false;

            self.server.handler.onDisconnect(self);
            return;
        }

        while (self.state.outputFrameQueue.items.len > 0) {
            const queueLen = self.state.outputFrameQueue.items.len;
            const beforeLen = queueLen;

            self.sendQueuedFrames(queueLen);
            if (self.state.outputFrameQueue.items.len >= beforeLen) break;
        }

        if (self.state.receivedSequences.items.len > 0) {
            var count: usize = 0;
            for (self.state.receivedSequences.items) |key| {
                if (count < self.ackBuffer.len) self.ackBuffer[count] = key;
                count += 1;
            }

            self.state.receivedSequences.clearRetainingCapacity();

            var ack = Messages.Ack{ .sequences = self.ackBuffer[0..count] };

            self.server.packetBuf.reset(false);
            var writer = self.server.packetBuf.writer;

            const serialized = ack.serialize(&writer) catch {
                return;
            };
            self.send(serialized);
        }

        if (self.state.lostSequences.items.len > 0) {
            var count: usize = 0;
            for (self.state.lostSequences.items) |key| {
                if (count < self.nackBuffer.len) self.nackBuffer[count] = key;
                count += 1;
            }

            self.state.lostSequences.clearRetainingCapacity();

            var nack = Messages.Ack{ .sequences = self.nackBuffer[0..count] };

            self.server.packetBuf.reset(false);
            var writer = self.server.packetBuf.writer;

            // Should work if not change to .dupe
            writer.buf[0] = @intFromEnum(PacketID.NACK);

            const serialized = nack.serialize(&writer) catch {
                return;
            };
            self.send(serialized);
        }

        if (self.connected) {
            const currentTime = std.time.milliTimestamp();

            if (currentTime - @as(i64, @intCast(self.lastPing)) >= self.pingInterval) {
                self.sendPing();
                self.lastPing = @intCast(currentTime);
            }
        }
    }

    /// Handles a raw incoming packet for this session.
    /// Dispatches packets to appropriate handlers based on packet type.
    pub fn handlePacket(self: *Session, payload: []const u8) !void {
        if (!self.active) return;

        if (payload.len == 0) {
            return;
        }

        const packetId: PacketID = PacketID.fromU8(payload[0]) orelse return;
        self.lastReceive = std.time.milliTimestamp();

        switch (packetId) {
            .ConnectedPing => {
                const ping = try Messages.ConnectedPing.deserialize(payload);

                self.server.packetBuf.reset(false);
                var writer = self.server.packetBuf.writer;

                var pong = Messages.ConnectedPong.init(ping.timestamp, std.time.milliTimestamp());
                const serialized = try pong.serialize(&writer);

                const frame = self.frameFromPayloadWithReliability(serialized, .Unreliable) catch |err| {
                    std.debug.print("Failed to alloc frame payload: {any}\n", .{err});
                    return;
                };
                self.sendFrame(frame, .Normal);
            },
            .ConnectedPong => {},
            .ConnectionRequest => {
                self.server.packetBuf.reset(false);
                var writer = self.server.packetBuf.writer;

                const request = try Messages.ConnectionRequest.deserialize(payload);
                const empty = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, self.server.options.port);

                var reply = Messages.ConnectionRequestAccepted.init(self.address, 0, empty, request.timestamp, std.time.milliTimestamp());
                const serialized = try reply.serialize(&writer);

                const frame = self.frameFromPayloadWithReliability(serialized, .Unreliable) catch |err| {
                    std.debug.print("Failed to alloc frame payload: {any}\n", .{err});
                    return;
                };
                self.sendFrame(frame, .Immediate);
            },
            .NewIncomingConnection => {
                self.connected = true;
                self.server.handler.onConnect(self);
            },
            .GamePacket => {
                self.server.handler.onGamePacket(self, payload);
            },
            .DisconnectNotification => {
                self.active = false;
                self.connected = false;

                self.server.handler.onDisconnect(self);
            },
            else => {
                std.debug.print("Unhandled packet: {any}\n", .{packetId});
            },
        }
    }

    /// Handles an ACK packet from the client.
    /// Cleans up any stored frames that have been acknowledged.
    pub fn handleAck(self: *Session, payload: []const u8) !void {
        if (!self.active) return;

        var ack = try Messages.Ack.deserializeAlloc(payload, self.allocator);
        defer ack.deinitAlloc(self.allocator);

        var i: usize = 0;
        while (i < ack.sequences.len) : (i += 1) {
            const sequence = ack.sequences[i];
            const key = @as(u24, @intCast(sequence));
            if (self.state.outputBackup.contains(key)) {
                if (self.state.outputBackup.get(key)) |*framesPtr| {
                    const frames = framesPtr.*;
                    var idx: usize = 0;
                    while (idx < frames.len) : (idx += 1) {
                        const fptr = &frames[idx];
                        if (fptr.shouldFree) fptr.deinit(self.allocator);
                    }
                    _ = self.state.outputBackup.remove(key);
                    self.allocator.free(frames);
                }
            }
        }
    }

    /// Handles a NACK packet from the client.
    /// Resends frames that the client reported as lost.
    pub fn handleNack(self: *Session, payload: []const u8) !void {
        if (!self.active) return;

        var nack = try Messages.Ack.deserializeAlloc(payload, self.allocator);
        defer nack.deinitAlloc(self.allocator);

        for (nack.sequences) |seq| {
            const frames = self.state.outputBackup.get(seq);
            if (frames) |f| {
                self.server.packetBuf.reset(false);
                var writer = self.server.packetBuf.writer;

                var frameset = Messages.FrameSet.init(seq, f);
                const serialized = frameset.serialize(&writer) catch continue;
                self.send(serialized);
                frameset.deinit(self.allocator);
            }
            _ = self.state.outputBackup.remove(seq);
        }
    }

    /// Handles a FrameSet packet, including reassembling split frames.
    pub fn handleFrameSet(self: *Session, payload: []const u8) !void {
        if (!self.active) return;

        self.lastReceive = std.time.milliTimestamp();

        var set = try Messages.FrameSet.deserialize(payload, self.allocator);
        defer set.deinit(self.allocator);

        const sequence = set.sequenceNumber;

        {
            const lastSeq = self.state.lastInputSequence;
            const receivedSeqs = self.state.receivedSequences;

            const isOldSequence = lastSeq != -1 and sequence <= @as(u24, @intCast(@max(0, lastSeq)));
            const alreadyReceived = arrayContains(receivedSeqs.items, sequence);

            const isDuplicate = isOldSequence or alreadyReceived;
            if (isDuplicate) {
                return;
            }
        }

        try self.state.receivedSequences.append(self.allocator, sequence);
        arrayRemove(&self.state.lostSequences, sequence);

        const lastSeq = self.state.lastInputSequence;
        if (sequence > lastSeq + 1) {
            var i: i32 = lastSeq + 1;
            while (i < sequence) : (i += 1) {
                try self.state.lostSequences.append(self.allocator, @intCast(i));
            }
        }

        self.state.lastInputSequence = @intCast(sequence);
        for (set.frames) |frame| {
            try self.handleFrame(frame);
        }

        try self.state.receivedSequences.append(self.allocator, sequence);
    }

    /// Handles a single frame.
    /// Will dispatch to split, ordered, or sequenced frame handlers as appropriate.
    pub fn handleFrame(self: *Session, frame: Frame) anyerror!void {
        if (!self.active) return;

        if (frame.payload.len == 0) {
            return;
        }

        const reliability = frame.reliability;

        if (frame.isSplit()) {
            try self.handleSplitFrame(frame);
        } else if (reliability.isSequenced()) {
            self.handleSequencedFrame(frame);
        } else if (reliability.isOrdered()) {
            self.handleOrderedFrame(frame);
        } else {
            try self.handlePacket(frame.payload);
        }
    }

    /// Handles a sequenced frame (non-split, non-ordered).
    pub fn handleSequencedFrame(self: *Session, frame: Frame) void {
        if (!self.active) return;

        const channel = frame.orderChannel orelse return;
        const frameIndex = frame.sequenceFrameIndex orelse return;
        const orderIndex = frame.orderedFrameIndex orelse return;

        const highest = self.state.inputHighestSequenceIndex[channel];
        if (frameIndex >= highest and orderIndex >= self.state.inputOrderIndex[channel]) {
            self.state.inputHighestSequenceIndex[channel] = frameIndex + 1;

            self.handlePacket(frame.payload) catch |err| {
                std.debug.print("Failed to handle packet: {any}\n", .{err});
                return;
            };
        }
    }

    /// Handles an ordered frame (non-split, ordered by channel).
    pub fn handleOrderedFrame(self: *Session, frame: Frame) void {
        if (!self.active) return;

        const channel = frame.orderChannel orelse return;
        const frameIndex = frame.orderedFrameIndex orelse return;

        if (frameIndex == self.state.inputOrderIndex[channel]) {
            self.state.inputHighestSequenceIndex[channel] = 0;
            self.state.inputOrderIndex[channel] = frameIndex + 1;

            self.handlePacket(frame.payload) catch {
                return;
            };

            var index = self.state.inputOrderIndex[channel];

            const outOfOrderQueuePtr = self.state.inputOrderingQueue.getPtr(channel);
            if (outOfOrderQueuePtr) |outOfOrderQueue| {
                while (true) {
                    const queuedFrame = outOfOrderQueue.get(index);
                    if (queuedFrame == null) break;

                    self.handlePacket(queuedFrame.?.payload) catch |err| {
                        std.debug.print("Error handling packet: {any}\n", .{err});
                        break;
                    };

                    _ = outOfOrderQueue.remove(index);
                    index += 1;
                }
            }

            self.state.inputOrderIndex[channel] = index;
        } else if (frameIndex > self.state.inputOrderIndex[channel]) {
            if (self.state.inputOrderingQueue.getPtr(channel)) |map| {
                map.put(frameIndex, frame) catch |err| {
                    std.debug.print("Failed to queue frame in ordering queue: {any}\n", .{err});
                };
            }
        } else {
            self.handlePacket(frame.payload) catch |err| {
                std.debug.print("Error handling packet: {any}\n", .{err});
            };
        }
    }

    /// Handles a split frame.
    /// Merges fragments when all pieces are received and dispatches the assembled frame.
    pub fn handleSplitFrame(self: *Session, frame: Frame) !void {
        const split = frame.splitInfo orelse {
            std.debug.print("Split frame missing split info\n", .{});
            return;
        };

        if (self.state.fragmentsQueue.getPtr(split.id)) |frag| {
            if (frag.contains(split.frameIndex)) {
                return;
            }

            const copy = try self.allocator.dupe(u8, frame.payload);
            const frameCopy = Frame.init(frame.reliability, copy, frame.orderChannel, frame.reliableFrameIndex, frame.sequenceFrameIndex, frame.orderedFrameIndex, frame.splitInfo, true);

            frag.put(split.frameIndex, frameCopy) catch {
                self.allocator.free(copy);
                return;
            };

            if (frag.count() == split.size) {
                var mergedLen: usize = 0;
                var iter = frag.iterator();
                while (iter.next()) |entry| {
                    mergedLen += entry.value_ptr.payload.len;
                }

                var merged = try self.allocator.alloc(u8, mergedLen);

                var i: u32 = 0;
                var pos: usize = 0;
                while (i < split.size) : (i += 1) {
                    const splitFrame = frag.get(i) orelse return;

                    std.mem.copyForwards(u8, merged[pos..], splitFrame.payload);
                    pos += splitFrame.payload.len;
                }

                var newFrame = Frame.init(frame.reliability, merged, frame.orderChannel, frame.reliableFrameIndex, frame.sequenceFrameIndex, frame.orderedFrameIndex, null, true);

                var fragIter = frag.iterator();
                while (fragIter.next()) |entry| {
                    entry.value_ptr.deinit(self.allocator);
                }
                frag.deinit();

                _ = self.state.fragmentsQueue.remove(split.id);

                if (newFrame.reliability.isSequenced()) {
                    self.handleSequencedFrame(newFrame);
                } else if (newFrame.reliability.isOrdered()) {
                    self.handleOrderedFrame(newFrame);
                } else {
                    self.handlePacket(newFrame.payload) catch |err| {
                        std.debug.print("Error handling packet: {any}\n", .{err});
                    };
                }

                newFrame.deinit(self.allocator);
            }
        } else {
            var newFragment = std.AutoHashMap(u32, Frame).init(self.allocator);

            const payloadCopy = self.allocator.dupe(u8, frame.payload) catch {
                return;
            };

            const frameCopy = Frame.init(frame.reliability, payloadCopy, frame.orderChannel, frame.reliableFrameIndex, frame.sequenceFrameIndex, frame.orderedFrameIndex, frame.splitInfo, true);

            newFragment.put(split.frameIndex, frameCopy) catch {
                self.allocator.free(payloadCopy);
                return;
            };
            self.state.fragmentsQueue.put(split.id, newFragment) catch {
                var iter = newFragment.iterator();
                while (iter.next()) |entry| {
                    entry.value_ptr.deinit(self.allocator);
                }
                newFragment.deinit();
                return;
            };
        }
    }

    /// Creates a frame from a payload.
    /// Allocates memory in the session arena.
    pub fn frameFromPayload(self: *Session, payload: []const u8) !Frame {
        const len = payload.len;
        const owned = try self.allocator.alloc(u8, len);
        std.mem.copyForwards(u8, owned, payload);
        return Frame.init(.ReliableOrdered, owned, 0, null, null, null, null, true);
    }

    /// Creates a frame from a payload with a specified reliability mode.
    pub fn frameFromPayloadWithReliability(self: *Session, payload: []const u8, reliability: Protocol.Reliability) !Frame {
        const len = payload.len;
        const owned = try self.allocator.alloc(u8, len);
        std.mem.copyForwards(u8, owned, payload);
        return Frame.init(reliability, owned, 0, null, null, null, null, true);
    }

    /// Sends a frame to the client, handling splitting if the frame exceeds MTU.
    pub fn sendFrame(self: *Session, frame: Frame, priority: Priority) void {
        if (!self.active) {
            return;
        }

        const channelIndex = frame.orderChannel orelse 0;
        const channel = @as(usize, channelIndex);
        var mutableFrame = frame;

        const reliability = mutableFrame.reliability;

        if (reliability.isSequenced()) {
            mutableFrame.orderedFrameIndex = self.state.outputOrderIndex[channel];
            mutableFrame.sequenceFrameIndex = self.state.outputSequenceIndex[channel];
            self.state.outputSequenceIndex[channel] += 1;
        } else if (reliability.isOrdered()) {
            mutableFrame.orderedFrameIndex = self.state.outputOrderIndex[channel];
            self.state.outputOrderIndex[channel] += 1;
            self.state.outputSequenceIndex[channel] = 0;
        }

        const payloadSize = mutableFrame.payload.len;
        const maxSize = self.mtuSize - 36;

        if (payloadSize <= maxSize) {
            if (reliability.isReliable()) {
                mutableFrame.reliableFrameIndex = self.state.outputReliableIndex;
                self.state.outputReliableIndex += 1;
            }
            self.enqueueFrame(&mutableFrame, priority);

            return;
        } else {
            const splitSize = (payloadSize + maxSize - 1) / maxSize;
            self.handleLargePayload(&mutableFrame, maxSize, splitSize, priority);
        }
    }

    /// Handles splitting a large payload into multiple frames.
    pub fn handleLargePayload(self: *Session, frame: *Frame, maxSize: usize, splitSize: usize, priority: Priority) void {
        const splitID = self.state.outputSplitIndex;
        self.state.outputSplitIndex = (self.state.outputSplitIndex +% 1);

        const originalPayload = frame.payload;

        var i: usize = 0;
        while (i < originalPayload.len) {
            const end = @min(i + maxSize, originalPayload.len);
            const fragmentPayload = originalPayload[i..end];

            const copy = fragmentPayload;

            var newFrame: Frame = undefined;
            if (frame.shouldFree) {
                const fragLen = fragmentPayload.len;
                const ownedFrag = self.allocator.alloc(u8, fragLen) catch {
                    return;
                };
                std.mem.copyForwards(u8, ownedFrag, fragmentPayload);
                newFrame = Frame.init(frame.reliability, ownedFrag, frame.orderChannel, frame.reliableFrameIndex, frame.sequenceFrameIndex, frame.orderedFrameIndex, .{
                    .id = splitID,
                    .size = @as(u32, @intCast(splitSize)),
                    .frameIndex = @as(u32, @intCast(i / maxSize)),
                }, true);
            } else {
                newFrame = Frame.init(frame.reliability, copy, frame.orderChannel, frame.reliableFrameIndex, frame.sequenceFrameIndex, frame.orderedFrameIndex, .{
                    .id = splitID,
                    .size = @as(u32, @intCast(splitSize)),
                    .frameIndex = @as(u32, @intCast(i / maxSize)),
                }, false);
            }

            if (i != 0 and newFrame.reliability.isReliable()) {
                newFrame.reliableFrameIndex = self.state.outputReliableIndex;
                self.state.outputReliableIndex += 1;
            } else if (i == 0 and newFrame.reliability.isReliable()) {
                newFrame.reliableFrameIndex = self.state.outputReliableIndex;
                self.state.outputReliableIndex += 1;
            }

            self.enqueueFrame(&newFrame, priority);
            i += maxSize;
        }
    }

    /// Enqueues a frame into the session's output queue.
    /// Sends immediately if priority is Immediate.
    pub fn enqueueFrame(self: *Session, frame: *Frame, priority: Priority) void {
        if (!self.active) {
            frame.deinit(self.allocator);
            return;
        }

        self.state.outputFrameQueue.append(self.allocator, frame.*) catch {
            frame.deinit(self.allocator);
            return;
        };

        const shouldSendImmediately = priority == Priority.Immediate;
        const queueLen = self.state.outputFrameQueue.items.len;
        if (shouldSendImmediately) {
            self.sendQueuedFrames(queueLen);
        }
    }

    /// Sends queued frames up to the given amount.
    /// Manages backup storage for reliable frames.
    pub fn sendQueuedFrames(self: *Session, amount: usize) void {
        if (self.state.outputFrameQueue.items.len == 0) return;

        const maxFragmentSize = self.mtuSize - Constants.UDP_HEADER_SIZE;
        var currentSize: usize = 4;
        var framesToSend: usize = 0;

        const queueLen = self.state.outputFrameQueue.items.len;
        const maxFrames = @min(amount, queueLen);

        for (self.state.outputFrameQueue.items[0..maxFrames]) |frame| {
            const frameSize = Constants.UDP_HEADER_SIZE + frame.payload.len;
            if (currentSize + frameSize > maxFragmentSize and framesToSend > 0) {
                break;
            }
            currentSize += frameSize;
            framesToSend += 1;
        }

        if (framesToSend == 0) {
            framesToSend = 1;
        }

        const frames = self.state.outputFrameQueue.items[0..framesToSend];

        const sequence = @as(u24, @truncate(self.state.outputSequence));
        self.state.outputSequence += 1;

        _ = self.state.outputBackup.remove(sequence);

        var backupBuf = self.allocator.alloc(Frame, frames.len) catch {
            std.debug.print("Failed to alloc backup buffer\n", .{});
            return;
        };

        var i: usize = 0;
        while (i < frames.len) : (i += 1) {
            backupBuf[i] = frames[i];
            backupBuf[i].shouldFree = true;
        }
        const backupSlice = backupBuf[0..frames.len];

        self.state.outputBackup.put(sequence, backupSlice) catch {
            self.allocator.free(backupSlice);
            std.debug.print("Failed to put output backup\n", .{});
            return;
        };

        var t: usize = 0;
        while (t < framesToSend) : (t += 1) {
            self.state.outputFrameQueue.items[t].shouldFree = false;
        }

        self.server.packetBuf.reset(false);
        var writer = self.server.packetBuf.writer;

        var frameset = Messages.FrameSet.init(sequence, frames);
        const serialized = frameset.serialize(&writer) catch |err| {
            std.debug.print("Error serializing frame: {any}\n", .{err});

            _ = self.state.outputBackup.remove(sequence);
            for (backupSlice) |*frame| {
                if (frame.shouldFree) frame.deinit(self.allocator);
            }
            self.allocator.free(backupSlice);
            return;
        };

        self.cleanupSentFrames(framesToSend);
        self.send(serialized);
    }

    /// Cleans up frames that were sent from the output queue.
    fn cleanupSentFrames(self: *Session, amount: usize) void {
        const queue = &self.state.outputFrameQueue;
        const toRemove = @min(amount, queue.items.len);
        if (toRemove == 0) return;

        for (queue.items[0..toRemove]) |*constFrame| {
            var frame: *Frame = @constCast(constFrame);
            frame.deinit(self.allocator);
        }

        queue.replaceRange(self.allocator, 0, toRemove, &[_]Frame{}) catch |err| {
            std.debug.print("Error cleaning frame queue: {any}\n", .{err});
            return;
        };
    }

    /// Sends raw data to the client.
    pub fn send(self: *Session, data: []const u8) void {
        self.server.send(data, self.address);
    }

    /// Sends an ACK packet for a specific sequence.
    fn sendAck(self: *Session, sequence: u24) void {
        self.server.packetBuf.reset(false);
        var writer = self.server.packetBuf.writer;

        var seq: [1]u24 = .{sequence};
        var ack = Messages.Ack{ .sequences = seq[0..] };
        const serialized = ack.serialize(&writer) catch return;
        self.send(serialized);
    }

    /// Sends a ConnectedPing to the client.
    pub fn sendPing(self: *Session) void {
        var ping = Messages.ConnectedPing.init(std.time.milliTimestamp());

        self.server.packetBuf.reset(false);
        var writer = self.server.packetBuf.writer;

        const serialized = ping.serialize(&writer) catch |err| {
            std.debug.print("Error trying to serialize ConnectedPing: {any}\n", .{err});
            return;
        };

        const frame = frameFromPayload(self, serialized) catch |err| {
            std.debug.print("Failed to alloc frame payload: {any}\n", .{err});
            return;
        };
        self.sendFrame(frame, .Normal);
    }
};

/// Stores internal state for a session.
/// Manages sequencing, ordering, fragments, and output queues.
const SessionState = struct {
    outputReliableIndex: u24,
    outputSequence: u32,
    outputSplitIndex: u16,

    outputFrameQueue: std.ArrayList(Frame),
    outputBackup: std.AutoHashMap(u24, []Frame),

    outputOrderIndex: [Constants.MAX_ACTIVE_FRAGMENTATIONS]u24,
    outputSequenceIndex: [Constants.MAX_ACTIVE_FRAGMENTATIONS]u24,

    lastInputSequence: i32 = -1,
    receivedSequences: std.ArrayList(u24),
    lostSequences: std.ArrayList(u24),

    inputHighestSequenceIndex: [Constants.MAX_ACTIVE_FRAGMENTATIONS]u32,
    inputOrderIndex: [Constants.MAX_ACTIVE_FRAGMENTATIONS]u32,
    inputOrderingQueue: std.AutoHashMap(u32, std.AutoHashMap(u32, Frame)),

    fragmentsQueue: std.AutoHashMap(u16, std.AutoHashMap(u32, Frame)),

    /// Initializes a new session state with empty queues and default indices.
    pub fn init(allocator: std.mem.Allocator) !SessionState {
        return .{
            .outputReliableIndex = 0,
            .outputSequence = 0,
            .outputSplitIndex = 0,
            .outputFrameQueue = std.ArrayList(Frame){ .items = &[_]Frame{}, .capacity = 0 },
            .outputBackup = std.AutoHashMap(u24, []Frame).init(allocator),
            .outputOrderIndex = undefined,
            .outputSequenceIndex = undefined,
            .lastInputSequence = -1,
            .receivedSequences = try std.ArrayList(u24).initCapacity(allocator, Constants.MAX_SEQUENCES),
            .lostSequences = try std.ArrayList(u24).initCapacity(allocator, Constants.MAX_SEQUENCES),
            .inputHighestSequenceIndex = undefined,
            .inputOrderIndex = undefined,
            .inputOrderingQueue = std.AutoHashMap(u32, std.AutoHashMap(u32, Frame)).init(allocator),
            .fragmentsQueue = std.AutoHashMap(u16, std.AutoHashMap(u32, Frame)).init(allocator),
        };
    }

    pub fn deinit(self: *SessionState, allocator: std.mem.Allocator) void {
        // Deinit simple hash maps
        self.receivedSequences.deinit(allocator);
        self.lostSequences.deinit(allocator);

        // Cleanup output frame queue
        for (self.outputFrameQueue.items) |*frame| {
            var f: *Frame = @constCast(frame);
            f.deinit(allocator);
        }
        self.outputFrameQueue.deinit(allocator);

        // Cleanup input ordering queues
        var outerIter = self.inputOrderingQueue.iterator();
        while (outerIter.next()) |outerEntry| {
            var innerMap = outerEntry.value_ptr;
            var innerIter = innerMap.iterator();
            while (innerIter.next()) |entry| {
                const frame: *Frame = @constCast(entry.value_ptr);
                if (frame.shouldFree) frame.deinit(allocator);
            }
            innerMap.deinit();
        }
        self.inputOrderingQueue.deinit();

        // Cleanup output backup frames
        var backupIter = self.outputBackup.iterator();
        while (backupIter.next()) |entry| {
            const frames = entry.value_ptr.*;
            for (frames) |*constFrame| {
                var frame: *Frame = @constCast(constFrame);
                if (frame.shouldFree) frame.deinit(allocator);
            }
            allocator.free(frames);
        }
        self.outputBackup.deinit();

        // Cleanup fragments queue
        var fragmentsIter = self.fragmentsQueue.iterator();
        while (fragmentsIter.next()) |outerEntry| {
            var innerMap = outerEntry.value_ptr;
            var innerIter = innerMap.iterator();
            while (innerIter.next()) |entry| {
                const frame = entry.value_ptr;
                if (frame.shouldFree) frame.deinit(allocator);
            }
            innerMap.deinit();
        }
        self.fragmentsQueue.deinit();
    }
};
