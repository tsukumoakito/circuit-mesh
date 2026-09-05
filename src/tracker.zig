const std = @import("std");
const mem = std.mem;
const Atomic = std.atomic.Value;

pub const TrackingAllocator = struct {
    base: mem.Allocator,
    current_allocated: Atomic(usize) = Atomic(usize).init(0),
    peak_allocated: Atomic(usize) = Atomic(usize).init(0),

    const vtable = mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    pub fn init(base: mem.Allocator) TrackingAllocator {
        return .{ .base = base };
    }

    pub fn allocator(self: *TrackingAllocator) mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn resetPeak(self: *TrackingAllocator) void {
        const curr = self.current_allocated.load(.monotonic);
        self.peak_allocated.store(curr, .monotonic);
    }

    fn updatePeak(self: *TrackingAllocator, new_val: usize) void {
        var current = self.peak_allocated.load(.monotonic);
        while (new_val > current) {
            current = self.peak_allocated.cmpxchgWeak(current, new_val, .monotonic, .monotonic) orelse break;
        }
    }

    fn alloc(ptr: *anyopaque, len: usize, ptr_align: mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ptr));
        const result = self.base.rawAlloc(len, ptr_align, ret_addr) orelse return null;
        const total = self.current_allocated.fetchAdd(len, .monotonic) + len;
        self.updatePeak(total);
        return result;
    }

    fn resize(ptr: *anyopaque, buf: []u8, buf_align: mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ptr));
        if (self.base.rawResize(buf, buf_align, new_len, ret_addr)) {
            if (new_len > buf.len) {
                const diff = new_len - buf.len;
                const total = self.current_allocated.fetchAdd(diff, .monotonic) + diff;
                self.updatePeak(total);
            } else {
                _ = self.current_allocated.fetchSub(buf.len - new_len, .monotonic);
            }
            return true;
        }
        return false;
    }

    fn remap(ptr: *anyopaque, buf: []u8, buf_align: mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ptr));
        const result = self.base.rawRemap(buf, buf_align, new_len, ret_addr) orelse return null;
        if (new_len > buf.len) {
            const diff = new_len - buf.len;
            const total = self.current_allocated.fetchAdd(diff, .monotonic) + diff;
            self.updatePeak(total);
        } else {
            _ = self.current_allocated.fetchSub(buf.len - new_len, .monotonic);
        }
        return result;
    }

    fn free(ptr: *anyopaque, buf: []u8, buf_align: mem.Alignment, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ptr));
        self.base.rawFree(buf, buf_align, ret_addr);
        _ = self.current_allocated.fetchSub(buf.len, .monotonic);
    }
};
