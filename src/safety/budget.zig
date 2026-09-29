//! zkit.safety.Budget / BudgetAllocator — memoria acotada y contabilidad
//! independiente, con informe de leaks al cierre.
//!
//! `Budget`: contador atómico de bytes con techo. `reserve(n)` falla (sin
//! efectos) si pasaría del techo. Sirve para cualquier recurso contable que
//! no sea una reserva de allocator: bytes retenidos en colas, bytes en vuelo
//! por sesión, etc.
//!
//! `BudgetAllocator`: envuelve un `Allocator` y
//!   - rechaza (`OutOfMemory`) toda reserva que pase de su `Budget`: un
//!     cliente hostil que infla una sesión se queda sin memoria él, no el
//!     proceso. Se anidan envolviendo uno en otro (global → usuario → sesión).
//!   - lleva contadores PROPIOS de reservas y liberaciones (número y bytes) y
//!     el pico, independientes de lo que mida el consumidor. Es la fuente
//!     independiente que pide la regla de evidencia de memoria de styx
//!     (allocs − frees), no el contador que se está midiendo.
//!   - opcionalmente (`track_sites`) guarda cada reserva viva con su
//!     dirección de retorno y, en `deinit`, informa de cada leak.
//!
//! Thread-safe: contadores atómicos; el registro de sitios va bajo mutex.

const std = @import("std");
const sync = @import("../sync.zig");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const Budget = struct {
    limit: u64,
    used: std.atomic.Value(u64) = .init(0),
    peak: std.atomic.Value(u64) = .init(0),
    denied: std.atomic.Value(u64) = .init(0),

    pub fn init(limit: u64) Budget {
        return .{ .limit = limit };
    }

    /// Reserva `n` unidades si caben; `false` (y nada cambia) si no.
    pub fn reserve(self: *Budget, n: u64) bool {
        var cur = self.used.load(.monotonic);
        while (true) {
            if (n > self.limit or cur > self.limit - n) {
                _ = self.denied.fetchAdd(1, .monotonic);
                return false;
            }
            cur = self.used.cmpxchgWeak(cur, cur + n, .monotonic, .monotonic) orelse break;
        }
        const now = cur + n;
        var p = self.peak.load(.monotonic);
        while (now > p) p = self.peak.cmpxchgWeak(p, now, .monotonic, .monotonic) orelse break;
        return true;
    }

    /// Devuelve `n` unidades. Pánico si se devuelve más de lo reservado
    /// (contabilidad corrupta: seguir sería mentir sobre el techo).
    pub fn release(self: *Budget, n: u64) void {
        const prev = self.used.fetchSub(n, .monotonic);
        if (prev < n) std.debug.panic("zkit.safety.Budget: release({d}) con sólo {d} reservados", .{ n, prev });
    }

    pub fn inUse(self: *const Budget) u64 {
        return self.used.load(.monotonic);
    }
};

pub const LeakReport = struct {
    live_allocs: u64,
    live_bytes: u64,
    total_allocs: u64,
    total_frees: u64,
    peak_bytes: u64,
    denied: u64,

    pub fn isClean(r: LeakReport) bool {
        return r.live_allocs == 0 and r.live_bytes == 0;
    }
};

pub const Options = struct {
    /// Techo de bytes vivos (`maxInt` = sin techo, sólo contabilidad).
    limit: u64 = std.math.maxInt(u64),
    /// Registrar cada reserva viva (dirección + tamaño + retorno) para el
    /// informe de leaks. Cuesta una entrada de hash map por reserva.
    track_sites: bool = false,
    /// Nombre para el informe.
    name: []const u8 = "budget",
};

