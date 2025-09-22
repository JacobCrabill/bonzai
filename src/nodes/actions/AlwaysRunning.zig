const AlwaysRunning = @This();

node: Node,

pub fn tick(_: *Node) Node.Status {
    return .running;
}

pub fn init(alloc: Allocator, name: []const u8) !AlwaysRunning {
    return .{
        .node = try .init(alloc, name, .action, .{
            .tick = tick,
        }),
    };
}

pub fn create(alloc: Allocator, name: []const u8) !*Node {
    var node = try alloc.create(AlwaysRunning);
    node.node = try .init(alloc, name, .action, .{
        .tick = tick,
        .deinit = deinit,
    });
    return &node.node;
}

/// Destroy this node instance
pub fn deinit(node: *Node, alloc: Allocator) void {
    const run: *AlwaysRunning = @alignCast(@fieldParentPtr("node", node));
    alloc.destroy(run);
}

const Node = @import("../../Node.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;
