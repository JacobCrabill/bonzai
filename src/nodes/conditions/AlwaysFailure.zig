const AlwaysFailure = @This();

node: Node,

pub fn tick(_: *Node) Node.Status {
    return .failure;
}

pub fn init(name: []const u8, alloc: std.mem.Allocator) !AlwaysFailure {
    return .{
        .node = try .init(alloc, name, .condition, .{
            .tick = tick,
        }),
    };
}

const Node = @import("../../Node.zig");
const std = @import("std");
