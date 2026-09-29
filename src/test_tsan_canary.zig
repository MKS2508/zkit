//! Canario de la lane TSAN: una carrera de datos DELIBERADA. Sólo se compila
//! con `-Dtsan-canary=true`, y con `-Dtsan=true` este test TIENE que hacer
//! fallar `zig build test`. Si pasa, la lane TSAN no está instrumentando nada
//! y su verde no significa nada (el "verde falso" que la regla de evidencia
//! de styx prohíbe).

const std = @import("std");

var shared: u64 = 0;

fn racer() void {
    for (0..100_000) |_| {
        const p: *volatile u64 = &shared;
        p.* += 1;
    }
}

test "canario TSAN: carrera deliberada (debe fallar bajo -Dtsan)" {
    const a = try std.Thread.spawn(.{}, racer, .{});
    const b = try std.Thread.spawn(.{}, racer, .{});
    a.join();
    b.join();
    std.mem.doNotOptimizeAway(shared);
}
