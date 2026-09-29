//! zkit.safety — capa de seguridad reutilizable para código Zig que procesa
//! entrada no confiable con hilos propios (styx dec-0117, parte 1 Zig).
//!
//! Cada pieza convierte una clase de bug en imposible o en fallo determinista:
//!
//! | Pieza | Clase de bug |
//! |---|---|
//! | `Handle(Tag)` / `TypedSlab` | use-after-free por handle obsoleto (generación) y confusión de handles (tipo por `Tag`) |
//! | `Budget` / `BudgetAllocator` | memoria sin cota por sesión/usuario; leaks sin informe; contabilidad no independiente |
//! | `fs.Root` | path traversal, symlinks que escapan, TOCTOU entre comprobar y abrir, FIFOs que bloquean |
//! | `BoundedReader` / `BitReader` | lecturas fuera de límites, longitudes del wire sin validar, contadores que dimensionan reservas, códigos Exp-Golomb/uvlc con desplazamientos gigantes |
//! | `checked` | desbordes aritméticos en offsets/longitudes (`offset + len` que da la vuelta) |
//! | `Mutex` | unlock desde otro hilo, autodeadlock, inversión de orden de locks |
//! | `fuzz` | parsers que hacen pánico o fugan con entradas truncadas/corruptas |
//!
//! Lo que esta capa NO puede imponer (lo imponen los guards de build/CI del
//! consumidor, dec-0117 "doble capa"): que el código no se la salte — rutas
//! crudas, pthread directo, `catch {}` en parsers, `unreachable` sobre input.

pub const Handle = @import("safety/handle.zig").Handle;
pub const TypedSlab = @import("safety/handle.zig").TypedSlab;
pub const SlabOptions = @import("safety/handle.zig").SlabOptions;

pub const Budget = @import("safety/budget.zig").Budget;
pub const BudgetAllocator = @import("safety/budget.zig").BudgetAllocator;
pub const LeakReport = @import("safety/budget.zig").LeakReport;

pub const fs = @import("safety/fs.zig");

pub const BoundedReader = @import("safety/bounded_reader.zig").BoundedReader;
pub const bounded_reader = @import("safety/bounded_reader.zig");
pub const checked = @import("safety/checked.zig");
pub const BitReader = @import("safety/bit_reader.zig").BitReader;

pub const Mutex = @import("safety/mutex.zig").Mutex;
pub const mutex = @import("safety/mutex.zig");

pub const fuzz = @import("safety/fuzz.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("safety/handle.zig");
    _ = @import("safety/budget.zig");
    _ = @import("safety/fs.zig");
    _ = @import("safety/bounded_reader.zig");
    _ = @import("safety/checked.zig");
    _ = @import("safety/bit_reader.zig");
    _ = @import("safety/mutex.zig");
    _ = @import("safety/fuzz.zig");
}
