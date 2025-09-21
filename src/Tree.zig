pub const Tree = @This();

root: *Node,
nodes: ArrayList(*Node),
loggers: ArrayList(Logger),

fn applyRecursiveVisitor(node: *Node, visitor: *const fn (*Node) void) void {
    switch (node.kind) {
        .control => {
            const control: *Control = @ptrCast(@alignCast(node));
            for (control.children.items) |child| {
                visitor(child);
                applyRecursiveVisitor(child);
            }
        },
        .decorator => {
            // TODO
        },
    }

    visitor(node);
}

pub fn addLogger(tree: *Tree, alloc: Allocator, logger: Logger) !void {
    try tree.loggers.append(alloc, logger);
}

const Node = @import("Node.zig");
const Logger = @import("Logger.zig");
const Control = @import("base_types/Control.zig");

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
