const std = @import("std");
const net = std.net;
const posix = std.posix;
const crypto = std.crypto;

const Config = @import("../config.zig").Config;
const TorSource = @import("../sources/tor.zig").TorSource;
const connection = @import("dns/connection.zig");
const crypto_mod = @import("dns/crypto.zig");
const c = crypto_mod.c;
const h2 = @import("dns/h2.zig");
const dns_io = @import("dns/io.zig");
const reporting = @import("dns/reporting.zig");
const types = @import("dns/types.zig");
const workers = @import("dns/workers.zig");

pub const DnsTunnelManager = struct {
    allocator: std.mem.Allocator,
    config: []Config.DnsTunnel,
    global_cfg: Config.GlobalSettings,
    profiles: []Config.RotationProfile,
    tor_cfg: Config.TorGlobalConfig,
    tor_source: *TorSource,
    is_tor_online: *const bool,
    debug: bool,
    stats: []types.TunnelStatus,
    ca_bundle: std.crypto.Certificate.Bundle,
    queues: []types.QueryQueue,
    udp_listeners: []posix.socket_t,
    ready_flags: []bool,
    ssl_ctx: ?*c.SSL_CTX = null,
    doh_fallback_allowed: bool,
    fallback_logged: std.atomic.Value(bool),

    rotating_count: std.atomic.Value(u32),

    pub fn init(allocator: std.mem.Allocator, cfg: *const Config, tor_source: *TorSource, status_ptr: *const bool, debug: bool) *DnsTunnelManager {
        _ = c.OPENSSL_init_ssl(0, null);
        const ssl_ctx = c.SSL_CTX_new(c.TLS_client_method());
        if (ssl_ctx) |ctx| {
            _ = c.SSL_CTX_set_default_verify_paths(ctx);
            _ = c.SSL_CTX_set_alpn_protos(ctx, "\x02h2", 3);
            _ = c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_2_VERSION);
            c.SSL_CTX_set_verify(ctx, c.SSL_VERIFY_PEER, null);
        }

        const self = allocator.create(DnsTunnelManager) catch unreachable;
        const stats = allocator.alloc(types.TunnelStatus, cfg.dns_tunnels.len) catch unreachable;
        const queues = allocator.alloc(types.QueryQueue, cfg.dns_tunnels.len) catch unreachable;
        const listeners = allocator.alloc(posix.socket_t, cfg.dns_tunnels.len) catch unreachable;
        const ready = allocator.alloc(bool, cfg.dns_tunnels.len) catch unreachable;
        @memset(ready, false);

        var bundle: std.crypto.Certificate.Bundle = .{};
        bundle.rescan(allocator) catch {};

        const now = std.time.timestamp();
        for (0..cfg.dns_tunnels.len) |i| {
            queues[i] = .{};
            const jitter = @as(i64, @intCast(crypto.random.uintAtMost(u32, 600)));

            stats[i] = .{};
            stats[i].last_success_ts.store(now, .monotonic);
            stats[i].next_rotation_ts.store(now + jitter, .monotonic);
            @memcpy(stats[i].last_route[0..4], "none");

            var u_bin: [32]u8 = undefined;
            var p_bin: [32]u8 = undefined;
            crypto.random.bytes(&u_bin);
            crypto.random.bytes(&p_bin);
            @memcpy(stats[i].socks_user[0..64], &std.fmt.bytesToHex(u_bin, .lower));
            @memcpy(stats[i].socks_pass[0..64], &std.fmt.bytesToHex(p_bin, .lower));
        }

        self.* = .{
            .allocator = allocator,
            .config = cfg.dns_tunnels,
            .global_cfg = cfg.global_settings,
            .profiles = cfg.rotation_profiles,
            .tor_cfg = tor_source.config,
            .tor_source = tor_source,
            .is_tor_online = status_ptr,
            .debug = debug,
            .stats = stats,
            .ca_bundle = bundle,
            .queues = queues,
            .udp_listeners = listeners,
            .ready_flags = ready,
            .ssl_ctx = ssl_ctx,
            .doh_fallback_allowed = cfg.doh_fallback_allowed,
            .fallback_logged = std.atomic.Value(bool).init(false),
            .rotating_count = std.atomic.Value(u32).init(0),
        };
        return self;
    }

    pub fn spawnAll(self: *DnsTunnelManager) !void {
        for (self.config, 0..) |_, i| {
            try self.spawnTunnel(i);
        }
        _ = try std.Thread.spawn(.{}, centralScheduler, .{self});
    }

    pub fn spawnTunnel(self: *DnsTunnelManager, idx: usize) !void {
        const tunnel = self.config[idx];
        _ = try std.Thread.spawn(.{}, workers.udpTunnelRunner, .{ self, tunnel, idx });
        _ = try std.Thread.spawn(.{}, workers.tcpTunnelRunner, .{ self, tunnel, idx });
    }

    fn centralScheduler(self: *DnsTunnelManager) void {
        const interval_ns = @as(u64, @intCast(self.global_cfg.rotation_check_interval_s)) * std.time.ns_per_s;

        while (true) {
            std.Thread.sleep(interval_ns);
            const now = std.time.timestamp();

            if (!self.is_tor_online.*) continue;

            for (self.config, 0..) |tunnel, i| {
                const s = &self.stats[i];

                if (!self.ready_flags[i]) {
                    if (self.debug) std.debug.print("♻️  [{s}] Listener dead. Respawning workers...\n", .{tunnel.name});
                    self.spawnTunnel(i) catch {};
                    continue;
                }
                const current_ip = std.mem.sliceTo(&s.current_exit_ip, 0);
                const is_colliding = if (current_ip.len > 0) self.isIpColliding(current_ip, i) else false;

                const is_silent = (now - s.last_success_ts.load(.monotonic) >= 120);
                const is_expired = (now >= s.next_rotation_ts.load(.monotonic));

                if (is_colliding or is_silent or is_expired) {
                    if (now - s.last_activity_ts.load(.monotonic) < 15) {
                        if (self.debug) std.debug.print("⏳ [{s}] Active traffic detected. Snoozing rotation...\n", .{tunnel.name});
                        continue;
                    }

                    if (self.debug and is_colliding) {
                        std.debug.print("⚠️ [{s}] Initial or active collision detected ({s}). Rotating...\n", .{ tunnel.name, current_ip });
                    }

                    self.rotateIdentitySeamlessly(tunnel, i) catch |err| {
                        if (err == error.Throttled) continue;
                        if (self.debug) std.debug.print("⚠️ [{s}] Scheduler: Rotation failed: {any}\n", .{ tunnel.name, err });
                    };

                    s.next_rotation_ts.store(self.calculateNextRotation("dns"), .monotonic);
                }
            }
        }
    }

    const ConnContext = struct {
        tls_client: ?std.crypto.tls.Client = null,
        dr: ?dns_io.DirectReader = null,
        dw: ?dns_io.DirectWriter = null,
        rb: ?[]u8 = null,
        wb: ?[]u8 = null,
        tls_rb: ?[]u8 = null,
        tls_wb: ?[]u8 = null,
        ssl: ?*c.SSL = null,
        stream: net.Stream,
        was_tor_online: bool,
        is_doh: bool,
    };

    pub fn connect(self: *DnsTunnelManager, tunnel: Config.DnsTunnel, idx: usize, use_tor: bool, opt_user: ?*const [64]u8, opt_pass: ?*const [64]u8) !*ConnContext {
        const is_doh = !use_tor;
        const user = if (opt_user) |u| u else &self.stats[idx].socks_user;
        const pass = if (opt_pass) |p| p else &self.stats[idx].socks_pass;

        if (is_doh and !self.doh_fallback_allowed) return error.DohFallbackBlocked;
        if (use_tor) self.fallback_logged.store(false, .seq_cst);

        const port: u16 = if (is_doh) 443 else 853;
        const stream = if (use_tor)
            try connection.connectViaTor(self.allocator, self.tor_cfg.socks_ip, self.tor_cfg.socks_port, tunnel.ip, 853, user, pass)
        else
            try net.tcpConnectToHost(self.allocator, tunnel.ip, port);

        const ctx = try self.allocator.create(ConnContext);
        ctx.* = .{ .stream = stream, .was_tor_online = use_tor, .is_doh = is_doh };
        errdefer self.destroyConn(ctx);

        if (is_doh) {
            const ssl = c.SSL_new(self.ssl_ctx.?) orelse return error.OpenSslNewFailed;
            ctx.ssl = ssl;
            const bio = c.BIO_new_socket(@intCast(stream.handle), c.BIO_NOCLOSE) orelse return error.BioNewFailed;
            c.SSL_set_bio(ssl, bio, bio);
            const sni_z = try self.allocator.dupeZ(u8, tunnel.sni);
            defer self.allocator.free(sni_z);
            _ = c.SSL_set_tlsext_host_name(ssl, sni_z.ptr);
            if (c.SSL_connect(ssl) != 1) return error.TlsHandshakeFailed;
        } else {
            const min_len = std.crypto.tls.Client.min_buffer_len;
            ctx.rb = try self.allocator.alloc(u8, min_len * 2);
            ctx.wb = try self.allocator.alloc(u8, min_len * 2);
            ctx.tls_rb = try self.allocator.alloc(u8, min_len);
            ctx.tls_wb = try self.allocator.alloc(u8, min_len);
            ctx.dr = .{ .reader = .{ .vtable = &dns_io.DirectReader.vtable, .buffer = ctx.rb.?, .seek = 0, .end = 0 }, .stream = stream };
            ctx.dw = .{ .writer = .{ .vtable = &dns_io.DirectWriter.vtable, .buffer = ctx.wb.?, .end = 0 }, .stream = stream };
            ctx.tls_client = try std.crypto.tls.Client.init(&ctx.dr.?.reader, &ctx.dw.?.writer, .{ .host = .{ .explicit = tunnel.sni }, .ca = .{ .bundle = self.ca_bundle }, .read_buffer = ctx.tls_rb.?, .write_buffer = ctx.tls_wb.? });
        }

        if (self.debug and !self.ready_flags[idx]) {
            std.debug.print("✨ [{s}] Established ({s}).\n", .{ tunnel.name, if (is_doh) "OpenSSL/h2" else "Zig/Native" });
            self.ready_flags[idx] = true;
        }

        const route_name = if (use_tor) "tor" else "direct";
        @memset(self.stats[idx].last_route[0..], 0);
        @memcpy(self.stats[idx].last_route[0..route_name.len], route_name);

        return ctx;
    }

    pub fn establishConn(self: *DnsTunnelManager, tunnel: Config.DnsTunnel, idx: usize) !*ConnContext {
        return self.connect(tunnel, idx, self.is_tor_online.*, null, null);
    }

    pub fn destroyConn(self: *DnsTunnelManager, ctx: *ConnContext) void {
        if (ctx.ssl) |s| {
            _ = c.SSL_shutdown(s);
            c.SSL_free(s);
        }
        posix.shutdown(ctx.stream.handle, .both) catch {};
        ctx.stream.close();
        if (ctx.rb) |b| self.allocator.free(b);
        if (ctx.wb) |b| self.allocator.free(b);
        if (ctx.tls_rb) |b| self.allocator.free(b);
        if (ctx.tls_wb) |b| self.allocator.free(b);
        self.allocator.destroy(ctx);
    }

    pub fn doExchange(self: *DnsTunnelManager, conn: *ConnContext, tunnel: Config.DnsTunnel, query: []u8, src_addr: posix.sockaddr.in, src_len: posix.socklen_t, idx: usize) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        if (conn.is_doh) {
            const resp = try h2.performHttp2Exchange(conn.ssl.?, tunnel, query, aa);
            if (resp.len >= 12) {
                _ = posix.system.sendto(self.udp_listeners[idx], resp.ptr, resp.len, 0, @ptrCast(&src_addr), src_len);
                _ = self.stats[idx].success_count_direct.fetchAdd(1, .monotonic);
                self.stats[idx].last_success_ts.store(std.time.timestamp(), .monotonic);
            }
        } else {
            const native = &conn.tls_client.?;
            var sb = try aa.alloc(u8, 2 + query.len);
            std.mem.writeInt(u16, sb[0..2], @intCast(query.len), .big);
            @memcpy(sb[2..], query);
            try native.writer.writeAll(sb);
            try native.writer.flush();
            try conn.dw.?.writer.flush();

            var lb: [2]u8 = undefined;
            try crypto_mod.nativeReadFull(native, &lb);
            const rl = std.mem.readInt(u16, &lb, .big);
            const rb = try aa.alloc(u8, rl);
            try crypto_mod.nativeReadFull(native, rb);
            _ = posix.system.sendto(self.udp_listeners[idx], rb.ptr, rb.len, 0, @ptrCast(&src_addr), src_len);
            _ = self.stats[idx].success_count_tor.fetchAdd(1, .monotonic);
            self.stats[idx].last_success_ts.store(std.time.timestamp(), .monotonic);
        }
    }

    pub fn processQuery(self: *DnsTunnelManager, client: net.Stream, tunnel: Config.DnsTunnel, idx: usize) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        var client_rb: [1024]u8 = undefined;
        var client_reader = client.reader(&client_rb);
        const cr_iface = client_reader.interface();
        while (true) {
            var len_buf: [2]u8 = undefined;
            cr_iface.readSliceAll(&len_buf) catch break;
            const len = std.mem.readInt(u16, &len_buf, .big);
            const buf = try aa.alloc(u8, len);
            try cr_iface.readSliceAll(buf);
            const conn = try self.establishConn(tunnel, idx);
            defer self.destroyConn(conn);
            if (conn.is_doh) {
                const resp = try h2.performHttp2Exchange(conn.ssl.?, tunnel, buf, aa);
                if (resp.len >= 12) {
                    var rlb: [2]u8 = undefined;
                    std.mem.writeInt(u16, &rlb, @intCast(resp.len), .big);
                    try client.writeAll(&rlb);
                    try client.writeAll(resp);
                    _ = self.stats[idx].success_count_direct.fetchAdd(1, .monotonic);
                    self.stats[idx].last_success_ts.store(std.time.timestamp(), .monotonic);
                }
            } else {
                try conn.tls_client.?.writer.writeAll(&len_buf);
                try conn.tls_client.?.writer.writeAll(buf);
                try conn.tls_client.?.writer.flush();
                try conn.dw.?.writer.flush();
                var rlb: [2]u8 = undefined;
                try crypto_mod.nativeReadFull(&conn.tls_client.?, &rlb);
                const r_len = std.mem.readInt(u16, &rlb, .big);
                const r_buf = try aa.alloc(u8, r_len);
                try crypto_mod.nativeReadFull(&conn.tls_client.?, r_buf);
                try client.writeAll(&rlb);
                try client.writeAll(r_buf);
                _ = self.stats[idx].success_count_tor.fetchAdd(1, .monotonic);
                self.stats[idx].last_success_ts.store(std.time.timestamp(), .monotonic);
            }
        }
    }

    pub fn rotateIdentitySeamlessly(self: *DnsTunnelManager, tunnel: Config.DnsTunnel, idx: usize) !void {
        if (self.rotating_count.load(.monotonic) >= self.global_cfg.max_concurrent_rotations) {
            return error.Throttled;
        }

        _ = self.rotating_count.fetchAdd(1, .monotonic);
        self.stats[idx].is_rotating.store(true, .monotonic);
        defer {
            _ = self.rotating_count.fetchSub(1, .monotonic);
            self.stats[idx].is_rotating.store(false, .monotonic);
        }

        var attempts: usize = 0;
        while (attempts < 2) : (attempts += 1) {
            var new_user: [64]u8 = undefined;
            var new_pass: [64]u8 = undefined;
            {
                var u_bin: [32]u8 = undefined;
                var p_bin: [32]u8 = undefined;
                crypto.random.bytes(&u_bin);
                crypto.random.bytes(&p_bin);
                @memcpy(&new_user, &std.fmt.bytesToHex(u_bin, .lower));
                @memcpy(&new_pass, &std.fmt.bytesToHex(p_bin, .lower));
            }

            const conn = self.connect(tunnel, idx, true, &new_user, &new_pass) catch continue;
            defer self.destroyConn(conn);

            if (!(try self.verifyConnWithProbe(conn, tunnel))) continue;

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const id_map = try self.tor_source.fetchTorIdentityMap(arena.allocator());

            if (id_map.get(&new_user)) |identity| {
                var it = std.mem.splitScalar(u8, identity, ' ');
                const new_ip = it.next() orelse "";
                if (self.isIpColliding(new_ip, idx)) continue;

                const old_user = try self.allocator.dupe(u8, self.stats[idx].socks_user[0..64]);
                {
                    self.stats[idx].mutex.lock();
                    defer self.stats[idx].mutex.unlock();
                    @memcpy(self.stats[idx].last_exit_ip[0..64], self.stats[idx].current_exit_ip[0..64]);
                    const copy_len = @min(new_ip.len, 63);
                    @memset(self.stats[idx].current_exit_ip[0..], 0);
                    @memcpy(self.stats[idx].current_exit_ip[0..copy_len], new_ip[0..copy_len]);
                    @memset(self.stats[idx].cached_identity[0..64], 0);
                    @memcpy(self.stats[idx].cached_identity[0..@min(identity.len, 63)], identity[0..@min(identity.len, 63)]);
                    @memcpy(self.stats[idx].socks_user[0..64], &new_user);
                    @memcpy(self.stats[idx].socks_pass[0..64], &new_pass);
                }

                const PurgeContext = struct {
                    mgr: *DnsTunnelManager,
                    id: []const u8,
                    fn run(ctx: *@This()) void {
                        std.Thread.sleep(15 * std.time.ns_per_s);
                        ctx.mgr.tor_source.requestCircuitPurge(ctx.id) catch {};
                        ctx.mgr.allocator.free(ctx.id);
                        ctx.mgr.allocator.destroy(ctx);
                    }
                };
                const p_ctx = try self.allocator.create(PurgeContext);
                p_ctx.* = .{ .mgr = self, .id = old_user };
                const thread = try std.Thread.spawn(.{}, PurgeContext.run, .{p_ctx});
                thread.detach();
                return;
            }
        }
        return error.RotationFailed;
    }

    pub fn calculateNextRotation(self: *DnsTunnelManager, profile_name: []const u8) i64 {
        for (self.profiles) |p| {
            if (std.mem.eql(u8, p.name, profile_name)) {
                const range = @as(u64, @intCast(p.max_ttl - p.min_ttl));
                const jitter = @as(i64, @intCast(crypto.random.uintAtMost(u64, range)));
                return std.time.timestamp() + p.min_ttl + jitter;
            }
        }
        return std.time.timestamp() + 300;
    }

    fn isIpColliding(self: *DnsTunnelManager, new_ip: []const u8, idx: usize) bool {
        if (new_ip.len == 0) return true;
        for (self.stats, 0..) |*s, i| {
            if (i == idx) continue;
            if (std.mem.eql(u8, std.mem.sliceTo(&s.current_exit_ip, 0), new_ip)) return true;
        }
        if (std.mem.eql(u8, std.mem.sliceTo(&self.stats[idx].last_exit_ip, 0), new_ip)) return true;
        return false;
    }

    fn verifyConnWithProbe(self: *DnsTunnelManager, conn: *ConnContext, tunnel: Config.DnsTunnel) !bool {
        var pkt: [64]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&pkt);
        const w = fbs.writer();
        try w.writeAll("\xab\xcd\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00");
        var it = std.mem.splitScalar(u8, tunnel.sni, '.');
        while (it.next()) |part| {
            try w.writeByte(@intCast(part.len));
            try w.writeAll(part);
        }
        try w.writeAll("\x00\x00\x01\x00\x01");
        const query = fbs.getWritten();

        const native = &conn.tls_client.?;
        var sb = try self.allocator.alloc(u8, 2 + query.len);
        defer self.allocator.free(sb);
        std.mem.writeInt(u16, sb[0..2], @intCast(query.len), .big);
        @memcpy(sb[2..], query);
        try native.writer.writeAll(sb);
        try native.writer.flush();
        try conn.dw.?.writer.flush();

        var lb: [2]u8 = undefined;
        try crypto_mod.nativeReadFull(native, &lb);
        const rl = std.mem.readInt(u16, &lb, .big);
        if (rl > 512) return false;
        const rb = try self.allocator.alloc(u8, rl);
        defer self.allocator.free(rb);
        try crypto_mod.nativeReadFull(native, rb);

        const success_id = (rb.len >= 12 and rb[0] == 0xab and rb[1] == 0xcd);
        const success_rcode = (rb[3] & 0x0F == 0);

        return success_id and success_rcode;
    }

    pub fn reportTunnels(self: *DnsTunnelManager) void {
        reporting.reportTunnels(self);
    }
};
