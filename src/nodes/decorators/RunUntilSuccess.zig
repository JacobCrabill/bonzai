//! An RunUntilSuccess ticks its child forever until it returns Success
const RunUntilSuccess = @This();

node: Node,

pub fn tick(node: *Node) Node.Status {
    var child: *Node = node.data.decorator.child;
    const result = child.tick();
    return switch (result) {
        .success => .success,
        .running => .running,
        .failure => blk: {
            child.halt();
            break :blk .running;
        },
        .idle => @panic("Nodes may not return 'idle' from tick()!"),
    };
}

pub fn init(alloc: Allocator, name: []const u8) !RunUntilSuccess {
    return .{
        .node = try .init(alloc, name, .decorator, .{
            .tick = tick,
        }),
    };
}

const Node = @import("../../Node.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

test "[RunUntilSuccess] basics" {
    const alloc = std.testing.allocator;
    const AlwaysRunning = @import("../actions/AlwaysRunning.zig");
    const AlwaysSuccess = @import("../conditions/AlwaysSuccess.zig");
    const AlwaysFailure = @import("../conditions/AlwaysFailure.zig");

    {
        const name = "running";
        var inv = try RunUntilSuccess.init(alloc, name);
        defer inv.node.deinit(alloc);

        try std.testing.expectEqualStrings(inv.node.name, name);

        var s1 = try AlwaysRunning.init(alloc, "running-1");
        inv.node.data.decorator.child = &s1.node;
        try std.testing.expectEqual(.running, inv.node.tick());

        inv.node.halt();
        try std.testing.expectEqual(.idle, inv.node.data.decorator.child.status);
    }

    {
        const name = "failure";
        var inv = try RunUntilSuccess.init(alloc, name);
        defer inv.node.deinit(alloc);

        try std.testing.expectEqualStrings(inv.node.name, name);

        var s1 = try AlwaysFailure.init(alloc, "failure-1");
        inv.node.data.decorator.child = &s1.node;
        try std.testing.expectEqual(.running, inv.node.tick());
        try std.testing.expectEqual(.running, inv.node.tick());
        try std.testing.expectEqual(.running, inv.node.tick());
        try std.testing.expectEqual(.running, inv.node.tick());
        // ...we could keep going here forever

        inv.node.halt();
        try std.testing.expectEqual(.idle, inv.node.data.decorator.child.status);
    }

    {
        const name = "success";
        var inv = try RunUntilSuccess.init(alloc, name);
        defer inv.node.deinit(alloc);

        try std.testing.expectEqualStrings(inv.node.name, name);

        var s1 = try AlwaysSuccess.init(alloc, "success-1");
        inv.node.data.decorator.child = &s1.node;
        try std.testing.expectEqual(.success, inv.node.tick());

        inv.node.halt();
        try std.testing.expectEqual(.idle, inv.node.data.decorator.child.status);
    }
}
