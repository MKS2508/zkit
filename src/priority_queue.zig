//! PriorityQueue(T) — hybrid bounded top-N + cheap overflow heap.
//!
//! Robado del patrón MoQ `lite/priority.rs` (CODE_VERIFIED, ~30 tests en
//! el upstream Rust): los top-N items in-flight viven en un `ArrayList`
//! ordenado por prioridad (index = prioridad, O(1) lookup, binary-search
//! insert), y el overflow cae a un `BinaryHeap` colapsado que reporta
//! `u8::MAX` (255). El insight robable —documentado en r40 § M4.priority
//! y en el harvest §2.1— es que **la parte caliente del scheduler nunca
//! crece con backlog ilimitado**: el overflow va a una estructura barata.
//!
//! ## Semántica de prioridad
//!
//! `priority: u8`, **menor = más urgente** (convención MoQ + iroh-live:
//! `VIDEO_PRIORITY=1, AUDIO=2, CHAT=10`). `0` es la prioridad máxima,
//! `255` es la mínima. Dentro de la misma prioridad, el orden es **FIFO**
//! (estable): el primer push sale primero.
//!
//! ## Estructura
//!
//! - `top_n`: `ArrayList(Entry)` ordenada ascending por `(priority, seq)`.
//!   Capacidad dura `top_n_cap` (default 255, constante `MAX_VEC_SIZE`
//!   del patrón MoQ). Insert es O(log N) vía binary-search + shift;
//!   pop es O(1) (siempre el primer elemento, el más urgente).
//! - `overflow`: `std.PriorityQueue(Entry)` min-heap. Cuando `top_n` está
//!   saturado, los pushes adicionales caen aquí con la prioridad
//!   **saturada a 255** (todos iguales → heap degenera a FIFO por seq).
//!   Cuando `top_n` se vacía, `pop()` drena del overflow trayendo el
//!   siguiente más urgente de vuelta a la estructura O(1).
//!
//! ## Concurrencia
//!
//! **NO es thread-safe.** El caller serializa vía mutex externo (el
//! scheduler del daemon envuelve cada PriorityQueue en su lock de sesión).
//! Esto está documentado en r40 y en el harvest: la parte top_n es
//! single-thread por diseño (SPSC o mutex-externo), no un ConcurrentSkipList.
//!
//! ## Anti-patrones rechazados
//!
//! - NO es un `Vec` sin cap que crece con backlog ilimitado en la parte
//!   caliente.
//! - NO decide política (ABR, descartes) — sólo ordena.
//! - NO tiene timers — es una estructura de datos pura.
//!
//! Origen: `styx/native/zig/media-core/scheduler/priority_queue.zig` (r40
//! § M4.priority). Portado con error sets explícitos, `pop` del overflow
//! documentado tal cual es (no "vuelve a la parte O(1)": sale directamente
//! del heap) y los tests externos de styx reescritos como verificación
//! contra un modelo de referencia.

const std = @import("std");

/// Capacidad máxima de la parte caliente (top-N). Constante del patrón
/// MoQ `lite/priority.rs` (`MAX_VEC_SIZE = 255`). Acota el coste de
/// insertion en el hot-path: O(log 255) ≈ 8 comparaciones peor caso.
pub const DEFAULT_TOP_N_CAP: u8 = 255;

/// Prioridad saturada a la que colapsa el overflow cuando `top_n` está
/// lleno. Coincide con `u8` max — el overflow reporta "prioridad mínima"
/// (menos urgente) para todos sus items, desempatando por `seq` (FIFO).
pub const OVERFLOW_SATURATED_PRIORITY: u8 = 255;

