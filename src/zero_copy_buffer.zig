//! ZeroCopyBuffer + BufferGuard — buffer refcontado de una sola reserva para
//! fanout sin copias, y su guarda de ciclo de vida para el productor.
//!
//! ZeroCopyBuffer (patrón `FrameBuf` de moq-dev):
//!   - Una reserva alineada a página (apta para sendfile/sendmsg).
//!   - Un productor escribe en `writableSlice()` y publica con `commit(n)`
//!     (store `.release`); N consumidores leen `view()` (load `.acquire`) y
//!     sólo ven bytes confirmados.
//!   - Fanout = `acquire()` N veces (un incremento atómico cada una), cero
//!     copias de payload. `release()` libera al llegar a 0.
//!
//! BufferGuard (patrón `GroupProducer::drop/abort` de moq-dev):
//!   - `finish()`: cierre limpio; la referencia del productor pasa a los
//!     consumidores (el buffer sobrevive hasta que lo suelten).
//!   - `abort()`: cierre sucio; suelta la referencia ya.
//!   - `drop()`: para `defer`; si nadie llamó a `finish`, es un `abort`.
//!
//! Origen: `styx/native/zig/media-core/source/buffer/{zero_copy_buffer,lifecycle}.zig`.
//! Arreglado al portar:
//!   - Doble `release`: el original "saturaba" el contador a 0 y seguía con un
//!     warning. Pero si la referencia anterior ya había llegado a 0, el
//!     buffer YA estaba liberado y ese mismo `fetchSub` era un use-after-free:
//!     no hay nada que saturar. Ahora es pánico en todos los modos (es un
//!     bug del llamador que ya corrompió memoria; seguir es peor).
//!   - `acquire` sobre un contador a 0 (resucitar un buffer liberado): pánico.
//!   - `commit(n)` con `n > capacidad`: pánico en todos los modos (antes
//!     `assert`, que desaparece en ReleaseFast y deja a los consumidores leer
//!     fuera del buffer).
//!   - `BufferGuard.init` ya no pide un allocator que no usaba.

const std = @import("std");

pub const page_size = std.heap.page_size_min;
const backing_align: std.mem.Alignment = .fromByteUnits(std.heap.page_size_min);

pub const ZeroCopyBuffer = struct {
    data: []align(backing_align.toByteUnits()) u8,
    committed_len: std.atomic.Value(usize) = .init(0),
    refcount: std.atomic.Value(usize) = .init(1),
    allocator: std.mem.Allocator,

    /// Reserva `capacity` bytes alineados a página. Refcount inicial 1: el
    /// llamador debe un `release()` (más uno por cada `acquire()`).
    pub fn init(allocator: std.mem.Allocator, cap: usize) error{OutOfMemory}!*ZeroCopyBuffer {
        const self = try allocator.create(ZeroCopyBuffer);
        errdefer allocator.destroy(self);
        const buf = try allocator.alignedAlloc(u8, backing_align, cap);
        self.* = .{ .data = buf, .allocator = allocator };
        return self;
    }

    /// Una referencia más. Pánico si el buffer ya no tenía ninguna.
    pub fn acquire(self: *ZeroCopyBuffer) *ZeroCopyBuffer {
        const prev = self.refcount.fetchAdd(1, .monotonic);
        if (prev == 0) @panic("ZeroCopyBuffer.acquire sobre un buffer ya liberado");
        return self;
    }

    /// Suelta una referencia; con la última libera. Tras llamarla, `self`
    /// no se toca. Pánico ante un `release` de más.
    pub fn release(self: *ZeroCopyBuffer) void {
        const prev = self.refcount.fetchSub(1, .release);
        if (prev == 0) @panic("ZeroCopyBuffer.release de más (refcount ya era 0)");
        if (prev == 1) {
            // Pareja del `.release` de los demás: todas sus escrituras son
            // visibles antes de liberar.
            _ = self.refcount.load(.acquire);
            const gpa = self.allocator;
            gpa.free(self.data);
            gpa.destroy(self);
        }
    }

    /// Publica los primeros `n` bytes (sólo el productor).
    pub fn commit(self: *ZeroCopyBuffer, n: usize) void {
        if (n > self.data.len) @panic("ZeroCopyBuffer.commit más allá de la capacidad");
        self.committed_len.store(n, .release);
    }

    /// Bytes confirmados, sin copia. No se liberan vía el slice.
    pub fn view(self: *const ZeroCopyBuffer) []const u8 {
        return self.data[0..self.committed_len.load(.acquire)];
    }

    /// Toda la capacidad, para que el productor escriba (sólo el productor).
    pub fn writableSlice(self: *ZeroCopyBuffer) []u8 {
        return self.data;
    }

    pub fn capacity(self: *const ZeroCopyBuffer) usize {
        return self.data.len;
    }

    /// Valor instantáneo del contador (diagnóstico; no sincroniza nada).
    pub fn refcountValue(self: *const ZeroCopyBuffer) usize {
        return self.refcount.load(.monotonic);
    }
};

pub const GuardState = enum { active, finished, aborted };

