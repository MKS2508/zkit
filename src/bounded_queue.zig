//! BoundedQueue(T) — cola FIFO acotada y thread-safe, con la política de
//! desborde como PARÁMETRO.
//!
//! Es la versión concurrente de `SubscriberQueue` (nodo `zkit/handle-concurrent`,
//! r44 #9 de styx) y la generalización de `PendingDeliveryQueue` de styx
//! (`moqt_pending_delivery.zig`), que llevaba mezclados la cola, la política
//! live/VOD, la espera por backpressure (con `nanosleep` de 0.5 ms en bucle)
//! y los contadores de dominio. Aquí queda la parte genérica:
//!
//!   - Anillo de capacidad fija reservado en `init`: `push` NUNCA reserva
//!     memoria, así que el hot path no tiene un `error.OutOfMemory` que
//!     convertir en pérdida silenciosa.
//!   - `Overflow.reject`: lleno ⇒ `.full` (o `pushWait` espera con un
//!     `Condition`, sin sondeo, hasta un plazo).
//!   - `Overflow.drop_oldest`: lleno ⇒ se expulsa el más viejo y se DEVUELVE
//!     al llamador (`.evicted`) para que libere lo que posea — la versión
//!     single-thread lo tiraba sin devolverlo, un leak para `T` con recursos.
//!     La siguiente `pop` devuelve `.discontinuity` (contrato de
//!     `SubscriberQueue`).
//!   - Drenado con RESERVA (`beginDrain`/`settleDrain`): lo que el consumidor
//!     se lleva para intentar entregar sigue contando contra la capacidad
//!     hasta que lo liquida; lo que no pudo entregar vuelve al FRENTE en
//!     orden. Invariante en todo instante: `len + reserved <= capacity`.
//!     Por eso `settleDrain` nunca desborda.
//!   - `close()` despierta a todos los que esperan; `wakeAll()` también, para
//!     que un productor que espera re-mire su flag de cancelación.
//!
//! Los contadores de dominio (por pista, por sesión) se quedan en el
//! consumidor; aquí sólo hay agregados baratos en `stats()`.

const std = @import("std");
const sync = @import("sync.zig");
const time = @import("time.zig");

pub const Overflow = enum {
    /// Lleno ⇒ el push falla (`.full`) o espera (`pushWait`). Sin pérdida.
    reject,
    /// Lleno ⇒ se expulsa el más viejo (devuelto al llamador) y se marca
    /// discontinuidad. Para colas "live" donde lo reciente vale más.
    drop_oldest,
};

pub const Options = struct {
    capacity: usize,
    overflow: Overflow,
};

