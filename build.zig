const std = @import("std");
const builtin = @import("builtin");

// `minimum_zig_version` in build.zig.zon is advisory — the build runner never
// checks it (a manifest declaring "0.99.0" builds fine on any toolchain). This
// block is the only thing that actually stops a build on the wrong compiler.
// Consumers link this module: a silent version mismatch here becomes their bug.
comptime {
    const required = std.SemanticVersion.parse("0.17.0-dev.1893+78e3b1c73") catch unreachable;
    if (builtin.zig_version.order(required) == .lt) {
        @compileError(
            "zkit requires Zig >= 0.17.0-dev.1893+78e3b1c73, found " ++
                builtin.zig_version_string,
        );
    }
}

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
        "src/test_errors.zig",
        "src/ipc.zig",
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
