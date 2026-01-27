const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Reader = BinaryUtils.BinaryReader;
const Writer = BinaryUtils.BinaryWriter;

const PacketID = @import("../packet.zig").PacketID;

/// ConnectionRequestAccepted packet.
///
/// Sent by the server to the client after a connection request is accepted.
/// Provides server addresses, system index, and handshake timestamps.
///
/// Notes:
/// - The `addresses` field contains 20 local server addresses; currently all are the same.
/// - Security is not applied to this packet.
///
/// Fields:
/// - `address`: The server's main address (primary).
/// - `addresses`: One of 20 server local network addresses.
/// - `systemIndex`: Index of the server/system in the network.
/// - `requestTimestamp`: Timestamp from the client's original request.
/// - `timestamp`: Server timestamp when accepting the connection.
pub const ConnectionRequestAccepted = struct {
    address: std.net.Address,
    systemIndex: u16,
    addresses: std.net.Address,
    requestTimestamp: i64,
    timestamp: i64,

    /// Initialize a new ConnectionRequestAccepted packet.
    pub fn init(
        address: std.net.Address,
        systemIndex: u16,
        addresses: std.net.Address,
        requestTimestamp: i64,
        timestamp: i64,
    ) ConnectionRequestAccepted {
        return .{
            .address = address,
            .systemIndex = systemIndex,
            .addresses = addresses,
            .requestTimestamp = requestTimestamp,
            .timestamp = timestamp,
        };
    }

    /// Serialize the packet into a buffer.
    ///
    /// Writes 20 copies of `addresses` to match the protocol format.
    pub fn serialize(self: *ConnectionRequestAccepted, writer: *Writer) ![]const u8 {
        try writer.writeU8(@intFromEnum(PacketID.ConnectionRequestAccepted));
        try writer.writeAddress(self.address);
        try writer.writeU16BE(self.systemIndex);

        // Write 20 addresses (all the same in current implementation)
        var i: u8 = 0;
        while (i < 20) : (i += 1) {
            try writer.writeAddress(self.addresses);
        }

        try writer.writeI64BE(self.requestTimestamp);
        try writer.writeI64BE(self.timestamp);

        return writer.buf[0..writer.pos];
    }

    /// Deserialize the packet from a buffer.
    ///
    /// Reads the first of the 20 server addresses and discards the remaining 19.
    pub fn deserialize(data: []const u8) !ConnectionRequestAccepted {
        var reader = Reader.init(data);

        _ = try reader.readU8();

        const address = try reader.readAddress();
        const systemIndex = try reader.readU16BE();

        // Read first of the 20 addresses; ignore the remaining
        const addresses = try reader.readAddress();
        var i: u8 = 0;
        while (i < 19) : (i += 1) {
            _ = try reader.readAddress();
        }

        const requestTimestamp = try reader.readI64BE();
        const timestamp = try reader.readI64BE();

        return .{
            .address = address,
            .systemIndex = systemIndex,
            .addresses = addresses,
            .requestTimestamp = requestTimestamp,
            .timestamp = timestamp,
        };
    }
};