/// Entrada individual. Empareja el payload del caller (`T`) con su
/// `(priority, seq)` para ordenamiento estable dentro de la misma
/// prioridad.
///
/// `seq` es un counter monótono asignado al push — garantiza FIFO
/// determinístico incluso si el caller pasa el mismo `T` dos veces.
pub fn Entry(comptime T: type) type {
    return struct {
        /// Payload opaque para la cola — la cola nunca lo interpreta.
        item: T,
        /// Prioridad declarada al push (0=max, 255=min). En el overflow
        /// se satura a `OVERFLOW_SATURATED_PRIORITY`.
        priority: u8,
        /// Sequence number monótono para desempate FIFO estable.
        seq: u64,

        const Self = @This();

        /// Comparador para ordenamiento total: menor `(priority, seq)`
        /// primero. Usado tanto por el binary-search del `top_n` como
        /// por el min-heap del overflow.
        fn lessThan(_: void, a: Self, b: Self) std.math.Order {
            if (a.priority != b.priority) {
                return std.math.order(a.priority, b.priority);
            }
            return std.math.order(a.seq, b.seq);
        }

        /// Wrapper de `lessThan` con la firma que espera
        /// `std.PriorityQueue` (devuelve `.lt` cuando `a` debe salir
        /// antes que `b` → min-heap).
        fn heapCompare(_: void, a: Self, b: Self) std.math.Order {
            return lessThan({}, a, b);
        }
    };
}

