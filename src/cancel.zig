//! CancelToken — cancelación por petición, encadenable, entre hilos.
//!
//! Una petición larga comprueba `isCancelled()` en cada unidad de trabajo;
//! otro hilo llama a `cancel()`. Un token de vida larga (una sesión) puede
//! tener enganchado el token de la petición en curso: cancelar cualquiera de
//! los dos para el trabajo (`cancel(requestId)` para un segmento; cerrar la
//! sesión para todo).
//!
//! Origen: `styx/native/zig/media-core/container/bytes.zig` (`CancelToken`,
//! r04/r20 §3.6), usado por los dos motores de medios y el daemon.

const std = @import("std");

pub const CancelToken = struct {
    cancelled: std.atomic.Value(bool) = .init(false),
    request: std.atomic.Value(?*const CancelToken) = .init(null),

    pub fn cancel(self: *CancelToken) void {
        self.cancelled.store(true, .release);
    }

    /// Cancelado él o el token enganchado (un nivel: el de la petición).
    pub fn isCancelled(self: *const CancelToken) bool {
        if (self.cancelled.load(.acquire)) return true;
        const r = self.request.load(.acquire) orelse return false;
        return r.cancelled.load(.acquire);
    }

    /// Engancha `request` (o lo suelta con `null`). El llamador mantiene
    /// vivo `request` hasta soltarlo.
    pub fn attach(self: *CancelToken, request: ?*const CancelToken) void {
        self.request.store(request, .release);
    }

    /// `error.Cancelled` si está cancelado: `try token.check();` en cada paso.
    pub fn check(self: *const CancelToken) error{Cancelled}!void {
        if (self.isCancelled()) return error.Cancelled;
    }
};

const testing = std.testing;

test "CancelToken: propio, enganchado y soltado" {
    var session: CancelToken = .{};
    var req: CancelToken = .{};
    try session.check();
    session.attach(&req);
    req.cancel();
    try testing.expectError(error.Cancelled, session.check());
    session.attach(null);
    try testing.expect(!session.isCancelled());
    session.cancel();
    try testing.expect(session.isCancelled());
}

test "CancelToken: cancelado desde otro hilo lo ve el trabajador (TSAN)" {
    var tok: CancelToken = .{};
    const W = struct {
        fn run(t: *CancelToken, iters: *u64) void {
            while (!t.isCancelled()) iters.* += 1;
        }
    };
    var iters: u64 = 0;
    const th = try std.Thread.spawn(.{}, W.run, .{ &tok, &iters });
    @import("time.zig").sleepNs(2 * std.time.ns_per_ms);
    tok.cancel();
    th.join();
    try testing.expect(iters > 0);
}
