//! Integration test for HungWorkerWatchdog in a concurrent worker scenario.
//!
//! Tests:
//!   - `test watchdog flags hung worker within bound`: a worker that stops
//!     petting the watchdog triggers .hung before the deadline.
//!   - `test watchdog does not flag fast worker`: a worker that pets the
//!     watchdog within the bound never triggers .hung.

const std = @import("std");
const testing = std.testing;
const HungWorkerWatchdog = @import("watchdog.zig").HungWorkerWatchdog;
const WatchdogStatus = @import("watchdog.zig").WatchdogStatus;

// ---------------------------------------------------------------------------
// nanosleep helper
// ---------------------------------------------------------------------------

fn nanosleep(ns: u64) void {
    var req = std.c.timespec{
        .sec = @as(std.c.time_t, @intCast(ns / std.time.ns_per_s)),
        .nsec = @as(c_long, @intCast(ns % std.time.ns_per_s)),
    };
    while (std.c.nanosleep(&req, &req) < 0) {
        if (std.c.errno(-1) != .INTR) break;
    }
}

// ---------------------------------------------------------------------------
// Fast worker test
// ---------------------------------------------------------------------------

test "watchdog does not flag fast worker" {
    // A worker that pets the watchdog within the bound must never trigger
    // a .hung status.
    //
    // Spawn a worker that does "work" (short delay) then pets the watchdog
    // every iteration. A separate checker thread periodically checks the
    // watchdog status. After several iterations, both threads stop and the
    // checker must never have observed .hung.

    var wd = HungWorkerWatchdog.init();

    const BOUND_MS: u64 = 100; // 100 ms bound
    const PET_INTERVAL_MS: u64 = 20; // worker pets every 20 ms
    const CHECK_INTERVAL_MS: u64 = 30; // checker checks every 30 ms
    const ITERATIONS: usize = 8;

    // Signals for thread coordination.
    var stop_flag = std.atomic.Value(bool).init(false);
    var checker_saw_hung = std.atomic.Value(bool).init(false);

    wd.start(BOUND_MS);

    // Worker thread: simulates a fast worker that pets regularly.
    const worker = try std.Thread.spawn(.{}, struct {
        fn run(w: *HungWorkerWatchdog, stop: *std.atomic.Value(bool)) void {
            while (!stop.load(.acquire)) {
                // Simulate doing some work.
                nanosleep(PET_INTERVAL_MS * std.time.ns_per_ms);
                // Pet the watchdog to indicate progress.
                w.pet();
            }
        }
    }.run, .{ &wd, &stop_flag });

    // Checker thread: periodically checks the watchdog status.
    const checker = try std.Thread.spawn(.{}, struct {
        fn run(
            w: *HungWorkerWatchdog,
            stop: *std.atomic.Value(bool),
            saw_hung: *std.atomic.Value(bool),
        ) void {
            var i: usize = 0;
            while (i < ITERATIONS and !stop.load(.acquire)) : (i += 1) {
                nanosleep(CHECK_INTERVAL_MS * std.time.ns_per_ms);
                if (w.check() == .hung) {
                    saw_hung.store(true, .release);
                }
            }
        }
    }.run, .{ &wd, &stop_flag, &checker_saw_hung });

    // Wait for checker to complete its iterations.
    checker.join();

    // Signal the worker to stop and join.
    stop_flag.store(true, .release);
    worker.join();

    // The checker must never have observed .hung — the worker was fast
    // and petting within the bound.
    try testing.expect(!checker_saw_hung.load(.acquire));
}

// ---------------------------------------------------------------------------
// Hung worker test
// ---------------------------------------------------------------------------

test "watchdog flags hung worker within bound" {
    // A worker that stops petting must trigger .hung within the bound.
    //
    // Spawn a worker that pets a few times, then stops (simulating a hang).
    // A checker thread waits long enough for the bound to expire and checks
    // that the watchdog reports .hung.

    var wd = HungWorkerWatchdog.init();

    const BOUND_MS: u64 = 50; // 50 ms bound — tight but not racy
    const WORK_DURATION_MS: u64 = 200; // wait well past the bound

    // Start with a short bound.
    wd.start(BOUND_MS);

    // Pet once to establish the baseline deadline.
    wd.pet();

    // Wait long enough that the bound expires (4x the bound).
    nanosleep(WORK_DURATION_MS * std.time.ns_per_ms);

    // The watchdog must report .hung — the worker stopped petting and
    // the deadline elapsed.
    try testing.expectEqual(WatchdogStatus.hung, wd.check());
}

// ---------------------------------------------------------------------------
// Edge cases
// ---------------------------------------------------------------------------

test "watchdog ok before start" {
    // A watchdog that was never started must report .ok.
    var wd = HungWorkerWatchdog.init();
    try testing.expectEqual(WatchdogStatus.ok, wd.check());
}

test "watchdog ok after reset" {
    // After resetting a watchdog that had timed out, it must return .ok.
    var wd = HungWorkerWatchdog.init();

    wd.start(10); // 10 ms bound
    nanosleep(100 * std.time.ns_per_ms);
    try testing.expectEqual(WatchdogStatus.hung, wd.check());

    wd.reset();
    try testing.expectEqual(WatchdogStatus.ok, wd.check());
}

test "watchdog ok with frequent pet" {
    // A worker that pets MORE frequently than the bound must never trigger
    // .hung, verified over multiple cycles.
    var wd = HungWorkerWatchdog.init();

    const BOUND_MS: u64 = 200;
    const PET_INTERVAL_MS: u64 = 30; // pet 6x within the bound

    wd.start(BOUND_MS);

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        nanosleep(PET_INTERVAL_MS * std.time.ns_per_ms);
        wd.pet();
        try testing.expectEqual(WatchdogStatus.ok, wd.check());
    }
}
