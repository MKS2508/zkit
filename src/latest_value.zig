//! LatestValue(T) — canal de un solo hueco "gana el último" con versión.
//!
//! Semántica de `watch::channel` (iroh-live, tokio): el productor publica el
//! valor fresco; el consumidor lee SÓLO el más reciente, nunca un backlog. Una
//! versión monotónica de 64 bits le dice al consumidor si lo que lee es nuevo
//! desde su última lectura. Es la contrapresión correcta entre un productor
//! rápido (5 Hz de señales de transporte) y un bucle de decisión más lento:
//! cien muestras en 200 ms no valen más que la última.
//!
//! Origen: `styx/native/zig/media-core/observability/transport_signals.zig`
//! (`TransportSignalsChannel`), con el payload (`TransportSignals`) dejado en
//! styx. Arreglado al portar: el original leía la versión FUERA del mutex y
//! el valor DENTRO, y subía la versión después de soltar el mutex, así que un
//! snapshot podía llevar el valor de la versión N+1 etiquetado como N — y la
//! siguiente `consumeSince(N)` devolvía ese mismo valor otra vez (entrega
//! duplicada). Aquí valor y versión se escriben y se leen juntos bajo el
//! mutex; la comprobación "¿hay algo nuevo?" sigue siendo un load atómico sin
//! bloqueo.

const std = @import("std");
const sync = @import("sync.zig");

pub fn LatestValue(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Snapshot = struct {
            value: T,
            /// Número de publicaciones hasta ésta (la primera es 1).
            version: u64,
        };

        /// Espejo atómico de `version_locked` para la vía rápida sin lock.
        version: std.atomic.Value(u64) = .init(0),
        mutex: sync.Mutex = .{},
        latest: T,
        version_locked: u64 = 0,

        /// `initial` es el valor antes de la primera publicación (versión 0,
        /// que ningún `consumeSince(0)` devuelve).
        pub fn init(initial: T) Self {
            return .{ .latest = initial };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.deinit();
            self.* = undefined;
        }

        /// Publica `value` como el último. Varios productores a la vez: gana
        /// el último en tomar el mutex. Devuelve la versión asignada.
        pub fn publish(self: *Self, value: T) u64 {
            const h = self.mutex.acquire();
            defer h.release();
            self.latest = value;
            self.version_locked += 1;
            self.version.store(self.version_locked, .release);
            return self.version_locked;
        }

        /// El último valor si su versión es ESTRICTAMENTE mayor que
        /// `seen_version`; `null` si no hay nada nuevo. El llamador guarda
        /// `snapshot.version` y la pasa en la siguiente llamada.
        pub fn consumeSince(self: *Self, seen_version: u64) ?Snapshot {
            if (self.version.load(.acquire) <= seen_version) return null;
            const h = self.mutex.acquire();
            defer h.release();
            return .{ .value = self.latest, .version = self.version_locked };
        }

        /// El valor actual y su versión, sea nuevo o no.
        pub fn get(self: *Self) Snapshot {
            const h = self.mutex.acquire();
            defer h.release();
            return .{ .value = self.latest, .version = self.version_locked };
        }

        /// Versión actual sin bloqueo (0 = nunca se publicó).
        pub fn peekVersion(self: *const Self) u64 {
            return self.version.load(.acquire);
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const Sample = struct { a: u64 = 0, b: u64 = 0 };

test "LatestValue: vacío devuelve null; 100 publicaciones se colapsan en la última" {
    var ch = LatestValue(Sample).init(.{});
    defer ch.deinit();
    try testing.expectEqual(@as(u64, 0), ch.peekVersion());
    try testing.expect(ch.consumeSince(0) == null);
    try testing.expect(ch.consumeSince(42) == null);

    for (0..100) |i| _ = ch.publish(.{ .a = i, .b = i * 2 });
    try testing.expectEqual(@as(u64, 100), ch.peekVersion());
    const s = ch.consumeSince(0).?;
    try testing.expectEqual(@as(u64, 99), s.value.a);
    try testing.expectEqual(@as(u64, 100), s.version);
    try testing.expect(ch.consumeSince(s.version) == null);

    try testing.expectEqual(@as(u64, 101), ch.publish(.{ .a = 7, .b = 14 }));
    const s2 = ch.consumeSince(s.version).?;
    try testing.expectEqual(@as(u64, 7), s2.value.a);
    try testing.expectEqual(@as(u64, 101), ch.get().version);
}

test "LatestValue: 2 productores + 2 consumidores — versión y valor coherentes, sin duplicados (TSAN)" {
    // Cada productor publica {a = k, b = k} con k creciente; la versión
    // asignada se guarda en el propio valor vía `b` = versión esperada no es
    // posible (la asigna el canal), así que comprobamos lo verificable:
    //   - a == b en todo snapshot (sin lectura rasgada del payload);
    //   - la versión de cada consumidor crece estrictamente (sin duplicados:
    //     el defecto del original devolvía dos veces el mismo valor);
    //   - ambos consumidores alcanzan la versión final.
    const N = 20_000;
    var ch = LatestValue(Sample).init(.{});
    defer ch.deinit();
    const Prod = struct {
        fn run(c: *LatestValue(Sample), base: u64) void {
            for (0..N) |i| _ = c.publish(.{ .a = base + i, .b = base + i });
        }
    };
    const Cons = struct {
        fn run(c: *LatestValue(Sample), bad: *std.atomic.Value(u32)) void {
            var seen: u64 = 0;
            while (seen < 2 * N) {
                const s = c.consumeSince(seen) orelse continue;
                if (s.version <= seen or s.value.a != s.value.b) _ = bad.fetchAdd(1, .monotonic);
                seen = s.version;
            }
        }
    };
    var bad: std.atomic.Value(u32) = .init(0);
    var cs: [2]std.Thread = undefined;
    for (&cs) |*t| t.* = try std.Thread.spawn(.{}, Cons.run, .{ &ch, &bad });
    const p1 = try std.Thread.spawn(.{}, Prod.run, .{ &ch, 0 });
    const p2 = try std.Thread.spawn(.{}, Prod.run, .{ &ch, 1_000_000 });
    p1.join();
    p2.join();
    for (cs) |t| t.join();
    try testing.expectEqual(@as(u32, 0), bad.load(.monotonic));
    try testing.expectEqual(@as(u64, 2 * N), ch.peekVersion());
}

test "LatestValue: un productor — el valor de cada snapshot es EXACTAMENTE el de su versión (TSAN)" {
    // Con un solo productor que publica a = k en la k-ésima publicación, la
    // versión N identifica el valor N. El defecto del original (versión leída
    // fuera del mutex, subida tras soltarlo) entregaba el valor N+1 con la
    // etiqueta N: esta comprobación lo caza.
    const N = 50_000;
    var ch = LatestValue(Sample).init(.{});
    defer ch.deinit();
    const Prod = struct {
        fn run(c: *LatestValue(Sample)) void {
            for (1..N + 1) |k| _ = c.publish(.{ .a = k, .b = k });
        }
    };
    const p = try std.Thread.spawn(.{}, Prod.run, .{&ch});
    var seen: u64 = 0;
    var mismatches: u32 = 0;
    while (seen < N) {
        const s = ch.consumeSince(seen) orelse continue;
        if (s.value.a != s.version) mismatches += 1;
        seen = s.version;
    }
    p.join();
    try testing.expectEqual(@as(u32, 0), mismatches);
}
