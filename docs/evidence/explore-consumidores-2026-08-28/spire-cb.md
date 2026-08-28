# Informe: `spire` + `consumer-bus` — sustrato zkit y estado del wire

Exploración read-only completa de `/tmp/spire-check` y `/tmp/cb-check`, más los tres módulos de `zkit/src/`. Verificación explícita del hallazgo previo incluida. No se ha modificado, creado ni borrado ningún fichero, ni corrido `bun install`/`tsc` (sin `node_modules` en ninguno de los dos checkouts).

---

## 0. Verificación del hallazgo previo — CONFIRMADO, con matiz de fecha

El doc `~/dotfiles/HANDOFF-zkit-inception.md:89-90` dice literalmente:

```
89 | Reconnect | ... | especificado, no implementado aún (transport unix-socket es STUB) |
90 | Transports | InProcessTransport (real...) · UnixSocketTransport/startUnixSocketServer (STUB, err:'not_implemented') | ...
```

Hoy es **falso**: `src/transport/unix-socket.server.ts` (276 líneas) y `unix-socket.transport.ts` (309 líneas) son implementaciones reales — `Bun.listen`/`Bun.connect`, framing NDJSON completo, reconexión con backoff+jitter, heartbeat. `grep -rn "not_implemented"` sobre `src/` da **cero** hits en código de transporte; solo aparece en `errors.ts:28` (el código de error, ahora vestigial) y en un test que afirma explícitamente que YA NO es ese código (`consumer-bus.contract.test.ts:470`).

