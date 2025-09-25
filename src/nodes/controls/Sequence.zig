//! A Sequence node ticks each of its children in series, one child per tick,
//! advancing to the next child only if the previous child returned Success.
//! If any child returns Failure, the Sequence returns Failure.
const Sequence = @This();

node: Node,
current_child: usize = 0,

pub fn tick(node: *Node) Node.Status {
    const seq: *Sequence = @alignCast(@fieldParentPtr("node", node));
    var control = node.data.control;

    if (seq.current_child >= control.numChildren()) return .failure;

    // Tick the current child, then handle the result
    const child_status = control.getChild(seq.current_child).tick();

    switch (child_status) {
        .success => seq.current_child += 1,
        .running, .failure => return child_status,
        .idle => {
            std.debug.print("ERROR: Nodes are not allowed to return IDLE\n", .{});
            return .failure;
        },
    }

    if (seq.current_child == control.numChildren())
        return .success;

    return .running;
}

/// Halt the node and all of its children
pub fn halt(node: *Node) void {
    const seq: *Sequence = @alignCast(@fieldParentPtr("node", node));
    seq.current_child = 0;
}

/// Initialize a new Sequence node.
pub fn init(self: *@This(), alloc: Allocator, ctx: *Context, name: []const u8) !void {
    self.current_child = 0;
    self.node = try .init(alloc, ctx, name, .control, .{
        .tick = tick,
        .halt = halt,
        .deinit = deinit,
    });
}

/// Create a new Sequence node, returning the base Node pointer
pub fn create(alloc: Allocator, ctx: *Context, name: []const u8) anyerror!*Node {
    var node = try alloc.create(@This());
    try node.init(alloc, ctx, name);
    return &node.node;
}

/// Deinit and destroy the Sequence instance
pub fn deinit(node: *Node, alloc: Allocator) void {
    const self: *@This() = @alignCast(@fieldParentPtr("node", node));
    alloc.destroy(self);
}

const Node = @import("../../Node.zig");
const Context = @import("../../Context.zig");

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

test "[Sequence] run to failure" {
    const alloc = std.testing.allocator;
    const AlwaysSuccess = @import("../conditions/AlwaysSuccess.zig");
    const AlwaysFailure = @import("../conditions/AlwaysFailure.zig");

    var ctx = try Context.create(alloc, null);
    defer ctx.deinit();

    const name = "run-to-failure";
    const seq: *Node = try Sequence.create(alloc, ctx, name);
    defer seq.deinit(alloc);

    try std.testing.expectEqualStrings(seq.name, name);

    // Create a few child nodes to add to the Sequence
    const s1 = try AlwaysSuccess.create(alloc, ctx, "success-1");
    const s2 = try AlwaysSuccess.create(alloc, ctx, "success-2");
    const f1 = try AlwaysFailure.create(alloc, ctx, "failure-1");

    try seq.data.control.addChild(alloc, s1);
    try seq.data.control.addChild(alloc, s2);
    try seq.data.control.addChild(alloc, f1);

    // We should be able to tick the Sequence 3 times, return Running, Running, Failure
    try std.testing.expectEqual(.running, seq.tick());
    try std.testing.expectEqual(.running, seq.tick());
    try std.testing.expectEqual(.failure, seq.tick());
}

test "[Sequence] run to success" {
    const alloc = std.testing.allocator;
    const AlwaysSuccess = @import("../conditions/AlwaysSuccess.zig");

    var ctx = try Context.create(alloc, null);
    defer ctx.deinit();

    const name = "run-to-success";
    const seq: *Node = try Sequence.create(alloc, ctx, name);
    defer seq.deinit(alloc);

    try std.testing.expectEqualStrings(seq.name, name);

    // Create a few child nodes to add to the Sequence
    const s1 = try AlwaysSuccess.create(alloc, ctx, "success-1");
    const s2 = try AlwaysSuccess.create(alloc, ctx, "success-2");
    const s3 = try AlwaysSuccess.create(alloc, ctx, "success-3");

    try seq.data.control.addChild(alloc, s1);
    try seq.data.control.addChild(alloc, s2);
    try seq.data.control.addChild(alloc, s3);

    // We should be able to tick the Sequence 3 times, return Running, Running, Failure
    try std.testing.expectEqual(.running, seq.tick());
    try std.testing.expectEqual(.running, seq.tick());
    try std.testing.expectEqual(.success, seq.tick());
}