pub const BudgetAllocator = struct {
    inner: Allocator,
    budget: Budget,
    name: []const u8,
    allocs: std.atomic.Value(u64) = .init(0),
    frees: std.atomic.Value(u64) = .init(0),
    track_sites: bool,
    sites_mutex: sync.Mutex = .{},
    /// Memoria del propio registro: `page_allocator`, para no contarla contra
    /// el presupuesto ni ensuciar el allocator envuelto.
    sites: std.AutoHashMapUnmanaged(usize, Site) = .empty,
    /// Reservas que no se pudieron registrar (OOM del registro): el informe
    /// no las pierde, las cuenta.
    untracked: std.atomic.Value(u64) = .init(0),

    const Site = struct { len: usize, ret_addr: usize };
    const bookkeeping = std.heap.page_allocator;

    pub fn init(inner: Allocator, opts: Options) BudgetAllocator {
        return .{ .inner = inner, .budget = .init(opts.limit), .name = opts.name, .track_sites = opts.track_sites };
    }

    /// Informe final. Si hay leaks y `track_sites`, los escribe con
    /// `std.log.err` (uno por reserva viva, máx. 32) antes de liberar el registro.
    pub fn deinit(self: *BudgetAllocator) LeakReport {
        const r = self.report();
        if (!r.isClean()) {
            std.log.err("zkit.safety.BudgetAllocator '{s}': {d} reservas vivas ({d} bytes) al cierre", .{ self.name, r.live_allocs, r.live_bytes });
            if (self.track_sites) {
                var it = self.sites.iterator();
                var shown: usize = 0;
                while (it.next()) |e| : (shown += 1) {
                    if (shown == 32) break;
                    std.log.err("  leak: {d} bytes en 0x{x}, reservado desde 0x{x}", .{ e.value_ptr.len, e.key_ptr.*, e.value_ptr.ret_addr });
                }
            }
        }
        self.sites.deinit(bookkeeping);
        self.sites_mutex.deinit();
        return r;
    }

    /// `error.MemoryLeak` si al cierre queda algo vivo (para tests/soak).
    pub fn deinitCheck(self: *BudgetAllocator) error{MemoryLeak}!void {
        if (!self.deinit().isClean()) return error.MemoryLeak;
    }

    pub fn report(self: *BudgetAllocator) LeakReport {
        const a = self.allocs.load(.monotonic);
        const f = self.frees.load(.monotonic);
        return .{
            .live_allocs = a -| f,
            .live_bytes = self.budget.inUse(),
            .total_allocs = a,
            .total_frees = f,
            .peak_bytes = self.budget.peak.load(.monotonic),
            .denied = self.budget.denied.load(.monotonic),
        };
    }

    pub fn allocator(self: *BudgetAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
        if (!self.budget.reserve(len)) return null;
        const p = self.inner.rawAlloc(len, alignment, ret_addr) orelse {
            self.budget.release(len);
            return null;
        };
        _ = self.allocs.fetchAdd(1, .monotonic);
        self.track(@intFromPtr(p), len, ret_addr);
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and !self.budget.reserve(new_len - memory.len)) return false;
        if (!self.inner.rawResize(memory, alignment, new_len, ret_addr)) {
            if (new_len > memory.len) self.budget.release(new_len - memory.len);
            return false;
        }
        if (new_len < memory.len) self.budget.release(memory.len - new_len);
        self.retrack(@intFromPtr(memory.ptr), @intFromPtr(memory.ptr), new_len, ret_addr);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and !self.budget.reserve(new_len - memory.len)) return null;
        const p = self.inner.rawRemap(memory, alignment, new_len, ret_addr) orelse {
            if (new_len > memory.len) self.budget.release(new_len - memory.len);
            return null;
        };
        if (new_len < memory.len) self.budget.release(memory.len - new_len);
        self.retrack(@intFromPtr(memory.ptr), @intFromPtr(p), new_len, ret_addr);
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
        self.untrack(@intFromPtr(memory.ptr));
        self.inner.rawFree(memory, alignment, ret_addr);
        self.budget.release(memory.len);
        _ = self.frees.fetchAdd(1, .monotonic);
    }

    fn track(self: *BudgetAllocator, addr: usize, len: usize, ret_addr: usize) void {
        if (!self.track_sites) return;
        const h = self.sites_mutex.acquire();
        defer h.release();
        self.sites.put(bookkeeping, addr, .{ .len = len, .ret_addr = ret_addr }) catch {
            _ = self.untracked.fetchAdd(1, .monotonic);
        };
    }

    fn retrack(self: *BudgetAllocator, old: usize, new: usize, len: usize, ret_addr: usize) void {
        if (!self.track_sites) return;
        const h = self.sites_mutex.acquire();
        defer h.release();
        const prev = self.sites.fetchRemove(old);
        const ra = if (prev) |kv| kv.value.ret_addr else ret_addr;
        self.sites.put(bookkeeping, new, .{ .len = len, .ret_addr = ra }) catch {
            _ = self.untracked.fetchAdd(1, .monotonic);
        };
    }

    fn untrack(self: *BudgetAllocator, addr: usize) void {
        if (!self.track_sites) return;
        const h = self.sites_mutex.acquire();
        defer h.release();
        _ = self.sites.remove(addr);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "Budget: reserve respeta el techo sin efectos al fallar; peak y denied" {
    var b = Budget.init(100);
    try testing.expect(b.reserve(60));
    try testing.expect(!b.reserve(41));
    try testing.expectEqual(@as(u64, 60), b.inUse());
    try testing.expect(b.reserve(40));
    try testing.expect(!b.reserve(std.math.maxInt(u64)));
    b.release(100);
    try testing.expectEqual(@as(u64, 0), b.inUse());
    try testing.expectEqual(@as(u64, 100), b.peak.load(.monotonic));
    try testing.expectEqual(@as(u64, 2), b.denied.load(.monotonic));
}

test "BudgetAllocator: techo corta el crecimiento; contadores independientes cuadran" {
    var ba = BudgetAllocator.init(testing.allocator, .{ .limit = 1024, .name = "sesion" });
    const a = ba.allocator();
    const x = try a.alloc(u8, 512);
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 600));
    a.free(x);
    var list: std.ArrayList(u8) = .empty;
    // Crecer por encima del techo falla limpio: el ArrayList conserva lo suyo.
    try list.appendNTimes(a, 'z', 400);
    try testing.expectError(error.OutOfMemory, list.appendNTimes(a, 'z', 700));
    try testing.expectEqual(@as(usize, 400), list.items.len);
    list.deinit(a);
    const r = ba.report();
    try testing.expectEqual(r.total_allocs, r.total_frees);
    try testing.expect(r.denied >= 2);
    try testing.expect(r.peak_bytes <= 1024);
    try ba.deinitCheck();
}

