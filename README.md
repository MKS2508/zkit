# zkit

Infraestructura Zig reutilizable cross-project: las piezas que varios repos
estaban escribiendo por separado, o que sólo existían en uno.

`Zig 0.17.0-dev.1893+78e3b1c73` · repo público (verificado en la API de GitHub el 2026-09-03) · **consumido en producción por hyperdiff y styx**

## Estado

**En uso.** `src/root.zig` exporta las primitivas originales (rescate de
`styx/spikes/candidate-h` + hyperdiff), lo extraído de `styx/native/zig` en la
pasada `zkit/styx-extraction` (2026-09-29) y la capa `zkit.safety`
(styx dec-0117, parte 1 Zig).

Consumidores: hyperdiff (`HandleSlab`, `WakeupPipe`, `errors`) y styx
(`HandleSlab`, `TrackingAllocator`; el paso 2 de la extracción cablea el resto
y borra las copias de styx). Mapa con sus tres ejes: `zkit.model.yml` →
`lock/mapa-de-consumidores`. Qué queda por extraer: `docs/catalogo-infra-extraible.md`.

## Qué contiene, y de dónde sale

### SO sin runtime `Io` (hilos propios, FFI)

Desde 0.16 `std.Thread.Mutex`, `nanoTimestamp`, `sleep`, `getenv` y `std.fs`
viven detrás de `std.Io`; una librería con hilos propios no tiene uno.

| Módulo | Origen | Qué aporta |
|---|---|---|
| `time` | 4+ `fn nowNs` de styx, `quic.sys` | `monotonicNs`, `realtimeNs`, `sleepNs`, `Deadline`, `Stopwatch`; sin fallback silencioso a 0 |
| `sync` | `backpressure_waker.zig` de styx, `watch/sync.zig` de hyperdiff | `Mutex`/`Condition` por valor, `tryLock`, `timedWait`/`waitUntil` sobre reloj monotónico |
| `os` | `quic.sys` | `getenv`, `getenvInt` (ausente ≠ malformado), `randomBytes` criptográfico |
| `fs` | `quic.sys` (shim de ficheros de un fork de sockets) | `File` con `pread`/`pwrite`, `stat` con dev/ino, `O_CLOEXEC`, `readFileAlloc` acotado |
| `testing.Fixture` | `styx/native/zig/test_fixture.zig` | directorio temporal aislado por test |

### Estructuras

