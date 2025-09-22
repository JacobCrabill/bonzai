const AlwaysFailure = @This();

node: Node,

pub fn tick(_: *Node) Node.Status {
    return .failure;
}

pub fn init(alloc: std.mem.Allocator, name: []const u8) !AlwaysFailure {
    return .{
        .node = try .init(alloc, name, .condition, .{
            .tick = tick,
        }),
    };
}

const Node = @import("../../Node.zig");
const std = @import("std");
