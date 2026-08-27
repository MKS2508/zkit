# LAUNCH — zkit-errors ronda 3 (el anidado SÍ compila: aquí está)

Tu r2 concluyó, textualmente:

> **Domain nesting is not achievable in 0.17-dev.1884 with the current approach.**
> The core blocker: `@field(domains, fname)` inside `inline for` over `field_names`
> produces a runtime-resolved pointer, not a comptime-known value.

**Es falso, y lo he compilado.** No te lo discuto de memoria: aquí tienes el
programa entero, corriendo contra tu mismo compilador (0.17-dev.1884+841dd0eb8).

## El esqueleto que funciona

```zig
const Entry  = struct { tag: []const u8, msg: []const u8 };
const Domain = struct { base: u16, entries: []const Entry };

const cfg = .{
    .io  = Domain{ .base = 1000, .entries = &.{
        .{ .tag = "NotFound", .msg = "not found" },
        .{ .tag = "Denied",   .msg = "denied" },
    } },
    .net = Domain{ .base = 2000, .entries = &.{
        .{ .tag = "Timeout",  .msg = "timeout" },
    } },
};

const Code = struct { name: []const u8, code: u16 };

fn buildCodes(comptime c: anytype) []const Code {
    comptime {
        var out: []const Code = &.{};
        const names = @typeInfo(@TypeOf(c)).@"struct".field_names;
        for (names) |fname| {
            const dom = @field(c, fname);
            for (dom.entries, 0..) |e, i| {
                out = out ++ &[_]Code{.{
                    .name = fname ++ "." ++ e.tag,
                    .code = dom.base + @as(u16, @intCast(i)),
                }};
            }
        }
        return out;
    }
}
```

Salida real:

```
io.NotFound = 1000
io.Denied   = 1001
net.Timeout = 2000
```

## Por qué a ti te salía runtime y aquí no

**`comptime c: anytype`.** Ese es todo el truco. Si el config entra como
parámetro runtime, `@field(c, fname)` es un valor runtime y `dom.entries[i]`
revienta con *"tuple field index must be comptime-known"* — que es exactamente el
error que reportaste. Con el parámetro marcado `comptime`, el `@field` resuelve en
comptime y el indexado es legal.

No necesitas `inline for`: dentro de un bloque `comptime {}` un `for` normal ya es
comptime (tu propio hallazgo #5 de r2 lo dice, y ahí tenías razón).

Y no necesitas `std.meta.FieldEnum` ni `@intToEnum` para nada. Aparte: `@intToEnum`
no "se eliminó en 1884" — se renombró a **`@enumFromInt` en 0.11**. Si tu primer
reflejo fue buscarlo, tu memoria de Zig es de la era 0.10; **desconfía de ella y
compila antes de declarar algo imposible.**

## La garantía, demostrada

Esto es lo que pedía r2 y lo que el diseño plano perdió. Compilado también:

```zig
fn assertDisjoint(comptime c: anytype) void {
    comptime {
        const names = @typeInfo(@TypeOf(c)).@"struct".field_names;
        for (names, 0..) |na, ia| {
            const da = @field(c, na);
            const enda = da.base + da.entries.len;
            for (names, 0..) |nb, ib| {
                if (ia >= ib) continue;
                const db = @field(c, nb);
                const endb = db.base + db.entries.len;
                if (da.base < endb and db.base < enda) {
                    @compileError("error-space: dominios '" ++ na ++ "' y '" ++ nb ++ "' solapan rango");
                }
            }
        }
    }
}
```

Con `.net` movido a `base = 1001` el compilador escupe:

```
probe_overlap.zig:51:21: error: error-space: dominios 'io' y 'net' solapan rango
```

Eso es **demostrado**, no afirmado: un rango solapado no compila. La unicidad sale
por construcción, no por disciplina del llamante.

## Tu trabajo

Es mecánico. Portar `src/errors/space.zig` del `Entry[]` plano a esta forma:

1. Config anidada por dominios, cada uno con `base` + `entries`.
2. `buildCodes` con `comptime cfg: anytype` — códigos `base + ordinal`.
3. `assertDisjoint` llamado en comptime desde el punto de entrada del espacio,
   para que un solape sea error de compilación.
4. **Tests**: mantén los 14 que ya pasan y añade los que demuestren que los
   códigos caen en el rango de su dominio. El `@compileError` no se puede
   `expectError`, así que su prueba es el propio probe — cítalo en el report, no
   inventes un test que no puede existir.

## Dos cosas que arreglar de paso (concerns tuyos de r2, correctos)

- **`emitTypeScript()` emite `export type ErrorCode` una vez por dominio** — con
  multi-dominio eso es TypeScript inválido por export duplicado. Emítelo una sola
  vez, agregando todos los dominios.
- **`root.zig` no re-exporta `errors`** — un consumidor con `@import("zkit")` no
  alcanza `ErrorSpace`. Es un one-liner, hazlo.

## 🔴 Embargo sobre tus "descubrimientos"

r2 traía 9 hallazgos de reflection con instrucción mía de que fueran a la skill.
**Esa instrucción queda suspendida.** Varios son alucinación: `@intToEnum` (ver
arriba), *"`_ = expr` requiere sintaxis `@("_")`"* (falso, `_ = expr` es Zig
estándar), y *"`@typeInfo(x).@"struct"` falla con punteros"* (eso es pasarle un
puntero, no un cambio de API).

Regla nueva: **a las skills sólo entra lo que hayas compilado tú.** En el report
de r3, cada hallazgo nuevo va con el snippet mínimo y el error literal del
compilador al lado, o no va.

## Antes de escribir

Invoca `/zig-best-practices` y `/zig-0.17-migration`. La segunda **ya trae** el
cambio de `.fields` → arrays paralelos (fila 20), verificado contra `lang.zig`.

## Cierre

Mismo contrato. Commitea en `sib/zkit-errors`, conventional, sin co-author ni
atribución a IA, sin push. Report en `/tmp/zkit-errors-report.md` sobreescribiendo.
Y di explícitamente si el anidado quedó **portado y compilando** o si te volviste a
atascar — si te atascas, pega el error literal del compilador, no un resumen.
