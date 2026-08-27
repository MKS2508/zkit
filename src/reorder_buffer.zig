//! Bounded reorder buffer with terminal semantics.
//!
//! Provides:
//!   - `SequenceNumber` — u64 per-request identifier
//!   - `ReorderBuffer(T)` — bounded reorder buffer
//!     - `insert(seq, chunk)` — insert chunk at sequence position
//!     - `drain(ctx, on_chunk)` — emit chunks in order, contiguous from
//!       next_expected; or release all held chunks after a reset
//!     - `gapTimeout(seq)` — mark a position as lost past its deadline
//!     - `reset()` — explicit transition to resetting state
//!
//! Terminal semantics:
//!   A position lost past its deadline triggers cancel/reset of the request
//!   + release of all held completions. NEVER waits infinitely.
//!   The reorder buffer is NOT a stall vector.

const std = @import("std");
const testing = std.testing;

// ---------------------------------------------------------------------------
// SequenceNumber
// ---------------------------------------------------------------------------

/// Sequence number within a single request's address space.
pub const SequenceNumber = u64;

// ---------------------------------------------------------------------------
// SlotState
// ---------------------------------------------------------------------------

/// Internal state of each circular-buffer slot.
const SlotState = enum(u2) {
    /// Slot is empty and available for insertion.
    free,
    /// Slot holds a chunk value at a given sequence number.
    filled,
    /// Slot was marked as timed out via `gapTimeout`; the position was lost
    /// past its deadline and will trigger a reset when drain reaches it.
    timed_out,
};

// ---------------------------------------------------------------------------
// ReorderBuffer
// ---------------------------------------------------------------------------