Matiz importante: el doc **no estaba equivocado cuando se escribió**. Trae su propia nota "ACTUALIZACIÓN 2026-08-28" diciendo que 0.1.1 estaba "pendiente de publish", y el propio `DESIGN.md` de consumer-bus (Provisional #1, `DESIGN.md:237-245`) documenta el stub como scope deliberado de esa iteración (0.0.1). El commit `3c2b3d2` ("chore: v0.1.1 — ship DESIGN.md in package (**zkit wire-format reference**)") es el que cerró la brecha — y es justo el commit que shipea el DESIGN.md que el propio repo etiqueta como referencia para el port de zkit. **La staleness no es solo del HANDOFF externo — vive dentro del propio repo** (ver §2.3 más abajo): quien lea `frames.ts` hoy sigue viendo "currently typed stubs" en la cabecera del fichero que se supone es la spec canónica del wire.

---

## 1. `spire`

**1. Qué es**: framework backend Bun-native (Elysia + Drizzle/Postgres + TypeBox), extraído de `cloudreve-mirror`. v0.1.0, "Pre-release, public API may evolve". Stack: Elysia + Eden Treaty (SDK tipado), Drizzle+postgres-js, OIDC vía Pocket-ID. 3569 LoC en `packages/`+`apps/`, **cero ficheros de test**. Runtime real hoy: HTTP + polling puro — `snapshots.ts` documenta explícitamente "Snapshot scan is driven by the **background polling loop**", nada de eventos. Es la pieza menos asentada de las dos: sin tests, con una visión de arquitectura (README) bastante por delante del código real.

**2. El wire**: spire NO habla ningún wire propio hoy. Su única superficie de bus es:
- `@spire/bus` (`packages/bus/src/index.ts`, 8 líneas) — re-export de valor puro de `ConsumerBusClient` desde `@mks2508/consumer-bus/client` (npm, `^0.1.1`, resuelve exacto a la versión que auditamos en `cb-check`).
- `@spire/sdk/bus` (`packages/sdk/src/bus/index.ts`) — re-export de **tipo** del mismo símbolo.

Ninguno de los dos está importado en ningún sitio de `apps/host` (grep confirmado) — `@spire/bus` es una dependencia declarada y sin usar.

**3. Solape con consumer-bus**: **ninguno funcional**. spire no tiene pub/sub propio que compita en diseño — solo un re-export sin uso y una visión documentada en el README ("`@spire/bus` grows into the canonical event plane... current consumer-bus functionality moves here under `@spire/bus/{host,client,transport}`"), que hoy no tiene ni una línea de código detrás. La "absorción" descrita es 100% aspiracional. El riesgo real no es de arquitectura sino de **tipos falsos** (ver punto 4).

**4. Hallazgo crítico — los tipos de consumer-bus en spire son fantasía, y están duplicados**:

Hay **dos** declaraciones ambient distintas para el mismo módulo `'@mks2508/consumer-bus/client'`, ambas en el mismo `tsconfig` (root `include: ["global.d.ts", "packages/**/src/**/*.ts", ...]`, y un `.d.ts` sí matchea el glob `*.ts`):

- `global.d.ts:5-18` (raíz del monorepo)
- `packages/sdk/src/types/consumer-bus.d.ts:6-12`

Ambas declaran `export class ConsumerBusClient` con **la misma forma inventada**, que no se parece en nada a la clase real:

| | Fantasía (spire) | Real (consumer-bus hoy) |
|---|---|---|
| constructor | `(url: string)` | `(transport: IBusTransport, schema: TSchema, identity, authToken?)` |
| `watch()` | `(topic: string, handler) => (unsubscribe fn)` — síncrono, callback | `async (topic, opts?) => Promise<Result<IBusSubscription, TConsumerBusError>>` — Result pattern + async iterator, subscribe-before-act |
| `close()` | `Promise<void>` | `Promise<Result<void, TConsumerBusError>>` |

Es literalmente el shape de un WebSocket-cliente genérico, no el protocolo snapshot+delta real. Sin `node_modules` instalado (no hay `dist/index.d.ts` real del paquete npm resolviéndose), nadie ha typecheckeado esto contra la librería de verdad — es exactamente el patrón "vibecoded types que nunca vieron el compilador".

Además, dos `declare module` ambient para el mismo specifier en el mismo programa **se mergean** (TS soporta merge de módulos ambient entre ficheros), pero dos `class ConsumerBusClient` con el mismo nombre en el scope mergeado **no se fusionan** — las clases no participan en declaration merging como las interfaces. Resultado esperado: `TS2300: Duplicate identifier 'ConsumerBusClient'` en cuanto alguien corra `tsc`. **No ejecutado** (repo sin `node_modules`, tarea read-only) — es un juicio de semántica TS, no un resultado empírico, pero de alta confianza.

Efecto práctico: el ambient module envenena el tipo de `'@mks2508/consumer-bus/client'` para **todo el programa**, incluido el re-export de valor real en `@spire/bus/src/index.ts:8` — cualquier consumidor de `@spire/bus` en spire ve la API falsa, no la real.

---

## 2. `consumer-bus` (`@mks2508/consumer-bus`)

**1. Qué es**: bus pub/sub local mono-máquina para consumers de un daemon (CLI/MCP/menubar/desktop/web). v0.1.1, público en npm. 2362 LoC en `src/` (sin tests) + 977 LoC de tests (62 casos en 4 ficheros) + `DESIGN.md` de 1609 líneas con invariantes I1-I9 documentadas, prior art verificado (Tailscale `WatchIPNBus`, Linear sync-id, Syncthing, Docker) y una sección "Provisional" que enumera honestamente cada corte de scope. Es sensiblemente más asentado que spire: choke-point de escritura reforzado a nivel de tipos (`ConsumerBusHost` es la única clase con `publish()`; `IConsumerBusReader` no tiene `publish` ni por accidente de tipos), subscribe-before-act con orden a-b-c-d probado, coalescing `boring` host-side, backpressure client-side con `droppedCount` explícito.

**2. El wire — real pero EN MOVIMIENTO, no congelado (esto contradice lo que documenta el propio repo)**:

NDJSON sobre unix-socket, un `TBusFrame` JSON por línea (`protocol/frames.ts`, 12 tipos de frame), versión exacta `CONSUMER_BUS_PROTOCOL_VERSION=1` sin ventana de compat. Pero al cruzar `unix-socket.server.ts` contra `unix-socket.transport.ts` y `consumer-bus-client.ts` encontré **tres bugs de protocolo reales** (encontrados por lectura cruzada, no ejecutados — pero verificados con grep exacto, no especulación):

**a) El heartbeat mata toda conexión socket a los ~45s.** El server arma un contador `missedCount` que solo se resetea cuando llega un frame `pong` (`unix-socket.server.ts:180-183`), y cierra la conexión al llegar a `missedPongThreshold` (default 3, `unix-socket.server.ts:220-231`). Pero **el server nunca construye ni envía un frame `ping`** — `grep -n "type: 'ping'" unix-socket.server.ts` da cero resultados. El cliente solo responde `pong` cuando *recibe* un `ping` (`unix-socket.transport.ts:189-193`), nunca lo inicia. Como el ping nunca sale, el pong nunca vuelve, `missedCount` sube 1 por tick de `heartbeat.intervalMs` (default 15s) sin condición, y a los 3 ticks (~45s) **toda conexión sana** se cierra con `heartbeat_timeout` → manda `bye` → el cliente cierra todas sus subscriptions como `host_shutdown`. Los 6 tests del socket (`unix-socket-transport-connect.test.ts`) solo cubren state-machine y lifecycle del listener — el propio header del fichero (líneas 4-7) admite que el flujo end-to-end real (connect→hello→subscribe→event) se verificó a mano contra un script en `/tmp` que ya no existe, nunca quedó como test.

