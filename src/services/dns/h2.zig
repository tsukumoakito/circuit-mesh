const std = @import("std");

const Config = @import("../../config.zig").Config;
const crypto_mod = @import("crypto.zig");
const c = crypto_mod.c;

pub fn performHttp2Exchange(ssl: *c.SSL, tunnel: Config.DnsTunnel, query: []u8, aa: std.mem.Allocator) ![]u8 {
    const orig_id_0 = query[0];
    const orig_id_1 = query[1];
    query[0] = 0;
    query[1] = 0;

    _ = c.SSL_write(ssl, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", 24);
    _ = c.SSL_write(ssl, &[_]u8{ 0, 0, 0, 4, 0, 0, 0, 0, 0 }, 9);

    var h_buf = std.ArrayListUnmanaged(u8){};
    const hw = h_buf.writer(aa);
    try hw.writeAll("\x83\x87\x41");
    try hw.writeByte(@intCast(tunnel.sni.len));
    try hw.writeAll(tunnel.sni);

    const path = if (tunnel.doh_path.len > 0) tunnel.doh_path else "/dns-query";
    try hw.writeAll("\x44");
    try hw.writeByte(@intCast(path.len));
    try hw.writeAll(path);

    try hw.writeAll("\x00\x06accept\x17application/dns-message\x00\x0ccontent-type\x17application/dns-message");
    const clen_s = try std.fmt.allocPrint(aa, "{d}", .{query.len});
    try hw.writeAll("\x00\x0econtent-length");
    try hw.writeByte(@intCast(clen_s.len));
    try hw.writeAll(clen_s);

    var h_frame: [9]u8 = undefined;
    std.mem.writeInt(u24, h_frame[0..3], @intCast(h_buf.items.len), .big);
    h_frame[3] = 0x01;
    h_frame[4] = 0x04;
    std.mem.writeInt(u32, h_frame[5..9], 1, .big);
    _ = c.SSL_write(ssl, &h_frame, 9);
    _ = c.SSL_write(ssl, h_buf.items.ptr, @intCast(h_buf.items.len));

    var d_frame: [9]u8 = undefined;
    std.mem.writeInt(u24, d_frame[0..3], @intCast(query.len), .big);
    d_frame[3] = 0x00;
    d_frame[4] = 0x01;
    std.mem.writeInt(u32, d_frame[5..9], 1, .big);
    _ = c.SSL_write(ssl, &d_frame, 9);
    _ = c.SSL_write(ssl, query.ptr, @intCast(query.len));

    var resp_payload = std.ArrayListUnmanaged(u8){};
    var settings_acked = false;
    var stream_ended = false;

    while (!stream_ended) {
        var fh: [9]u8 = undefined;
        try crypto_mod.sslReadFull(ssl, &fh);
        const flen = (@as(u32, fh[0]) << 16) | (@as(u32, fh[1]) << 8) | fh[2];
        const ftype = fh[3];
        const fflags = fh[4];
        const fsid = std.mem.readInt(u32, fh[5..9], .big);
        const p = try aa.alloc(u8, flen);
        try crypto_mod.sslReadFull(ssl, p);
        if (ftype == 0x00) {
            if (fsid == 1) try resp_payload.appendSlice(aa, p);
            if ((fflags & 0x01) != 0) stream_ended = true;
        } else if (ftype == 0x01) {
            if (fsid == 1 and (fflags & 0x01) != 0) stream_ended = true;
        } else if (ftype == 0x04) {
            if (!settings_acked and (fflags & 0x01) == 0) {
                _ = c.SSL_write(ssl, &[_]u8{ 0, 0, 0, 4, 1, 0, 0, 0, 0 }, 9);
                settings_acked = true;
            }
        } else if (ftype == 0x07) return error.Http2GoAway;
    }

    if (resp_payload.items.len >= 12) {
        resp_payload.items[0] = orig_id_0;
        resp_payload.items[1] = orig_id_1;
    }
    return resp_payload.items;
}
