//! A RunUntilSuccess ticks its child forever until it returns Success
const RunUntilSuccess = @This();

pub const kind: Node.Kind = .decorator;

pub fn tick(_: *RunUntilSuccess, node: *Node) Node.Status {
    return switch (node.data.decorator.tick()) {
        .success => .success,
        .running => .running,
        .failure => blk: {
            node.data.decorator.halt();
            break :blk .running;
        },
        .idle => @panic("Nodes may not return 'idle' from tick()!"),
    };
}

const Node = @import("../../Node.zig");
const Context = @import("../../Context.zig");
const NodeImpl = @import("../../node_impl.zig").NodeImpl;

const std = @import("std");

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

test "[RunUntilSuccess] basics" {
    const alloc = std.testing.allocator;
    const AlwaysRunning = @import("../actions/AlwaysRunning.zig");
    const AlwaysSuccess = @import("../conditions/AlwaysSuccess.zig");
    const AlwaysFailure = @import("../conditions/AlwaysFailure.zig");

    var ctx = try Context.create(std.testing.io, alloc);
    defer ctx.deinit();

    {
        const name = "running";
        const run: *Node = try NodeImpl(RunUntilSuccess).create(alloc, ctx, name);
        defer run.deinit(alloc);

        try std.testing.expectEqualStrings(run.name, name);

        const s1 = try NodeImpl(AlwaysRunning).create(alloc, ctx, "running-1");
        run.data.decorator.child = s1;
        try std.testing.expectEqual(.running, run.tick());

        run.halt();
        try std.testing.expectEqual(.idle, run.data.decorator.child.?.status);
    }

    {
        const name = "failure";
        var run = try NodeImpl(RunUntilSuccess).create(alloc, ctx, name);
        defer run.deinit(alloc);

        try std.testing.expectEqualStrings(run.name, name);

        const s1 = try NodeImpl(AlwaysFailure).create(alloc, ctx, "failure-1");
        run.data.decorator.child = s1;
        try std.testing.expectEqual(.running, run.tick());
        try std.testing.expectEqual(.running, run.tick());
        try std.testing.expectEqual(.running, run.tick());
        try std.testing.expectEqual(.running, run.tick());
        // ...we could keep going here forever

        run.halt();
        try std.testing.expectEqual(.idle, run.data.decorator.child.?.status);
    }

    {
        const name = "success";
        const run = try NodeImpl(RunUntilSuccess).create(alloc, ctx, name);
        defer run.deinit(alloc);

        try std.testing.expectEqualStrings(run.name, name);

        const s1 = try NodeImpl(AlwaysSuccess).create(alloc, ctx, "success-1");
        run.data.decorator.child = s1;
        try std.testing.expectEqual(.success, run.tick());

        run.halt();
        try std.testing.expectEqual(.idle, run.data.decorator.child.?.status);
    }
}
