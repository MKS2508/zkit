//! zkit.safety.BitReader — lector MSB-first de bits sobre bytes no
//! confiables, con Exp-Golomb (H.264/H.265 SPS/PPS) y uvlc (AV1).
//!
//! Mismo contrato que `BoundedReader`: nunca lee fuera del buffer, nunca hace
//! pánico, y una lectura que falla no avanza el cursor. Los códigos de
//! longitud variable nunca desplazan más de 32 bits: Exp-Golomb rechaza más
//! de 31 ceros iniciales y uvlc satura en 2^32-1 como manda AV1.
//!
//! Origen: `styx/native/zig/media-core/container/bytes.zig` (`BitReader`),
//! consumido por `codec_config.zig` y `frame_info.zig`. Arreglado al portar:
//! el original avanzaba el cursor bit a bit y dejaba un estado a medias si
//! fallaba a mitad de un campo; `se()` hacía `@intCast` de `(k+1)/2` sin
//! comprobar (seguro sólo porque `ue` limitaba k a 2^32); y `uvlc` con 32
//! ceros devolvía `Malformed` cuando la especificación define 2^32-1.

const std = @import("std");

pub const Error = error{
    /// Faltan bits.
    EndOfStream,
    /// Código de longitud variable ilegal (demasiados ceros iniciales).
    InvalidEncoding,
};

