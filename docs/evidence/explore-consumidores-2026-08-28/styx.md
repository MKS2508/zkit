# Dossier: styx como consumidor de zkit

## 1. Qué es styx

**Propósito** (VERIFICADO, `README.md:1-9`): Federated Media Runtime — control plane en Bun/TypeScript (catálogo, identidad, playback), data plane en Zig (daemon multimedia, byte runtime, media graph, transmux), clientes nativos. Norte medible: superar a Jellyfin. Regla dura r01: los bytes de vídeo nunca atraviesan JS ni el bus NATS.

**Stack** (VERIFICADO, `CLAUDE.md:95-113`, `README.md:288-300`): Bun 1.4.0 + Elysia (5-layer) + Rolldown/tsc + tsgo + Oxlint + Vitest + Arktype + drizzle-orm + NATS JetStream + PostgreSQL + Valkey. Data plane: Zig `0.17.0-dev.1893+78e3b1c73`.

**Tamaño** (VERIFICADO, medido con `find`+`wc -l` hoy):

| Lenguaje | Líneas | Ficheros | Ámbito |
|---|---|---|---|
| Zig | 30.222 | 60 | `native/zig/` (excluye `.zig-cache`, `zig-out`, `zig-pkg` vendorizado) |
| TypeScript/TSX | 56.398 | 486 | `apps/` + `packages/` (excluye `node_modules`, `dist`) |

Zig es ~35% del volumen de código propio y concentra la parte "owned end-to-end" de bytes (daemon, cache, transport).

**Madurez** (VERIFICADO, `README.md:162-206`): fase **F0 — Media laboratory**, `in_progress`, exit gate `F0.F` `in_progress`. `native/zig` "compila, ~76 zig tests" según el README, pero medido hoy en `docs/track/byte-runtime/m5/evidence/m5-01-report-v2-2026-08-28.md:445` el conteo real en frío es **266/266** tests repartidos en 12 runners (media-core 180, cache 7, l1 12, metrics 8, l3 8, l2 7, tiered 21, zcb 5, bpw 4, pq 7, guard 4, signals 3) — el README no está actualizado a la cifra de hoy. Ningún cliente real existe todavía; CI nunca ha corrido (memoria citada en el mismo report, línea 283-284).

## 2. Consumo actual de zkit

**SÍ hay dependencia real y en producción**, no solo declarada — verificado en tres capas independientes:

**a) `.zon`** (VERIFICADO, `native/zig/build.zig.zon:7-10`):
```zig
.zkit = .{
    .url = "https://github.com/MKS2508/zkit/archive/09fd8cfc28c1f8065d35a395080f6f5ddbf090c3.tar.gz",
    .hash = "zkit-0.0.0-_fk2iHC5AQAWelE3FAeWXksnFCnVrHyltKBZaR265VKW",
},
```

**b) `build.zig`** (VERIFICADO, `native/zig/build.zig:64-65,201,220,240,333`): `zkit_dep`/`zkit_module` se declaran, pasan por `applyTsan` (instrumentación TSAN/valgrind uniforme) y se inyectan como módulo nombrado `zkit` en `root_module`, `test_module`, `cache_soak_module` y `tiered_cache_module`.

**c) `@import` en código de producción** (VERIFICADO):
- `native/zig/media-core/cache/tiered_cache.zig:19,46`: `const BufferSlab = zkit.HandleSlab(*ZeroCopyBuffer)` — es el pool real de buffers de la caché tiered (L1/L2/L3), no un test.
- `native/zig/media-daemon/main.zig:61-62` y `cache_soak.zig:41-42`: `const TrackingAllocator = zkit.TrackingAllocator`.

**Confirmado en `git log` (commits reales en `master`, no en rama sin mergear)**:
```
2c14285 refactor(daemon): borra la copia local de TrackingAllocator y consume la de zkit
29dd1a9 feat(cache): arista .zon a zkit + HandleSlab real + BackingStore load-bearing
```
Ambos del 2026-08-28 (hoy). Esto contradice lo que podría inferirse de un vistazo superficial ("styx solo declara zkit pero no lo usa") — el consumo es real, wired y verificado con tests + TSAN (`m5-01-report-v2-2026-08-28.md:24-30`: `zig build test:cache_tiered` exit 0, 21/21; lane TSAN exit 0, canarios YES).

**Módulos de zkit consumidos hoy**: `HandleSlab` (1 consumidor: `tiered_cache.zig`) y `TrackingAllocator` (1 consumidor: el soak de `media-daemon`). **Módulos exportados por zkit pero NO consumidos en styx**: `SubscriberQueue`, `ReorderBuffer`, `HungWorkerWatchdog`, `errors`, `log` — ver §3 y §5.

