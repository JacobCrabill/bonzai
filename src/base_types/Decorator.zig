//! A Decorator is a high-level node type which has a single child node.
const Decorator = @This();

child: ?*Node = null,

pub fn halt(decorator: *Decorator) void {
    if (decorator.child) |child| child.halt();
}

pub fn deinit(decorator: *Decorator, alloc: Allocator) void {
    if (decorator.child) |child| child.deinit(alloc);
}

pub fn tick(decorator: *Decorator) Node.Status {
    return if (decorator.child) |child| child.tick() else .failure;
}

const Node = @import("../Node.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
