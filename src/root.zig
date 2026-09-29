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
