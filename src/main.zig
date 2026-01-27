const std = @import("std");
const Raknet = @import("Raknet");
const Server = Raknet.Server;
const Session = Raknet.Session;

fn onGamePacket(conn: *Session, payload: []const u8, _: ?*anyopaque) void {
    std.debug.print("GamePacket received, guid={d} len={d} data={any}\n", .{ conn.guid, payload.len, payload });
}

fn onConnect(conn: *Session, _: ?*anyopaque) void {
    std.debug.print("Session connected, guid: {d}\n", .{conn.guid});
    conn.onGamePacket(onGamePacket, null);
}

fn onDisconnect(conn: *Session, _: ?*anyopaque) void {
    std.debug.print("Session disconnected, guid: {d}\n", .{conn.guid});
}

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var server = Server.init(.{
        .address = "127.0.0.1",
    }, allocator) catch |err| {
        std.debug.print("Error creating server: {any}\n", .{err});
        return;
    };
    defer server.deinit();

    server.onConnect(onConnect, null);
    server.onDisconnect(onDisconnect, null);

    server.listen(null) catch |err| {
        std.debug.print("Error listening: {any}\n", .{err});
        return;
    };
}
