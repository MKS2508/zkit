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
    /// Name on the TypeScript side when it is not derivable from `tag` with
    /// `Options.ts_prefix` + `Options.ts_case` (e.g. Zig `permission_denied`
    /// ↔ TS `SOURCE_FILE_PERMISSION_DENIED`).
    ts_name: ?[]const u8 = null,
};

/// Naming of the emitted TypeScript. The defaults reproduce the historical
/// output byte for byte (hyperdiff's generated file does not change).
pub const Options = struct {
    /// Name of the emitted union type.
    ts_type_name: []const u8 = "ErrorCode",
    /// Prefix for the emitted constants (`{prefix}NAME_TO_CODE`, ...).
    ts_const_prefix: []const u8 = "",
    /// Prefix for every TS code name (`SOURCE_` + `FILE_NOT_FOUND`).
    ts_prefix: []const u8 = "",
    /// How a Zig tag becomes a TS name.
    ts_case: enum { as_is, upper } = .as_is,
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

/// Every variant of `E` has exactly one entry, and every entry names a
/// variant of `E`. The previous `codeOf` hit `unreachable` at RUNTIME for a
/// variant without entry — the "cannot be incomplete" promise of the design
/// held only for the direction the compiler checks by accident.
fn assertComplete(comptime E: type, comptime domains: []const Domain) void {
    comptime {
        @setEvalBranchQuota(200_000);
        const names = @typeInfo(E).error_set.error_names orelse
            @compileError("ErrorSpace: E must be an explicit error set, not anyerror");
        for (names) |name| {
            var hits: usize = 0;
            for (domains) |d| for (d.entries) |e| {
                if (std.mem.eql(u8, e.tag, name)) hits += 1;
            };
            if (hits == 0) @compileError("ErrorSpace: error." ++ name ++ " has no entry");
            if (hits > 1) @compileError("ErrorSpace: error." ++ name ++ " has more than one entry");
        }
        for (domains) |d| for (d.entries) |e| {
            var found = false;
            for (names) |name| {
                if (std.mem.eql(u8, e.tag, name)) found = true;
            }
            if (!found) @compileError("ErrorSpace: entry '" ++ e.tag ++ "' in domain '" ++ d.name ++ "' is not a variant of E");
        };
    }
}

fn tsNameOf(comptime opts: Options, comptime e: Entry) []const u8 {
    comptime {
        if (e.ts_name) |n| return n;
        var out: []const u8 = opts.ts_prefix;
        switch (opts.ts_case) {
            .as_is => out = out ++ e.tag,
            .upper => for (e.tag) |ch| {
                out = out ++ &[_]u8{std.ascii.toUpper(ch)};
            },
        }
        return out;
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
    return ErrorSpaceWith(E, domains, .{});
}

/// `ErrorSpace` with TypeScript naming options.
pub fn ErrorSpaceWith(comptime E: type, comptime domains: []const Domain, comptime opts: Options) type {
    comptime assertDisjoint(domains);
    comptime assertComplete(E, domains);
    return struct {
        pub const Error = E;
        pub const Code = u16;

        /// `codeOf` for an error of a wider set: `null` if `err` is not in `E`.
        pub fn codeOfAny(err: anyerror) ?Code {
            inline for (domains) |domain| {
                inline for (domain.entries, 0..) |entry, ordinal| {
                    if (@field(anyerror, entry.tag) == err) {
                        return domain.base + @as(Code, @intCast(ordinal));
                    }
                }
            }
            return null;
        }

        /// TypeScript name of `code` (as emitted), or `null` if unknown.
        pub fn nameOf(code: Code) ?[]const u8 {
            inline for (domains) |domain| {
                inline for (domain.entries, 0..) |entry, ordinal| {
                    if (domain.base + @as(Code, @intCast(ordinal)) == code) {
                        return comptime tsNameOf(opts, entry);
                    }
                }
            }
            return null;
        }

        // ── codeOf ──────────────────────────────────────────────────────────
        /// Total: `assertComplete` guarantees at compile time that every
        /// variant of `E` has exactly one entry.
        pub fn codeOf(err: Error) Code {
            inline for (domains) |domain| {
                inline for (domain.entries, 0..) |entry, ordinal| {
                    if (@field(E, entry.tag) == err) {
                        return domain.base + @as(Code, @intCast(ordinal));
                    }
                }
            }
            unreachable; // impossible: assertComplete checked every variant
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
            out = out ++ "export type " ++ opts.ts_type_name ++ " =\n";
            inline for (domains) |domain| {
                inline for (domain.entries) |entry| {
                    out = out ++ "  | \"" ++ comptime tsNameOf(opts, entry) ++ "\"\n";
                }
            }
            out = out ++ ";\n\n";

            // NAME_TO_CODE — `as const` so consumers keep the literal value
            // types (`FILE_NOT_FOUND: 1001`, not `number`). Emitting it beats
            // deriving it in TypeScript, which widens the type.
            out = out ++ "export const " ++ opts.ts_const_prefix ++ "NAME_TO_CODE = {\n";
            inline for (domains) |domain| {
                inline for (domain.entries, 0..) |entry, ordinal| {
                    const code = domain.base + @as(Code, @intCast(ordinal));
                    out = out ++ std.fmt.comptimePrint("  {s}: {d},\n", .{ comptime tsNameOf(opts, entry), code });
                }
            }
            out = out ++ "} as const;\n\n";

            // CODE_TO_NAME
            out = out ++ "export const " ++ opts.ts_const_prefix ++ "CODE_TO_NAME: Record<number, " ++ opts.ts_type_name ++ "> = {\n";
            inline for (domains) |domain| {
                inline for (domain.entries, 0..) |entry, ordinal| {
                    const code = domain.base + @as(Code, @intCast(ordinal));
                    out = out ++ std.fmt.comptimePrint("  {d}: \"{s}\",\n", .{ code, comptime tsNameOf(opts, entry) });
                }
            }
            out = out ++ "};\n\n";

            // CODE_TO_MESSAGE
            out = out ++ "export const " ++ opts.ts_const_prefix ++ "CODE_TO_MESSAGE: Record<number, string> = {\n";
            inline for (domains) |domain| {
                inline for (domain.entries, 0..) |entry, ordinal| {
                    const code = domain.base + @as(Code, @intCast(ordinal));
                    out = out ++ std.fmt.comptimePrint("  {d}: \"{s}\",\n", .{ code, entry.message });
                }
            }
            out = out ++ "};\n\n";

            // DOMAIN_OF
            out = out ++ "export const " ++ opts.ts_const_prefix ++ "DOMAIN_OF: Record<number, string> = {\n";
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
