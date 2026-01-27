const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Reader = BinaryUtils.BinaryReader;
const Writer = BinaryUtils.BinaryWriter;

const Magic = @import("../magic.zig").Magic;
const PacketID = @import("../packet.zig").PacketID;
const Constants = @import("../constants.zig");

/// OpenConnectionRequest1 (RakNet)
///
/// Sent by the client during the first stage of connection negotiation.
///
/// Purpose:
/// - Advertise the client's RakNet protocol version
/// - Allow the server to infer the client's MTU size based on packet length
///
/// IMPORTANT:
/// - MTU is *not* sent explicitly
/// - MTU is derived from packet size + UDP header
/// - The packet is padded with zeros up to the MTU
pub const ConnectionRequest1 = struct {
    /// RakNet protocol version used by the client
    protocol: u8,

    /// Target MTU size (including UDP header)
    ///
    /// This controls how much zero-padding is written during serialization.
    mtuSize: u16,

    /// Create a new ConnectionRequest1 packet
    pub fn init(protocol: u8, mtuSize: u16) ConnectionRequest1 {
        return .{
            .protocol = protocol,
            .mtuSize = mtuSize,
        };
    }

    /// Serialize the packet into a byte buffer.
    ///
    /// Layout:
    /// [PacketID]
    /// [Magic]
    /// [Protocol]
    /// [Zero padding up to MTU - UDP_HEADER_SIZE]
    ///
    /// The server determines the MTU by observing the total UDP payload size.
    pub fn serialize(self: *ConnectionRequest1, writer: *Writer) ![]const u8 {
        try writer.writeU8(@intFromEnum(PacketID.OpenConnectionRequest1));

        try Magic.write(writer);

        try writer.writeU8(self.protocol);

        const padding =
            self.mtuSize - writer.pos - Constants.UDP_HEADER_SIZE;

        std.mem.set(
            u8,
            writer.buf[writer.pos .. writer.pos + padding],
            0,
        );
        writer.pos += padding;

        return writer.buf[0..writer.pos];
    }

    /// Deserialize an OpenConnectionRequest1 packet.
    ///
    /// Notes:
    /// - MTU is inferred from remaining packet length
    /// - Magic bytes are validated
    /// - UDP header size is accounted for implicitly by packet size
    pub fn deserialize(data: []const u8) !ConnectionRequest1 {
        var reader = Reader.init(data);

        _ = try reader.readU8();

        try Magic.read(&reader);

        const protocol = try reader.readU8();

        var mtuSize: u16 = @intCast(data.len - reader.pos);

        if (mtuSize > Constants.MAX_MTU_SIZE)
            mtuSize = Constants.MAX_MTU_SIZE;

        return .{
            .protocol = protocol,
            .mtuSize = mtuSize,
        };
    }
};