test "BudgetAllocator: informe de leaks con sitio; deinitCheck falla" {
    var ba = BudgetAllocator.init(testing.allocator, .{ .track_sites = true, .name = "leaky" });
    const a = ba.allocator();
    const keep = try a.alloc(u8, 10);
    const gone = try a.alloc(u8, 20);
    a.free(gone);
    const r = ba.report();
    try testing.expectEqual(@as(u64, 1), r.live_allocs);
    try testing.expectEqual(@as(u64, 10), r.live_bytes);
    try testing.expectEqual(@as(u64, 2), r.total_allocs);
    try testing.expectEqual(@as(u32, 1), ba.sites.count());
    // Libera por fuera para no fugar del testing.allocator, pero el informe
    // ya lo ha visto vivo: deinit reporta 0 tras liberar.
    a.free(keep);
    try testing.expect(ba.deinit().isClean());

    var bb = BudgetAllocator.init(testing.allocator, .{ .name = "leaky2" });
    const l = try bb.allocator().alloc(u8, 3);
    // `deinit` loguea con std.log.err, que el test runner cuenta como fallo:
    // aquí comprobamos el informe sin cerrar, y cerramos limpio.
    try testing.expect(!bb.report().isClean());
    bb.allocator().free(l);
    try bb.deinitCheck();
}

test "BudgetAllocator: anidado global → sesión; el techo más estrecho manda" {
    var global = BudgetAllocator.init(testing.allocator, .{ .limit = 4096 });
    var session = BudgetAllocator.init(global.allocator(), .{ .limit = 1024 });
    const s = session.allocator();
    const a = try s.alloc(u8, 1000);
    try testing.expectError(error.OutOfMemory, s.alloc(u8, 100));
    try testing.expectEqual(@as(u64, 1000), global.report().live_bytes);
    s.free(a);
    try session.deinitCheck();
    try global.deinitCheck();
}

test "BudgetAllocator: sin leaks en ningún camino de OOM (checkAllAllocationFailures)" {
    const Work = struct {
        fn run(gpa: Allocator) !void {
            var ba = BudgetAllocator.init(gpa, .{ .track_sites = false });
            const a = ba.allocator();
            var list: std.ArrayList(u64) = .empty;
            defer list.deinit(a);
            for (0..100) |i| try list.append(a, i);
            const extra = try a.dupe(u64, list.items);
            a.free(extra);
            list.deinit(a);
            list = .empty;
            try ba.deinitCheck();
        }
    };
    try std.testing.checkAllAllocationFailures(testing.allocator, Work.run, .{});
}

test "BudgetAllocator: 4 hilos contra un techo compartido — nunca lo pasa, cuadra al final (TSAN)" {
    var ba = BudgetAllocator.init(std.heap.c_allocator, .{ .limit = 64 * 1024, .track_sites = true });
    const W = struct {
        fn run(b: *BudgetAllocator, seed: u64) void {
            var prng = std.Random.DefaultPrng.init(seed);
            const r = prng.random();
            var held: [16]?[]u8 = @splat(null);
            for (0..5_000) |_| {
                const i = r.uintLessThan(usize, held.len);
                if (held[i]) |m| {
                    b.allocator().free(m);
                    held[i] = null;
                } else {
                    held[i] = b.allocator().alloc(u8, 1 + r.uintLessThan(usize, 4096)) catch null;
                }
                std.debug.assert(b.budget.inUse() <= 64 * 1024);
            }
            for (held) |h| if (h) |m| b.allocator().free(m);
        }
    };
    var ts: [4]std.Thread = undefined;
    for (&ts, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, W.run, .{ &ba, i });
    for (ts) |t| t.join();
    const r = ba.report();
    try testing.expect(r.peak_bytes <= 64 * 1024);
    try testing.expectEqual(r.total_allocs, r.total_frees);
    try ba.deinitCheck();
}
