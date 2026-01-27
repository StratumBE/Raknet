const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Reader = BinaryUtils.BinaryReader;
const Writer = BinaryUtils.BinaryWriter;

const Reliability = @import("reliability.zig").Reliability;
const Flags = @import("reliability.zig").Flags;

/// RakNet Frame
///
/// A Frame represents a single RakNet payload unit inside a Datagram.
/// Depending on its reliability mode, it may include sequence numbers,
/// ordering information, and/or split metadata.
///
/// Field presence is dictated by `reliability`.
pub const Frame = struct {
    /// Application payload carried by this frame
    payload: []const u8,

    /// Optional split metadata, present when the Split flag is set
    splitInfo: ?SplitInfo,

    /// Reliable frame index (24-bit), present for reliable frames
    reliableFrameIndex: ?u24,

    /// Sequence index (24-bit), present for sequenced frames
    sequenceFrameIndex: ?u24,

    /// Ordered frame index (24-bit), present for ordered frames
    orderedFrameIndex: ?u24,

    /// Ordering channel, only valid when ordered
    orderChannel: ?u8,

    /// Reliability mode of this frame
    reliability: Reliability,

    /// Whether `payload` is owned by this frame and should be freed
    shouldFree: bool = false,

    /// Metadata for split frames
    ///
    /// Used when a payload is too large to fit in a single frame
    pub const SplitInfo = struct {
        /// Split packet identifier
        id: u16,

        /// Total number of frames in this split
        size: u32,

        /// Index of this frame within the split
        frameIndex: u32,
    };

    /// Construct a Frame
    ///
    /// NOTE:
    /// - Index fields must match the selected reliability mode
    /// - `payload` ownership is controlled by `shouldFree`
    pub fn init(
        reliability: Reliability,
        payload: []const u8,
        orderChannel: ?u8,
        reliableFrameIndex: ?u24,
        sequenceFrameIndex: ?u24,
        orderedFrameIndex: ?u24,
        splitInfo: ?SplitInfo,
        shouldFree: bool,
    ) Frame {
        return .{
            .reliability = reliability,
            .payload = payload,
            .orderChannel = orderChannel,
            .reliableFrameIndex = reliableFrameIndex,
            .sequenceFrameIndex = sequenceFrameIndex,
            .orderedFrameIndex = orderedFrameIndex,
            .splitInfo = splitInfo,
            .shouldFree = shouldFree,
        };
    }

    /// Free the payload if this frame owns it
    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        if (self.shouldFree) {
            allocator.free(self.payload);
            // Prevent double frees
            self.shouldFree = false;
        }
    }

    /// Returns true if this frame is marked as split
    pub fn isSplit(self: *const Frame) bool {
        return self.splitInfo != null;
    }

    /// Calculate the serialized size of this frame in bytes
    ///
    /// Base fields:
    /// - 1 byte flags
    /// - 2 bytes payload length (in bits)
    /// - payload bytes
    ///
    /// Optional fields are added depending on reliability and split status.
    pub fn getLength(self: *const Frame) usize {
        var len: usize = 3 + self.payload.len;

        if (self.reliability.isReliable()) len += 3;
        if (self.reliability.isSequenced()) len += 3;
        if (self.reliability.isOrdered()) len += 4;
        if (self.isSplit()) len += 10;

        return len;
    }

    /// Deserialize a Frame from the reader
    ///
    /// Format:
    /// - Flags byte (reliability + split flag)
    /// - Payload length (in bits)
    /// - Optional indices based on reliability
    /// - Optional split metadata
    /// - Payload bytes
    pub fn read(reader: *Reader) !Frame {
        const rawFlags = try reader.readU8();

        const reliability: Reliability =
            @as(Reliability, @enumFromInt((rawFlags & 0b1110_0000) >> 5));

        const isFrameSplit = (rawFlags & 0x10) != 0;

        const lengthBits = try reader.readU16BE();
        const payloadLength = (lengthBits + 7) / 8;

        if (payloadLength == 0) {
            return error.InvalidFrameLength;
        }

        var orderChannel: ?u8 = null;
        var reliableFrameIndex: ?u24 = null;
        var sequenceFrameIndex: ?u24 = null;
        var orderedFrameIndex: ?u24 = null;
        var splitInfo: ?Frame.SplitInfo = null;

        if (reliability.isReliable()) {
            reliableFrameIndex = try reader.readU24LE();
        }
        if (reliability.isSequenced()) {
            sequenceFrameIndex = try reader.readU24LE();
        }
        if (reliability.isOrdered()) {
            orderedFrameIndex = try reader.readU24LE();
            orderChannel = try reader.readU8();
        }

        if (isFrameSplit) {
            splitInfo = Frame.SplitInfo{
                .size = try reader.readU32BE(),
                .id = try reader.readU16BE(),
                .frameIndex = try reader.readU32BE(),
            };
        }

        const remaining = reader.buf.len - reader.pos;
        const toRead = @min(payloadLength, remaining);

        const payload = try reader.read(toRead);

        return Frame.init(
            reliability,
            payload,
            orderChannel,
            reliableFrameIndex,
            sequenceFrameIndex,
            orderedFrameIndex,
            splitInfo,
            false,
        );
    }

    /// Build the frame flags byte
    ///
    /// Layout:
    /// - bits 7..5: reliability
    /// - bit 4: split flag
    fn buildFlags(self: *const Frame) u8 {
        var flags: u8 = @as(u8, @intFromEnum(self.reliability)) << 5;
        if (self.isSplit()) flags |= @intFromEnum(Flags.Split);
        return flags;
    }

    /// Serialize the frame into the writer
    ///
    /// Errors if required indices are missing for the selected reliability mode.
    pub fn write(self: *const Frame, writer: *Writer) !void {
        const lengthBits: u16 =
            @as(u16, @intCast(self.payload.len)) * 8;

        try writer.writeU8(self.buildFlags());
        try writer.writeU16BE(lengthBits);

        if (self.reliability.isReliable()) {
            if (self.reliableFrameIndex == null)
                return error.MissingReliableIndex;
            try writer.writeU24LE(self.reliableFrameIndex.?);
        }
        if (self.reliability.isSequenced()) {
            if (self.sequenceFrameIndex == null)
                return error.MissingSequenceIndex;
            try writer.writeU24LE(self.sequenceFrameIndex.?);
        }
        if (self.reliability.isOrdered()) {
            if (self.orderedFrameIndex == null)
                return error.MissingOrderedIndex;
            if (self.orderChannel == null)
                return error.MissingOrderChannel;

            try writer.writeU24LE(self.orderedFrameIndex.?);
            try writer.writeU8(self.orderChannel.?);
        }
        if (self.isSplit()) {
            const split = self.splitInfo.?;
            try writer.writeU32BE(split.size);
            try writer.writeU16BE(split.id);
            try writer.writeU32BE(split.frameIndex);
        }

        try writer.write(self.payload);
    }
};
