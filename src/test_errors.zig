//! Tests for zkit/errors — ErrorSpace mechanism.
const std = @import("std");
const testing = std.testing;
const errors = @import("errors.zig");

const IoErrors = error{
    FILE_NOT_FOUND,
    PERMISSION_DENIED,
    INVALID_HANDLE,
};

const IoSpace = errors.ErrorSpace(IoErrors, &[_]errors.Entry{
    .{ .tag = "FILE_NOT_FOUND", .code = 1000, .message = "File not found" },
    .{ .tag = "PERMISSION_DENIED", .code = 1001, .message = "Permission denied" },
    .{ .tag = "INVALID_HANDLE", .code = 1002, .message = "Invalid handle" },
});

test "codeOf: maps each error variant to its code" {
    try testing.expectEqual(@as(IoSpace.Code, 1000), IoSpace.codeOf(IoSpace.Error.FILE_NOT_FOUND));
    try testing.expectEqual(@as(IoSpace.Code, 1001), IoSpace.codeOf(IoSpace.Error.PERMISSION_DENIED));
    try testing.expectEqual(@as(IoSpace.Code, 1002), IoSpace.codeOf(IoSpace.Error.INVALID_HANDLE));
}

test "errorOf: maps code back to error variant" {
    // Compare via int to avoid nominal type aliasing mismatch between IoSpace.Error
    // (the E type alias inside the generated struct) and the IoErrors declared in
    // this test file — both are the same error set structurally.
    try testing.expectEqual(@intFromError(IoSpace.Error.FILE_NOT_FOUND), @intFromError(IoSpace.errorOf(1000).?));
    try testing.expectEqual(@intFromError(IoSpace.Error.PERMISSION_DENIED), @intFromError(IoSpace.errorOf(1001).?));
    try testing.expectEqual(@intFromError(IoSpace.Error.INVALID_HANDLE), @intFromError(IoSpace.errorOf(1002).?));
}

test "errorOf: unknown code returns null" {
    try testing.expectEqual(@as(?IoSpace.Error, null), IoSpace.errorOf(9999));
}

test "messageOf: returns the correct message" {
    try testing.expectEqualStrings("File not found", IoSpace.messageOf(1000).?);
    try testing.expectEqualStrings("Permission denied", IoSpace.messageOf(1001).?);
    try testing.expectEqualStrings("Invalid handle", IoSpace.messageOf(1002).?);
}

test "messageOf: unknown code returns null" {
    try testing.expectEqual(@as(?[]const u8, null), IoSpace.messageOf(9999));
}

test "emitTypeScript: produces valid TypeScript structure" {
    const emitted = IoSpace.emitTypeScript();
    try testing.expect(std.mem.indexOf(u8, emitted, "export type ErrorCode").? >= 0);
    try testing.expect(std.mem.indexOf(u8, emitted, "export const CODE_TO_NAME: Record<number, ErrorCode>").? >= 0);
    try testing.expect(std.mem.indexOf(u8, emitted, "export const CODE_TO_MESSAGE: Record<number, string>").? >= 0);
    try testing.expect(std.mem.indexOf(u8, emitted, "FILE_NOT_FOUND").? >= 0);
    try testing.expect(std.mem.indexOf(u8, emitted, "1000:").? >= 0);
    try testing.expect(std.mem.indexOf(u8, emitted, "9999") == null);
}

test "emitTypeScript: codes are sequential within domain starting at base" {
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

test "emitTypeScript: TypeScript union syntax uses | prefix except last" {
    const emitted = IoSpace.emitTypeScript();
    try testing.expect(std.mem.indexOf(u8, emitted, "  | \"FILE_NOT_FOUND\"").? >= 0);
    try testing.expect(std.mem.indexOf(u8, emitted, "  | \"PERMISSION_DENIED\"").? >= 0);
    try testing.expect(std.mem.indexOf(u8, emitted, "  \"INVALID_HANDLE\"").? >= 0);
}
