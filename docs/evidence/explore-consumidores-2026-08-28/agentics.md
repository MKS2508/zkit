# mks-agentics como consumer de zkit — informe

Read-only, sin tocar nada. Repo: `/Volumes/KODAK1TB/REPOS y PROYECTOS/nodejs-bun/mks-agentics`.

## 1. Qué es mks-agentics

**Propósito** (README es *stale* — habla de `agent-backend`/`agent-ui`/`agent-tui`, estructura que ya no existe; la real sale de `package.json` workspaces): sistema de ejecución/orquestación de agentes de coding AI — backend de control plane, brokers, runners, CLI/TUI, menubar macOS. `agentics.model.yml` lo confirma: 5 outcomes activos — `gateway-control-plane` (live en prod, OIDC), `agent-orchestration` (A2A three-plane, ADR-0018), `big-connection` (superficie unificada cross-repo con MC/workspaces), `second-brain-jarvis` (TTS+memoria), y el nuevo `spire-adoption` (queued).

**Stack**: 100% Bun/TypeScript. `bun.lock`, workspaces `core/packages/*` + `apps/*`, Elysia (rutas broker), arktype (validación WS), SQLite (better-sqlite3 vía `wraith-broker-sqlite`), `@mks2508/no-throw` + `@mks2508/better-logger` (mismo ecosistema Result/logger que hyperdiff).

**Packages principales** (27 en `core/packages/`, 10 apps): `wraith-broker` (Elysia, WS, heartbeat GC), `wraith-broker-core`/`-sqlite` (persistencia, fan-out), `wraith-sdk` (cliente, paridad CLI≡MCP≡SDK), `runner-protocol`/`gateway-protocol` (contratos), `wraithd` (daemon runner, lanza procesos `claude`), `build-runner`, `jarvis-*` (memoria/TTS/narración), `session-transcript`, `task-sync`. Único componente no-TS: `apps/wraith-linux/src-tauri` (Rust/Tauri, shell desktop Linux — no relacionado con zkit).

**Madurez**: 4054 ficheros trackeados, 1302 `.ts` + 205 `.tsx`, 218 ficheros `*.test.ts`, 801 `.md` de docs/handoffs (alto churn documental, sesiones diarias). MVP en vuelo activamente: roadmap muestra `mvp-wraith-binary-3facades⚠ (partial)` con 3 gates abiertos (`mvp-wraith-mcp-roundtrip`, `mvp-orchestration-dogfood`, más uno). No es un proyecto maduro/estable — es un monorepo grande en construcción con mucha deuda de coordinación (docs stale detectados en el propio README, bugs off-by-one ya cazados y corregidos en producción, ver §4).

## 2. Relación con zkit

**Hoy: cero dependencia.** Verificado: `git ls-files` no devuelve ningún `.zig`/`.zon`; no hay `bun:ffi` en código real (solo mencionado en un README de una dependencia externa, `ff-labs/fff-bun`, ajena a zkit). Es TS puro de punta a punta.

`zkit.model.yml` (autoridad cross-repo, lock `mapa-de-consumidores`, 2026-08-28) ya fija esto explícitamente en su **EJE 2 (cómo se consume)**:
> «Por C-ABI / FFI: los TypeScript (spire, agentics) y Swift (wraith-app).»

Y en el **EJE 3 (estado de la relación)**:
> «lockeado por waxin, aún sin cablear: mks-agentics.»

O sea: la vía de consumo ya está decidida (FFI, no linkado directo como hyperdiff/styx que son Zig nativo) pero **no implementada ni empezada**. No existe todavía ni el módulo `zkit/ipc` (spec-only, confirmado en el ADR — root.zig re-exporta solo 7 módulos, ninguno IPC) ni un binding TS del lado agentics.

**Qué le aportaría de verdad** (con matiz — ver más abajo): no reuso de código hoy, sino la posibilidad futura de sustituir ≥4 reimplementaciones TS hand-rolled del mismo concepto por una única primitiva Zig probada, una vez exista el puente FFI. Detalle en §4.

## 3. El patrón spire — marco de 3 scopes (tal cual el ADR, `docs/jarvis/spire-pattern-direction-2026-08-28.md`)

Dirección lockeada por waxin (2026-08-28): mks-agentics se muda al patrón `spire` (wire-protocol-as-contract, extraído de `cloudreve-mirror`). El ADR es explícito en que "migrar a spire" son **tres scopes que no deben mezclarse**:

