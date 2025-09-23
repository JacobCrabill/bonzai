pub const Tree = @This();

allocator: Allocator,
root: ?*Node = null,
nodes: ArrayList(*Node) = .empty,
loggers: ArrayList(*Logger) = .empty,

pub fn init(alloc: Allocator) Tree {
    return .{
        .allocator = alloc,
    };
}

pub fn deinit(tree: *Tree, alloc: Allocator) void {
    if (tree.root) |*root| root.*.deinit(alloc);
    tree.nodes.deinit(alloc);
    tree.loggers.deinit(alloc);
}

pub fn tick(tree: *Tree) Node.Status {
    return if (tree.root) |root| root.tick() else .failure;
}

/// Add the given logger as a Status Change callback to all Nodes in the Tree
pub fn addLogger(tree: *Tree, alloc: Allocator, logger: *Logger) !void {
    try tree.loggers.append(alloc, logger);

    const visitor = LoggerVisitor{
        .alloc = alloc,
        .logger = logger,
    };

    if (tree.root) |root| {
        applyRecursiveVisitor(root, visitor, LoggerVisitor.visit);
    }
}

/// Struct to act as a capture group for an allocator and a Logger,
/// for use with applyRecursiveVisitor
const LoggerVisitor = struct {
    alloc: Allocator,
    logger: *Logger,

    pub fn visit(ctx: anytype, node: *Node) void {
        const visitor: LoggerVisitor = @as(LoggerVisitor, ctx);
        node.status_changed_cbs.append(visitor.alloc, .{
            .ctx = visitor.logger,
            .callback = Logger.callback,
        }) catch @panic("OOM");
    }
};

/// Recursively applies the function defined via 'ctx' and 'visitor' to the node.
/// The visitor is applied depth-first to any and all child nodes.
fn applyRecursiveVisitor(node: *Node, ctx: anytype, visitor: *const fn (anytype, *Node) void) void {
    switch (node.data) {
        .control => |control| {
            for (control.children.items) |child| {
                applyRecursiveVisitor(child, ctx, visitor);
                visitor(ctx, child);
            }
        },
        .decorator => |d| {
            applyRecursiveVisitor(d.child, ctx, visitor);
            visitor(ctx, d.child);
        },
        else => {},
    }

    visitor(ctx, node);
}

const Node = @import("Node.zig");
const Logger = @import("Logger.zig");
const Control = @import("base_types/Control.zig");

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

test "[Tree] Add Logger, No Nodes" {
    const alloc = std.testing.allocator;

    var tree = Tree.init(alloc);
    defer tree.deinit(alloc);

    var logger = @import("loggers/StdoutLogger.zig").init();
    try tree.addLogger(alloc, &logger.logger);

    try std.testing.expectEqual(.failure, tree.tick());
}
