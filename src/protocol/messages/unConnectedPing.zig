const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Reader = BinaryUtils.BinaryReader;
const Writer = BinaryUtils.BinaryWriter;

const Magic = @import("../magic.zig").Magic;

const PacketID = @import("../packet.zig").PacketID;

/// Represents an unconnected ping packet.
///
/// Used to test latency or reachability of a server without establishing
/// a full connection. Security features are not applied in this packet.
///
/// Fields:
/// - `timestamp`: Client-side timestamp when the ping was created.
/// - `guid`: Unique identifier of the client sending the ping.
pub const UnconnectedPing = struct {
    timestamp: i64,
    guid: u64,

    /// Initialize a new UnconnectedPing packet.
    pub fn init(timestamp: i64, guid: u64) UnconnectedPing {
        return .{
            .timestamp = timestamp,
            .guid = guid,
        };
    }

    /// Serialize the ping into the provided writer.
    ///
    /// Format:
    /// - Packet ID (1 byte)
    /// - Timestamp (8 bytes, big-endian)
    /// - Magic bytes (16 bytes)
    /// - GUID (8 bytes, big-endian)
    pub fn serialize(self: *UnconnectedPing, writer: *Writer) ![]u8 {
        try writer.writeU8(@intFromEnum(PacketID.UnconnectedPing));
        try writer.writeI64BE(self.timestamp);
        try Magic.write(writer);
        try writer.writeU64BE(self.guid);

        return writer.buf[0..writer.pos];
    }

    /// Deserialize an UnconnectedPing packet from a buffer.
    ///
    /// Returns an error if the buffer is malformed or too short.
    pub fn deserialize(buffer: []const u8) !UnconnectedPing {
        var reader = Reader.init(buffer);

        _ = try reader.readU8();
        const timestamp = try reader.readI64BE();
        try Magic.read(&reader);
        const guid = try reader.readU64BE();

        return .{
            .timestamp = timestamp,
            .guid = guid,
        };
    }
};
