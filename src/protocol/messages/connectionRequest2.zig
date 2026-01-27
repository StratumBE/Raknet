const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Reader = BinaryUtils.BinaryReader;
const Writer = BinaryUtils.BinaryWriter;

const Magic = @import("../magic.zig").Magic;
const PacketID = @import("../packet.zig").PacketID;
const Constants = @import("../constants.zig");

/// Open Connection Request 2 packet.
///
/// This packet is sent after a successful ConnectionRequest1 exchange.
/// It finalizes MTU negotiation and communicates the client GUID
/// and the server address the client is attempting to connect to.
///
/// NOTE:
/// Security (cookies / encryption / challenge-response) is NOT supported.
/// `serverHasSecurity` is always false and `cookie` is ignored.
pub const ConnectionRequest2 = struct {
    /// Address of the server the client is connecting to.
    serverAddress: std.net.Address,

    /// Negotiated MTU size.
    mtuSize: u16,

    /// Globally unique identifier of the client.
    clientGUID: u64,

    /// Whether the server reports that it supports security features.
    ///
    /// This implementation does NOT support RakNet security,
    /// so this value is always false.
    serverHasSecurity: bool,

    /// Security cookie value.
    ///
    /// Not used in this implementation. Always set to 0.
    cookie: u32,

    /// Creates a new ConnectionRequest2 packet.
    pub fn init(
        serverAddress: std.net.Address,
        mtuSize: u16,
        clientGUID: u64,
        serverHasSecurity: bool,
        cookie: u32,
    ) ConnectionRequest2 {
        return .{
            .serverAddress = serverAddress,
            .mtuSize = mtuSize,
            .clientGUID = clientGUID,
            .serverHasSecurity = serverHasSecurity,
            .cookie = cookie,
        };
    }

    /// Serializes the packet into a byte buffer.
    ///
    /// Layout:
    /// - Packet ID
    /// - Magic bytes
    /// - Server address
    /// - MTU size
    /// - Client GUID
    ///
    /// Security fields are intentionally omitted.
    pub fn serialize(self: *ConnectionRequest2, writer: *Writer) !ConnectionRequest2 {
        try writer.writeU8(@intFromEnum(PacketID.OpenConnectionRequest2));
        try Magic.write(writer);
        try writer.writeAddress(self.serverAddress);
        try writer.writeU16BE(self.mtuSize);
        try writer.writeU64BE(self.clientGUID);

        return writer.buf[0..writer.pos];
    }

    /// Deserializes a ConnectionRequest2 packet.
    ///
    /// Since security is not supported, `serverHasSecurity` is set to false
    /// and `cookie` is set to 0 regardless of input.
    pub fn deserialize(data: []const u8) !ConnectionRequest2 {
        var reader = Reader.init(data);

        _ = try reader.readU8();
        try Magic.read(&reader);

        const address = try reader.readAddress();
        const mtuSize = try reader.readU16BE();
        const clientGUID = try reader.readU64BE();

        return .{
            .serverAddress = address,
            .mtuSize = mtuSize,
            .clientGUID = clientGUID,
            .serverHasSecurity = false,
            .cookie = 0,
        };
    }
};
