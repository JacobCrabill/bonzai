//! An Inverter simply inverts the return value of its child
const Inverter = @This();

node: Node,

pub fn tick(node: *Node) Node.Status {
    const result = node.data.decorator.child.tick();
    return switch (result) {
        .running => .running,
        .success => .failure,
        .failure => .success,
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
        const inv: *Node = try Inverter.create(alloc, name);
        defer inv.deinit(alloc);

        try std.testing.expectEqualStrings(inv.name, name);

        const s1 = try AlwaysRunning.create(alloc, "running-1");
        inv.data.decorator.child = s1;
        try std.testing.expectEqual(.running, inv.tick());

        inv.halt();
        try std.testing.expectEqual(.idle, inv.data.decorator.child.status);
    }

    {
        const name = "failure";
        const inv: *Node = try Inverter.create(alloc, name);
        defer inv.deinit(alloc);

        try std.testing.expectEqualStrings(inv.name, name);

        const s1 = try AlwaysSuccess.create(alloc, "success-1");
        inv.data.decorator.child = s1;
        try std.testing.expectEqual(.failure, inv.tick());

        inv.halt();
        try std.testing.expectEqual(.idle, inv.data.decorator.child.status);
    }

    {
        const name = "success";
        const inv = try Inverter.create(alloc, name);
        defer inv.deinit(alloc);

        try std.testing.expectEqualStrings(inv.name, name);

        const s1 = try AlwaysFailure.create(alloc, "failure-1");
        inv.data.decorator.child = s1;
        try std.testing.expectEqual(.success, inv.tick());

        inv.halt();
        try std.testing.expectEqual(.idle, inv.data.decorator.child.status);
    }
}
