//! An Inverter simply inverts the return value of its child
const Inverter = @This();

node: Node,
child: *Node,

pub fn tick(node: *Node) Node.Status {
    const inverter: *Inverter = @alignCast(@fieldParentPtr("node", node));

    const result = inverter.child.tick();
    return switch (result) {
        .running => .running,
        .success => .failure,
        .failure => .success,
        .idle => @panic("Nodes may not return 'idle' from tick()!"),
    };
}

pub fn halt(node: *Node) void {
    const inverter: *Inverter = @alignCast(@fieldParentPtr("node", node));
    inverter.child.halt();
}

pub fn deinit(node: *Node, alloc: Allocator) void {
    const inverter: *Inverter = @alignCast(@fieldParentPtr("node", node));
    inverter.child.deinit(alloc);
}

pub fn init(alloc: Allocator, name: []const u8) !Inverter {
    return .{
        .child = undefined,
        .node = try .init(alloc, name, .decorator, .{
            .tick = tick,
            .deinit = deinit,
            .halt = halt,
        }),
    };
}

const Node = @import("../../Node.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

test "[Inverter] basics" {
    const alloc = std.testing.allocator;
    const AlwaysRunning = @import("../actions/AlwaysRunning.zig");
    const AlwaysSuccess = @import("../conditions/AlwaysSuccess.zig");
    const AlwaysFailure = @import("../conditions/AlwaysFailure.zig");

    {
        const name = "running";
        var inv = try Inverter.init(alloc, name);
        defer inv.node.deinit(alloc);

        try std.testing.expectEqualStrings(inv.node.name, name);

        var s1 = try AlwaysRunning.init("running-1", alloc);
        inv.child = &s1.node;
        try std.testing.expectEqual(.running, inv.node.tick());

        inv.node.halt();
        try std.testing.expectEqual(.idle, inv.child.status);
    }

    {
        const name = "failure";
        var inv = try Inverter.init(alloc, name);
        defer inv.node.deinit(alloc);

        try std.testing.expectEqualStrings(inv.node.name, name);

        var s1 = try AlwaysSuccess.init("success-1", alloc);
        inv.child = &s1.node;
        try std.testing.expectEqual(.failure, inv.node.tick());

        inv.node.halt();
        try std.testing.expectEqual(.idle, inv.child.status);
    }

    {
        const name = "success";
        var inv = try Inverter.init(alloc, name);
        defer inv.node.deinit(alloc);

        try std.testing.expectEqualStrings(inv.node.name, name);

        var s1 = try AlwaysFailure.init("failure-1", alloc);
        inv.child = &s1.node;
        try std.testing.expectEqual(.success, inv.node.tick());

        inv.node.halt();
        try std.testing.expectEqual(.idle, inv.child.status);
    }
}
