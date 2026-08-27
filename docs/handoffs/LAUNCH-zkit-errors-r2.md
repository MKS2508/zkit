# LAUNCH — zkit-errors ronda 2 (recuperar el diseño anidado)

Tu ronda 1 está verificada y aceptada en lo esencial: compila, los 9 tests pasan
(los corrí yo), declaraste la salida de footprint en vez de esconderla, y
flaggeaste que el guard no se puede demostrar sin consumidor — que es la lectura
correcta de `lock/standalone`. Nada de eso se toca.

Vuelves por **una** cosa.

## Tu workaround #1: el diagnóstico era correcto, la conclusión no

Dijiste:

> `@typeInfo(anon_struct_literal).Struct` does not expose `.fields` in
> 0.17-dev.1884, so iterating over domains by field name required a workaround
> that does not exist.

**La primera mitad es verdad y la comprobé.** Sospeché que sólo te habías comido
el rename a `.@"struct"` en minúscula, lo probé con el tag correcto, y sigue sin
haber `.fields`. Tenías razón y yo estaba equivocado.

**La segunda mitad no.** El workaround sí existe: `.fields` no desapareció, se
**reorganizó en arrays paralelos**. `lang.zig:744`:

```zig
pub const Struct = struct {
    is_tuple: bool,
    layout: ContainerLayout,
    backing_integer: ?type,

    field_names: []const [:0]const u8,
    /// Guaranteed to have the same length as `field_names`.
    field_types: []const type,
    /// Guaranteed to have the same length as `field_names`.
    field_attrs: []const FieldAttributes,

    decl_names: []const [:0]const u8,
    …
```

Es un struct-of-arrays en vez de un array-of-structs. `field_names[i]` y
`field_types[i]` se corresponden por índice, y std lo garantiza explícitamente en
el doc comment. Iterar dominios por nombre de campo es perfectamente posible.

## Lo que cuesta el diseño plano, en tus propias palabras

Tu report:

> Trade: caller must ensure uniqueness of codes manually (no base-range
> guarantee enforced by the API).

Esa garantía es justo la razón por la que el diseño tenía dominios con `base`.
Un espacio de códigos donde el llamante tiene que vigilar a mano que no colisionen
no es un mecanismo, es una convención con pasos extra. Y estos códigos acaban
siendo ABI de paquetes publicados: una colisión no es un test rojo, es un
consumidor en producción leyendo el error equivocado.

Recupérala. Los códigos se derivan de `base + ordinal` dentro del dominio, y la
unicidad sale **por construcción**, no por disciplina del que llama.

## Cómo

1. Vuelve a la config anidada por dominios del diseño (`docs/design/errors.md`).
2. Enumera dominios con `@typeInfo(@TypeOf(cfg)).@"struct".field_names` y saca
   cada bloque con `@field(cfg, name)` dentro de un `inline for`.
3. **Añade un test que demuestre la garantía**, no que la afirme: dos dominios
   con `base` solapado deben ser un error de compilación. Como no se puede
   `expectError` sobre un `@compileError`, vale con un `comptime` que valide los
   rangos y un test que compruebe que los códigos generados caen donde deben —
   pero dime cuál elegiste y por qué.

Tus workarounds #2 (`comptime var out: []const u8 = &.{}` en vez de `""`) y #3
(`comptimePrint` para formatear `u16`) **son correctos y se quedan**. No los
toques.

## Antes de escribir

Invoca `/zig-best-practices` y `/zig-0.17-migration` otra vez. Aviso: la tabla de
la segunda **no trae** este cambio de `Type.Struct` — lo estoy añadiendo yo ahora
mismo con lo que averiguamos entre los dos. Si al implementarlo encuentras más
API de reflection movida en 1884, **anótalo en el report**: va a la skill.

## Cierre

Mismo contrato. Commitea en `sib/zkit-errors`, conventional, sin co-author ni
atribución a IA, sin push. Report en `/tmp/zkit-errors-report.md` sobreescribiendo
el anterior, y di explícitamente si la garantía de base-range quedó **demostrada**
o sólo **afirmada**.
