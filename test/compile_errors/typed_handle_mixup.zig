// expect: expected type 'safety.handle.Handle(typed_handle_mixup.BufferTag)', found 'safety.handle.Handle(typed_handle_mixup.SessionTag)'
const zkit = @import("zkit");
const SessionTag = struct {};
const BufferTag = struct {};
test {
    var buffers = try zkit.safety.TypedSlab(u32, BufferTag, .{}).init(@import("std").testing.allocator, 1);
    defer buffers.deinit();
    const session_handle = zkit.safety.Handle(SessionTag).fromRaw(1);
    _ = buffers.get(session_handle);
}