| Scope | Coste | Lectura del ADR |
|---|---|---|
| **Wire/bus** — usar `@spire/bus` (re-exporta `@mks2508/consumer-bus`) | ~0 (agentics ya usa consumer-bus) | incremental, alineado, "hazlo cuando toque" |
| **zkit/ipc** — Zig hablando el bus | futuro (zkit recién nacido, ipc *planned*, no existe) | **"no-ahora"** |
| **Framework** — `@spire/db`/`@spire/host`/`@spire/sdk` en agentics | rewrite (se moldea por dogfood) | "el molde ES el trabajo; secuenciar deliberado, no mid-MVP a lo loco" |

**Sobre zkit/ipc en concreto**, el ADR (hallazgo B, agente de research) es tajante: *«zkit/ipc no es código: no hay módulo `ipc` en zkit»*. Conflaciona dos cosas distintas: (1) migración del wakeup-pipe de hyperdiff (diseñado, 151 LOC en prod, no es el wire), y (2) el port C-ABI del wire de consumer-bus — descrito como *«la decisión más vieja sin abrir del programa»*, con una `AskUserQuestion §5` (Swift-native NDJSON vs `zkit/ipc` C-ABI) que **nunca se hizo**. Además el wire está versionado (`PROTOCOL_VERSION=1`) pero **no congelado**: cero parity gate, cero codegen (`verify:wire` no existe), y su propio `DESIGN.md` ya está stale vs el código real. Conclusión del ADR: portarlo a Zig a mano hoy driftearía en silencio.

Una corrección posterior (axon1, primary source de zkit) templa el "vapor": las primitivas de zkit no están muertas, son **huérfanas de consumidor** (1805 líneas reales con tests: `ReorderBuffer` 822, `SubscriberQueue` 481, `HandleSlab` 269, `HungWorkerWatchdog` 233) — lo que falta es exactamente el módulo `ipc` que las ensambla + el port C-ABI, no las piezas en sí.

## 4. Piezas candidatas — dónde agentics ya hace a mano lo que zkit ofrece como primitiva

Encontré **4 focos concretos de reimplementación manual**, todos en TS, ninguno linkado a zkit:

**a) Watchdog de worker/proceso colgado → equivalente a `HungWorkerWatchdog`.** Hay al menos 3 implementaciones independientes del mismo concepto, con ventanas de timeout distintas y sin compartir código:
- `apps/wraith-broker/src/services/broker.service.ts:88-112` — DOS `setInterval` de 60s: uno GC de "operator wraiths muertos" (SEC-5, con comentario explícito de que reemplaza un signal(0) probing por PID), otro GC de heartbeat de runners con stale-window de 120s = "4x el heartbeat interval de 30s" (comentado a mano, sin primitiva).
- `apps/wraith-broker/src/routes/runners.routes.ts:47,72` — check inline duplicado `alive: Date.now() - r.lastHeartbeat < 30000` (magic number repetido, no reusa la constante del broker.service).
- `apps/build-runner/src/transport/control-ws.ts:34-160` — heartbeat cliente-lado con `HEARTBEAT_MS=30_000` / `HEARTBEAT_ACK_TIMEOUT_MS=35_000`, timer de ack-timeout que fuerza reconexión.

Tres políticas de timeout distintas (120s, 30s, 35s) para la misma idea conceptual — exactamente el tipo de "N copias divergentes sin un mecanismo común" que zkit ataca en su README para el caso de errores.

**b) Cola por-suscriptor con backpressure real → hueco frente a `SubscriberQueue`.** `core/packages/wraith-broker-sqlite/src/broker/wraith-session-stream.ts` documenta "Backpressure-safe: slow subscribers don't block the emitter" pero la implementación real (líneas 102-134) es solo `try/catch` alrededor de una llamada síncrona a cada suscriptor — **no hay cola acotada ni política de overflow**, solo "si el callback lanza, lo logueo y sigo". Es backpressure de nombre, no de hecho. `apps/wraithd/src/sinks/session-stream-emitter.ts:68` lo reconoce explícitamente en un comentario: *"Heuristics (F1 — coarse; refined in F4 when bounded queues + coalescing land)"* — o sea, colas acotadas por suscriptor ya están en el roadmap interno de agentics, independiente de zkit, como trabajo futuro (F4).

**c) Reordenado / cursor de secuencia → paralelo a `ReorderBuffer`+`SequenceNumber`.** Tanto `wraith-session-stream.ts` (seq por wraithId, `getHistory` con `fromCursor`) como `apps/wraith-broker/src/services/broker-events.service.ts` (contador `nextSeq`, `list({since})`) reimplementan contadores monotónicos + paginación por cursor a mano. El propio código documenta que esto ya causó un bug real: comentario en `wraith-session-stream.ts:170-174` sobre un off-by-one en `nextCursor` (`lastSeq + 1` saltaba un frame) ya cazado y corregido en producción — justo la clase de bug que una primitiva con tests dedicados (`ReorderBuffer`, 822 líneas, 15 tests inline) existe para prevenir.

