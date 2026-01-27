const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Reader = BinaryUtils.BinaryReader;
const Writer = BinaryUtils.BinaryWriter;

const PacketID = @import("../packet.zig").PacketID;
const Frame = @import("../frame.zig").Frame;

/// A set of frames that share a common sequence number.
///
/// Used to send multiple `Frame`s together in a single packet.
/// Typically used in reliable and/or ordered transmissions.
///
/// Fields:
/// - sequenceNumber: Sequence number of this frame set (used for ordering/reliability)
/// - frames: Slice of `Frame` objects contained in this set
///
/// ⚠️ Memory Ownership Notes:
/// - Each `Frame` in `frames` may own its own payload (if `shouldFree` is true).
/// - Failing to call `deinit()` on the FrameSet will leak frame payloads and
///   the frame slice itself if allocated with `deserialize()`.
/// - Always call `deinit()` with the same allocator used for allocation.
pub const FrameSet = struct {
    sequenceNumber: u24,
    frames: []const Frame,

    /// Initialize a new FrameSet with a sequence number and frame slice.
    pub fn init(sequenceNumber: u24, frames: []const Frame) FrameSet {
        return .{
            .sequenceNumber = sequenceNumber,
            .frames = frames,
        };
    }

    /// Deinitialize the FrameSet and free any allocated frame payloads.
    ///
    /// allocator: Allocator used to free frame payload memory.
    pub fn deinit(self: *FrameSet, allocator: std.mem.Allocator) void {
        var i: usize = 0;
        while (i < self.frames.len) : (i += 1) {
            const fptr: *Frame = @constCast(&self.frames[i]);
            fptr.deinit(allocator);
        }
        if (self.frames.len != 0) allocator.free(self.frames);
    }

    /// Serialize the FrameSet into the writer.
    ///
    /// Format:
    /// - Packet ID (1 byte)
    /// - Sequence number (3 bytes)
    /// - Serialized frames in order
    pub fn serialize(self: *FrameSet, writer: *Writer) ![]u8 {
        try writer.writeU8(@intFromEnum(PacketID.FrameSet));
        try writer.writeU24LE(self.sequenceNumber);

        for (self.frames) |frame| {
            try frame.write(writer);
        }

        return writer.buf[0..writer.pos];
    }

    /// Deserialize a FrameSet from a buffer.
    ///
    /// allocator: Allocator used to allocate memory for the frames.
    /// Returns a FrameSet with frames allocated on the provided allocator.
    ///
    /// ⚠️ Make sure to call `deinit()` on the returned FrameSet to free memory.
    pub fn deserialize(buffer: []const u8, allocator: std.mem.Allocator) !FrameSet {
        var reader = Reader.init(buffer);

        _ = try reader.readU8();
        const sequenceNumber = try reader.readU24LE();

        var frames = try std.ArrayList(Frame).initCapacity(allocator, 5);

        while (reader.pos < reader.buf.len) {
            const frame = try Frame.read(&reader);
            try frames.append(allocator, frame);
        }

        const out_len = frames.items.len;
        if (out_len == 0) {
            frames.deinit(allocator);
            return .{
                .sequenceNumber = sequenceNumber,
                .frames = &[_]Frame{},
            };
        }

        var out_buf = try allocator.alloc(Frame, out_len);
        var idx: usize = 0;
        while (idx < out_len) : (idx += 1) {
            out_buf[idx] = frames.items[idx];
        }
        frames.deinit(allocator);

        return .{
            .sequenceNumber = sequenceNumber,
            .frames = out_buf[0..out_len],
        };
    }
};
