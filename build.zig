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
        // watchdog/ipc llaman a libc (`std.c.*`); desde 0.17-dev la dependencia
        // de libc tiene que declararse explícitamente en el módulo.
        .link_libc = true,
    });

    // ── Tests ──────────────────────────────────────────────────────
    // `-Dtsan=true`: lane ThreadSanitizer. Todo lo que tiene hilos en zkit
    // (sync, colas concurrentes, slab concurrente, LatestValue, histograma,
    // ZeroCopyBuffer, safety.Mutex, BudgetAllocator) corre sus tests de
    // estrés bajo TSAN con este flag. Canario: `-Dtsan-canary=true` añade un
    // test con una carrera deliberada que TIENE que fallar.
    const tsan = b.option(bool, "tsan", "Compile tests with ThreadSanitizer") orelse false;
    const tsan_canary = b.option(bool, "tsan-canary", "Add a deliberate data race (must FAIL under -Dtsan)") orelse false;
    const test_filters = b.option([]const []const u8, "test-filter", "Only run tests matching this filter") orelse &.{};

    const test_step = b.step("test", "Run zkit tests");

    var standalone_tests: std.ArrayList([]const u8) = .empty;
    standalone_tests.appendSlice(b.allocator, &.{
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
        "src/time.zig",
        "src/sync.zig",
        "src/os.zig",
        "src/fs.zig",
        "src/testing.zig",
    }) catch @panic("OOM");
    if (tsan_canary) standalone_tests.append(b.allocator, "src/test_tsan_canary.zig") catch @panic("OOM");

    for (standalone_tests.items) |src| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .sanitize_thread = if (tsan) true else null,
            }),
            .filters = test_filters,
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