/// A bounded reorder buffer with terminal semantics.
///
/// Manages a fixed-size window of slots indexed by `seq % bound`. Out-of-order
/// chunks are placed into slots; `drain()` emits them in contiguous order from
/// `next_expected`. A timed-out gap at the head immediately transitions the
/// buffer to resetting state, and the next drain call releases all held chunks.
///
/// After a reset the buffer is fully cleared (`next_expected = 0`, all slots
/// free) and ready for a new sequence space.
pub fn ReorderBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        // ------------------------------------------------------------------
        // Fields
        // ------------------------------------------------------------------

        allocator: std.mem.Allocator,
        /// Max window size / max gap bound.
        bound: usize,
        /// Next sequence number expected in the contiguous stream.
        next_expected: SequenceNumber,
        /// Whether a gap timeout has triggered a pending reset.
        resetting: bool,
        /// Parallel arrays indexed by `seq % bound`.
        states: []SlotState,
        seqs: []SequenceNumber,
        values: []T,

        // ------------------------------------------------------------------
        // Lifecycle
        // ------------------------------------------------------------------

        /// Initialise a buffer with the given capacity.
        ///
        /// `bound` is the max window size / max gap. All slots start free.
        /// The allocator is retained for deinit.
        pub fn init(allocator: std.mem.Allocator, bound: usize) !Self {
            const states = try allocator.alloc(SlotState, bound);
            const seqs = try allocator.alloc(SequenceNumber, bound);
            const values = try allocator.alloc(T, bound);
            @memset(states, .free);
            return .{
                .allocator = allocator,
                .bound = bound,
                .next_expected = 0,
                .resetting = false,
                .states = states,
                .seqs = seqs,
                .values = values,
            };
        }

        /// Release all memory.
        ///
        /// Does NOT run drop on stored values — caller must have drained them.
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.states);
            self.allocator.free(self.seqs);
            self.allocator.free(self.values);
        }

        // ------------------------------------------------------------------
        // Insert
        // ------------------------------------------------------------------

        /// Insert a chunk at the given sequence number.
        ///
        /// Errors:
        ///   - `error.Resetting` — buffer is in resetting state; accept no
        ///     new chunks until drained and cleared.
        ///   - `error.Stale` — `seq` is behind `next_expected` (past the
        ///     window edge).
        ///   - `error.OutOfWindow` — `seq` is beyond `next_expected + bound`
        ///     (ahead of the window).
        ///   - `error.Duplicate` — the slot is already occupied (either by
        ///     a chunk at a different sequence that hasn't been drained, or
        ///     by a genuine duplicate).
        pub fn insert(self: *Self, seq: SequenceNumber, value: T) !void {
            if (self.resetting) return error.Resetting;
            if (seq < self.next_expected) return error.Stale;
            const b = @as(SequenceNumber, @intCast(self.bound));
            if (seq >= self.next_expected + b) return error.OutOfWindow;

            const idx = @as(usize, @intCast(seq % b));
            if (self.states[idx] != .free) return error.Duplicate;

            self.states[idx] = .filled;
            self.seqs[idx] = seq;
            self.values[idx] = value;
        }

        // ------------------------------------------------------------------
        // Drain
        // ------------------------------------------------------------------

        /// Drain contiguously available chunks and/or release held chunks
        /// after a reset.
        ///
        /// `ctx` is passed as a pointer — the callback receives the same
        /// pointer value. This avoids double-indirection when the caller
        /// already holds a pointer.
        ///
        /// Each chunk is passed to `on_chunk(ctx, seq, &value)`. The callback
        /// receives a pointer to the value still in the buffer slot and may
        /// copy or process it. After the callback returns the slot is freed.
        ///
        /// Returns the number of chunks drained / released.
        ///
        /// ## Normal path
        ///
        /// Emits every chunk whose sequence number equals `next_expected`,
        /// advancing the cursor. Stops at the first gap (free or
        /// sequence-mismatched slot).
        ///
        /// ## Timed-out-at-head path
        ///
        /// If the slot at `next_expected` is in `timed_out` state (set by an
        /// earlier `gapTimeout` for a future position that drain has now
        /// reached), the buffer transitions to resetting and returns the
        /// count of chunks drained so far. The caller must invoke drain again
        /// to release all held chunks via the reset-release path.
        ///
        /// ## Reset-release path
        ///
        /// When `self.resetting` is true (set by `gapTimeout` on the head
        /// position, by the timed-out-at-head path above, or by an explicit
        /// `reset()`), every filled slot is released via the callback, all
        /// states are cleared, `next_expected` resets to 0, and `resetting`
        /// is set back to `false`.
        pub fn drain(
            self: *Self,
            ctx: anytype,
            comptime on_chunk: fn (@TypeOf(ctx), SequenceNumber, *T) void,
        ) usize {
            var count: usize = 0;

            // --- Reset-release path ---
            if (self.resetting) {
                for (0..self.bound) |i| {
                    if (self.states[i] == .filled) {
                        on_chunk(ctx, self.seqs[i], &self.values[i]);
                        count += 1;
                    }
                    self.states[i] = .free;
                }
                self.next_expected = 0;
                self.resetting = false;
                return count;
            }

            // --- Normal drain path ---
            const b = @as(SequenceNumber, @intCast(self.bound));

            while (true) {
                const idx = @as(usize, @intCast(self.next_expected % b));

                switch (self.states[idx]) {
                    .free => break,
                    .filled => {
                        // Due to cyclic wrap-around the slot may hold a
                        // different sequence — only drain if it matches.
                        if (self.seqs[idx] != self.next_expected) break;
                        on_chunk(ctx, self.next_expected, &self.values[idx]);
                        self.states[idx] = .free;
                        self.next_expected += 1;
                        count += 1;
                    },
                    .timed_out => {
                        // A gap was pre-announced via `gapTimeout` for a
                        // future position and drain has now reached it.
                        // Clear the marker and transition to resetting.
                        self.states[idx] = .free;
                        self.resetting = true;
                        return count;
                    },
                }
            }

            return count;
        }

        // ------------------------------------------------------------------
        // Gap timeout
        // ------------------------------------------------------------------

        /// Mark a sequence number as having timed out.
        ///
        /// If `seq == next_expected`, the buffer immediately transitions to
        /// `resetting` — the next `drain()` call (or the reset-release path
        /// triggered within the same call chain) will release all held chunks.
        ///
        /// Future positions (`seq > next_expected`) are marked in `timed_out`
        /// state so that `drain()` will reset when it reaches them.
        ///
        /// Positions behind `next_expected` or beyond the window are silently
        /// ignored — they are already irrelevant to the current request.
        pub fn gapTimeout(self: *Self, seq: SequenceNumber) void {
            if (self.resetting) return;
            if (seq < self.next_expected) return;
            const b = @as(SequenceNumber, @intCast(self.bound));
            if (seq >= self.next_expected + b) return;

            const idx = @as(usize, @intCast(seq % b));

            if (seq == self.next_expected) {
                // Head position lost — immediate reset.
                // Discard any value that was already stored here.
                self.states[idx] = .free;
                self.resetting = true;
            } else {
                self.states[idx] = .timed_out;
            }
        }

        // ------------------------------------------------------------------
        // Reset
        // ------------------------------------------------------------------

        /// Explicitly put the buffer into resetting state.
        ///
        /// The next `drain()` call will release all held chunks and reset
        /// `next_expected` to 0. This is useful for tests and cleanup when
        /// the caller needs to abort the current request without a specific
        /// gap timeout.
        pub fn reset(self: *Self) void {
            self.resetting = true;
        }

        // ------------------------------------------------------------------
        // Introspection
        // ------------------------------------------------------------------

        /// Returns `true` while the buffer is in resetting state.
        pub fn isResetting(self: *const Self) bool {
            return self.resetting;
        }

        /// The current bound (max window size).
        pub fn getBound(self: *const Self) usize {
            return self.bound;
        }

        /// Number of filled slots.
        pub fn filledCount(self: *const Self) usize {
            var n: usize = 0;
            for (self.states) |s| {
                if (s == .filled) n += 1;
            }
            return n;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "insert out-of-order — drain emits in order" {
    var buf = try ReorderBuffer(u64).init(testing.allocator, 8);
    defer buf.deinit();

    // Insert out of order.
    try buf.insert(2, 30);
    try buf.insert(0, 10);
    try buf.insert(1, 20);

    const Ctx = struct {
        allocator: std.mem.Allocator,
        items: std.ArrayList(u64),
        seqs: std.ArrayList(SequenceNumber),
        fn onChunk(ctx: *@This(), seq: SequenceNumber, val: *u64) void {
            ctx.items.append(ctx.allocator, val.*) catch @panic("OOM");
            ctx.seqs.append(ctx.allocator, seq) catch @panic("OOM");
        }
    };
    const items = try std.ArrayList(u64).initCapacity(testing.allocator, 16);
    const seqs = try std.ArrayList(SequenceNumber).initCapacity(testing.allocator, 16);
    var ctx = Ctx{ .allocator = testing.allocator, .items = items, .seqs = seqs };
    defer {
        ctx.items.deinit(testing.allocator);
        ctx.seqs.deinit(testing.allocator);
    }

    // Drain should emit 0 → 1 → 2.
    const n = buf.drain(&ctx, Ctx.onChunk);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(u64, 10), ctx.items.items[0]);
    try testing.expectEqual(@as(u64, 20), ctx.items.items[1]);
    try testing.expectEqual(@as(u64, 30), ctx.items.items[2]);
    try testing.expectEqual(@as(SequenceNumber, 0), ctx.seqs.items[0]);
    try testing.expectEqual(@as(SequenceNumber, 1), ctx.seqs.items[1]);
    try testing.expectEqual(@as(SequenceNumber, 2), ctx.seqs.items[2]);

    // Buffer is empty after drain.
    try testing.expectEqual(@as(usize, 0), buf.filledCount());
}

