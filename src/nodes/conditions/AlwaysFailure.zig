const AlwaysFailure = @This();

node: Node,

pub fn tick(_: *Node) Node.Status {
    return .failure;
}

/// Initialize a new node of this type
pub fn init(self: *@This(), alloc: Allocator, name: []const u8) !void {
    self.node = try .init(alloc, name, .condition, .{
        .tick = tick,
        .deinit = deinit,
    });
}

/// Create an instance of this node type
pub fn create(alloc: Allocator, name: []const u8) !*Node {
    var node = try alloc.create(@This());
    try node.init(alloc, name);
    return &node.node;
}

/// Destroy this node instance
pub fn deinit(node: *Node, alloc: Allocator) void {
    const self: *@This() = @alignCast(@fieldParentPtr("node", node));
    alloc.destroy(self);
}

const Node = @import("../../Node.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;
