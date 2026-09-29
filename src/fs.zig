//! zkit/fs — ficheros sobre descriptores POSIX, sin runtime `Io`.
//!
//! `std.fs.File`/`std.fs.cwd()` pasaron detrás de `std.Io` en 0.16. Un daemon
//! con hilos propios no tiene un `Io`, así que styx tomó prestado el shim de
//! ficheros del fork de quic-zig (`quic.sys.File`, `createFile`,
//! `openFileRead`, `readFileAlloc`) — una dependencia de sockets usada para
//! abrir ficheros. Este módulo es ese shim, con cuatro arreglos:
//!
//!   - `File.stat` usa `statx`/`fstat` y devuelve tamaño, tipo e identidad
//!     (dev, ino). El shim original medía el tamaño con tres `lseek` que
//!     movían el offset compartido del fd (carrera con cualquier otro hilo que
//!     leyese por el mismo descriptor).
//!   - `File.readAt`/`readAllAt` son `pread`: sin offset compartido, seguros
//!     entre hilos sobre el mismo fd.
//!   - `EAGAIN` en escritura no es un bucle caliente: devuelve
//!     `error.WouldBlock` (un fd bloqueante nunca lo produce).
//!   - Todo `open` lleva `O_CLOEXEC`: un `fork`+`exec` no hereda descriptores.
//!
//! Rutas: aquí se abren rutas RELATIVAS AL CWD o absolutas, sin política. Para
//! abrir ficheros controlados por un cliente dentro de una raíz (path
//! traversal, symlinks, TOCTOU) usa `zkit.safety.fs.Root`, que es fd-relativo.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;

comptime {
    switch (builtin.os.tag) {
        .linux, .macos, .ios, .watchos, .tvos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => {},
        else => @compileError("zkit.fs: sistema operativo sin soporte POSIX"),
    }
}

pub const fd_t = posix.fd_t;
pub const max_path_bytes = std.fs.max_path_bytes;

pub const OpenError = error{
    FileNotFound,
    AccessDenied,
    IsDir,
    NotDir,
    NameTooLong,
    SymLinkLoop,
    PathAlreadyExists,
    NoSpaceLeft,
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    ReadOnlyFileSystem,
    Unexpected,
};

pub const ReadError = error{ InputOutput, AccessDenied, IsDir, WouldBlock, Unexpected };

pub const WriteError = error{
    DiskQuota,
    NoSpaceLeft,
    FileTooBig,
    BrokenPipe,
    InputOutput,
    AccessDenied,
    WouldBlock,
    Unexpected,
};

pub const StatError = error{ AccessDenied, SystemResources, Unexpected };

pub const Kind = enum { file, directory, sym_link, other };

/// Metadatos de un descriptor abierto.
pub const Stat = struct {
    size: u64,
    kind: Kind,
    /// Dispositivo + inodo: la identidad del objeto, no de la ruta. Dos
    /// descriptores con el mismo par apuntan al mismo fichero.
    dev: u64,
    ino: u64,
    mode: u32,
};

