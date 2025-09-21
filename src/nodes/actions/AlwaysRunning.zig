const AlwaysRunning = @This();

node: Node,

pub fn tick(_: *Node) Node.Status {
    return .running;
}

pub fn init(name: []const u8, alloc: std.mem.Allocator) !AlwaysRunning {
    return .{
        .node = try .init(alloc, name, .action, .{
            .tick = tick,
        }),
    };
}

const Node = @import("../../Node.zig");
const std = @import("std");
