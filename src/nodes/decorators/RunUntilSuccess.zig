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
pub fn init(self: *@This(), alloc: Allocator, ctx: *Context, name: []const u8) !void {
    self.node = try .init(alloc, ctx, name, .decorator, .{
        .tick = tick,
        .deinit = deinit,
    });
}

/// Create an instance of this node type
pub fn create(alloc: Allocator, ctx: *Context, name: []const u8) anyerror!*Node {
    var node = try alloc.create(@This());
    try node.init(alloc, ctx, name);
    return &node.node;
}

/// Deinitialize the node and free all resources
pub fn deinit(node: *Node, alloc: Allocator) void {
    const self = node.cast(@This());
    alloc.destroy(self);
}

const Node = @import("../../Node.zig");
const Context = @import("../../Context.zig");

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

    var ctx = try Context.create(alloc, null);
    defer ctx.deinit();

    {
        const name = "running";
        const run: *Node = try RunUntilSuccess.create(alloc, ctx, name);
        defer run.deinit(alloc);

        try std.testing.expectEqualStrings(run.name, name);

        const s1 = try AlwaysRunning.create(alloc, ctx, "running-1");
        run.data.decorator.child = s1;
        try std.testing.expectEqual(.running, run.tick());

        run.halt();
        try std.testing.expectEqual(.idle, run.data.decorator.child.status);
    }

    {
        const name = "failure";
        var run = try RunUntilSuccess.create(alloc, ctx, name);
        defer run.deinit(alloc);

        try std.testing.expectEqualStrings(run.name, name);

        const s1 = try AlwaysFailure.create(alloc, ctx, "failure-1");
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
        const run = try RunUntilSuccess.create(alloc, ctx, name);
        defer run.deinit(alloc);

        try std.testing.expectEqualStrings(run.name, name);

        const s1 = try AlwaysSuccess.create(alloc, ctx, "success-1");
        run.data.decorator.child = s1;
        try std.testing.expectEqual(.success, run.tick());

        run.halt();
        try std.testing.expectEqual(.idle, run.data.decorator.child.status);
    }
}
