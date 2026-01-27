const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Reader = BinaryUtils.BinaryReader;
const Writer = BinaryUtils.BinaryWriter;

const Magic = @import("../magic.zig").Magic;
const PacketID = @import("../packet.zig").PacketID;

/// Open Connection Reply 1 packet.
///
/// Sent by the server in response to `OpenConnectionRequest1`.
/// This packet confirms reachability, echoes the negotiated MTU,
/// and provides the server's GUID.
///
/// NOTE:
/// Security is not supported in this implementation.
/// While `serverHasSecurity` exists for protocol compatibility,
/// it is expected to always be `false`.
pub const ConnectionReply1 = struct {
    /// Globally unique identifier of the server.
    serverGUID: u64,

    /// Indicates whether the server supports security features.
    ///
    /// This implementation does NOT support RakNet security,
    /// so this value should always be false.
    serverHasSecurity: bool,

    /// Security cookie value.
    ///
    /// Not used in this implementation.
    cookie: u32,

    /// Negotiated MTU size accepted by the server.
    mtuSize: u16,

    /// Creates a new ConnectionReply1 packet.
    pub fn init(
        serverGUID: u64,
        serverHasSecurity: bool,
        cookie: u32,
        mtuSize: u16,
    ) ConnectionReply1 {
        return .{
            .serverGUID = serverGUID,
            .serverHasSecurity = serverHasSecurity,
            .cookie = cookie,
            .mtuSize = mtuSize,
        };
    }

    /// Serializes the packet into a byte buffer.
    ///
    /// Layout:
    /// - Packet ID
    /// - Magic bytes
    /// - Server GUID
    /// - Security flag
    /// - MTU size
    ///
    /// Security cookies are intentionally omitted.
    pub fn serialize(self: *ConnectionReply1, writer: *Writer) ![]const u8 {
        try writer.writeU8(@intFromEnum(PacketID.OpenConnectionReply1));
        try Magic.write(writer);
        try writer.writeU64BE(self.serverGUID);
        try writer.writeBool(self.serverHasSecurity);
        try writer.writeU16BE(self.mtuSize);

        return writer.buf[0..writer.pos];
    }

    /// Deserializes a ConnectionReply1 packet from a byte buffer.
    ///
    /// The security flag is read for protocol correctness,
    /// but no security features are acted upon.
    pub fn deserialize(data: []const u8) !ConnectionReply1 {
        var reader = Reader.init(data);

        _ = try reader.readU8();
        try Magic.read(&reader);

        const serverGUID = try reader.readU64BE();
        const serverHasSecurity = try reader.readBool();
        const mtuSize = try reader.readU16BE();

        return .{
            .serverGUID = serverGUID,
            .serverHasSecurity = serverHasSecurity,
            .mtuSize = mtuSize,
        };
    }
};
