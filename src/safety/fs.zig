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
//!
//! Montajes (`Mounts`): por defecto (`.same`) una apertura no cruza ningún
//! punto de montaje bajo la raíz, tampoco un bind mount de un fichero de
//! fuera sobre un nombre de dentro (mismo `dev`, así que comparar `dev` no lo
//! ve). openat2 lleva `RESOLVE_NO_XDEV`; además, en Linux, el `mnt_id`
//! (statx) de lo abierto tiene que ser el de la raíz, lo que cubre también
//! el recorrido, que por sí solo no distingue un montaje. `.cross` lo relaja
//! para la raíz que lo necesite (bind mounts dentro de una biblioteca).
//!
//! Entradas directas de la raíz (un servidor que gestiona su directorio de
//! staging): `deleteEntry`, `renameEntry`, `entries` y `syncDir`. Sólo
//! aceptan UN componente (`validateEntryName`: sin `/`, ni `.`/`..`), así
//! que no hay ningún componente intermedio que resolver ni que cambiar por
//! un symlink; y `unlinkat`/`renameat` actúan sobre el enlace, nunca lo
//! siguen: un symlink plantado con ese nombre se borra o se reemplaza, lo
//! que apunta queda intacto.

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

pub const EntryNameError = PathError || error{
    /// No es UNA entrada directa de la raíz: lleva `/`, o es `.`/`..`.
    NotAnEntryName,
};

