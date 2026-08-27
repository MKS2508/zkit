//! Generic opaque handle slab with generation counters.
//!
//! Provides ABA-safe opaque u64 handles for FFI consumers. The handle
//! encodes a generation counter (top 16 bits) and a slot index (low 48
//! bits). Stale handles are always rejected — freeing a handle and
//! reusing the slot bumps the generation, invalidating old handles.
//!
//! ## Design
//!
//!   Handle layout: `(generation: u16) << 48 | (slot index, low 48 bits)`
//!
//!   - 16-bit generation → 65535 reuses before wrap (ABA window)
//!   - the slot field is 48 bits wide, but the API is `u32` end to end
//!     (`capacity`, `init`, `encodeHandle`, `decodeSlot`), so the real
//!     ceiling is 2^32 slots. The spare 16 bits are headroom, not capacity —
//!     a slot index above 2^32 cannot be constructed.
//!
//! `0` is never a live handle, so consumers may use it as a NULL sentinel
//! (styx does: `BufferHandle.NULL`). `alloc()` skips generation 0 to make
//! that hold by construction rather than by arithmetic accident.
//!
//! ## Usage
//!
//! ```zig
//! var slab = try HandleSlab(*MyState).init(allocator, 64);
//! defer slab.deinit();
//!
//! const handle = try slab.alloc(my_state_ptr);
//! const ptr = slab.get(handle) orelse return error.InvalidHandle;
//! slab.free(handle);
//! // slab.get(handle) now returns null (generation mismatch).
//! ```
//!
//! ## Thread Safety
//!
//! Not thread-safe. Callers must synchronize externally if shared
//! between threads (typical FFI pattern: single-threaded consumer).

const std = @import("std");

