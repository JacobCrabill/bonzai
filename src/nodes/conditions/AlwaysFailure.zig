//! A trivial Condition which always returns Failure.
const AlwaysFailure = @This();

pub const kind: Node.Kind = .condition;

pub fn tick(_: *AlwaysFailure) Node.Status {
    return .failure;
}

const Node = @import("../../Node.zig");