## 3. Duplicados

| Primitiva zkit | Duplicado en styx | Estado | Evidencia |
|---|---|---|---|
| `TrackingAllocator` | `media-daemon/tracking_allocator.zig` (98 líneas) | **CERRADO hoy** — fichero borrado, commit `2c14285` | `ls native/zig/media-daemon/tracking_allocator.zig` → no existe. Diff byte-a-byte confirmado idéntico salvo orden de builtins (`m6-01-report-ejecutor-2026-08-28.md:50-56`) |
| `HandleSlab`/`HandlePool` | `types.zig:213-222` citaba un `HandlePool(*ZeroCopyBuffer)` propio | **Nunca existió como código real** — era un comentario colgado que mentía; se corrigió en el mismo commit `29dd1a9` (`m5-01-report-v2-2026-08-28.md:145-149`) | `grep -rn HandlePool native/zig/media-core/` → 0 hits, control positivo con `TrackingAllocator` (5 hits) confirma que el grep funciona (`m5-01-report-v2-2026-08-28.md:290-294`) |
| `SubscriberQueue`/`ReorderBuffer`/`HungWorkerWatchdog` | Ninguno hoy — origen fue `styx/spikes/candidate-h`, ya borrado del repo | **Sin wirear**, gateado por gauntlet **H-F5** (M7 gatea el merge de M6, que aún no ha arrancado) | `spikes/candidate-h` no existe (`find spikes` → solo `README.md`, `ui-component-lab`); grep de `Watchdog`/`watchdog` en `media-core`+`media-daemon` → 0 hits (`m1-rearcheology-dossier-2026-08-27.md:124`) |
| `errors.ErrorSpace` | `local_file.zig:109`: `SourceErrorCode` propio | **No es duplicado real** — espejo deliberado de un enum TS (`@styx/source-sdk`), no reimplementación del mecanismo genérico de zkit. styx no instancia `zkit.errors` para su propia ABI todavía | `grep -n ErrorCode local_file.zig` → solo el comentario "mirrors SourceErrorCode" |
| `log` scoped centralizado | 29 usos de `std.log.scoped` en 12 directorios sin módulo central | **Sin dedup, sin plan activo** — zkit tiene `log.zig` con 0 consumidores propios (`zkit/README.md:28`) | `grep -rl std.log.scoped native/zig` (excl. vendor) → 29 hits en 12 dirs (observability, source, source/buffer, sync, tests, media-daemon, ipc, moqt, otel, session, session/producers, transport) |

**Criterio de calidad en el único caso donde hubo comparación directa** (`TrackingAllocator`): las dos copias eran funcionalmente idénticas (mismo bug conocido en `resize()` — under/overflow de `live_bytes` si el allocator interno redondea al alza en shrink — presente en ambas por igual, documentado en `m6-01-report-ejecutor-2026-08-28.md:76-83`). No hubo mejora de calidad al dedupear, solo eliminación de -95 líneas netas; el fix del bug queda pendiente **upstream en zkit** (dec-0103 §1), no en styx.

**Riesgo de duplicado FUTURO (INFERIDO, no materializado)**: `zkit.model.yml:186-193` (repo zkit, no styx) declara que cuando `conduit` se funda con styx, su propio `HandleSlab` — **sin contador de generación**, por tanto con use-after-free por construcción — aterrizará en un repo que ya linka el de zkit. Esto es un evento futuro planificado, no algo presente hoy en el árbol de styx.

## 4. Submódulos

**Corrección de premisa**: styx tiene **un único git submodule real**. `.gitmodules:1-3` declara solo:
```
[submodule "docs/references/quic-zig"]
	path = docs/references/quic-zig
	url = https://github.com/MKS2508/quic-zig.git
```
`git submodule status` confirma: `cf68ecc32a5d2f50b430e9b4f5f817c0cb5ff9e1 docs/references/quic-zig (heads/main)`, actualizado hoy (2026-08-28 04:47).

**libxev NO es submodule de styx** — es una dependencia Zig transitiva declarada dentro del `build.zig.zon` de `quic-zig` (`docs/references/quic-zig/build.zig.zon`), fetcheada al package cache local en `native/zig/zig-pkg/libxev-.../`. La formulación "quic-zig, libxev y demás submódulos" del brief es imprecisa en ese punto — libxev llega por el gestor de paquetes de Zig, no por `.gitmodules`.

**Pines de `minimum_zig_version` por manifiesto**:

| Manifest | `minimum_zig_version` | Comptime guard propio |
|---|---|---|
| `native/zig/build.zig.zon` (media_daemon) | `0.17.0-dev.1893+78e3b1c73` | **SÍ** — `build.zig:6-10` |
| `native/zig/media-core/build.zig.zon` | `0.17.0-dev.1893+78e3b1c73` | **SÍ** — `media-core/build.zig:6-8` |
| `native/zig/media-core/sync/build.zig.zon` | `0.17.0-dev.1893+78e3b1c73` | no revisado (submódulo pequeño, no chequeado) |
| `docs/references/quic-zig/build.zig.zon` (submodule) | `0.17.0-dev.1893+78e3b1c73` | **SÍ** — `quic-zig/build.zig:7-15`, `@compileError` explícito |
| `zkit` (vendorizado en `zig-pkg/`) | `0.17.0-dev.1893+78e3b1c73` | **NO** — `grep comptime` en su `build.zig` → 0 hits |
| `libxev` (fork, vendorizado en `zig-pkg/`) | `0.17.0-dev.1884+841dd0eb8` — **desalineado, más viejo** | **NO** — `grep comptime\|builtin` en su `build.zig` → 0 hits relevantes |

**Concuerdan entre sí**: 4 de 6 manifiestos pinean exactamente `1893+78e3b1c73` (media_daemon, media-core, media-core/sync, quic-zig). **libxev es el outlier** con `1884` — metadata desactualizada del fork, sin bumpear.

**Sobre el guard comptime**: el brief acierta en el mecanismo pero la respuesta es matizada, **no binaria**. styx **SÍ** tiene guard comptime real contra `builtin.zig_version` en los dos build.zig que controla directamente (`media-daemon` y `media-core`), y el submodule `quic-zig` **también** lo tiene, con el mismo patrón textual (`@compileError` citando `dec-0103`/comentario casi idéntico → convención deliberada replicada). Donde el guard **falta** es en las dos dependencias vendorizadas de terceros que styx NO controla desde su propio repo: **zkit** y **libxev** — ahí solo existe el `.zon` no-enforcing, exactamente el patrón que el brief describe como riesgo. Como zkit y libxev se compilan dentro del mismo proceso `zig build` de styx, el guard de nivel superior (`media-daemon/build.zig:6-10`) los protege indirectamente **mientras se construyan como parte del grafo de styx** — pero si alguien compila zkit o libxev de forma standalone (su propio `zig build test`), nada les impide correr con un toolchain viejo pese a lo que dice su `.zon`. Es un gap en esos dos repos, no en styx.

## 5. Qué necesitaría styx de zkit, y qué le sobra

**Ya tomado y en producción**: `HandleSlab` (cache tiered) y `TrackingAllocator` (soak). Consumo real, no aspiracional.

**Necesitaría, si H-F5 se cierra** (condiciones documentadas en `m1-rearcheology-dossier-2026-08-27.md:117-124`, todas `open` hoy): `SubscriberQueue` + `ReorderBuffer` + `HungWorkerWatchdog` para el delivery pump de M6 (fan-out/streaming), que **todavía no existe** en `media-core/` — nada que gatear hasta que M6 arranque. No es una necesidad inmediata, es una dependencia declarada para una fase futura.

**No necesitaría, y zkit lo sabe** (`zkit/README.md:38-49`): una cola genérica unificada que fusione `patch_ring`/`event_queue`/`subscriber_queue` — decisión ya tomada en zkit de NO construirla, con razón explícita de disciplinas de concurrencia distintas.

**Le sobra o es prematuro consumir hoy**: `zkit.log` (cero consumidores declarados en el propio zkit, `std_options` de dudosa herencia por módulo — el propio zkit avisa de comprobarlo antes de wirear) y `zkit.errors` para su propia ABI (styx mantiene su enum `SourceErrorCode` espejado desde TS, no lo ha migrado al mecanismo genérico — no hay evidencia de que lo necesite a corto plazo).

**Bloqueante real conocido, no de styx sino de zkit, que styx hereda**: `HandleSlab` es explícitamente no-thread-safe (`zkit/src/handle.zig:29`, "Callers must synchronize externally", 0 hits de `atomic`) — styx lo serializa correctamente bajo `TieredCache.mutex` (enumeración completa verificada en `m5-01-report-v2-2026-08-28.md:157-186`), pero es una responsabilidad que styx carga por el contrato de zkit, no una garantía que zkit le dé.

---

Read-only en todo momento, ningún fichero tocado, ningún commit. No toqué git en ningún repo.