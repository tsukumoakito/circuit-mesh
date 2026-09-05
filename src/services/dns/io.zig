const std = @import("std");
const net = std.net;

pub const DirectReader = struct {
    reader: std.Io.Reader,
    stream: net.Stream,
    pub const vtable = std.Io.Reader.VTable{ .stream = streamFn, .rebase = rebaseFn };

    fn rebaseFn(r: *std.Io.Reader, capacity: usize) std.Io.Reader.RebaseError!void {
        _ = capacity;
        std.mem.copyForwards(u8, r.buffer, r.buffer[r.seek..r.end]);
        r.end -= r.seek;
        r.seek = 0;
    }

    fn streamFn(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *DirectReader = @alignCast(@fieldParentPtr("reader", r));
        var buf: [16384]u8 = undefined;
        const n = self.stream.read(limit.slice(&buf)) catch return error.ReadFailed;
        if (n > 0) return w.write(buf[0..n]) catch error.WriteFailed;
        return error.EndOfStream;
    }
};

pub const DirectWriter = struct {
    writer: std.Io.Writer,
    stream: net.Stream,
    pub const vtable = std.Io.Writer.VTable{ .drain = drainFn, .flush = flushFn, .rebase = rebaseFn };

    fn flushFn(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *DirectWriter = @alignCast(@fieldParentPtr("writer", w));
        const buffered = w.buffer[0..w.end];
        if (buffered.len > 0) {
            self.stream.writeAll(buffered) catch return error.WriteFailed;
            w.end = 0;
        }
    }

    fn rebaseFn(w: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
        _ = preserve;
        _ = capacity;
        try flushFn(w);
    }

    fn drainFn(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *DirectWriter = @alignCast(@fieldParentPtr("writer", w));
        try flushFn(w);
        var total: usize = 0;
        for (data) |slice| {
            if (slice.len == 0) continue;
            self.stream.writeAll(slice) catch return error.WriteFailed;
            total += slice.len;
        }
        _ = splat;
        return total;
    }
};
