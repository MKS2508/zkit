//! zkit — primitives toolkit for Zig
//!
//! Re-exports all public primitives. No `usingnamespace` — explicit re-export
//! per symbol so the public API is visible and auditable.

pub const SubscriberQueue = @import("subscriber_queue.zig").SubscriberQueue;
pub const ReorderBuffer = @import("reorder_buffer.zig").ReorderBuffer;
pub const SequenceNumber = @import("reorder_buffer.zig").SequenceNumber;
pub const HungWorkerWatchdog = @import("watchdog.zig").HungWorkerWatchdog;
pub const WatchdogStatus = @import("watchdog.zig").WatchdogStatus;
pub const TrackingAllocator = @import("tracking_allocator.zig").TrackingAllocator;
pub const HandleSlab = @import("handle.zig").HandleSlab;
pub const log = @import("log.zig");
pub const errors = @import("errors.zig");
pub const WakeupPipe = @import("ipc.zig").WakeupPipe;

// ── SO sin runtime `Io` (hilos propios / FFI) ─────────────────────────────
pub const time = @import("time.zig");
pub const sync = @import("sync.zig");
pub const os = @import("os.zig");
pub const fs = @import("fs.zig");
pub const testing = @import("testing.zig");

// ── Concurrencia (nodo zkit/handle-concurrent) ────────────────────────────
pub const ConcurrentHandleSlab = @import("handle_concurrent.zig").ConcurrentHandleSlab;
pub const bounded_queue = @import("bounded_queue.zig");
pub const BoundedQueue = bounded_queue.BoundedQueue;

// ── Estructuras extraídas del data plane de styx ──────────────────────────
pub const PriorityQueue = @import("priority_queue.zig").PriorityQueue;
pub const LatestValue = @import("latest_value.zig").LatestValue;
pub const AtomicHistogram = @import("histogram.zig").AtomicHistogram;
pub const ZeroCopyBuffer = @import("zero_copy_buffer.zig").ZeroCopyBuffer;
pub const BufferGuard = @import("zero_copy_buffer.zig").BufferGuard;

// ── Capa de seguridad (styx dec-0117) ─────────────────────────────────────
pub const safety = @import("safety.zig");

test {
    // Un solo binario de test para todo lo que exporta la raíz: cada fichero
    // arrastra los tests de lo que importa, así que un binario por fichero
    // ejecutaba los mismos tests varias veces. `refAllDecls` además obliga a
    // analizar toda la API pública (el análisis perezoso de Zig no compila
    // cuerpos que nadie referencia).
    const std = @import("std");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(safety);
    _ = @import("subscriber_queue.zig");
    _ = @import("reorder_buffer.zig");
    _ = @import("watchdog.zig");
    _ = @import("tracking_allocator.zig");
    _ = @import("handle.zig");
    _ = @import("log.zig");
    _ = @import("ipc.zig");
    _ = @import("time.zig");
    _ = @import("sync.zig");
    _ = @import("os.zig");
    _ = @import("fs.zig");
    _ = @import("testing.zig");
    _ = @import("handle_concurrent.zig");
    _ = @import("bounded_queue.zig");
    _ = @import("priority_queue.zig");
    _ = @import("latest_value.zig");
    _ = @import("histogram.zig");
    _ = @import("zero_copy_buffer.zig");
    _ = @import("safety.zig");
}
