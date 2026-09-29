# Propuesta de enmienda: conduit y spire pasan a Zig, y styx los consume

**Estado**: PROPUESTA. No toca `zkit.model.yml`. Sólo waxin (o axon con su OK) la aplica al
ledger.
**Origen**: gobernanza de la tanda 4 de styx (2026-09-29).
**Locks afectados**:
- `lock/conduit-motor-al-core`, cláusulas (1) y (4);
- `lock/mapa-de-consumidores`, nota "ENMENDADO 2026-09-03";
- `lock/spire-en-el-programa`, como extensión y no como choque.

---

## Qué decidió waxin el 2026-09-28

Son decisiones de waxin del 2026-09-28, tomadas en la sesión de orquestación de styx, que las
marca como LOCKED:

1. **conduit y spire se pasan a Zig y styx los consume.** La decisión está tomada y es locked.
   La crítica previa se usa como lista de requisitos, no como bloqueo.
2. **conduit = SDK Zig de upload real.** Tiene:
   - un codec único para cliente y servidor, con resume, chunks paralelos y SHA-256 en streaming;
   - `ReorderBuffer`/`HandleSlab` de zkit con generación;
   - la máquina de estados de upload dentro del SDK;
   - C-ABI para Swift y Bun FFI, más WASM para la web.

   conduit **conserva** la spec, los vectores de conformidad y el CLI. `@mks2508/chunk-engine`
   (TS) sigue compatible con el wire. El Zig muerto se borra. Los consumidores en styx son el
   `IngestSink` del daemon (servidor, mismo codec) y el CLI de styx (cliente).
3. **spire = SDK de mensajería unificado de styx (Zig + TS).** Los bindings se generan desde
   `@styx/api-contracts`. Tiene transportes enchufables: in-process, unix socket (control
   Bun↔daemon) y NATS JetStream. NATS se queda como broker. spire es también el punto único de
   seguridad de las comunicaciones (styx `dec-0119`, LOCKED). zkit aporta las primitivas de
   transporte: framing, `ReorderBuffer`, `WakeupPipe` y colas.
4. zkit absorbe **todo lo genérico** de `native/zig` de styx y la capa `zkit.safety` (styx
   `dec-0117`). Esto supersede, para zkit, la regla de "dos consumidores".

## Dónde choca con este ledger

| Lock | Texto vigente | Choque |
|---|---|---|
| `lock/conduit-motor-al-core` (1) | "¿portarlo a Zig? NO […] cero consumidores no-TS → no se porta; se reabre si aparece uno (wraith-app, Swift)" | El propio lock se reabre si aparece un consumidor no-TS, y ya ha aparecido: el `IngestSink` del daemon Zig de styx, y Swift después. El port a Zig pasa a ser la decisión. |
| `lock/conduit-motor-al-core` (4) | "styx NO es destino de conduit — es consumidor OPCIONAL […] hoy 0 hits y 0 ingest" | styx pasa a ser consumidor **obligado**: el wire de conduit es su protocolo de ingesta. conduit sigue siendo repo propio; styx consume su SDK y no absorbe su código. |
| `lock/mapa-de-consumidores` (nota 2026-09-03) | "conduit SIGUE como repo y styx NO es su destino (consumidor opcional)" | La mitad "sigue como repo" se mantiene. La mitad "consumidor opcional" cae, por la fila anterior. |
| `lock/spire-en-el-programa` | spire como paquetes TS publicables (core/db/host) que absorben las semánticas de consumer-bus | No choca, lo extiende: se añade el SDK Zig y el consumidor styx (IPC de control del daemon y NATS de los servicios). `spire/consume-zkit` gana un candidato real: las primitivas de transporte de zkit. |

Lo que **no** cambia:
- (2) conduit sigue como repo y como casa del CLI y del paquete TS.
- (3) el Zig muerto de conduit se borra. El port nace nuevo, detrás de la misma interfaz, como
  ya preveía el lock.
- La integridad sobre ciphertext y `seal(key)`.
- mesh y cloudreve-mirror siguen consumiendo el paquete TS.

## Texto propuesto para el ledger

Un lock nuevo, más una línea "ENMENDADO" en los dos locks afectados:

```yaml
  - id: lock/conduit-y-spire-a-zig-styx-consume
    date: '2026-09-28'
    origin: 'decisión de waxin en la sesión de orquestación de styx (tandas 3-4), registrada por la gobernanza de la tanda 4 el 2026-09-29'
    quote: >-
      waxin: "conduit y spire SE PASAN A ZIG Y STYX LOS CONSUME (decisión tomada)"; "spire =
      SDK de mensajería UNIFICADO de styx (Zig+TS, bindings generados desde
      @styx/api-contracts) con transportes enchufables"; "spire y conduit NO se dejan a medias".
    decision: >-
      (1) conduit gana un SDK Zig de upload (codec único cliente/servidor, resume, chunks
      paralelos, SHA-256 streaming, ReorderBuffer/HandleSlab de zkit, máquina de estados en el
      SDK, C-ABI Swift/Bun + WASM); conduit conserva spec + vectores + CLI y el paquete TS sigue
      compatible con el wire; el Zig muerto se borra igual (lock/conduit-motor-al-core (3)).
      (2) styx es consumidor obligado de conduit (IngestSink del daemon + CLI) y de spire (IPC
      de control Bun<->daemon + NATS de servicios), con consumidor real en production path y
      test (criterio load-bearing de waxin). (3) spire gana un SDK Zig además del TS, consume
      primitivas de transporte de zkit y es el punto único de seguridad de comunicaciones de
      styx (styx dec-0119).
      ENMIENDA lock/conduit-motor-al-core (1) y (4) y la nota 2026-09-03 de
      lock/mapa-de-consumidores; EXTIENDE lock/spire-en-el-programa.
```

En `lock/conduit-motor-al-core` y `lock/mapa-de-consumidores`, añadir:
`ENMENDADO 2026-09-28 por lock/conduit-y-spire-a-zig-styx-consume: styx es consumidor obligado
de conduit y el port a Zig se hace (el consumidor no-TS que pedía (1) es el daemon Zig de styx).`

Nodos que habría que dar de alta, o que styx ya lleva por su lado:
- `conduit/zig-sdk`, en el repo conduit;
- `spire/zig-sdk`, en el repo spire;
- en styx, los nodos `track/byte-runtime/ingest` y `track/spire` (`styx.model.yml`, tanda 4,
  ambos queued).

## Estado a 2026-09-29 (para no confundir decisión con hecho)

- Nada de esto está en código todavía. En la tanda 4 de styx sólo corrió la lane de zkit. Su
  trabajo está en `feat/styx-extraction` (14 commits sobre `a985961`, **sin push**) y en la rama
  `w4/zkit` de styx. Quedó sin resolver: los escépticos de la ronda 3 refutan la cobertura del
  guard `zig build audit:safety` de styx.
- Las lanes de spire y conduit no arrancaron: van encadenadas tras integrar zkit. Ni
  `MKS2508/spire` ni `MKS2508/conduit` tienen rama `feat/*`.
