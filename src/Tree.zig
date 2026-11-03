pub const Tree = @This();

io: std.Io,
allocator: Allocator,
root: ?*Node = null,
context: *Context,
blackboard: Blackboard,
nodes: ArrayList(*Node) = .empty,
loggers: ArrayList(*Logger) = .empty,

/// Initialize the tree, providing an allocator and a global Context.
/// The Tree does not take ownership of the Context struct.
pub fn init(io: std.Io, alloc: Allocator, ctx: *Context) Tree {
    return .{
        .io = io,
        .allocator = alloc,
        .context = ctx,
        .blackboard = Blackboard.init(alloc),
    };
}

pub fn deinit(tree: *Tree) void {
    if (tree.root) |*root| root.*.deinit(tree.allocator);
    tree.nodes.deinit(tree.allocator);
    tree.loggers.deinit(tree.allocator);
    var iter = tree.blackboard.iterator();
    while (iter.next()) |elem| {
        switch (elem.value_ptr.*) {
            .string => |s| tree.allocator.free(s),
            else => {},
        }
        tree.allocator.free(elem.key_ptr.*);
    }
    tree.blackboard.deinit();
}

/// Tick the root of the tree
pub fn tick(tree: *Tree) Node.Status {
    return if (tree.root) |root| root.tick() else .failure;
}

pub fn addNode(tree: *Tree, node: *Node) !void {
    try tree.nodes.append(tree.allocator, node);
}

/// Add the given logger as a Status Change callback to all Nodes in the Tree
pub fn addLogger(tree: *Tree, alloc: Allocator, logger: *Logger) !void {
    try tree.loggers.append(alloc, logger);

    const visitor = LoggerVisitor{
        .alloc = alloc,
        .logger = logger,
    };

    if (tree.root) |root| {
        applyRecursiveVisitor(root, LoggerVisitor, visitor, LoggerVisitor.visit);
    }
}

/// Struct to act as a capture group for an allocator and a Logger,
/// for use with applyRecursiveVisitor
const LoggerVisitor = struct {
    alloc: Allocator,
    logger: *Logger,

    pub fn visit(visitor: LoggerVisitor, node: *Node) void {
        // const visitor: LoggerVisitor = @as(LoggerVisitor, ctx);
        node.status_changed_cbs.append(visitor.alloc, .{
            .ctx = visitor.logger,
            .callback = Logger.callback,
        }) catch @panic("OOM");
    }
};

/// Recursively applies the function defined via 'ctx' and 'visitor' to the node.
/// The visitor is applied depth-first to any and all child nodes.
fn applyRecursiveVisitor(node: *Node, comptime T: type, ctx: T, visitor: *const fn (T, *Node) void) void {
    switch (node.data) {
        .control => |control| {
            for (control.children.items) |child| {
                applyRecursiveVisitor(child, T, ctx, visitor);
            }
        },
        .decorator => |d| {
            applyRecursiveVisitor(d.child, T, ctx, visitor);
        },
        else => {},
    }

    visitor(ctx, node);
}

const Node = @import("Node.zig");
const Context = @import("Context.zig");
const Logger = @import("Logger.zig");
const Control = @import("base_types/Control.zig");

const Blackboard = @import("blackboard.zig").Blackboard;
const BlackboardValue = @import("blackboard.zig").Value;

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

////////////////////////////////////////////////////////////////////////////////
// Unit Tests
////////////////////////////////////////////////////////////////////////////////

test "[Tree] Add Logger, No Nodes" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var ctx = try Context.create(alloc, null);
    defer ctx.deinit();

    var tree = Tree.init(io, alloc, ctx);
    defer tree.deinit();

    var logger: @import("loggers/StdoutLogger.zig") = .init(io);
    try tree.addLogger(alloc, logger.interface());

    try std.testing.expectEqual(.failure, tree.tick());
}
