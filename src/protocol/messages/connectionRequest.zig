const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Reader = BinaryUtils.BinaryReader;
const Writer = BinaryUtils.BinaryWriter;

const PacketID = @import("../packet.zig").PacketID;

/// Standard Connection Request packet.
///
/// Sent by a client to initiate a connection with the server.
/// Contains a client GUID, a timestamp for handshake validation,
/// and a security flag.
///
/// NOTE:
/// - Security (`useSecurity`) is not supported in this implementation.
///   The flag is parsed and serialized only for protocol compatibility.
pub const ConnectionRequest = struct {
    /// Unique identifier of the client.
    guid: i64,

    /// Timestamp sent by the client for connection validation.
    timestamp: i64,

    /// Indicates whether the client requests security.
    ///
    /// Security is not implemented and should be considered informational only.
    useSecurity: bool,

    /// Initializes a new ConnectionRequest packet.
    pub fn init(guid: u64, timestamp: i64, useSecurity: bool) ConnectionRequest {
        return .{
            .guid = guid,
            .timestamp = timestamp,
            .useSecurity = useSecurity,
        };
    }

    /// Serializes the ConnectionRequest into a byte buffer.
    ///
    /// Layout:
    /// - Packet ID
    /// - GUID (64-bit big-endian)
    /// - Timestamp (64-bit big-endian)
    /// - Security flag (bool)
    pub fn serialize(self: *ConnectionRequest, writer: *Writer) ![]const u8 {
        try writer.writeU8(@intFromEnum(PacketID.ConnectionRequest));
        try writer.writeI64BE(self.guid);
        try writer.readI64BE(self.timestamp);
        try writer.writeBool(self.useSecurity);

        return writer.buf[0..writer.pos];
    }

    /// Deserializes a ConnectionRequest from a byte buffer.
    ///
    /// Security flags are parsed but not enforced.
    pub fn deserialize(data: []const u8) !ConnectionRequest {
        var reader = Reader.init(data);

        _ = try reader.readU8();
        const guid = try reader.readI64BE();
        const timestamp = try reader.readI64BE();
        const useSecurity = try reader.readBool();

        return .{
            .guid = guid,
            .timestamp = timestamp,
            .useSecurity = useSecurity,
        };
    }
};
