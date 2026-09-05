const std = @import("std");

const Netlink = @import("../netlink.zig").NetlinkEngine;
const Tracker = @import("../tracker.zig").TrackingAllocator;

pub fn syncIpset(nl: *Netlink, current: *std.StringHashMap(void), targets: *const std.StringHashMap(void), allocator: std.mem.Allocator, debug: bool) !void {
    var added: usize = 0;
    var removed: usize = 0;

    var it = targets.keyIterator();
    while (it.next()) |ip| {
        if (!current.contains(ip.*)) {
            try nl.updateBarrier(9, ip.*);
            try current.put(try allocator.dupe(u8, ip.*), {});
            if (debug) std.debug.print("➕ Barrier: Allowed {s}\n", .{ip.*});
            added += 1;
        }
    }

    var remove_list = std.ArrayListUnmanaged([]const u8){};
    defer remove_list.deinit(allocator);

    var curr_it = current.iterator();
    while (curr_it.next()) |entry| {
        if (!targets.contains(entry.key_ptr.*)) {
            try nl.updateBarrier(10, entry.key_ptr.*);
            try remove_list.append(allocator, entry.key_ptr.*);
            if (debug) std.debug.print("❌ Barrier: Revoked {s}\n", .{entry.key_ptr.*});
            removed += 1;
        }
    }

    for (remove_list.items) |ip| {
        const kv = current.fetchRemove(ip).?;
        allocator.free(kv.key);
    }

    if (!debug and (added > 0 or removed > 0)) {
        std.debug.print("🔄 Barrier sync: {d} allowed, {d} revoked.\n", .{ added, removed });
    }
}

pub fn reportMemory(tracker: *Tracker, label: []const u8) void {
    const current = tracker.current_allocated.load(.monotonic);
    const peak = tracker.peak_allocated.load(.monotonic);
    std.debug.print("📊 Memory [{s}]: Net={d:.2} KiB | Peak={d:.2} KiB\n", .{
        label,
        @as(f64, @floatFromInt(current)) / 1024.0,
        @as(f64, @floatFromInt(peak)) / 1024.0,
    });
    tracker.resetPeak();
}
