//! TrackingAllocator — a thin wrapper around any `std.mem.Allocator` that
//! keeps an atomic live-byte counter, used by soak harnesses to populate
//! the `live_bytes` column of `metrics.csv`.
//!
//! Overhead: 2 atomic adds per alloc/free (one for `allocated`, one for
//! `freed`). Atomics are `.monotonic` because the live-byte total is a
//! statistical telemetry signal, not a synchronization primitive — we
//! only ever read it from a different thread, and the off-by-a-few-bytes
//! drift is below the resolution of the soak report.

const std = @import("std");

/// Wraps any `std.mem.Allocator` with an atomic live-byte counter.
pub const TrackingAllocator = struct {
    inner: std.mem.Allocator,
    allocated: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    freed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn init(inner: std.mem.Allocator) TrackingAllocator {
        return .{ .inner = inner };
    }

    pub fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocFn,
                .resize = resizeFn,
                .remap = remapFn,
                .free = freeFn,
            },
        };
    }

    /// Current live bytes (allocated - freed). May drift by a few bytes
    /// across threads in the moment of the read; that's fine for soak
    /// telemetry.
    pub fn liveBytes(self: *const TrackingAllocator) usize {
        return self.allocated.load(.monotonic) - self.freed.load(.monotonic);
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.inner.vtable.alloc(self.inner.ptr, len, alignment, ret_addr);
        if (ptr != null) {
            _ = self.allocated.fetchAdd(len, .monotonic);
        }
        return ptr;
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const old_len = memory.len;
        const ok = self.inner.vtable.resize(self.inner.ptr, memory, alignment, new_len, ret_addr);
        if (ok) {
            if (new_len > old_len) {
                _ = self.allocated.fetchAdd(new_len - old_len, .monotonic);
            } else {
                _ = self.freed.fetchAdd(old_len - new_len, .monotonic);
            }
        }
        return ok;
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const old_len = memory.len;
        const result = self.inner.vtable.remap(self.inner.ptr, memory, alignment, new_len, ret_addr);
        if (result) |new_ptr| {
            if (new_ptr != memory.ptr) {
                // Relocated: the old memory is gone, so we reduce freed by old_len
                // and the new allocation is tracked via the new pointer.
                _ = self.freed.fetchAdd(old_len, .monotonic);
                _ = self.allocated.fetchAdd(new_len, .monotonic);
            } else {
                // In-place: same address, size changed
                if (new_len > old_len) {
                    _ = self.allocated.fetchAdd(new_len - old_len, .monotonic);
                } else {
                    _ = self.freed.fetchAdd(old_len - new_len, .monotonic);
                }
            }
        }
        return result;
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.inner.vtable.free(self.inner.ptr, memory, alignment, ret_addr);
        _ = self.freed.fetchAdd(memory.len, .monotonic);
    }
};
