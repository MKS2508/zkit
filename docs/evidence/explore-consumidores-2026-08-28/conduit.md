# conduit como consumidor de zkit — informe (read-only, verificado)

Nota de método: solo lectura de todo el repo, salvo `zig build test` en `packages/sdk-zig` para verificar compilación (ver §6 — genera `.zig-cache/` local, cero fuentes tocadas). Todos los puntos siguientes están verificados por mí de forma independiente contra el código fuente, y **después** contrastados con el `groundTruth` ya existente en `zkit.model.yml` (`gt/conduit-reimplemento-zkit-y-le-quito-la-seguridad`, líneas 968-996) — coinciden en todo salvo un dato de historial que no puedo re-verificar (marcado abajo).

## 1. Veredicto sobre el hallazgo previo — CONFIRMADO, con una precisión

| Afirmación | Veredicto | Evidencia file:line |
|---|---|---|
| Reimplementa HandleSlab en vez de consumir zkit | ✅ CONFIRMADO | `packages/sdk-zig/src/sdk.zig:12-39` |
| Reimplementa ReorderBuffer en vez de consumir zkit | ✅ CONFIRMADO | `packages/sdk-zig/src/sdk.zig:45-98` |
| `build.zig.zon` con `dependencies` vacío | ✅ CONFIRMADO (matiz) | `sdk-zig/build.zig.zon:13` y `bridge-zig/build.zig.zon:11` → `.dependencies = .{}`. **Matiz**: `apps/cli-zig/build.zig.zon:12-16` SÍ tiene dependencia, pero es un path-dep local a `sdk-zig`, no a zkit. Ningún `.zon` del repo referencia zkit — el único rastro es un comentario (`sdk-zig/build.zig.zon:12`). El hecho load-bearing (cero deps reales a zkit) se sostiene. |
| TODO en `sdk.zig:13` apuntando a zkit | ✅ CONFIRMADO exacto | `sdk.zig:13`: `// TODO(sub-import): cuando zkit/ipc/ exista, sub-importar @zkit/handlepool` |
| HandleSlab sin contador de generación → UAF por construcción | ✅ CONFIRMADO y con test que lo fija como "correcto" | Ver §3 |

## 2. Qué es conduit

"Upload Protocol with Zig SDK Stack" — protocolo de subida chunked (Content-Range custom, servidor NO resumable, resume solo client-side) con: una SDK Zig embebible, un bridge FFI servidor (`.so`) pensado para hablar con el host "spire" vía consumer-bus/NDJSON (cuando exista `zkit/ipc/`), y 3 clientes: CLI Zig standalone, CLI Bun (vía `Bun.dlopen`), mini-app web (drag-drop + SSE, servido con `Bun.serve`).

- **Repo**: 1 solo commit (`522117f feat: initial scaffold`), 1 autor. Todo el README lo declara `STUB` en su propia status matrix.
- **Tamaño**: ~431 líneas Zig (7 ficheros) + ~225 líneas TS (3 ficheros). Proporción ≈ 66% Zig / 34% TS, pero es un scaffold — no hay lógica real en ningún lado: el CLI Zig solo imprime strings, el bridge son 3 funciones no-op, la mini-app es un `Bun.serve` con un HTML-string y un progreso simulado con `Math.random()`.
- **Madurez**: cero end-to-end. `bun.lock` no tiene NINGUNA entrada para `@conduit/*`, `@sinclair/typebox` ni `@mks2508/consumer-bus` (declaradas en `apps/cli-bun/package.json` pero nunca instaladas) — `bun install` no se ha corrido nunca sobre los paquetes reales del workspace.

## 3. Inventario de `packages/sdk-zig` + comparación pieza a pieza

