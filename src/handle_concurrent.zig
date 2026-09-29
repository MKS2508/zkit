//! ConcurrentHandleSlab(T) — `HandleSlab` compartible entre hilos.
//!
//! Nodo `zkit/handle-concurrent` (dec-0103 §2 de styx, r44 #2). `HandleSlab`
//! es single-thread por contrato; styx lo serializaba bajo un mutex ajeno
//! (`TieredCache.mutex`), y el delivery plane multi-thread de r44 necesita el
//! slab compartido sin que cada consumidor reinvente el candado.
//!
//! Por qué un mutex y no un slab lock-free:
//!   - El peligro real no es la carrera sobre el slot, es el TOCTOU sobre el
//!     VALOR: `get(h)` devuelve `*Buffer`, otro hilo hace `take(h)` y libera
//!     el buffer, y el primero lo usa (UAF). Un slab lock-free sólo protege
//!     la palabra del slot; el valor sigue sin dueño. La API de aquí cierra
//!     ese hueco con `lock(h)`: el valor se usa (p. ej. `buf.acquire()` para
//!     subir su refcount) CON el slab bloqueado, y ningún `take` concurrente
//!     puede colarse entre la resolución y el uso.
//!   - La sección crítica es O(1) y sin syscalls; bajo contención real un
//!     mutex pthread es más barato que un CAS-loop con reintentos, y TSAN lo
//!     entiende sin anotaciones.
//!
//! Handles: mismo formato que `HandleSlab` (generación de 16 bits + slot),
//! `0` nunca es un handle vivo.

const std = @import("std");
const HandleSlab = @import("handle.zig").HandleSlab;
const sync = @import("sync.zig");

