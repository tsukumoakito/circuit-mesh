const std = @import("std");
const posix = std.posix;
const Atomic = std.atomic.Value;

pub const TunnelStatus = struct {
    success_count_tor: Atomic(u64) = Atomic(u64).init(0),
    fail_count_tor: Atomic(u64) = Atomic(u64).init(0),
    success_count_direct: Atomic(u64) = Atomic(u64).init(0),
    fail_count_direct: Atomic(u64) = Atomic(u64).init(0),

    last_success_ts: Atomic(i64) = Atomic(i64).init(0),
    last_activity_ts: Atomic(i64) = Atomic(i64).init(0),
    next_rotation_ts: Atomic(i64) = Atomic(i64).init(0),
    is_rotating: Atomic(bool) = Atomic(bool).init(false),

    last_route: [16]u8 = [_]u8{0} ** 16,

    socks_user: [64]u8 = undefined,
    socks_pass: [64]u8 = undefined,
    current_exit_ip: [64]u8 = [_]u8{0} ** 64,
    last_exit_ip: [64]u8 = [_]u8{0} ** 64,
    cached_identity: [64]u8 = [_]u8{0} ** 64,

    mutex: std.Thread.Mutex = .{},
};

pub const PendingQuery = struct { data: []u8, addr: posix.sockaddr.in, addr_len: posix.socklen_t };

pub const QueryNode = struct { data: PendingQuery, next: ?*QueryNode = null };

pub const QueryQueue = struct {
    first: ?*QueryNode = null,
    last: ?*QueryNode = null,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    pub fn push(self: *QueryQueue, node: *QueryNode) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.last) |last| last.next = node else self.first = node;
        self.last = node;
        node.next = null;
        self.cond.signal();
    }

    pub fn pop(self: *QueryQueue) *QueryNode {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.first == null) self.cond.wait(&self.mutex);
        const node = self.first.?;
        self.first = node.next;
        if (self.first == null) self.last = null;
        return node;
    }

    pub fn flush(self: *QueryQueue, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var curr = self.first;
        while (curr) |node| {
            const next = node.next;
            allocator.free(node.data.data);
            allocator.destroy(node);
            curr = next;
        }
        self.first = null;
        self.last = null;
    }
};