/// Descriptor de fichero propio. `close` lo libera; no hay finalizador.
pub const File = struct {
    fd: fd_t,

    pub fn close(self: File) void {
        _ = c.close(self.fd);
    }

    /// Lee hasta `dest.len` bytes en el offset actual. 0 = EOF.
    pub fn read(self: File, dest: []u8) ReadError!usize {
        while (true) {
            const rc = c.read(self.fd, dest.ptr, dest.len);
            if (rc >= 0) return @intCast(rc);
            switch (posix.errno(rc)) {
                .INTR => continue,
                else => |e| return mapReadErrno(e),
            }
        }
    }

    /// `pread`: lee en `offset` sin tocar el offset del descriptor. 0 = EOF.
    pub fn readAt(self: File, dest: []u8, offset: u64) ReadError!usize {
        while (true) {
            const rc = c.pread(self.fd, dest.ptr, dest.len, @intCast(offset));
            if (rc >= 0) return @intCast(rc);
            switch (posix.errno(rc)) {
                .INTR => continue,
                else => |e| return mapReadErrno(e),
            }
        }
    }

    /// Lee hasta llenar `dest` o llegar a EOF desde `offset`. Devuelve lo leído.
    pub fn readAllAt(self: File, dest: []u8, offset: u64) ReadError!usize {
        var done: usize = 0;
        while (done < dest.len) {
            const n = try self.readAt(dest[done..], offset + done);
            if (n == 0) break;
            done += n;
        }
        return done;
    }

    pub fn writeAll(self: File, bytes: []const u8) WriteError!void {
        var written: usize = 0;
        while (written < bytes.len) {
            const rc = c.write(self.fd, bytes[written..].ptr, bytes.len - written);
            if (rc >= 0) {
                written += @intCast(rc);
                continue;
            }
            switch (posix.errno(rc)) {
                .INTR => continue,
                else => |e| return mapWriteErrno(e),
            }
        }
    }

    /// `pwrite` completo en `offset`.
    pub fn writeAllAt(self: File, bytes: []const u8, offset: u64) WriteError!void {
        var written: usize = 0;
        while (written < bytes.len) {
            const rc = c.pwrite(self.fd, bytes[written..].ptr, bytes.len - written, @intCast(offset + written));
            if (rc >= 0) {
                written += @intCast(rc);
                continue;
            }
            switch (posix.errno(rc)) {
                .INTR => continue,
                else => |e| return mapWriteErrno(e),
            }
        }
    }

    /// `fsync`: los datos y metadatos llegan al dispositivo.
    pub fn sync(self: File) WriteError!void {
        if (c.fsync(self.fd) == 0) return;
        return mapWriteErrno(posix.errno(-1));
    }

    pub fn stat(self: File) StatError!Stat {
        return statFd(self.fd);
    }
};

/// `stat` de un descriptor: `statx` en Linux (donde `std.c.fstat` no está
/// declarado para todas las libc), `fstat` en el resto.
pub fn statFd(fd: fd_t) StatError!Stat {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var stx: linux.Statx = undefined;
        const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .SIZE = true, .INO = true }, &stx);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .ACCES => return error.AccessDenied,
            .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
        return .{
            .size = stx.size,
            .kind = kindOfMode(stx.mode),
            .dev = (@as(u64, stx.dev_major) << 32) | stx.dev_minor,
            .ino = stx.ino,
            .mode = stx.mode,
        };
    } else {
        var st: c.Stat = undefined;
        if (c.fstat(fd, &st) != 0) return switch (posix.errno(-1)) {
            .ACCES => error.AccessDenied,
            .NOMEM => error.SystemResources,
            else => error.Unexpected,
        };
        return .{
            .size = @intCast(st.size),
            .kind = kindOfMode(@intCast(st.mode)),
            .dev = @intCast(st.dev),
            .ino = @intCast(st.ino),
            .mode = @intCast(st.mode),
        };
    }
}

pub fn kindOfMode(mode: u32) Kind {
    if (c.S.ISREG(mode)) return .file;
    if (c.S.ISDIR(mode)) return .directory;
    if (c.S.ISLNK(mode)) return .sym_link;
    return .other;
}

