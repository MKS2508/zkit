//! Reorder-buffer stall bound tests (H-D2).
//!
//! The reorder buffer's `bound` defines the maximum window size / max gap:
//! no more than `bound` chunks can ever be held simultaneously. A lost chunk
//! (gap timeout) at or reached by the head forces an immediate reset, releasing
//! all held chunks. The buffer is NOT a stall vector — terminal semantics
//! guarantee that a permanently lost chunk causes completions to be released
//! within the documented bound.
//!
//! This test defines the stall bound as the `bound` parameter of the reorder
//! buffer and applies it across several scenarios:
//!
//!   1. Permanent head loss with buffer full up to bound-1 — all released.
//!   2. Bound enforcement: out-of-window inserts rejected.
//!   3. Gap marker within bound — drain reaches it, reset releases remainder.
//!   4. Wrap-around: seq `bound` at same index as seq 0, no false drain.
//!   5. Maximum held = bound — buffer is full at boundary, not beyond.
//!   6. Post-reset reuse — same bound applies after clean.
//!   7. GapTimeout head loss with partial fill at window edge.

const std = @import("std");
const testing = std.testing;
const ReorderBuffer = @import("reorder_buffer.zig").ReorderBuffer;
const SequenceNumber = @import("reorder_buffer.zig").SequenceNumber;

// ---------------------------------------------------------------------------
// Stall bound constant
// ---------------------------------------------------------------------------

/// The stall bound for these tests.
/// This is the `bound` parameter of the reorder buffer — the maximum window
/// size / max gap. Within this bound, a permanently lost chunk triggers
/// release of all held completions (terminal semantics). The buffer never
/// stalls waiting for chunks beyond this bound.
///
/// Using a small prime power gives room for wrap-around tests (seq >= BOUND
/// lands at index `seq % BOUND`).
const BOUND: usize = 8;

// ---------------------------------------------------------------------------
// Test context helpers
// ---------------------------------------------------------------------------

