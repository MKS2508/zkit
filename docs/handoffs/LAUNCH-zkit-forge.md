# LAUNCH — zkit-forge (scaffold + puerto de primitivas)

Eres la lane `zkit-forge`. Trabajas en un worktree del repo **zkit**, que acaba de
nacer y todavía no tiene ni una línea de Zig. Tu trabajo es ponerle el esqueleto y
traer las primitivas que vienen de otros dos repos.

## 🔴 REGLA DURA — NO COMPILES

**Prohibido ejecutar `zig build`, `zig build test`, `zig test`, `zig run` o
cualquier cosa que compile.** Hay una matriz de benchmarks midiendo latencias de
filesystem en esta máquina y cualquier proceso pesado la contamina; ya se ha
tenido que relanzar seis veces. Comprueba con `pgrep -f runner.ts` si dudas: si
devuelve algo, no compilas.

Esto significa que vas a escribir código Zig **sin poder verificarlo**. Es
deliberado. Escribe con cuidado, apóyate en leer el original, y cuando termines
**para y reporta**: yo te desbloqueo para compilar en cuanto la matriz acabe.
Un `zig build` a escondidas invalida ~2h de medidas ajenas.

Lo que **sí** puedes hacer sin límite: leer, escribir ficheros, `git`, `grep`,
`diff`, `wc`. Y `zig fmt` **no** compila (solo parsea) — ese sí puedes usarlo.

## Lee esto primero

`zkit.model.yml` en la raíz del repo es la **autoridad** del programa. Léelo
entero antes de tocar nada. En particular:

- `locks:` — decisiones de waxin que no se re-abren.
- `groundTruth:` — hechos ya verificados. **No los re-descubras ni los pongas en
  duda sin evidencia nueva**; cada uno costó tiempo de averiguar.
- `nodes:` — el DAG. Tus nodos son `zkit/scaffold`, `zkit/rescue`, `zkit/handle`
  y `zkit/log`. **`zkit/errors-mechanism` NO es tuyo** — ese lo diseña axon1, no
  lo toques ni lo esbozes.

Y `CLAUDE.md`, que lleva las reglas de código de este repo.

## Toolchain

`0.17.0-dev.1884+841dd0eb8`. El snapshot real está en
`~/.local/zig-master/zig-aarch64-macos-0.17.0-dev.1884+841dd0eb8/`. Su `lib/std/`
es tu fuente de verdad para cualquier duda de API — **léelo** en vez de asumir lo
que recuerdes de otra versión de Zig. std se ha movido mucho.

Trampas ya conocidas de esta versión (están en `groundTruth`, las repito porque
son las que más muerden al portar):

| No uses | Usa | Por qué |
|---|---|---|
| `std.heap.GeneralPurposeAllocator` | `std.heap.SafeAllocator` | **borrado** en 0.16.0 |
| `std.heap.DebugAllocator` | `std.heap.SafeAllocator` | alias deprecado |
| `std.ArrayListUnmanaged(T)` | `std.ArrayList(T)` con `.empty` | alias deprecado; el allocator va por llamada |
| `builtin.mode == .Debug` | `builtin.mode == .debug` | el enum se **renombró**; las mayúsculas sobreviven solo como decls deprecadas, y en `==` se exige campo real |
| `callconv(.C)` | `callconv(.c)` | minúscula |

## Tarea 1 — scaffold (`zkit/scaffold`)

Crea `build.zig`, `build.zig.zon` y `src/root.zig`.

- `build.zig.zon`: `.name = .zkit`, `.version = "0.0.0"`, `minimum_zig_version =
  "0.17.0-dev.1884+841dd0eb8"`, `.paths` con `build.zig`, `build.zig.zon`, `src`.
  Necesita `.fingerprint` — genera uno cualquiera y déjalo (Zig se queja y te
  dice el valor correcto la primera vez que compile; anótalo como pendiente en el
  report en vez de inventarte que es correcto).
- `build.zig`: expone un **módulo** `zkit` (que otros repos puedan importar) y un
  `test_step` que corra los tests de cada fichero. Mira
  `/Volumes/KODAK1TB/REPOS y PROYECTOS/zig-and-node-bun-related/hyperdiff/core/zig/build.zig`
  para ver cómo se declaran tests por fichero en esta versión de la build API
  (`b.createModule` + `.root_module`) — copia el patrón, no lo inventes.
- `src/root.zig`: barrel que re-exporta los módulos. Sin `usingnamespace` (está
  **removido** del lenguaje) — re-exporta cada nombre explícitamente.

## Tarea 2 — puerto de primitivas (`zkit/rescue`)

Origen: `/Volumes/KODAK1TB/REPOS y PROYECTOS/styx/` (**solo lectura**, no
escribas ahí ni por accidente).

