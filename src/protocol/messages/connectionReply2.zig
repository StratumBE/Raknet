const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Reader = BinaryUtils.BinaryReader;
const Writer = BinaryUtils.BinaryWriter;

const Magic = @import("../magic.zig").Magic;
const PacketID = @import("../packet.zig").PacketID;

/// Open Connection Reply 2 packet.
///
/// Sent by the server in response to `OpenConnectionRequest2`.
/// This packet finalizes the connection handshake by confirming
/// the server GUID, echoed client address, and negotiated MTU.
///
/// NOTE:
/// - Encryption / security is NOT supported by this implementation.
/// - Any security-related flags are parsed or written only for
///   protocol compatibility and should be considered informational.
pub const ConnectionReply2 = struct {
    /// Globally unique identifier of the server.
    serverGUID: u64,

    /// Address of the client as seen by the server.
    ///
    /// This is typically echoed back to the client to confirm
    /// the externally visible address.
    address: std.net.Address,

    /// Final negotiated MTU size for the connection.
    mtuSize: u16,

    /// Indicates whether encryption is enabled.
    ///
    /// Encryption is not implemented, so this value is expected
    /// to be false.
    encryptionEnabled: bool,

    /// Creates a new ConnectionReply2 packet.
    pub fn init(
        serverGUID: u64,
        address: std.net.Address,
        mtuSize: u16,
        encryptionEnabled: bool,
    ) ConnectionReply2 {
        return .{
            .serverGUID = serverGUID,
            .address = address,
            .mtuSize = mtuSize,
            .encryptionEnabled = encryptionEnabled,
        };
    }

    /// Serializes the packet into a byte buffer.
    ///
    /// Layout:
    /// - Packet ID
    /// - Magic bytes
    /// - Server GUID
    /// - Client address
    /// - MTU size
    /// - Encryption enabled flag
    ///
    /// Security fields are written for compatibility only.
    pub fn serialize(self: *ConnectionReply2, writer: *Writer) ![]const u8 {
        try writer.writeU8(@intFromEnum(PacketID.OpenConnectionReply2));
        try Magic.write(writer);
        try writer.writeU64BE(self.serverGUID);
        try writer.writeAddress(self.address);
        try writer.writeU16BE(self.mtuSize);
        try writer.writeBool(self.encryptionEnabled);

        return writer.buf[0..writer.pos];
    }

    /// Deserializes a ConnectionReply2 packet from a byte buffer.
    ///
    /// Security and encryption flags are parsed but not acted upon.
    pub fn deserialize(data: []const u8) !ConnectionReply2 {
        var reader = Reader.init(data);

        _ = try reader.readU8();
        try Magic.read(&reader);

        const serverGUID = try reader.readU64BE();
        const serverHasSecurity = try reader.readBool();
        const mtuSize = try reader.readU16BE();
        const encryptionEnabled = try reader.readBool();

        return .{
            .serverGUID = serverGUID,
            .serverHasSecurity = serverHasSecurity,
            .mtuSize = mtuSize,
            .encryptionEnabled = encryptionEnabled,
        };
    }
};
