//! zkit.safety.fs — abrir ficheros controlados por un cliente dentro de una
//! raíz, sin path traversal, sin symlinks que escapen y sin TOCTOU.
//!
//! El patrón clásico (el de `styx/local_file.zig`, que es el origen del path
//! guard de aquí): rechazar `..` léxicamente, `realpath` de la ruta y de la
//! raíz, comprobar el prefijo con frontera, `open(O_NOFOLLOW)` y comparar
//! (dev, ino) del fd con los del `realpath`. Cierra casi todo, pero sigue
//! siendo RESOLUCIÓN POR RUTA: entre el `realpath` y el `open` un componente
//! INTERMEDIO puede cambiarse por un symlink (O_NOFOLLOW sólo protege el
//! último), y la comprobación de identidad llega después del `open`.
//!
//! `Root` resuelve RELATIVO A UN DESCRIPTOR de la raíz, que se abre una vez
//! (configuración del operador) y ya no depende de ninguna ruta:
//!
//!   - Linux ≥ 5.6: `openat2(root_fd, rel, RESOLVE_BENEATH | …)`. El kernel
//!     resuelve TODA la ruta atómicamente y garantiza que no sale de la raíz
//!     (ni por `..`, ni por symlink absoluto o relativo, ni por /proc
//!     magic-links). Sin ventana TOCTOU: es una sola syscall.
//!   - Resto (y Linux sin openat2 o bajo seccomp que lo bloquee): recorrido
//!     componente a componente con `openat(dirfd, comp, O_NOFOLLOW |
//!     O_DIRECTORY)`. Cada paso se hace sobre el fd del anterior; un symlink
//!     en cualquier componente es error. Tampoco hay ventana: nunca se
//!     vuelve a resolver una ruta.
//!
//! Política de symlinks (`Symlinks`):
//!   - `.reject` (defecto): ningún componente puede ser symlink.
//!   - `.beneath`: se siguen symlinks mientras el resultado quede dentro de
//!     la raíz (sólo con openat2; sin él cae a `.reject`, que es más
//!     estricto, nunca a menos).
//!
//! Y además: `require_regular` (por defecto) rechaza directorios, FIFOs y
//! dispositivos (`error.NotRegularFile`): un FIFO bajo la raíz bloquearía un
//! lector para siempre.

const std = @import("std");
const builtin = @import("builtin");
const zfs = @import("../fs.zig");
const c = std.c;
const posix = std.posix;

pub const PathError = error{
    /// Ruta vacía.
    EmptyPath,
    /// Ruta absoluta donde se exige relativa a la raíz.
    AbsolutePath,
    /// Un componente `..`.
    ParentReference,
    /// Byte NUL embebido o ruta más larga que `max_path_bytes`.
    NameTooLong,
    /// La ruta absoluta no está bajo la raíz (`relativeTo`).
    PathEscapesRoot,
};

/// Validación LÉXICA de una ruta relativa a la raíz. Rechaza vacío, `/`
/// inicial, componentes `..` y NUL. `.` y `//` se toleran (no escapan).
pub fn validateRelative(path: []const u8) PathError!void {
    if (path.len == 0) return error.EmptyPath;
    if (path[0] == '/') return error.AbsolutePath;
    if (path.len >= zfs.max_path_bytes or std.mem.indexOfScalar(u8, path, 0) != null) return error.NameTooLong;
    var it = std.mem.splitScalar(u8, path, '/');
    var any = false;
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) return error.ParentReference;
        if (comp.len != 0 and !std.mem.eql(u8, comp, ".")) any = true;
    }
    if (!any) return error.EmptyPath;
}

/// Parte relativa de `abs` bajo `root` (ambas absolutas), con frontera de
/// componente: `/media/a` NO contiene a `/media/ab` (el bug de prefijo que
/// styx arregló en TKT-009). Léxico: no resuelve symlinks — eso lo hace
/// `Root`. `error.PathEscapesRoot` si no está debajo.
pub fn relativeTo(root: []const u8, abs: []const u8) PathError![]const u8 {
    if (root.len == 0 or root[0] != '/' or abs.len == 0 or abs[0] != '/') return error.PathEscapesRoot;
    const r = std.mem.trimEnd(u8, root, "/");
    if (!std.mem.startsWith(u8, abs, r)) return error.PathEscapesRoot;
    const tail = abs[r.len..];
    if (tail.len == 0) return error.EmptyPath;
    if (tail[0] != '/') return error.PathEscapesRoot;
    const rel = std.mem.trimStart(u8, tail, "/");
    try validateRelative(rel);
    return rel;
}

