# LAUNCH — ipc-wakeup-pipe (portar WakeupPipe desde hyperdiff)

Eres la lane `ipc-wakeup-pipe`. Trabajas en un worktree de **zkit**. Tu
footprint es `src/ipc.zig` (nuevo), `src/root.zig`, `build.zig`.

## Lo primero, antes de escribir Zig

**Invoca `/zig-best-practices` y `/zig-0.17-migration`.** Enteras.

Después lee, en este orden:
1. `zkit.model.yml` — nodo `cand/ipc-wakeup-pipe`. Su `dod` y sus locks/
   groundTruth no se re-descubren.
2. **`docs/handoffs/PLAN-ipc-wakeup-pipe-zkit.md` — tu plan. Ejecútalo tal
   cual, no lo re-diseñes.** Ya está verificado empíricamente (build real
   sobre copia de trabajo, no predicción): baseline `19/19` steps →
   `21/21` + `2/2` tests tras los 3 cambios. Sigue sus pasos en orden.
3. `CLAUDE.md` — reglas de código del repo.

Y `pwd` + `git rev-parse --show-toplevel`: confirma que estás en TU
worktree, no en el repo principal.

## Qué NO tocas

- **`hyperdiff` no se toca.** Es otro repo, otro dueño (axon1) — el borrado
  del original y el rewiring de su `build.zig` es un plan hermano, de otra
  lane. Tu trabajo es SOLO puerto + re-export en zkit.
- No wirees `conduit` — su repo no está clonado localmente, fuera de alcance.
- No es el port C-ABI del wire (eso es `cand/ipc-wakeup`, nodo distinto,
  sigue bloqueado en la §5). Esto es Zig puro, cero C-ABI.

## El check que de verdad importa (no el obvio)

`zig build` (plano, sin `test`) **no ejercita el re-export nuevo** —
`root.zig` con el import descartado no compila nada que lo referencie. El
plan trae el probe exacto que sí lo comprueba (un consumidor downstream que
hace `@import("zkit")` y llama `zkit.WakeupPipe.init()`). Ejecútalo tal
cual está en el plan, no te fíes de `zig build` solo.

## Reglas

- Puerto fiel: cero rediseño de API. El plan ya resolvió el único punto de
  juicio (genericizar el doc-comment que nombraba símbolos C-ABI de
  hyperdiff que no existen en zkit).
- `std.testing.allocator` en los tests portados.
- `zig build` **y** `zig build test`, los dos.

## Cierre

Commitea en tu rama `sib/ipc-wakeup-pipe`, conventional commits, sin
co-author ni atribución a IA. **No pushees.** Report en
`/tmp/ipc-wakeup-pipe-report.md`: `filesChanged`, `verifyPassed`,
`verifyOutput` crudo (incluye el `Build Summary: N/N` real, no memorizado),
`introducedWorkarounds`, `architecturalConcerns`, `stopReason`.
