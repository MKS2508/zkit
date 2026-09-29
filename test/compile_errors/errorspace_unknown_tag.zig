// expect: ErrorSpace: entry 'range_too_large' in domain 's' is not a variant of E
const errors = @import("zkit_errors");
const E = error{file_not_found};
const S = errors.ErrorSpace(E, &.{.{ .name = "s", .base = 1, .entries = &.{
    .{ .tag = "file_not_found", .message = "x" },
    .{ .tag = "range_too_large", .message = "y" },
} }});
test {
    _ = S.codeOf(error.file_not_found);
}
