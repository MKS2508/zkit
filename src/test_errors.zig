//! Tests for zkit/errors — ErrorSpace mechanism.
const std = @import("std");
const testing = std.testing;
const errors = @import("errors.zig");

// ── Error set types ────────────────────────────────────────────────────────────

const IoErrors = error{
    FILE_NOT_FOUND,
    PERMISSION_DENIED,
    INVALID_HANDLE,
};

const HashErrors = error{
    INVALID_UTF8,
    BUFFER_OVERFLOW,
};

// ── Single-domain space ────────────────────────────────────────────────────────

const IoSpace = errors.ErrorSpace(IoErrors, &[_]errors.Domain{
    .{ .name = "io", .base = 1000, .entries = &[_]errors.Entry{
        .{ .tag = "FILE_NOT_FOUND",   .message = "File not found" },
        .{ .tag = "PERMISSION_DENIED", .message = "Permission denied" },
        .{ .tag = "INVALID_HANDLE",   .message = "Invalid handle" },
    }},
});

test "codeOf: maps each error variant to base+ordinal" {
    try testing.expectEqual(@as(IoSpace.Code, 1000), IoSpace.codeOf(IoSpace.Error.FILE_NOT_FOUND));
    try testing.expectEqual(@as(IoSpace.Code, 1001), IoSpace.codeOf(IoSpace.Error.PERMISSION_DENIED));
    try testing.expectEqual(@as(IoSpace.Code, 1002), IoSpace.codeOf(IoSpace.Error.INVALID_HANDLE));
}

test "errorOf: maps code back to error variant" {
    try testing.expectEqual(
        @intFromError(IoSpace.Error.FILE_NOT_FOUND),
        @intFromError(IoSpace.errorOf(1000).?),
    );
    try testing.expectEqual(
        @intFromError(IoSpace.Error.PERMISSION_DENIED),
        @intFromError(IoSpace.errorOf(1001).?),
    );
    try testing.expectEqual(
        @intFromError(IoSpace.Error.INVALID_HANDLE),
        @intFromError(IoSpace.errorOf(1002).?),
    );
}

test "errorOf: unknown code returns null" {
    try testing.expectEqual(@as(?IoSpace.Error, null), IoSpace.errorOf(9999));
}

test "messageOf: returns the correct message" {
    try testing.expectEqualStrings("File not found",    IoSpace.messageOf(1000).?);
    try testing.expectEqualStrings("Permission denied", IoSpace.messageOf(1001).?);
    try testing.expectEqualStrings("Invalid handle",   IoSpace.messageOf(1002).?);
}

test "messageOf: unknown code returns null" {
    try testing.expectEqual(@as(?[]const u8, null), IoSpace.messageOf(9999));
}

// ── Multi-domain space ─────────────────────────────────────────────────────────

const MultiSpace = errors.ErrorSpace(IoErrors || HashErrors, &[_]errors.Domain{
    .{ .name = "io", .base = 1000, .entries = &[_]errors.Entry{
        .{ .tag = "FILE_NOT_FOUND",   .message = "File not found" },
        .{ .tag = "PERMISSION_DENIED", .message = "Permission denied" },
        .{ .tag = "INVALID_HANDLE",   .message = "Invalid handle" },
    }},
    .{ .name = "hash", .base = 2000, .entries = &[_]errors.Entry{
        .{ .tag = "INVALID_UTF8",    .message = "Invalid UTF-8 sequence" },
        .{ .tag = "BUFFER_OVERFLOW", .message = "Buffer overflow" },
    }},
});

test "multi-domain: codeOf maps across domains" {
    try testing.expectEqual(@as(MultiSpace.Code, 1000), MultiSpace.codeOf(MultiSpace.Error.FILE_NOT_FOUND));
    try testing.expectEqual(@as(MultiSpace.Code, 1002), MultiSpace.codeOf(MultiSpace.Error.INVALID_HANDLE));
    try testing.expectEqual(@as(MultiSpace.Code, 2000), MultiSpace.codeOf(MultiSpace.Error.INVALID_UTF8));
    try testing.expectEqual(@as(MultiSpace.Code, 2001), MultiSpace.codeOf(MultiSpace.Error.BUFFER_OVERFLOW));
}