pub const BufferGuard = struct {
    /// La referencia del productor, o `null` tras finish/abort.
    buffer: ?*ZeroCopyBuffer,
    state: GuardState = .active,

    /// Toma posesión de UNA referencia de `buffer`.
    pub fn init(buffer: *ZeroCopyBuffer) BufferGuard {
        return .{ .buffer = buffer };
    }

    /// Cierre limpio: la referencia pasa a los consumidores (no se suelta).
    pub fn finish(self: *BufferGuard) void {
        if (self.state != .active) return;
        self.state = .finished;
        self.buffer = null;
    }

    /// Cierre sucio: suelta la referencia ya.
    pub fn abort(self: *BufferGuard) void {
        if (self.state != .active) return;
        self.state = .aborted;
        if (self.buffer) |b| b.release();
        self.buffer = null;
    }

    /// Para `defer guard.drop()`: sin `finish` previo equivale a `abort`.
    pub fn drop(self: *BufferGuard) void {
        if (self.state == .active) self.abort();
    }

    pub fn bufferOrNull(self: *const BufferGuard) ?*ZeroCopyBuffer {
        return self.buffer;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "ZeroCopyBuffer: init + release libera; alineado a página" {
    const buf = try ZeroCopyBuffer.init(testing.allocator, 4096);
    try testing.expectEqual(@as(usize, 4096), buf.capacity());
    try testing.expect(std.mem.isAligned(@intFromPtr(buf.data.ptr), page_size));
    try testing.expectEqual(@as(usize, 1), buf.refcountValue());
    try testing.expectEqual(@as(usize, 0), buf.view().len);
    buf.release();
}

test "ZeroCopyBuffer: init no fuga si falla la segunda reserva" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    try testing.expectError(error.OutOfMemory, ZeroCopyBuffer.init(failing.allocator(), 64));
}

test "ZeroCopyBuffer: commit expone sólo lo confirmado y view no copia" {
    const buf = try ZeroCopyBuffer.init(testing.allocator, 256);
    defer buf.release();
    const w = buf.writableSlice();
    @memcpy(w[0..5], "hello");
    try testing.expectEqual(@as(usize, 0), buf.view().len);
    buf.commit(3);
    try testing.expectEqualStrings("hel", buf.view());
    buf.commit(5);
    try testing.expectEqualStrings("hello", buf.view());
    try testing.expectEqual(@intFromPtr(w.ptr), @intFromPtr(buf.view().ptr));
}

test "ZeroCopyBuffer: fanout concurrente acquire/release termina liberado (TSAN)" {
    const buf = try ZeroCopyBuffer.init(testing.allocator, 64);
    @memcpy(buf.writableSlice()[0..3], "abc");
    buf.commit(3);
    const W = struct {
        fn run(b: *ZeroCopyBuffer) void {
            for (0..2_000) |_| {
                const r = b.acquire();
                std.debug.assert(std.mem.eql(u8, r.view(), "abc"));
                r.release();
            }
        }
    };
    var ts: [4]std.Thread = undefined;
    for (&ts) |*t| t.* = try std.Thread.spawn(.{}, W.run, .{buf});
    for (ts) |t| t.join();
    try testing.expectEqual(@as(usize, 1), buf.refcountValue());
    buf.release();
}

test "ZeroCopyBuffer: el último release en otro hilo libera (TSAN: happens-before del free)" {
    const buf = try ZeroCopyBuffer.init(testing.allocator, 32);
    const W = struct {
        fn run(b: *ZeroCopyBuffer) void {
            b.writableSlice()[0] = 7;
            b.commit(1);
            b.release();
        }
    };
    _ = buf.acquire();
    const t = try std.Thread.spawn(.{}, W.run, .{buf});
    buf.release();
    t.join();
}

fn makeBuffer(payload: []const u8) !*ZeroCopyBuffer {
    const buf = try ZeroCopyBuffer.init(testing.allocator, payload.len);
    @memcpy(buf.writableSlice()[0..payload.len], payload);
    buf.commit(payload.len);
    return buf;
}

test "BufferGuard: finish+drop conserva el buffer para el consumidor" {
    const buf = try makeBuffer("cached-frame");
    var guard = BufferGuard.init(buf);
    guard.finish();
    guard.drop();
    try testing.expectEqual(@as(?*ZeroCopyBuffer, null), guard.bufferOrNull());
    try testing.expectEqualStrings("cached-frame", buf.view());
    buf.release(); // el consumidor suelta la referencia heredada
}

test "BufferGuard: abort y drop sucio liberan; consumidor con ref propia sobrevive" {
    {
        var guard = BufferGuard.init(try makeBuffer("doomed"));
        guard.abort();
        try testing.expectEqual(GuardState.aborted, guard.state);
        guard.abort(); // idempotente
    }
    {
        var guard = BufferGuard.init(try makeBuffer("dirty"));
        guard.drop();
        try testing.expectEqual(GuardState.aborted, guard.state);
    }
    {
        const buf = try makeBuffer("shared");
        const consumer = buf.acquire();
        var guard = BufferGuard.init(buf);
        guard.drop();
        try testing.expectEqualStrings("shared", consumer.view());
        consumer.release();
    }
}

test "BufferGuard: 1000 guardas con defer drop y cierres mezclados — cero supervivientes" {
    for (0..1000) |i| {
        const buf = try makeBuffer("frame");
        var guard = BufferGuard.init(buf);
        defer guard.drop();
        switch (i % 3) {
            0 => {
                guard.finish();
                buf.release();
            },
            1 => guard.abort(),
            else => {},
        }
    }
}
