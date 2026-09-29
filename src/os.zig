//! zkit/os — entorno y aleatoriedad del SO sin runtime `Io`.
//!
//! Desde 0.16 `std.process.getEnvVarOwned` y `std.crypto.random` cuelgan de la
//! interfaz `Io`. Un daemon con hilos propios no tiene uno que pasarles, así
//! que cada repo reescribía `getenv` y `randomBytes` sobre libc (styx los
//! tomaba del fork de quic-zig, `quic.sys`, que es un shim de sockets y no
//! debería ser la dependencia de nadie para leer una variable de entorno).
//!
//! Reglas:
//!   - `getenv` devuelve memoria de libc: no se libera y no sobrevive a un
//!     `setenv` posterior del mismo nombre. Si hay que conservarla, cópiala.
//!   - `getenvInt` distingue "no está" (`null`) de "está mal" (`error`): un
//!     valor de configuración malformado no se convierte en el default en
//!     silencio — el llamador decide si eso es fatal.
//!   - `randomBytes` es aleatoriedad CRIPTOGRÁFICA (getrandom / arc4random).
//!     Nunca falla en silencio: si el kernel no puede darla, pánico.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

comptime {
    switch (builtin.os.tag) {
        .linux, .macos, .ios, .watchos, .tvos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => {},
        else => @compileError("zkit.os: sistema operativo sin soporte POSIX"),
    }
}

/// Valor de la variable de entorno `name`, o `null` si no está definida.
/// La memoria pertenece a libc (ver doc del módulo).
pub fn getenv(name: [*:0]const u8) ?[:0]const u8 {
    const raw = c.getenv(name) orelse return null;
    return std.mem.span(raw);
}

pub const GetenvIntError = error{InvalidEnvValue};

/// Entero decimal de la variable `name`. `null` si no está definida o está
/// vacía; `error.InvalidEnvValue` si no es un `T` válido (incluye desborde).
pub fn getenvInt(comptime T: type, name: [*:0]const u8) GetenvIntError!?T {
    const s = getenv(name) orelse return null;
    if (s.len == 0) return null;
    return std.fmt.parseInt(T, s, 10) catch return error.InvalidEnvValue;
}

extern "c" fn arc4random_buf(buf: [*]u8, len: usize) void;

/// Rellena `buf` con bytes aleatorios criptográficos.
pub fn randomBytes(buf: []u8) void {
    switch (builtin.os.tag) {
        .linux => {
            var off: usize = 0;
            while (off < buf.len) {
                const rc = std.os.linux.getrandom(buf[off..].ptr, buf.len - off, 0);
                switch (std.os.linux.errno(rc)) {
                    .SUCCESS => off += rc,
                    .INTR => continue,
                    else => |e| std.debug.panic("zkit.os.randomBytes: getrandom {t}", .{e}),
                }
            }
        },
        else => arc4random_buf(buf.ptr, buf.len),
    }
}

/// Un entero aleatorio criptográfico de tipo `T`.
pub fn randomInt(comptime T: type) T {
    var bytes: [@sizeOf(T)]u8 = undefined;
    randomBytes(&bytes);
    return std.mem.readInt(T, &bytes, .little);
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "getenv / getenvInt: ausente, vacío, válido y malformado se distinguen" {
    const name = "ZKIT_OS_TEST_VAR";
    _ = unsetenv(name);
    try testing.expect(getenv(name) == null);
    try testing.expectEqual(@as(?u32, null), try getenvInt(u32, name));

    try testing.expectEqual(@as(c_int, 0), setenv(name, "", 1));
    try testing.expectEqual(@as(?u32, null), try getenvInt(u32, name));

    try testing.expectEqual(@as(c_int, 0), setenv(name, "4096", 1));
    try testing.expectEqualStrings("4096", getenv(name).?);
    try testing.expectEqual(@as(?u32, 4096), try getenvInt(u32, name));

    try testing.expectEqual(@as(c_int, 0), setenv(name, "70000", 1));
    try testing.expectError(error.InvalidEnvValue, getenvInt(u16, name));
    try testing.expectEqual(@as(c_int, 0), setenv(name, "12abc", 1));
    try testing.expectError(error.InvalidEnvValue, getenvInt(u64, name));
    _ = unsetenv(name);
}

test "randomBytes rellena el buffer y dos lecturas difieren" {
    var a: [32]u8 = @splat(0);
    var b: [32]u8 = @splat(0);
    randomBytes(&a);
    randomBytes(&b);
    try testing.expect(!std.mem.eql(u8, &a, &b));
    // Un buffer vacío no es un error.
    randomBytes(&[_]u8{});
    _ = randomInt(u64);
}