/// Cola de prioridad híbrida acotada.
///
/// `T` es el tipo del payload (cualquier tipo copiable — la cola no lo
/// aloca ni lo posee; si `T` es un puntero, el caller gestiona su lifetime).
pub fn PriorityQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const EntryT = Entry(T);

        /// Parte caliente: top-N items ordenados ascending por urgencia.
        /// Index 0 = próximo a salir (más urgente). O(1) pop, O(log N)
        /// insert vía binary-search.
        top_n: std.ArrayList(EntryT),

        /// Overflow colapsado: min-heap con prioridad saturada. Drena
        /// de vuelta a `top_n` cuando éste se vacía.
        overflow: std.PriorityQueue(EntryT, void, Entry(T).heapCompare),

        /// Capacidad dura de `top_n`. Una vez fijada en `init`, no crece
        /// — el exceso va al overflow por diseño.
        top_n_cap: u8,

        /// Counter monótono para asignar `seq` y garantizar FIFO estable
        /// dentro de la misma prioridad. Envolver a 0 solo tras 2^64
        /// pushes (no es un caso realista).
        seq_counter: u64 = 0,

        /// Allocator dueño de ambas estructuras internas. Se guarda para
        /// que `deinit` libere todo sin que el caller tenga que recordar
        /// cuál usó.
        allocator: std.mem.Allocator,

        /// Inicializa la cola con capacidad top-N por defecto (255).
        ///
        /// El allocator se guarda internamente; `deinit` lo usa para
        /// liberar `top_n` y `overflow`. El caller NO debe liberar
        /// nada manualmente — solo `deinit`.
        pub fn init(allocator: std.mem.Allocator) Self {
            return initCapacity(allocator, DEFAULT_TOP_N_CAP);
        }

        /// Inicializa con capacidad top-N explícita. Útil para tests
        /// pequeños (ej. cap=4 para verificar saturación sin empujar
        /// 256 elementos) o para tuning por workload.
        pub fn initCapacity(allocator: std.mem.Allocator, cap: u8) Self {
            return Self{
                .top_n = .empty,
                .overflow = .empty,
                .top_n_cap = cap,
                .allocator = allocator,
            };
        }

        /// Libera ambas estructuras internas. Tras esto, la instancia
        /// queda en estado indefinido — no usar sin re-`init`.
        pub fn deinit(self: *Self) void {
            self.top_n.deinit(self.allocator);
            self.overflow.deinit(self.allocator);
            self.* = undefined;
        }

        /// Número total de items encolados (`top_n` + `overflow`).
        pub fn count(self: *const Self) usize {
            return self.top_n.items.len + self.overflow.count();
        }

        /// True si no hay items encolados.
        pub fn isEmpty(self: *const Self) bool {
            return self.count() == 0;
        }

        /// Inserta un item con la prioridad dada.
        ///
        /// Si `top_n` no está saturado, lo inserta en orden (binary-search
        /// + shift, O(log N)). Si está saturado, lo manda al overflow con
        /// prioridad saturada a `OVERFLOW_SATURATED_PRIORITY` (el payload
        /// y el `seq` se preservan — solo la prioridad efectiva colapsa).
        ///
        /// @param item payload a encolar (copiado — la cola no lo posee)
        /// @param priority 0=urgente, 255=mínimo
        pub fn push(self: *Self, item: T, priority: u8) error{OutOfMemory}!void {
            const seq = self.seq_counter;
            self.seq_counter += 1;
            const entry = EntryT{ .item = item, .priority = priority, .seq = seq };

            if (self.top_n.items.len < self.top_n_cap) {
                // top_n no saturado: binary-search la posición de inserción.
                // Buscamos el primer índice donde el entry existente sea
                // ESTRICTAMENTE MAYOR (menos urgente) que el nuevo — eso
                // preserva FIFO dentro de la misma prioridad (insertamos
                // DESPUÉS de los de igual prioridad, que llegaron antes).
                const idx = findInsertIndex(T, self.top_n.items, entry);
                try self.top_n.insert(self.allocator, idx, entry);
            } else {
                // Saturado: al overflow, prioridad colapsada a 255.
                // El seq se preserva → dentro del overflow, FIFO puro.
                const overflowed = EntryT{
                    .item = item,
                    .priority = OVERFLOW_SATURATED_PRIORITY,
                    .seq = seq,
                };
                try self.overflow.push(self.allocator, overflowed);
            }
        }

        /// Extrae el item más urgente.
        ///
        /// Siempre del `top_n` si no está vacío (`orderedRemove(0)`: O(N)
        /// con N <= 255, preserva el orden de los restantes). Si `top_n`
        /// está vacío, sale el siguiente del overflow (FIFO por `seq`, todos
        /// saturados a 255).
        ///
        /// @return el item más urgente, o `null` si ambas estructuras
        ///         están vacías.
        pub fn pop(self: *Self) ?T {
            if (self.top_n.items.len > 0) {
                // orderedRemove(0): O(N) shift, pero N ≤ 255 → barato.
                // No usamos swapRemove porque rompería el orden.
                const entry = self.top_n.orderedRemove(0);
                return entry.item;
            }
            if (self.overflow.count() > 0) {
                // top_n vacío pero overflow con items: drena el más
                // urgente del heap. Su prioridad ya está saturada a 255,
                // pero el seq preserva el orden FIFO original.
                const entry = self.overflow.pop() orelse return null;
                return entry.item;
            }
            return null;
        }

        /// Mira el item más urgente SIN extraerlo (para inspección / tests).
        /// O(1). No muta estado.
        pub fn peek(self: *const Self) ?T {
            if (self.top_n.items.len > 0) {
                return self.top_n.items[0].item;
            }
            if (self.overflow.peek()) |entry| {
                return entry.item;
            }
            return null;
        }

        /// Número de items actualmente en la parte caliente (top_n).
        /// Útil para tests de saturación.
        pub fn topNCount(self: *const Self) usize {
            return self.top_n.items.len;
        }

        /// Número de items actualmente en el overflow.
        /// Útil para tests de saturación.
        pub fn overflowCount(self: *const Self) usize {
            return self.overflow.count();
        }

        /// Vacía ambas estructuras sin liberar la capacidad (reusable).
        pub fn clearRetainingCapacity(self: *Self) void {
            self.top_n.clearRetainingCapacity();
            self.overflow.clearRetainingCapacity();
            self.seq_counter = 0;
        }
    };
}

/// Binary-search la posición de inserción para mantener `top_n` ordenado
/// ascending por `(priority, seq)`. Preserva FIFO dentro de la misma
/// prioridad: inserta DESPUÉS de todos los entries de igual o menor
/// urgencia (que llegaron antes).
///
/// No usa `std.sort.binarySearch` directamente porque ese devuelve el
/// índice de un match exacto, y nosotros queremos el **punto de
/// inserción** (lower-bound) incluso sin match. Implementación manual
/// del lower-bound clásico.
fn findInsertIndex(comptime T: type, items: []const Entry(T), target: Entry(T)) usize {
    var low: usize = 0;
    var high: usize = items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const cmp = Entry(T).lessThan({}, items[mid], target);
        switch (cmp) {
            // items[mid] es ESTRICTAMENTE más urgente que target →
            // target va después.
            .lt => low = mid + 1,
            // items[mid] es igual o menos urgente → target va antes o aquí.
            .eq, .gt => high = mid,
        }
    }
    return low;
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "PriorityQueue: init + deinit (empty, no leak)" {
    var pq = PriorityQueue(u32).init(testing.allocator);
    defer pq.deinit();
    try testing.expect(pq.isEmpty());
    try testing.expectEqual(@as(usize, 0), pq.count());
    try testing.expectEqual(@as(?u32, null), pq.pop());
}

