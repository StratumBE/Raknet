const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Reader = BinaryUtils.BinaryReader;
const Writer = BinaryUtils.BinaryWriter;

const PacketID = @import("../packet.zig").PacketID;

/// Represents a connected ping packet.
///
/// Sent by a client or server to measure latency after a connection has been established.
/// Security and encryption are not applied to this packet.
///
/// Fields:
/// - `timestamp`: The current timestamp of the sender when the ping was created.
pub const ConnectedPing = struct {
    timestamp: i64,

    /// Initialize a new ConnectedPing packet.
    pub fn init(timestamp: i64) ConnectedPing {
        return .{
            .timestamp = timestamp,
        };
    }

    /// Serialize the connected ping into the provided writer.
    ///
    /// Format:
    /// - Packet ID (1 byte)
    /// - Timestamp (8 bytes, big-endian)
    pub fn serialize(self: *ConnectedPing, writer: *Writer) ![]u8 {
        try writer.writeU8(@intFromEnum(PacketID.ConnectedPing));
        try writer.writeI64BE(self.timestamp);

        return writer.buf[0..writer.pos];
    }

    /// Deserialize a connected ping packet from a buffer.
    ///
    /// Returns an error if the buffer is malformed or too short.
    pub fn deserialize(buffer: []const u8) !ConnectedPing {
        var reader = Reader.init(buffer);

        _ = try reader.readU8();
        const timestamp = try reader.readI64BE();

        return .{
            .timestamp = timestamp,
        };
    }
};
