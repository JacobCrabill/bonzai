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

/// Initialize a new node of this type
pub fn init(self: *@This(), alloc: Allocator, name: []const u8) !void {
    self.node = try .init(alloc, name, .decorator, .{
        .tick = tick,
        .deinit = deinit,
    });
}

/// Create a new Sequence node, returning the base Node pointer
pub fn create(alloc: Allocator, name: []const u8) anyerror!*Node {
    var node = try alloc.create(@This());
    try node.init(alloc, name);
    return &node.node;
}

/// Deinitialize the node and free all resources
pub fn deinit(node: *Node, alloc: Allocator) void {
    const self: *@This() = @alignCast(@fieldParentPtr("node", node));
    alloc.destroy(self);
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
        const run: *Node = try RunUntilSuccess.create(alloc, name);
        defer run.deinit(alloc);

        try std.testing.expectEqualStrings(run.name, name);

        const s1 = try AlwaysRunning.create(alloc, "running-1");
        run.data.decorator.child = s1;
        try std.testing.expectEqual(.running, run.tick());

        run.halt();
        try std.testing.expectEqual(.idle, run.data.decorator.child.status);
    }

    {
        const name = "failure";
        var run = try RunUntilSuccess.create(alloc, name);
        defer run.deinit(alloc);

        try std.testing.expectEqualStrings(run.name, name);

        const s1 = try AlwaysFailure.create(alloc, "failure-1");
        run.data.decorator.child = s1;
        try std.testing.expectEqual(.running, run.tick());
        try std.testing.expectEqual(.running, run.tick());
        try std.testing.expectEqual(.running, run.tick());
        try std.testing.expectEqual(.running, run.tick());
        // ...we could keep going here forever

        run.halt();
        try std.testing.expectEqual(.idle, run.data.decorator.child.status);
    }

    {
        const name = "success";
        const run = try RunUntilSuccess.create(alloc, name);
        defer run.deinit(alloc);

        try std.testing.expectEqualStrings(run.name, name);

        const s1 = try AlwaysSuccess.create(alloc, "success-1");
        run.data.decorator.child = s1;
        try std.testing.expectEqual(.success, run.tick());

        run.halt();
        try std.testing.expectEqual(.idle, run.data.decorator.child.status);
    }
}