test "PriorityQueue: single push + pop returns the item" {
    var pq = PriorityQueue(u32).init(testing.allocator);
    defer pq.deinit();
    try pq.push(42, 100);
    try testing.expectEqual(@as(usize, 1), pq.count());
    try testing.expectEqual(@as(?u32, 42), pq.pop());
    try testing.expect(pq.isEmpty());
}

test "PriorityQueue: lower priority value = more urgent (pops first)" {
    // priority 0 = urgente, 255 = mínimo. Verificamos el orden.
    var pq = PriorityQueue(u32).init(testing.allocator);
    defer pq.deinit();
    try pq.push(10, 5); // menos urgente
    try pq.push(20, 1); // más urgente
    try pq.push(30, 3); // medio
    try testing.expectEqual(@as(?u32, 20), pq.pop()); // priority 1
    try testing.expectEqual(@as(?u32, 30), pq.pop()); // priority 3
    try testing.expectEqual(@as(?u32, 10), pq.pop()); // priority 5
}

test "PriorityQueue: FIFO dentro de la misma prioridad" {
    var pq = PriorityQueue(u32).init(testing.allocator);
    defer pq.deinit();
    try pq.push(1, 5);
    try pq.push(2, 5);
    try pq.push(3, 5);
    // Mismo priority → orden de llegada.
    try testing.expectEqual(@as(?u32, 1), pq.pop());
    try testing.expectEqual(@as(?u32, 2), pq.pop());
    try testing.expectEqual(@as(?u32, 3), pq.pop());
}

test "PriorityQueue: saturación manda exceso al overflow" {
    // cap=4: 6 pushes misma priority → 4 en top_n, 2 en overflow.
    var pq = PriorityQueue(u32).initCapacity(testing.allocator, 4);
    defer pq.deinit();
    for (0..6) |i| {
        try pq.push(@intCast(i), 10);
    }
    try testing.expectEqual(@as(usize, 4), pq.topNCount());
    try testing.expectEqual(@as(usize, 2), pq.overflowCount());
    // Los 4 del top_n salen primero (FIFO: 0,1,2,3), luego los del overflow.
    for (0..6) |expected| {
        try testing.expectEqual(@as(?u32, @intCast(expected)), pq.pop());
    }
    try testing.expect(pq.isEmpty());
}

test "PriorityQueue: peek no extrae" {
    var pq = PriorityQueue(u32).init(testing.allocator);
    defer pq.deinit();
    try pq.push(99, 1);
    try testing.expectEqual(@as(?u32, 99), pq.peek());
    try testing.expectEqual(@as(usize, 1), pq.count());
    try testing.expectEqual(@as(?u32, 99), pq.pop());
}

test "findInsertIndex: lower-bound correcto" {
    const E = Entry(u32);
    var buf: [4]E = undefined;
    // items ya ordenados ascending por (priority, seq)
    buf[0] = .{ .item = 0, .priority = 1, .seq = 0 };
    buf[1] = .{ .item = 0, .priority = 2, .seq = 1 };
    buf[2] = .{ .item = 0, .priority = 2, .seq = 5 };
    buf[3] = .{ .item = 0, .priority = 5, .seq = 9 };
    const items = buf[0..4];

    // Insertar algo más urgente que todo → idx 0
    const urgent = E{ .item = 0, .priority = 0, .seq = 100 };
    try testing.expectEqual(@as(usize, 0), findInsertIndex(u32, items, urgent));

    // Insertar con priority 2, seq 3 → entre seq=1 y seq=5 → idx 2
    const mid = E{ .item = 0, .priority = 2, .seq = 3 };
    try testing.expectEqual(@as(usize, 2), findInsertIndex(u32, items, mid));

    // Insertar menos urgente que todo → idx 4 (final)
    const tail = E{ .item = 0, .priority = 9, .seq = 200 };
    try testing.expectEqual(@as(usize, 4), findInsertIndex(u32, items, tail));

    // Vacío → idx 0
    try testing.expectEqual(@as(usize, 0), findInsertIndex(u32, items[0..0], urgent));
}