**d) Handle generacional → paralelo simplificado de `HandleSlab`.** `apps/wraithd/src/services/cli-launcher.ts:701-708`, campo `_generation: number` en `IRunnerSessionInfo`: *"incremented each time a new process is registered under this sessionId. The exit handler only acts if its session's generation still matches — otherwise the process has been replaced [...] Guards against the stale-exit-handler bug in resume."* Es la misma idea de fondo que `HandleSlab` (generación para invalidar referencias viejas), pero como contador suelto en un campo, no un pool con free-list — funciona para este caso puntual, pero es el mismo patrón de "cada sitio reinventa su propio guard de generación" que el lock de zkit señala para conduit (que además sí introdujo un bug real: `HandleSlab` duplicado en conduit **sin** contador de generación → use-after-free por construcción).

**Duplicación literal ya confesada en código**: `apps/wraith-broker/src/services/broker-events.service.ts:9-10` — *"Copied verbatim from `apps/gateway-server/src/services/broker-events.service.ts`. Both apps need identical logic; shared workspace package is deferred to F3+."* Esto no es zkit todavía, pero es la MISMA enfermedad (copia manual duplicada por falta de módulo compartido) que el lock de zkit usa como argumento forzante contra dejar HandleSlab duplicado en conduit.

**Matiz importante**: todo esto es paralelismo *conceptual*, no señal de que "falte zkit hoy". Son problemas resueltos en TS single-threaded (donde no hace falta atomics ni lock-free), del tamaño adecuado a su escala actual. El valor real de zkit aparece solo **si/cuando** exista el puente FFI — hoy no hay ninguno, así que consumir zkit no es "añadir un import", es construir primero el módulo `ipc` + el binding TS que el propio ADR dice que no existe.

## 5. Riesgos — el caveat del ADR

El ADR trae un caveat explícito de secuenciación (no lo interpreto yo, es cita):

> «**Caveat de fiabilidad (no blocker, sí sequencing)**: moldear un framework compartido entre 3 consumers mientras agentics está mid-MVP (wraith-binary-3facades en vuelo, objetivo máximo pendiente) es trabajo real. El wire/bus es seguro e incremental; la adopción del framework se hace deliberada, sin derailar el MVP. El molde se paga en dogfood — asumido por waxin.»

Precisión de scope: este caveat aplica al **scope 3 (framework spire)**, no al scope 2 (`zkit/ipc`) — que el propio ADR ya marca como "no-ahora" por estar zkit recién nacido. Es decir, el riesgo de derailar el MVP de agentics es específicamente sobre adoptar `@spire/db`/`host`/`sdk` (que además el hallazgo A del ADR describe como 4/5 paquetes media-shaped/Postgres-hardcoded/vibecoded en 2 commits, 0 tests, `bun run typecheck` roto en clean clone) — no sobre zkit.

Riesgos adicionales que verifiqué en el propio ADR y que son relevantes si alguien quisiera acelerar el scope 2 antes de tiempo:
- **Decisión arquitectural abierta sin dueño**: la `AskUserQuestion §5` (Swift-native NDJSON vs `zkit/ipc` C-ABI) nunca se hizo — cablear agentics a zkit hoy sería construir sobre una bifurcación no resuelta.
- **Wire sin freeze**: sin `verify:wire`/parity gate/codegen, portar el wire a Zig ahora mismo driftearía en silencio (literal del ADR).
- **Roadmap de agentics ya lo sabe y lo secuencia**: `outcome/spire-adoption` está `○ queued` en `agentics.model.yml`, sin deps declaradas pero detrás de `mvp-wraith-binary-3facades` (aún `⚠ partial`) en la práctica — coherente con el caveat.

Nota al margen (no verificada de primera mano, la cito porque aparece en el propio `zkit.model.yml:1020,1993` como evidencia ya devuelta): ya existe un `~/dotfiles/COORD-agentics-a-axon1-zkit-recibido.md` de una sesión previa de mks-agentics coordinando con axon1 sobre zkit, y un "segundo gate... devuelto por la sesión de mks-agentics y aceptado" sobre el freeze del wire — si esto es relevante para tu interview de mañana, merece la pena que lo lea quien lleve esa lane, no lo he abierto (fuera de los dos repos que se me pidió explorar).
