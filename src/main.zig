const std = @import("std");
const Raknet = @import("Raknet");
const Handler = Raknet.Handler;
const Server = Raknet.Server;
const Session = Raknet.Session;

const MyHandler = struct {
    counter: usize,

    fn onConnect(ctx: *anyopaque, session: *Session) void {
        const self: *MyHandler = @ptrCast(@alignCast(ctx));
        self.counter += 1;

        std.debug.print("Session connected, guid: {d}\nCurrently connected: {d}\n", .{ session.guid, self.counter });
    }

    pub fn onDisconnect(ctx: *anyopaque, session: *Session) void {
        const self: *MyHandler = @ptrCast(@alignCast(ctx));
        self.counter -= 1;

        std.debug.print("Session disconnected, guid: {d}\nCurrently connected: {d}\n", .{ session.guid, self.counter });
    }

    pub fn onGamePacket(ctx: *anyopaque, session: *Session, payload: []const u8) void {
        _ = ctx;

        std.debug.print("GamePacket received, guid={d} len={d} data={any}\n", .{ session.guid, payload.len, payload });
    }

    const vtable = Handler.VTable{
        .onConnect = onConnect,
        .onDisconnect = onDisconnect,
        .onGamePacket = onGamePacket,
    };

    pub fn handler(self: *MyHandler) Handler {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }
};

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var handler = MyHandler{ .counter = 0 };

    var server = Server.init(.{
        .address = "0.0.0.0",
        .maxSessions = -1,
        .port = 14232,
    }, handler.handler(), allocator) catch |err| {
        std.debug.print("Error creating server: {any}\n", .{err});
        return;
    };
    defer server.deinit();

    server.listen(64) catch |err| {
        std.debug.print("Error listening: {any}\n", .{err});
        return;
    };
}
