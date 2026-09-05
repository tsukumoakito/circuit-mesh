const std = @import("std");
const net = std.net;
const posix = std.posix;

pub fn connectViaTor(allocator: std.mem.Allocator, socks_ip: []const u8, socks_port: u16, t_ip: []const u8, t_port: u16, user: *const [64]u8, pass: *const [64]u8) !net.Stream {
    const stream = try net.tcpConnectToHost(allocator, socks_ip, socks_port);
    errdefer stream.close();

    const timeout = posix.timeval{ .sec = 10, .usec = 0 };
    try posix.setsockopt(stream.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(timeout));
    try posix.setsockopt(stream.handle, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &std.mem.toBytes(timeout));
    try posix.setsockopt(stream.handle, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(i32, 1)));

    try stream.writeAll(&[_]u8{ 0x05, 0x02, 0x00, 0x02 });
    var mb: [2]u8 = undefined;
    try readFull(stream, &mb);
    if (mb[1] == 0x02) {
        var ap: [131]u8 = undefined;
        ap[0] = 0x01;
        ap[1] = 64;
        @memcpy(ap[2..66], user);
        ap[66] = 64;
        @memcpy(ap[67..131], pass);
        try stream.writeAll(&ap);
        var ar: [2]u8 = undefined;
        try readFull(stream, &ar);
        if (ar[1] != 0x00) return error.SocksAuthFailed;
    }
    var cr_buf: [262]u8 = undefined;
    cr_buf[0] = 0x05;
    cr_buf[1] = 0x01;
    cr_buf[2] = 0x00;
    cr_buf[3] = 0x03;

    const addr_len = @as(u8, @intCast(t_ip.len));
    cr_buf[4] = addr_len;

    @memcpy(cr_buf[5 .. 5 + t_ip.len], t_ip);

    std.mem.writeInt(u16, cr_buf[5 + t_ip.len ..][0..2], t_port, .big);

    try stream.writeAll(cr_buf[0 .. 7 + t_ip.len]);

    var rs: [10]u8 = undefined;
    try readFull(stream, &rs);
    if (rs[1] != 0x00) return error.SocksConnectFailed;
    return stream;
}

pub fn readFull(stream: net.Stream, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const bytes = try stream.read(buffer[offset..]);
        if (bytes == 0) return error.ConnectionClosed;
        offset += bytes;
    }
}
