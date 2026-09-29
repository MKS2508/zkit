//! zkit.safety.BoundedReader — cursor de lectura sobre bytes NO confiables.
//!
//! Todo parser de wire o contenedor (MoQT, H3/QPACK, WebTransport, MP4, MKV,
//! el codec de conduit y el de spire) hace lo mismo: lee enteros de ancho
//! fijo, varints y campos con prefijo de longitud de un buffer que ha escrito
//! un atacante. Los bugs se repiten: leer más allá del final, un `len` del
//! wire que se usa sin comparar con lo que queda, un contador que reserva
//! memoria proporcional a un número de 62 bits, un `unreachable` en la rama
//! "no puede pasar" que el atacante hace pasar.
//!
//! Contrato:
//!   - Ninguna operación lee fuera de `buf`, ninguna hace pánico, ninguna
//!     reserva memoria. Todo fallo es un error del conjunto `Error`.
//!   - El cursor no avanza si la lectura falla (una lectura es atómica): un
//!     parser que reintenta con más datos no ve un estado a medias.
//!   - `sub(len)` da un lector hijo acotado a `len` bytes (estructuras
//!     anidadas: átomos MP4, elementos EBML, frames de control): el hijo no
//!     puede leer fuera de su padre por construcción.
//!   - `readCount(max)` para contadores que dimensionan algo: por encima de
//!     `max` es `error.LimitExceeded`, antes de reservar nada.

const std = @import("std");
const checked = @import("checked.zig");

pub const Error = error{
    /// Faltan bytes: el mensaje está truncado (o llegará más tarde).
    EndOfStream,
    /// Un valor del wire no cabe en el tipo pedido.
    Overflow,
    /// Un contador/longitud supera el límite del llamador.
    LimitExceeded,
    /// Codificación ilegal (varint no mínimo cuando se exige, marcador EBML 0...).
    InvalidEncoding,
    /// Sobran bytes donde el formato exige que la estructura termine.
    TrailingBytes,
};