test "partial insert — partial drain then complete" {
    var buf = try ReorderBuffer(u64).init(testing.allocator, 8);
    defer buf.deinit();

    try buf.insert(0, 10);
    try buf.insert(2, 30); // seq 1 is missing

    const Ctx = struct {
        allocator: std.mem.Allocator,
        items: std.ArrayList(u64),
        fn onChunk(ctx: *@This(), _: SequenceNumber, val: *u64) void {
            ctx.items.append(ctx.allocator, val.*) catch @panic("OOM");
        }
    };

    {
        const items = try std.ArrayList(u64).initCapacity(testing.allocator, 16);
        var ctx = Ctx{ .allocator = testing.allocator, .items = items };
        defer ctx.items.deinit(testing.allocator);

        // Only seq 0 is contiguous.
        const n1 = buf.drain(&ctx, Ctx.onChunk);
        try testing.expectEqual(@as(usize, 1), n1);
        try testing.expectEqual(@as(u64, 10), ctx.items.items[0]);
    }

    // Now insert seq 1.
    try buf.insert(1, 20);

    {
        const items = try std.ArrayList(u64).initCapacity(testing.allocator, 16);
        var ctx = Ctx{ .allocator = testing.allocator, .items = items };
        defer ctx.items.deinit(testing.allocator);

        // Drain yields seq 1, 2.
        const n2 = buf.drain(&ctx, Ctx.onChunk);
        try testing.expectEqual(@as(usize, 2), n2);
        try testing.expectEqual(@as(u64, 20), ctx.items.items[0]);
        try testing.expectEqual(@as(u64, 30), ctx.items.items[1]);
    }
}