/// Generic handle slab. `T` is the stored value type (typically a pointer).
pub fn HandleSlab(comptime T: type) type {
    return struct {
        entries: []?T,
        generations: []u16,
        free_list: []u32,
        free_count: u32,
        capacity: u32,
        allocator: std.mem.Allocator,

        const Self = @This();

        /// Initialize a slab with `capacity` slots.
        pub fn init(allocator: std.mem.Allocator, capacity: u32) !Self {
            if (capacity == 0) return error.InvalidParameter;

            const entries = try allocator.alloc(?T, capacity);
            @memset(entries, null);

            const generations = try allocator.alloc(u16, capacity);
            @memset(generations, 0);

            const free_list = try allocator.alloc(u32, capacity);
            // Initialize free list: all slots available, in reverse order
            // so alloc() returns slot 0 first.
            for (free_list, 0..) |*slot, i| {
                slot.* = @intCast(capacity - 1 - i);
            }

            return .{
                .entries = entries,
                .generations = generations,
                .free_list = free_list,
                .free_count = capacity,
                .capacity = capacity,
                .allocator = allocator,
            };
        }

        /// Release all slab memory.
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.entries);
            self.allocator.free(self.generations);
            self.allocator.free(self.free_list);
        }

        /// Allocate a slot and return an opaque handle.
        ///
        /// The handle encodes `(generation << 48) | slot_index`.
        /// Generation 0 is skipped, so a live handle is never `0` and
        /// consumers may use `0` as a NULL sentinel.
        /// Returns `error.PoolFull` if no slots available.
        pub fn alloc(self: *Self, value: T) !u64 {
            if (self.free_count == 0) return error.PoolFull;
            self.free_count -= 1;
            const slot = self.free_list[self.free_count];
            self.generations[slot] +%= 1;
            if (self.generations[slot] == 0) self.generations[slot] = 1;
            self.entries[slot] = value;
            return encodeHandle(self.generations[slot], slot);
        }

        /// Resolve a handle to its stored value.
        ///
        /// Returns `null` if the handle is invalid (wrong generation
        /// or already freed).
        pub fn get(self: *const Self, handle: u64) ?T {
            const slot = decodeSlot(handle);
            const gen = decodeGeneration(handle);
            if (slot >= self.capacity) return null;
            if (self.generations[slot] != gen) return null;
            return self.entries[slot];
        }

        /// Free a slot. The handle becomes invalid immediately.
        ///
        /// Safe to call with an already-freed or invalid handle (no-op).
        pub fn free(self: *Self, handle: u64) void {
            const slot = decodeSlot(handle);
            const gen = decodeGeneration(handle);
            if (slot >= self.capacity) return;
            if (self.generations[slot] != gen) return;
            if (self.entries[slot] == null) return; // Already freed.
            self.entries[slot] = null;
            // Bump generation so the handle is immediately invalidated.
            // Next alloc() of this slot will bump again, giving a fresh gen.
            self.generations[slot] +%= 1;
            self.free_list[self.free_count] = slot;
            self.free_count += 1;
        }

        /// Number of active (allocated) slots.
        pub fn activeCount(self: *const Self) u32 {
            return self.capacity - self.free_count;
        }

        fn encodeHandle(gen: u16, slot: u32) u64 {
            return (@as(u64, gen) << 48) | @as(u64, slot);
        }

        fn decodeSlot(handle: u64) u32 {
            return @truncate(handle & 0xFFFF_FFFF_FFFF);
        }

        fn decodeGeneration(handle: u64) u16 {
            return @truncate(handle >> 48);
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "HandleSlab: alloc and get" {
    var slab = try HandleSlab(u32).init(std.testing.allocator, 4);
    defer slab.deinit();

    const h1 = try slab.alloc(42);
    const h2 = try slab.alloc(99);

    try std.testing.expectEqual(@as(?u32, 42), slab.get(h1));
    try std.testing.expectEqual(@as(?u32, 99), slab.get(h2));
    try std.testing.expectEqual(@as(u32, 2), slab.activeCount());
}

test "HandleSlab: free invalidates handle" {
    var slab = try HandleSlab(u32).init(std.testing.allocator, 4);
    defer slab.deinit();

    const h = try slab.alloc(42);
    try std.testing.expectEqual(@as(?u32, 42), slab.get(h));

    slab.free(h);
    try std.testing.expectEqual(@as(?u32, null), slab.get(h));
}

test "HandleSlab: generation prevents ABA" {
    var slab = try HandleSlab(u32).init(std.testing.allocator, 2);
    defer slab.deinit();

    const h1 = try slab.alloc(10);
    slab.free(h1);

    // Reuse the same slot.
    const h2 = try slab.alloc(20);

    // Old handle should be invalid (generation changed).
    try std.testing.expectEqual(@as(?u32, null), slab.get(h1));
    // New handle should work.
    try std.testing.expectEqual(@as(?u32, 20), slab.get(h2));
    // Handles should be different.
    try std.testing.expect(h1 != h2);
}

test "HandleSlab: full slab returns error" {
    var slab = try HandleSlab(u32).init(std.testing.allocator, 2);
    defer slab.deinit();

    _ = try slab.alloc(1);
    _ = try slab.alloc(2);

    try std.testing.expectError(error.PoolFull, slab.alloc(3));
}

test "HandleSlab: 0 is never a live handle, across a full generation cycle" {
    // Locks the NULL-sentinel guarantee for slot 0, the only slot whose
    // handle could collide with 0. 200k alloc/free pairs bump the u16
    // generation ~400k times, so the wrap is covered many times over.
    var slab = try HandleSlab(u32).init(std.testing.allocator, 1);
    defer slab.deinit();

    var i: u32 = 0;
    while (i < 200_000) : (i += 1) {
        const h = try slab.alloc(i);
        try std.testing.expect(h != 0);
        try std.testing.expect(slab.generations[0] != 0);
        try std.testing.expectEqual(@as(?u32, i), slab.get(h));
        slab.free(h);
    }
}

test "HandleSlab: double free is safe" {
    var slab = try HandleSlab(u32).init(std.testing.allocator, 4);
    defer slab.deinit();

    const h = try slab.alloc(42);
    slab.free(h);
    slab.free(h); // Should be no-op (generation already changed).
    try std.testing.expectEqual(@as(u32, 0), slab.activeCount());
}

test "HandleSlab: invalid handle returns null" {
    var slab = try HandleSlab(u32).init(std.testing.allocator, 4);
    defer slab.deinit();

    try std.testing.expectEqual(@as(?u32, null), slab.get(0xDEAD_BEEF));
    try std.testing.expectEqual(@as(?u32, null), slab.get(0xFFFF_FFFF_FFFF_FFFF));
}

test "HandleSlab: stress alloc/free cycles" {
    var slab = try HandleSlab(u32).init(std.testing.allocator, 8);
    defer slab.deinit();

    var handles: [8]u64 = undefined;

    // 100 cycles of fill + drain.
    for (0..100) |cycle| {
        for (0..8) |i| {
            handles[i] = try slab.alloc(@intCast(cycle * 8 + i));
        }
        try std.testing.expectEqual(@as(u32, 8), slab.activeCount());

        for (0..8) |i| {
            slab.free(handles[i]);
        }
        try std.testing.expectEqual(@as(u32, 0), slab.activeCount());
    }
}

test "HandleSlab: pointer type" {
    const MyState = struct { value: u32 };
    var slab = try HandleSlab(*MyState).init(std.testing.allocator, 4);
    defer slab.deinit();

    var state = MyState{ .value = 42 };
    const h = try slab.alloc(&state);

    const ptr = slab.get(h).?;
    try std.testing.expectEqual(@as(u32, 42), ptr.value);
}
