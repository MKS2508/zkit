// expect: TypedSlab.lock requiere .thread_safe = true
const zkit = @import("zkit");
const Tag = struct {};
test {
    var s = try zkit.safety.TypedSlab(u32, Tag, .{}).init(@import("std").testing.allocator, 1);
    defer s.deinit();
    _ = s.lock(.none);
}
