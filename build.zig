const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Zig Module (for `zig fetch` / `@import("zkit")`) ──────────
    _ = b.addModule("zkit", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Tests ──────────────────────────────────────────────────────
    const test_step = b.step("test", "Run zkit tests");

    const standalone_tests = [_][]const u8{
        "src/subscriber_queue.zig",
        "src/reorder_buffer.zig",
        "src/watchdog.zig",
        "src/tracking_allocator.zig",
        "src/handle.zig",
        "src/log.zig",
        "src/test_reorder_buffer_bound.zig",
        "src/test_watchdog.zig",
    };
    for (standalone_tests) |src| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
