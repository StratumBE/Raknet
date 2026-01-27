const std = @import("std");

const BinaryUtils = @import("BinaryUtils");
const Reader = BinaryUtils.BinaryReader;
const Writer = BinaryUtils.BinaryWriter;

const PacketID = @import("../packet.zig").PacketID;

const RECORD_RANGE: u8 = 0;
const RECORD_SINGLE: u8 = 1;

/// ACK packet
/// NOTE:
/// - sequences MUST be sorted
/// - sequences MUST be unique
pub const Ack = struct {
    sequences: []u24,

    /// Deserialize into a caller-provided buffer.
    /// Errors if the buffer is too small.
    pub fn deserializeInto(
        data: []const u8,
        out: []u24,
    ) !Ack {
        var reader = Reader.init(data);

        _ = try reader.readU8();
        const recordCount = try reader.readU16BE();

        var outIdx: usize = 0;
        var recordsRead: u16 = 0;

        while (recordsRead < recordCount) : (recordsRead += 1) {
            const recordType = try reader.readU8();

            switch (recordType) {
                RECORD_SINGLE => {
                    if (outIdx >= out.len)
                        return error.OutBufferTooSmall;

                    out[outIdx] = try reader.readU24LE();
                    outIdx += 1;
                },
                RECORD_RANGE => {
                    const start = try reader.readU24LE();
                    const end = try reader.readU24LE();

                    if (end < start)
                        return error.InvalidRange;

                    var cur: u32 = start;
                    while (cur <= end) : (cur += 1) {
                        if (outIdx >= out.len)
                            return error.OutBufferTooSmall;

                        out[outIdx] = @intCast(cur);
                        outIdx += 1;
                    }
                },
                else => return error.InvalidRecordType,
            }
        }

        return .{ .sequences = out[0..outIdx] };
    }

    /// Deserialize and allocate sequence buffer
    pub fn deserializeAlloc(
        data: []const u8,
        allocator: std.mem.Allocator,
    ) !Ack {
        var reader = Reader.init(data);

        _ = try reader.readU8();
        const recordCount = try reader.readU16BE();

        var countReader = Reader.init(data[3..]);
        var total: usize = 0;

        var recordsRead: u16 = 0;
        while (recordsRead < recordCount) : (recordsRead += 1) {
            const recordType = try countReader.readU8();

            switch (recordType) {
                RECORD_SINGLE => {
                    _ = try countReader.readU24LE();
                    total += 1;
                },
                RECORD_RANGE => {
                    const start = try countReader.readU24LE();
                    const end = try countReader.readU24LE();

                    if (end < start)
                        return error.InvalidRange;

                    total += @as(usize, end - start) + 1;
                },
                else => return error.InvalidRecordType,
            }

            if (total > 1_000_000)
                return error.TooManySequences;
        }

        if (total == 0)
            return .{ .sequences = &[_]u24{} };

        const buf = try allocator.alloc(u24, total);

        var fillReader = Reader.init(data[3..]);
        var outIdx: usize = 0;

        recordsRead = 0;
        while (recordsRead < recordCount) : (recordsRead += 1) {
            const recordType = try fillReader.readU8();

            switch (recordType) {
                RECORD_SINGLE => {
                    buf[outIdx] = try fillReader.readU24LE();
                    outIdx += 1;
                },
                RECORD_RANGE => {
                    const start = try fillReader.readU24LE();
                    const end = try fillReader.readU24LE();

                    var cur: u32 = start;
                    while (cur <= end) : (cur += 1) {
                        buf[outIdx] = @intCast(cur);
                        outIdx += 1;
                    }
                },
                else => unreachable,
            }
        }

        return .{ .sequences = buf };
    }

    /// Free sequences allocated by deserializeAlloc
    pub fn deinitAlloc(self: *Ack, allocator: std.mem.Allocator) void {
        allocator.free(self.sequences);
    }

    /// Serialize ACK into writer.
    /// sequences MUST be sorted and strictly increasing.
    pub fn serialize(self: Ack, writer: *Writer) ![]const u8 {
        try writer.writeU8(@intFromEnum(PacketID.ACK));

        if (self.sequences.len == 0) {
            try writer.writeU16BE(0);
            return writer.buf[0..writer.pos];
        }

        const recordCountPos = writer.pos;
        try writer.writeU16BE(0); // patched later

        var records: u16 = 0;

        var start = self.sequences[0];
        var last = start;

        var i: usize = 1;
        while (i < self.sequences.len) : (i += 1) {
            const cur = self.sequences[i];

            // std.debug.assert(cur > last);

            if (cur == last + 1) {
                last = cur;
                continue;
            }

            try writeRecord(writer, start, last);
            records += 1;

            start = cur;
            last = cur;
        }

        try writeRecord(writer, start, last);
        records += 1;

        const endPos = writer.pos;
        writer.pos = recordCountPos;
        try writer.writeU16BE(records);
        writer.pos = endPos;

        return writer.buf[0..endPos];
    }

    fn writeRecord(writer: *Writer, start: u24, end: u24) !void {
        if (start == end) {
            try writer.writeU8(RECORD_SINGLE);
            try writer.writeU24LE(start);
        } else {
            try writer.writeU8(RECORD_RANGE);
            try writer.writeU24LE(start);
            try writer.writeU24LE(end);
        }
    }
};
