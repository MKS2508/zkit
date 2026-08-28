# Dossier de consumidores de zkit — explore profundo (2026-08-28)

Seis agentes read-only, uno por repo, con la instrucción de citar `fichero:línea` para cada
afirmación y distinguir VERIFICADO de INFERIDO. Esto es la síntesis; lo que sigue cambia
el mapa que teníamos.

**El hecho que reordena todo lo demás**: `grep -rn "export fn\|callconv(.C)"` sobre
`zkit/src/` da **cero**. zkit no tiene frontera C-ABI: sólo se puede consumir como
**módulo Zig linkado**. Todos los consumidores que no son Zig (spire, agentics,
wraith-app, el bridge de conduit) están bloqueados por eso — y no por `ipc`, sino por la
frontera misma. `ipc` es el contenido; el C-ABI es la puerta.

---

## 1. Consumidores REALES hoy — dos, los dos en producción

| repo | qué consume | dónde | vía |
|---|---|---|---|
| **hyperdiff** | `HandleSlab` ×3 · `errors.ErrorSpace` (38 códigos) | `src/exports.zig:50,153-157` (slab de cachés FFI) · `src/watch/exports.zig:40,47,354` (WatchSlab, SessionSlab) · `src/errors.zig:27,57` | módulo Zig linkado, `build.zig.zon:8-11` |
| **styx** | `HandleSlab` · `TrackingAllocator` | `media-core/cache/tiered_cache.zig:19,46` (pool de buffers de la caché tiered, no un test) · `media-daemon/main.zig:61-62` | módulo Zig linkado, `native/zig/build.zig.zon:7-10` |

styx lo wireó **hoy**: `29dd1a9` (arista `.zon` + `HandleSlab` real) y `2c14285` (borra su
copia local de `TrackingAllocator` y consume la de zkit, −95 líneas netas). Verificado con
tests + TSAN en verde.

Los dos pinean el mismo tarball (`09fd8cfc…`). O sea que **la copia de zkit que consumen
es anterior al guard comptime que le puse** (`86a36ef`): sus `zig-pkg/` vendorizados no lo
tienen. No es un problema mientras compilen dentro del grafo de styx/hyperdiff (el guard
de nivel superior los cubre), pero sí lo es si alguien compila zkit standalone.

## 2. Consumidores declarados y NO cableados — cuatro, cada uno bloqueado por algo distinto

| repo | lenguaje | qué le bloquea | coste de arrancar |
|---|---|---|---|
| **conduit** | Zig | nada técnico: es scaffold de 1 commit | ~0 — ver §3 |
| **spire** | TS | falta C-ABI en zkit; y FFI por evento es la forma equivocada (§4) | alto, y probablemente no se debe pagar |
| **consumer-bus** | TS | ídem, más 3 bugs de protocolo propios (§5) | ídem |
| **wraith-app** | Swift | falta C-ABI; **y su lado está en blanco** | 0 de retrabajo, 100 % por escribir |
| **agentics** | TS | ídem spire; su ADR lo marca "no-ahora" y con razón | detrás de su MVP |
| **cloudreve-mirror** | TS | **no es candidato** — ver §6 | — |

## 3. conduit — la copia insegura, ahora con dos defectos y un test que la bendice

Confirmado todo lo que teníamos, y peor:

- `sdk.zig:12-39` reimplementa `HandleSlab`; `sdk.zig:45-98` reimplementa `ReorderBuffer`.
- `sdk.zig:13`: `// TODO(sub-import): cuando zkit/ipc/ exista, sub-importar @zkit/handlepool`.
- **Sin contador de generación** → un handle liberado se reutiliza con el mismo valor.
- **Segundo defecto, nuevo**: `sdk.zig:33` hace
  `self.released.append(self.allocator, h) catch {};` — si el append falla por OOM el slot
  **se fuga en silencio**. Es exactamente el defecto por el que descartamos el
  `HandlePool` de styx al diseñar zkit. conduit reproduce **los dos a la vez**.
