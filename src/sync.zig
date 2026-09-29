//! zkit/sync — Mutex y Condition bloqueantes sobre pthread, sin runtime `Io`.
//!
//! Desde 0.16 `std.Thread.Mutex`/`Condition` no existen: el mutex bloqueante
//! vive en `std.Io.Mutex` y exige un `Io`. Una librería con hilos propios
//! (`std.Thread.spawn`) no tiene uno, así que cada consumidor escribió su capa
//! pthread (styx: `backpressure_waker.zig` más 60 usos de `pthread_mutex_t`
//! crudo; hyperdiff: `watch/sync.zig`). Ésta es la única.
//!
//! Diseño:
//!   - Los dos tipos se inicializan por valor (`.{}` = `PTHREAD_*_INITIALIZER`):
//!     no hay `init` que olvidar ni `error.MutexInitFailed` que propagar. El
//!     `deinit` existe para simetría y es opcional sobre un mutex estático.
//!   - `lock`/`unlock`/`wait` sólo fallan por bugs (EINVAL, EDEADLK, EPERM):
//!     se promueven a pánico, nunca se ignoran.
//!   - `timedWait` mide contra el reloj MONOTÓNICO siempre que la plataforma
//!     lo permita (glibc ≥ 2.30 `pthread_cond_clockwait`, Darwin
//!     `pthread_cond_timedwait_relative_np`); un salto del reloj de pared no
//!     alarga ni acorta la espera. En musl / BSD cae a `CLOCK_REALTIME`, y el
//!     bucle de `waitUntil` recorta contra el plazo monotónico igualmente.
//!   - TSAN entiende pthread por interceptores: no hace falta anotar nada.
//!
//! Para detectar inversiones de orden de locks y unlocks desde otro hilo usa
//! `zkit.safety.Mutex`, que envuelve éste.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const time = @import("time.zig");

const is_darwin = builtin.os.tag.isDarwin();

/// glibc ≥ 2.30 trae `pthread_cond_clockwait`, que acepta el reloj por
/// llamada y funciona sobre un cond inicializado estáticamente.
const has_clockwait = builtin.os.tag == .linux and builtin.abi.isGnu() and blk: {
    const v = builtin.target.os.versionRange().gnuLibCVersion() orelse break :blk false;
    break :blk v.order(.{ .major = 2, .minor = 30, .patch = 0 }) != .lt;
};

// `std.c` declara lock/unlock/trylock/destroy y cond wait/timedwait/signal/
// broadcast/destroy. NO declara estas dos, que son las únicas extern propias.
extern "c" fn pthread_cond_clockwait(
    noalias cond: *c.pthread_cond_t,
    noalias mutex: *c.pthread_mutex_t,
    clock: c.clockid_t,
    noalias abstime: *const c.timespec,
) c.E;
extern "c" fn pthread_cond_timedwait_relative_np(
    noalias cond: *c.pthread_cond_t,
    noalias mutex: *c.pthread_mutex_t,
    noalias reltime: *const c.timespec,
) c.E;

/// Mutex no recursivo con atributos por defecto.
pub const Mutex = struct {
    raw: c.pthread_mutex_t = c.PTHREAD_MUTEX_INITIALIZER,

    pub fn deinit(m: *Mutex) void {
        _ = c.pthread_mutex_destroy(&m.raw);
        m.* = undefined;
    }

    pub fn lock(m: *Mutex) void {
        switch (c.pthread_mutex_lock(&m.raw)) {
            .SUCCESS => {},
            else => |e| std.debug.panic("zkit.sync.Mutex.lock: {t}", .{e}),
        }
    }

    /// `true` si el lock se tomó; `false` si otro hilo lo tiene.
    pub fn tryLock(m: *Mutex) bool {
        return switch (c.pthread_mutex_trylock(&m.raw)) {
            .SUCCESS => true,
            .BUSY => false,
            else => |e| std.debug.panic("zkit.sync.Mutex.tryLock: {t}", .{e}),
        };
    }

    pub fn unlock(m: *Mutex) void {
        switch (c.pthread_mutex_unlock(&m.raw)) {
            .SUCCESS => {},
            else => |e| std.debug.panic("zkit.sync.Mutex.unlock: {t}", .{e}),
        }
    }

    /// Guarda para `defer`: `var held = m.acquire(); defer held.release();`.
    pub fn acquire(m: *Mutex) Held {
        m.lock();
        return .{ .mutex = m };
    }

    pub const Held = struct {
        mutex: *Mutex,

        pub fn release(self: Held) void {
            self.mutex.unlock();
        }
    };
};

