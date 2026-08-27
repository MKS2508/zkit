//! ErrorSpace — comptime error space with TypeScript emitter and build-time guard.
//!
//! Design: `docs/design/errors.md`.
//!
//! ## Usage
//!
//! ```zig
//! const MyErrors = error{
//!     FILE_NOT_FOUND,
//!     PERMISSION_DENIED,
//! };
//!
//! pub const Space = ErrorSpace(MyErrors, &[_]Entry{
//!     .{ .tag = "FILE_NOT_FOUND", .code = 1000, .message = "File not found" },
//!     .{ .tag = "PERMISSION_DENIED", .code = 1001, .message = "Permission denied" },
//! });
//! ```
//!
//! Exposes: `Space.Code` (u16), `Space.Error` (the error set type),
//! `Space.codeOf(err)`, `Space.errorOf(code)`, `Space.messageOf(code)`,
//! `Space.emitTypeScript()`.

const std = @import("std");

// ── Config types ───────────────────────────────────────────────────────────────

pub const Entry = struct {
    /// Must exactly match an error variant name in the error set.
    tag: []const u8,
    /// Numeric code. Must be unique across all entries.
    code: u16,
    message: []const u8,
};

// ── Core ─────────────────────────────────────────────────────────────────────

/// Create an error space.
///
/// - `E`: the error set type. Must contain one variant for every entry tag.
/// - `entries`: flat slice of `Entry`. Each entry's `tag` must match a variant
///   in `E` and each `code` must be unique.
///
/// Adding an entry without a matching error variant produces a compile error
/// in `codeOf` (exhaustive switch). Adding an error variant without an entry
/// produces a compile error in `errorOf` (unreachable branch).
///
/// Range validity (non-overlapping codes) is NOT enforced at compile time by
/// this API — callers must ensure uniqueness of codes manually.
pub fn ErrorSpace(comptime E: type, comptime entries: []const Entry) type {
    const n = entries.len;

    return struct {
        pub const Error = E;
        pub const Code = u16;

        // ── codeOf ────────────────────────────────────────────────────────────
        // Exhaustive switch: compiler verifies every entry has a matching error variant.

        pub fn codeOf(err: Error) Code {
            inline for (entries) |entry| {
                if (@field(E, entry.tag) == err) {
                    return entry.code;
                }
            }
            unreachable;
        }

        // ── errorOf ─────────────────────────────────────────────────────────
        // Adding an error variant without an entry hits unreachable.

        pub fn errorOf(code: Code) ?Error {
            inline for (entries) |entry| {
                if (entry.code == code) {
                    return @field(E, entry.tag);
                }
            }
            return null;
        }

        // ── messageOf ────────────────────────────────────────────────────────

        pub fn messageOf(code: Code) ?[]const u8 {
            inline for (entries) |entry| {
                if (entry.code == code) return entry.message;
            }
            return null;
        }

        // ── emitTypeScript ──────────────────────────────────────────────────

        /// Emit the TypeScript data module.
        pub fn emitTypeScript() []const u8 {
            comptime var out: []const u8 = &.{};

            // Union type
            out = out ++ "export type ErrorCode =\n";
            inline for (entries, 0..) |entry, i| {
                const sep = if (i < n - 1) "  | " else "  ";
                out = out ++ sep ++ "\"" ++ entry.tag ++ "\"\n";
            }
            out = out ++ ";\n\n";

            // CODE_TO_NAME
            out = out ++ "export const CODE_TO_NAME: Record<number, ErrorCode> = {\n";
            inline for (entries) |entry| {
                out = out ++ std.fmt.comptimePrint("  {d}: \"{s}\",\n", .{
                    entry.code,
                    entry.tag,
                });
            }
            out = out ++ "};\n\n";

            // CODE_TO_MESSAGE
            out = out ++ "export const CODE_TO_MESSAGE: Record<number, string> = {\n";
            inline for (entries) |entry| {
                out = out ++ std.fmt.comptimePrint("  {d}: \"{s}\",\n", .{
                    entry.code,
                    entry.message,
                });
            }
            out = out ++ "};\n\n";

            return out;
        }
    };
}