/// Copia `path` a `buf` con terminador NUL.
pub fn pathZ(path: []const u8, buf: *[max_path_bytes]u8) error{NameTooLong}![:0]const u8 {
    if (path.len >= buf.len or std.mem.indexOfScalar(u8, path, 0) != null) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

/// Abre un fichero existente para leer.
pub fn openRead(path: []const u8) OpenError!File {
    var buf: [max_path_bytes]u8 = undefined;
    const z = try pathZ(path, &buf);
    return openRaw(c.AT.FDCWD, z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
}

pub const CreateOptions = struct {
    /// `false` = O_EXCL: falla con `PathAlreadyExists` si ya existe.
    truncate_existing: bool = true,
    exclusive: bool = false,
    mode: posix.mode_t = 0o644,
    read: bool = false,
};

/// Crea (o trunca) un fichero para escribir.
pub fn createFile(path: []const u8, opts: CreateOptions) OpenError!File {
    var buf: [max_path_bytes]u8 = undefined;
    const z = try pathZ(path, &buf);
    return openRaw(c.AT.FDCWD, z, createFlags(opts), opts.mode);
}

pub fn createFlags(opts: CreateOptions) posix.O {
    return .{
        .ACCMODE = if (opts.read) .RDWR else .WRONLY,
        .CREAT = true,
        .EXCL = opts.exclusive,
        .TRUNC = opts.truncate_existing and !opts.exclusive,
        .CLOEXEC = true,
    };
}

/// `openat` con el errno traducido. Público para `zkit.safety.fs`.
pub fn openRaw(dir: fd_t, path: [*:0]const u8, flags: posix.O, mode: posix.mode_t) OpenError!File {
    while (true) {
        const rc = c.openat(dir, path, flags, mode);
        if (rc >= 0) return .{ .fd = @intCast(rc) };
        switch (posix.errno(rc)) {
            .INTR => continue,
            else => |e| return mapOpenErrno(e),
        }
    }
}

pub fn mapOpenErrno(e: posix.E) OpenError {
    return switch (e) {
        .ACCES, .PERM => error.AccessDenied,
        .NOENT => error.FileNotFound,
        .ISDIR => error.IsDir,
        .NOTDIR => error.NotDir,
        .NAMETOOLONG => error.NameTooLong,
        .LOOP => error.SymLinkLoop,
        .EXIST => error.PathAlreadyExists,
        .NOSPC, .DQUOT => error.NoSpaceLeft,
        .NOMEM => error.SystemResources,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .ROFS => error.ReadOnlyFileSystem,
        else => error.Unexpected,
    };
}

fn mapReadErrno(e: posix.E) ReadError {
    return switch (e) {
        .IO => error.InputOutput,
        .ISDIR => error.IsDir,
        .ACCES, .PERM => error.AccessDenied,
        .AGAIN => error.WouldBlock,
        else => error.Unexpected,
    };
}

fn mapWriteErrno(e: posix.E) WriteError {
    return switch (e) {
        .DQUOT => error.DiskQuota,
        .NOSPC => error.NoSpaceLeft,
        .FBIG => error.FileTooBig,
        .PIPE => error.BrokenPipe,
        .IO => error.InputOutput,
        .ACCES, .PERM => error.AccessDenied,
        .AGAIN => error.WouldBlock,
        else => error.Unexpected,
    };
}

pub const MakeDirError = error{
    PathAlreadyExists,
    AccessDenied,
    FileNotFound,
    NotDir,
    NameTooLong,
    NoSpaceLeft,
    ReadOnlyFileSystem,
    Unexpected,
};

pub const MakeDirOptions = struct {
    mode: posix.mode_t = 0o755,
    /// `true`: un directorio que ya existe no es error (un FICHERO con ese
    /// nombre sí lo es: `PathAlreadyExists`).
    exist_ok: bool = false,
};

pub fn makeDir(path: []const u8, opts: MakeDirOptions) MakeDirError!void {
    var buf: [max_path_bytes]u8 = undefined;
    const z = try pathZ(path, &buf);
    return makeDirAt(c.AT.FDCWD, z, opts);
}

pub fn makeDirAt(dir: fd_t, z: [*:0]const u8, opts: MakeDirOptions) MakeDirError!void {
    if (c.mkdirat(dir, z, opts.mode) == 0) return;
    return switch (posix.errno(-1)) {
        .EXIST => if (opts.exist_ok and isDirAt(dir, z)) {} else error.PathAlreadyExists,
        .ACCES, .PERM => error.AccessDenied,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .NAMETOOLONG => error.NameTooLong,
        .NOSPC, .DQUOT => error.NoSpaceLeft,
        .ROFS => error.ReadOnlyFileSystem,
        else => error.Unexpected,
    };
}

fn isDirAt(dir: fd_t, z: [*:0]const u8) bool {
    const f = openRaw(dir, z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0) catch return false;
    f.close();
    return true;
}

pub const ReadFileError = OpenError || ReadError || StatError || std.mem.Allocator.Error || error{FileTooBig};

/// Lee `path` entero en memoria nueva de `gpa`. `error.FileTooBig` si pasa
/// de `max_bytes` (comprobado ANTES de reservar y otra vez al leer, por si el
/// fichero crece entre el `stat` y la lectura).
pub fn readFileAlloc(gpa: std.mem.Allocator, path: []const u8, max_bytes: usize) ReadFileError![]u8 {
    const f = try openRead(path);
    defer f.close();
    return readFileAllocFd(gpa, f, max_bytes);
}

pub fn readFileAllocFd(gpa: std.mem.Allocator, f: File, max_bytes: usize) ReadFileError![]u8 {
    const st = try f.stat();
    if (st.kind == .directory) return error.IsDir;
    if (st.size > max_bytes) return error.FileTooBig;
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try list.ensureTotalCapacityPrecise(gpa, @intCast(st.size));
    var offset: u64 = 0;
    while (true) {
        if (list.items.len == list.capacity) {
            if (list.items.len >= max_bytes) {
                // Lleno justo en el límite: un byte más significa demasiado grande.
                var probe: [1]u8 = undefined;
                if (try f.readAt(&probe, offset) != 0) return error.FileTooBig;
                break;
            }
            try list.ensureUnusedCapacity(gpa, @min(4096, max_bytes - list.items.len));
        }
        const dst = list.unusedCapacitySlice();
        const room = @min(dst.len, max_bytes - list.items.len);
        const n = try f.readAt(dst[0..room], offset);
        if (n == 0) break;
        list.items.len += n;
        offset += n;
    }
    return list.toOwnedSlice(gpa);
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const Fixture = @import("testing.zig").Fixture;

test "createFile + writeAll + readFileAlloc: ida y vuelta, límite y EXCL" {
    var fx = Fixture.init();
    defer fx.deinit();
    const p = try fx.path("a.bin");

    {
        const f = try createFile(p, .{});
        defer f.close();
        try f.writeAll("hola zkit");
        try f.sync();
    }
    const data = try readFileAlloc(testing.allocator, p, 64);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("hola zkit", data);

    try testing.expectError(error.FileTooBig, readFileAlloc(testing.allocator, p, 4));
    try testing.expectError(error.PathAlreadyExists, createFile(p, .{ .exclusive = true }));
    try testing.expectError(error.FileNotFound, openRead(try fx.path("no-existe")));
}

test "readAt/readAllAt: pread no mueve el offset compartido; stat da tamaño e identidad" {
    var fx = Fixture.init();
    defer fx.deinit();
    const p = try fx.path("b.bin");
    {
        const f = try createFile(p, .{});
        defer f.close();
        try f.writeAll("0123456789");
    }
    const f = try openRead(p);
    defer f.close();
    var buf: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try f.readAllAt(&buf, 6));
    try testing.expectEqualStrings("6789", &buf);
    // El offset del fd sigue en 0.
    try testing.expectEqual(@as(usize, 4), try f.read(&buf));
    try testing.expectEqualStrings("0123", &buf);
    // Más allá del final: 0 bytes, no error.
    try testing.expectEqual(@as(usize, 0), try f.readAllAt(&buf, 100));

    const st = try f.stat();
    try testing.expectEqual(@as(u64, 10), st.size);
    try testing.expectEqual(Kind.file, st.kind);
    const g = try openRead(p);
    defer g.close();
    const st2 = try g.stat();
    try testing.expectEqual(st.ino, st2.ino);
    try testing.expectEqual(st.dev, st2.dev);
}

test "makeDir: exist_ok tolera un directorio pero no un fichero" {
    var fx = Fixture.init();
    defer fx.deinit();
    const d = try fx.path("sub");
    try makeDir(d, .{});
    try testing.expectError(error.PathAlreadyExists, makeDir(d, .{}));
    try makeDir(d, .{ .exist_ok = true });
    const p = try fx.path("file");
    (try createFile(p, .{})).close();
    try testing.expectError(error.PathAlreadyExists, makeDir(p, .{ .exist_ok = true }));
    try testing.expectError(error.IsDir, readFileAlloc(testing.allocator, d, 10));
}

test "pathZ rechaza NUL embebido y rutas demasiado largas" {
    var buf: [max_path_bytes]u8 = undefined;
    try testing.expectError(error.NameTooLong, pathZ("a\x00b", &buf));
    const long: [max_path_bytes]u8 = @splat('a');
    try testing.expectError(error.NameTooLong, pathZ(&long, &buf));
}