pub const TimedWaitError = error{Timeout};

/// Variable de condición. Se asocia a un `Mutex` en cada `wait`.
/// Los despertares espurios son posibles: el llamador re-comprueba su
/// predicado en bucle.
pub const Condition = struct {
    raw: c.pthread_cond_t = c.PTHREAD_COND_INITIALIZER,

    pub fn deinit(cond: *Condition) void {
        _ = c.pthread_cond_destroy(&cond.raw);
        cond.* = undefined;
    }

    /// Libera `mutex` (que el llamador sostiene), duerme hasta una señal y lo
    /// vuelve a tomar antes de volver.
    pub fn wait(cond: *Condition, mutex: *Mutex) void {
        switch (c.pthread_cond_wait(&cond.raw, &mutex.raw)) {
            .SUCCESS => {},
            else => |e| std.debug.panic("zkit.sync.Condition.wait: {t}", .{e}),
        }
    }

    /// Como `wait`, pero como mucho `timeout_ns`. `error.Timeout` si venció
    /// sin señal. Puede volver antes (despertar espurio) sin error.
    pub fn timedWait(cond: *Condition, mutex: *Mutex, timeout_ns: u64) TimedWaitError!void {
        return cond.waitUntil(mutex, time.Deadline.fromNow(timeout_ns));
    }

    /// Como `wait`, hasta el plazo monotónico `deadline`.
    pub fn waitUntil(cond: *Condition, mutex: *Mutex, deadline: time.Deadline) TimedWaitError!void {
        if (deadline.at_ns == time.Deadline.never.at_ns) return cond.wait(mutex);
        const remaining = deadline.remainingNs();
        if (remaining == 0) return error.Timeout;

        const rc: c.E = if (has_clockwait) blk: {
            const abs = nsToTimespec(deadline.at_ns);
            break :blk pthread_cond_clockwait(&cond.raw, &mutex.raw, c.CLOCK.MONOTONIC, &abs);
        } else if (is_darwin) blk: {
            const rel = nsToTimespec(remaining);
            break :blk pthread_cond_timedwait_relative_np(&cond.raw, &mutex.raw, &rel);
        } else blk: {
            // CLOCK_REALTIME: un salto de reloj puede desplazar el despertar,
            // pero el plazo real se sigue midiendo en monotónico (abajo).
            const now_rt: u64 = @intCast(@max(time.realtimeNs(), 0));
            const abs = nsToTimespec(now_rt +| remaining);
            break :blk c.pthread_cond_timedwait(&cond.raw, &mutex.raw, &abs);
        };
        switch (rc) {
            .SUCCESS => return,
            .TIMEDOUT => return if (deadline.expired()) error.Timeout else {},
            .INTR => return,
            else => |e| std.debug.panic("zkit.sync.Condition.waitUntil: {t}", .{e}),
        }
    }

    /// Despierta al menos a un hilo en espera.
    pub fn signal(cond: *Condition) void {
        switch (c.pthread_cond_signal(&cond.raw)) {
            .SUCCESS => {},
            else => |e| std.debug.panic("zkit.sync.Condition.signal: {t}", .{e}),
        }
    }

    /// Despierta a todos los hilos en espera.
    pub fn broadcast(cond: *Condition) void {
        switch (c.pthread_cond_broadcast(&cond.raw)) {
            .SUCCESS => {},
            else => |e| std.debug.panic("zkit.sync.Condition.broadcast: {t}", .{e}),
        }
    }
};

