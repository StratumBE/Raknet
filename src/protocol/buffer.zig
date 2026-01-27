const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Writer = BinaryUtils.BinaryWriter;
const Constants = @import("constants.zig");

/// A reusable packet buffer for serializing network packets.
///
/// Designed to hold a single packet at a time. The buffer can be
/// reset and reused to avoid repeated allocations, which is ideal
/// for high-performance, single-threaded packet processing.
///
/// Fields:
/// - `buffer`: The raw byte buffer used to store packet data.
///   Its size is `Constants.MAX_MTU_SIZE`, enough to hold the
///   maximum transmission unit of a single packet.
/// - `writer`: A `Writer` instance tied to `buffer` for serializing
///   packet data directly into it.
///
/// Methods:
/// - `init()`: Creates a new `PacketBuffer` with an initialized writer
///   pointing to its internal buffer. Optionally clears the buffer.
/// - `reset(shouldClear: bool)`: Resets the writer to point to the start
///   of the buffer. If `shouldClear` is true, sets all bytes in the buffer
///   to zero, clearing previous packet data.
pub const PacketBuffer = struct {
    buffer: [Constants.MAX_MTU_SIZE]u8,
    writer: Writer,

    /// Initializes a new PacketBuffer with its internal writer.
    /// The buffer is optionally cleared via `reset()`.
    pub fn init() PacketBuffer {
        var buf = PacketBuffer{
            .buffer = undefined,
            .writer = Writer.init(&[_]u8{}),
        };
        buf.reset(true);
        return buf;
    }

    /// Resets the writer to point to the buffer start.
    ///
    /// Parameters:
    /// - `shouldClear`: If true, the buffer is zeroed to remove
    ///   any leftover data from previous packets.
    pub fn reset(self: *PacketBuffer, shouldClear: bool) void {
        if (shouldClear) {
            @memset(self.buffer[0..], 0);
        }
        self.writer = Writer.init(self.buffer[0..]);
    }
};
