// expect: ErrorSpace: error.path_traversal has no entry
const errors = @import("zkit_errors");
const E = error{ file_not_found, path_traversal };
const S = errors.ErrorSpace(E, &.{.{ .name = "s", .base = 1, .entries = &.{
    .{ .tag = "file_not_found", .message = "x" },
} }});
test {
    _ = S.codeOf(error.file_not_found);
}