**b) Doble `hello` con identidad fabricada.** `UnixSocketTransport.doConnect()` envía su propio `hello` en el callback `open` del socket, con identidad hardcodeada `{ consumerType: 'wraith' }` y un campo `transport: 'unix-socket'` que **no existe** en `IHelloFrame` (`unix-socket.transport.ts:114` — construido como objeto JSON literal, no tipado como `IHelloFrame`, así que TS no lo pesca). Ese hello resuelve la promesa de `transport.connect()`. Después, `ConsumerBusClient.doConnect()` llama `transport.connect()` y **además** manda un SEGUNDO `hello` propio con la identidad real (`consumer-bus-client.ts:149-156`). `InProcessTransport.connect()`, en cambio, no manda ningún hello — el único lo manda `ConsumerBusClient`. O sea: los dos transportes rompen la invariante que el propio `transport.contract.ts` (JSDoc, línea 3) declara ("Invariante I6: `ConsumerBusClient` behaves identically over any implementation") — el path socket quema un hello extra con identidad falsa que el path in-process nunca ve.

**c) `authToken` nunca llega al hook `authenticate`.** El hook de `startUnixSocketServer` se evalúa contra el PRIMER hello (`unix-socket.server.ts:195-203`), que es el que manda el transport sin `authToken` (no está en el objeto literal de la línea 114). El `authToken` real viaja en el SEGUNDO hello (el de `ConsumerBusClient`), que para entonces el server ya marcó `authenticated=true` y lo enruta directo al dispatcher (`unix-socket.server.ts:236-237`, rama "post-auth"), que ni siquiera invoca `authenticate` (`dispatcher.ts`, caso `'hello'`, solo chequea `protocolVersion`). Con cualquier `authenticate` real que exija token, la autenticación por socket es estructuralmente inalcanzable.

Esto cambia la respuesta de "¿está congelado o en movimiento?": el contrato documentado (un solo hello, ping iniciado por el host, auth sobre el hello real) **no es lo que el código hace hoy** — el path socket es funcional en un happy-path corto (por eso pasa los 6 tests de lifecycle) pero se autodestruye pasados ~45s y nunca autentica de verdad. El path in-process (26 tests de contrato, invariantes I1-I5 probadas) sí está asentado.

**3. Staleness dentro del propio repo** (relevante para tu punto 5): `protocol/frames.ts:6-8,12,29` sigue describiendo `UnixSocketTransport`/`startUnixSocketServer` como "**currently typed stubs**" y habla de "the future real unix-socket implementation" — en el mismo fichero que se supone es la spec canónica NDJSON del wire. Quien lea `frames.ts` hoy (incluido quien implemente el lado Zig) se lleva la misma información desactualizada que el HANDOFF externo.

