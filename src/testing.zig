//! zkit/testing — utilidades para los tests de los consumidores.
//!
//! `Fixture`: un directorio temporal propio por test bajo
//! `.zig-cache/tmp/<aleatorio>/` (vía `std.testing.tmpDir`), así que dos
//! procesos de test concurrentes en el mismo cwd nunca comparten ficheros.
//!
//! Los tests de código con hilos propios abren ficheros por RUTA (no tienen un
//! `Io.Dir` que pasar), así que la API devuelve rutas cwd-relativas con NUL.
//! Toda ruta vive en el arena de la fixture y se libera en `deinit`, que además
//! borra el árbol completo. El arena cuelga de `std.testing.allocator`: una
//! fixture sin `deinit` es un leak que el propio runner reporta.
//!
//! Origen: `styx/native/zig/test_fixture.zig` (18 importadores). Portado con
//! `mkdir` sobre `zkit.fs` en vez de `std.c.mkdir` crudo.
//!
//! Para fuzz y tests de seguridad ver `zkit.safety.fuzz`.

const std = @import("std");
const fs = @import("fs.zig");

pub const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,

    pub fn init() Fixture {
        return .{
            .tmp = std.testing.tmpDir(.{}),
            .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        };
    }

    /// Borra el directorio de la fixture (recursivo) y libera sus rutas.
    pub fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }

    /// Ruta cwd-relativa del directorio raíz de la fixture.
    pub fn dir(self: *Fixture) error{OutOfMemory}![:0]const u8 {
        return self.print(".zig-cache/tmp/{s}", .{&self.tmp.sub_path});
    }

    /// Ruta cwd-relativa de `name` (puede llevar subdirectorios).
    pub fn path(self: *Fixture, name: []const u8) error{OutOfMemory}![:0]const u8 {
        return self.print(".zig-cache/tmp/{s}/{s}", .{ &self.tmp.sub_path, name });
    }

    /// Crea el subdirectorio `name` y devuelve su ruta. Un directorio que "ya
    /// existe" es justo la colisión que esta fixture elimina: es error.
    pub fn mkdir(self: *Fixture, name: []const u8) (fs.MakeDirError || error{OutOfMemory})![:0]const u8 {
        const p = try self.path(name);
        try fs.makeDir(p, .{});
        return p;
    }

    /// Crea `name` con `contents` y devuelve su ruta.
    pub fn writeFile(self: *Fixture, name: []const u8, contents: []const u8) (fs.OpenError || fs.WriteError || error{OutOfMemory})![:0]const u8 {
        const p = try self.path(name);
        const f = try fs.createFile(p, .{});
        defer f.close();
        try f.writeAll(contents);
        return p;
    }

    /// Formatea en el arena de la fixture (p. ej. URIs `file://{s}`).
    pub fn print(self: *Fixture, comptime fmt: []const u8, args: anytype) error{OutOfMemory}![:0]const u8 {
        return std.fmt.allocPrintSentinel(self.arena.allocator(), fmt, args, 0);
    }
};

test "Fixture: dos fixtures no comparten directorio y deinit lo borra" {
    var a = Fixture.init();
    var b = Fixture.init();
    defer b.deinit();

    const pa = try a.path("x.tmp");
    const pb = try b.path("x.tmp");
    try std.testing.expect(!std.mem.eql(u8, pa, pb));

    const d = try a.mkdir("sub");
    try std.testing.expectError(error.PathAlreadyExists, a.mkdir("sub"));
    const f = try a.writeFile("sub/f.txt", "abc");
    var copy: [256]u8 = undefined;
    const kept = try std.fmt.bufPrintSentinel(&copy, "{s}", .{d}, 0);
    try std.testing.expectEqual(@as(c_int, 0), std.c.access(kept, 0));
    const data = try fs.readFileAlloc(std.testing.allocator, f, 16);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("abc", data);
    a.deinit();
    try std.testing.expect(std.c.access(kept, 0) != 0);
}