/// Identidad de un objeto del sistema de ficheros (no de su ruta).
pub const FileIdentity = struct {
    dev: u64,
    ino: u64,

    pub fn ofFile(f: zfs.File) zfs.StatError!FileIdentity {
        const st = try f.stat();
        return .{ .dev = st.dev, .ino = st.ino };
    }

    pub fn eql(a: FileIdentity, b: FileIdentity) bool {
        return a.dev == b.dev and a.ino == b.ino;
    }
};

pub const Symlinks = enum { reject, beneath };

pub const Resolver = enum {
    /// openat2 si el kernel lo tiene; si no, recorrido.
    auto,
    /// Siempre recorrido componente a componente (tests, o para forzar el
    /// camino portable).
    walk,
};

pub const Access = enum { read_only, write_only, read_write };

pub const OpenOptions = struct {
    access: Access = .read_only,
    symlinks: Symlinks = .reject,
    require_regular: bool = true,
    resolver: Resolver = .auto,
};

pub const CreateOptions = struct {
    /// `true` (defecto): O_EXCL — nunca reutiliza ni trunca un fichero
    /// existente (ni sigue un symlink plantado en su lugar).
    exclusive: bool = true,
    mode: posix.mode_t = 0o600,
    read: bool = false,
    resolver: Resolver = .auto,
};

pub const Error = zfs.OpenError || zfs.StatError || PathError || error{
    /// Un componente es un symlink y la política lo prohíbe.
    SymlinkRejected,
    /// No es un fichero regular (directorio, FIFO, dispositivo, socket).
    NotRegularFile,
};

pub const Opened = struct {
    file: zfs.File,
    stat: zfs.Stat,

    pub fn identity(o: Opened) FileIdentity {
        return .{ .dev = o.stat.dev, .ino = o.stat.ino };
    }
};

