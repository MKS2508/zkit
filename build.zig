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
        // `root.zig` arrastra los tests de todos los módulos que exporta
        // (ver su bloque `test`); los tres `test_*.zig` son suites aparte.
        "src/root.zig",
        "src/test_reorder_buffer_bound.zig",
        "src/test_watchdog.zig",
        "src/test_errors.zig",
        "src/test_errors_space_v2.zig",
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

    // ── Guards comptime: tienen que FALLAR al compilar ─────────────────────
    // Cada caso es código que zkit debe rechazar; el paso pasa sólo si la
    // compilación falla con el mensaje esperado. Un guard que nunca se ha
    // visto fallar no es un guard (CLAUDE.md).
    const CompileError = struct { file: []const u8, module: []const u8, root: []const u8, expect: []const u8 };
    const compile_errors = [_]CompileError{
        .{ .file = "test/compile_errors/errorspace_missing_entry.zig", .module = "zkit_errors", .root = "src/errors.zig", .expect = "ErrorSpace: error.path_traversal has no entry" },
        .{ .file = "test/compile_errors/errorspace_unknown_tag.zig", .module = "zkit_errors", .root = "src/errors.zig", .expect = "ErrorSpace: entry 'range_too_large' in domain 's' is not a variant of E" },
        .{ .file = "test/compile_errors/errorspace_duplicate_entry.zig", .module = "zkit_errors", .root = "src/errors.zig", .expect = "ErrorSpace: error.file_not_found has more than one entry" },
        .{ .file = "test/compile_errors/typed_handle_mixup.zig", .module = "zkit", .root = "src/root.zig", .expect = "expected type 'safety.handle.Handle(typed_handle_mixup.BufferTag)', found 'safety.handle.Handle(typed_handle_mixup.SessionTag)'" },
        .{ .file = "test/compile_errors/typed_slab_lock_single_thread.zig", .module = "zkit", .root = "src/root.zig", .expect = "TypedSlab.lock requiere .thread_safe = true" },
        .{ .file = "test/compile_errors/histogram_bad_bounds.zig", .module = "zkit", .root = "src/root.zig", .expect = "AtomicHistogram: bounds debe ser estrictamente creciente" },
    };
    for (compile_errors) |ce| {
        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "test", "-lc", "--dep", ce.module });
        run.addPrefixedFileArg("-Mroot=", b.path(ce.file));
        run.addPrefixedFileArg(b.fmt("-M{s}=", .{ce.module}), b.path(ce.root));
        run.expectExitCode(1);
        run.expectStdErrMatch(ce.expect);
        // Siempre se re-ejecuta: el resultado depende de todo `src/`, no sólo
        // de los dos ficheros de la línea de comandos.
        run.has_side_effects = true;
        test_step.dependOn(&run.step);
    }

    // ── Fuzz guiado por cobertura ───────────────────────────────────────────
    // `zig build fuzz --fuzz=<N>`: sólo el binario raíz y sólo los tests que
    // usan `std.testing.fuzz` (vía `zkit.safety.fuzz.fuzzBytes`). Sin
    // `--fuzz` corre su corpus como un test normal.
    const fuzz_step = b.step("fuzz", "Coverage-guided fuzz of zkit parsers (use with --fuzz=N)");
    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .filters = &.{"std.testing.fuzz"},
    });
    fuzz_step.dependOn(&b.addRunArtifact(fuzz_tests).step);
}
