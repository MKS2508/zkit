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
                // Relocated: the old block was released, so it counts as freed,
                // and the new block counts as a fresh allocation.
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

test "TrackingAllocator: el contaje cuadra en shrink, grow y remap" {
    // Fija el invariante `allocated == freed` al final de un ciclo completo.
    // Se reportó desde styx un under/overflow de `live_bytes` cuando el
    // allocator interno redondea al alza en un shrink; no reproduce sobre este
    // código, y este test lo deja anclado para que se note si alguna vez pasa.
    // Los allocators se recorren a propósito porque unos aceptan el shrink en
    // sitio y otros lo rechazan — los dos caminos de `resizeFn` importan.
    const backings = [_]std.mem.Allocator{
        std.heap.page_allocator,
        std.testing.allocator,
    };
    for (backings) |inner| {
        var ta = TrackingAllocator.init(inner);
        const a = ta.allocator();

        // Shrink (resizeFn puede devolver true o false según el allocator).
        var buf = try a.alloc(u8, 3 * 4096);
        if (a.resize(buf, 4096)) buf = buf[0..4096];
        a.free(buf);
        try std.testing.expectEqual(@as(usize, 0), ta.liveBytes());

        // Grow con reubicación probable (remapFn, rama relocated).
        var small = try a.alloc(u8, 64);
        if (a.remap(small, 1 << 16)) |moved| small = moved;
        a.free(small);
        try std.testing.expectEqual(@as(usize, 0), ta.liveBytes());

        // Crecimiento por appends, que es el patrón real de un ArrayList.
        var list = std.array_list.AlignedManaged(u64, null).init(a);
        var i: usize = 0;
        while (i < 2000) : (i += 1) try list.append(i);
        const owned = try list.toOwnedSlice();
        a.free(owned);

        try std.testing.expectEqual(@as(usize, 0), ta.liveBytes());
        try std.testing.expectEqual(
            ta.allocated.load(.monotonic),
            ta.freed.load(.monotonic),
        );
    }
}
