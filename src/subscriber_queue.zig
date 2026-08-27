//! Bounded per-subscriber queue with explicit overflow signalling.
//!
//! Provides:
//!   - `SubscriberQueue(T)` — bounded circular buffer per subscriber
//!   - `push(item)` → PushResult (.ok | .full) — overflow is contract-gated
//!   - `pop()`  → PopResult (.item(T) | .discontinuity | .empty)
//!   - `drop_oldest()` → bool (true if an item was evicted)
//!
//! `drop_oldest()` records a discontinuity marker observable on the
//! next `pop()` call, signalling the subscriber that items were lost.
//!
//! NO importa native/zig/ — pure bounded buffer, no external dependencies
//! beyond `std`.

const std = @import("std");
const testing = std.testing;

// ---------------------------------------------------------------------------
// SubscriberQueue
// ---------------------------------------------------------------------------

/// Bounded per-subscriber queue with explicit overflow signalling.
///
/// Overflow is contract-gated: `push` returns `.full` instead of silently
/// dropping items. The caller must explicitly decide how to handle the full
/// condition (e.g., by calling `drop_oldest()` to evict the oldest item and
/// retrying the push).
///
/// `drop_oldest()` evicts the oldest (head) item and marks a
/// discontinuity. The next call to `pop()` returns `.discontinuity` before
/// any remaining items, so the subscriber is never silently starved.
pub fn SubscriberQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        // ------------------------------------------------------------------
        // Fields
        // ------------------------------------------------------------------

        allocator: std.mem.Allocator,
        /// Circular buffer of items.
        buf: []T,
        /// Index of the oldest (next-to-pop) item.
        head: usize,
        /// Index of the first free slot (next-to-push).
        tail: usize,
        /// Number of items currently in the queue.
        count: usize,
        /// Set when at least one item has been dropped via `drop_oldest`
        /// since the last `pop()`. Cleared after surfacing.
        discontinuity_flag: bool,

        // ------------------------------------------------------------------
        // Result types
        // ------------------------------------------------------------------

        /// Result of a push operation.
        pub const PushResult = union(enum) {
            ok: void,
            full: void,
        };

        /// Result of a pop operation.
        pub const PopResult = union(enum) {
            item: T,
            discontinuity: void,
            empty: void,
        };

        // ------------------------------------------------------------------
        // Lifecycle
        // ------------------------------------------------------------------

        /// Initialise a queue with the given capacity.
        ///
        /// The allocator is retained for `deinit`.
        pub fn init(allocator: std.mem.Allocator, cap: usize) !Self {
            const buf = try allocator.alloc(T, cap);
            return .{
                .allocator = allocator,
                .buf = buf,
                .head = 0,
                .tail = 0,
                .count = 0,
                .discontinuity_flag = false,
            };
        }

        /// Release all memory.
        ///
        /// Does NOT destruct stored values — caller must have consumed them
        /// via `pop` before deinitialising.
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buf);
        }

        // ------------------------------------------------------------------
        // Push
        // ------------------------------------------------------------------

        /// Push `item` into the queue.
        ///
        /// Returns `.ok` on success. Returns `.full` when the queue is at
        /// capacity — the caller must handle overflow explicitly (overflow
        /// contract-gated). A typical pattern is:
        ///
        /// ```zig
        /// if (queue.push(item) == .full) {
        ///     _ = queue.drop_oldest();
        ///     _ = queue.push(item); // guaranteed to succeed
        /// }
        /// ```
        pub fn push(self: *Self, item: T) PushResult {
            if (self.count == self.buf.len) return .{ .full = {} };
            self.buf[self.tail] = item;
            self.tail = (self.tail + 1) % self.buf.len;
            self.count += 1;
            return .{ .ok = {} };
        }

        // ------------------------------------------------------------------
        // Pop
        // ------------------------------------------------------------------

        /// Pop the oldest item from the queue.
        ///
        /// Returns `.discontinuity` first if `drop_oldest()` was called
        /// since the last `pop()`. After surfacing the discontinuity
        /// the flag is cleared and subsequent `pop()` calls return items
        /// normally.
        ///
        /// Returns `.empty` if the queue holds no items and no
        /// discontinuity marker is pending.
        pub fn pop(self: *Self) PopResult {
            if (self.discontinuity_flag) {
                self.discontinuity_flag = false;
                return .{ .discontinuity = {} };
            }
            if (self.count == 0) return .{ .empty = {} };
            const item = self.buf[self.head];
            self.head = (self.head + 1) % self.buf.len;
            self.count -= 1;
            return .{ .item = item };
        }

        // ------------------------------------------------------------------
        // Drop oldest
        // ------------------------------------------------------------------

        /// Drop the oldest item from the queue.
        ///
        /// The next `pop()` will return `.discontinuity` to signal that
        /// items were lost. Multiple calls to `drop_oldest()`
        /// between successive `pop()` calls coalesce into a single
        /// `.discontinuity` marker.
        ///
        /// Returns `true` if an item was evicted, `false` if the queue
        /// was empty and nothing was dropped.
        pub fn drop_oldest(self: *Self) bool {
            if (self.count == 0) return false;
            self.head = (self.head + 1) % self.buf.len;
            self.count -= 1;
            self.discontinuity_flag = true;
            return true;
        }

        // ------------------------------------------------------------------
        // Introspection
        // ------------------------------------------------------------------

        /// Capacity of the queue (maximum items it can hold).
        pub fn capacity(self: *const Self) usize {
            return self.buf.len;
        }

        /// Number of items currently in the queue.
        pub fn len(self: *const Self) usize {
            return self.count;
        }

        /// Whether a discontinuity marker is pending from a prior
        /// `drop_oldest()` that has not yet been surfaced by `pop()`.
        pub fn hasDiscontinuity(self: *const Self) bool {
            return self.discontinuity_flag;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "push and pop basic cycle" {
    var q = try SubscriberQueue(u64).init(testing.allocator, 4);
    defer q.deinit();

    try testing.expectEqual(@as(usize, 0), q.len());
    try testing.expectEqual(@as(usize, 4), q.capacity());

    // Push and pop in order.
    try testing.expectEqual(.ok, q.push(10));
    try testing.expectEqual(.ok, q.push(20));
    try testing.expectEqual(.ok, q.push(30));
    try testing.expectEqual(@as(usize, 3), q.len());

    {
        const r = q.pop();
        try testing.expect(r == .item);
        try testing.expectEqual(@as(u64, 10), r.item);
    }
    {
        const r = q.pop();
        try testing.expect(r == .item);
        try testing.expectEqual(@as(u64, 20), r.item);
    }
    {
        const r = q.pop();
        try testing.expect(r == .item);
        try testing.expectEqual(@as(u64, 30), r.item);
    }

    try testing.expectEqual(@as(usize, 0), q.len());
}

test "pop empty returns empty" {
    var q = try SubscriberQueue(u64).init(testing.allocator, 4);
    defer q.deinit();

    try testing.expectEqual(.empty, q.pop());
}

test "full queue push returns full" {
    var q = try SubscriberQueue(u64).init(testing.allocator, 3);
    defer q.deinit();

    try testing.expectEqual(.ok, q.push(1));
    try testing.expectEqual(.ok, q.push(2));
    try testing.expectEqual(.ok, q.push(3));

    // Queue is full — push must return .full.
    try testing.expectEqual(.full, q.push(4));
    try testing.expectEqual(.full, q.push(5));
    try testing.expectEqual(@as(usize, 3), q.len());
}

test "full queue overflow contract — drop oldest and retry" {
    var q = try SubscriberQueue(u64).init(testing.allocator, 3);
    defer q.deinit();

    try testing.expectEqual(.ok, q.push(1));
    try testing.expectEqual(.ok, q.push(2));
    try testing.expectEqual(.ok, q.push(3));

    // Overflow: drop the oldest and retry.
    if (q.push(4) == .full) {
        try testing.expect(q.drop_oldest()); // evicts 1
        try testing.expectEqual(.ok, q.push(4));
    }

    // Queue should contain [2, 3, 4] (1 was dropped).
    try testing.expectEqual(@as(usize, 3), q.len());

    // pop must surface discontinuity first.
    try testing.expectEqual(.discontinuity, q.pop());

    // Then the remaining items in order.
    {
        const r = q.pop();
        try testing.expect(r == .item);
        try testing.expectEqual(@as(u64, 2), r.item);
    }
    {
        const r = q.pop();
        try testing.expect(r == .item);
        try testing.expectEqual(@as(u64, 3), r.item);
    }
    {
        const r = q.pop();
        try testing.expect(r == .item);
        try testing.expectEqual(@as(u64, 4), r.item);
    }

    try testing.expectEqual(.empty, q.pop());
}

test "drop oldest with discontinuity marker" {
    var q = try SubscriberQueue(u64).init(testing.allocator, 4);
    defer q.deinit();

    try testing.expectEqual(.ok, q.push(10));
    try testing.expectEqual(.ok, q.push(20));
    try testing.expectEqual(.ok, q.push(30));

    // Drop the oldest (10).
    try testing.expect(q.drop_oldest());
    try testing.expect(q.hasDiscontinuity());
    try testing.expectEqual(@as(usize, 2), q.len());

    // A regular pop must NOT return the dropped item — it returns
    // .discontinuity first.
    try testing.expectEqual(.discontinuity, q.pop());
    try testing.expect(!q.hasDiscontinuity());

    // The remaining items (20, 30) are still available in order.
    {
        const r = q.pop();
        try testing.expect(r == .item);
        try testing.expectEqual(@as(u64, 20), r.item);
    }
    {
        const r = q.pop();
        try testing.expect(r == .item);
        try testing.expectEqual(@as(u64, 30), r.item);
    }

    try testing.expectEqual(.empty, q.pop());
}

test "multiple drop oldest coalesce into single discontinuity" {
    var q = try SubscriberQueue(u64).init(testing.allocator, 5);
    defer q.deinit();

    try testing.expectEqual(.ok, q.push(1));
    try testing.expectEqual(.ok, q.push(2));
    try testing.expectEqual(.ok, q.push(3));
    try testing.expectEqual(.ok, q.push(4));
    try testing.expectEqual(.ok, q.push(5));

    // Drop three items.
    try testing.expect(q.drop_oldest()); // drops 1
    try testing.expect(q.drop_oldest()); // drops 2
    try testing.expect(q.drop_oldest()); // drops 3

    try testing.expect(q.hasDiscontinuity());
    try testing.expectEqual(@as(usize, 2), q.len());

    // Single discontinuity marker.
    try testing.expectEqual(.discontinuity, q.pop());
    try testing.expect(!q.hasDiscontinuity());

    // Remaining items: 4, 5.
    {
        const r = q.pop();
        try testing.expect(r == .item);
        try testing.expectEqual(@as(u64, 4), r.item);
    }
    {
        const r = q.pop();
        try testing.expect(r == .item);
        try testing.expectEqual(@as(u64, 5), r.item);
    }

    try testing.expectEqual(.empty, q.pop());
}

test "drop oldest all items — discontinuity then empty" {
    var q = try SubscriberQueue(u64).init(testing.allocator, 3);
    defer q.deinit();

    try testing.expectEqual(.ok, q.push(10));
    try testing.expectEqual(.ok, q.push(20));
    try testing.expectEqual(.ok, q.push(30));

    // Drop all three items.
    try testing.expect(q.drop_oldest()); // drops 10
    try testing.expect(q.drop_oldest()); // drops 20
    try testing.expect(q.drop_oldest()); // drops 30

    try testing.expectEqual(@as(usize, 0), q.len());
    try testing.expect(q.hasDiscontinuity());

    // Discontinuity surfaces even though queue is empty.
    try testing.expectEqual(.discontinuity, q.pop());
    try testing.expectEqual(.empty, q.pop());
}

test "empty drop oldest returns false" {
    var q = try SubscriberQueue(u64).init(testing.allocator, 4);
    defer q.deinit();

    try testing.expect(!q.drop_oldest());
    try testing.expect(!q.hasDiscontinuity());
    try testing.expectEqual(@as(usize, 0), q.len());
}

test "discontinuity surfaces before items pushed after drop" {
    var q = try SubscriberQueue(u64).init(testing.allocator, 3);
    defer q.deinit();

    try testing.expectEqual(.ok, q.push(1));
    try testing.expectEqual(.ok, q.push(2));
    try testing.expectEqual(.ok, q.push(3));

    try testing.expect(q.drop_oldest()); // drops 1

    // Push new items after the drop.
    try testing.expectEqual(.ok, q.push(4)); // tail slot re-used
    try testing.expectEqual(@as(usize, 3), q.len());

    // Discontinuity surfaces before 2, 3, 4.
    try testing.expectEqual(.discontinuity, q.pop());

    {
        const r = q.pop();
        try testing.expect(r == .item);
        try testing.expectEqual(@as(u64, 2), r.item);
    }
    {
        const r = q.pop();
        try testing.expect(r == .item);
        try testing.expectEqual(@as(u64, 3), r.item);
    }
    {
        const r = q.pop();
        try testing.expect(r == .item);
        try testing.expectEqual(@as(u64, 4), r.item);
    }
}

test "wrap-around ring buffer behaviour" {
    var q = try SubscriberQueue(u64).init(testing.allocator, 3);
    defer q.deinit();

    // Fill [A, B, C].
    try testing.expectEqual(.ok, q.push(10));
    try testing.expectEqual(.ok, q.push(20));
    try testing.expectEqual(.ok, q.push(30));

    // Pop A and B so head/tail advance, then push D and E to wrap tail.
    try testing.expectEqual(@as(u64, 10), q.pop().item);
    try testing.expectEqual(@as(u64, 20), q.pop().item);

    try testing.expectEqual(.ok, q.push(40)); // wraps tail to slot 0
    try testing.expectEqual(.ok, q.push(50)); // wraps tail to slot 1

    // Queue now: C, D, E.
    try testing.expectEqual(@as(usize, 3), q.len());

    try testing.expectEqual(@as(u64, 30), q.pop().item);
    try testing.expectEqual(@as(u64, 40), q.pop().item);
    try testing.expectEqual(@as(u64, 50), q.pop().item);
    try testing.expectEqual(.empty, q.pop());
}

test "wrap around with drop oldest and discontinuity" {
    var q = try SubscriberQueue(u64).init(testing.allocator, 3);
    defer q.deinit();

    // Fill [A, B, C].
    try testing.expectEqual(.ok, q.push(10));
    try testing.expectEqual(.ok, q.push(20));
    try testing.expectEqual(.ok, q.push(30));

    // Pop A, B so head = 2, tail = 0 (wrapped).
    try testing.expectEqual(@as(u64, 10), q.pop().item);
    try testing.expectEqual(@as(u64, 20), q.pop().item);

    // Push D, E so tail = 2 (wrapped back to where head is).
    try testing.expectEqual(.ok, q.push(40)); // slot 0
    try testing.expectEqual(.ok, q.push(50)); // slot 1

    try testing.expectEqual(.full, q.push(60));

    // Drop oldest (C=30 at head=2). Head wraps to 0, tail=2, count=2.
    try testing.expect(q.drop_oldest());
    try testing.expect(q.hasDiscontinuity());

    // Push F into the freed slot at tail=2.
    try testing.expectEqual(.ok, q.push(60));
    // Queue: [D=40 (slot 0), E=50 (slot 1), F=60 (slot 2)].

    // Discontinuity surfaces first.
    try testing.expectEqual(.discontinuity, q.pop());

    // Then D, E, F in order.
    try testing.expectEqual(@as(u64, 40), q.pop().item);
    try testing.expectEqual(@as(u64, 50), q.pop().item);
    try testing.expectEqual(@as(u64, 60), q.pop().item);

    try testing.expectEqual(.empty, q.pop());
}
