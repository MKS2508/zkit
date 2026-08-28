# Catálogo: qué hay ya construido y desacoplado en hyperdiff (2026-08-28)

Para cuando waxin abra sesión en zkit. Esto **no** es una propuesta de mover nada — es el
menú, medido, para que la decisión se tome mirando el inventario y no la memoria.

## El método, y por qué corrige a la auditoría anterior

La auditoría de consumidores (`~/dotfiles/AUDIT-zkit-consumidores.md`) preguntaba *"¿quién
usa esto hoy?"* y respondía bien: 2 librerías, 1 mudanza, 4 archivo. Ese criterio sigue en
pie y no se re-litiga — mover código de un solo consumidor es una frontera de repo y un pin
a cambio de nada.

Pero con un **tercer repo consumidor** entrando, la pregunta útil cambia a *"¿qué hay ya
construido que un consumidor nativo nuevo podría usar mañana?"*. Y esa no la había medido
nadie.

Medida: para cada módulo, el conjunto **completo** de `@import` y si declara `extern struct`
con forma del dominio diff. Control corrido: `grep -nE '@import\("\.\.?/'` sobre los 9
módulos devuelve **cero** — no hay imports relativos que se me escapen.

## Tier 1 — se mueve tal cual, cero trabajo de desacoplado

Imports = sólo `std`, `builtin`, `sync`, `ipc`. Ningún `extern struct` del dominio.

| módulo | líneas | qué es | notas |
|---|---:|---|---|
| `watch/sync.zig` | 321 | pthread Mutex/Condition, relojes, fs | **gate Q4 abierto**, 2 consumidores verificados |
| `watch/ipc.zig` | 151 | `WakeupPipe` — fd que entra en un event loop externo | consumidor nuevo reportado por waxin |
| `watch/hot_ranker.zig` | 372 | ranking de ficheros calientes | |
| `watch/state/blob_cache.zig` | 273 | LRU con cap en bytes | su único extern es `CacheStats`, telemetría |
| `watch/patch_ring.zig` | 671 | anillo de **bytes** SPSC | `RecordHeader` es su propio formato de registro, no del diff. Eran 625 hasta `73e5432` (28-ago), que arregló el atasco con records mayores que el scratch del consumidor |
| `watch/platform_kqueue.zig` | 1125 | kqueue | |
| `watch/platform.zig` | 2289 | FSEvents + inotify + dispatch | sus 2 externs son ABI de Apple (`CFRunLoopSourceContext`, `FSEventStreamContext`), no dominio |

**Total: 5.202 líneas.**

## Tier 2 — genérico en estructura, payload con forma de dominio

Habría que parametrizar el tipo del elemento antes de moverlos.

| módulo | líneas | el payload acoplado |
|---|---:|---|
| `watch/event_queue.zig` | 542 | `CChange`, `CStatusBatch` |
| `watch/patch_queue.zig` | 295 | `CWatchPatchEvent`, `CWatchPatchBatch` |

**Total: 837 líneas.**

## El grafo de dependencias, que fija el orden

```
sync ──┬──> event_queue
       ├──> platform_kqueue
       └──> platform <── ipc

ipc, hot_ranker, blob_cache, patch_ring, patch_queue : hojas (sólo std/builtin)
```

`sync` e `ipc` son **hojas y se justifican solos** — ninguno depende de que el resto siga
aprobado. Ese es el orden topológico que ya estaba lockeado (`sync → ipc → platform`), y esta
medida lo confirma en el código en vez de por acuerdo.

## Lo que esto sí dice y lo que NO

**Sí dice**: hay ~6.000 líneas de infraestructura que **ya están desacopladas del dominio
diff**, y el 86% se mueve sin tocar una línea. La intuición de waxin ("veo muchísimo código")
está medida y es correcta.

**NO dice** que haya que moverlas. El criterio de consumidores sigue mandando: cada pieza
necesita su segundo consumidor real, no plausible. Lo que cambia con un tercer repo es que
ese segundo consumidor deja de ser hipotético para varias de ellas a la vez.

**NO dice** nada sobre `watching` (`platform*`, 3.414 líneas), que waxin ya aprobó subir por
**testabilidad**, no por consumidores. Que no se cite mal: sigue habiendo un consumidor.

## Lo que falta para decidir

Nombrar el proyecto tercero. Es lo único que bloquea `cand/ipc-wakeup` hoy, y es lo que
convierte media tabla de "1 consumidor" en "2".