pub fn BoundedQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const InitError = error{ InvalidParameter, OutOfMemory };
        pub const Error = error{Closed};
        pub const WaitError = error{ Closed, Timeout, Cancelled };

        pub const PushResult = union(enum) {
            ok,
            /// `.drop_oldest`: entró, a cambio de expulsar éste (el llamador
            /// es su dueño ahora).
            evicted: T,
            /// No entró: `.reject` lleno, o `.drop_oldest` con todo reservado
            /// por un drenado en curso (no se puede expulsar lo que el
            /// consumidor tiene en la mano).
            full,
        };

        pub const PopResult = union(enum) {
            item: T,
            /// Se perdieron items (`.drop_oldest`) desde la última `pop`.
            discontinuity,
            empty,
        };

        pub const Stats = struct {
            evicted: u64 = 0,
            rejected: u64 = 0,
            /// Episodios de espera en `pushWait` (no vueltas del bucle).
            waited: u64 = 0,
        };

        allocator: std.mem.Allocator,
        mutex: sync.Mutex = .{},
        not_empty: sync.Condition = .{},
        not_full: sync.Condition = .{},
        buf: []T,
        head: usize = 0,
        count: usize = 0,
        reserved: usize = 0,
        overflow: Overflow,
        discontinuity: bool = false,
        closed: bool = false,
        stats_: Stats = .{},

        pub fn init(allocator: std.mem.Allocator, opts: Options) InitError!Self {
            if (opts.capacity == 0) return error.InvalidParameter;
            return .{
                .allocator = allocator,
                .buf = try allocator.alloc(T, opts.capacity),
                .overflow = opts.overflow,
            };
        }

        /// Libera el anillo. Los items que queden NO se destruyen: si `T`
        /// posee recursos, vacíala antes con `drainInto`.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.reserved == 0);
            self.allocator.free(self.buf);
            self.not_full.deinit();
            self.not_empty.deinit();
            self.mutex.deinit();
            self.* = undefined;
        }

        pub fn capacity(self: *const Self) usize {
            return self.buf.len;
        }

        pub fn len(self: *Self) usize {
            const h = self.mutex.acquire();
            defer h.release();
            return self.count;
        }

        pub fn reservedCount(self: *Self) usize {
            const h = self.mutex.acquire();
            defer h.release();
            return self.reserved;
        }

        pub fn stats(self: *Self) Stats {
            const h = self.mutex.acquire();
            defer h.release();
            return self.stats_;
        }

        /// Cierra la cola: los `push` posteriores fallan con `error.Closed`, y
        /// los que esperan se despiertan. Lo ya encolado se puede seguir
        /// sacando.
        pub fn close(self: *Self) void {
            {
                const h = self.mutex.acquire();
                defer h.release();
                self.closed = true;
            }
            self.not_full.broadcast();
            self.not_empty.broadcast();
        }

        /// Despierta a todos los que esperan para que re-evalúen su plazo o
        /// su flag de cancelación.
        pub fn wakeAll(self: *Self) void {
            // Tomar el mutex ordena el cambio del flag del llamador antes del
            // despertar (sin él, un waiter podría leer el flag viejo y dormir
            // después del broadcast).
            self.mutex.lock();
            self.mutex.unlock();
            self.not_full.broadcast();
            self.not_empty.broadcast();
        }

        /// Encola sin bloquear.
        pub fn push(self: *Self, item: T) Error!PushResult {
            const r = blk: {
                const h = self.mutex.acquire();
                defer h.release();
                if (self.closed) return error.Closed;
                break :blk self.pushLocked(item);
            };
            if (r != .full) self.not_empty.signal();
            return r;
        }

        /// Encola; con `.reject` y la cola llena espera (sin sondeo) a que
        /// haya sitio hasta `deadline`. `cancel` se re-evalúa en cada
        /// despertar: quien lo pone a `true` debe llamar a `wakeAll()`.
        /// Con `.drop_oldest` no espera nunca (salvo todo-reservado).
        pub fn pushWait(
            self: *Self,
            item: T,
            deadline: time.Deadline,
            cancel: ?*const std.atomic.Value(bool),
        ) WaitError!PushResult {
            const r = blk: {
                const h = self.mutex.acquire();
                defer h.release();
                var counted = false;
                while (true) {
                    if (self.closed) return error.Closed;
                    if (cancel) |flag| if (flag.load(.acquire)) {
                        self.stats_.rejected += 1;
                        return error.Cancelled;
                    };
                    if (self.count + self.reserved < self.buf.len or
                        (self.overflow == .drop_oldest and self.count > 0))
                    {
                        break :blk self.pushLocked(item);
                    }
                    if (!counted) {
                        counted = true;
                        self.stats_.waited += 1;
                    }
                    self.not_full.waitUntil(&self.mutex, deadline) catch {
                        self.stats_.rejected += 1;
                        return error.Timeout;
                    };
                }
            };
            self.not_empty.signal();
            return r;
        }

        fn pushLocked(self: *Self, item: T) PushResult {
            if (self.count + self.reserved < self.buf.len) {
                self.buf[(self.head + self.count) % self.buf.len] = item;
                self.count += 1;
                return .ok;
            }
            if (self.overflow == .drop_oldest and self.count > 0) {
                // Fuera el más viejo, dentro el nuevo al final. Físicamente
                // siempre hay hueco: el anillo guarda `count` items y lo
                // reservado ya salió de él (`count < buf.len`).
                const old = self.buf[self.head];
                self.head = (self.head + 1) % self.buf.len;
                self.buf[(self.head + self.count - 1) % self.buf.len] = item;
                self.discontinuity = true;
                self.stats_.evicted += 1;
                return .{ .evicted = old };
            }
            self.stats_.rejected += 1;
            return .full;
        }

        /// Saca el más viejo sin bloquear.
        pub fn pop(self: *Self) PopResult {
            const r = blk: {
                const h = self.mutex.acquire();
                defer h.release();
                break :blk self.popLocked();
            };
            if (r == .item) self.not_full.signal();
            return r;
        }

        /// Como `pop`, esperando hasta `deadline` si está vacía.
        /// `error.Closed` sólo cuando está cerrada Y vacía.
        pub fn popWait(self: *Self, deadline: time.Deadline) error{ Closed, Timeout }!PopResult {
            const r = blk: {
                const h = self.mutex.acquire();
                defer h.release();
                while (true) {
                    const got = self.popLocked();
                    if (got != .empty) break :blk got;
                    if (self.closed) return error.Closed;
                    try self.not_empty.waitUntil(&self.mutex, deadline);
                }
            };
            if (r == .item) self.not_full.signal();
            return r;
        }

        fn popLocked(self: *Self) PopResult {
            if (self.discontinuity) {
                self.discontinuity = false;
                return .discontinuity;
            }
            if (self.count == 0) return .empty;
            const item = self.buf[self.head];
            self.head = (self.head + 1) % self.buf.len;
            self.count -= 1;
            return .{ .item = item };
        }

        /// `true` (una vez) si hubo expulsiones desde la última consulta.
        /// Para consumidores por lotes que no usan `pop`.
        pub fn takeDiscontinuity(self: *Self) bool {
            const h = self.mutex.acquire();
            defer h.release();
            defer self.discontinuity = false;
            return self.discontinuity;
        }

        /// Mueve hasta `out.len` items a `out` (propiedad plena, sin reserva).
        pub fn drainInto(self: *Self, out: []T) usize {
            const n = self.takeLocked(out, false);
            if (n > 0) self.not_full.broadcast();
            return n;
        }

        /// Como `drainInto`, pero lo sacado SIGUE contando contra la
        /// capacidad hasta `settleDrain`. Un único consumidor: begin/settle
        /// estrictamente emparejados.
        pub fn beginDrain(self: *Self, out: []T) usize {
            return self.takeLocked(out, true);
        }

        /// Liquida el drenado en curso: `held` (lo que NO se pudo entregar,
        /// en su orden original, prefijo o subconjunto ordenado de lo sacado)
        /// vuelve al FRENTE. Siempre cabe (invariante `len + reserved <=
        /// capacity`).
        pub fn settleDrain(self: *Self, held: []const T) void {
            {
                const h = self.mutex.acquire();
                defer h.release();
                std.debug.assert(held.len <= self.reserved);
                self.reserved = 0;
                const n = self.buf.len;
                var i = held.len;
                while (i > 0) {
                    i -= 1;
                    self.head = (self.head + n - 1) % n;
                    self.buf[self.head] = held[i];
                    self.count += 1;
                }
                std.debug.assert(self.count <= n);
            }
            self.not_full.broadcast();
            if (held.len > 0) self.not_empty.signal();
        }

        fn takeLocked(self: *Self, out: []T, reserve: bool) usize {
            const h = self.mutex.acquire();
            defer h.release();
            if (reserve) std.debug.assert(self.reserved == 0);
            const n = @min(out.len, self.count);
            for (out[0..n]) |*o| {
                o.* = self.buf[self.head];
                self.head = (self.head + 1) % self.buf.len;
            }
            self.count -= n;
            if (reserve) self.reserved = n;
            return n;
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "reject: FIFO, lleno ⇒ .full contado, pop libera sitio" {
    var q = try BoundedQueue(u32).init(testing.allocator, .{ .capacity = 3, .overflow = .reject });
    defer q.deinit();
    for (0..3) |i| try testing.expectEqual(.ok, try q.push(@intCast(i)));
    try testing.expectEqual(.full, try q.push(9));
    try testing.expectEqual(@as(u32, 0), q.pop().item);
    try testing.expectEqual(.ok, try q.push(3));
    for (1..4) |i| try testing.expectEqual(@as(u32, @intCast(i)), q.pop().item);
    try testing.expectEqual(.empty, q.pop());
    try testing.expectEqual(@as(u64, 1), q.stats().rejected);
}

test "drop_oldest: expulsa y devuelve el más viejo, marca discontinuidad una vez" {
    var q = try BoundedQueue(u32).init(testing.allocator, .{ .capacity = 2, .overflow = .drop_oldest });
    defer q.deinit();
    _ = try q.push(1);
    _ = try q.push(2);
    try testing.expectEqual(@as(u32, 1), (try q.push(3)).evicted);
    try testing.expectEqual(@as(u32, 2), (try q.push(4)).evicted);
    try testing.expectEqual(.discontinuity, q.pop());
    try testing.expectEqual(@as(u32, 3), q.pop().item);
    try testing.expectEqual(@as(u32, 4), q.pop().item);
    try testing.expectEqual(.empty, q.pop());
    try testing.expectEqual(@as(u64, 2), q.stats().evicted);
}

test "reserva: len + reserved <= capacity en todo instante; settle devuelve al frente en orden" {
    var q = try BoundedQueue(u32).init(testing.allocator, .{ .capacity = 4, .overflow = .reject });
    defer q.deinit();
    for (0..4) |i| _ = try q.push(@intCast(i));
    var out: [4]u32 = undefined;
    try testing.expectEqual(@as(usize, 3), q.beginDrain(out[0..3]));
    // 1 en cola + 3 reservados = lleno: el productor no puede rellenar.
    try testing.expectEqual(.full, try q.push(10));
    // Se entregó sólo el 0; 1 y 2 vuelven al frente, delante del 3.
    q.settleDrain(out[1..3]);
    try testing.expectEqual(.ok, try q.push(10));
    const want = [_]u32{ 1, 2, 3, 10 };
    for (want) |w| try testing.expectEqual(w, q.pop().item);
}

test "drop_oldest con reserva: expulsa sólo de lo encolado y conserva el orden" {
    var q = try BoundedQueue(u32).init(testing.allocator, .{ .capacity = 4, .overflow = .drop_oldest });
    defer q.deinit();
    for (0..4) |i| _ = try q.push(@intCast(i));
    var out: [2]u32 = undefined;
    try testing.expectEqual(@as(usize, 2), q.beginDrain(&out)); // 0,1 en mano; 2,3 en cola
    try testing.expectEqual(@as(u32, 2), (try q.push(4)).evicted); // cola: 3,4
    try testing.expectEqual(@as(u32, 3), (try q.push(5)).evicted); // cola: 4,5
    q.settleDrain(&out); // 0,1 vuelven: 0,1,4,5
    const want = [_]u32{ 0, 1 };
    try testing.expectEqual(.discontinuity, q.pop());
    for (want) |w| try testing.expectEqual(w, q.pop().item);
    try testing.expectEqual(@as(u32, 4), q.pop().item);
    try testing.expectEqual(@as(u32, 5), q.pop().item);
    // Todo reservado: no hay nada que expulsar ⇒ .full.
    _ = try q.push(6);
    _ = try q.push(7);
    _ = try q.push(8);
    _ = try q.push(9);
    var all: [4]u32 = undefined;
    try testing.expectEqual(@as(usize, 4), q.beginDrain(&all));
    try testing.expectEqual(.full, try q.push(10));
    q.settleDrain(&.{});
}

test "pushWait: vence con Timeout, se cancela con wakeAll y termina con close" {
    var q = try BoundedQueue(u32).init(testing.allocator, .{ .capacity = 1, .overflow = .reject });
    defer q.deinit();
    _ = try q.push(1);
    try testing.expectError(error.Timeout, q.pushWait(2, time.Deadline.fromNow(2 * time.ns_per_ms), null));

    const Ctx = struct {
        fn canceller(qq: *BoundedQueue(u32), flag: *std.atomic.Value(bool)) void {
            time.sleepNs(3 * time.ns_per_ms);
            flag.store(true, .release);
            qq.wakeAll();
        }
    };
    var flag: std.atomic.Value(bool) = .init(false);
    const t = try std.Thread.spawn(.{}, Ctx.canceller, .{ &q, &flag });
    try testing.expectError(error.Cancelled, q.pushWait(2, .never, &flag));
    t.join();

    q.close();
    try testing.expectError(error.Closed, q.push(3));
    try testing.expectEqual(@as(u32, 1), (try q.popWait(.never)).item);
    try testing.expectError(error.Closed, q.popWait(.never));
    try testing.expect(q.stats().waited >= 2);
}

test "estrés MPSC: 4 productores bloqueantes x 5k, 1 consumidor por lotes con reserva — sin pérdida (TSAN)" {
    var q = try BoundedQueue(u64).init(testing.allocator, .{ .capacity = 16, .overflow = .reject });
    defer q.deinit();
    const P = 4;
    const N = 5_000;
    const Prod = struct {
        fn run(qq: *BoundedQueue(u64), id: u64) void {
            for (0..N) |i| {
                const r = qq.pushWait(id * N + i, .never, null) catch unreachable;
                std.debug.assert(r == .ok);
            }
        }
    };
    var ts: [P]std.Thread = undefined;
    for (&ts, 0..) |*t, k| t.* = try std.Thread.spawn(.{}, Prod.run, .{ &q, @as(u64, k) });

    const seen = try testing.allocator.alloc(bool, P * N);
    defer testing.allocator.free(seen);
    @memset(seen, false);
    var last: [P]i64 = @splat(-1);
    var got: usize = 0;
    var batch: [8]u64 = undefined;
    var round: usize = 0;
    const Check = struct {
        fn deliver(v: u64, last_: *[P]i64, seen_: []bool) !void {
            const prod = v / N;
            const seq: i64 = @intCast(v % N);
            // FIFO por productor aunque haya re-encolado.
            try testing.expect(seq > last_[prod]);
            last_[prod] = seq;
            try testing.expect(!seen_[v]);
            seen_[v] = true;
        }
    };
    while (got < P * N) : (round += 1) {
        const n = q.beginDrain(&batch);
        if (n == 0) {
            q.settleDrain(&.{});
            // Vacía: esperar sin sondeo al siguiente item.
            switch (try q.popWait(.never)) {
                .item => |v| {
                    try Check.deliver(v, &last, seen);
                    got += 1;
                },
                else => {},
            }
            continue;
        }
        // Cada tres rondas se entrega la mitad; el resto vuelve al frente
        // (simula un envío parcial que el transporte no aceptó).
        const deliver = if (round % 3 == 0) n / 2 else n;
        for (batch[0..deliver]) |v| try Check.deliver(v, &last, seen);
        got += deliver;
        q.settleDrain(batch[deliver..n]);
    }
    for (ts) |t| t.join();
    for (seen) |s| try testing.expect(s);
}
