//! Centralized logging configuration.
//!
//! Usage:
//! ```zig
//! const log = @import("log").scoped;
//! const cli_log = log("cli");
//! const diff_log = log("diff");
//!
//! cli_log.info("Watching: {s}", .{path});
//! diff_log.debug("Diff computed {d} edits", .{edits.len});
//! ```

const std = @import("std");

/// Suppress info/warn/debug logs in dylib builds (only err and above).
/// This is read at compile time by std.log.logEnabled.
pub const std_options: std.Options = .{
    .log_level = .err,
};

/// Helper for scoped logging with consistent interface.
///
/// Returns a struct with scoped log methods for the given namespace.
///
/// ```zig
/// const log = @import("log").scoped;
/// const my_log = log("my_module");
///
/// my_log.debug("Debug info: {}", .{value});
/// my_log.info("Info message: {}", .{data});
/// my_log.warn("Warning: {}", .{warning});
/// my_log.err("Error: {}", .{error});
/// ```
pub fn scoped(comptime name: []const u8) type {
    return struct {
        pub fn debug(comptime fmt: []const u8, args: anytype) void {
            std.log.debug("[{s}] " ++ fmt, .{name} ++ args);
        }
        pub fn info(comptime fmt: []const u8, args: anytype) void {
            std.log.info("[{s}] " ++ fmt, .{name} ++ args);
        }
        pub fn warn(comptime fmt: []const u8, args: anytype) void {
            std.log.warn("[{s}] " ++ fmt, .{name} ++ args);
        }
        pub fn err(comptime fmt: []const u8, args: anytype) void {
            std.log.err("[{s}] " ++ fmt, .{name} ++ args);
        }
    };
}
