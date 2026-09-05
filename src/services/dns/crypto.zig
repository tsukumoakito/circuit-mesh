const std = @import("std");

const types = @import("types.zig");

pub const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
});

pub fn sslReadFull(ssl: *c.SSL, buf: []u8) !void {
    var received: usize = 0;
    while (received < buf.len) {
        const n = c.SSL_read(ssl, buf.ptr + received, @intCast(buf.len - received));
        if (n <= 0) return error.TlsReadFailed;
        received += @intCast(n);
    }
}

pub fn nativeReadFull(client: *std.crypto.tls.Client, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const n = try client.reader.readSliceShort(buffer[offset..]);
        if (n == 0) {
            try client.reader.fillMore();
            continue;
        }
        offset += n;
    }
}