test "multi-domain: errorOf maps across domains" {
    try testing.expectEqual(
        @intFromError(MultiSpace.Error.FILE_NOT_FOUND),
        @intFromError(MultiSpace.errorOf(1000).?),
    );
    try testing.expectEqual(
        @intFromError(MultiSpace.Error.INVALID_UTF8),
        @intFromError(MultiSpace.errorOf(2000).?),
    );
}

test "multi-domain: messageOf maps across domains" {
    try testing.expectEqualStrings("File not found",         MultiSpace.messageOf(1000).?);
    try testing.expectEqualStrings("Invalid UTF-8 sequence", MultiSpace.messageOf(2000).?);
    try testing.expectEqualStrings("Buffer overflow",        MultiSpace.messageOf(2001).?);
}

// ── TypeScript emission ────────────────────────────────────────────────────────

test "emitTypeScript: produces valid TypeScript structure" {
    const emitted = IoSpace.emitTypeScript();
    try testing.expect(std.mem.indexOf(u8, emitted, "export type ErrorCode").? >= 0);
    try testing.expect(std.mem.indexOf(u8, emitted, "export const CODE_TO_NAME: Record<number, ErrorCode>").? >= 0);
    try testing.expect(std.mem.indexOf(u8, emitted, "export const CODE_TO_MESSAGE: Record<number, string>").? >= 0);
    try testing.expect(std.mem.indexOf(u8, emitted, "export const DOMAIN_OF: Record<number, string>").? >= 0);
    try testing.expect(std.mem.indexOf(u8, emitted, "FILE_NOT_FOUND").? >= 0);
    try testing.expect(std.mem.indexOf(u8, emitted, "1000:").? >= 0);
    try testing.expect(std.mem.indexOf(u8, emitted, "9999") == null);
}

test "emitTypeScript: codes are base+ordinal" {
    const emitted = IoSpace.emitTypeScript();
    try testing.expect(std.mem.indexOf(u8, emitted, "1000: \"FILE_NOT_FOUND\"").? >= 0);
    try testing.expect(std.mem.indexOf(u8, emitted, "1001: \"PERMISSION_DENIED\"").? >= 0);
    try testing.expect(std.mem.indexOf(u8, emitted, "1002: \"INVALID_HANDLE\"").? >= 0);
}

test "emitTypeScript: messages are correct" {
    const emitted = IoSpace.emitTypeScript();
    try testing.expect(std.mem.indexOf(u8, emitted, "1000: \"File not found\"").? >= 0);
    try testing.expect(std.mem.indexOf(u8, emitted, "1001: \"Permission denied\"").? >= 0);
}

test "emitTypeScript: union syntax uses | prefix except last" {
    const emitted = IoSpace.emitTypeScript();
    try testing.expect(std.mem.indexOf(u8, emitted, "  | \"FILE_NOT_FOUND\"").? >= 0);
    try testing.expect(std.mem.indexOf(u8, emitted, "  | \"PERMISSION_DENIED\"").? >= 0);
    try testing.expect(std.mem.indexOf(u8, emitted, "  \"INVALID_HANDLE\"").? >= 0);
}

test "emitTypeScript: DOMAIN_OF contains domain names" {
    const emitted = IoSpace.emitTypeScript();
    try testing.expect(std.mem.indexOf(u8, emitted, "1000: \"io\"").? >= 0);
}

test "emitTypeScript: multi-domain emits all entries" {
    const emitted = MultiSpace.emitTypeScript();
    try testing.expect(std.mem.indexOf(u8, emitted, "1000: \"FILE_NOT_FOUND\"").? >= 0);
    try testing.expect(std.mem.indexOf(u8, emitted, "1002: \"INVALID_HANDLE\"").? >= 0);
    try testing.expect(std.mem.indexOf(u8, emitted, "2000: \"INVALID_UTF8\"").? >= 0);
    try testing.expect(std.mem.indexOf(u8, emitted, "2001: \"BUFFER_OVERFLOW\"").? >= 0);
    // Both domain names appear
    try testing.expect(std.mem.indexOf(u8, emitted, "1000: \"io\"").? >= 0);
    try testing.expect(std.mem.indexOf(u8, emitted, "2000: \"hash\"").? >= 0);
}