| Símbolo | Líneas conduit | ¿Equivalente en zkit? | Comparación |
|---|---|---|---|
| `HandleSlab` | `sdk.zig:12-39` (28 líneas) | Sí — `handle.zig` (269 líneas c/tests, 111 de implementación) | **zkit gana, no es cercano.** Conduit: `next: u64` monótono + free-list, **sin campo de valor `T`** (solo recicla IDs, no guarda payload) y **sin generación**. zkit: handle `u64` = `(gen:u16)<<48 \| slot`, salta gen 0 para reservar el NULL sentinel, bump de generación en `alloc()` Y en `free()` (doble bump → invalidación inmediata), 65535 reusos de ABA-window, 9 tests incluyendo un stress de 200k ciclos que fija por test que el handle nunca colisiona con 0. |
| `ReorderBuffer` | `sdk.zig:45-98` (54 líneas) | Sí — `reorder_buffer.zig` (823 líneas c/tests, ~244 de implementación) | **zkit gana, no es cercano.** Conduit: `ArrayList` que **crece sin cota** (`resize(allocator, index+1)` — si `index` viene del cliente/red, es vector de agotamiento de memoria), duplicado en un índice ya ocupado se **descarta en silencio** (no hay `error.Duplicate`), sin timeout de gaps, sin `reset()`, sin semántica terminal. zkit: `bound` fijo en `init`, errores explícitos (`Stale`/`OutOfWindow`/`Duplicate`/`Resetting`), `gapTimeout()` con semántica terminal documentada explícitamente como "NUNCA espera infinitamente, NO es un stall vector" — justo la garantía que a conduit le falta (su comentario de test dice literalmente "head does NOT auto-reset between calls"). |
| `StreamingSha256` | `sdk.zig:104-120` | No hay en zkit (fuera de su scope — primitiva de dominio, no de infra genérica) | Correcta, delgada, sin bugs. Verificado: test golden-vector pasa (`Sha256.hash` vs streaming). |
| `OidcClient` | `sdk.zig:126-148` | No aplica a zkit | **Bug latente de compilación**, ver §3.1 |
| `ResumeMachine` | `sdk.zig:162-171` | No aplica a zkit (FSM de dominio del protocolo de upload) | Trivial: `transition()` no valida legalidad de transición (p.ej. `completed → uploading` se acepta sin más). No hay candidato en zkit para esto — es correcto que viva en conduit. |

### 3.1 Hallazgo adicional no pedido pero relevante: `OidcClient.init` no compila si se llega a usar

`sdk.zig:131-137` usa `try allocator.dupe(...)` dentro de una función que devuelve `@This()` (no un error-union). Hoy pasa `zig build test` porque Zig analiza cuerpos de función de forma perezosa y `OidcClient.init`/`fetchToken` no están referenciados en ningún sitio (ni tests ni apps). Confirmado con control positivo: reproduje el mismo patrón aislado en un fichero de scratchpad — falla en silencio si nadie lo llama, y en cuanto se añade una sola llamada (`_ = Foo.init(...)`) el compilador revienta con `error: expected type 'Foo', found 'error{OutOfMemory}'`. Es deuda invisible: el día que alguien cablee OIDC de verdad, esto no compila.

### 3.2 Segundo defecto de HandleSlab, más grave que la falta de generación: fuga de slots en OOM

`sdk.zig:33`: `self.released.append(self.allocator, h) catch {};` — si el `append` falla por OOM, el error se traga y el slot se pierde para siempre (fuga silenciosa, no un crash). Esto es exactamente el defecto que la propia documentación de zkit (`README.md`/`CLAUDE.md`) cita como el motivo por el que se **descartó** el `HandlePool` de styx al diseñar zkit: *"sin `catch {}` que fugue slots en OOM"*. Conduit reproduce los dos defectos descalificantes a la vez (sin generación + fuga en OOM). También hay `catch unreachable` en las inicializaciones (`sdk.zig:21`, `sdk.zig:57`) — menos grave (aborta en vez de fugar), pero mismo patrón de no propagar el error.

### 3.3 El test de conduit fija el UAF como comportamiento "correcto"

`tests/sdk_test.zig:72-83`, test `"HandleSlab acquire and release"`, asserta explícitamente `h3 == h1` (el handle reciclado es **igual** al liberado). Es el espejo invertido del test de zkit `"HandleSlab: generation prevents ABA"` (`handle.zig:176-192`), que asserta `h1 != h2` tras el mismo ciclo. No es un descuido de un caso no cubierto — el test suite de conduit **codifica la vulnerabilidad como spec**.

## 4. Toolchain