- **Y su test lo fija como spec**: `tests/sdk_test.zig:72-83` assertea `h3 == h1` — el
  espejo invertido del test de zkit (`handle.zig:176-192`, `h1 != h2`). No es un caso sin
  cubrir: la vulnerabilidad está codificada como comportamiento esperado.
- Su `ReorderBuffer` crece **sin cota** (`resize(allocator, index+1)`): si el índice viene
  de la red, es un vector de agotamiento de memoria. Y descarta duplicados en silencio.
- Bonus no pedido: `sdk.zig:131-137` (`OidcClient.init`) **no compila si alguien lo llama**
  — usa `try` en una función que no devuelve error-union, y hoy cuela porque Zig analiza
  cuerpos de forma perezosa y nadie lo referencia.
- Los 4 `.zon` declaran `1893` y **ningún `build.zig` tiene guard comptime**.

**Coste de migrarlo: prácticamente cero** — no hay ningún productor real consumiendo esas
piezas fuera de sus propios tests. Es el momento más barato posible, y el lock ya dice que
conduit se funde en styx, que ya linka el bueno.

## 4. La vía para los consumidores TS — FFI por evento está descartada

El agente lo argumenta y lo comparto: lo que viajaría por esas colas son objetos JS
dinámicos con payload validado en runtime; Zig necesita `[]T` de layout fijo. Cruzar la
frontera FFI **en cada `push`/`pop`** obliga a serializar cada envelope, y el marshaling
cuesta más que la operación pura en JS (índices en un array, O(1)). El volumen de ese bus
—consumers CLI/MCP/menubar de un daemon personal— no está cerca del régimen que lo
justificaría.

**La palanca real no es FFI hacia TS: es un hablante Zig nativo del wire.** Ahí sí se usan
las tres primitivas tal cual, porque el consumidor es un proceso Zig.

Y para el lado TS, lo que tiene sentido es **portar las semánticas, no el código**:
- `SubscriberQueue` es literalmente la pieza que el `DESIGN.md` de consumer-bus marca como
  ausente (hoy el backpressure sólo está acotado client-side; el wire ya reserva
  `IOverflowFrame` en `frames.ts:125-130` y **nada lo construye nunca**).
- `HungWorkerWatchdog` mapea 1:1 al heartbeat hand-rolled **y roto** del server (§5a).

## 5. 🔴 El wire NO se puede congelar todavía — tres bugs de protocolo

Encontrados leyendo `unix-socket.server.ts` contra `unix-socket.transport.ts` y
`consumer-bus-client.ts`:

**a) El heartbeat mata toda conexión sana a los ~45 s.** El server cuenta `missedCount`,
que sólo se resetea al recibir un `pong` (`:180-183`), y cierra a las 3 fallas
(`:220-231`). Pero **el server nunca envía un `ping`**: `grep "type: 'ping'"` da cero. El
cliente sólo responde `pong` cuando recibe uno. Así que el contador sube 1 por tick (15 s)
sin condición y a los 3 ticks cierra con `heartbeat_timeout` → `bye` → el cliente cierra
todas sus subscriptions como `host_shutdown`.

**b) Doble `hello`, uno con identidad fabricada.** `UnixSocketTransport.doConnect()` manda
su propio hello con `{ consumerType: 'wraith' }` hardcodeado y un campo `transport` que no
existe en `IHelloFrame` (`:114`, objeto literal sin tipar). Después `ConsumerBusClient`
manda un **segundo** hello con la identidad real. El transporte in-process no manda
ninguno. Rompe la invariante I6 que el propio `transport.contract.ts` declara.

**c) `authToken` nunca llega al hook `authenticate`.** El hook se evalúa contra el PRIMER
hello, que no lleva token; el segundo llega cuando el server ya marcó `authenticated=true`
y lo enruta al dispatcher, que no invoca `authenticate`. **La auth por socket es
estructuralmente inalcanzable.**

**Consecuencia operativa**: portar un hablante Zig contra este comportamiento **congela el
bug, no el contrato**. El freeze del wire deja de ser "una decisión pendiente" y pasa a ser
"arreglar tres bugs y *luego* decidir".

Y hay staleness dentro del propio repo: `protocol/frames.ts:6-8,12,29` — el fichero que se
supone es la spec canónica — sigue llamando "currently typed stubs" a implementaciones que
ya son reales (276 + 309 líneas).