test "gap timeout at head — releases held chunks" {
    var buf = try ReorderBuffer(u64).init(testing.allocator, 8);
    defer buf.deinit();

    // Chunks 1 and 2 arrive before chunk 0.
    try buf.insert(1, 100);
    try buf.insert(2, 200);

    // Chunk 0 times out — head lost.
    buf.gapTimeout(0);
    try testing.expect(buf.isResetting());

    // Drain should release chunks 1 and 2.
    const Ctx = struct {
        allocator: std.mem.Allocator,
        items: std.ArrayList(u64),
        seqs: std.ArrayList(SequenceNumber),
        fn onChunk(ctx: *@This(), seq: SequenceNumber, val: *u64) void {
            ctx.items.append(ctx.allocator, val.*) catch @panic("OOM");
            ctx.seqs.append(ctx.allocator, seq) catch @panic("OOM");
        }
    };
    const items = try std.ArrayList(u64).initCapacity(testing.allocator, 16);
    const seqs = try std.ArrayList(SequenceNumber).initCapacity(testing.allocator, 16);
    var ctx = Ctx{ .allocator = testing.allocator, .items = items, .seqs = seqs };
    defer {
        ctx.items.deinit(testing.allocator);
        ctx.seqs.deinit(testing.allocator);
    }

    const n = buf.drain(&ctx, Ctx.onChunk);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u64, 100), ctx.items.items[0]);
    try testing.expectEqual(@as(u64, 200), ctx.items.items[1]);
    try testing.expectEqual(@as(SequenceNumber, 1), ctx.seqs.items[0]);
    try testing.expectEqual(@as(SequenceNumber, 2), ctx.seqs.items[1]);

    // Buffer is fully reset after drain.
    try testing.expectEqual(@as(usize, 0), buf.filledCount());
    try testing.expect(!buf.isResetting());
}

