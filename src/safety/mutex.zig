//! zkit.safety.Mutex — mutex con dueño comprobado y orden de locks.
//!
//! `zkit.sync.Mutex` es el mutex pthread desnudo. Éste lo envuelve con los
//! invariantes que convierten un bug de concurrencia latente (que TSAN sólo
//! ve si la carrera ocurre durante el test) en un fallo determinista la
//! primera vez que el código mal ordenado se EJECUTA:
//!
//!   - Dueño: `unlock` desde un hilo que no lo tiene, o re-`lock` desde el
//!     hilo que ya lo tiene (autodeadlock), son pánico con el nombre del lock.
//!     `assertHeld()` documenta y comprueba "esta función se llama con el lock".
//!   - Orden: cada mutex puede declarar un `level`. Un hilo sólo puede tomar
//!     locks en orden estrictamente CRECIENTE de nivel; tomar uno de nivel <=
//!     a alguno que ya tiene es pánico ("lock order violation: 'cache'(10)
//!     mientras tiene 'session'(20)"). Así una inversión A→B / B→A se detecta
//!     aunque los dos hilos nunca coincidan en el test. `level = 0` = sin
//!     orden (no participa).
//!   - `tryLock` no puede interbloquear: no comprueba orden (sí se registra).
//!
//! Coste: con `std.debug.runtime_safety` (Debug, ReleaseSafe) un store
//! atómico del dueño y una pila thread-local de hasta 16 locks; en
//! ReleaseFast/Small los checks desaparecen y queda el mutex desnudo.

const std = @import("std");
const sync = @import("../sync.zig");
const time = @import("../time.zig");

pub const checks_enabled = std.debug.runtime_safety;
pub const max_held = 16;

pub const Options = struct {
    /// Nombre para los mensajes de pánico.
    name: []const u8 = "anon",
    /// Nivel de orden (0 = no participa).
    level: u16 = 0,
};

threadlocal var held_stack: [max_held]*const Mutex = undefined;
threadlocal var held_len: usize = 0;

fn selfId() u64 {
    return @as(u64, std.Thread.getCurrentId()) + 1; // 0 = sin dueño
}

pub const Violation = union(enum) {
    relock: []const u8,
    order: struct { acquiring: []const u8, acquiring_level: u16, held: []const u8, held_level: u16 },
    too_many_held,
    not_owner: []const u8,
};

pub const Mutex = struct {
    inner: sync.Mutex = .{},
    owner: std.atomic.Value(u64) = .init(0),
    opts: Options = .{},

    pub fn init(opts: Options) Mutex {
        return .{ .opts = opts };
    }

    pub fn deinit(m: *Mutex) void {
        m.inner.deinit();
        m.* = undefined;
    }

    pub fn lock(m: *Mutex) void {
        if (checks_enabled) if (m.lockViolation()) |v| panicViolation(v);
        m.inner.lock();
        if (checks_enabled) m.markAcquired();
    }

    pub fn tryLock(m: *Mutex) bool {
        if (checks_enabled and m.owner.load(.monotonic) == selfId()) panicViolation(.{ .relock = m.opts.name });
        if (!m.inner.tryLock()) return false;
        if (checks_enabled) m.markAcquired();
        return true;
    }

    pub fn unlock(m: *Mutex) void {
        if (checks_enabled) {
            if (m.unlockViolation()) |v| panicViolation(v);
            m.markReleased();
        }
        m.inner.unlock();
    }

    /// Pánico si el hilo actual no tiene el lock (no-op sin runtime safety).
    pub fn assertHeld(m: *const Mutex) void {
        if (checks_enabled and m.owner.load(.monotonic) != selfId()) panicViolation(.{ .not_owner = m.opts.name });
    }

    pub fn isHeldByCurrentThread(m: *const Mutex) bool {
        return m.owner.load(.monotonic) == selfId();
    }

    pub fn acquire(m: *Mutex) Held {
        m.lock();
        return .{ .mutex = m };
    }

    pub const Held = struct {
        mutex: *Mutex,
        pub fn release(h: Held) void {
            h.mutex.unlock();
        }
    };

    /// `cond.wait` con este mutex: suelta la propiedad mientras duerme y la
    /// recupera al despertar (sin re-comprobar el orden: es el mismo lock).
    pub fn wait(m: *Mutex, cond: *sync.Condition) void {
        m.assertHeld();
        if (checks_enabled) m.markReleased();
        cond.wait(&m.inner);
        if (checks_enabled) m.markAcquired();
    }

    pub fn waitUntil(m: *Mutex, cond: *sync.Condition, deadline: time.Deadline) sync.TimedWaitError!void {
        m.assertHeld();
        if (checks_enabled) m.markReleased();
        defer if (checks_enabled) m.markAcquired();
        return cond.waitUntil(&m.inner, deadline);
    }

    /// Lo que `lock` comprobaría, sin efectos (para tests y diagnósticos).
    pub fn lockViolation(m: *const Mutex) ?Violation {
        if (m.owner.load(.monotonic) == selfId()) return .{ .relock = m.opts.name };
        if (m.opts.level != 0) {
            for (held_stack[0..held_len]) |h| {
                if (h.opts.level != 0 and h.opts.level >= m.opts.level) return .{ .order = .{
                    .acquiring = m.opts.name,
                    .acquiring_level = m.opts.level,
                    .held = h.opts.name,
                    .held_level = h.opts.level,
                } };
            }
        }
        if (held_len == max_held) return .too_many_held;
        return null;
    }

    pub fn unlockViolation(m: *const Mutex) ?Violation {
        if (m.owner.load(.monotonic) != selfId()) return .{ .not_owner = m.opts.name };
        return null;
    }

    fn markAcquired(m: *Mutex) void {
        m.owner.store(selfId(), .monotonic);
        if (held_len == max_held) panicViolation(.too_many_held);
        held_stack[held_len] = m;
        held_len += 1;
    }

    fn markReleased(m: *Mutex) void {
        m.owner.store(0, .monotonic);
        // Se permite soltar fuera de orden LIFO: quitar donde esté.
        var i = held_len;
        while (i > 0) {
            i -= 1;
            if (held_stack[i] == m) {
                std.mem.copyForwards(*const Mutex, held_stack[i .. held_len - 1], held_stack[i + 1 .. held_len]);
                held_len -= 1;
                return;
            }
        }
    }
};

