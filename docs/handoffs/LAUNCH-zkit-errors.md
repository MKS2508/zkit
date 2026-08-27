# LAUNCH — zkit-errors (el mecanismo de la taxonomía de códigos)

Eres la lane `zkit-errors`. Trabajas en un worktree de **zkit**. Tu footprint es
`src/errors.zig`, `src/root.zig` y `docs/design/**`.

## Lo primero, antes de escribir Zig

**Invoca `/zig-best-practices` y `/zig-0.17-migration`.** Enteras. Nos costó
horas re-derivar a mano cosas que ya estaban escritas ahí. No lo repitas.

Después lee, en este orden:
1. `zkit.model.yml` — la **autoridad** del programa. Sus `locks` no se re-abren y
   su `groundTruth` no se re-descubre: cada hecho de ahí costó tiempo.
2. `docs/design/errors.md` — tu diseño. **Se implementa, no se re-diseña.**
3. `CLAUDE.md` — reglas de código del repo.

Y `pwd` + `git rev-parse --show-toplevel`: confirma que estás en TU worktree.

## Toolchain

`0.17.0-dev.1884+841dd0eb8`, snapshot en `~/.local/zig-master/`. **El `zig` del
PATH puede ser otro** — `zig version` antes de creerte un error.

## Qué construyes, y qué NO

`lock/zkit-v0-mechanism`: zkit aporta el **mecanismo** — espacio de códigos
genérico, mapeo error-set↔código, emisión a TypeScript. **NO** una copia de los
42 códigos de hyperdiff.

El motivo importa y no es estético: **esos 42 códigos SON la ABI de paquetes
publicados en npm** (`@mks2508/hyperdiff-*`, que mission-control consume en
producción). Dos copias del mismo código divergen, y cuando divergen, divergen
en la ABI. Por eso los códigos concretos se quedan en hyperdiff hasta que exista
un parity gate. Si te tienta traerte los 42 "ya que estamos": no.

## La forma

```zig
pub const Space = zkit.errors.ErrorSpace(&.{
    .{ .name = "io", .base = 1000, .entries = &.{
        .{ .tag = "FILE_NOT_FOUND", .message = "File not found" },
    }},
});
```

Expone `Code`, `Error`, `codeOf`, `errorOf`, `messageOf`, `emitTypeScript()`.

## El guard es la razón de existir de todo esto

```zig
comptime {
    const emitted = Space.emitTypeScript();
    const on_disk = @embedFile("<ruta al .ts generado>");
    if (!std.mem.eql(u8, emitted, on_disk)) @compileError("desincronizado");
}
```

Sin el guard, esto es una abstracción para un solo consumidor y no se justifica.
Con él, el `.ts` **no puede** quedarse atrás del `.zig` sin romper el build. Eso
es lo que compras.

⚠️ **Verifica primero que el mecanismo es viable antes de construir encima.** La
pregunta concreta: ¿`comptimePrint` sobre un `inline for` produce algo
comptime-known y comparable con `@embedFile` mediante `std.mem.eql`? Escribe un
espécimen mínimo que lo demuestre **antes** de escribir el `ErrorSpace` completo.
Si no se sostiene, **para y repórtalo** — es un hallazgo valioso, no un fracaso,
y prefiero saberlo en 20 líneas que en 400.

Y el control positivo del guard hazlo con **un desajuste real**: cambia un
mensaje en el `.ts` y comprueba que el build **falla**. Un guard que nunca has
visto saltar no es un guard, es decoración.

## Reglas

- Error sets explícitos en la frontera pública.
- `std.testing.allocator` en todo test.
- `zig build` **y** `zig build test`, los dos. Son targets distintos: en este
  mismo programa hubo un `zig build` verde con seis errores en el de tests.

## Cierre

Commitea en tu rama `sib/zkit-errors`, conventional commits, sin co-author ni
atribución a IA. **No pushees.** Report en `/tmp/zkit-errors-report.md`:
`filesChanged`, `verifyPassed`, `verifyOutput` crudo, `introducedWorkarounds`,
`architecturalConcerns`, `stopReason`.
