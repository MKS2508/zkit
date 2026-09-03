# zkit

Infraestructura Zig reutilizable cross-project: las piezas que varios repos
estaban escribiendo por separado, o que sólo existían en uno.

`Zig 0.17.0-dev.1893+78e3b1c73` · repo público (verificado en la API de GitHub el 2026-09-03) · **consumido en producción por hyperdiff y styx**

## Estado

**En uso.** `zkit/scaffold` y `zkit/rescue` están cerrados: el código está aquí y
`zig build test` pasa. `src/root.zig` exporta 8 símbolos y las primitivas suman
~1.800 líneas con tests inline.

De esos 8, **dos tienen dos consumidores reales** (`HandleSlab`, `errors.ErrorSpace`),
uno tiene uno (`TrackingAllocator`, el soak de styx) y cuatro tienen cero **a día de
hoy** — pero `SubscriberQueue`, `ReorderBuffer`+`SequenceNumber` y `HungWorkerWatchdog`
no están muertos: son el substrato de un bus pub/sub con snapshot+delta, y su
consumidor previsto (`consumer-bus`, que absorbe `spire`) existe y está publicado.

Mapa completo con sus tres ejes: `zkit.model.yml` → `lock/mapa-de-consumidores`.
Qué queda por extraer y a qué coste: `docs/catalogo-infra-extraible.md`.

## Qué va a contener, y de dónde sale

| Módulo | Origen | Por qué |
|---|---|---|
| `errors` | mecanismo nuevo, modelado sobre `hyperdiff/core/zig/src/errors.zig` | Hoy la ABI de errores se mantiene **a mano en 5 tablas paralelas** entre Zig y TS, con un doc-comment que promete "1:1" y nada que lo compruebe. zkit aporta el espacio de códigos genérico y **genera** el `.ts`. Es el análogo Zig de `@mks2508/no-throw`. |
| `log` | ⚠️ **cero consumidores.** La copia de hyperdiff se **borró** (2026-08-28) por eso mismo, y porque su `std_options` era inerte: sólo se lee del módulo RAÍZ de la compilación. Antes de wirearlo, comprobar que eso no se hereda | Logging scoped centralizado. styx tiene 44 `std.log.scoped` sueltos en 12 directorios y ningún módulo central. Análogo de `@mks2508/better-logger`. |
| `handle` | portado desde hyperdiff (su copia ya **no existe**: consume ésta) | Pool generacional con handle `u64` opaco que **es** la ABI. Gana al `HandlePool` de styx: free list fija sin alloc tras init, sin `catch {}` que fugue slots en OOM. |
| `subscriber_queue` | `styx/spikes/candidate-h` | Cola acotada por suscriptor, overflow contract-gated. `std`-only, 11 tests inline. |
| `reorder_buffer` | `styx/spikes/candidate-h` | Buffer de reordenado acotado con timeout. `std`-only, 15 tests inline. |
| `watchdog` | `styx/spikes/candidate-h` | Detector de worker colgado: timer con bound + status atómico. `std`-only. |
| `tracking_allocator` | `styx/native/zig/media-daemon` | Wrapper de `Allocator` con contador atómico de bytes vivos y leak-check. |

Las tres primitivas de `candidate-h` venían de un spike marcado para borrado por
la propia gobernanza de styx. Se rescatan antes del `git rm`, no después.

## Qué NO va a contener, y por qué

- **Una cola genérica que unifique las existentes.** `patch_ring` (MPSC bytes),
  `event_queue` (SPSC fijo) y `subscriber_queue` (acotada con política) son tres
  disciplinas de concurrencia distintas, no tres copias. Fusionarlas sería
  flexibilidad especulativa.
- **Los 49 códigos de error concretos de hyperdiff.** Son la ABI de paquetes
  publicados y en producción; dos copias divergirían. zkit aporta el mecanismo,
  hyperdiff lo instancia — con parity gate, y no en esta pasada.
- **Abstracción de procesos / PTY.** La auditoría cross-repo dio negativo: tanto
  `mks-agentics` como `mks-workspaces` delegan (tmux, Docker, SSH) sin dolor
  medido. Es un candidato que la evidencia refuta, no una tarea pendiente.

## SSOT

`zkit.model.yml` es la autoridad del programa cross-repo — cubre zkit,
hyperdiff, styx, quic-zig y libxev, porque la cadena de pinneo cruza fronteras y
la extracción toca tres repos en la misma pasada.

`hyperdiff/ROADMAP.md` y `styx/styx.model.yml` siguen mandando cada uno sobre su
propio repo. La evidencia (el porqué, lo descartado, las medidas) vive en los
`HANDOFF-*` de `~/dotfiles` — el modelo es estado, no narrativa.
