# CLAUDE.md — zkit

## 🔴 2026-09-03 — hay un SEGUNDO ledger, y contradice a este

`zkit.model.yml` es la autoridad **de este programa**. Pero **`mesh/roadmap.spec.yml`**
(D-001..D-065, tocado hoy) es otra autoridad viva, y **ninguna de las dos sabe que la otra
existe**. Descubierto en una auditoría cross-repo.

El choque concreto está en el lock **`mapa-de-consumidores`** (`zkit.model.yml:166-205`,
2026-08-28), que declara dos movimientos estructurales:

- **"conduit pasa a FORMAR PARTE de styx"** (`:197`)
- **"consumer-bus se MIGRA dentro del nuevo spire"** (`:195`)

…mientras `mesh` planificaba **absorber el protocolo de chunks de conduit** (D-050/D-053).
Esa cláusula de mecanismo quedó **reabierta como D-065** y la lane `mesh-transfer` está
**GATED** precisamente por esto.

**Antes de ejecutar cualquier nodo de este modelo que toque conduit, spire o consumer-bus,
reconcilia los dos ficheros.**

### Lo que la auditoría confirma de este repo (buenas noticias)

`zkit` **es** el núcleo real: 2.360 LoC, 73 tests (21/21 steps verdes), cero dependencias,
guard de versión comptime que sí funciona. Lo que **no** existe es que alguien lo consuma:
las cinco aristas que `conduit/README` declara hacia zkit/quic-zig/libxev son **prosa** — sus
tres `build.zig.zon` tienen `.dependencies` vacío.

Y lo que `CLAUDE.md:72-75` de este repo ya decía sobre la duplicación de conduit **está
confirmado y es peor**: además del `HandleSlab` sin generación, `conduit/packages/sdk-zig/src/sdk.zig:131-136`
**no compila y nunca ha compilado** (`try` dentro de una fn que devuelve `@This()`). Sus
tests dan 4/4 PASS porque el análisis perezoso de Zig nunca toca ese cuerpo.

📍 **Mapa completo**:
`/Volumes/KODAK1TB/REPOS y PROYECTOS/nodejs-bun/mesh/docs/research/2026-09-03-mapa-cross-repo.md`

⚠️ **`styx` y `hyperdiff` NO se auditaron** — todo lo que el mapa dice de ellos viene del
`dossier-consumidores` de este repo, o sea testimonio de segunda mano.

## Lo primero

`zkit.model.yml` es la **autoridad** del programa. Léelo antes de tocar nada: lleva
los locks de waxin, los hechos ya verificados (sección `groundTruth` — no los
re-descubras) y el DAG de nodos con su `owner`.

## Toolchain

`0.17.0-dev.1893+78e3b1c73`. Es lo que hay en el PATH vía `zv`; volver atrás es
`zv use <version>`. (El `~/.local/zig-master/` que citaba este doc **ya no existe**
— si lo ves mencionado en algún sitio, está stale.)

`minimum_zig_version` del `.zon` **no para ningún build**: el build runner nunca lo
comprueba, y un manifest que declare `0.99.0` compila con cualquier toolchain. Lo
único que falla de verdad es un bloque comptime en `build.zig`:

```zig
comptime {
    const required = std.SemanticVersion.parse("0.17.0-dev.1893+78e3b1c73") catch unreachable;
    if (builtin.zig_version.order(required) == .lt) {
        @compileError("zkit requires Zig >= 0.17.0-dev.1893+78e3b1c73, found " ++
            builtin.zig_version_string);
    }
}
```

Ojo: `///` no vale sobre un bloque comptime, tiene que ser `//`. Verifícalo siempre
con control positivo — sube el requisito a `0.18.0`, comprueba que sale `EXIT=1` con
el `@compileError`, y restaura. Un guard que no has visto fallar no es un guard.

Caso real de por qué importa: `MKS2508/conduit` declara 1893 en su `.zon` y el repo
se construyó con **0.15.1**. Nada se quejó.

## Reglas de código

**Invoca `/zig-best-practices` antes de escribir Zig** — la skill entera, no este
resumen. Y las hermanas `zig-*` según toque (`zig-build-system` para `build.zig`,
`zig-cinterop` para la frontera C, `zig-debugging` para panics). Lo de abajo es un
recordatorio de lo que más se incumple al portar código desde otros repos, no un
sustituto de la skill.

- `std.heap.SafeAllocator`, no `GeneralPurposeAllocator` (borrado en 0.16.0) ni
  `DebugAllocator` (alias deprecado).
- `std.ArrayList` con `.empty` + allocator por llamada. `ArrayListUnmanaged` es
  alias deprecado.
- Error sets **explícitos** en la frontera pública; `!` inferido sólo dentro.
- `std.testing.allocator` en todo test — falla al leak con stack trace.
- Un `catch {}` que se traga un fallo de allocación es un bug, no un atajo.
  Ese fue exactamente el motivo de descartar el `HandlePool` de styx.

## Al portar código desde otro repo

Es un puerto, no un copy-paste:

1. Los tests inline viajan con el fichero. Si un test externo arrastra tipos del
   repo de origen, **no se porta** — se reescribe o se deja fuera, y se dice.
2. Los nombres de dominio no cruzan: `error.WatchQueueFull` en un contenedor
   genérico se convierte en `error.PoolFull`.
3. Si el original tiene un defecto conocido, se arregla **al portarlo** y se
   documenta en el commit. No se hereda por respeto al original.

## Consumidores — ESTO CAMBIÓ, no te fíes de docs viejos

Este doc decía "cero consumidores wireados, no añadas dependencias". **Ya no es
cierto** y era lo contrario de la realidad:

- **hyperdiff** depende de zkit en su `.zon` (URL+hash) y consume `HandleSlab` en
  3 slabs más `errors.ErrorSpace`. **En producción.**
- **styx** consume `HandleSlab`, `ErrorSpace` y `TrackingAllocator`.
- **conduit** reimplementó `HandleSlab` y `ReorderBuffer` en vez de consumirlos, con
  un `TODO(sub-import): cuando zkit/ipc/ exista` en su fuente — y su copia no tiene
  contador de generación, o sea use-after-free por construcción. Va a entrar dentro
  de styx, que ya linka los buenos.
- **mks-agentics** entra por lock de waxin. **spire** y **wraith-app** consumirían por
  C-ABI, no el módulo Zig.

El mapa completo con sus tres ejes está en `zkit.model.yml` → `lock/mapa-de-consumidores`,
y el catálogo de qué queda por extraer en `docs/catalogo-infra-extraible.md`.

**Prioridad**: waxin lockeó `el trabajo de hacer zkit pasa a ser prioridad CROSS REPO`
(2026-08-28). Los tres que moldean el diseño por dogfood son agentics, styx y hyperdiff.

## Commits

Conventional. Sin co-author, sin atribución AI.