**4. `wire-lock.json`/`verify:wire`**: no existe. `DESIGN.md` Provisional #5 lo documenta como corte deliberado ("shipping a hash file nothing checks es el patrón la_exageracion_compila"). Sigue sin existir en 0.1.1.

---

## 3. Síntesis

### 3.1 Solape spire↔consumer-bus: no hay conflicto de diseño — hay ausencia de integración

No es una fusión de dos sistemas que hacen lo mismo distinto — es spire con **cero** código de bus funcionando (solo un re-export sin usar + tipos falsos) frente a una librería consumer-bus madura y ya usada en producción por otro producto (wraithd — el propio `DESIGN.md`/README hablan del "mirror" en devenv/axon). La absorción es barata en el plano de diseño (no hay que reconciliar dos arquitecturas) pero antes de escribir código de integración real hay que:
1. Arreglar los dos `declare module` duplicados/fantasía en spire (borrar uno, y el que quede debe reflejar la API real — o mejor, arreglar la resolución de módulos para que TS lea el `.d.ts` real publicado por el paquete y no necesite ningún shim).
2. Asumir que el path socket de consumer-bus, tal cual está hoy, **no aguanta una conexión larga** (bug a) y **no autentica** (bug c) — cualquier plan de "spire habla con consumer-bus por socket" se rompe a los 45s si no se arregla primero.

### 3.2 Piezas de zkit — vía y coste

Los tres módulos (`SubscriberQueue(T)`, `ReorderBuffer(T)`+`SequenceNumber`, `HungWorkerWatchdog`) son estructuras de datos puras, sin I/O, sin dependencia de red — comptime genéricas, cero acoplamiento a ningún formato de wire. Zig pinneado a `0.17.0-dev.1893+78e3b1c73` (coincide con el master actual del resto de tu stack).

**Vía descartada: FFI directo desde los procesos TS de spire/consumer-bus.** Los elementos que viajarían por estas colas son objetos JS dinámicos (`IBusEnvelope<TTopic, TData>`, payload arbitrario validado por schema en runtime) — Zig necesita `[]T` de layout fijo. Cruzar FFI por cada `push`/`pop`/`drain` (es decir, por cada evento publicado) obligaría a serializar cada envelope a un buffer de bytes en cada llamada, con overhead de marshaling que casi seguro supera el coste de la operación pura en JS (manipulación de índices en un array, O(1)). El volumen de este bus (consumers CLI/MCP/menubar de un daemon personal) no está ni remotamente cerca del régimen de throughput que justificaría pagar ese cruce. **No recomendado.**