| Símbolo | Origen | Por qué |
|---|---|---|
| `HandleSlab` | hyperdiff (su copia ya no existe) | pool generacional, handle `u64` opaco = la ABI; `take` devuelve el valor |
| `ConcurrentHandleSlab` | nodo `zkit/handle-concurrent` (styx r44 #2) | slab compartible; `lock(h)` usa el valor sin carrera con `take` |
| `BoundedQueue` | `PendingDeliveryQueue` de styx (r44 #9) | cola acotada thread-safe: `reject`/`drop_oldest`, espera con `Condition`, drenado con reserva |
| `SubscriberQueue` | `styx/spikes/candidate-h` | cola por suscriptor single-thread con discontinuidad |
| `ReorderBuffer` / `SequenceNumber` | `styx/spikes/candidate-h` | reordenado acotado con timeout |
| `HungWorkerWatchdog` | `styx/spikes/candidate-h` | detector de worker colgado |
| `PriorityQueue` | `styx/media-core/scheduler` | top-N acotado + overflow FIFO (MoQ `lite/priority.rs`) |
| `LatestValue` | `TransportSignalsChannel` de styx | canal latest-wins con versión (valor y versión coherentes) |
| `AtomicHistogram` | `range_hist.zig` de styx | cubos comptime validados, `record` lock-free |
| `ZeroCopyBuffer` / `BufferGuard` | `styx/media-core/source/buffer` | buffer refcontado alineado a página para fanout sin copias |
| `CancelToken` | `container/bytes.zig` de styx | cancelación por petición encadenable |
| `TrackingAllocator` | `styx/native/zig/media-daemon` | contador atómico de bytes vivos |
| `WakeupPipe` | hyperdiff | despertar de un loop por pipe |
| `errors.ErrorSpace` / `ErrorSpaceWith` | mecanismo nuevo | espacio de códigos + TS generado; completo al compilar, nombres TS configurables |
| `log` | hyperdiff | ⚠️ cero consumidores (ver `zkit.model.yml`) |

### `zkit.safety` — seguridad por construcción

Cada pieza convierte una clase de bug en imposible o en fallo determinista:

| Pieza | Clase de bug |
|---|---|
| `Handle(Tag)` / `TypedSlab` | UAF por handle obsoleto (generación) y confusión de handles (tipo por `Tag`, error de compilación) |
| `Budget` / `BudgetAllocator` | memoria sin cota por sesión/usuario, leaks sin informe, contabilidad no independiente |
| `fs.Root` | path traversal, symlinks que escapan, TOCTOU (openat2 `RESOLVE_BENEATH` o recorrido `O_NOFOLLOW` fd a fd), FIFOs; entradas directas de la raíz (`deleteEntry`, `renameEntry`, `entries`, `syncDir`: un solo componente, el enlace nunca se sigue) para un servidor que gestiona su staging |
| `BoundedReader` / `BitReader` | lecturas fuera de límites, longitudes del wire sin validar, varints QUIC / VINT EBML / Exp-Golomb hostiles |
| `checked` | desbordes en offsets/longitudes (`checkRange` nunca calcula `offset + len`) |
| `Mutex` | unlock ajeno, autodeadlock, inversión de orden de locks (niveles) |
| `fuzz` | parsers que hacen pánico o fugan con entradas truncadas/corruptas |

Lo que la capa no puede imponer —que el consumidor no se la salte— lo imponen
los guards de build/CI del consumidor (dec-0117, doble capa).

## Build y tests

```sh
zig build test                       # 1 binario raíz + 4 suites + 6 compile-fail
zig build test -Dtsan=true           # lane ThreadSanitizer
zig build test -Dtsan=true -Dtsan-canary=true   # TIENE que fallar (carrera deliberada)
zig build test -Doptimize=ReleaseSafe
zig build test -Dtest-filter=<nombre>
zig build fuzz                       # corpus de los tests std.testing.fuzz
```

- `test/compile_errors/`: código que zkit debe rechazar al compilar
  (ErrorSpace incompleto, handles de tags distintos mezclados, …). El paso pasa
  sólo si la compilación falla con el mensaje esperado.
- `zig build fuzz --fuzz=N` (guiado por cobertura) falla hoy en
  0.17.0-dev.1893 con `corrupted coverage file … pcs_len was zero`, también
  con un test standalone sin zkit: bug del toolchain. Los barridos
  deterministas de `safety.fuzz` corren en `zig build test`.

## Qué NO va a contener, y por qué

- **Una cola genérica que unifique todas.** `patch_ring` (MPSC bytes),
  `event_queue` (SPSC fijo), `SubscriberQueue` (single-thread) y
  `BoundedQueue` (mutex + condición + reserva) son disciplinas distintas.
- **Los códigos de error concretos de nadie.** zkit aporta el mecanismo; cada
  consumidor instancia su espacio.
- **Dominio de styx**: la caché C7/C8, el scheduler de sesión, los contadores
  por pista, la política live/VOD, `Limits` de los demuxers, el verificador SCT.
  Se quedan en styx sobre estas primitivas.
- **Abstracción de procesos / PTY.** La auditoría cross-repo dio negativo.

## SSOT

`zkit.model.yml` es la autoridad del programa cross-repo — cubre zkit,
hyperdiff, styx, quic-zig y libxev, porque la cadena de pinneo cruza fronteras y
la extracción toca varios repos en la misma pasada.

`hyperdiff/ROADMAP.md` y `styx/styx.model.yml` siguen mandando cada uno sobre su
propio repo. La evidencia (el porqué, lo descartado, las medidas) vive en los
`HANDOFF-*` de `~/dotfiles` — el modelo es estado, no narrativa.