/// Modelo de referencia: la misma semántica escrita de la forma más tonta
/// posible (lista ordenada por inserción lineal + FIFO plano).
fn Model(comptime cap: usize) type {
    return struct {
        top: std.ArrayList(Entry(u32)) = .empty,
        over: std.ArrayList(Entry(u32)) = .empty,
        seq: u64 = 0,

        fn push(m: *@This(), gpa: std.mem.Allocator, item: u32, prio: u8) !void {
            const e: Entry(u32) = .{ .item = item, .priority = prio, .seq = m.seq };
            m.seq += 1;
            if (m.top.items.len < cap) {
                var i: usize = 0;
                while (i < m.top.items.len and Entry(u32).lessThan({}, m.top.items[i], e) == .lt) i += 1;
                try m.top.insert(gpa, i, e);
            } else try m.over.append(gpa, e);
        }

        fn pop(m: *@This()) ?u32 {
            if (m.top.items.len > 0) return m.top.orderedRemove(0).item;
            if (m.over.items.len > 0) return m.over.orderedRemove(0).item;
            return null;
        }

        fn deinit(m: *@This(), gpa: std.mem.Allocator) void {
            m.top.deinit(gpa);
            m.over.deinit(gpa);
        }
    };
}

test "PriorityQueue: 20k operaciones aleatorias idénticas al modelo de referencia" {
    const cap = 8;
    var pq = PriorityQueue(u32).initCapacity(testing.allocator, cap);
    defer pq.deinit();
    var model: Model(cap) = .{};
    defer model.deinit(testing.allocator);
    var prng = std.Random.DefaultPrng.init(0x5eed_2026);
    const r = prng.random();
    var next: u32 = 0;
    for (0..20_000) |_| {
        if (r.uintLessThan(u8, 10) < 6) {
            const prio = r.uintLessThan(u8, 6);
            try pq.push(next, prio);
            try model.push(testing.allocator, next, prio);
            next += 1;
        } else {
            try testing.expectEqual(model.pop(), pq.pop());
        }
        try testing.expectEqual(model.top.items.len + model.over.items.len, pq.count());
    }
    while (model.pop()) |want| try testing.expectEqual(@as(?u32, want), pq.pop());
    try testing.expectEqual(@as(?u32, null), pq.pop());
}

test "PriorityQueue: 256+ con la misma prioridad llenan top_n (255) y el resto va al overflow" {
    var pq = PriorityQueue(u32).init(testing.allocator);
    defer pq.deinit();
    for (0..300) |i| try pq.push(@intCast(i), 7);
    try testing.expectEqual(@as(usize, DEFAULT_TOP_N_CAP), pq.topNCount());
    try testing.expectEqual(@as(usize, 300 - @as(usize, DEFAULT_TOP_N_CAP)), pq.overflowCount());
    for (0..300) |i| try testing.expectEqual(@as(?u32, @intCast(i)), pq.pop());
    pq.clearRetainingCapacity();
    try testing.expect(pq.isEmpty());
}

test "PriorityQueue: OOM en push no pierde lo ya encolado" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var pq = PriorityQueue(u32).initCapacity(failing.allocator(), 1);
    defer pq.deinit();
    try pq.push(1, 0); // top_n: 1 alloc
    try testing.expectError(error.OutOfMemory, pq.push(2, 0)); // overflow: falla
    try testing.expectEqual(@as(?u32, 1), pq.pop());
    try testing.expectEqual(@as(?u32, null), pq.pop());
}