fn nsToTimespec(ns: u64) c.timespec {
    return .{
        .sec = @intCast(@min(ns / time.ns_per_s, std.math.maxInt(i32))),
        .nsec = @intCast(ns % time.ns_per_s),
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "Mutex: tryLock falla con el lock tomado por otro hilo y funciona libre" {
    var m: Mutex = .{};
    defer m.deinit();

    try testing.expect(m.tryLock());
    const Other = struct {
        fn run(mm: *Mutex, out: *bool) void {
            out.* = mm.tryLock();
        }
    };
    var got = true;
    const t = try std.Thread.spawn(.{}, Other.run, .{ &m, &got });
    t.join();
    try testing.expect(!got);
    m.unlock();

    const held = m.acquire();
    held.release();
    try testing.expect(m.tryLock());
    m.unlock();
}

test "Mutex: 4 hilos x 10k incrementos sin pérdidas (TSAN limpio)" {
    const Shared = struct {
        m: Mutex = .{},
        n: u64 = 0,
        fn run(s: *@This()) void {
            for (0..10_000) |_| {
                const h = s.m.acquire();
                defer h.release();
                s.n += 1;
            }
        }
    };
    var s: Shared = .{};
    var ts: [4]std.Thread = undefined;
    for (&ts) |*t| t.* = try std.Thread.spawn(.{}, Shared.run, .{&s});
    for (ts) |t| t.join();
    try testing.expectEqual(@as(u64, 40_000), s.n);
}

test "Condition: timedWait vence con error.Timeout sin señal" {
    var m: Mutex = .{};
    var cv: Condition = .{};
    m.lock();
    defer m.unlock();
    const sw = time.Stopwatch.start();
    // Bucle canónico: los espurios no cuentan como timeout.
    const d = time.Deadline.fromNow(5 * time.ns_per_ms);
    while (true) {
        cv.waitUntil(&m, d) catch |err| {
            try testing.expectEqual(error.Timeout, err);
            break;
        };
    }
    try testing.expect(sw.readNs() >= 5 * time.ns_per_ms);
    try testing.expectError(error.Timeout, cv.timedWait(&m, 0));
}

test "Condition: signal despierta al que espera (sin polling)" {
    const Shared = struct {
        m: Mutex = .{},
        cv: Condition = .{},
        ready: bool = false,
        fn producer(s: *@This()) void {
            time.sleepNs(2 * time.ns_per_ms);
            s.m.lock();
            s.ready = true;
            s.m.unlock();
            s.cv.signal();
        }
    };
    var s: Shared = .{};
    const t = try std.Thread.spawn(.{}, Shared.producer, .{&s});
    s.m.lock();
    const d = time.Deadline.fromNow(5 * time.ns_per_s);
    while (!s.ready) try s.cv.waitUntil(&s.m, d);
    s.m.unlock();
    t.join();
    try testing.expect(s.ready);
}

test "Condition: broadcast despierta a todos" {
    const Shared = struct {
        m: Mutex = .{},
        cv: Condition = .{},
        go: bool = false,
        woke: std.atomic.Value(u32) = .init(0),
        fn waiter(s: *@This()) void {
            s.m.lock();
            defer s.m.unlock();
            while (!s.go) s.cv.wait(&s.m);
            _ = s.woke.fetchAdd(1, .monotonic);
        }
    };
    var s: Shared = .{};
    var ts: [3]std.Thread = undefined;
    for (&ts) |*t| t.* = try std.Thread.spawn(.{}, Shared.waiter, .{&s});
    time.sleepNs(2 * time.ns_per_ms);
    s.m.lock();
    s.go = true;
    s.m.unlock();
    s.cv.broadcast();
    for (ts) |t| t.join();
    try testing.expectEqual(@as(u32, 3), s.woke.load(.monotonic));
}
