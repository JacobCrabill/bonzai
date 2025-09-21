//! A Fallback node ticks each of its children in series, one child per tick,
//! advancing to the next child only if the previous child returned Failure.
//! If any child returns Success, the Sequence returns Success.
const Fallback = @This();

control: Control,
node: Node,
current_child: usize = 0,

pub fn tick(node: *Node) Node.Status {
    const fb: *Fallback = @alignCast(@fieldParentPtr("node", node));

    if (fb.current_child >= fb.control.numChildren()) return .failure;

    // Tick the current child, then handle the result
    const child_status = fb.control.getChild(fb.current_child).tick();

    switch (child_status) {
        .failure => fb.current_child += 1,
        .running, .success => return child_status,
        .idle => {
            std.debug.print("ERROR: Nodes are not allowed to return IDLE\n", .{});
            return .failure;
        },
    }

    if (fb.current_child == fb.control.numChildren())
        return .failure;

    return .running;
}

/// Halt the node and all of its children
pub fn halt(node: *Node) void {
    const fb: *Fallback = @alignCast(@fieldParentPtr("node", node));
    fb.control.halt();
    fb.current_child = 0;
}

/// Initialize a new Fallback node.
pub fn init(alloc: Allocator, name: []const u8) !Fallback {
    return .{
        .control = .{},
        .node = try .init(alloc, name, .control, .{
            .tick = tick,
            .halt = halt,
            .deinit = deinit,
        }),
    };
}

/// Deinitialize the node and free all resources
pub fn deinit(node: *Node, alloc: Allocator) void {
    const fb: *Fallback = @alignCast(@fieldParentPtr("node", node));
    fb.control.deinit(alloc);
}

const Node = @import("../../Node.zig");
const Control = @import("../../base_types/Control.zig");

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

test "[Fallback] run to success" {
    const alloc = std.testing.allocator;
    const AlwaysSuccess = @import("../conditions/AlwaysSuccess.zig");
    const AlwaysFailure = @import("../conditions/AlwaysFailure.zig");

    const name = "run-to-failure";
    var fb = try Fallback.init(alloc, name);
    defer fb.node.deinit(alloc);

    try std.testing.expectEqualStrings(fb.node.name, name);

    // Create a few child nodes to add to the Fallback
    var f1 = try AlwaysFailure.init("failure-1", alloc);
    var f2 = try AlwaysFailure.init("failure-2", alloc);
    var s1 = try AlwaysSuccess.init("success-1", alloc);

    try fb.control.addChild(alloc, &f1.node);
    try fb.control.addChild(alloc, &f2.node);
    try fb.control.addChild(alloc, &s1.node);

    // We should be able to tick the Fallback 3 times, return Running, Running, Success
    try std.testing.expectEqual(.running, fb.node.tick());
    try std.testing.expectEqual(.running, fb.node.tick());
    try std.testing.expectEqual(.success, fb.node.tick());
}

test "[Fallback] run to failure" {
    const alloc = std.testing.allocator;
    const AlwaysFailure = @import("../conditions/AlwaysFailure.zig");

    const name = "run-to-success";
    var fb = try Fallback.init(alloc, name);
    defer fb.node.deinit(alloc);

    try std.testing.expectEqualStrings(fb.node.name, name);

    // Create a few child nodes to add to the Fallback
    var f1 = try AlwaysFailure.init("failure-1", alloc);
    var f2 = try AlwaysFailure.init("failure-2", alloc);
    var f3 = try AlwaysFailure.init("failure-3", alloc);

    try fb.control.addChild(alloc, &f1.node);
    try fb.control.addChild(alloc, &f2.node);
    try fb.control.addChild(alloc, &f3.node);

    // We should be able to tick the Fallback 3 times, return Running, Running, Failure
    try std.testing.expectEqual(.running, fb.node.tick());
    try std.testing.expectEqual(.running, fb.node.tick());
    try std.testing.expectEqual(.failure, fb.node.tick());
}