**Vía recomendada: portar las semánticas a TypeScript, no el código.** Son estructuras triviales (~40-80 líneas cada una) y ahora tienes el argumento perfecto para justificarlo con evidencia, no con gusto:
- `SubscriberQueue(T)` es **literalmente** la pieza host-side que el propio `DESIGN.md` (Provisional #4) marca como ausente: hoy el backpressure de consumer-bus solo está acotado client-side (`BusSubscription`, drop-oldest simple sin marcador de discontinuidad dedicado); el wire ya reserva `IOverflowFrame` (`frames.ts:125-130`) pero nada lo construye nunca. `SubscriberQueue` da exactamente la semántica que falta (cola acotada + marcador de discontinuidad explícito) para cuando se implemente backpressure real del lado host — que hace falta MÁS aún ahora que sabemos que la implementación hand-rolled actual del socket tiene bugs de protocolo (facilita el argumento: la pieza custom actual ya está rota en otro punto, no hay sunk cost real que defender).
- `HungWorkerWatchdog` — mapea 1:1 al heartbeat hand-rolled y roto de `unix-socket.server.ts` (contador `missedCount` + `setInterval`). Portarlo a TS de paso arregla el bug (a): un watchdog con `pet()`/`check()` explícito fuerza a decidir quién llama `pet()` y cuándo, en vez de un contador que sube solo porque nadie envía el `ping` que debería resetearlo.
- `ReorderBuffer(T)`+`SequenceNumber` — encaja peor aquí de forma directa: una conexión unix-socket es un stream ordenado (TCP-like), no hay reordering que resolver dentro de una sola conexión. Su semántica de "terminal = cancelar/resetear la request" encaja más con reordenar chunks de una transferencia troceada (huele a `conduit`, fuera de este scope) que con fan-out pub/sub. Candidato futuro razonable si algún día se implementa el ring-buffer de replay parcial que `DESIGN.md` §7 deja pendiente (hoy `fromCursor` siempre responde `gap:true`+snapshot fresco, nunca replay) — pero no es un fit v1.

**La palanca real de zkit no es FFI hacia TS — es un speaker Zig nativo del wire** (`zkit/ipc/`, ya nombrado en el README de spire como plan). Ahí SÍ tiene sentido usar los tres primitivos zkit tal cual, porque el consumidor sería un proceso Zig, no un cruce FFI por evento.

### 3.3 Qué debe congelarse ANTES de que zkit implemente nada del wire

1. **Arreglar los 3 bugs de protocolo del socket (§2.2 a/b/c)** antes de que nadie —Zig o no— trate el socket real como referencia. Portar un speaker Zig contra un comportamiento roto congela el bug, no el contrato.
2. **Actualizar `frames.ts` y `DESIGN.md`** para dejar de llamar "stub"/"future" a algo que ya es real — es el documento que el propio commit `3c2b3d2` etiqueta como "zkit wire-format reference".
3. **Handshake de facto vs spec**: decidir y fijar un único `hello` por conexión (hoy hay dos, uno con identidad falsa) antes de que un cliente Zig tenga que replicar cuál de los dos imitar.
4. **Política de heartbeat**: quién manda `ping` (hoy nadie), defaults reales de `intervalMs`/`missedPongThreshold` una vez que el ping exista de verdad.
5. **Semántica del hook `authenticate`**: qué token, contra qué hello, validado cómo — hoy es inalcanzable en la práctica.
6. **arktype → TypeBox** (ya anunciado en ambos READMEs, `@mks2508/consumer-bus@0.2.0` pendiente): los bytes NDJSON no cambian con este swap, pero si algún día un validador Zig necesita expresar los topic schemas de forma portable, TypeBox (JSON-Schema-compatible) es viable de portar y arktype no lo es. No bloquea el wire, pero sí bloquea cualquier validación de payload independiente en Zig.
7. **`wire-lock.json`/`verify:wire`**: opcional mientras solo exista una implementación (TS); se vuelve no-opcional en cuanto exista una segunda implementación (Zig) — es exactamente el escenario para el que ese guard existe.
8. Timeouts de request (`handshake_timeout`/`subscribe_timeout` — códigos definidos, nunca usados) y la convención de `socketPath` (`CONSUMER_BUS_SOCKET`, hoy resuelto por convención de producto, no por el paquete) — decidir antes de que un cliente en otro lenguaje tenga que adivinar cuánto esperar o dónde buscar el socket.

Rutas citadas, para referencia rápida:
- `/tmp/cb-check/src/transport/unix-socket.server.ts` (276L), `unix-socket.transport.ts` (309L)
- `/tmp/cb-check/src/client/consumer-bus-client.ts`, `src/host/dispatcher.ts`, `src/protocol/frames.ts`
- `/tmp/spire-check/global.d.ts`, `packages/sdk/src/types/consumer-bus.d.ts`, `packages/bus/src/index.ts`
- `/Volumes/KODAK1TB/REPOS y PROYECTOS/zig-and-node-bun-related/zkit/src/{subscriber_queue,reorder_buffer,watchdog}.zig`
- `~/dotfiles/HANDOFF-zkit-inception.md:89-90`