const AlwaysSuccess = @This();

node: Node,

pub fn tick(_: *Node) Node.Status {
    return .success;
}

pub fn init(name: []const u8, alloc: std.mem.Allocator) !AlwaysSuccess {
    return .{
        .node = try .init(alloc, name, .condition, .{
            .tick = tick,
        }),
    };
}

const Node = @import("../../Node.zig");
const std = @import("std");
