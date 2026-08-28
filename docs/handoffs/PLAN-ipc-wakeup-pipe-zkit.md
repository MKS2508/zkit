---
type: plan
unit: cand/ipc-wakeup-pipe
status: ready
profile: compact
source: zkit.model.yml#cand/ipc-wakeup-pipe
effort: S
commit-strategy: single
commit-prefix: feat-phase(unscoped)
generatedBy: task-decomposer
roadmapItemId: cand/ipc-wakeup-pipe
suggestedBranch: task/cand/ipc-wakeup-pipe
---

# Plan: cand/ipc-wakeup-pipe — WakeupPipe a zkit (Zig puro, sin C-ABI)

## Goal

Portar `WakeupPipe` (pipe-based wakeup cross-thread, `std.c.*` Darwin-style,
~151 líneas) de `hyperdiff/core/zig/src/watch/ipc.zig` a `zkit/src/ipc.zig`,
re-exportado flat en `root.zig`, con sus 2 tests inline verdes. Puerto fiel:
cero rediseño de API, cero C-ABI. Cierra SOLO el lado zkit — el borrado del
original en hyperdiff (`gt/extraer-sin-sustituir`) es de la lane hermana.

## Cambios

- **`zkit/src/ipc.zig`** (nuevo, ~154 líneas — 151 del original menos las
  10 del bloque de doc-comment sustituido más las 13 del bloque
  genericizado, no verificar contra un conteo exacto) — copia de
  `hyperdiff/core/zig/src/watch/ipc.zig` con UN cambio de texto (código y
  API byte-idénticos, cero rediseño): el doc-comment de cabecera (líneas
  8-17 del original, bloque "## Consumer Integration (Bun example)") nombra
  `hyperdiff_watch_get_fd`/`hyperdiff_watch_drain` — símbolos C-ABI de
  hyperdiff que no existen en zkit y que zkit no define (ese C-ABI es
  `cand/ipc-wakeup`, nodo distinto, fuera de este plan). Por la regla de
  puerto del CLAUDE.md ("los nombres de dominio no cruzan"), genericizar
  ese bloque a:

  ```zig
  //! ## Consumer Integration (example)
  //!
  //! Expose `read_fd` through your own FFI/handle surface, then integrate
  //! with any event loop that watches raw fds (epoll/kqueue/libuv/Bun via
  //! `node:net`):
  //!
  //! ```typescript
  //! const fd = getReadFd(handle);        // your FFI accessor
  //! const pipe = new net.Socket({ fd, readable: true, writable: false });
  //! pipe.on('readable', () => {
  //!   const count = drainEvents(handle, buffer, bufferLen); // your drain call
  //!   for (let i = 0; i < count; i++) processChange(buffer[i]);
  //! });
  //! ```
  ```

  Líneas 1-6 del doc-comment original (mecanismo genérico: pipe +
  ring-buffer conceptual, sin nombrar símbolos de hyperdiff) SÍ se
  mantienen tal cual — no hay cruce de dominio ahí.
  El doc-comment interno "Mirrors the std Io/Dispatch pattern since
  std.c.pipe2 is {} on darwin" (línea 22 del original, sobre
  `pipe2WithFlags`) SE MANTIENE tal cual: verificado contra el std de este
  mismo toolchain (`lib/std/c.zig:10464-10467` — `pipe2` cae al
  `else => {}` del switch en `native_os` para macOS/darwin; sólo
  dragonfly/emscripten/netbsd/freebsd/illumos/openbsd/linux/serenity
  tienen `private.pipe2` real). Es un hecho verificado de la stdlib, no
  una apología de workaround — no lo toques. Todo lo demás (helpers
  privados `pipe2WithFlags`/`pipeOk`, `WakeupPipe` público
  `init/deinit/wake/clear/isValid`, los 2 tests inline `"WakeupPipe: init
  and deinit"` / `"WakeupPipe: wake and clear"`) es copia literal.
  `zig fmt --check` sobre el original YA pasa (exit 0) — sólo el bloque de
  arriba necesita reformat manual tras editarlo.

- **`zkit/src/root.zig`** — añadir 1 línea al final (tras la línea 14,
  `errors`), siguiendo el patrón flat existente (ej. línea 12 `HandleSlab`):

  ```zig
  pub const WakeupPipe = @import("ipc.zig").WakeupPipe;
  ```

- **`zkit/build.zig:32-42`** (array `standalone_tests`) — añadir
  `"src/ipc.zig",` como última entrada, antes del `};` de cierre (línea 42):

  ```zig
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
  ```

- **`zkit/build.zig:23-27`** (`_ = b.addModule("zkit", ...)`) — **NO tocar
  de entrada.** Verificado EMPÍRICAMENTE en este toolchain
  (`0.17.0-dev.1893+78e3b1c73`), no asumido: (1) copié `ipc.zig` a un
  build.zig standalone en scratch, `zig build test` → exit 0, 2/2 tests
  verdes, sin `.link_libc` en ningún lado; (2) control positivo YA dentro
  de este mismo `zkit/build.zig`: `src/watchdog.zig` llama
  `std.c.nanosleep`/`std.c.clock_gettime` sin `.link_libc` en el
  `addModule("zkit", ...)` y hoy pasa verde (baseline `19/19` steps de test
  antes de este plan). Contraste: el `ipc_mod` de hyperdiff SÍ lleva
  `.link_libc = true, // pipe/fcntl/close externs` (su `build.zig:102`),
  pero ahí es un `createModule` AISLADO sin más símbolos libc alrededor —
  no comparable 1:1 con el módulo `zkit` que ya linka libc transitivamente
  vía watchdog. Si pese a esto `zig build test` (paso de verify abajo)
  falla con símbolo de libc no resuelto, entonces y sólo entonces añadir
  `.link_libc = true,` a ese `addModule`.
  Tercera verificación, la más fuerte: apliqué los 3 cambios de este plan
  sobre una copia de trabajo y corrí `zig build test --summary all` de
  verdad — `21/21 steps succeeded; 2/2 tests passed`, sin tocar
  `.link_libc`. Los números del bloque Verify de abajo no son una
  predicción aritmética, son la salida real de esa corrida.

