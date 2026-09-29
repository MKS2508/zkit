//! zkit.safety.checked — aritmética que falla con error en vez de desbordar.
//!
//! En un parser de entrada no confiable (MoQT, H3, MP4, MKV, el codec de
//! conduit/spire) la aritmética sobre campos del wire es donde nacen los
//! desbordes: `offset + len` que da la vuelta y pasa un bounds check, `count *
//! size` que se trunca y reserva poco. En ReleaseFast `+` desborda en
//! silencio; en ReleaseSafe es pánico — un DoS remoto. Aquí todo devuelve
//! `error.Overflow` o `error.OutOfBounds`, que el parser propaga como "input
//! inválido".
//!
//! Reglas que este módulo hace cumplir por tipo:
//!   - Ningún resultado se trunca: `cast` falla si el valor no cabe.
//!   - Los rangos se validan como `[offset, offset+len) ⊆ [0, total)` sin
//!     calcular nunca `offset + len` con desborde.

const std = @import("std");

pub const Error = error{Overflow};
pub const RangeError = error{ Overflow, OutOfBounds };

pub fn add(comptime T: type, a: T, b: T) Error!T {
    const r = @addWithOverflow(a, b);
    if (r[1] != 0) return error.Overflow;
    return r[0];
}

pub fn sub(comptime T: type, a: T, b: T) Error!T {
    const r = @subWithOverflow(a, b);
    if (r[1] != 0) return error.Overflow;
    return r[0];
}

pub fn mul(comptime T: type, a: T, b: T) Error!T {
    const r = @mulWithOverflow(a, b);
    if (r[1] != 0) return error.Overflow;
    return r[0];
}

/// `a * b + c` sin desborde intermedio.
pub fn mulAdd(comptime T: type, a: T, b: T, c: T) Error!T {
    return add(T, try mul(T, a, b), c);
}

/// Convierte `v` a `T` o falla si no cabe (nunca trunca, nunca cambia signo).
pub fn cast(comptime T: type, v: anytype) Error!T {
    return std.math.cast(T, v) orelse error.Overflow;
}

/// `x` redondeado hacia arriba al múltiplo de `alignment` (potencia de dos).
pub fn alignForward(comptime T: type, x: T, alignment: T) Error!T {
    std.debug.assert(alignment != 0 and std.math.isPowerOfTwo(alignment));
    return (try add(T, x, alignment - 1)) & ~(alignment - 1);
}

/// Fin exclusivo de `[offset, offset+len)` o `error.Overflow`.
pub fn rangeEnd(offset: u64, len: u64) Error!u64 {
    return add(u64, offset, len);
}

/// Valida `[offset, offset+len) ⊆ [0, total)`.
pub fn checkRange(offset: u64, len: u64, total: u64) RangeError!void {
    if (offset > total) return error.OutOfBounds;
    if (len > total - offset) return error.OutOfBounds;
}

/// `buf[offset..][0..len]` validado (o `error.OutOfBounds`).
pub fn subslice(comptime T: type, buf: []T, offset: u64, len: u64) RangeError![]T {
    try checkRange(offset, len, buf.len);
    const o: usize = try cast(usize, offset);
    const l: usize = try cast(usize, len);
    return buf[o..][0..l];
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "checked: add/sub/mul/mulAdd fallan en el borde exacto" {
    try testing.expectEqual(@as(u8, 255), try add(u8, 254, 1));
    try testing.expectError(error.Overflow, add(u8, 255, 1));
    try testing.expectError(error.Overflow, sub(u64, 0, 1));
    try testing.expectEqual(@as(i8, -128), try sub(i8, -127, 1));
    try testing.expectError(error.Overflow, sub(i8, -128, 1));
    try testing.expectError(error.Overflow, mul(u32, 1 << 16, 1 << 16));
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), try mulAdd(u32, 0xFFFF, 0x10001, 0));
    try testing.expectError(error.Overflow, mulAdd(u32, 0xFFFF, 0x10001, 1));
}

test "checked: cast nunca trunca ni cambia signo" {
    try testing.expectEqual(@as(u16, 65535), try cast(u16, @as(u64, 65535)));
    try testing.expectError(error.Overflow, cast(u16, @as(u64, 65536)));
    try testing.expectError(error.Overflow, cast(u64, @as(i64, -1)));
    try testing.expectError(error.Overflow, cast(i32, @as(u32, 0x8000_0000)));
}

test "checked: alignForward" {
    try testing.expectEqual(@as(u64, 4096), try alignForward(u64, 1, 4096));
    try testing.expectEqual(@as(u64, 4096), try alignForward(u64, 4096, 4096));
    try testing.expectError(error.Overflow, alignForward(u64, std.math.maxInt(u64) - 2, 4096));
}

test "checked: checkRange no calcula offset+len (sin desborde con offsets enormes)" {
    try checkRange(0, 10, 10);
    try checkRange(10, 0, 10);
    try testing.expectError(error.OutOfBounds, checkRange(11, 0, 10));
    try testing.expectError(error.OutOfBounds, checkRange(5, 6, 10));
    // El bug clásico: offset + len da la vuelta y "cabe".
    try testing.expectError(error.OutOfBounds, checkRange(8, std.math.maxInt(u64) - 4, 10));
    try testing.expectError(error.OutOfBounds, checkRange(std.math.maxInt(u64), 2, 10));
    try testing.expectError(error.Overflow, rangeEnd(std.math.maxInt(u64), 1));

    var buf: [8]u8 = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    try testing.expectEqualSlices(u8, &.{ 2, 3 }, try subslice(u8, &buf, 2, 2));
    try testing.expectError(error.OutOfBounds, subslice(u8, &buf, 7, 2));
}

test "checked: propiedad — checkRange equivale a la comparación en u128 (100k casos)" {
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    for (0..100_000) |_| {
        const shift_a = r.int(u6);
        const shift_b = r.int(u6);
        const offset = r.int(u64) >> shift_a;
        const len = r.int(u64) >> shift_b;
        const total = r.int(u64) >> r.int(u6);
        const want = @as(u128, offset) + len <= total;
        const got = if (checkRange(offset, len, total)) |_| true else |_| false;
        try testing.expectEqual(want, got);
    }
}