pub const BoundedReader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) BoundedReader {
        return .{ .buf = buf };
    }

    pub fn remaining(self: *const BoundedReader) usize {
        return self.buf.len - self.pos;
    }

    pub fn isEmpty(self: *const BoundedReader) bool {
        return self.pos == self.buf.len;
    }

    /// Lo que queda sin consumir (préstamo, no copia).
    pub fn rest(self: *const BoundedReader) []const u8 {
        return self.buf[self.pos..];
    }

    /// `error.TrailingBytes` si queda algo.
    pub fn expectEnd(self: *const BoundedReader) Error!void {
        if (!self.isEmpty()) return error.TrailingBytes;
    }

    /// `n` bytes prestados del buffer (sin copia).
    pub fn readBytes(self: *BoundedReader, n: usize) Error![]const u8 {
        if (n > self.remaining()) return error.EndOfStream;
        defer self.pos += n;
        return self.buf[self.pos..][0..n];
    }

    /// Como `readBytes` con `n` de tipo del wire (u64), comprobado.
    pub fn readBytesLen(self: *BoundedReader, n: u64) Error![]const u8 {
        const len = std.math.cast(usize, n) orelse return error.EndOfStream;
        return self.readBytes(len);
    }

    pub fn skip(self: *BoundedReader, n: u64) Error!void {
        _ = try self.readBytesLen(n);
    }

    pub fn readByte(self: *BoundedReader) Error!u8 {
        return (try self.readBytes(1))[0];
    }

    pub fn peekByte(self: *const BoundedReader) Error!u8 {
        if (self.isEmpty()) return error.EndOfStream;
        return self.buf[self.pos];
    }

    pub fn readInt(self: *BoundedReader, comptime T: type, endian: std.builtin.Endian) Error!T {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        const b = try self.readBytes(n);
        return std.mem.readInt(T, b[0..n], endian);
    }

    /// Lector hijo sobre los siguientes `len` bytes; el padre avanza `len`.
    pub fn sub(self: *BoundedReader, len: u64) Error!BoundedReader {
        return .init(try self.readBytesLen(len));
    }

    /// Entero `T` del wire que dimensiona algo: `LimitExceeded` si > `max`.
    pub fn limit(value: anytype, max: u64) Error!u64 {
        const v: u64 = std.math.cast(u64, value) orelse return error.Overflow;
        if (v > max) return error.LimitExceeded;
        return v;
    }

    // ── Varints ───────────────────────────────────────────────────────────

    /// Varint de QUIC (RFC 9000 §16): 1/2/4/8 bytes según los dos bits altos,
    /// valor de hasta 62 bits. Base de MoQT, H3 y WebTransport.
    pub fn readQuicVarint(self: *BoundedReader) Error!u62 {
        const first = try self.peekByte();
        const len: usize = @as(usize, 1) << @intCast(first >> 6);
        const b = try self.readBytes(len);
        var v: u64 = b[0] & 0x3f;
        for (b[1..]) |x| v = (v << 8) | x;
        return @intCast(v);
    }

    /// Como `readQuicVarint` pero rechaza codificaciones no mínimas
    /// (`InvalidEncoding`), para campos donde la especificación lo exige.
    pub fn readQuicVarintMinimal(self: *BoundedReader) Error!u62 {
        const start = self.pos;
        const v = try self.readQuicVarint();
        const used = self.pos - start;
        if (used != quicVarintLen(v)) {
            self.pos = start;
            return error.InvalidEncoding;
        }
        return v;
    }

    /// Varint QUIC que dimensiona algo (longitud, contador): `LimitExceeded`
    /// si pasa de `max`, y el cursor no avanza.
    pub fn readQuicVarintMax(self: *BoundedReader, max: u64) Error!u64 {
        const start = self.pos;
        const v = try self.readQuicVarint();
        if (v > max) {
            self.pos = start;
            return error.LimitExceeded;
        }
        return v;
    }

    /// Campo con prefijo de longitud varint QUIC, longitud <= `max`.
    pub fn readQuicLengthPrefixed(self: *BoundedReader, max: u64) Error![]const u8 {
        const start = self.pos;
        const n = try self.readQuicVarintMax(max);
        return self.readBytesLen(n) catch |err| {
            self.pos = start;
            return err;
        };
    }

    pub const EbmlVint = struct {
        value: u64,
        /// Todos los bits de valor a 1: "tamaño desconocido" en Matroska.
        unknown: bool,
        len: u4,
    };

    /// VINT de EBML (RFC 8794 §4): la longitud (1..8) la da el primer bit a
    /// 1 del primer byte; el marcador se quita del valor. `0x00` como primer
    /// byte es ilegal (`InvalidEncoding`). `max_len` limita la longitud
    /// (4 para IDs de elemento, 8 para tamaños).
    pub fn readEbmlVint(self: *BoundedReader, max_len: u4) Error!EbmlVint {
        const first = try self.peekByte();
        if (first == 0) return error.InvalidEncoding;
        const len: u4 = @intCast(@clz(first) + 1);
        if (len > max_len) return error.InvalidEncoding;
        const b = try self.readBytes(len);
        const value_bits: u7 = @as(u7, len) * 7;
        var v: u64 = if (len == 8) 0 else b[0] & (@as(u8, 0xff) >> @intCast(len));
        for (b[1..]) |x| v = (v << 8) | x;
        const all_ones = (@as(u64, 1) << @intCast(value_bits)) - 1;
        return .{ .value = v, .unknown = v == all_ones, .len = len };
    }
};

/// Bytes mínimos para codificar `v` como varint QUIC.
pub fn quicVarintLen(v: u64) usize {
    if (v < (1 << 6)) return 1;
    if (v < (1 << 14)) return 2;
    if (v < (1 << 30)) return 4;
    return 8;
}

