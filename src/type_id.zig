//! A minimal runtime type identifier.
//!
//! `typeId(T)` returns the address of a global variable that exists once per type `T`,
//! giving a unique, link-time-constant value that can be stored and compared at runtime.
//! It is only meaningful within a single program image; do not persist or serialize it.

/// A unique runtime identifier for a type
pub const TypeId = *const anyopaque;

pub fn typeId(comptime T: type) TypeId {
    return @ptrCast(&struct {
        // Capturing T makes this a distinct struct type (and thus a distinct global) for each T
        const _ = T;
        // A non-zero-sized `var` guarantees a unique address that cannot be merged
        var id: u8 = 0;
    }.id);
}

test "[typeId] unique per type" {
    const std = @import("std");
    const A = struct { x: u32 };
    const B = struct { x: u32 };
    try std.testing.expect(typeId(A) == typeId(A));
    try std.testing.expect(typeId(A) != typeId(B));
    try std.testing.expect(typeId(u32) != typeId(i32));
}
