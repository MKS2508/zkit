# Hyperdiff como consumidor de zkit — informe

Todas las rutas son relativas a `hyperdiff/core/zig/`. Todo VERIFICADO (fichero abierto) salvo donde se marca INFERIDO.

## 1. Consumo actual — SÍ hay dependencia, ya activa hoy

`build.zig.zon:8-11` declara la dependencia:
```
.zkit = .{ .url = "https://github.com/MKS2508/zkit/archive/09fd8cfc...", .hash = "zkit-0.0.0-..." }
```

`build.zig:156-157` la resuelve (`b.dependency("zkit", ...)`) y `build.zig:154-155` documenta el motivo: *"Provides HandleSlab (the FFI handle ABI used by watch and cache exports) and ErrorSpace (errors.ts gate)"*. Se wirea como import `"zkit"` en: módulo principal `hyperdiff` (build.zig:210), lib/static_lib compartidas (256, 275), CLI exe (295), tests de exports/watch-exports (509-522), bench_ffi (605), y build WASM (643-665, dependencia separada `zkit_wasm_mod`).

Puntos de consumo real en código (no solo build.zig):
- `src/exports.zig:50,153,155,157` — `zkit.HandleSlab(*CachedFile)` para el slab de cachés FFI (máx 256 concurrentes).
- `src/watch/exports.zig:40,47,354` — `zkit.HandleSlab(*WatcherState)` (WatchSlab) y `zkit.HandleSlab(*SessionHandle)` (SessionSlab).
- `src/errors.zig:27,57` — `@import("zkit").errors`, usado como `space.ErrorSpace(ErrorCode, &.{...})` para los 38 códigos de error compartidos con TS (io/hash/cache/thread/diff/validation/allocator). `src/errors_core.zig:4` documenta explícitamente que ese fichero *"intentionally has NO dependency on zkit"* — el split es: datos de dominio (errors_core.zig) vs. mecanismo genérico comptime (zkit.errors, consumido en errors.zig).
- `src/bench_ffi_optimizations.zig:12` — también importa zkit (no inspeccioné el uso concreto, fuera de scope de la pregunta).

**Conclusión: hyperdiff NO es un consumidor hipotético de zkit — ya consume 2 de sus 6 primitivas (`HandleSlab`, `errors.ErrorSpace`) de forma profunda y en el hot path de FFI.** El catálogo de zkit (`docs/catalogo-infra-extraible.md`) habla de "cuando entre un tercer consumidor" en el sentido de subir código DE hyperdiff HACIA zkit — dirección inversa a esta pregunta, y no contradice lo anterior.

## 2. Duplicados — de los 6 módulos de zkit, sólo 2 tienen equivalente en hyperdiff, y no son duplicados sino consumo directo

Grep de `Watchdog|TrackingAllocator|SubscriberQueue|ReorderBuffer|SequenceNumber|deadline-heartbeat` sobre todo `core/zig/src` (excluyendo el paquete vendorizado):

