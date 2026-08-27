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
//! pub const Space = ErrorSpace(MyErrors, &.{
//!     .{ .name = "io", .base = 1000, .entries = &.{
//!         .{ .tag = "FILE_NOT_FOUND",   .message = "File not found" },
//!         .{ .tag = "PERMISSION_DENIED", .message = "Permission denied" },
//!     }},
//! });
//! ```
//!
//! Exposes: `Space.Error`, `Space.Code`, `Space.codeOf(err)`, `Space.errorOf(code)`,
//! `Space.messageOf(code)`, `Space.emitTypeScript()`.

const std = @import("std");

// ── Config types ───────────────────────────────────────────────────────────────

pub const Entry = struct {
    /// Must exactly match an error variant name in `E`.
    tag: []const u8,
    /// Human-readable message.
    message: []const u8,
};

pub const Domain = struct {
    /// Domain name, used as prefix in generated TypeScript.
    name: []const u8,
    /// Base numeric code. First entry gets `base`, second `base + 1`, etc.
    base: u16,
    /// Entries in declaration order — ordinal position determines code offset.
    entries: []const Entry,
};

// ── Comptime guard ───────────────────────────────────────────────────────────

/// Reject overlapping domain ranges at compile time.
///
/// A domain owns `[base, base + entries.len)`. Two domains whose ranges
/// intersect would make `codeOf` and `errorOf` disagree — `errorOf` returns the
/// first match in declaration order, so the shadowed variant becomes
/// unreachable through the code path while `codeOf` still emits its number.
/// These codes are the ABI of published packages: a collision is not a red
/// test, it is a consumer reading the wrong error.
fn assertDisjoint(comptime domains: []const Domain) void {
    comptime {
        for (domains, 0..) |a, ia| {
            const a_end = a.base + a.entries.len;
            for (domains[ia + 1 ..]) |b| {
                const b_end = b.base + b.entries.len;
                if (a.base < b_end and b.base < a_end) {
                    @compileError(
                        "ErrorSpace: domains '" ++ a.name ++ "' and '" ++ b.name ++
                            "' have overlapping code ranges",
                    );
                }
            }
        }
    }
}

// ── Core ─────────────────────────────────────────────────────────────────────

/// Create an error space from an error set and domain descriptors.
///
/// The error set type `E` is explicit — no `@Type(.enum_literal)` (removed in
/// 0.16.0).  Adding an entry whose `tag` has no matching variant in `E`
/// produces a compile error in `codeOf` (exhaustive switch over `E`).  Adding a
/// variant in `E` without an entry hits `unreachable` in `errorOf`.
///
/// Code uniqueness across domains is enforced at comptime — see `assertDisjoint`.
pub fn ErrorSpace(comptime E: type, comptime domains: []const Domain) type {
    comptime assertDisjoint(domains);
    return struct {
        pub const Error = E;
        pub const Code = u16;

        // ── codeOf ──────────────────────────────────────────────────────────
        /// Exhaustive switch: every error variant in E must appear in a domain entry,
        /// or this fails to compile.
        pub fn codeOf(err: Error) Code {
            inline for (domains) |domain| {
                inline for (domain.entries, 0..) |entry, ordinal| {
                    if (@field(E, entry.tag) == err) {
                        return domain.base + @as(Code, @intCast(ordinal));
                    }
                }
            }
            unreachable; // variant with no entry
        }

        // ── errorOf ────────────────────────────────────────────────────────

        /// Inverse of `codeOf`.  Returns `null` for unknown codes.
        pub fn errorOf(code: Code) ?Error {
            inline for (domains) |domain| {
                inline for (domain.entries, 0..) |entry, ordinal| {
                    if (domain.base + @as(Code, @intCast(ordinal)) == code) {
                        return @field(E, entry.tag);
                    }
                }
            }
            return null;
        }

        // ── messageOf ─────────────────────────────────────────────────────

        pub fn messageOf(code: Code) ?[]const u8 {
            inline for (domains) |domain| {
                inline for (domain.entries, 0..) |entry, ordinal| {
                    if (domain.base + @as(Code, @intCast(ordinal)) == code) {
                        return entry.message;
                    }
                }
            }
            return null;
        }

        // ── emitTypeScript ─────────────────────────────────────────────────

        /// Emit the TypeScript data module as a comptime-known string.
        /// Emits in a single pass over domains → entries; no intermediate array.
        pub fn emitTypeScript() []const u8 {
            // Four tables over every entry: the default 12000 backwards
            // branches runs out around 40 codes.
            @setEvalBranchQuota(200_000);
            comptime var out: []const u8 = &.{};

            // Every member carries its own leading pipe. TypeScript accepts a
            // leading `|` on the first member, so this needs no last-element
            // special case — the previous one dropped the pipe on the final
            // member, which silently left that code out of the union.
            out = out ++ "export type ErrorCode =\n";
            inline for (domains) |domain| {
                inline for (domain.entries) |entry| {
                    out = out ++ "  | \"" ++ entry.tag ++ "\"\n";
                }
            }
            out = out ++ ";\n\n";

            // NAME_TO_CODE — `as const` so consumers keep the literal value
            // types (`FILE_NOT_FOUND: 1001`, not `number`). Emitting it beats
            // deriving it in TypeScript, which widens the type.
            out = out ++ "export const NAME_TO_CODE = {\n";
            inline for (domains) |domain| {
                inline for (domain.entries, 0..) |entry, ordinal| {
                    const code = domain.base + @as(Code, @intCast(ordinal));
                    out = out ++ std.fmt.comptimePrint("  {s}: {d},\n", .{ entry.tag, code });
                }
            }
            out = out ++ "} as const;\n\n";

            // CODE_TO_NAME
            out = out ++ "export const CODE_TO_NAME: Record<number, ErrorCode> = {\n";
            inline for (domains) |domain| {
                inline for (domain.entries, 0..) |entry, ordinal| {
                    const code = domain.base + @as(Code, @intCast(ordinal));
                    out = out ++ std.fmt.comptimePrint("  {d}: \"{s}\",\n", .{ code, entry.tag });
                }
            }
            out = out ++ "};\n\n";

            // CODE_TO_MESSAGE
            out = out ++ "export const CODE_TO_MESSAGE: Record<number, string> = {\n";
            inline for (domains) |domain| {
                inline for (domain.entries, 0..) |entry, ordinal| {
                    const code = domain.base + @as(Code, @intCast(ordinal));
                    out = out ++ std.fmt.comptimePrint("  {d}: \"{s}\",\n", .{ code, entry.message });
                }
            }
            out = out ++ "};\n\n";

            // DOMAIN_OF
            out = out ++ "export const DOMAIN_OF: Record<number, string> = {\n";
            inline for (domains) |domain| {
                inline for (domain.entries, 0..) |_, ordinal| {
                    const code = domain.base + @as(Code, @intCast(ordinal));
                    out = out ++ std.fmt.comptimePrint("  {d}: \"{s}\",\n", .{ code, domain.name });
                }
            }
            out = out ++ "};\n";

            return out;
        }
    };
}