test "gap timeout at future position — reset when reached" {
    var buf = try ReorderBuffer(u64).init(testing.allocator, 8);
    defer buf.deinit();

    try buf.insert(0, 10);
    try buf.insert(1, 20);
    try buf.insert(2, 30);
    try buf.insert(3, 40);
    try buf.insert(4, 50);

    // Mark seq 5 as timed out (future position).
    buf.gapTimeout(5);

    const Ctx = struct {
        allocator: std.mem.Allocator,
        items: std.ArrayList(u64),
        fn onChunk(ctx: *@This(), _: SequenceNumber, val: *u64) void {
            ctx.items.append(ctx.allocator, val.*) catch @panic("OOM");
        }
    };

    {
        const items = try std.ArrayList(u64).initCapacity(testing.allocator, 16);
        var ctx = Ctx{ .allocator = testing.allocator, .items = items };
        defer ctx.items.deinit(testing.allocator);

        // Drain yields 0, 1, 2, 3, 4 (contiguous, no gap).
        const n1 = buf.drain(&ctx, Ctx.onChunk);
        try testing.expectEqual(@as(usize, 5), n1);
        try testing.expectEqual(@as(u64, 10), ctx.items.items[0]);
        try testing.expectEqual(@as(u64, 20), ctx.items.items[1]);
        try testing.expectEqual(@as(u64, 50), ctx.items.items[4]);
    }

    // next_expected is now 5, which is the timed_out slot.
    // Drain returns 0 and transitions to resetting.
    try testing.expect(buf.isResetting());

    {
        const items = try std.ArrayList(u64).initCapacity(testing.allocator, 16);
        var ctx = Ctx{ .allocator = testing.allocator, .items = items };
        defer ctx.items.deinit(testing.allocator);

        const n2 = buf.drain(&ctx, Ctx.onChunk);
        try testing.expectEqual(@as(usize, 0), n2); // nothing held to release
        try testing.expect(!buf.isResetting());
        try testing.expectEqual(@as(usize, 0), buf.filledCount());
    }
}

test "gap timeout at future position with held chunks — reset releases them" {
    var buf = try ReorderBuffer(u64).init(testing.allocator, 8);
    defer buf.deinit();

    try buf.insert(0, 10);
    try buf.insert(1, 20);
    try buf.insert(4, 400); // ahead; will be released on reset
    try buf.insert(5, 500);

    // Mark seq 2 as timed out (future position).
    buf.gapTimeout(2);

    const Ctx = struct {
        allocator: std.mem.Allocator,
        items: std.ArrayList(u64),
        fn onChunk(ctx: *@This(), _: SequenceNumber, val: *u64) void {
            ctx.items.append(ctx.allocator, val.*) catch @panic("OOM");
        }
    };

    {
        const items = try std.ArrayList(u64).initCapacity(testing.allocator, 16);
        var ctx = Ctx{ .allocator = testing.allocator, .items = items };
        defer ctx.items.deinit(testing.allocator);

        // Drain yields 0, 1.
        const n1 = buf.drain(&ctx, Ctx.onChunk);
        try testing.expectEqual(@as(usize, 2), n1);
        try testing.expectEqual(@as(u64, 10), ctx.items.items[0]);
        try testing.expectEqual(@as(u64, 20), ctx.items.items[1]);
    }

    // Now next_expected = 2, which is timed_out → resetting.
    try testing.expect(buf.isResetting());

    {
        const items = try std.ArrayList(u64).initCapacity(testing.allocator, 16);
        var ctx = Ctx{ .allocator = testing.allocator, .items = items };
        defer ctx.items.deinit(testing.allocator);

        // Reset-release: chunks 4 and 5 are released.
        const n2 = buf.drain(&ctx, Ctx.onChunk);
        try testing.expectEqual(@as(usize, 2), n2);
        try testing.expectEqual(@as(u64, 400), ctx.items.items[0]);
        try testing.expectEqual(@as(u64, 500), ctx.items.items[1]);

        try testing.expect(!buf.isResetting());
        try testing.expectEqual(@as(usize, 0), buf.filledCount());
    }
}

