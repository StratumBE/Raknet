const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Reader = BinaryUtils.BinaryReader;
const Writer = BinaryUtils.BinaryWriter;

const PacketID = @import("../packet.zig").PacketID;

/// Represents a connected pong packet.
///
/// Sent in response to a `ConnectedPing` to measure latency and verify the connection.
/// Security and encryption are not applied to this packet.
///
/// Fields:
/// - `timestamp`: The timestamp from the original ping packet.
/// - `pongTimestamp`: The current timestamp of the sender when the pong was created.
pub const ConnectedPong = struct {
    timestamp: i64,
    pongTimestamp: i64,

    /// Initialize a new ConnectedPong packet.
    pub fn init(timestamp: i64, pongTimestamp: i64) ConnectedPong {
        return .{
            .timestamp = timestamp,
            .pongTimestamp = pongTimestamp,
        };
    }

    /// Serialize the connected pong into the provided writer.
    ///
    /// Format:
    /// - Packet ID (1 byte)
    /// - Timestamp (8 bytes, big-endian)
    /// - Pong timestamp (8 bytes, big-endian)
    pub fn serialize(self: *ConnectedPong, writer: *Writer) ![]u8 {
        try writer.writeU8(@intFromEnum(PacketID.ConnectedPong));
        try writer.writeI64BE(self.timestamp);
        try writer.writeI64BE(self.pongTimestamp);

        return writer.buf[0..writer.pos];
    }

    /// Deserialize a connected pong packet from a buffer.
    ///
    /// Returns an error if the buffer is malformed or too short.
    pub fn deserialize(buffer: []const u8) !ConnectedPong {
        var reader = Reader.init(buffer);

        _ = try reader.readU8();

        const timestamp = try reader.readI64BE();
        const pongTimestamp = try reader.readI64BE();

        return .{
            .timestamp = timestamp,
            .pongTimestamp = pongTimestamp,
        };
    }
};
