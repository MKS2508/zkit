# `zkit/errors` — el espacio de códigos como mecanismo

**Estado**: diseño. Sin implementar.
**Nodo**: `zkit/errors-mechanism` (owner: axon1).
**Lock**: `lock/zkit-v0-mechanism` — zkit aporta el mecanismo, **no** los 42 códigos de
hyperdiff. Los códigos concretos son la ABI de paquetes publicados y se quedan donde están.

---

## 1. El problema, medido

La ABI de errores de hyperdiff se mantiene **a mano en cinco tablas paralelas, en dos
lenguajes**:

```
core/zig/src/errors.zig (572 l)          core/packages/utils/src/errors.ts
  ├─ error sets por dominio                ├─ HyperdiffErrorCode  (union de strings)
  ├─ enum numérico (1000-1099 io,          ├─ HYPERDIFF_NUMERIC_CODES (string→number)
  │   2000-2099 hash, …)                   └─ ERROR_MESSAGES (number→mensaje)
  └─ errorMessage()
```

El doc-comment de `errors.ts:7` promete: *"Every error code, message, and domain is 1:1 with
errors.zig"*.

**Nada lo comprueba.** Es una promesa sostenida por disciplina humana, en el borde entre un
motor nativo y tres paquetes npm publicados. El día que alguien añada un código en Zig y olvide
la tabla de mensajes en TS, el fallo no aparece al compilar ni al testear: aparece en producción,
como un error sin mensaje.

## 2. La forma

Un `ErrorSpace` comptime: se declara **una vez**, en Zig, y de ahí se derivan todas las vistas.

```zig
const zkit = @import("zkit");

pub const Space = zkit.errors.ErrorSpace(&.{
    .{ .name = "io", .base = 1000, .entries = &.{
        .{ .tag = "FILE_NOT_FOUND",   .message = "File not found" },
        .{ .tag = "PERMISSION_DENIED", .message = "Permission denied" },
        // …
    }},
    .{ .name = "hash", .base = 2000, .entries = &.{
        .{ .tag = "INVALID_UTF8", .message = "Invalid UTF-8 sequence" },
        // …
    }},
});
```

Y `Space` expone, todo derivado:

| Miembro | Qué es |
|---|---|
| `Space.Code` | `enum(u16)` con un tag por entrada, valor `base + ordinal` |
| `Space.Error` | el error set de Zig, un error por entrada |
| `Space.codeOf(err) Code` | switch exhaustivo generado — **no puede quedar incompleto** |
| `Space.errorOf(code) ?Error` | la inversa |
| `Space.messageOf(code) []const u8` | el mensaje |
| `Space.emitTypeScript()` | `[]const u8` **comptime** con el módulo TS de datos |

El switch de `codeOf` se genera con `inline for` sobre las entradas: añadir un error al espacio
y olvidar su código **no compila**. Hoy eso es un `switch` de 572 líneas escrito a mano.

## 3. El guard: la divergencia pasa a ser un error de compilación

`emitTypeScript()` es comptime-conocido, y `@embedFile` también. Así que la comparación entera
ocurre en comptime:

```zig
comptime {
    const emitted = Space.emitTypeScript();
    const on_disk = @embedFile("../../packages/utils/src/errors.generated.ts");
    if (!std.mem.eql(u8, emitted, on_disk)) {
        @compileError("errors.generated.ts está desincronizado — regenera con `zig build emit-errors`");
    }
}
```

No es un test que alguien puede olvidar correr: **es el compilador**. Si los códigos divergen,
hyperdiff no compila. La promesa del doc-comment se vuelve un invariante.

`@embedFile` resuelve rutas dentro del propio paquete, así que este bloque vive en **hyperdiff**,
no en zkit. zkit aporta `emitTypeScript()`; hyperdiff aporta el `@embedFile` y la ruta. Es el
reparto correcto: el mecanismo es genérico, la ruta es del consumidor.

## 4. Qué se genera y qué no

Se genera **solo la capa de datos**, en un fichero aparte:

```
errors.generated.ts     ← generado. Union de tags, mapa numérico, mensajes. Nadie lo edita.
errors.ts               ← a mano. Importa lo anterior y pone la ergonomía:
                          resultError(), la tabla de metadata (retryable, httpStatus,
                          suggestedAction), los type guards, la integración con
                          @mks2508/no-throw.
```

**El mecanismo genera datos; las personas conservan la ergonomía.** Generar `errors.ts` entero
sería más "completo" y peor: metería la tabla de metadata —que es criterio humano, no derivable
del espacio de códigos— dentro de un fichero que nadie puede tocar.

## 5. Coste honesto

- **Un solo consumidor hoy.** styx no cruza códigos de error a TS (su borde con Bun es
  `media-daemon/ipc/control.zig`, framing binario propio); quic-zig tampoco. Así que esto no es
  abstracción-para-reutilizar: **es abstracción para correctitud**, y se justifica por el guard,
  no por el número de consumidores. Si el guard no se implementa, esto no vale la pena y hay que
  decirlo en voz alta.
- **~200 líneas de comptime** sustituyen ~572 de Zig escrito a mano más tres tablas TS. El neto
  es negativo en líneas, pero el comptime es más difícil de leer que un switch plano. Compensa
  por el guard, no por el ahorro.
- **Migrar hyperdiff no entra en esta pasada** (`lock/standalone`: cero aristas `.zon`). Primero
  existe el mecanismo con sus propios tests en zkit; el wiring va después y con parity gate,
  porque toca la ABI de tres paquetes publicados.

## 6. Verificación pendiente

Nada compilado — la matriz ocupa la máquina. Antes de implementar:

1. Confirmar que un `[]const u8` construido con `std.fmt.comptimePrint` sobre un `inline for`
   sigue siendo comptime-conocido en `0.17.0-dev.1884` y se puede comparar con `@embedFile` en
   un bloque `comptime`. Es la pieza que sostiene todo el diseño; si no se puede, el guard baja
   a test normal (`std.testing.expectEqualStrings`) y pierde el "no compila".
2. Medir el impacto en tiempo de compilación de generar ~46 entradas por `inline for`. Si sube
   de forma apreciable, el emisor puede ser un step de `build.zig` en vez de comptime puro, y el
   guard queda como test.
