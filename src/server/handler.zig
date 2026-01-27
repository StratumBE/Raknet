const std = @import("std");

const Session = @import("session.zig").Session;

pub const Handler = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        onConnect: *const fn (*anyopaque, *Session) void,
        onDisconnect: *const fn (*anyopaque, *Session) void,
        onGamePacket: *const fn (*anyopaque, *Session, []const u8) void,
    };

    pub fn onConnect(self: Handler, session: *Session) void {
        self.vtable.onConnect(self.ctx, session);
    }

    pub fn onDisconnect(self: Handler, session: *Session) void {
        self.vtable.onDisconnect(self.ctx, session);
    }

    pub fn onGamePacket(self: Handler, session: *Session, data: []const u8) void {
        self.vtable.onGamePacket(self.ctx, session, data);
    }
};
