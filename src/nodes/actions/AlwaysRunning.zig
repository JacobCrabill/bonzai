//! A trivial Action which always returns Running.
const AlwaysRunning = @This();

pub const kind: Node.Kind = .action;

pub fn tick(_: *AlwaysRunning) Node.Status {
    return .running;
}

const Node = @import("../../Node.zig");
