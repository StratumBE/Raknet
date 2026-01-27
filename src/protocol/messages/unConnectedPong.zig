const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Reader = BinaryUtils.BinaryReader;
const Writer = BinaryUtils.BinaryWriter;

const Magic = @import("../magic.zig").Magic;
const PacketID = @import("../packet.zig").PacketID;

/// Represents an unconnected pong packet.
///
/// Sent by the server in response to an UnconnectedPing packet.
/// Used to measure latency and provide server information without
/// establishing a full connection. Security features are not applied.
///
/// Fields:
/// - `timestamp`: The timestamp sent by the client in the corresponding ping.
/// - `guid`: Unique identifier of the client that sent the ping.
/// - `message`: Optional server message or MOTD, UTF-8 encoded.
pub const UnconnectedPong = struct {
    timestamp: i64,
    guid: u64,
    message: []const u8,

    /// Initialize a new UnconnectedPong packet.
    pub fn init(timestamp: i64, guid: u64, message: []const u8) UnconnectedPong {
        return .{
            .timestamp = timestamp,
            .guid = guid,
            .message = message,
        };
    }

    /// Serialize the pong into the provided writer.
    ///
    /// Format:
    /// - Packet ID (1 byte)
    /// - Timestamp (8 bytes, big-endian)
    /// - GUID (8 bytes, big-endian)
    /// - Magic bytes (16 bytes)
    /// - Server message length (2 bytes, big-endian)
    /// - Server message (variable)
    pub fn serialize(self: *UnconnectedPong, writer: *Writer) ![]u8 {
        try writer.writeU8(@intFromEnum(PacketID.UnconnectedPong));
        try writer.writeI64BE(self.timestamp);
        try writer.writeU64BE(self.guid);
        try Magic.write(writer);
        try writer.writeString16BE(self.message);

        return writer.buf[0..writer.pos];
    }

    /// Deserialize an UnconnectedPong packet from a buffer.
    ///
    /// Returns an error if the buffer is malformed or too short.
    pub fn deserialize(buffer: []const u8) !UnconnectedPong {
        var reader = Reader.init(buffer);

        _ = try reader.readU8();

        const timestamp = try reader.readI64BE();
        const guid = try reader.readU64BE();
        try Magic.read(&reader);
        const message = try reader.readString16BE();

        return .{
            .timestamp = timestamp,
            .guid = guid,
            .message = message,
        };
    }
};