| Copiar a `src/` | Origen | LOC |
|---|---|---|
| `subscriber_queue.zig` | `spikes/candidate-h/src/subscriber_queue.zig` | 485 |
| `reorder_buffer.zig` | `spikes/candidate-h/src/reorder_buffer.zig` | 825 |
| `watchdog.zig` | `spikes/candidate-h/src/watchdog.zig` | 235 |
| `tracking_allocator.zig` | `native/zig/media-daemon/tracking_allocator.zig` | 98 |

Los tres primeros importan **solo `std`** (verificado), así que portan sin limpiar
contexto. Los tests inline viajan dentro del fichero — no los toques.

Tests externos:
- **SÍ porta** `spikes/candidate-h/src/test_h_d2.zig` (440 l) → `src/test_reorder_buffer_bound.zig`.
  Importa solo `reorder_buffer` + `std`, y cubre el contrato duro (bound, stall,
  ventana máxima). Ajusta la ruta del import.
- **SÍ porta** `spikes/candidate-h/src/test_hung_worker_watchdog.zig` (171 l) →
  `src/test_watchdog.zig`. Importa solo `watchdog.zig` + `std`.
- **NO portes** `test_h_d1.zig` ni `test_h_f7.zig`: arrastran `delivery_pump.zig`
  y `delivery_profile.zig`, que son arquitectura del spike Candidate H, no
  primitivas. Portarlos metería en zkit código que no queremos.
- **NO portes** `handle.zig` ni `byte_domain.zig` de candidate-h. Ver Tarea 3 y
  `groundTruth/gt/handle-verdict`.

Al portar: quita las referencias a "Candidate H" y a los invariantes C-numerados
de los doc-comments — aquí no significan nada. **Conserva** lo que explique el
comportamiento real (el contrato de overflow, la semántica del bound). Si un
doc-comment describe una decisión del spike que aquí no aplica, bórralo; si
describe la estructura de datos, se queda.

## Tarea 3 — `handle` desde hyperdiff (`zkit/handle`)

Origen: `/Volumes/KODAK1TB/REPOS y PROYECTOS/zig-and-node-bun-related/hyperdiff/core/zig/src/handle_slab.zig` (242 l).

Cópialo a `src/handle.zig`. **Un cambio obligatorio**: `error.WatchQueueFull` →
`error.PoolFull`. Es un nombre de dominio filtrado dentro de un contenedor
genérico; aquí no hay ninguna "watch queue". Actualiza también el test que lo
espera (`expectError`).

Motivo de que salga de hyperdiff y no de styx: el `HandlePool` de candidate-h usa
`ArrayListUnmanaged.append` en su `free()` y **se traga el fallo con `catch {}`**
(fuga de slot en OOM), su handle es un struct que no cruza C-ABI, y su
`resolve_and_pin` no pinea nada. El de hyperdiff no aloja nada después de `init`
y su handle `u64` **es** la ABI.

## Tarea 4 — `log` (`zkit/log`)

Origen: `hyperdiff/core/zig/src/log.zig` (58 l) → `src/log.zig`. Léelo y pórtalo
quitando lo específico de hyperdiff (los scopes con nombre de sus módulos). Lo que
queremos aquí es el mecanismo de scoping, no su lista de scopes.

## Lo que NO haces

- **No compilas** (regla dura de arriba).
- **No tocas** `zkit/errors-mechanism` — es de axon1.
- **No escribes** en styx ni en hyperdiff. Son solo lectura.
- **No añades dependencias** en `build.zig.zon` hacia hyperdiff ni styx: zkit nace
  standalone (`lock/standalone`).
- **No inventes** primitivas nuevas ni "mejoras" que nadie pidió. Es un puerto.

## Report

Escribe `/tmp/zkit-forge-report.md` con:

```
scaffold:
  ficheros: [...]
  fingerprintPendiente: sí/no
  patronBuildCopiadoDe: (qué fichero miraste)
rescue:
  portados: [fichero origen → destino, LOC]
  testsInlineConservados: (cuántos por fichero)
  testsExternosPortados: [...]
  adaptaciones: [qué tuviste que cambiar respecto al original, y por qué]
handle:
  errorRenombrado: sí/no
  otrosCambios: [...]
log:
  quitado: [qué era específico de hyperdiff]
sinVerificar:
  - (TODO lo que no pudiste comprobar por no poder compilar — sé exhaustivo aquí,
     es lo más útil de tu report: dime exactamente qué habría que mirar primero
     cuando se pueda compilar)
dudas: [cualquier cosa donde tuviste que decidir sin datos]
```

Commitea en tu rama (`conventional commits`, **sin co-author, sin atribución
AI**), **sin push**, y **para**. No encadenes trabajo que no se te ha pedido.