| módulo zkit | ¿hyperdiff tiene equivalente propio? | veredicto |
|---|---|---|
| `HandleSlab` | No — usa `zkit.HandleSlab` directo (ver §1) | sin duplicado |
| `errors` (ErrorSpace) | No — usa `zkit.errors.ErrorSpace` directo (ver §1) | sin duplicado |
| `SubscriberQueue(T)` | No literal. Lo más cercano conceptualmente es `RingBuffer` en `src/watch/event_queue.zig:182-` (SPSC, overflow como flag atómico global + "hacer rescan completo", no discontinuidad por item) | **no es el mismo diseño**: SubscriberQueue señaliza overflow por item vía `PopResult.discontinuity` (zkit `subscriber_queue.zig:1-30`); el RingBuffer de hyperdiff usa un flag global + estrategia de recovery "rescan completo" propia del dominio watch (coalescing FS events). No comparable 1:1, no hay redundancia real que limpiar. |
| `ReorderBuffer(T)` | No. `drainSince` en `src/watch/session.zig:853-` es un filtro por cursor monotónico (`ev.cursor > since_cursor`, scan lineal) sobre datos YA ordenados — resuelve "dame todo después de X", no reensamblado fuera de orden. zkit `ReorderBuffer` indexa por `seq % bound` para reordenar llegadas desconectadas, con `gapTimeout` + reset terminal (`reorder_buffer.zig:1-16`). | problema distinto, sin solape real |
| `HungWorkerWatchdog` | No existe ningún concepto de heartbeat/pet()/hung-worker en el repo (grep vacío para `heartbeat|hung.?worker|pet\(\)`). Los "deadline" que sí aparecen (`platform_kqueue.zig:140-143`, `platform.zig:2108-2177`) son timers de debounce/coalescing, no vigilancia de workers colgados. | sin duplicado, zkit aporta algo que hoy no existe |
| `TrackingAllocator` | No existe (grep vacío para `live_bytes|allocated\.fetchAdd|TrackingAllocator`) | sin duplicado |
| `log` (`zkit.log.scoped`) | **Sí hay solape de intención, sin consumo.** Tres ficheros (`watch/platform.zig:22-25`, `src/exports.zig:35-38`, y presumiblemente el 3er root de compilación) declaran a mano `pub const std_options: std.Options = .{ .log_level = .err }` — exactamente lo que hace `zkit/src/log.zig:16-19`. Además `session.zig`, `platform_kqueue.zig` y `platform.zig` usan `std.log.scoped(.nombre_atom)` nativo de Zig en vez de `zkit.log.scoped("nombre")` (que es un wrapper que concatena `[name]` como string, NO el mecanismo de scopes nativo). **Diferencia real, no cosmética**: el scope nativo de Zig (`std.log.scoped`) es filtrable en runtime/comptime vía `std_options.log_scope_levels` por scope individual; el `scoped()` de zkit es sólo un prefijo de string sobre el scope por defecto — pierde esa granularidad. Es decir, en este punto concreto **la práctica de hyperdiff es más idiomática/potente que zkit.log**, aunque duplica la parte de "silenciar logs no-err en build de dylib" en 2+ sitios en vez de centralizarla. INFERIDO (semántica de módulos Zig, no compilado para confirmar): `platform.zig` sólo aparece como módulo importado (`build.zig:108` es `b.addModule`, nunca root de un `addExecutable/addLibrary/addTest`), así que su `std_options` probablemente no tiene efecto real sobre el binario final — el que manda es el de `exports.zig`, que sí es root de lib/static_lib/tests. No verificado compilando. |

## 3. Candidatos a subir — el catálogo acierta en 8/9, se equivoca en las líneas de 1

Medí `wc -l` real + `@import` completo + `extern struct` de los 9 módulos listados en `docs/catalogo-infra-extraible.md`:

| módulo | líneas catálogo | líneas REAL (verificado) | imports reales | extern struct |
|---|---:|---:|---|---|
| `watch/sync.zig` | 321 | **321** ✓ | `std`, `builtin` | ninguno |
| `watch/ipc.zig` | 151 | **151** ✓ | `std` | ninguno |
| `watch/hot_ranker.zig` | 372 | **372** ✓ | `std` | ninguno |
| `watch/state/blob_cache.zig` | 273 | **273** ✓ | `std` | `CacheStats` (blob_cache.zig:25) — telemetría, sin forma de dominio diff |
| `watch/patch_ring.zig` | 625 | **671** ✗ (catálogo desactualizado) | `std`, `builtin` | `RecordHeader` (patch_ring.zig:38) — 4 campos genéricos de bytes (`record_len`,`path_len`,`patch_len`,`repo_id`), sin línea/edit counts. Confirmado: NO tiene forma de dominio diff. |
| `watch/platform_kqueue.zig` | 1125 | **1125** ✓ | `std`, `builtin`, `sync` | ninguno |
| `watch/platform.zig` | 2289 | **2289** ✓ | `std`, `builtin`, `ipc`, `sync` | `CFRunLoopSourceContext` (platform.zig:175), `FSEventStreamContext` (platform.zig:188) — ABI de Apple, no de dominio |
| `watch/event_queue.zig` | 542 | **542** ✓ | `std`, `sync` | `CChange` (event_queue.zig:64-118) — **sí tiene forma de dominio**: `old_line_count`, `new_line_count`, `edit_count`, `added_lines`, `deleted_lines`, `content_hash` ("Shiki/SSR cache key"), `cache_handle`. `CStatusBatch` (166) también. |
| `watch/patch_queue.zig` | 295 | **295** ✓ | `std` | `CWatchPatchEvent` (patch_queue.zig:15-36) — mismos campos de dominio (`old/new_line_count`, `edit_count`, `added/deleted_lines`) + timings de pipeline (`diff_ns`,`format_ns`). `CWatchPatchBatch` (38). |

**Única corrección al catálogo: `patch_ring.zig` es hoy 671 líneas, no 625.** Causa verificada: commit `73e5432` ("fix(watch): un patch de 1-4 MiB atascaba el PatchRing para siempre", `Fri Aug 28 06:14:28 2026`) añadió 48 líneas netas (drain retry vs. discard-and-count) DESPUÉS de que se escribiera el catálogo (mismo día). El resto de la tabla Tier 1/Tier 2 del catálogo es exacta: imports y extern structs verificados coinciden campo por campo con lo que dice el documento, incluyendo la distinción correcta entre externs "de dominio" (event_queue, patch_queue) y "no de dominio" (blob_cache, patch_ring, platform).

