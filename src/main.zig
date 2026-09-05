const std = @import("std");
const builtin = @import("builtin");

const Config = @import("config.zig").Config;
const Barrier = @import("core/barrier.zig");
const Cli = @import("core/cli.zig");
const Netlink = @import("netlink.zig").NetlinkEngine;
const DnsTunnel = @import("services/dns.zig").DnsTunnelManager;
const Tor = @import("sources/tor.zig").TorSource;
const Tracker = @import("tracker.zig").TrackingAllocator;

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    defer _ = debug_allocator.deinit();

    const base_alloc = if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)
        debug_allocator.allocator()
    else
        std.heap.smp_allocator;

    var startup_arena = std.heap.ArenaAllocator.init(base_alloc);
    defer startup_arena.deinit();
    const startup_alloc = startup_arena.allocator();

    const cli = try Cli.parse(startup_alloc);
    var debug_mode = cli.debug_mode;

    const parsed_config = Config.load(startup_alloc, cli.config_path) catch |err| {
        std.debug.print("❌ Failed to load config from {s}: {any}\n", .{ cli.config_path, err });
        std.process.exit(1);
    };
    const cfg = parsed_config.value;
    if (cfg.force_debug_mode) debug_mode = true;

    var tracker = Tracker.init(base_alloc);
    const track_alloc = tracker.allocator();

    var nl = Netlink.init(debug_mode, cfg.ipset_name);
    var tor = Tor.init(track_alloc, debug_mode, cfg.tor_global);
    var current_ips = std.StringHashMap(void).init(track_alloc);
    var tor_online = false;

    if (debug_mode) std.debug.print("⚡ Cold Start: Using config {s}\n", .{cli.config_path});
    var target_ips = std.StringHashMap(void).init(startup_alloc);
    try tor.extractDAFromBinary(track_alloc, &target_ips);
    try tor.extractGuardsFromPrivilegedFiles(track_alloc, &target_ips);

    try Barrier.syncIpset(&nl, &current_ips, &target_ips, track_alloc, debug_mode);
    if (debug_mode) Barrier.reportMemory(&tracker, "Cold Start Memory Report");

    if (!cfg.cold_start_doh_enabled) {
        tor.waitForControlPort();
        tor_online = true;
    } else {
        var startup_ips = std.StringHashMap(void).init(startup_alloc);
        if (tor.collectLiveIps(startup_alloc, &startup_ips, false)) |_| {
            if (debug_mode) std.debug.print("🚀 Tor already online. Prioritizing Tor/DoT from the start.\n", .{});
            tor_online = true;
        } else |_| {
            if (debug_mode) std.debug.print("🚀 Tor not ready. Starting with DoH Fallback mode...\n", .{});
            tor_online = false;
        }
    }

    var dns_mgr: ?*DnsTunnel = null;
    if (cfg.dns_tunnels.len > 0) {
        dns_mgr = DnsTunnel.init(track_alloc, &cfg, &tor, &tor_online, debug_mode);
        try dns_mgr.?.spawnAll();
        if (debug_mode) Barrier.reportMemory(&tracker, "DNS Tunnel Engine Ready");
    }

    var first_report_done = false;
    var last_tor_report_time = std.time.timestamp();
    var last_mem_report = std.time.timestamp();
    var tor_fail_count: u32 = 0;
    var last_valid_ips = std.StringHashMap(void).init(track_alloc);

    var prev_tor_online = tor_online;

    while (true) {
        const now = std.time.timestamp();
        var loop_arena = std.heap.ArenaAllocator.init(base_alloc);
        defer loop_arena.deinit();
        const aa = loop_arena.allocator();

        var live_ips = std.StringHashMap(void).init(aa);
        const should_log_tor = (now - last_tor_report_time >= 60);

        var collect_success = true;
        var list_changed = false;

        tor.collectLiveIps(aa, &live_ips, should_log_tor) catch |err| {
            collect_success = false;
            tor_fail_count += 1;

            if (tor_fail_count <= 5 and debug_mode) {
                std.debug.print("⚠️ [Debug] Tor ControlPort error (count: {d}): {any}\n", .{ tor_fail_count, err });
            }

            if (tor_fail_count == 5) {
                if (tor_online) {
                    if (cfg.doh_fallback_allowed) {
                        std.debug.print("⚠️ Tor service confirmed DEAD. DNS falling back to Direct/DoH...\n", .{});
                    } else {
                        std.debug.print("🛡️  Tor service confirmed DEAD. Policy: Lock-down (No DNS access).\n", .{});
                    }
                    tor_online = false;
                }
            } else if (tor_online and tor_fail_count < 5) {
                var it = last_valid_ips.keyIterator();
                while (it.next()) |ip| try live_ips.put(try aa.dupe(u8, ip.*), {});
            }
        };

        if (collect_success and live_ips.count() > 0) {
            if (!tor_online) {
                std.debug.print("✅ Tor service reconnected. Resuming DNS via Tor/DoT.\n", .{});
                tor_online = true;
            }
            tor_fail_count = 0;

            if (live_ips.count() != last_valid_ips.count()) {
                list_changed = true;
            } else {
                var it = live_ips.keyIterator();
                while (it.next()) |ip| {
                    if (!last_valid_ips.contains(ip.*)) {
                        list_changed = true;
                        break;
                    }
                }
            }

            if (list_changed or !first_report_done) {
                var old_it = last_valid_ips.keyIterator();
                while (old_it.next()) |old_ip| track_alloc.free(old_ip.*);
                last_valid_ips.clearRetainingCapacity();
                var it = live_ips.keyIterator();
                while (it.next()) |ip| try last_valid_ips.put(try track_alloc.dupe(u8, ip.*), {});
            }
        }

        if (should_log_tor) last_tor_report_time = now;

        if (!tor_online and cfg.doh_fallback_allowed) {
            for (cfg.dns_tunnels) |tunnel| {
                try live_ips.put(try aa.dupe(u8, tunnel.ip), {});
            }
        }

        const state_changed = (tor_online != prev_tor_online);
        const should_sync = state_changed or (collect_success and list_changed) or tor_fail_count == 5;

        if (should_sync) {
            if (live_ips.count() > 0 or current_ips.count() > 0) {
                try Barrier.syncIpset(&nl, &current_ips, &live_ips, track_alloc, debug_mode);
            }
        }
        prev_tor_online = tor_online;

        if (debug_mode and !first_report_done and tor_online) {
            std.debug.print("\n📋 [Debug] Initial Monitoring IP List:\n", .{});
            var it = current_ips.keyIterator();
            while (it.next()) |ip| std.debug.print("  - {s}\n", .{ip.*});
            std.debug.print("------------------------------------------------------------\n", .{});
            Barrier.reportMemory(&tracker, "Handover Memory Report");
            first_report_done = true;
        }

        if (debug_mode and now - last_mem_report >= cfg.mem_report_interval_s) {
            std.debug.print("\n📊 {d}-Second System Status (Tor Online: {any}):\n", .{ cfg.mem_report_interval_s, tor_online });
            std.debug.print("  - Net Data: {d:.2} KiB\n", .{@as(f64, @floatFromInt(tracker.current_allocated.load(.monotonic))) / 1024.0});
            std.debug.print("  - Peak Alloc: {d:.2} KiB\n", .{@as(f64, @floatFromInt(tracker.peak_allocated.load(.monotonic))) / 1024.0});

            if (dns_mgr) |mgr| mgr.reportTunnels();

            last_mem_report = now;
            tracker.resetPeak();
        }

        std.Thread.sleep(cfg.monitoring_interval_ms * std.time.ns_per_ms);
    }
}