pub const BitReader = struct {
    buf: []const u8,
    bit: usize = 0,

    pub fn init(buf: []const u8) BitReader {
        return .{ .buf = buf };
    }

    pub fn bitsRemaining(self: *const BitReader) usize {
        return self.buf.len * 8 - self.bit;
    }

    /// `n` bits (0..64) como entero sin signo, MSB primero.
    pub fn bits(self: *BitReader, n: u7) Error!u64 {
        std.debug.assert(n <= 64);
        if (n > self.bitsRemaining()) return error.EndOfStream;
        var v: u64 = 0;
        var i: u7 = 0;
        while (i < n) : (i += 1) {
            const b = (self.buf[self.bit / 8] >> @intCast(7 - (self.bit % 8))) & 1;
            v = (v << 1) | b;
            self.bit += 1;
        }
        return v;
    }

    pub fn flag(self: *BitReader) Error!bool {
        return (try self.bits(1)) == 1;
    }

    pub fn skip(self: *BitReader, n: usize) Error!void {
        if (n > self.bitsRemaining()) return error.EndOfStream;
        self.bit += n;
    }

    /// Salta a la siguiente frontera de byte.
    pub fn alignToByte(self: *BitReader) void {
        self.bit = std.mem.alignForward(usize, self.bit, 8);
    }

    fn leadingZeros(self: *BitReader, max: u6) Error!u6 {
        var zeros: u6 = 0;
        while (true) {
            if (self.bit >= self.buf.len * 8) return error.EndOfStream;
            if (try self.flag()) return zeros;
            if (zeros == max) return error.InvalidEncoding;
            zeros += 1;
        }
    }

    /// Exp-Golomb sin signo `ue(v)` (H.264 §9.1), hasta 2^32 - 2.
    pub fn ue(self: *BitReader) Error!u64 {
        const start = self.bit;
        errdefer self.bit = start;
        const zeros = try self.leadingZeros(31);
        if (zeros == 0) return 0;
        return (@as(u64, 1) << zeros) - 1 + try self.bits(zeros);
    }

    /// Exp-Golomb con signo `se(v)`.
    pub fn se(self: *BitReader) Error!i64 {
        const k = try self.ue();
        const mag: i64 = @intCast((k + 1) / 2); // k < 2^32: cabe
        return if (k % 2 == 1) mag else -mag;
    }

    /// `uvlc()` de AV1 (§4.10.3), exacto a la especificación: cuenta ceros
    /// hasta el primer 1 (acotado por el buffer, no por un desplazamiento) y
    /// con 32 o más devuelve 2^32 - 1.
    pub fn uvlc(self: *BitReader) Error!u64 {
        const start = self.bit;
        errdefer self.bit = start;
        var zeros: u64 = 0;
        while (!(try self.flag())) zeros += 1;
        if (zeros >= 32) return (1 << 32) - 1;
        if (zeros == 0) return 0;
        const z: u7 = @intCast(zeros);
        return (@as(u64, 1) << @intCast(z)) - 1 + try self.bits(z);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const fuzz = @import("fuzz.zig");

test "BitReader: bits MSB-first, flag, skip, align y cursor intacto al fallar" {
    var r = BitReader.init(&.{ 0b1010_0000, 0xFF });
    try testing.expectEqual(@as(u64, 0b101), try r.bits(3));
    try testing.expect(!(try r.flag()));
    r.alignToByte();
    try testing.expectEqual(@as(u64, 0xFF), try r.bits(8));
    try testing.expectError(error.EndOfStream, r.bits(1));
    var s = BitReader.init(&.{0xAB});
    try testing.expectError(error.EndOfStream, s.bits(9));
    try testing.expectEqual(@as(usize, 8), s.bitsRemaining());
    try testing.expectEqual(@as(u64, 0xAB), try s.bits(8));
    var w = BitReader.init(&.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    try testing.expectEqual(@as(u64, 0x0102030405060708), try w.bits(64));
}

test "BitReader: ue/se — tabla 9-1/9-3 de H.264" {
    // 1 | 010 | 011 | 00100 | 00101 | 00110 | 00111  → ue = 0,1,2,3,4,5,6
    var r = BitReader.init(&.{ 0b1010_0110, 0b0100_0010, 0b1001_1000, 0b1110_0000 });
    for (0..7) |want| try testing.expectEqual(@as(u64, want), try r.ue());
    // se: k=1→1, k=2→-1, k=3→2, k=4→-2
    var s = BitReader.init(&.{ 0b0100_1100, 0b1000_0101 });
    const want_se = [_]i64{ 1, -1, 2, -2 };
    for (want_se) |w| try testing.expectEqual(w, try s.se());
}

test "BitReader: ue rechaza 32+ ceros y no avanza; truncado tampoco" {
    var r = BitReader.init(&.{ 0, 0, 0, 0, 0x80 });
    try testing.expectError(error.InvalidEncoding, r.ue());
    try testing.expectEqual(@as(usize, 0), r.bit);
    var t = BitReader.init(&.{0b0001_0000}); // 3 ceros, 1, faltan 3 bits... hay 4
    try testing.expectEqual(@as(u64, 7), try t.ue());
    var u = BitReader.init(&.{0b0000_0001}); // 7 ceros, 1, faltan 7 bits
    try testing.expectError(error.EndOfStream, u.ue());
    try testing.expectEqual(@as(usize, 0), u.bit);
    // Máximo legal: 31 ceros → 2^32 - 2 + ... cabe en u64.
    var m = BitReader.init(&.{ 0, 0, 0, 1, 0xFF, 0xFF, 0xFF, 0xFE });
    try testing.expectEqual(@as(u64, (1 << 32) - 2), try m.ue());
}

test "BitReader: uvlc de AV1, incluido el caso de 32 ceros" {
    var r = BitReader.init(&.{0b1010_0000});
    try testing.expectEqual(@as(u64, 0), try r.uvlc());
    try testing.expectEqual(@as(u64, 1), try r.uvlc());
    var big = BitReader.init(&.{ 0, 0, 0, 0, 0x80 }); // 32 ceros y el 1
    try testing.expectEqual(@as(u64, (1 << 32) - 1), try big.uvlc());
    try testing.expectEqual(@as(usize, 7), big.bitsRemaining());
    var nothing = BitReader.init(&.{ 0, 0, 0, 0, 0 }); // sin 1 final: truncado
    try testing.expectError(error.EndOfStream, nothing.uvlc());
    try testing.expectEqual(@as(usize, 0), nothing.bit);
}

fn parseSpsLike(_: void, input: []const u8) void {
    var r = BitReader.init(input);
    while (r.bitsRemaining() > 0) {
        _ = r.ue() catch return;
        _ = r.se() catch return;
        _ = r.uvlc() catch return;
        _ = r.bits(13) catch return;
    }
}

test "fuzz: BitReader sobre entradas corruptas (barridos + aleatorio)" {
    const seed = [_]u8{ 0b1010_0110, 0b0100_0010, 0b1001_1000, 0b1110_0000, 0, 0, 0, 1, 0xFF };
    try fuzz.truncations(&seed, {}, parseSpsLike);
    try fuzz.bitFlips(testing.allocator, &seed, {}, parseSpsLike);
    try fuzz.byteSubstitutions(testing.allocator, &seed, {}, parseSpsLike);
    try fuzz.randomMutations(testing.allocator, 0xB17, 20_000, &.{&seed}, {}, parseSpsLike);
}
