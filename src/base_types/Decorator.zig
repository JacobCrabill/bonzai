//! A Decorator is a high-level node type which has a single child node.
const Decorator = @This();

child: *Node = undefined,

pub fn halt(decorator: *Decorator) void {
    decorator.child.halt();
}

pub fn deinit(decorator: *Decorator, alloc: Allocator) void {
    decorator.child.deinit(alloc);
}

const Node = @import("../Node.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