## 4. Acoplamiento — qué bloquea mover cada uno HOY

- **Tier 1 (sync, ipc, hot_ranker, blob_cache, patch_ring, platform_kqueue, platform) — nada de dominio bloquea.** El único acoplamiento real es el grafo interno ya documentado en el catálogo (`sync → event_queue`, `sync/ipc → platform`, `sync → platform_kqueue`) — mover uno sin sus dependencias hojas no compila, pero mover el conjunto sí es mecánico.
- **`event_queue.zig`**: el `RingBuffer` (event_queue.zig:182) está definido como `buffer: []CChange` — no genérico sobre `T`. Para subirlo a zkit habría que parametrizar `RingBuffer(comptime T: type)` y mover `CChange`/`CStatusBatch` se queda en hyperdiff (son ABI pública hacia la capa TS — `event_queue.zig:44` dice literalmente "Numeric mapping is part of the public ABI — matches `BaselineErrorCode` in `core/packages/utils/src/types.ts`"). Bloqueo concreto: el tipo del payload es parte de un contrato cruzando el límite Zig↔TS, no sólo interno.
- **`patch_queue.zig`**: mismo patrón — `CWatchPatchEvent`/`CWatchPatchBatch` (patch_queue.zig:15,38) llevan campos de diff (`old_line_count`, `edit_count`, etc.) y timings de pipeline (`diff_ns`, `format_ns`) específicos de hyperdiff. `OwnedPatchEvent` (patch_queue.zig:48) además gestiona ownership de memoria atado a esos tipos concretos.
- Ninguno de los 9 usa un `extern` del dominio diff propiamente dicho (`CEdit`, `DiffResult` de `types.zig` no aparecen en ninguno de los 9 — confirmado por el grep de `@import` + `extern struct`, cero referencias cruzadas a `types.zig` en estos ficheros).

## 5. Frontera — zkit se consume como módulo Zig linkado, NO por C-ABI

Verificado: `grep -rn "export fn\|callconv(.C)"` sobre todo `zkit/src/` → **cero resultados**. zkit no expone ningún C-ABI propio, es una librería Zig pura pensada para `addImport`.

Hyperdiff sí expone su propio C-ABI hacia SUS consumidores (Bun FFI, NAPI) en `src/exports.zig` (comentario cabecera: *"All functions use C ABI for consumption from any language via dlopen"*) y `src/watch/exports.zig` (`hyperdiff_watch_*`, 15+ símbolos) — pero esa frontera es hacia AFUERA de hyperdiff, no hacia zkit.

Implicación: la única forma en que zkit entra hoy en hyperdiff es como **módulo Zig linkado directo** (`b.dependency` + `addImport`, ver §1) — mismo patrón para lib nativa, WASM y tests. Si un consumidor futuro quisiera zkit vía C-ABI en vez de link directo, tendría que ser zkit quien añada `export fn`/`callconv(.c)` — hoy no existe esa opción porque zkit no tiene frontera C-ABI, sólo frontera de módulo Zig (que exige que el consumidor también compile en Zig, no sirve para consumidores desde Bun/Node/Python vía dlopen). Esto es coherente con cómo hyperdiff YA usa zkit (link directo, mismo toolchain) vs. cómo hyperdiff expone SU PROPIA superficie (C-ABI, cualquier lenguaje) — son dos capas de acoplamiento distintas y no deberían confundirse en la decisión de mañana.

---

**Archivos citados** (todos bajo `/Volumes/KODAK1TB/REPOS y PROYECTOS/zig-and-node-bun-related/hyperdiff/core/zig/`, salvo zkit explícito):
`build.zig.zon`, `build.zig`, `src/exports.zig`, `src/errors.zig`, `src/errors_core.zig`, `src/watch/exports.zig`, `src/watch/event_queue.zig`, `src/watch/patch_queue.zig`, `src/watch/patch_ring.zig`, `src/watch/platform.zig`, `src/watch/platform_kqueue.zig`, `src/watch/session.zig`; y en zkit: `src/root.zig`, `src/log.zig`, `src/errors.zig`, `src/subscriber_queue.zig`, `src/reorder_buffer.zig`, `src/watchdog.zig`, `src/tracking_allocator.zig`, `src/handle.zig`, `docs/catalogo-infra-extraible.md`.

No se modificó ni creó ningún fichero.