fn panicViolation(v: Violation) noreturn {
    switch (v) {
        .relock => |n| std.debug.panic("zkit.safety.Mutex: '{s}' re-lock desde el hilo que ya lo tiene (autodeadlock)", .{n}),
        .order => |o| std.debug.panic(
            "zkit.safety.Mutex: lock order violation: '{s}'({d}) mientras tiene '{s}'({d})",
            .{ o.acquiring, o.acquiring_level, o.held, o.held_level },
        ),
        .too_many_held => std.debug.panic("zkit.safety.Mutex: más de {d} locks a la vez en un hilo", .{max_held}),
        .not_owner => |n| std.debug.panic("zkit.safety.Mutex: '{s}' liberado/usado por un hilo que no lo tiene", .{n}),
    }
}

/// Número de `safety.Mutex` que el hilo actual tiene (diagnóstico/tests).
pub fn heldCount() usize {
    return held_len;
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "safety.Mutex: orden creciente permitido, inversión detectada con nombres" {
    if (!checks_enabled) return error.SkipZigTest;
    var session = Mutex.init(.{ .name = "session", .level = 20 });
    var cache = Mutex.init(.{ .name = "cache", .level = 10 });
    var free = Mutex.init(.{ .name = "free" });

    cache.lock();
    try testing.expect(session.lockViolation() == null);
    session.lock();
    try testing.expectEqual(@as(usize, 2), heldCount());
    try testing.expect(free.lockViolation() == null); // level 0 no participa
    session.unlock();
    cache.unlock();

    session.lock();
    const v = cache.lockViolation().?;
    try testing.expectEqualStrings("cache", v.order.acquiring);
    try testing.expectEqualStrings("session", v.order.held);
    // tryLock no puede interbloquear: permitido y registrado.
    try testing.expect(cache.tryLock());
    try testing.expectEqual(@as(usize, 2), heldCount());
    // Soltar fuera de orden LIFO es válido.
    session.unlock();
    cache.unlock();
    try testing.expectEqual(@as(usize, 0), heldCount());
}

test "safety.Mutex: dueño — relock y unlock ajeno detectados; assertHeld" {
    if (!checks_enabled) return error.SkipZigTest;
    var m = Mutex.init(.{ .name = "m" });
    try testing.expect(m.unlockViolation() != null);
    m.lock();
    m.assertHeld();
    try testing.expectEqualStrings("m", m.lockViolation().?.relock);
    const Other = struct {
        fn run(mm: *Mutex, out: *?Violation) void {
            out.* = mm.unlockViolation();
        }
    };
    var got: ?Violation = null;
    const t = try std.Thread.spawn(.{}, Other.run, .{ &m, &got });
    t.join();
    try testing.expectEqualStrings("m", got.?.not_owner);
    m.unlock();
    try testing.expect(!m.isHeldByCurrentThread());
}

test "safety.Mutex: wait/waitUntil sueltan y recuperan la propiedad; estrés 4 hilos (TSAN)" {
    const Shared = struct {
        m: Mutex = .init(.{ .name = "counter", .level = 1 }),
        cv: sync.Condition = .{},
        n: u64 = 0,
        fn run(s: *@This()) void {
            for (0..5_000) |_| {
                const h = s.m.acquire();
                defer h.release();
                s.m.assertHeld();
                s.n += 1;
                if (s.n == 20_000) s.cv.broadcast();
            }
        }
    };
    var s: Shared = .{};
    var ts: [4]std.Thread = undefined;
    for (&ts) |*t| t.* = try std.Thread.spawn(.{}, Shared.run, .{&s});
    s.m.lock();
    const d = time.Deadline.fromNow(10 * time.ns_per_s);
    while (s.n < 20_000) try s.m.waitUntil(&s.cv, d);
    s.m.assertHeld();
    s.m.unlock();
    for (ts) |t| t.join();
    try testing.expectEqual(@as(u64, 20_000), s.n);
    try testing.expectEqual(@as(usize, 0), heldCount());
}
