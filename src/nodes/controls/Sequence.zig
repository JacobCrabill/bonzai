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
pub fn init(alloc: Allocator, name: []const u8) !Sequence {
    return .{
        .node = try .init(alloc, name, .control, .{
            .tick = tick,
            .halt = halt,
        }),
    };
}

/// Deinit and destroy the Sequence instance
pub fn deinit(node: *Node, alloc: Allocator) void {
    const seq: *Sequence = @alignCast(@fieldParentPtr("node", node));
    alloc.destroy(seq);
}

/// Create a new Sequence node, returning the base Node pointer
pub fn create(alloc: Allocator, name: []const u8) anyerror!*Node {
    var node = try alloc.create(Sequence);
    node.node = try .init(alloc, name, .control, .{
        .tick = tick,
        .halt = halt,
        .deinit = deinit,
    });
    return &node.node;
}

const Node = @import("../../Node.zig");
const Control = @import("../../base_types/Control.zig");

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

    const name = "run-to-failure";
    var seq = try Sequence.init(alloc, name);
    defer seq.node.deinit(alloc);

    try std.testing.expectEqualStrings(seq.node.name, name);

    // Create a few child nodes to add to the Sequence
    var s1 = try AlwaysSuccess.init(alloc, "success-1");
    var s2 = try AlwaysSuccess.init(alloc, "success-2");
    var f1 = try AlwaysFailure.init(alloc, "failure-1");

    try seq.node.data.control.addChild(alloc, &s1.node);
    try seq.node.data.control.addChild(alloc, &s2.node);
    try seq.node.data.control.addChild(alloc, &f1.node);

    // We should be able to tick the Sequence 3 times, return Running, Running, Failure
    try std.testing.expectEqual(.running, seq.node.tick());
    try std.testing.expectEqual(.running, seq.node.tick());
    try std.testing.expectEqual(.failure, seq.node.tick());
}

test "[Sequence] run to success" {
    const alloc = std.testing.allocator;
    const AlwaysSuccess = @import("../conditions/AlwaysSuccess.zig");

    const name = "run-to-success";
    var seq = try Sequence.init(alloc, name);
    defer seq.node.deinit(alloc);

    try std.testing.expectEqualStrings(seq.node.name, name);

    // Create a few child nodes to add to the Sequence
    var s1 = try AlwaysSuccess.init(alloc, "success-1");
    var s2 = try AlwaysSuccess.init(alloc, "success-2");
    var s3 = try AlwaysSuccess.init(alloc, "success-3");

    try seq.node.data.control.addChild(alloc, &s1.node);
    try seq.node.data.control.addChild(alloc, &s2.node);
    try seq.node.data.control.addChild(alloc, &s3.node);

    // We should be able to tick the Sequence 3 times, return Running, Running, Failure
    try std.testing.expectEqual(.running, seq.node.tick());
    try std.testing.expectEqual(.running, seq.node.tick());
    try std.testing.expectEqual(.success, seq.node.tick());
}
