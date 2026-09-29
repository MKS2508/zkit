//! zkit.safety.fuzz — barridos deterministas y puente a `std.testing.fuzz`
//! para parsers de entrada no confiable.
//!
//! Un parser de wire o contenedor tiene un único contrato de seguridad
//! verificable sin conocer el formato: para CUALQUIER entrada devuelve un
//! resultado o un error — nunca pánico, nunca lectura fuera de límites, nunca
//! leak. Estas utilidades generan las entradas que más a menudo rompen ese
//! contrato, a partir de un ejemplo válido (semilla):
//!
//!   - `truncations`: todos los prefijos (el caso "llegó medio mensaje").
//!   - `bitFlips`: cada bit invertido, uno a uno (longitudes y tipos corruptos).
//!   - `byteSubstitutions`: cada byte sustituido por los valores frontera
//!     (0x00, 0x01, 0x3f, 0x40, 0x7f, 0x80, 0xbf, 0xc0, 0xfe, 0xff): los que
//!     cambian la longitud de un varint o el signo de un campo.
//!   - `randomMutations`: mutaciones aleatorias reproducibles (semilla fija)
//!     sobre el corpus: inserciones, borrados, duplicados y splices.
//!   - `fuzzBytes`: el mismo callback bajo `std.testing.fuzz` — en `zig build
//!     test` corre el corpus; con `zig build test --fuzz` es fuzzing guiado por
//!     cobertura.
//!
//! El callback recibe los bytes y hace lo que quiera con el resultado
//! (típicamente `_ = parse(x) catch {};`). Un pánico dentro tumba el test (y
//! señala el caso); un leak lo detecta `std.testing.allocator` si el parser lo
//! usa. Para fallos de reserva usa además `checkAllAllocationFailures`.

const std = @import("std");

/// Re-export: ejecuta `test_fn` fallando cada reserva en turno (no leaks ni
/// estados corruptos en ningún camino de `error.OutOfMemory`).
pub const checkAllAllocationFailures = std.testing.checkAllAllocationFailures;

pub const interesting_bytes = [_]u8{ 0x00, 0x01, 0x3f, 0x40, 0x7f, 0x80, 0xbf, 0xc0, 0xfe, 0xff };

/// `func(ctx, input[0..n])` para todo `n` en `0..=input.len`.
pub fn truncations(input: []const u8, ctx: anytype, comptime func: fn (@TypeOf(ctx), []const u8) void) !void {
    for (0..input.len + 1) |n| func(ctx, input[0..n]);
}

/// `func` sobre cada variante de `input` con un único bit invertido.
pub fn bitFlips(gpa: std.mem.Allocator, input: []const u8, ctx: anytype, comptime func: fn (@TypeOf(ctx), []const u8) void) !void {
    const buf = try gpa.dupe(u8, input);
    defer gpa.free(buf);
    for (0..buf.len) |i| {
        for (0..8) |bit| {
            const mask = @as(u8, 1) << @intCast(bit);
            buf[i] ^= mask;
            func(ctx, buf);
            buf[i] ^= mask;
        }
    }
}

/// `func` sobre cada variante con un byte sustituido por un valor frontera.
pub fn byteSubstitutions(gpa: std.mem.Allocator, input: []const u8, ctx: anytype, comptime func: fn (@TypeOf(ctx), []const u8) void) !void {
    const buf = try gpa.dupe(u8, input);
    defer gpa.free(buf);
    for (0..buf.len) |i| {
        const orig = buf[i];
        for (interesting_bytes) |b| {
            buf[i] = b;
            func(ctx, buf);
        }
        buf[i] = orig;
    }
}

/// `iterations` entradas derivadas del corpus por mutación aleatoria
/// reproducible (misma `seed` ⇒ mismas entradas). Longitud máxima: 4x la
/// semilla más larga + 64.
pub fn randomMutations(
    gpa: std.mem.Allocator,
    seed: u64,
    iterations: usize,
    corpus: []const []const u8,
    ctx: anytype,
    comptime func: fn (@TypeOf(ctx), []const u8) void,
) !void {
    var max_seed: usize = 0;
    for (corpus) |c| max_seed = @max(max_seed, c.len);
    const cap = max_seed * 4 + 64;
    const buf = try gpa.alloc(u8, cap);
    defer gpa.free(buf);
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    for (0..iterations) |_| {
        var len: usize = 0;
        if (corpus.len > 0) {
            const src = corpus[r.uintLessThan(usize, corpus.len)];
            @memcpy(buf[0..src.len], src);
            len = src.len;
        }
        const rounds = 1 + r.uintLessThan(usize, 4);
        for (0..rounds) |_| len = mutate(r, buf, len, corpus);
        func(ctx, buf[0..len]);
    }
}

