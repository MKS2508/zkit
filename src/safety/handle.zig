//! zkit.safety.Handle / TypedSlab — handles generacionales con TIPO.
//!
//! `HandleSlab` ya hace imposible el use-after-free por handle obsoleto (la
//! generación no coincide ⇒ `null`). Lo que no impide es CONFUNDIR handles:
//! todos son `u64`, así que pasar el handle de una sesión donde se espera el
//! de un buffer compila y, si el slot existe en el otro slab, resuelve a un
//! objeto ajeno. `Handle(Tag)` es un `enum(u64)` distinto por cada `Tag`:
//! mezclarlos es un error de compilación, y cruzar la frontera FFI exige un
//! `fromRaw`/`raw` explícito.
//!
//!     const SessionTag = struct {};
//!     var sessions = try TypedSlab(*Session, SessionTag, .{}).init(gpa, 64);
//!     const h = try sessions.alloc(s);      // h: Handle(SessionTag)
//!     buffers.get(h);                       // error de compilación
//!
//! `.thread_safe = true` usa `ConcurrentHandleSlab` y expone `lock(h)`.

const std = @import("std");
const HandleSlab = @import("../handle.zig").HandleSlab;
const ConcurrentHandleSlab = @import("../handle_concurrent.zig").ConcurrentHandleSlab;

/// Handle opaco con tipo. `none` (0) nunca es un handle vivo.
pub fn Handle(comptime Tag: type) type {
    return enum(u64) {
        none = 0,
        _,

        pub const Kind = Tag;

        /// Para cruzar una frontera FFI/IPC hacia fuera.
        pub fn raw(h: @This()) u64 {
            return @backingInt(h);
        }

        /// Para aceptar un handle que viene de fuera. No valida nada: el
        /// slab rechaza (null) lo que no sea un handle vivo suyo.
        pub fn fromRaw(v: u64) @This() {
            return @fromBackingInt(@intCast(v));
        }
    };
}

pub const SlabOptions = struct {
    thread_safe: bool = false,
};

pub fn TypedSlab(comptime T: type, comptime Tag: type, comptime opts: SlabOptions) type {
    return struct {
        const Self = @This();
        const Inner = if (opts.thread_safe) ConcurrentHandleSlab(T) else HandleSlab(T);

        pub const H = Handle(Tag);
        pub const InitError = Inner.InitError;
        pub const AllocError = Inner.AllocError;

        inner: Inner,

        pub fn init(allocator: std.mem.Allocator, capacity: u32) InitError!Self {
            return .{ .inner = try Inner.init(allocator, capacity) };
        }

        pub fn deinit(self: *Self) void {
            self.inner.deinit();
        }

        pub fn alloc(self: *Self, value: T) AllocError!H {
            return H.fromRaw(try self.inner.alloc(value));
        }

        pub fn get(self: *Self, h: H) ?T {
            return self.inner.get(h.raw());
        }

        pub fn take(self: *Self, h: H) ?T {
            return self.inner.take(h.raw());
        }

        pub fn free(self: *Self, h: H) void {
            _ = self.inner.take(h.raw());
        }

        pub fn activeCount(self: *Self) u32 {
            return self.inner.activeCount();
        }

        pub const Locked = if (opts.thread_safe) Inner.Locked else void;

        /// Sólo con `.thread_safe`: resuelve y deja el slab bloqueado.
        pub fn lock(self: *Self, h: H) ?Locked {
            if (!opts.thread_safe) @compileError("TypedSlab.lock requiere .thread_safe = true");
            return self.inner.lock(h.raw());
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const SessionTag = struct {};
const BufferTag = struct {};

test "TypedSlab: handles de tags distintos son tipos distintos; stale ⇒ null" {
    try testing.expect(Handle(SessionTag) != Handle(BufferTag));
    try testing.expect(Handle(SessionTag) == Handle(SessionTag));
    // Ni siquiera coercionan entre sí ni desde u64 sin fromRaw.
    try testing.expect(!@hasDecl(Handle(SessionTag), "fromHandle"));

    var sessions = try TypedSlab(u32, SessionTag, .{}).init(testing.allocator, 4);
    defer sessions.deinit();
    const h = try sessions.alloc(10);
    try testing.expect(h != .none);
    try testing.expectEqual(@as(?u32, 10), sessions.get(h));
    try testing.expectEqual(@as(?u32, 10), sessions.take(h));
    try testing.expectEqual(@as(?u32, null), sessions.get(h)); // UAF por handle: imposible
    const h2 = try sessions.alloc(11);
    try testing.expect(h2 != h); // mismo slot, otra generación
    try testing.expectEqual(@as(?u32, null), sessions.get(.none));
    // Ida y vuelta por la frontera FFI.
    try testing.expectEqual(@as(?u32, 11), sessions.get(.fromRaw(h2.raw())));
    try testing.expectEqual(@as(?u32, null), sessions.get(.fromRaw(0xFFFF_0000_0000_0003)));
}

test "TypedSlab thread_safe: lock expone el valor con el slab bloqueado" {
    var bufs = try TypedSlab(u64, BufferTag, .{ .thread_safe = true }).init(testing.allocator, 2);
    defer bufs.deinit();
    const h = try bufs.alloc(99);
    {
        const l = bufs.lock(h).?;
        defer l.unlock();
        try testing.expectEqual(@as(u64, 99), l.value);
    }
    bufs.free(h);
    try testing.expect(bufs.lock(h) == null);
    try testing.expectEqual(@as(u32, 0), bufs.activeCount());
}
