const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Reader = BinaryUtils.BinaryReader;
const Writer = BinaryUtils.BinaryWriter;

const Magic = @import("../magic.zig").Magic;

const PacketID = @import("../packet.zig").PacketID;

/// Indicates that the client and server are using incompatible protocol versions.
///
/// Security is not applied to this packet.
///
/// Fields:
/// - `protocolVersion`: The protocol version of the sender (usually the server).
/// - `guid`: The GUID of the sender.
pub const IncompatibleProtocolVersion = struct {
    protocolVersion: u8,
    guid: u64,

    /// Initialize a new IncompatibleProtocolVersion packet.
    pub fn init(protocolVersion: u8, guid: u64) IncompatibleProtocolVersion {
        return .{
            .protocolVersion = protocolVersion,
            .guid = guid,
        };
    }

    /// Serialize the packet into the provided writer.
    ///
    /// Format:
    /// - Packet ID (1 byte)
    /// - Protocol version (1 byte)
    /// - Magic bytes (16 bytes)
    /// - Sender GUID (8 bytes, big-endian)
    pub fn serialize(self: *IncompatibleProtocolVersion, writer: *Writer) ![]u8 {
        try writer.writeU8(@intFromEnum(PacketID.IncompatibleProtocolVersion));
        try writer.writeU8(self.protocolVersion);
        try Magic.write(writer);
        try writer.writeU64BE(self.guid);

        return writer.buf[0..writer.pos];
    }

    /// Deserialize the packet from a buffer.
    ///
    /// Returns an error if the buffer is malformed or too short.
    pub fn deserialize(buffer: []const u8) !IncompatibleProtocolVersion {
        var reader = Reader.init(buffer);

        _ = try reader.readU8();
        const protocolVersion = try reader.readU8();
        try Magic.read(&reader);
        const guid = try reader.readU64BE();

        return .{
            .protocolVersion = protocolVersion,
            .guid = guid,
        };
    }
};