pub const Root = struct {
    dir: zfs.File,
    identity: FileIdentity,

    /// Abre la raíz (ruta del OPERADOR, p. ej. `STYX_MEDIA_ROOT`). La raíz
    /// en sí puede ser un symlink (lo decide quien configura); lo que hay
    /// DEBAJO se rige por la política de cada apertura.
    pub fn open(path: []const u8) Error!Root {
        var buf: [zfs.max_path_bytes]u8 = undefined;
        const z = try zfs.pathZ(path, &buf);
        const d = try zfs.openRaw(c.AT.FDCWD, z, dirFlags(false), 0);
        errdefer d.close();
        const st = try d.stat();
        if (st.kind != .directory) return error.NotDir;
        return .{ .dir = d, .identity = .{ .dev = st.dev, .ino = st.ino } };
    }

    pub fn close(self: *Root) void {
        self.dir.close();
        self.* = undefined;
    }

    /// Abre `rel` (relativa a la raíz) según `opts`.
    pub fn openFile(self: *const Root, rel: []const u8, opts: OpenOptions) Error!Opened {
        try validateRelative(rel);
        var flags = accessFlags(opts.access);
        flags.CLOEXEC = true;
        flags.NOCTTY = true;
        // Nunca bloquear en open(2) sobre un FIFO plantado bajo la raíz.
        flags.NONBLOCK = opts.require_regular;
        const f = try self.resolve(rel, flags, 0, opts.symlinks, opts.resolver);
        errdefer f.close();
        const st = try f.stat();
        if (opts.require_regular and st.kind != .file) return error.NotRegularFile;
        if (flags.NONBLOCK) clearNonblock(f.fd);
        return .{ .file = f, .stat = st };
    }

    /// Crea `rel` bajo la raíz. Los directorios intermedios deben existir
    /// (y no ser symlinks). Con `exclusive` un symlink plantado en el nombre
    /// final hace fallar la creación (`PathAlreadyExists`), no la redirige.
    pub fn createFile(self: *const Root, rel: []const u8, opts: CreateOptions) Error!zfs.File {
        try validateRelative(rel);
        var flags = zfs.createFlags(.{ .exclusive = opts.exclusive, .truncate_existing = !opts.exclusive, .read = opts.read });
        flags.NOCTTY = true;
        return self.resolve(rel, flags, opts.mode, .reject, opts.resolver);
    }

    /// Crea el directorio `rel` bajo la raíz (padres deben existir).
    pub fn makeDir(self: *const Root, rel: []const u8, opts: zfs.MakeDirOptions) (Error || zfs.MakeDirError)!void {
        try validateRelative(rel);
        const split = splitParent(rel);
        var parent = try self.openParent(split.parent);
        defer if (parent.fd != self.dir.fd) parent.close();
        var buf: [zfs.max_path_bytes]u8 = undefined;
        const z = try zfs.pathZ(split.name, &buf);
        try zfs.makeDirAt(parent.fd, z, opts);
    }

    /// Atajo: `abs` debe estar léxicamente bajo `root_path` (la misma ruta
    /// con la que se abrió la raíz), y se abre su parte relativa.
    pub fn openAbsolute(self: *const Root, root_path: []const u8, abs: []const u8, opts: OpenOptions) Error!Opened {
        return self.openFile(try relativeTo(root_path, abs), opts);
    }

    fn resolve(self: *const Root, rel: []const u8, flags: posix.O, mode: posix.mode_t, symlinks: Symlinks, resolver: Resolver) Error!zfs.File {
        if (builtin.os.tag == .linux and resolver == .auto) {
            if (openat2(self.dir.fd, rel, flags, mode, symlinks)) |f| return f else |err| switch (err) {
                error.Unsupported => {}, // cae al recorrido
                else => |e| return e,
            }
        }
        return self.walk(rel, flags, mode);
    }

    /// Recorrido portable: cada componente sobre el fd del anterior con
    /// O_NOFOLLOW. Los symlinks son siempre error (política `.reject`).
    fn walk(self: *const Root, rel: []const u8, flags: posix.O, mode: posix.mode_t) Error!zfs.File {
        const split = splitParent(rel);
        var parent = try self.openParent(split.parent);
        defer if (parent.fd != self.dir.fd) parent.close();
        var buf: [zfs.max_path_bytes]u8 = undefined;
        const z = try zfs.pathZ(split.name, &buf);
        var f = flags;
        f.NOFOLLOW = true;
        return zfs.openRaw(parent.fd, z, f, mode) catch |err| switch (err) {
            error.SymLinkLoop => error.SymlinkRejected,
            else => |e| if (e != error.PathAlreadyExists and isSymlinkAt(parent.fd, z)) error.SymlinkRejected else e,
        };
    }

    /// fd del directorio `parent` (relativo a la raíz), componente a
    /// componente. Devuelve `self.dir` si `parent` está vacío.
    fn openParent(self: *const Root, parent: []const u8) Error!zfs.File {
        var cur = self.dir;
        errdefer if (cur.fd != self.dir.fd) cur.close();
        var it = std.mem.splitScalar(u8, parent, '/');
        var buf: [zfs.max_path_bytes]u8 = undefined;
        while (it.next()) |comp| {
            if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;
            const z = try zfs.pathZ(comp, &buf);
            const next = zfs.openRaw(cur.fd, z, dirFlags(true), 0) catch |err| switch (err) {
                // O_NOFOLLOW|O_DIRECTORY sobre un symlink: ELOOP o ENOTDIR
                // según el sistema. Distinguimos mirando qué es.
                error.SymLinkLoop => return error.SymlinkRejected,
                error.NotDir => return if (isSymlinkAt(cur.fd, z)) error.SymlinkRejected else error.NotDir,
                else => |e| return e,
            };
            if (cur.fd != self.dir.fd) cur.close();
            cur = next;
        }
        return cur;
    }
};

const Split = struct { parent: []const u8, name: []const u8 };

fn splitParent(rel: []const u8) Split {
    const trimmed = std.mem.trimEnd(u8, rel, "/");
    const i = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return .{ .parent = "", .name = trimmed };
    return .{ .parent = trimmed[0..i], .name = trimmed[i + 1 ..] };
}

