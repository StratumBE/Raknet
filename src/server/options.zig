const std = @import("std");

pub const Options = struct {
    protocolVersion: u8 = 11,
    address: []const u8 = "0.0.0.0",
    port: u16 = 19132,
    tickRate: i64 = 50,
    advertisement: []const u8 = "",
    timeout: i64 = 10_000,
    maxSessions: i32 = 20,
};
