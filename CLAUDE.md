# CLAUDE.md — zkit

## Lo primero

`zkit.model.yml` es la **autoridad** del programa. Léelo antes de tocar nada: lleva
los locks de waxin, los hechos ya verificados (sección `groundTruth` — no los
re-descubras) y el DAG de nodos con su `owner`.

## Toolchain

`0.17.0-dev.1884+841dd0eb8`, snapshot en `~/.local/zig-master/`. El `zig` del PATH
puede ser otro — comprueba `zig version` antes de creerte un error de compilación.

`minimum_zig_version` **no se enforcea**: es metadata declarativa. Leer un `.zon`
no dice con qué compiler algo compila.

## Reglas de código

Sigue `~/.claude/skills/zig-best-practices` y las hermanas `zig-*`. Lo que más se
incumple en el código que llega aquí desde otros repos:

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

## Lo que este repo NO hace todavía

**Cero consumidores wireados** (lock de waxin). No añadas dependencias `.zon`
desde hyperdiff ni desde styx hacia aquí: el camino verde de esos repos no debe
depender de que zkit exista. El wiring llega después y con parity gate.

## Commits

Conventional. Sin co-author, sin atribución AI.
