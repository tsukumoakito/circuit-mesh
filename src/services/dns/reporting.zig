const std = @import("std");

const DnsTunnelManager = @import("../dns.zig").DnsTunnelManager;

pub fn reportTunnels(mgr: *DnsTunnelManager) void {
    if (!mgr.debug) return;

    var arena = std.heap.ArenaAllocator.init(mgr.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const id_map = if (mgr.is_tor_online.*)
        mgr.tor_source.fetchTorIdentityMap(aa) catch null
    else
        null;

    const Row = struct { name: []const u8, ip: []const u8, route: []const u8, identity: []const u8, tor_stat: []const u8, h2_stat: []const u8 };
    var rows = std.ArrayListUnmanaged(Row){};

    var w_name: usize = "Name".len;
    var w_ip: usize = "IP".len;
    var w_route: usize = "Route".len;
    var w_ident: usize = "Tor Exit Identity".len;
    var w_tor: usize = "Tor OK/NG".len;
    var w_h2: usize = "H2 OK/NG".len;

    for (mgr.config, 0..) |t, i| {
        const s = &mgr.stats[i];

        const route_raw = std.mem.sliceTo(&s.last_route, 0);
        const is_tor = std.mem.eql(u8, route_raw, "tor");
        const route_str = if (is_tor) "tor" else if (std.mem.eql(u8, route_raw, "direct")) "direct" else route_raw;

        var exit_id: []const u8 = "N/A (Direct)";
        if (is_tor) {
            s.mutex.lock();
            if (id_map) |m| {
                if (m.get(s.socks_user[0..64])) |val| {
                    exit_id = val;
                    var it = std.mem.splitScalar(u8, val, ' ');
                    if (it.next()) |ip| {
                        @memset(s.current_exit_ip[0..], 0);
                        @memcpy(s.current_exit_ip[0..@min(ip.len, 63)], ip[0..@min(ip.len, 63)]);
                    }
                    @memset(s.cached_identity[0..64], 0);
                    @memcpy(s.cached_identity[0..@min(val.len, 63)], val[0..@min(val.len, 63)]);
                } else {
                    const cached = std.mem.sliceTo(&s.cached_identity, 0);
                    exit_id = if (cached.len > 0) cached else "establishing...";
                }
            } else {
                const cached = std.mem.sliceTo(&s.cached_identity, 0);
                exit_id = if (cached.len > 0) cached else "fetching...";
            }
            s.mutex.unlock();
        } else if (mgr.doh_fallback_allowed) {
            exit_id = "[FALLBACK] Direct DoH";
        } else {
            exit_id = "[LOCKED] Offline";
        }

        const tor_s = std.fmt.allocPrint(aa, "{d}/{d}", .{ s.success_count_tor.load(.monotonic), s.fail_count_tor.load(.monotonic) }) catch "0/0";
        const h2_s = std.fmt.allocPrint(aa, "{d}/{d}", .{ s.success_count_direct.load(.monotonic), s.fail_count_direct.load(.monotonic) }) catch "0/0";

        rows.append(aa, .{ .name = t.name, .ip = t.ip, .route = route_str, .identity = exit_id, .tor_stat = tor_s, .h2_stat = h2_s }) catch {};

        w_name = @max(w_name, t.name.len);
        w_ip = @max(w_ip, t.ip.len);
        w_route = @max(w_route, route_str.len);
        w_ident = @max(w_ident, exit_id.len);
        w_tor = @max(w_tor, tor_s.len);
        w_h2 = @max(w_h2, h2_s.len);
    }

    std.debug.print("\n🛡️  DNS Tunnel Health Report (Zero-Trust Logic):\n", .{});

    const printP = struct {
        fn run(str: []const u8, width: usize) void {
            std.debug.print("{s}", .{str});
            var p: usize = str.len;
            while (p < width) : (p += 1) std.debug.print(" ", .{});
        }
    }.run;

    std.debug.print("  ", .{});
    printP("Name", w_name);
    std.debug.print(" | ", .{});
    printP("IP", w_ip);
    std.debug.print(" | ", .{});
    printP("Route", w_route);
    std.debug.print(" | ", .{});
    printP("Tor Exit Identity", w_ident);
    std.debug.print(" | ", .{});
    printP("Tor OK/NG", w_tor);
    std.debug.print(" | ", .{});
    printP("H2 OK/NG", w_h2);
    std.debug.print("\n", .{});

    var k: usize = 0;
    while (k < (w_name + w_ip + w_route + w_ident + w_tor + w_h2 + 17)) : (k += 1) std.debug.print("-", .{});
    std.debug.print("\n", .{});

    for (rows.items) |r| {
        std.debug.print("  ", .{});
        printP(r.name, w_name);
        std.debug.print(" | ", .{});
        printP(r.ip, w_ip);
        std.debug.print(" | ", .{});

        if (std.mem.eql(u8, r.route, "tor")) {
            std.debug.print("\x1b[32mtor\x1b[0m", .{});
        } else if (std.mem.eql(u8, r.route, "direct")) {
            std.debug.print("\x1b[31mdirect\x1b[0m", .{});
        } else {
            std.debug.print("{s}", .{r.route});
        }
        var p: usize = r.route.len;
        while (p < w_route) : (p += 1) std.debug.print(" ", .{});
        std.debug.print(" | ", .{});

        printP(r.identity, w_ident);
        std.debug.print(" | ", .{});
        printP(r.tor_stat, w_tor);
        std.debug.print(" | ", .{});
        printP(r.h2_stat, w_h2);
        std.debug.print("\n", .{});
    }
}
