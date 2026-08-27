# zkit-forge — LAUNCH report

## scaffold
  ficheros: [build.zig.zon, build.zig, src/root.zig]
  fingerprintPendiente: sí (value=undefined, requiere compilación para obtener valor real)
  patronBuildCopiadoDe: hyperdiff/core/zig/build.zig

## rescue
  portados:
    - spikes/candidate-h/src/subscriber_queue.zig (485 l) → src/subscriber_queue.zig
    - spikes/candidate-h/src/reorder_buffer.zig (825 l) → src/reorder_buffer.zig
    - spikes/candidate-h/src/watchdog.zig (235 l) → src/watchdog.zig
    - native/zig/media-daemon/tracking_allocator.zig (98 l) → src/tracking_allocator.zig
  testsInlineConservados: 11 (subscriber_queue) + 15 (reorder_buffer) + 6 (watchdog) + 0 (tracking_allocator)
  testsExternosPortados:
    - test_h_d2.zig (440 l) → src/test_reorder_buffer_bound.zig
    - test_hung_worker_watchdog.zig (171 l) → src/test_watchdog.zig
  adaptaciones:
    - subscriber_queue: doc-comment C-numerados del spike Candidate H → descripción del contrato real
    - subscriber_queue: todos los tests inline conservados (11)
    - reorder_buffer: mismo tratamiento de doc-comments (C-numerados removidos, semántica conservada)
    - watchdog: sin cambios (ya era genérico)
    - tracking_allocator: sin cambios (ya era genérico)
    - NO se portaron test_h_d1.zig, test_h_f7.zig (arrastran delivery_pump + delivery_profile)

## handle
  errorRenombrado: sí
    - origen: hyperdiff/core/zig/src/handle_slab.zig
    - cambio: `error.WatchQueueFull` → `error.PoolFull` en `alloc()` y en `expectError(error.WatchQueueFull, ...)` del test "full slab"
  otrosCambios: ninguno (resto del código idéntico al original)

## log
  quitado:
    - `init()` (función vacía, solo hacía `_ = std.log`)
    - comentario "// centralized logging configuration for hyperdiff" → "centralized logging configuration"
    - `std_options` mantenido (config de nivel err, sin scopes hardcodeados)

## sinVerificar (no compila — matriz de benchmarks en curso)
  - build.zig.zon fingerprint: `undefined` necesita valor real tras `zig build`; la primera compilación lo rechazará y dirá el valor correcto
  - `std.atomic.Value(bool)` en watchdog.zig línea 47 — necesita verificar que `std.atomic.Value(bool).init(false)` compila en 0.17.0-dev.1884+841dd0eb8 (el API atómico cambió mucho entre versiones)
  - `std.c.clock_gettime` y `std.c.nanosleep` en watchdog — requiere `link_libc`; el test runner actual no lo pasa, habría que añadir `.link_libc = true` al módulo de test o verificar que `b.addTest` con `root_module`propaga `link_libc` correctamente desde el módulo
  - `std.c.CLOCK.MONOTONIC` —不确定是否存在，需要验证
  - subscriber_queue/test_reorder_buffer_bound/test_watchdog: todos los tests inline usan `std.testing.allocator` correctamente, pero no hay forma de verificar leaks hasta poder compilar
  - handle.zig: `error.PoolFull` vs `error.WatchQueueFull` — el rename compila (el test externo espera `error.PoolFull`), pero el test inline "full slab returns error" en handle.zig también cambió (antes esperaba `error.WatchQueueFull`, ahora `error.PoolFull`)
  - build.zig: los tests de tracking_allocator.zig y watchdog.zig necesitan libc (uses `std.c.*`); habría que añadir `link_libc = true` a esos test modules o verificar si `b.addTest` lo soporta

## dudas
  - ¿El test runner de Zig en 0.17.0-dev.1884 soporta `std.c.clock_gettime` sin link_libc en tests? En caso negativo, habría que marcar los tests de watchdog como libc-dependent o separar los tests que usan `nowMs()` en un build config diferente.
  - ¿Los 11 tests inline de subscriber_queue (y los otros) funcionan con `std.testing.allocator` cuando se lancen con `zig build test`? No hay forma de verificar leaks sin compilar.