/// Validación léxica de un nombre de entrada directa de la raíz: un solo
/// componente, no vacío, sin `/`, sin NUL, distinto de `.` y `..`.
pub fn validateEntryName(name: []const u8) EntryNameError!void {
    if (name.len == 0) return error.EmptyPath;
    if (name.len >= zfs.max_path_bytes or std.mem.indexOfScalar(u8, name, 0) != null) return error.NameTooLong;
    if (std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."))
        return error.NotAnEntryName;
}

pub const DeleteError = EntryNameError || error{
    FileNotFound,
    AccessDenied,
    IsDir,
    FileBusy,
    ReadOnlyFileSystem,
    SystemResources,
    Unexpected,
};

pub const RenameError = EntryNameError || error{
    FileNotFound,
    AccessDenied,
    IsDir,
    NotDir,
    DirNotEmpty,
    FileBusy,
    NoSpaceLeft,
    ReadOnlyFileSystem,
    SystemResources,
    Unexpected,
};

pub const SyncDirError = zfs.OpenError || zfs.WriteError;

pub const EntriesError = zfs.OpenError || error{SystemResources};

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

/// ¿Puede una apertura cruzar un punto de montaje bajo la raíz?
pub const Mounts = enum {
    /// No (defecto): `RESOLVE_NO_XDEV` y el `mnt_id` de lo abierto igual al
    /// de la raíz. Un montaje debajo es `error.PathEscapesRoot`.
    same,
    /// Sí: para una raíz cuyo operador monta cosas dentro a propósito.
    cross,
};

pub const Access = enum { read_only, write_only, read_write };

pub const OpenOptions = struct {
    access: Access = .read_only,
    symlinks: Symlinks = .reject,
    require_regular: bool = true,
    resolver: Resolver = .auto,
    mounts: Mounts = .same,
};

pub const CreateOptions = struct {
    /// `true` (defecto): O_EXCL — nunca reutiliza ni trunca un fichero
    /// existente (ni sigue un symlink plantado en su lugar).
    exclusive: bool = true,
    mode: posix.mode_t = 0o600,
    read: bool = false,
    resolver: Resolver = .auto,
    mounts: Mounts = .same,
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
    /// `mnt_id` del montaje de la raíz (Linux ≥ 5.8); null donde el sistema
    /// no lo da, y entonces sólo quedan `RESOLVE_NO_XDEV` y el `dev`.
    mount_id: ?u64,

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
        return .{ .dir = d, .identity = .{ .dev = st.dev, .ino = st.ino }, .mount_id = mountIdOf(d.fd) };
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
        const f = try self.resolve(rel, flags, 0, opts.symlinks, opts.resolver, opts.mounts);
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
        return self.resolve(rel, flags, opts.mode, .reject, opts.resolver, opts.mounts);
    }

    /// Crea el directorio `rel` bajo la raíz (padres deben existir).
    pub fn makeDir(self: *const Root, rel: []const u8, opts: zfs.MakeDirOptions) (Error || zfs.MakeDirError)!void {
        try validateRelative(rel);
        const split = splitParent(rel);
        var parent = try self.openParent(split.parent);
        defer if (parent.fd != self.dir.fd) parent.close();
        try self.expectSameMount(parent.fd);
        var buf: [zfs.max_path_bytes]u8 = undefined;
        const z = try zfs.pathZ(split.name, &buf);
        try zfs.makeDirAt(parent.fd, z, opts);
    }

    /// Borra la entrada `name` de la raíz (`unlinkat`, relativo al fd). Un
    /// symlink con ese nombre se borra él, sin seguirlo; un directorio es
    /// `error.IsDir` (no borra árboles) en toda plataforma.
    pub fn deleteEntry(self: *const Root, name: []const u8) DeleteError!void {
        try validateEntryName(name);
        var buf: [zfs.max_path_bytes]u8 = undefined;
        const z = try zfs.pathZ(name, &buf);
        while (true) {
            const e = posix.errno(c.unlinkat(self.dir.fd, z, 0));
            if (e == .INTR) continue;
            return unlinkResult(e, self.dir.fd, z);
        }
    }

    /// Renombra la entrada `from` a `to`, las dos directas de la raíz
    /// (`renameat`, atómico). Si `to` existe se reemplaza — también un
    /// symlink plantado con ese nombre: se sustituye el enlace, lo que
    /// apuntaba no se toca. Un `from` symlink se renombra como enlace.
    pub fn renameEntry(self: *const Root, from: []const u8, to: []const u8) RenameError!void {
        try validateEntryName(from);
        try validateEntryName(to);
        var from_buf: [zfs.max_path_bytes]u8 = undefined;
        var to_buf: [zfs.max_path_bytes]u8 = undefined;
        const from_z = try zfs.pathZ(from, &from_buf);
        const to_z = try zfs.pathZ(to, &to_buf);
        while (true) {
            switch (posix.errno(c.renameat(self.dir.fd, from_z, self.dir.fd, to_z))) {
                .SUCCESS => return,
                .INTR => continue,
                .NOENT => return error.FileNotFound,
                .ACCES, .PERM => return error.AccessDenied,
                .ISDIR => return error.IsDir,
                .NOTDIR => return error.NotDir,
                .NOTEMPTY, .EXIST => return error.DirNotEmpty,
                .BUSY => return error.FileBusy,
                .NOSPC, .DQUOT => return error.NoSpaceLeft,
                .ROFS => return error.ReadOnlyFileSystem,
                .NOMEM => return error.SystemResources,
                else => return error.Unexpected,
            }
        }
    }

    /// `fsync` del directorio raíz: hace durables los `createFile`,
    /// `renameEntry` y `deleteEntry` ya hechos. El fd de la raíz es `O_PATH`
    /// en Linux (sólo búsqueda) y no se puede sincronizar: abre `.` debajo
    /// para lectura, sincroniza y cierra.
    pub fn syncDir(self: *const Root) SyncDirError!void {
        const d = try zfs.openRaw(self.dir.fd, ".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
        defer d.close();
        try d.sync();
    }

    /// Recorre las entradas directas de la raíz (sin `.` ni `..`). Cierra el
    /// iterador con `close`. Borrar con `deleteEntry` la entrada que se acaba
    /// de recibir es seguro; si una entrada creada o borrada por otro durante
    /// el recorrido aparece o no, POSIX no lo fija.
    pub fn entries(self: *const Root) EntriesError!Entries {
        const d = try zfs.openRaw(self.dir.fd, ".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
        const stream = c.fdopendir(d.fd) orelse {
            d.close();
            return error.SystemResources;
        };
        return .{ .stream = stream };
    }

    /// Atajo: `abs` debe estar léxicamente bajo `root_path` (la misma ruta
    /// con la que se abrió la raíz), y se abre su parte relativa.
    pub fn openAbsolute(self: *const Root, root_path: []const u8, abs: []const u8, opts: OpenOptions) Error!Opened {
        return self.openFile(try relativeTo(root_path, abs), opts);
    }

    fn resolve(self: *const Root, rel: []const u8, flags: posix.O, mode: posix.mode_t, symlinks: Symlinks, resolver: Resolver, mounts: Mounts) Error!zfs.File {
        const f = open: {
            if (builtin.os.tag == .linux and resolver == .auto) {
                if (openat2(self.dir.fd, rel, flags, mode, symlinks, mounts)) |f| break :open f else |err| switch (err) {
                    error.Unsupported => {}, // cae al recorrido
                    else => |e| return e,
                }
            }
            break :open try self.walk(rel, flags, mode);
        };
        if (mounts == .same) self.expectSameMount(f.fd) catch |err| {
            f.close();
            return err;
        };
        return f;
    }

    /// `fd` está en el mismo montaje que la raíz. Donde el sistema no da
    /// `mnt_id` no hay nada que comparar; si la raíz lo tiene y `fd` no, se
    /// rechaza (sin dato no se admite).
    fn expectSameMount(self: *const Root, fd: posix.fd_t) Error!void {
        const root_mount = self.mount_id orelse return;
        const mount = mountIdOf(fd) orelse return error.PathEscapesRoot;
        if (mount != root_mount) return error.PathEscapesRoot;
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

/// Iterador de `Root.entries`.
pub const Entries = struct {
    stream: *c.DIR,

    /// Nombre de la siguiente entrada, o null al acabar (o si el sistema
    /// falla leyendo: no hay forma de distinguirlo sin errno, y para quien
    /// barre un directorio es lo mismo). El slice vale hasta el siguiente
    /// `next` o `close`.
    pub fn next(self: *Entries) ?[]const u8 {
        while (c.readdir(self.stream)) |ent| {
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            return name;
        }
        return null;
    }

    pub fn close(self: *Entries) void {
        _ = c.closedir(self.stream);
        self.* = undefined;
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

/// Resultado de `unlinkat(dir, name, 0)` con errno `e`. Linux dice EISDIR
/// para un directorio; POSIX permite EPERM y es lo que devuelve Darwin (y
/// los BSD). Un EPERM/EACCES se contrasta con `fstatat(AT_SYMLINK_NOFOLLOW)`:
/// si la entrada es un directorio (no un symlink a uno) es `IsDir`, si no el
/// permiso de verdad falta.
fn unlinkResult(e: posix.E, dir: posix.fd_t, name: [*:0]const u8) DeleteError!void {
    return switch (e) {
        .SUCCESS => {},
        .NOENT => error.FileNotFound,
        .ACCES, .PERM => if (isDirAt(dir, name)) error.IsDir else error.AccessDenied,
        .ISDIR => error.IsDir,
        .BUSY => error.FileBusy,
        .ROFS => error.ReadOnlyFileSystem,
        .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
}

/// ¿Es `name` (sin seguir un symlink final) un directorio? `false` si no se
/// puede saber.
fn isDirAt(dir: posix.fd_t, name: [*:0]const u8) bool {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var stx: linux.Statx = undefined;
        const rc = linux.statx(dir, name, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &stx);
        return linux.errno(rc) == .SUCCESS and c.S.ISDIR(stx.mode);
    } else {
        var st: c.Stat = undefined;
        if (c.fstatat(dir, name, &st, c.AT.SYMLINK_NOFOLLOW) != 0) return false;
        return c.S.ISDIR(@intCast(st.mode));
    }
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

/// `mnt_id` del montaje en el que está `fd` (statx `STATX_MNT_ID`, Linux ≥
/// 5.8); null fuera de Linux o si el kernel no lo rellena.
fn mountIdOf(fd: posix.fd_t) ?u64 {
    if (builtin.os.tag != .linux) return null;
    const linux = std.os.linux;
    var stx: linux.Statx = undefined;
    const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .MNT_ID = true }, &stx);
    if (linux.errno(rc) != .SUCCESS or !stx.mask.MNT_ID) return null;
    return stx.mnt_id;
}

// ── openat2 (Linux) ─────────────────────────────────────────────────────────

const RESOLVE_NO_XDEV: u64 = 0x01;
const RESOLVE_NO_MAGICLINKS: u64 = 0x02;
const RESOLVE_NO_SYMLINKS: u64 = 0x04;
const RESOLVE_BENEATH: u64 = 0x08;

const OpenHow = extern struct { flags: u64, mode: u64, resolve: u64 };

/// `false` tras el primer ENOSYS/EPERM: no volver a intentarlo.
var openat2_available: std.atomic.Value(bool) = .init(true);

fn openat2(dir: posix.fd_t, rel: []const u8, flags: posix.O, mode: posix.mode_t, symlinks: Symlinks, mounts: Mounts) (Error || error{Unsupported})!zfs.File {
    if (!openat2_available.load(.monotonic)) return error.Unsupported;
    const linux = std.os.linux;
    var buf: [zfs.max_path_bytes]u8 = undefined;
    const z = try zfs.pathZ(rel, &buf);
    var how: OpenHow = .{
        .flags = @as(u32, @bitCast(flags)),
        .mode = if (flags.CREAT) mode else 0,
        .resolve = RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS,
    };
    if (mounts == .same) how.resolve |= RESOLVE_NO_XDEV;
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

test "Root: un montaje bajo la raíz (tmpfs, o bind de un fichero de fuera: mismo dev) no se cruza con ningún resolvedor; .cross lo admite" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;
    var fx = Fixture.init();
    defer fx.deinit();
    const root_path = try buildTree(&fx);
    const secret = try fx.writeFile("secret.bin", "SECRET");
    const mnt = try fx.mkdir("root/mnt");
    const bind = try fx.writeFile("root/bind.bin", "PLACEHOLDER");
    // Montar exige CAP_SYS_ADMIN: sin él el caso no se puede construir, y se
    // salta (nunca pasa en verde sin ejercitarse).
    switch (linux.errno(linux.mount("tmpfs", mnt, "tmpfs", 0, 0))) {
        .SUCCESS => {},
        .PERM, .ACCES => return error.SkipZigTest,
        else => return error.MountFailed,
    }
    defer _ = linux.umount2(mnt, 0);
    if (linux.errno(linux.mount(secret, bind, null, linux.MS.BIND, 0)) != .SUCCESS) return error.MountFailed;
    defer _ = linux.umount2(bind, 0);
    _ = try fx.writeFile("root/mnt/x.bin", "TMPFS");

    var root = try Root.open(root_path);
    defer root.close();
    for ([_]Resolver{ .auto, .walk }) |res| {
        try testing.expectError(error.PathEscapesRoot, root.openFile("bind.bin", .{ .resolver = res }));
        try testing.expectError(error.PathEscapesRoot, root.openFile("mnt/x.bin", .{ .resolver = res }));
        try testing.expectError(error.PathEscapesRoot, root.createFile("mnt/new.bin", .{ .resolver = res }));
        const ok = try root.openFile("ok.bin", .{ .resolver = res });
        ok.file.close();
        const crossed = try root.openFile("bind.bin", .{ .resolver = res, .mounts = .cross });
        defer crossed.file.close();
        try testing.expectEqualStrings("SECRET", (try readAll(crossed))[0..6]);
    }
    try testing.expectError(error.PathEscapesRoot, root.makeDir("mnt/d", .{}));
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

test "validateEntryName: un solo componente" {
    try validateEntryName("a.part");
    try validateEntryName("..a");
    try testing.expectError(error.EmptyPath, validateEntryName(""));
    try testing.expectError(error.NotAnEntryName, validateEntryName("."));
    try testing.expectError(error.NotAnEntryName, validateEntryName(".."));
    try testing.expectError(error.NotAnEntryName, validateEntryName("sub/deep.bin"));
    try testing.expectError(error.NotAnEntryName, validateEntryName("/etc"));
    try testing.expectError(error.NotAnEntryName, validateEntryName("a/"));
    try testing.expectError(error.NameTooLong, validateEntryName("a\x00b"));
}

/// ¿Existe `name` (sin seguir un symlink final)?
fn exists(fx: *Fixture, name: []const u8) !bool {
    const p = try fx.path(name);
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var stx: linux.Statx = undefined;
        return linux.errno(linux.statx(c.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &stx)) == .SUCCESS;
    }
    var st: c.Stat = undefined;
    return c.fstatat(c.AT.FDCWD, p, &st, c.AT.SYMLINK_NOFOLLOW) == 0;
}

test "Root.deleteEntry: borra el enlace, nunca lo que apunta; no baja a subdirectorios" {
    var fx = Fixture.init();
    defer fx.deinit();
    var root = try Root.open(try buildTree(&fx));
    defer root.close();

    try root.deleteEntry("ok.bin");
    try testing.expect(!try exists(&fx, "root/ok.bin"));
    // Symlink que escapa: se borra él; outside.bin sigue ahí.
    try root.deleteEntry("link_out");
    try testing.expect(!try exists(&fx, "root/link_out"));
    try testing.expect(try exists(&fx, "outside.bin"));
    // Symlink de directorio: el enlace, no el directorio.
    try root.deleteEntry("dirlink");
    try testing.expect(try exists(&fx, "root/sub/deep.bin"));
    try testing.expectError(error.IsDir, root.deleteEntry("sub"));
    try testing.expectError(error.FileNotFound, root.deleteEntry("ok.bin"));
    try testing.expectError(error.NotAnEntryName, root.deleteEntry("sub/deep.bin"));
    try testing.expectError(error.NotAnEntryName, root.deleteEntry(".."));
    try testing.expectError(error.NotAnEntryName, root.deleteEntry("../outside.bin"));
    try testing.expect(try exists(&fx, "root/sub/deep.bin"));
    try testing.expect(try exists(&fx, "outside.bin"));
}

test "Root.deleteEntry: el EPERM/EACCES de Darwin sobre un directorio es IsDir; sobre un fichero o un symlink a directorio, AccessDenied" {
    // Linux devuelve EISDIR y nunca pasa por esta rama; se ejercita el mapeo
    // con el errno que da Darwin contra entradas reales.
    var fx = Fixture.init();
    defer fx.deinit();
    var root = try Root.open(try buildTree(&fx));
    defer root.close();
    for ([_]posix.E{ .PERM, .ACCES }) |e| {
        try testing.expectError(error.IsDir, unlinkResult(e, root.dir.fd, "sub"));
        try testing.expectError(error.AccessDenied, unlinkResult(e, root.dir.fd, "ok.bin"));
        try testing.expectError(error.AccessDenied, unlinkResult(e, root.dir.fd, "dirlink"));
        try testing.expectError(error.AccessDenied, unlinkResult(e, root.dir.fd, "missing"));
    }
    try testing.expectError(error.IsDir, unlinkResult(.ISDIR, root.dir.fd, "sub"));
}

test "Root.renameEntry: atómico dentro de la raíz; un symlink plantado en el destino se reemplaza, no se sigue" {
    var fx = Fixture.init();
    defer fx.deinit();
    var root = try Root.open(try buildTree(&fx));
    defer root.close();

    _ = try fx.writeFile("root/a.part", "NEW");
    // `link_out` apunta fuera: renombrar encima sustituye el enlace.
    try root.renameEntry("a.part", "link_out");
    try root.syncDir();
    try testing.expect(!try exists(&fx, "root/a.part"));
    const o = try root.openFile("link_out", .{}); // regular ya: .reject no salta
    defer o.file.close();
    try testing.expectEqualStrings("NEW", (try readAll(o))[0..3]);
    const out = try zfs.readFileAlloc(testing.allocator, try fx.path("outside.bin"), 64);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("SECRET", out);

    try testing.expectError(error.NotAnEntryName, root.renameEntry("ok.bin", "../escaped"));
    try testing.expectError(error.NotAnEntryName, root.renameEntry("ok.bin", "sub/moved"));
    try testing.expectError(error.NotAnEntryName, root.renameEntry("sub/deep.bin", "deep.bin"));
    try testing.expectError(error.FileNotFound, root.renameEntry("missing", "x"));
    try testing.expect(try exists(&fx, "root/ok.bin"));
}

test "Root.entries: lista las entradas directas (sin . ni ..) y admite borrar la actual mientras barre" {
    var fx = Fixture.init();
    defer fx.deinit();
    var root = try Root.open(try buildTree(&fx));
    defer root.close();

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| testing.allocator.free(k.*);
        seen.deinit(testing.allocator);
    }
    {
        var it = try root.entries();
        defer it.close();
        while (it.next()) |name| try seen.put(testing.allocator, try testing.allocator.dupe(u8, name), {});
    }
    try testing.expectEqual(@as(u32, 6), seen.count());
    for ([_][]const u8{ "ok.bin", "sub", "link_in", "link_out", "dirlink", "fifo" }) |n| try testing.expect(seen.contains(n));

    // Barrido: borrar los `link_*` mientras se recorre.
    var removed: u32 = 0;
    {
        var it = try root.entries();
        defer it.close();
        while (it.next()) |name| {
            if (!std.mem.startsWith(u8, name, "link_")) continue;
            try root.deleteEntry(name);
            removed += 1;
        }
    }
    try testing.expectEqual(@as(u32, 2), removed);
    try testing.expect(!try exists(&fx, "root/link_in"));
    try testing.expect(try exists(&fx, "root/ok.bin"));
    try testing.expect(try exists(&fx, "outside.bin"));
}
