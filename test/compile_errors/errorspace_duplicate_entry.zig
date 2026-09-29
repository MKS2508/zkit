// expect: ErrorSpace: error.file_not_found has more than one entry
const errors = @import("zkit_errors");
const E = error{file_not_found};
const S = errors.ErrorSpace(E, &.{
    .{ .name = "a", .base = 1, .entries = &.{.{ .tag = "file_not_found", .message = "x" }} },
    .{ .name = "b", .base = 10, .entries = &.{.{ .tag = "file_not_found", .message = "y" }} },
});
test {
    _ = S.codeOf(error.file_not_found);
}