pub fn ConcurrentHandleSlab(comptime T: type) type {
    return struct {
        const Self = @This();
        const Inner = HandleSlab(T);

        pub const InitError = Inner.InitError;
        pub const AllocError = Inner.AllocError;

        mutex: sync.Mutex = .{},
        inner: Inner,

        pub fn init(allocator: std.mem.Allocator, capacity: u32) InitError!Self {
            return .{ .inner = try Inner.init(allocator, capacity) };
        }

        /// Libera el slab. Los valores que queden dentro NO se liberan: si son
        /// recursos, vacíalos antes con `drain`.
        pub fn deinit(self: *Self) void {
            self.inner.deinit();
            self.mutex.deinit();
            self.* = undefined;
        }

        pub fn alloc(self: *Self, value: T) AllocError!u64 {
            const held = self.mutex.acquire();
            defer held.release();
            return self.inner.alloc(value);
        }

        /// Copia del valor. Para `T` puntero, el valor puede liberarse en
        /// cuanto vuelve esta función: si vas a desreferenciarlo, usa `lock`.
        pub fn get(self: *Self, handle: u64) ?T {
            const held = self.mutex.acquire();
            defer held.release();
            return self.inner.get(handle);
        }

        /// Invalida el handle y devuelve el valor que tenía (una sola vez).
        pub fn take(self: *Self, handle: u64) ?T {
            const held = self.mutex.acquire();
            defer held.release();
            return self.inner.take(handle);
        }

        pub fn free(self: *Self, handle: u64) void {
            _ = self.take(handle);
        }

        pub fn activeCount(self: *Self) u32 {
            const held = self.mutex.acquire();
            defer held.release();
            return self.inner.activeCount();
        }

        /// Resuelve `handle` y deja el slab BLOQUEADO hasta `Locked.unlock()`.
        /// `null` (y sin bloqueo) si el handle es obsoleto. Úsalo para
        /// operar sobre el valor sin que un `take` concurrente lo invalide:
        ///
        ///     if (slab.lock(h)) |l| { defer l.unlock(); _ = l.value.acquire(); }
        pub fn lock(self: *Self, handle: u64) ?Locked {
            self.mutex.lock();
            const v = self.inner.get(handle) orelse {
                self.mutex.unlock();
                return null;
            };
            return .{ .slab = self, .value = v };
        }

        pub const Locked = struct {
            slab: *Self,
            value: T,

            pub fn unlock(l: Locked) void {
                l.slab.mutex.unlock();
            }
        };

        /// Saca TODOS los valores vivos (invalidando sus handles) hacia `out`
        /// hasta llenarlo. Devuelve cuántos. Para cerrar un slab de recursos:
        /// `while (slab.drain(&buf) > 0)` liberando cada uno.
        pub fn drain(self: *Self, out: []T) usize {
            const held = self.mutex.acquire();
            defer held.release();
            var n: usize = 0;
            for (self.inner.entries, 0..) |e, slot| {
                if (n == out.len) break;
                if (e == null) continue;
                const h = (@as(u64, self.inner.generations[slot]) << 48) | @as(u64, @intCast(slot));
                out[n] = self.inner.take(h).?;
                n += 1;
            }
            return n;
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "ConcurrentHandleSlab: API single-thread equivalente a HandleSlab" {
    var slab = try ConcurrentHandleSlab(u32).init(testing.allocator, 2);
    defer slab.deinit();
    const a = try slab.alloc(1);
    const b = try slab.alloc(2);
    try testing.expectError(error.PoolFull, slab.alloc(3));
    try testing.expectEqual(@as(?u32, 1), slab.get(a));
    try testing.expectEqual(@as(?u32, 2), slab.take(b));
    try testing.expectEqual(@as(?u32, null), slab.get(b));
    try testing.expect(slab.lock(b) == null);
    {
        const l = slab.lock(a).?;
        defer l.unlock();
        try testing.expectEqual(@as(u32, 1), l.value);
    }
    var out: [4]u32 = undefined;
    try testing.expectEqual(@as(usize, 1), slab.drain(&out));
    try testing.expectEqual(@as(u32, 0), slab.activeCount());
    try testing.expectEqual(@as(?u32, null), slab.get(a));
}

/// Recurso refcontado: el escenario real de styx (slab de `*ZeroCopyBuffer`).
const Res = struct {
    refs: std.atomic.Value(u32) = .init(1),
    fn acquire(r: *Res) void {
        _ = r.refs.fetchAdd(1, .monotonic);
    }
    fn release(r: *Res, gpa: std.mem.Allocator) void {
        if (r.refs.fetchSub(1, .acq_rel) == 1) gpa.destroy(r);
    }
};

test "ConcurrentHandleSlab: lock+acquire vs take+release concurrentes sin UAF ni leak (TSAN)" {
    // 4 lectores resuelven handles y suben el refcount bajo `lock`; 2
    // escritores crean y retiran recursos. Con `get`+acquire fuera del lock
    // esto es un UAF que TSAN/SafeAllocator detectan; con `lock` no.
    const gpa = std.heap.c_allocator; // thread-safe; los leaks los cuenta `live`
    const Shared = struct {
        slab: ConcurrentHandleSlab(*Res),
        handles: [64]std.atomic.Value(u64) = @splat(.init(0)),
        live: std.atomic.Value(i64) = .init(0),
        stop: std.atomic.Value(bool) = .init(false),

        fn writer(s: *@This(), seed: u64) void {
            var prng = std.Random.DefaultPrng.init(seed);
            const r = prng.random();
            for (0..20_000) |_| {
                const i = r.uintLessThan(usize, s.handles.len);
                const old = s.handles[i].swap(0, .acq_rel);
                if (old != 0) if (s.slab.take(old)) |res| {
                    res.release(gpa);
                    _ = s.live.fetchSub(1, .monotonic);
                };
                const res = gpa.create(Res) catch continue;
                res.* = .{};
                _ = s.live.fetchAdd(1, .monotonic);
                const h = s.slab.alloc(res) catch {
                    res.release(gpa);
                    _ = s.live.fetchSub(1, .monotonic);
                    continue;
                };
                const prev = s.handles[i].swap(h, .acq_rel);
                if (prev != 0) if (s.slab.take(prev)) |p| {
                    p.release(gpa);
                    _ = s.live.fetchSub(1, .monotonic);
                };
            }
        }

        fn reader(s: *@This()) void {
            var i: usize = 0;
            while (!s.stop.load(.acquire)) : (i +%= 1) {
                const h = s.handles[i % s.handles.len].load(.acquire);
                if (h == 0) continue;
                const res = blk: {
                    const l = s.slab.lock(h) orelse continue;
                    defer l.unlock();
                    l.value.acquire();
                    break :blk l.value;
                };
                // Fuera del lock: tenemos nuestra propia referencia.
                std.mem.doNotOptimizeAway(res.refs.load(.monotonic));
                res.release(gpa);
            }
        }
    };
    var s: Shared = .{ .slab = try .init(testing.allocator, 128) };
    defer s.slab.deinit();

    var readers: [4]std.Thread = undefined;
    for (&readers) |*t| t.* = try std.Thread.spawn(.{}, Shared.reader, .{&s});
    var writers: [2]std.Thread = undefined;
    for (&writers, 0..) |*t, k| t.* = try std.Thread.spawn(.{}, Shared.writer, .{ &s, k + 1 });
    for (writers) |t| t.join();
    s.stop.store(true, .release);
    for (readers) |t| t.join();

    var out: [128]*Res = undefined;
    while (true) {
        const n = s.slab.drain(&out);
        if (n == 0) break;
        for (out[0..n]) |res| {
            res.release(gpa);
            _ = s.live.fetchSub(1, .monotonic);
        }
    }
    try testing.expectEqual(@as(i64, 0), s.live.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), s.slab.activeCount());
}