/// Codifica `v` (<= 2^62-1) como varint QUIC mínimo en `out`.
pub fn writeQuicVarint(out: []u8, v: u62) error{NoSpaceLeft}!usize {
    const len = quicVarintLen(v);
    if (out.len < len) return error.NoSpaceLeft;
    var x: u64 = v;
    var i = len;
    while (i > 0) {
        i -= 1;
        out[i] = @truncate(x);
        x >>= 8;
    }
    out[0] |= @as(u8, @intCast(std.math.log2_int(usize, len))) << 6;
    return len;
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const fuzz = @import("fuzz.zig");

test "BoundedReader: enteros, bytes prestados, fin y cursor atómico ante fallo" {
    var r = BoundedReader.init(&.{ 0x01, 0x02, 0x03, 0x04, 0xAA });
    try testing.expectEqual(@as(u16, 0x0102), try r.readInt(u16, .big));
    try testing.expectError(error.EndOfStream, r.readInt(u32, .little));
    try testing.expectEqual(@as(usize, 3), r.remaining()); // no avanzó
    try testing.expectEqual(@as(u16, 0x0403), try r.readInt(u16, .little));
    try testing.expectError(error.TrailingBytes, r.expectEnd());
    try testing.expectEqual(@as(u8, 0xAA), try r.readByte());
    try r.expectEnd();
    try testing.expectError(error.EndOfStream, r.readByte());
    try testing.expectError(error.EndOfStream, r.skip(std.math.maxInt(u64)));
}

test "BoundedReader: sub acota al hijo y el padre salta el bloque entero" {
    var r = BoundedReader.init("abcdefXYZ");
    var child = try r.sub(6);
    try testing.expectEqualStrings("abc", try child.readBytes(3));
    try testing.expectError(error.EndOfStream, child.readBytes(4));
    try testing.expectEqualStrings("XYZ", r.rest());
    try testing.expectError(error.EndOfStream, r.sub(4));
}

test "QUIC varint: vectores de RFC 9000 §A.1 + mínimo + límites" {
    const cases = [_]struct { bytes: []const u8, v: u62, minimal: bool }{
        .{ .bytes = &.{ 0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c }, .v = 151288809941952652, .minimal = true },
        .{ .bytes = &.{ 0x9d, 0x7f, 0x3e, 0x7d }, .v = 494878333, .minimal = true },
        .{ .bytes = &.{ 0x7b, 0xbd }, .v = 15293, .minimal = true },
        .{ .bytes = &.{0x25}, .v = 37, .minimal = true },
        .{ .bytes = &.{ 0x40, 0x25 }, .v = 37, .minimal = false },
    };
    for (cases) |cs| {
        var r = BoundedReader.init(cs.bytes);
        try testing.expectEqual(cs.v, try r.readQuicVarint());
        try r.expectEnd();
        var m = BoundedReader.init(cs.bytes);
        if (cs.minimal) {
            try testing.expectEqual(cs.v, try m.readQuicVarintMinimal());
        } else {
            try testing.expectError(error.InvalidEncoding, m.readQuicVarintMinimal());
            try testing.expectEqual(@as(usize, 0), m.pos);
        }
        var out: [8]u8 = undefined;
        if (cs.minimal) {
            const n = try writeQuicVarint(&out, cs.v);
            try testing.expectEqualSlices(u8, cs.bytes, out[0..n]);
        }
    }
    var trunc = BoundedReader.init(&.{ 0x9d, 0x7f });
    try testing.expectError(error.EndOfStream, trunc.readQuicVarint());
    try testing.expectEqual(@as(usize, 0), trunc.pos);

    var big = BoundedReader.init(&.{ 0x7b, 0xbd, 'x' });
    try testing.expectError(error.LimitExceeded, big.readQuicVarintMax(1000));
    try testing.expectEqual(@as(usize, 0), big.pos);
    var lp = BoundedReader.init(&.{ 0x03, 'a', 'b' });
    try testing.expectError(error.EndOfStream, lp.readQuicLengthPrefixed(10));
    try testing.expectEqual(@as(usize, 0), lp.pos);
}

test "EBML vint: ID de 4 bytes, tamaño 1..8, desconocido, cero ilegal, límite de longitud" {
    var r = BoundedReader.init(&.{ 0x1A, 0x45, 0xDF, 0xA3 }); // ID EBML header
    const id = try r.readEbmlVint(4);
    try testing.expectEqual(@as(u4, 4), id.len);
    try testing.expectEqual(@as(u64, 0x0A45DFA3), id.value);

    var s = BoundedReader.init(&.{0x81});
    try testing.expectEqual(@as(u64, 1), (try s.readEbmlVint(8)).value);
    var u = BoundedReader.init(&.{ 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
    const unk = try u.readEbmlVint(8);
    try testing.expect(unk.unknown);
    try testing.expectEqual(@as(u4, 8), unk.len);
    var z = BoundedReader.init(&.{ 0x00, 0x01 });
    try testing.expectError(error.InvalidEncoding, z.readEbmlVint(8));
    var l = BoundedReader.init(&.{ 0x08, 0, 0, 0, 0 });
    try testing.expectError(error.InvalidEncoding, l.readEbmlVint(4));
}

test "QUIC varint: ida y vuelta para 50k valores aleatorios" {
    var prng = std.Random.DefaultPrng.init(99);
    const rnd = prng.random();
    var out: [8]u8 = undefined;
    for (0..50_000) |_| {
        const v: u62 = @truncate(rnd.int(u64) >> rnd.int(u6));
        const n = try writeQuicVarint(&out, v);
        var r = BoundedReader.init(out[0..n]);
        try testing.expectEqual(v, try r.readQuicVarintMinimal());
        try r.expectEnd();
    }
}

/// Parser de ejemplo (TLV anidado con varints QUIC) para demostrar el patrón
/// y fuzzear el propio lector: sólo puede devolver `Error`, nunca pánico.
fn parseTlv(input: []const u8, depth: u8) Error!u64 {
    if (depth > 8) return error.LimitExceeded;
    var r = BoundedReader.init(input);
    var sum: u64 = 0;
    while (!r.isEmpty()) {
        const kind = try r.readQuicVarint();
        var body = BoundedReader.init(try r.readQuicLengthPrefixed(1 << 20));
        switch (kind) {
            0 => sum +%= try body.readInt(u32, .big),
            1 => sum +%= try parseTlv(body.rest(), depth + 1),
            2 => sum +%= (try body.readEbmlVint(8)).value,
            else => return error.InvalidEncoding,
        }
    }
    return sum;
}

fn parseTlvOne(_: void, input: []const u8) void {
    _ = parseTlv(input, 0) catch {};
}

test "fuzz: parser TLV sobre BoundedReader — truncados, bit-flips, sustituciones y aleatorio" {
    const seed = [_]u8{ 0x00, 0x04, 0, 0, 0, 7, 0x01, 0x06, 0x00, 0x04, 0, 0, 1, 0, 0x02, 0x01, 0x85 };
    try testing.expectEqual(@as(u64, 7 + 256 + 5), try parseTlv(&seed, 0));
    try fuzz.truncations(&seed, {}, parseTlvOne);
    try fuzz.bitFlips(testing.allocator, &seed, {}, parseTlvOne);
    try fuzz.byteSubstitutions(testing.allocator, &seed, {}, parseTlvOne);
    try fuzz.randomMutations(testing.allocator, 0xB0B, 20_000, &.{&seed}, {}, parseTlvOne);
}

test "fuzz (std.testing.fuzz): parser TLV — corpus en `zig build test`, libFuzzer-style con --fuzz" {
    const seed = [_]u8{ 0x00, 0x04, 0, 0, 0, 7, 0x01, 0x03, 0x02, 0x01, 0x85 };
    try fuzz.fuzzBytes({}, parseTlvOne, &.{&seed});
}
