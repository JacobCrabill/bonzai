//! A trivial Condition which always returns Success.
const AlwaysSuccess = @This();

pub const kind: Node.Kind = .condition;

pub fn tick(_: *AlwaysSuccess) Node.Status {
    return .success;
}

const Node = @import("../../Node.zig");
