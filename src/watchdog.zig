//! HungWorkerWatchdog with bound timer and atomic status.
//!
//! Provides:
//!   - WatchdogStatus — ok / hung
//!   - HungWorkerWatchdog — deadline-based watchdog with pet() and reset()
//!
//! Thread-safe: all mutable state is atomic. The worker calls pet() to
//! extend the deadline; check() returns hung if the deadline has passed.

const std = @import("std");
const testing = std.testing;

// ---------------------------------------------------------------------------
// WatchdogStatus
// ---------------------------------------------------------------------------

/// Result of a HungWorkerWatchdog check.
pub const WatchdogStatus = enum {
    /// Worker has been making progress — deadline has not elapsed.
    ok,
    /// Worker has not checked in within the bound — deemed hung.
    hung,
};

// ---------------------------------------------------------------------------
// HungWorkerWatchdog
// ---------------------------------------------------------------------------

/// A deadline-based watchdog that detects hung workers.
///
/// Usage:
///   var wd = HungWorkerWatchdog.init();
///   wd.start(5000);                  // 5-second bound
///   // ... in worker loop ...
///   wd.pet();                        // extend the deadline
///   // ... in monitor thread ...
///   if (wd.check() == .hung) { ... }
///   wd.reset();                      // re-arm
///
/// Thread-safe: all fields are atomics. No external synchronisation needed.
pub const HungWorkerWatchdog = struct {
    /// Absolute monotonic deadline in milliseconds. 0 means "not started".
    deadline: std.atomic.Value(i64),
    /// Whether start() has been called.
    started: std.atomic.Value(bool),
    /// The bound duration in milliseconds (stored for pet()).
    bound_ms: std.atomic.Value(u64),

    pub fn init() HungWorkerWatchdog {
        return .{
            .deadline = std.atomic.Value(i64).init(0),
            .started = std.atomic.Value(bool).init(false),
            .bound_ms = std.atomic.Value(u64).init(0),
        };
    }

    /// Arm the watchdog with a timeout of `bound_ms` milliseconds.
    ///
    /// The deadline is set to `now + bound_ms`. After this, the worker must
    /// call `pet()` before the deadline elapses, or `check()` will return
    /// `.hung`.
    pub fn start(self: *HungWorkerWatchdog, bound_ms: u64) void {
        self.bound_ms.store(bound_ms, .release);
        const deadline = nowMs() + @as(i64, @intCast(bound_ms));
        self.deadline.store(deadline, .release);
        self.started.store(true, .release);
    }

    /// Reset the deadline to `now + bound_ms`.
    ///
    /// Called periodically by the worker to signal "still alive".
    pub fn pet(self: *HungWorkerWatchdog) void {
        const bound = self.bound_ms.load(.acquire);
        const deadline = nowMs() + @as(i64, @intCast(bound));
        self.deadline.store(deadline, .release);
    }

    /// Check whether the watchdog has timed out.
    ///
    /// Returns `.hung` if the deadline has elapsed (i.e., the worker has not
    /// called `pet()` in time). Returns `.ok` if the watchdog was never
    /// started, or if the deadline is still in the future.
    pub fn check(self: *HungWorkerWatchdog) WatchdogStatus {
        if (!self.started.load(.acquire)) return .ok;
        if (nowMs() > self.deadline.load(.acquire)) {
            return .hung;
        }
        return .ok;
    }

    /// Reset to the initial (unstarted) state.
    ///
    /// After calling `reset()`, `check()` returns `.ok` until `start()` is
    /// called again.
    pub fn reset(self: *HungWorkerWatchdog) void {
        self.started.store(false, .release);
        self.deadline.store(0, .release);
        self.bound_ms.store(0, .release);
    }
};

// ---------------------------------------------------------------------------
// Time helper
// ---------------------------------------------------------------------------

/// Monotonic clock in milliseconds.
fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 +
        @as(i64, @intCast(@as(u64, @intCast(ts.nsec)) / 1_000_000));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "watchdog returns ok when worker is fast" {
    var wd = HungWorkerWatchdog.init();

    // Start with a generous 5-second bound.
    wd.start(5000);

    // Pet immediately — deadline is far in the future.
    wd.pet();

    // Check right away — should be ok.
    try testing.expectEqual(WatchdogStatus.ok, wd.check());
}

test "watchdog returns hung when worker is slow" {
    var wd = HungWorkerWatchdog.init();

    // Very tight bound.
    wd.start(10);

    // Wait 10x the bound to guarantee expiry.
    var req = std.c.timespec{
        .sec = 0,
        .nsec = @as(c_long, 100 * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&req, null);

    try testing.expectEqual(WatchdogStatus.hung, wd.check());
}

test "watchdog reset clears hung state" {
    var wd = HungWorkerWatchdog.init();

    // Tight bound, let it expire.
    wd.start(10);
    var req = std.c.timespec{
        .sec = 0,
        .nsec = @as(c_long, 100 * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&req, null);

    try testing.expectEqual(WatchdogStatus.hung, wd.check());

    // Reset — should return to ok.
    wd.reset();
    try testing.expectEqual(WatchdogStatus.ok, wd.check());
}

test "watchdog returns ok before start" {
    var wd = HungWorkerWatchdog.init();

    // Never started → must return ok.
    try testing.expectEqual(WatchdogStatus.ok, wd.check());
}

test "watchdog pet extends deadline" {
    var wd = HungWorkerWatchdog.init();

    wd.start(200); // 200 ms bound

    // Pet every 50 ms — should stay alive.
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var req = std.c.timespec{
            .sec = 0,
            .nsec = @as(c_long, 50 * std.time.ns_per_ms),
        };
        _ = std.c.nanosleep(&req, null);
        wd.pet();
        try testing.expectEqual(WatchdogStatus.ok, wd.check());
    }
}

test "watchdog thread-safe concurrent pet and check" {
    var wd = HungWorkerWatchdog.init();
    wd.start(2000); // 2-second bound

    var keep_running = std.atomic.Value(bool).init(true);
    var checker_ok = std.atomic.Value(bool).init(true);

    // Pet thread: pets every 50 ms.
    const petter = try std.Thread.spawn(.{}, struct {
        fn run(w: *HungWorkerWatchdog, keep: *std.atomic.Value(bool)) void {
            while (keep.load(.acquire)) {
                w.pet();
                var req = std.c.timespec{
                    .sec = 0,
                    .nsec = @as(c_long, 50 * std.time.ns_per_ms),
                };
                _ = std.c.nanosleep(&req, null);
            }
        }
    }.run, .{ &wd, &keep_running });

    // Checker thread: checks every 30 ms for 300 ms.
    const checker = try std.Thread.spawn(.{}, struct {
        fn run(w: *HungWorkerWatchdog, ok: *std.atomic.Value(bool)) void {
            var i: usize = 0;
            while (i < 10) : (i += 1) {
                if (w.check() != .ok) {
                    ok.store(false, .release);
                }
                var req = std.c.timespec{
                    .sec = 0,
                    .nsec = @as(c_long, 30 * std.time.ns_per_ms),
                };
                _ = std.c.nanosleep(&req, null);
            }
        }
    }.run, .{ &wd, &checker_ok });

    checker.join();
    keep_running.store(false, .release);
    petter.join();

    try testing.expect(checker_ok.load(.acquire));
}