## Alcance — qué NO cierra este plan

- NO toca `hyperdiff` (borrado del original + import de la copia zkit) —
  lane hermana, otro dueño (axon1). El nodo SSOT `cand/ipc-wakeup-pipe`
  queda **parcialmente cerrado** tras ejecutar este plan: por
  `gt/extraer-sin-sustituir`, "NO está hecho hasta que el original en
  hyperdiff está BORRADO y hyperdiff importa la copia de zkit — no basta
  con copiar". No marcar `status: done` en `zkit.model.yml` sólo con este
  plan ejecutado.
- NO toca `conduit` (`packages/sdk-zig/src/sdk.zig:13`) — repo no clonado
  localmente, fuera de alcance explícito.
- NO es el port C-ABI del wire (eso es `cand/ipc-wakeup`, nodo distinto,
  bloqueado en la §5 sin decidir).

## Verify

Baseline medido antes de este plan (repo limpio, mismo toolchain):
`zig build test --summary all` → `19/19 steps succeeded`, 0 fallos (9
ficheros × compile+run + 1 step agregado `test`).

Tras los 3 cambios:

```bash
cd "zkit" && zig build test --summary all
```

Esperado (ya reproducido sobre copia de trabajo, no es predicción):
`21/21 steps succeeded; 2/2 tests passed`, y la salida debe incluir el par
`run test` / `compile test debug native` nuevo correspondiente a
`src/ipc.zig` que no existía en el baseline.

OJO — `zig build` (plano, sin `test`) NO sirve como verify de este cambio:
hoy es `1/1 steps succeeded` porque `_ = b.addModule("zkit", ...)` con el
resultado descartado no crea ningún step que compile `root.zig`; nada en
el árbol referencia el módulo `zkit` desde dentro del propio repo. Seguirá
en `1/1` verde aunque la línea nueva de `root.zig` tenga un typo. El check
real para la cadena de re-export (`root.zig` → `ipc.zig` → `WakeupPipe`)
es un consumidor downstream que la importe por `@import("zkit")`:

```bash
mkdir -p /tmp/zkit-reexport-probe/src && cd /tmp/zkit-reexport-probe
cat > src/main.zig <<'EOF'
const std = @import("std");
const zkit = @import("zkit");
test "consumer sees zkit.WakeupPipe through root.zig re-export" {
    var pipe = try zkit.WakeupPipe.init();
    defer pipe.deinit();
    try std.testing.expect(pipe.isValid());
}
EOF
cat > build.zig <<'EOF'
const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zkit_dep = b.dependency("zkit", .{ .target = target, .optimize = optimize });
    const t = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize,
        .imports = &.{.{ .name = "zkit", .module = zkit_dep.module("zkit") }},
    }) });
    b.step("test", "run").dependOn(&b.addRunArtifact(t).step);
}
EOF
cat > build.zig.zon <<'EOF'
.{ .name = .zkit_consumer_probe, .version = "0.0.0", .fingerprint = 0xcb52886bf17fc6fb,
   .dependencies = .{ .zkit = .{ .path = "/ruta/absoluta/a/zkit" } },
   .paths = .{ "build.zig", "build.zig.zon", "src" } }
EOF
zig build test --summary all
```

Ya ejecutado tal cual (mismo nombre `.zkit_consumer_probe` y fingerprint,
sobre una copia de trabajo con los 3 cambios aplicados, dependencia por
`path` al `zkit` modificado): `3/3 steps succeeded; 1/1 tests passed`. El
fingerprint está atado al `.name` del `.zon` — si renombras el paquete
`zig build` imprime el fingerprint correcto a usar, no reutilices el de
arriba con otro nombre. Es el check que de verdad ejercita la línea nueva
de `root.zig` — `zig build` plano no la ejercita en absoluto.

Opcional, control de estilo: `zig fmt --check src/ipc.zig` → exit 0 (ya
verificado sobre el original antes de copiar; el bloque de doc-comment
genericizado puede necesitar `zig fmt` tras editarlo a mano).

## Git context

- Rama sugerida: `task/cand/ipc-wakeup-pipe`
  (inferida de: `roadmapItemId=cand/ipc-wakeup-pipe`, sin `phase` en el
  nodo SSOT → fallback `task/<roadmapItemId>`)
- Commit prefix: `feat-phase(unscoped)` — fallback por ausencia de `phase`
  en el nodo SSOT. Nota: este repo NO usa nomenclatura de phases
  (`zkit.model.yml` usa `track:` — `cand`/`audit`/`trans`, no fases tipo
  `0.10.4.A`), así que si el equipo prefiere `feat(ipc):` convencional
  simple en vez de `feat-phase(unscoped)`, es una elección de estilo
  legítima — el CLAUDE.md del repo sólo exige "conventional, sin
  co-author".
- Tag para hook: `[#cand/ipc-wakeup-pipe]` — incluir en el commit para que
  el hook `post-tool-use-bash` (si `@mks-agentics/task-sync` está activo en
  este repo) linkee el commit a la UDA `gitcommit`. Si no hay TW conectado,
  el tag es noop y el commit sigue siendo válido.
- Estrategia: `single` — un solo commit: 1 fichero nuevo + 2 ediciones de
  1 línea/1 entrada. No hay milestones independientes que ameriten
  separación (el port es una unidad atómica, ~30-45min de trabajo real).