fn accessFlags(a: Access) posix.O {
    return .{ .ACCMODE = switch (a) {
        .read_only => .RDONLY,
        .write_only => .WRONLY,
        .read_write => .RDWR,
    } };
}

fn dirFlags(nofollow: bool) posix.O {
    var f: posix.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = nofollow };
    if (builtin.os.tag == .linux) f.PATH = true; // basta con permiso de búsqueda (x)
    return f;
}

fn clearNonblock(fd: posix.fd_t) void {
    const fl = c.fcntl(fd, c.F.GETFL);
    if (fl < 0) return;
    var o: posix.O = @bitCast(@as(u32, @intCast(fl)));
    o.NONBLOCK = false;
    _ = c.fcntl(fd, c.F.SETFL, @as(c_int, @bitCast(@as(u32, @bitCast(o)))));
}

fn isSymlinkAt(dir: posix.fd_t, name: [*:0]const u8) bool {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var stx: linux.Statx = undefined;
        const rc = linux.statx(dir, name, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &stx);
        return linux.errno(rc) == .SUCCESS and c.S.ISLNK(stx.mode);
    } else {
        var st: c.Stat = undefined;
        if (c.fstatat(dir, name, &st, c.AT.SYMLINK_NOFOLLOW) != 0) return false;
        return c.S.ISLNK(@intCast(st.mode));
    }
}

// ── openat2 (Linux) ─────────────────────────────────────────────────────────

const RESOLVE_NO_MAGICLINKS: u64 = 0x02;
const RESOLVE_NO_SYMLINKS: u64 = 0x04;
const RESOLVE_BENEATH: u64 = 0x08;

const OpenHow = extern struct { flags: u64, mode: u64, resolve: u64 };

/// `false` tras el primer ENOSYS/EPERM: no volver a intentarlo.
var openat2_available: std.atomic.Value(bool) = .init(true);