/// Test context that collects drained chunks and their sequence numbers.
const DrainCtx = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(u64),
    seqs: std.ArrayList(SequenceNumber),

    fn init(allocator: std.mem.Allocator) DrainCtx {
        return .{
            .allocator = allocator,
            .items = std.ArrayList(u64).initCapacity(allocator, 32) catch @panic("OOM"),
            .seqs = std.ArrayList(SequenceNumber).initCapacity(allocator, 32) catch @panic("OOM"),
        };
    }

    fn deinit(self: *DrainCtx) void {
        self.items.deinit(self.allocator);
        self.seqs.deinit(self.allocator);
    }

    fn onChunk(ctx: *DrainCtx, seq: SequenceNumber, val: *u64) void {
        ctx.items.append(ctx.allocator, val.*) catch @panic("OOM");
        ctx.seqs.append(ctx.allocator, seq) catch @panic("OOM");
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "H-D2: permanent head loss with buffer full up to bound-1" {
    // Fill slots 1..BOUND-1 out of order, then lose seq 0 at head.
    // All held chunks must be released within the bound.
    var buf = try ReorderBuffer(u64).init(testing.allocator, BOUND);
    defer buf.deinit();

    // Insert seq 1 through BOUND-1 (out of order, leaving seq 0 missing).
    var i: SequenceNumber = 1;
    while (i < BOUND) : (i += 1) {
        try buf.insert(i, @intCast(i * 10));
    }

    // Verify filled count: BOUND - 1 chunks held.
    try testing.expectEqual(@as(usize, BOUND - 1), buf.filledCount());

    // Seq 0 times out at head → immediate reset.
    buf.gapTimeout(0);
    try testing.expect(buf.isResetting());

    // Drain releases all BOUND - 1 chunks.
    var ctx = DrainCtx.init(testing.allocator);
    defer ctx.deinit();

    const n = buf.drain(&ctx, DrainCtx.onChunk);
    // All held chunks from seq 1..BOUND-1 are released.
    try testing.expectEqual(@as(usize, BOUND - 1), n);

    // Verify contents: each released chunk matches its sequence mapping.
    var j: usize = 0;
    var seq_val: SequenceNumber = 1;
    while (seq_val < BOUND) : (seq_val += 1) {
        try testing.expectEqual(seq_val * 10, ctx.items.items[j]);
        try testing.expectEqual(seq_val, ctx.seqs.items[j]);
        j += 1;
    }

    // Buffer is clean after reset.
    try testing.expect(!buf.isResetting());
    try testing.expectEqual(@as(usize, 0), buf.filledCount());
    try testing.expectEqual(@as(SequenceNumber, 0), buf.next_expected);
}

test "H-D2: bound enforcement — out-of-window inserts rejected" {
    // Verify the bound is enforced: seq >= next_expected + BOUND is rejected.
    var buf = try ReorderBuffer(u64).init(testing.allocator, BOUND);
    defer buf.deinit();

    // Seq 0 fits (0 < 0 + BOUND).
    try buf.insert(0, 10);

    // Seq BOUND is at the exclusive edge: BOUND >= 0 + BOUND → out.
    try testing.expectError(error.OutOfWindow, buf.insert(BOUND, 99));

    // Seq BOUND - 1 fits (BOUND - 1 < 0 + BOUND).
    try buf.insert(BOUND - 1, 80);

    // Drain seq 0 → next_expected becomes 1, window slides.
    var ctx = DrainCtx.init(testing.allocator);
    defer ctx.deinit();

    _ = buf.drain(&ctx, DrainCtx.onChunk);
    try testing.expectEqual(@as(usize, 1), ctx.items.items.len);
    try testing.expectEqual(@as(u64, 10), ctx.items.items[0]);

    // After drain: next_expected = 1. Now BOUND is in window:
    //   BOUND = 8 < 1 + 8 = 9 → fits.
    try buf.insert(BOUND, 90);

    // seq BOUND + 1 = 9: 9 >= 1 + 8 = 9 → out.
    try testing.expectError(error.OutOfWindow, buf.insert(BOUND + 1, 999));
}

test "H-D2: gap marker within bound — drain reaches it, reset releases remainder" {
    // Insert seq 0..3, mark seq 4 as timed out (within bound).
    // Drain yields 0..3, then hits timed_out at seq 4 → resetting.
    // A second drain releases any remaining chunks (none in this case).
    var buf = try ReorderBuffer(u64).init(testing.allocator, BOUND);
    defer buf.deinit();

    try buf.insert(0, 10);
    try buf.insert(1, 20);
    try buf.insert(2, 30);
    try buf.insert(3, 40);

    // Seq 5 is also inserted (ahead of the gap) — should be released on reset.
    try buf.insert(5, 500);

    // Gap at seq 4 — within bound, not yet at head.
    buf.gapTimeout(4);

    // Drain yields 0, 1, 2, 3 (contiguous from head), stops at 4 (timed_out).
    {
        var ctx = DrainCtx.init(testing.allocator);
        defer ctx.deinit();

        const n1 = buf.drain(&ctx, DrainCtx.onChunk);
        try testing.expectEqual(@as(usize, 4), n1);
        try testing.expectEqual(@as(u64, 10), ctx.items.items[0]);
        try testing.expectEqual(@as(u64, 40), ctx.items.items[3]);
    }

    // Buffer is now resetting (timed_out at head position 4).
    try testing.expect(buf.isResetting());

    // Second drain: reset-release path frees the held seq 5.
    {
        var ctx = DrainCtx.init(testing.allocator);
        defer ctx.deinit();

        const n2 = buf.drain(&ctx, DrainCtx.onChunk);
        try testing.expectEqual(@as(usize, 1), n2);
        try testing.expectEqual(@as(u64, 500), ctx.items.items[0]);
        try testing.expectEqual(@as(SequenceNumber, 5), ctx.seqs.items[0]);
    }

    // Buffer is clean.
    try testing.expect(!buf.isResetting());
    try testing.expectEqual(@as(usize, 0), buf.filledCount());
}

test "H-D2: maximum held chunks equals bound — no more accepted" {
    // Fill all BOUND slots. The window `[next_expected, next_expected + bound)`
    // prevents any seq >= next_expected + BOUND from being inserted. With
    // next_expected = 0, seq BOUND is at the exclusive window edge → rejected.
    // This verifies the buffer can never hold more than `bound` chunks.
    var buf = try ReorderBuffer(u64).init(testing.allocator, BOUND);
    defer buf.deinit();

    // Insert seq 0..BOUND-1 (fills every slot at unique indices).
    var i: SequenceNumber = 0;
    while (i < BOUND) : (i += 1) {
        try buf.insert(i, @intCast(i * 10));
    }

    try testing.expectEqual(BOUND, buf.filledCount());

    // seq BOUND is at the window's trailing edge: BOUND >= 0 + BOUND.
    // The window check fires first (before the duplicate collision check),
    // so the insert returns OutOfWindow, NOT Duplicate.
    try testing.expectError(error.OutOfWindow, buf.insert(BOUND, 999));

    // Drain all contiguous chunks (0..BOUND-1, all present). After drain,
    // next_expected = BOUND, all slots free.
    {
        var ctx = DrainCtx.init(testing.allocator);
        defer ctx.deinit();
        try testing.expectEqual(BOUND, buf.drain(&ctx, DrainCtx.onChunk));
    }

    try testing.expectEqual(@as(usize, 0), buf.filledCount());
    try testing.expectEqual(@as(SequenceNumber, BOUND), buf.next_expected);

    // Window is now [BOUND, BOUND + BOUND). seq BOUND is within window.
    try buf.insert(BOUND, @intCast(BOUND * 10));
    try testing.expectEqual(@as(usize, 1), buf.filledCount());

    // Fill from BOUND+1 up to 2*BOUND-1 (total BOUND held).
    var j: SequenceNumber = BOUND + 1;
    while (j < 2 * BOUND) : (j += 1) {
        try buf.insert(j, @intCast(j * 10));
    }
    try testing.expectEqual(BOUND, buf.filledCount());

    // seq 2*BOUND is at the new window edge: 2*BOUND >= BOUND + BOUND → out.
    try testing.expectError(error.OutOfWindow, buf.insert(2 * BOUND, 999));
}

test "H-D2: wrap-around index collision — seq BOUND at same index as seq 0" {
    // When next_expected advances past seq 0, seq BOUND (BOUND % BOUND == 0)
    // can be inserted at the same slot. Drain must check the seq field to
    // NOT falsely drain a slot that holds a different seq.
    var buf = try ReorderBuffer(u64).init(testing.allocator, BOUND);
    defer buf.deinit();

    try buf.insert(0, 10); // slot[0]

    // Drain seq 0 → slot[0] freed, next_expected = 1.
    {
        var ctx = DrainCtx.init(testing.allocator);
        defer ctx.deinit();
        _ = buf.drain(&ctx, DrainCtx.onChunk);
    }

    // Insert seq BOUND → slot[0] again (BOUND % 8 = 0).
    // With next_expected = 1, BOUND is within window: BOUND < 1 + 8 = 9.
    try buf.insert(BOUND, @intCast(BOUND * 10));

    // Seq 1 is head (next_expected = 1). Slot[1] is free.
    // Drain gets nothing because slot[1] is free.
    // It must NOT falsely drain slot[0] (seq BOUND != next_expected = 1).
    {
        var ctx = DrainCtx.init(testing.allocator);
        defer ctx.deinit();
        try testing.expectEqual(@as(usize, 0), buf.drain(&ctx, DrainCtx.onChunk));
    }

    // Insert seq 1..BOUND-1 to fill remaining slots.
    var i: SequenceNumber = 1;
    while (i < BOUND) : (i += 1) {
        try buf.insert(i, @intCast(i * 10));
    }

    // Drain yields 1..BOUND-1 (slot[0] holds seq BOUND != next_expected=1,
    // so it is skipped initially). Then next_expected advances to BOUND,
    // and slot[0]'s seq BOUND now matches next_expected → drained.
    {
        var ctx = DrainCtx.init(testing.allocator);
        defer ctx.deinit();
        const n = buf.drain(&ctx, DrainCtx.onChunk);
        // BOUND chunks drained: 1, 2, ..., BOUND-1, BOUND
        try testing.expectEqual(BOUND, n);

        // First drained is seq 1.
        try testing.expectEqual(@as(u64, 10), ctx.items.items[0]);
        try testing.expectEqual(@as(SequenceNumber, 1), ctx.seqs.items[0]);

        // Last drained is seq BOUND.
        try testing.expectEqual(@as(u64, BOUND * 10), ctx.items.items[BOUND - 1]);
        try testing.expectEqual(@as(SequenceNumber, BOUND), ctx.seqs.items[BOUND - 1]);
    }

    try testing.expectEqual(@as(usize, 0), buf.filledCount());
}

test "H-D2: post-reset reuse — same bound applies" {
    // After a gap-timeout reset, the buffer must be fully reusable:
    // next_expected = 0, all slots free, and inserts obey the same bound.
    var buf = try ReorderBuffer(u64).init(testing.allocator, BOUND);
    defer buf.deinit();

    // Insert some chunks, lose head.
    try buf.insert(2, 20);
    try buf.insert(3, 30);
    buf.gapTimeout(0); // head lost → resetting

    // Drain to release held chunks.
    {
        var ctx = DrainCtx.init(testing.allocator);
        defer ctx.deinit();
        _ = buf.drain(&ctx, DrainCtx.onChunk);
    }

    try testing.expect(!buf.isResetting());
    try testing.expectEqual(@as(SequenceNumber, 0), buf.next_expected);
    try testing.expectEqual(@as(usize, 0), buf.filledCount());

    // Buffer is reusable: insert from seq 0.
    try buf.insert(0, 100);
    try buf.insert(1, 200);
    try buf.insert(BOUND - 1, 800); // fits: BOUND-1 < 0 + BOUND

    // Out-of-window still rejected.
    try testing.expectError(error.OutOfWindow, buf.insert(BOUND, 999));

    // Drain works after reuse.
    {
        var ctx = DrainCtx.init(testing.allocator);
        defer ctx.deinit();
        const n = buf.drain(&ctx, DrainCtx.onChunk);
        try testing.expectEqual(@as(usize, 2), n); // seq 0, 1
    }

    // Complete drain of seq BOUND-1.
    {
        var ctx = DrainCtx.init(testing.allocator);
        defer ctx.deinit();
        _ = buf.drain(&ctx, DrainCtx.onChunk);
    }
}

test "H-D2: gapTimeout head loss with partial fill at window edge" {
    // Scenario that stresses the bound edge:
    //   - seq 0 is lost (gapTimeout at head → immediate reset)
    //   - seq BOUND - 1 is held (last slot within window)
    //   - seq BOUND is out of window (not yet accepted)
    //
    // After the reset, all held chunks (just seq BOUND-1) are released.
    // seq BOUND was never accepted — it was beyond the bound at the time.
    var buf = try ReorderBuffer(u64).init(testing.allocator, BOUND);
    defer buf.deinit();

    // Insert at the far edge of the window: seq BOUND - 1.
    try buf.insert(BOUND - 1, @intCast((BOUND - 1) * 10));

    // Seq BOUND is out of window (BOUND >= 0 + BOUND).
    try testing.expectError(error.OutOfWindow, buf.insert(BOUND, 999));

    // Lose seq 0 at head → immediate reset.
    buf.gapTimeout(0);
    try testing.expect(buf.isResetting());

    // Drain releases the held seq BOUND-1.
    {
        var ctx = DrainCtx.init(testing.allocator);
        defer ctx.deinit();
        const n = buf.drain(&ctx, DrainCtx.onChunk);
        try testing.expectEqual(@as(usize, 1), n);
        try testing.expectEqual(@as(u64, (BOUND - 1) * 10), ctx.items.items[0]);
        try testing.expectEqual(@as(SequenceNumber, BOUND - 1), ctx.seqs.items[0]);
    }

    // Buffer clean.
    try testing.expect(!buf.isResetting());
    try testing.expectEqual(@as(usize, 0), buf.filledCount());
}

test "H-D2: multiple drains before reset — progressive release within bound" {
    // Insert seq sequences that can only be partially drained due to gaps,
    // demonstrating progressive release within the bound.
    var buf = try ReorderBuffer(u64).init(testing.allocator, BOUND);
    defer buf.deinit();

    // Insert seq 0 and seq 2 (seq 1 missing).
    try buf.insert(0, 10);
    try buf.insert(2, 30);

    // Drain yields seq 0 only. Seq 2 stays.
    {
        var ctx = DrainCtx.init(testing.allocator);
        defer ctx.deinit();
        try testing.expectEqual(@as(usize, 1), buf.drain(&ctx, DrainCtx.onChunk));
        try testing.expectEqual(@as(u64, 10), ctx.items.items[0]);
    }

    // Insert seq 1 → now seq 1 and 2 are contiguous → drain both.
    try buf.insert(1, 20);

    {
        var ctx = DrainCtx.init(testing.allocator);
        defer ctx.deinit();
        try testing.expectEqual(@as(usize, 2), buf.drain(&ctx, DrainCtx.onChunk));
        try testing.expectEqual(@as(u64, 20), ctx.items.items[0]);
        try testing.expectEqual(@as(u64, 30), ctx.items.items[1]);
    }

    // Buffer is empty after progressive drain.
    try testing.expectEqual(@as(usize, 0), buf.filledCount());
    try testing.expectEqual(@as(SequenceNumber, 3), buf.next_expected);
}

test "H-D2: stall bound documented constant is applied explicitly" {
    // The stall bound is `BOUND`. This test verifies the constant is set
    // and that the buffer's bound method returns the same value.
    //
    // This is a structural assertion: any change to BOUND must be
    // intentional and all tests in this file apply the same bound.
    try testing.expectEqual(@as(usize, 8), BOUND);

    var buf = try ReorderBuffer(u64).init(testing.allocator, BOUND);
    defer buf.deinit();

    try testing.expectEqual(BOUND, buf.getBound());
    try testing.expectEqual(@as(usize, 0), buf.filledCount());

    // After inserting seq 0..BOUND-1 (one per slot), filled = bound.
    var i: SequenceNumber = 0;
    while (i < BOUND) : (i += 1) {
        try buf.insert(i, @intCast(i));
    }
    try testing.expectEqual(BOUND, buf.filledCount());
    try testing.expectEqual(BOUND, buf.getBound());
}