fn mutate(r: std.Random, buf: []u8, len: usize, corpus: []const []const u8) usize {
    switch (r.uintLessThan(u8, 7)) {
        0 => if (len > 0) { // flip de bit
            buf[r.uintLessThan(usize, len)] ^= @as(u8, 1) << r.int(u3);
        },
        1 => if (len > 0) { // byte frontera
            buf[r.uintLessThan(usize, len)] = interesting_bytes[r.uintLessThan(usize, interesting_bytes.len)];
        },
        2 => if (len > 0) { // borrar un tramo
            const at = r.uintLessThan(usize, len);
            const n = 1 + r.uintLessThan(usize, len - at);
            std.mem.copyForwards(u8, buf[at..], buf[at + n .. len]);
            return len - n;
        },
        3 => if (len < buf.len) { // insertar bytes aleatorios
            const at = r.uintLessThan(usize, len + 1);
            const n = 1 + r.uintLessThan(usize, @min(8, buf.len - len));
            std.mem.copyBackwards(u8, buf[at + n .. len + n], buf[at..len]);
            r.bytes(buf[at..][0..n]);
            return len + n;
        },
        4 => if (len > 0 and len < buf.len) { // duplicar un tramo
            const at = r.uintLessThan(usize, len);
            const n = 1 + r.uintLessThan(usize, @min(len - at, buf.len - len));
            std.mem.copyBackwards(u8, buf[at + n .. len + n], buf[at..len]);
            return len + n;
        },
        5 => if (corpus.len > 0) { // splice con otra semilla
            const other = corpus[r.uintLessThan(usize, corpus.len)];
            const at = if (len == 0) 0 else r.uintLessThan(usize, len);
            const n = @min(other.len, buf.len - at);
            @memcpy(buf[at..][0..n], other[0..n]);
            return @max(len, at + n);
        },
        else => if (len > 0) { // truncar
            return r.uintLessThan(usize, len + 1);
        },
    }
    return len;
}

/// Puente a `std.testing.fuzz`: el callback recibe un slice (hasta 4 KiB)
/// generado por el `Smith`. Sin `--fuzz` corre el corpus y la entrada vacía.
pub fn fuzzBytes(ctx: anytype, comptime func: fn (@TypeOf(ctx), []const u8) void, corpus: []const []const u8) !void {
    const Wrap = struct {
        fn one(c: @TypeOf(ctx), smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const n = smith.slice(&buf);
            func(c, buf[0..n]);
        }
    };
    try std.testing.fuzz(ctx, Wrap.one, .{ .corpus = corpus });
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const Counter = struct {
    calls: usize = 0,
    total_len: usize = 0,
    max_len: usize = 0,
    fn see(c: *Counter, input: []const u8) void {
        c.calls += 1;
        c.total_len += input.len;
        c.max_len = @max(c.max_len, input.len);
    }
};

test "fuzz: los barridos generan exactamente las variantes prometidas" {
    const seed = "abcd";
    var c: Counter = .{};
    try truncations(seed, &c, Counter.see);
    try testing.expectEqual(@as(usize, 5), c.calls);
    c = .{};
    try bitFlips(testing.allocator, seed, &c, Counter.see);
    try testing.expectEqual(@as(usize, 32), c.calls);
    c = .{};
    try byteSubstitutions(testing.allocator, seed, &c, Counter.see);
    try testing.expectEqual(@as(usize, 4 * interesting_bytes.len), c.calls);
}

test "fuzz: randomMutations es reproducible y respeta la cota de longitud" {
    const Hash = struct {
        h: std.hash.Wyhash = .init(0),
        max: usize = 0,
        fn see(s: *@This(), input: []const u8) void {
            s.h.update(input);
            s.max = @max(s.max, input.len);
        }
    };
    var a: Hash = .{};
    var b: Hash = .{};
    const corpus = [_][]const u8{ "hello", "world!!" };
    try randomMutations(testing.allocator, 1, 5_000, &corpus, &a, Hash.see);
    try randomMutations(testing.allocator, 1, 5_000, &corpus, &b, Hash.see);
    try testing.expectEqual(a.h.final(), b.h.final());
    try testing.expect(a.max <= 7 * 4 + 64);
    var c: Hash = .{};
    try randomMutations(testing.allocator, 2, 5_000, &corpus, &c, Hash.see);
    try testing.expect(a.h.final() != c.h.final());
    // Corpus vacío: sólo inserciones/aleatorio, no pánico.
    try randomMutations(testing.allocator, 3, 1_000, &.{}, &c, Hash.see);
}
