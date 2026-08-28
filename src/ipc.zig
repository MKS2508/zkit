//! Pipe-based wakeup mechanism for cross-thread event notification.
//!
//! The consumer needs to know when new events are available without polling.
//! Solution: a pipe. The watcher thread writes 1 byte after pushing events
//! to the ring buffer. The consumer adds the pipe read fd to its event loop
//! (epoll/kqueue/libuv/Bun). When data is readable, it drains the ring buffer.
//!
//! ## Consumer Integration (example)
//!
//! Expose `read_fd` through your own FFI/handle surface, then integrate
//! with any event loop that watches raw fds (epoll/kqueue/libuv/Bun via
//! `node:net`):
//!
//! ```typescript
//! const fd = getReadFd(handle);        // your FFI accessor
//! const pipe = new net.Socket({ fd, readable: true, writable: false });
//! pipe.on('readable', () => {
//!   const count = drainEvents(handle, buffer, bufferLen); // your drain call
//!   for (let i = 0; i < count; i++) processChange(buffer[i]);
//! });
//! ```

const std = @import("std");

/// Portable pipe2 implementation: pipe() + fcntl for flags.
/// Mirrors the std Io/Dispatch pattern since std.c.pipe2 is {} on darwin.
fn pipe2WithFlags(flags: std.c.O) ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    try pipeOk(std.c.pipe(&fds));
    errdefer {
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
    }

    // CLOEXEC via F_SETFD (file descriptor flag)
    if (flags.CLOEXEC) {
        for (&fds) |fd| {
            while (true) {
                const ret = std.c.fcntl(fd, std.c.F.SETFD, @as(u32, std.c.FD_CLOEXEC));
                switch (std.c.errno(ret)) {
                    .SUCCESS => {},
                    .INTR => continue,
                    else => return error.PipeFailed,
                }
                break;
            }
        }
    }

    // NONBLOCK via F_SETFL (file status flag)
    if (flags.NONBLOCK) {
        const new_flags = @as(u32, @bitCast(flags));
        for (&fds) |fd| {
            while (true) {
                const ret = std.c.fcntl(fd, std.c.F.SETFL, new_flags);
                switch (std.c.errno(ret)) {
                    .SUCCESS => {},
                    .INTR => continue,
                    else => return error.PipeFailed,
                }
                break;
            }
        }
    }

    return fds;
}

/// Convert a raw c_int return (0=ok, -1=error with errno) to an error union.
fn pipeOk(ret: c_int) !void {
    if (ret != 0) {
        switch (std.c.errno(ret)) {
            .SUCCESS => {},
            .NFILE => return error.SystemFdQuotaExceeded,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => return error.PipeFailed,
        }
    }
}

/// Pipe-based wakeup for event loop integration.
///
/// The read fd can be registered with any event loop (epoll, kqueue, libuv,
/// Bun's event loop via `node:net`). When the watcher pushes events, it
/// writes 1 byte to wake the consumer.
pub const WakeupPipe = struct {
    /// Consumer adds this fd to its event loop (readable = events available).
    read_fd: std.posix.fd_t,
    /// Watcher writes to this fd after pushing to ring buffer.
    write_fd: std.posix.fd_t,

    /// Create a new wakeup pipe pair.
    ///
    /// Both fds are set to CLOEXEC (not inherited by child processes)
    /// and NONBLOCK (reads/writes never block).
    pub fn init() !WakeupPipe {
        const fds = try pipe2WithFlags(.{ .CLOEXEC = true, .NONBLOCK = true });
        return .{
            .read_fd = fds[0],
            .write_fd = fds[1],
        };
    }

    /// Close both pipe fds. After calling, the pipe is invalid.
    pub fn deinit(self: *WakeupPipe) void {
        _ = std.c.close(self.read_fd);
        _ = std.c.close(self.write_fd);
        self.read_fd = -1;
        self.write_fd = -1;
    }

    /// Wake the consumer. Called from watcher thread after pushing events.
    ///
    /// Writes a single byte to the pipe. The write is non-blocking —
    /// if the pipe buffer is full (consumer hasn't read), the write
    /// is silently dropped (the consumer will drain on next read anyway).
    pub fn wake(self: *const WakeupPipe) void {
        _ = std.c.write(self.write_fd, &[_]u8{1}, 1);
    }

    /// Clear the pipe. Called from consumer thread after draining events.
    ///
    /// Reads and discards all pending bytes from the pipe so the fd
    /// goes back to "not readable" state in the event loop.
    pub fn clear(self: *const WakeupPipe) void {
        var buf: [64]u8 = undefined;
        while (true) {
            const ret = std.c.read(self.read_fd, &buf, buf.len);
            if (ret <= 0) break;
        }
    }

    /// Check if the pipe read fd is valid.
    pub fn isValid(self: *const WakeupPipe) bool {
        return self.read_fd >= 0 and self.write_fd >= 0;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "WakeupPipe: init and deinit" {
    var pipe = try WakeupPipe.init();
    defer pipe.deinit();

    try std.testing.expect(pipe.isValid());
}

test "WakeupPipe: wake and clear" {
    var pipe = try WakeupPipe.init();
    defer pipe.deinit();

    pipe.wake();
    pipe.clear();
    try std.testing.expect(pipe.isValid());
}