test "gap timeout past head with intervening insert — drains before reset" {
    var buf = try ReorderBuffer(u64).init(testing.allocator, 8);
    defer buf.deinit();

    try buf.insert(0, 10);
    try buf.insert(1, 20);
    buf.gapTimeout(3); // future position

    // Insert seq 2.
    try buf.insert(2, 30);

    const Ctx = struct {
        allocator: std.mem.Allocator,
        items: std.ArrayList(u64),
        fn onChunk(ctx: *@This(), _: SequenceNumber, val: *u64) void {
            ctx.items.append(ctx.allocator, val.*) catch @panic("OOM");
        }
    };
    const items = try std.ArrayList(u64).initCapacity(testing.allocator, 16);
    var ctx = Ctx{ .allocator = testing.allocator, .items = items };
    defer ctx.items.deinit(testing.allocator);

    // Drain yields 0, 1, 2; then hits timed_out at seq 3.
    const n = buf.drain(&ctx, Ctx.onChunk);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(u64, 10), ctx.items.items[0]);
    try testing.expectEqual(@as(u64, 20), ctx.items.items[1]);
    try testing.expectEqual(@as(u64, 30), ctx.items.items[2]);

    try testing.expect(buf.isResetting());
}

test "bound respected — out-of-window rejected" {
    var buf = try ReorderBuffer(u64).init(testing.allocator, 4);
    defer buf.deinit();

    // seq 0 fits: 0 < 0 + 4.
    try buf.insert(0, 10);

    // seq 4 is out-of-window: 4 >= 0 + 4.
    try testing.expectError(error.OutOfWindow, buf.insert(4, 40));

    // seq 3 fits at the boundary: 3 < 0 + 4.
    try buf.insert(3, 30);

    // Drain moves next_expected forward, making room.
    const Ctx = struct {
        allocator: std.mem.Allocator,
        items: std.ArrayList(u64),
        fn onChunk(ctx: *@This(), _: SequenceNumber, val: *u64) void {
            ctx.items.append(ctx.allocator, val.*) catch @panic("OOM");
        }
    };
    {
        const items = try std.ArrayList(u64).initCapacity(testing.allocator, 16);
        var ctx = Ctx{ .allocator = testing.allocator, .items = items };
        defer ctx.items.deinit(testing.allocator);
        _ = buf.drain(&ctx, Ctx.onChunk); // drains seq 0
    }

    // After draining seq 0, next_expected = 1.
    // seq 4: 4 < 1 + 4 = 5 → now fits.
    try buf.insert(4, 40);

    // seq 5: 5 >= 1 + 4 = 5 → out-of-window (boundary is exclusive).
    try testing.expectError(error.OutOfWindow, buf.insert(5, 50));
}

test "stale insert rejected" {
    var buf = try ReorderBuffer(u64).init(testing.allocator, 4);
    defer buf.deinit();

    try buf.insert(0, 10);

    // Drain seq 0.
    const Ctx = struct {
        allocator: std.mem.Allocator,
        items: std.ArrayList(u64),
        fn onChunk(ctx: *@This(), _: SequenceNumber, val: *u64) void {
            ctx.items.append(ctx.allocator, val.*) catch @panic("OOM");
        }
    };
    {
        const items = try std.ArrayList(u64).initCapacity(testing.allocator, 16);
        var ctx = Ctx{ .allocator = testing.allocator, .items = items };
        defer ctx.items.deinit(testing.allocator);
        _ = buf.drain(&ctx, Ctx.onChunk);
    }

    // seq 0 is now stale (behind next_expected = 1).
    try testing.expectError(error.Stale, buf.insert(0, 999));
}

test "duplicate insert rejected" {
    var buf = try ReorderBuffer(u64).init(testing.allocator, 4);
    defer buf.deinit();

    try buf.insert(1, 10);
    // Same slot, same seq (wraps to same index) → duplicate.
    try testing.expectError(error.Duplicate, buf.insert(1, 999));
}