- Los 4 `build.zig.zon` de conduit (root sdk-zig, bridge-zig, apps/cli-zig — cli-bun/mini-app no son Zig) declaran `minimum_zig_version = "0.17.0-dev.1893+78e3b1c73"` — coincide exactamente con el toolchain que zkit usa y con el que tengo instalado localmente (`zig version` → `0.17.0-dev.1893+78e3b1c73`).
- **Verificado por mí, negativo por grep**: `grep -rn "zig_version\|builtin" --include="*.zig"` sobre todo el repo → **cero resultados**. No hay ningún bloque `comptime` que compare `builtin.zig_version` contra el mínimo declarado, en ningún `build.zig` de conduit (a diferencia de `zkit/build.zig:8-16`, que sí lo tiene).
- **Verificado por mí**: con el toolchain 1893 instalado, `zig build test` en `sdk-zig` compila y pasa limpio (3/3 steps, 3 tests OK).
- **No verificado por mí, atribuido a `zkit.model.yml` groundTruth** (no tengo forma de reconstruir el estado histórico desde un clon fresco): el groundTruth de zkit afirma que este mismo repo conduit "se construyó con 0.15.1" pese a declarar 1893, sin que nada se quejara — sería la demostración en vivo de por qué el guard comptime importa (`minimum_zig_version` es puramente advisory, el build runner nunca lo comprueba). Lo que yo sí puedo afirmar de primera mano: el guard no existe hoy en ningún `build.zig` de conduit, así que nada impediría que eso vuelva a pasar.

## 5. Qué haría falta para que conduit consuma zkit

El lock de waxin en `zkit.model.yml:185-193` ya fija el camino: **conduit pasa a formar parte de styx**, que ya linka el zkit bueno — la absorción es "el momento natural de matar la copia", no una migración standalone de conduit. Con eso como marco, la mecánica concreta si se hiciera la migración:

1. **Wiring de dependencia**: añadir zkit a `sdk-zig/build.zig.zon` (path-dep mientras zkit es privado, URL+hash cuando se publique — así lo hace hyperdiff hoy) y en `build.zig` pasar el módulo `zkit` como import del `sdk_module`. Borra el comentario-placeholder de `build.zig.zon:12`.
2. **HandleSlab**: `HandleSlab(T)` de zkit exige un tipo de valor por slot — conduit hoy no guarda ningún payload (`acquire()`/`release()` son solo IDs). Migrar fuerza a decidir *qué* vive detrás de cada handle (probablemente el estado de sesión de upload), lo cual conduit todavía no ha diseñado. El test `sdk_test.zig:72-83` se invierte: `h3 == h1` → `h3 != h1`.
3. **ReorderBuffer**: `ReorderBuffer(T)` de zkit exige un `bound` en `init()` — conduit hoy no tiene noción de ventana máxima. Definirlo es forzoso y es justo lo que cierra el vector de agotamiento de memoria de `sdk.zig:65`. El manejo de duplicados pasa de silencio a `error.Duplicate` — los call sites que dependan del silencio (hoy ninguno, no hay call sites reales) tendrían que manejarlo.
4. **Coste real de romper algo**: es prácticamente cero. Conduit es un scaffold de un commit sin código productor consumiendo `HandleSlab`/`ReorderBuffer` fuera de sus propios tests — es el momento más barato posible para swap-in, exactamente el punto que hace la "regla de la apología" innecesaria aquí: no hay nada que justificar, se sustituye y punto.
5. **Recomendación independiente del punto anterior**: añadir el guard `comptime` contra `builtin.zig_version` en los 3 `build.zig` de conduit (sdk-zig, bridge-zig, cli-zig) ya, sin esperar a la absorción en styx — es barato y el propio estado de este repo (manifest 1893 sin guard) es la prueba viva de que el manifest no protege nada.
6. **bridge-zig → zkit/ipc**: bloqueado aguas arriba — `zkit/ipc` (puente NDJSON) todavía no existe (`docs/integration.md:36-45`, `bridge.zig:3-5,21,25`). No es una tarea de conduit, es una dependencia de roadmap de zkit.

Ficheros clave citados: `/tmp/conduit-check/packages/sdk-zig/src/sdk.zig`, `/tmp/conduit-check/packages/sdk-zig/src/root.zig`, `/tmp/conduit-check/packages/sdk-zig/build.zig.zon`, `/tmp/conduit-check/packages/sdk-zig/tests/sdk_test.zig`, `/tmp/conduit-check/packages/bridge-zig/src/bridge.zig`, `/tmp/conduit-check/apps/cli-zig/build.zig.zon`; contraste en `/Volumes/KODAK1TB/REPOS y PROYECTOS/zig-and-node-bun-related/zkit/src/handle.zig`, `.../src/reorder_buffer.zig`, `.../build.zig`, `.../zkit.model.yml:968-996`.