//! zkit/time — relojes y espera para código con hilos propios y sin runtime `Io`.
//!
//! Desde 0.16 `std.time.nanoTimestamp`/`std.Thread.sleep` viven detrás de la
//! interfaz `Io`. Una librería con sus propios `std.Thread` (daemon, FFI) no
//! tiene un `Io` que pasarles, así que cada repo acababa escribiendo su
//! `fn nowNs()` sobre `clock_gettime` (styx tenía cinco copias literales y un
//! sexto clon en quic-zig `sys.nanoTimestamp`). Este módulo es la única.
//!
//! Reglas:
//!   - `monotonicNs` es el reloj de deadlines, timeouts y latencias. Nunca
//!     retrocede. Su cero es arbitrario (arranque de la máquina): no se
//!     compara con fechas.
//!   - `realtimeNs`/`realtimeSeconds` son el reloj de pared. Puede saltar
//!     (NTP, el operador), así que sólo sirve para fechas absolutas que otro
//!     host va a leer (caducidad de un token, un timestamp de log), jamás
//!     para medir una duración.
//!   - Todos devuelven enteros sin signo o con signo explícito; ningún
//!     fallback silencioso a 0: `clock_gettime` sobre un reloj que el SO
//!     garantiza sólo falla por un bug (puntero o clockid inválido), y eso es
//!     un pánico, no un número falso.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

comptime {
    switch (builtin.os.tag) {
        .linux, .macos, .ios, .watchos, .tvos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => {},
        else => @compileError("zkit.time: sistema operativo sin soporte (POSIX clock_gettime)"),
    }
}

pub const ns_per_us: u64 = std.time.ns_per_us;
pub const ns_per_ms: u64 = std.time.ns_per_ms;
pub const ns_per_s: u64 = std.time.ns_per_s;

fn readClock(clock: c.clockid_t) c.timespec {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(clock, &ts) != 0) {
        // Con un clockid constante y un puntero a la pila sólo falla por
        // corrupción de memoria: no hay valor honesto que devolver.
        @panic("zkit.time: clock_gettime falló sobre un reloj obligatorio");
    }
    return ts;
}

/// Nanosegundos del reloj monotónico (`CLOCK_MONOTONIC`).
pub fn monotonicNs() u64 {
    const ts = readClock(c.CLOCK.MONOTONIC);
    return @as(u64, @intCast(ts.sec)) * ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Milisegundos del reloj monotónico.
pub fn monotonicMs() u64 {
    return monotonicNs() / ns_per_ms;
}

/// Nanosegundos desde la época Unix por el reloj de pared (`CLOCK_REALTIME`).
/// Con signo: un reloj mal puesto antes de 1970 es posible y no debe
/// convertirse en pánico por un cast.
pub fn realtimeNs() i64 {
    const ts = readClock(c.CLOCK.REALTIME);
    return @as(i64, ts.sec) * @as(i64, ns_per_s) + @as(i64, ts.nsec);
}

/// Segundos desde la época Unix por el reloj de pared.
pub fn realtimeSeconds() i64 {
    return @intCast(readClock(c.CLOCK.REALTIME).sec);
}

/// Milisegundos desde la época Unix por el reloj de pared.
pub fn realtimeMs() i64 {
    return @divFloor(realtimeNs(), @as(i64, ns_per_ms));
}

/// Duerme al menos `ns` nanosegundos (reintenta tras `EINTR` con lo que falte).
pub fn sleepNs(ns: u64) void {
    var req: c.timespec = .{
        .sec = @intCast(ns / ns_per_s),
        .nsec = @intCast(ns % ns_per_s),
    };
    var rem: c.timespec = undefined;
    while (c.nanosleep(&req, &rem) != 0) {
        switch (c.errno(@as(c_int, -1))) {
            .INTR => req = rem,
            else => return,
        }
    }
}

/// Plazo absoluto sobre el reloj monotónico. Sustituye al patrón
/// `waited_ns += POLL_NS` (que deriva porque ignora el tiempo real de cada
/// vuelta) y es lo que consumen `sync.Condition.timedWait` y las colas.
pub const Deadline = struct {
    at_ns: u64,

    /// Plazo a `timeout_ns` desde ahora. Satura en lugar de desbordar.
    pub fn fromNow(timeout_ns: u64) Deadline {
        return .{ .at_ns = monotonicNs() +| timeout_ns };
    }

    /// Plazo que nunca vence.
    pub const never: Deadline = .{ .at_ns = std.math.maxInt(u64) };

    pub fn expired(self: Deadline) bool {
        return monotonicNs() >= self.at_ns;
    }

    /// Nanosegundos que quedan (0 si ya venció).
    pub fn remainingNs(self: Deadline) u64 {
        return self.at_ns -| monotonicNs();
    }
};

/// Cronómetro monotónico: `start` + `readNs`/`lapNs`.
pub const Stopwatch = struct {
    started_ns: u64,

    pub fn start() Stopwatch {
        return .{ .started_ns = monotonicNs() };
    }

    pub fn readNs(self: Stopwatch) u64 {
        return monotonicNs() -| self.started_ns;
    }

    /// Devuelve lo transcurrido y reinicia.
    pub fn lapNs(self: *Stopwatch) u64 {
        const now = monotonicNs();
        const elapsed = now -| self.started_ns;
        self.started_ns = now;
        return elapsed;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "monotonicNs no retrocede y sleepNs duerme al menos lo pedido" {
    const a = monotonicNs();
    sleepNs(2 * ns_per_ms);
    const b = monotonicNs();
    try testing.expect(b >= a + 2 * ns_per_ms);
    try testing.expect(monotonicMs() >= a / ns_per_ms);
}

test "realtime es una fecha plausible (después de 2020)" {
    const s = realtimeSeconds();
    try testing.expect(s > 1_577_836_800); // 2020-01-01
    const ns = realtimeNs();
    try testing.expect(@divFloor(ns, @as(i64, ns_per_s)) >= s);
    try testing.expect(realtimeMs() >= s * 1000);
}

test "Deadline: vence, satura y never no vence" {
    const d = Deadline.fromNow(1 * ns_per_ms);
    try testing.expect(!Deadline.never.expired());
    try testing.expect(d.remainingNs() <= 1 * ns_per_ms);
    sleepNs(2 * ns_per_ms);
    try testing.expect(d.expired());
    try testing.expectEqual(@as(u64, 0), d.remainingNs());
    // Saturación: un timeout enorme no desborda a un plazo en el pasado.
    const far = Deadline.fromNow(std.math.maxInt(u64));
    try testing.expect(!far.expired());
}

test "Stopwatch: lap reinicia" {
    var sw = Stopwatch.start();
    sleepNs(1 * ns_per_ms);
    const lap = sw.lapNs();
    try testing.expect(lap >= 1 * ns_per_ms);
    try testing.expect(sw.readNs() < lap + 50 * ns_per_ms);
}
