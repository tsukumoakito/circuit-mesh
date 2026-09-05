const std = @import("std");
const net = std.net;
const posix = std.posix;

const Config = @import("../../config.zig").Config;
const DnsTunnelManager = @import("../dns.zig").DnsTunnelManager;

pub fn udpTunnelRunner(mgr: *DnsTunnelManager, tunnel: Config.DnsTunnel, idx: usize) void {
    const address = net.Address.parseIp4(tunnel.local_ip, tunnel.local_port) catch return;
    const sock = posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP) catch return;
    defer posix.close(sock);

    defer mgr.ready_flags[idx] = false;

    posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(i32, 1))) catch return;
    posix.bind(sock, &address.any, address.getOsSockLen()) catch return;

    mgr.udp_listeners[idx] = sock;
    mgr.ready_flags[idx] = true;

    const Context = struct {
        mgr: *DnsTunnelManager,
        tunnel: Config.DnsTunnel,
        data: []u8,
        addr: posix.sockaddr.in,
        len: posix.socklen_t,
        idx: usize,
    };

    var buf: [4096]u8 = undefined;
    while (true) {
        var src_addr: posix.sockaddr.in = undefined;
        var src_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        const n = posix.recvfrom(sock, &buf, 0, @ptrCast(&src_addr), &src_len) catch break;
        if (n == 0) continue;

        mgr.stats[idx].last_activity_ts.store(std.time.timestamp(), .monotonic);

        const query_data = mgr.allocator.dupe(u8, buf[0..n]) catch continue;
        const ctx = mgr.allocator.create(Context) catch {
            mgr.allocator.free(query_data);
            continue;
        };
        ctx.* = .{ .mgr = mgr, .tunnel = tunnel, .data = query_data, .addr = src_addr, .len = src_len, .idx = idx };

        const thread = std.Thread.spawn(.{}, struct {
            fn run(ctx_ptr: *Context) void {
                const m = ctx_ptr.mgr;
                defer {
                    m.allocator.free(ctx_ptr.data);
                    m.allocator.destroy(ctx_ptr);
                }
                const conn = m.establishConn(ctx_ptr.tunnel, ctx_ptr.idx) catch return;
                defer m.destroyConn(conn);

                m.doExchange(conn, ctx_ptr.tunnel, ctx_ptr.data, ctx_ptr.addr, ctx_ptr.len, ctx_ptr.idx) catch {
                    if (conn.is_doh) {
                        _ = m.stats[ctx_ptr.idx].fail_count_direct.fetchAdd(1, .monotonic);
                    } else {
                        _ = m.stats[ctx_ptr.idx].fail_count_tor.fetchAdd(1, .monotonic);
                    }

                    if (!conn.is_doh) {
                        m.tor_source.requestCircuitPurge(m.stats[ctx_ptr.idx].socks_user[0..64]) catch {};
                    }
                };
            }
        }.run, .{ctx}) catch {
            mgr.allocator.free(query_data);
            mgr.allocator.destroy(ctx);
            continue;
        };
        thread.detach();
    }
}

pub fn tcpTunnelRunner(mgr: *DnsTunnelManager, tunnel: Config.DnsTunnel, idx: usize) void {
    const address = net.Address.parseIp4(tunnel.local_ip, tunnel.local_port) catch return;
    var server = address.listen(.{ .reuse_address = true }) catch return;
    defer server.deinit();

    defer mgr.ready_flags[idx] = false;
    mgr.ready_flags[idx] = true;

    while (true) {
        const conn = server.accept() catch break;
        _ = std.Thread.spawn(.{}, struct {
            fn run(m: *DnsTunnelManager, t: Config.DnsTunnel, c: net.Server.Connection, i: usize) void {
                defer c.stream.close();
                m.processQuery(c.stream, t, i) catch {};
            }
        }.run, .{ mgr, tunnel, conn, idx }) catch {
            conn.stream.close();
            continue;
        };
    }
}

pub fn watchdogWorker(mgr: *DnsTunnelManager, tunnel: Config.DnsTunnel, idx: usize) void {
    std.Thread.sleep(10 * std.time.ns_per_s);

    while (true) {
        const interval_ns = @as(u64, @intCast(mgr.global_cfg.rotation_check_interval_s)) * std.time.ns_per_s;
        std.Thread.sleep(interval_ns);

        const now = std.time.timestamp();

        if (!mgr.is_tor_online.*) continue;

        const is_silent = (now - mgr.stats[idx].last_success_ts.load(.monotonic) >= 120);
        const is_expired = (now >= mgr.stats[idx].next_rotation_ts.load(.monotonic));

        if (is_silent or is_expired) {
            if (now - mgr.stats[idx].last_activity_ts.load(.monotonic) < 15) {
                if (mgr.debug) std.debug.print("⏳ [{s}] Active traffic detected. Snoozing rotation...\n", .{tunnel.name});
                continue;
            }

            if (mgr.debug) {
                const cause = if (is_silent) "Silence" else "TTL Expired";
                std.debug.print("🔍 [{s}] Rotation scheduled (Cause: {s})...\n", .{ tunnel.name, cause });
            }

            mgr.rotateIdentitySeamlessly(tunnel, idx) catch |err| {
                if (err == error.Throttled) continue;
                if (mgr.debug) std.debug.print("⚠️ [{s}] Background rotation failed: {any}\n", .{ tunnel.name, err });
            };

            const next_ts = mgr.calculateNextRotation("dns");
            mgr.stats[idx].next_rotation_ts.store(next_ts, .monotonic);

            if (mgr.debug) {
                const next_wait = next_ts - now;
                std.debug.print("📅 [{s}] Next rotation scheduled in {d} min.\n", .{ tunnel.name, @divTrunc(next_wait, 60) });
            }
        }
    }
}