**En spire, además**: dos `declare module` ambient duplicados para
`@mks2508/consumer-bus/client` (`global.d.ts:5-18` y
`packages/sdk/src/types/consumer-bus.d.ts:6-12`), los dos con una **API inventada** que no
se parece a la clase real (constructor `(url)` vs `(transport, schema, identity, token)`;
`watch()` síncrono con callback vs async con Result). Envenena el tipo para todo el
programa, incluido el re-export real de `@spire/bus`.

## 6. wraith-app y cloudreve-mirror

**wraith-app**: 5 ficheros Swift, **3905 bytes**, 3 commits el 21-ago y parado desde
entonces. **Cero IPC, cero NDJSON, cero socket** — pizarra en blanco. Para el desempate del
§5 del inception (Swift implementa NDJSON por su cuenta vs zkit lo hace una vez por C-ABI)
eso significa que **el coste de retrabajo de elegir B es cero**. Lo que sigue sin aparecer
es el consumer Linux nativo que el propio doc fija como desempate: no hay repo ni commit.

**cloudreve-mirror**: **no es un mirror de Cloudreve** (`isFork:false`, cero código
vendorizado). Es un puente bidireccional Cloudreve↔Jellyfin, en producción en Helsinki vía
Coolify. Consume `@mks2508/consumer-bus` a través del re-export de `@spire/bus`, en **TS
puro sin FFI**. **No es el consumer Linux que desempata el §5** — dominio distinto.

## 7. Deuda de zkit que sale del explore (es mía, no de los consumidores)

1. **`TrackingAllocator.resize()` tiene under/overflow de `live_bytes`** si el allocator
   interno redondea al alza en un shrink. Estaba en las dos copias (styx y zkit) por igual;
   styx dedupeó hacia zkit, así que **el bug ahora vive sólo aquí** y es upstream.
2. **`HandleSlab` no es thread-safe** y está documentado (`handle.zig:29`), pero es una
   responsabilidad que el consumidor carga. styx lo serializa bajo `TieredCache.mutex`.
3. **`zkit.log.scoped` es un downgrade** frente a lo que hacen los consumidores. El
   `std.log.scoped` nativo de Zig es filtrable por scope en runtime/comptime vía
   `std_options.log_scope_levels`; el de zkit es sólo un prefijo de string sobre el scope
   por defecto — pierde esa granularidad. zkit tiene **0 consumidores de su propio `log`**,
   y hyperdiff/styx usan el nativo. Candidato a borrar, no a promocionar.
4. **Corrección al catálogo**: `patch_ring.zig` es **671 líneas**, no 625 — el fix del
   atasco (`73e5432`, hoy) añadió 48. El resto de la tabla del catálogo se verificó campo a
   campo y es exacta, incluida la distinción entre externs de dominio (`event_queue`,
   `patch_queue`) y de no-dominio (`blob_cache`, `patch_ring`, `platform`).
5. **`event_queue` no es genérico**: su `RingBuffer` está declarado como `buffer: []CChange`
   (`event_queue.zig:182`), y `CChange` es **ABI pública hacia TS** — el bloqueo para
   subirlo no es interno, es un contrato cruzando el límite Zig↔TS.

## 8. Lo que yo haría con esto mañana

1. **Decidir la frontera C-ABI de zkit antes que `ipc`.** Sin ella, cuatro de los seis
   consumidores no pueden ni empezar, y `ipc` no cambia eso.
2. **Absorber conduit ya** — es gratis hoy y cada día que pasa es más caro. Y de paso,
   guard comptime en sus tres `build.zig`.
3. **No congelar el wire**: arreglar los tres bugs primero. Un freeze sobre (a)+(b)+(c)
   congela el fallo.
4. **Arreglar el bug de `TrackingAllocator`** — ya es sólo nuestro.
5. **Reasignar los `cand/*` del SSOT**, que siguen con `owner: axon unificado` por herencia
   de un reparto viejo.

---

Informes completos de los seis agentes en `docs/evidence/explore-consumidores-2026-08-28/`.