test "insert during resetting rejected" {
    var buf = try ReorderBuffer(u64).init(testing.allocator, 4);
    defer buf.deinit();

    buf.reset();
    try testing.expect(buf.isResetting());
    try testing.expectError(error.Resetting, buf.insert(0, 10));
}

test "explicit reset releases held chunks" {
    var buf = try ReorderBuffer(u64).init(testing.allocator, 8);
    defer buf.deinit();

    try buf.insert(3, 300);
    try buf.insert(7, 700);

    buf.reset();
    try testing.expect(buf.isResetting());

    const Ctx = struct {
        allocator: std.mem.Allocator,
        items: std.ArrayList(u64),
        seqs: std.ArrayList(SequenceNumber),
        fn onChunk(ctx: *@This(), seq: SequenceNumber, val: *u64) void {
            ctx.items.append(ctx.allocator, val.*) catch @panic("OOM");
            ctx.seqs.append(ctx.allocator, seq) catch @panic("OOM");
        }
    };
    const items = try std.ArrayList(u64).initCapacity(testing.allocator, 16);
    const seqs = try std.ArrayList(SequenceNumber).initCapacity(testing.allocator, 16);
    var ctx = Ctx{ .allocator = testing.allocator, .items = items, .seqs = seqs };
    defer {
        ctx.items.deinit(testing.allocator);
        ctx.seqs.deinit(testing.allocator);
    }

    const n = buf.drain(&ctx, Ctx.onChunk);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u64, 300), ctx.items.items[0]);
    try testing.expectEqual(@as(u64, 700), ctx.items.items[1]);
    try testing.expectEqual(@as(SequenceNumber, 3), ctx.seqs.items[0]);
    try testing.expectEqual(@as(SequenceNumber, 7), ctx.seqs.items[1]);

    try testing.expect(!buf.isResetting());
    try testing.expectEqual(@as(usize, 0), buf.filledCount());

    // Buffer is clean and reusable.
    try buf.insert(0, 42);
    try testing.expectEqual(@as(usize, 1), buf.filledCount());
}

test "multiple drains before reset — partial progressive drain" {
    var buf = try ReorderBuffer(u64).init(testing.allocator, 8);
    defer buf.deinit();

    try buf.insert(0, 10);
    try buf.insert(2, 30);

    const Ctx = struct {
        allocator: std.mem.Allocator,
        items: std.ArrayList(u64),
        fn onChunk(ctx: *@This(), _: SequenceNumber, val: *u64) void {
            ctx.items.append(ctx.allocator, val.*) catch @panic("OOM");
        }
    };

    {
        const items = try std.ArrayList(u64).initCapacity(testing.allocator, 16);
        var ctx = Ctx{ .allocator = testing.allocator, .items = items };
        defer ctx.items.deinit(testing.allocator);

        // Only seq 0 is available.
        try testing.expectEqual(@as(usize, 1), buf.drain(&ctx, Ctx.onChunk));
        try testing.expectEqual(@as(u64, 10), ctx.items.items[0]);
    }

    // Insert seq 1.
    try buf.insert(1, 20);

    {
        const items = try std.ArrayList(u64).initCapacity(testing.allocator, 16);
        var ctx = Ctx{ .allocator = testing.allocator, .items = items };
        defer ctx.items.deinit(testing.allocator);

        // Drain yields 1 and 2.
        try testing.expectEqual(@as(usize, 2), buf.drain(&ctx, Ctx.onChunk));
        try testing.expectEqual(@as(u64, 20), ctx.items.items[0]);
        try testing.expectEqual(@as(u64, 30), ctx.items.items[1]);
    }

    try testing.expectEqual(@as(usize, 0), buf.filledCount());
}

