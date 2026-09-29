//! AtomicHistogram(bounds) — histograma de cubos fijos, lock-free.
//!
//! Instrumentación en el hot path: `record` es un `fetchAdd` monotónico sobre
//! un contador de un array fijo, sin reservas ni locks. Los límites de los
//! cubos son comptime y se validan al compilar (empiezan en 0, estrictamente
//! crecientes), así que un histograma mal definido no compila.
//!
//! Cubo `i` = `[bounds[i], bounds[i+1])`; el último es `[bounds[n-1], ∞)`.
//!
//! Origen: `styx/native/zig/media-daemon/metrics/range_hist.zig`, que tenía la
//! mecánica (array de atomics + búsqueda lineal de cubo + snapshot) repetida
//! para dos caminos (P1 WT y P4 MOQT-FETCH) y cosida a sus nombres. Aquí queda
//! la mecánica; los caminos y sus contadores de rama se quedan en styx.
//!
//! Snapshot: cada contador se lee con `.monotonic`; un snapshot concurrente
//! con escrituras no es una foto atómica del conjunto (no lo necesita un
//! exportador de métricas), pero cada contador es exacto y no retrocede.

const std = @import("std");

pub fn AtomicHistogram(comptime bounds: []const u64) type {
    comptime {
        if (bounds.len == 0) @compileError("AtomicHistogram: bounds vacío");
        if (bounds[0] != 0) @compileError("AtomicHistogram: bounds[0] debe ser 0");
        for (bounds[1..], 0..) |b, i| {
            if (b <= bounds[i]) @compileError("AtomicHistogram: bounds debe ser estrictamente creciente");
        }
    }
    return struct {
        const Self = @This();
        pub const bucket_count = bounds.len;
        pub const boundaries = bounds;
        pub const Snapshot = [bucket_count]u64;

        counts: [bucket_count]std.atomic.Value(u64) = @splat(.init(0)),

        /// Índice del cubo de `value` (búsqueda binaria: último límite <= value).
        pub fn bucketIndex(value: u64) usize {
            var lo: usize = 0;
            var hi: usize = bucket_count;
            while (hi - lo > 1) {
                const mid = lo + (hi - lo) / 2;
                if (bounds[mid] <= value) lo = mid else hi = mid;
            }
            return lo;
        }

        pub fn record(self: *Self, value: u64) void {
            _ = self.counts[bucketIndex(value)].fetchAdd(1, .monotonic);
        }

        pub fn recordN(self: *Self, value: u64, n: u64) void {
            _ = self.counts[bucketIndex(value)].fetchAdd(n, .monotonic);
        }

        pub fn snapshot(self: *const Self) Snapshot {
            var out: Snapshot = undefined;
            for (&out, &self.counts) |*o, *c| o.* = c.load(.monotonic);
            return out;
        }

        pub fn total(self: *const Self) u64 {
            var sum: u64 = 0;
            for (&self.counts) |*c| sum +%= c.load(.monotonic);
            return sum;
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const KiB = 1024;
const MiB = 1024 * KiB;
const Sizes = AtomicHistogram(&.{ 0, 64 * KiB, 256 * KiB, 1 * MiB, 4 * MiB, 16 * MiB });

test "AtomicHistogram: límites inclusivos por abajo, exclusivos por arriba" {
    const cases = [_]struct { v: u64, i: usize }{
        .{ .v = 0, .i = 0 },                    .{ .v = 64 * KiB - 1, .i = 0 },
        .{ .v = 64 * KiB, .i = 1 },             .{ .v = 256 * KiB - 1, .i = 1 },
        .{ .v = 256 * KiB, .i = 2 },            .{ .v = 1 * MiB, .i = 3 },
        .{ .v = 4 * MiB - 1, .i = 3 },          .{ .v = 4 * MiB, .i = 4 },
        .{ .v = 16 * MiB - 1, .i = 4 },         .{ .v = 16 * MiB, .i = 5 },
        .{ .v = std.math.maxInt(u64), .i = 5 },
    };
    for (cases) |cs| try testing.expectEqual(cs.i, Sizes.bucketIndex(cs.v));
}

test "AtomicHistogram: bucketIndex coincide con la búsqueda lineal para 100k valores" {
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    for (0..100_000) |_| {
        const v = r.int(u64) >> r.int(u6);
        var lin: usize = Sizes.bucket_count - 1;
        for (Sizes.boundaries, 0..) |b, i| {
            if (v < b) {
                lin = i - 1;
                break;
            }
        }
        try testing.expectEqual(lin, Sizes.bucketIndex(v));
    }
}

test "AtomicHistogram: 4 hilos x 25k record — total exacto (TSAN)" {
    var h: Sizes = .{};
    const W = struct {
        fn run(hh: *Sizes, seed: u64) void {
            var prng = std.Random.DefaultPrng.init(seed);
            for (0..25_000) |_| hh.record(prng.random().uintLessThan(u64, 32 * MiB));
        }
    };
    var ts: [4]std.Thread = undefined;
    for (&ts, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, W.run, .{ &h, i });
    for (ts) |t| t.join();
    try testing.expectEqual(@as(u64, 100_000), h.total());
    var sum: u64 = 0;
    for (h.snapshot()) |c| sum += c;
    try testing.expectEqual(@as(u64, 100_000), sum);
    h.recordN(0, 5);
    try testing.expectEqual(@as(u64, 100_005), h.total());
}
