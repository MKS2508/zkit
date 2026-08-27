//! zkit/errors — comptime error-space with TypeScript emission and build-time guard
//!
//! See `docs/design/errors.md` for the design document.

pub const ErrorSpace = @import("errors/space.zig").ErrorSpace;
pub const Entry = @import("errors/space.zig").Entry;
pub const Domain = @import("errors/space.zig").Domain;