test "wrap-around index collision — does not falsely drain" {
    var buf = try ReorderBuffer(u64).init(testing.allocator, 4);
    defer buf.deinit();

    // Insert seq 0 → slot[0].
    try buf.insert(0, 10);

    const Ctx = struct {
        allocator: std.mem.Allocator,
        items: std.ArrayList(u64),
        fn onChunk(ctx: *@This(), _: SequenceNumber, val: *u64) void {
            ctx.items.append(ctx.allocator, val.*) catch @panic("OOM");
        }
    };

    // Drain seq 0 → slot[0] freed, next_expected = 1.
    {
        const items = try std.ArrayList(u64).initCapacity(testing.allocator, 16);
        var ctx = Ctx{ .allocator = testing.allocator, .items = items };
        defer ctx.items.deinit(testing.allocator);
        _ = buf.drain(&ctx, Ctx.onChunk);
    }

    // Insert seq 4 → slot[0] again (4 % 4 = 0).
    // With next_expected = 1, seq 4 is within window (4 < 1 + 4 = 5).
    try buf.insert(4, 40);

    // seq 1 is the head (next_expected = 1). Slot[1] is free.
    // Drain gets nothing because slot[1] is free.
    // Crucially, it does NOT falsely drain slot[0] (seq 4 != next_expected).
    {
        const items = try std.ArrayList(u64).initCapacity(testing.allocator, 16);
        var ctx = Ctx{ .allocator = testing.allocator, .items = items };
        defer ctx.items.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), buf.drain(&ctx, Ctx.onChunk));
    }

    // Insert seq 1 → slot[1], seq 2 → slot[2], seq 3 → slot[3].
    try buf.insert(1, 20);
    try buf.insert(2, 30);
    try buf.insert(3, 50);

    // Drain yields 1, 2, 3 (slot[0] holds seq 4, not drained because
    // next_expected=1 != 4). Then next_expected = 4 and loop continues.
    // Now slot[0] holds seq 4 == next_expected → drained as well.
    // Total: 4 chunks.
    {
        const items = try std.ArrayList(u64).initCapacity(testing.allocator, 16);
        var ctx = Ctx{ .allocator = testing.allocator, .items = items };
        defer ctx.items.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 4), buf.drain(&ctx, Ctx.onChunk));
        try testing.expectEqual(@as(u64, 20), ctx.items.items[0]);
        try testing.expectEqual(@as(u64, 30), ctx.items.items[1]);
        try testing.expectEqual(@as(u64, 50), ctx.items.items[2]);
        try testing.expectEqual(@as(u64, 40), ctx.items.items[3]);
    }
}

test "gapTimeout silently ignores stale and out-of-window positions" {
    var buf = try ReorderBuffer(u64).init(testing.allocator, 4);
    defer buf.deinit();

    try buf.insert(0, 10);

    const Ctx = struct {
        allocator: std.mem.Allocator,
        items: std.ArrayList(u64),
        fn onChunk(ctx: *@This(), _: SequenceNumber, val: *u64) void {
            ctx.items.append(ctx.allocator, val.*) catch @panic("OOM");
        }
    };
    {
        const items = try std.ArrayList(u64).initCapacity(testing.allocator, 16);
        var ctx = Ctx{ .allocator = testing.allocator, .items = items };
        defer ctx.items.deinit(testing.allocator);
        _ = buf.drain(&ctx, Ctx.onChunk);
    }

    // next_expected = 1.
    // gapTimeout(0) is stale (0 < 1) — no-op.
    buf.gapTimeout(0);
    try testing.expect(!buf.isResetting());

    // gapTimeout(10) is out-of-window (10 >= 1 + 4) — no-op.
    buf.gapTimeout(10);
    try testing.expect(!buf.isResetting());
}

test "gapTimeout during resetting is no-op" {
    var buf = try ReorderBuffer(u64).init(testing.allocator, 4);
    defer buf.deinit();

    buf.reset();
    try testing.expect(buf.isResetting());

    // gapTimeout while already resetting — no-op.
    buf.gapTimeout(0);
    try testing.expect(buf.isResetting()); // still resetting
}