fn openat2(dir: posix.fd_t, rel: []const u8, flags: posix.O, mode: posix.mode_t, symlinks: Symlinks) (Error || error{Unsupported})!zfs.File {
    if (!openat2_available.load(.monotonic)) return error.Unsupported;
    const linux = std.os.linux;
    var buf: [zfs.max_path_bytes]u8 = undefined;
    const z = try zfs.pathZ(rel, &buf);
    var how: OpenHow = .{
        .flags = @as(u32, @bitCast(flags)),
        .mode = if (flags.CREAT) mode else 0,
        .resolve = RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS,
    };
    if (symlinks == .reject) {
        how.resolve |= RESOLVE_NO_SYMLINKS;
        how.flags |= @as(u32, @bitCast(posix.O{ .NOFOLLOW = true }));
    }
    while (true) {
        const rc = linux.syscall4(.openat2, @bitCast(@as(isize, dir)), @intFromPtr(z.ptr), @intFromPtr(&how), @sizeOf(OpenHow));
        switch (linux.errno(rc)) {
            .SUCCESS => return .{ .fd = @intCast(rc) },
            .INTR => continue,
            .NOSYS, .PERM => {
                // PERM: seccomp (contenedores) que filtra openat2. Recorrido.
                openat2_available.store(false, .monotonic);
                return error.Unsupported;
            },
            .XDEV => return error.PathEscapesRoot,
            .LOOP => return error.SymlinkRejected,
            .AGAIN => return error.Unsupported, // RESOLVE_CACHED no usado; defensivo
            else => |e| return zfs.mapOpenErrno(e),
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
extern "c" fn mkfifo(path: [*:0]const u8, mode: posix.mode_t) c_int;
const Fixture = @import("../testing.zig").Fixture;

test "validateRelative / relativeTo: léxico con frontera de componente" {
    try validateRelative("a/b.mkv");
    try validateRelative("./a//b");
    try testing.expectError(error.EmptyPath, validateRelative(""));
    try testing.expectError(error.EmptyPath, validateRelative("./"));
    try testing.expectError(error.AbsolutePath, validateRelative("/etc/passwd"));
    try testing.expectError(error.ParentReference, validateRelative("a/../../etc"));
    try testing.expectError(error.ParentReference, validateRelative(".."));
    try testing.expectError(error.NameTooLong, validateRelative("a\x00b"));

    try testing.expectEqualStrings("x/y.mp4", try relativeTo("/media/a", "/media/a/x/y.mp4"));
    try testing.expectEqualStrings("y.mp4", try relativeTo("/media/a/", "/media/a//y.mp4"));
    try testing.expectError(error.PathEscapesRoot, relativeTo("/media/a", "/media/ab/y.mp4"));
    try testing.expectError(error.EmptyPath, relativeTo("/media/a", "/media/a"));
    try testing.expectError(error.ParentReference, relativeTo("/media/a", "/media/a/../b/y"));
    try testing.expectError(error.PathEscapesRoot, relativeTo("media", "/media/x"));
}

/// Árbol de prueba:
///   root/ok.bin            fichero
///   root/sub/deep.bin      fichero
///   root/link_in -> ok.bin              symlink que queda dentro
///   root/link_out -> ../outside.bin     symlink que escapa
///   root/dirlink -> sub                 symlink de directorio
///   root/fifo                           FIFO
///   outside.bin            fuera de la raíz
fn buildTree(fx: *Fixture) ![:0]const u8 {
    const root = try fx.mkdir("root");
    _ = try fx.mkdir("root/sub");
    _ = try fx.writeFile("root/ok.bin", "OK");
    _ = try fx.writeFile("root/sub/deep.bin", "DEEP");
    _ = try fx.writeFile("outside.bin", "SECRET");
    try testing.expectEqual(@as(c_int, 0), c.symlink("ok.bin", try fx.path("root/link_in")));
    try testing.expectEqual(@as(c_int, 0), c.symlink("../outside.bin", try fx.path("root/link_out")));
    try testing.expectEqual(@as(c_int, 0), c.symlink("sub", try fx.path("root/dirlink")));
    try testing.expectEqual(@as(c_int, 0), mkfifo(try fx.path("root/fifo"), 0o600));
    return root;
}

fn readAll(o: Opened) ![16]u8 {
    var b: [16]u8 = @splat(0);
    _ = try o.file.readAllAt(&b, 0);
    return b;
}

test "Root: contención con ambos resolvedores (openat2 y recorrido)" {
    var fx = Fixture.init();
    defer fx.deinit();
    const root_path = try buildTree(&fx);
    var root = try Root.open(root_path);
    defer root.close();

    for ([_]Resolver{ .auto, .walk }) |res| {
        {
            const o = try root.openFile("ok.bin", .{ .resolver = res });
            defer o.file.close();
            try testing.expectEqualStrings("OK", (try readAll(o))[0..2]);
        }
        {
            const o = try root.openFile("sub/deep.bin", .{ .resolver = res });
            defer o.file.close();
            try testing.expectEqual(@as(u64, 4), o.stat.size);
        }
        // Symlinks: rechazados por defecto, en cualquier componente.
        try testing.expectError(error.SymlinkRejected, root.openFile("link_in", .{ .resolver = res }));
        try testing.expectError(error.SymlinkRejected, root.openFile("link_out", .{ .resolver = res }));
        try testing.expectError(error.SymlinkRejected, root.openFile("dirlink/deep.bin", .{ .resolver = res }));
        // Léxico antes que nada.
        try testing.expectError(error.ParentReference, root.openFile("../outside.bin", .{ .resolver = res }));
        try testing.expectError(error.AbsolutePath, root.openFile("/etc/passwd", .{ .resolver = res }));
        // No regulares: directorio y FIFO (sin bloquear en open).
        try testing.expectError(error.NotRegularFile, root.openFile("sub", .{ .resolver = res }));
        try testing.expectError(error.NotRegularFile, root.openFile("fifo", .{ .resolver = res }));
        try testing.expectError(error.FileNotFound, root.openFile("nope.bin", .{ .resolver = res }));
    }
}

test "Root: .beneath sigue symlinks que quedan dentro y rechaza los que escapan (openat2)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fx = Fixture.init();
    defer fx.deinit();
    const root_path = try buildTree(&fx);
    var root = try Root.open(root_path);
    defer root.close();
    const in = root.openFile("link_in", .{ .symlinks = .beneath }) catch |err| {
        // Kernel sin openat2 (o seccomp): `.beneath` cae a `.reject`, que es
        // más estricto. Eso es lo prometido; no es un fallo.
        try testing.expectEqual(error.SymlinkRejected, err);
        return;
    };
    defer in.file.close();
    try testing.expectEqualStrings("OK", (try readAll(in))[0..2]);
    const via_dir = try root.openFile("dirlink/deep.bin", .{ .symlinks = .beneath });
    via_dir.file.close();
    try testing.expectError(error.PathEscapesRoot, root.openFile("link_out", .{ .symlinks = .beneath }));
}

test "Root: TOCTOU — cambiar un directorio intermedio por un symlink tras abrir la raíz no escapa" {
    var fx = Fixture.init();
    defer fx.deinit();
    const root_path = try buildTree(&fx);
    var root = try Root.open(root_path);
    defer root.close();
    // El atacante sustituye `sub` por un symlink a un directorio de fuera.
    _ = try fx.mkdir("evil");
    _ = try fx.writeFile("evil/deep.bin", "PWNED");
    try testing.expectEqual(@as(c_int, 0), c.rename(try fx.path("root/sub"), try fx.path("root/sub.old")));
    try testing.expectEqual(@as(c_int, 0), c.symlink("../evil", try fx.path("root/sub")));
    for ([_]Resolver{ .auto, .walk }) |res| {
        try testing.expectError(error.SymlinkRejected, root.openFile("sub/deep.bin", .{ .resolver = res }));
    }
    // Y mover la RAÍZ entera de sitio no cambia a qué apunta el fd.
    try testing.expectEqual(@as(c_int, 0), c.rename(root_path, try fx.path("moved")));
    const o = try root.openFile("ok.bin", .{});
    defer o.file.close();
    try testing.expectEqualStrings("OK", (try readAll(o))[0..2]);
}

test "Root: createFile exclusivo no sigue un symlink plantado; makeDir bajo la raíz" {
    var fx = Fixture.init();
    defer fx.deinit();
    const root_path = try buildTree(&fx);
    var root = try Root.open(root_path);
    defer root.close();
    for ([_]Resolver{ .auto, .walk }) |res| {
        // `link_out` apunta fuera: crear sobre él NO debe escribir fuera.
        const err = root.createFile("link_out", .{ .resolver = res });
        try testing.expect(std.meta.isError(err));
        const secret = try zfs.readFileAlloc(testing.allocator, try fx.path("outside.bin"), 64);
        defer testing.allocator.free(secret);
        try testing.expectEqualStrings("SECRET", secret);
    }
    try root.makeDir("ingest", .{});
    try root.makeDir("ingest", .{ .exist_ok = true });
    const f = try root.createFile("ingest/u1.part", .{});
    try f.writeAll("chunk");
    f.close();
    try testing.expectError(error.PathAlreadyExists, root.createFile("ingest/u1.part", .{}));
    try testing.expectError(error.SymlinkRejected, root.makeDir("dirlink/x", .{}));
    const o = try root.openFile("ingest/u1.part", .{});
    defer o.file.close();
    try testing.expectEqual(@as(u64, 5), o.stat.size);
    try testing.expectEqual(@as(u32, 0o600), o.stat.mode & 0o777);
}

test "Root: identidad dev/ino estable y openAbsolute con frontera" {
    var fx = Fixture.init();
    defer fx.deinit();
    const root_rel = try buildTree(&fx);
    var abs_buf: [zfs.max_path_bytes]u8 = undefined;
    const root_abs = std.mem.span(c.realpath(root_rel, &abs_buf).?);
    var root = try Root.open(root_abs);
    defer root.close();
    const a = try root.openFile("ok.bin", .{});
    defer a.file.close();
    const file_abs = try fx.print("{s}/ok.bin", .{root_abs});
    const b = try root.openAbsolute(root_abs, file_abs, .{});
    defer b.file.close();
    try testing.expect(a.identity().eql(b.identity()));
    try testing.expect(a.identity().eql(try FileIdentity.ofFile(b.file)));
    const sibling = try fx.print("{s}x/ok.bin", .{root_abs});
    try testing.expectError(error.PathEscapesRoot, root.openAbsolute(root_abs, sibling, .{}));
}
