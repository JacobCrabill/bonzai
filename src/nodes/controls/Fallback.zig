//! A Fallback node ticks each of its children in series, one child per tick,
//! advancing to the next child only if the previous child returned Failure.
//! If any child returns Success, the Fallback returns Success.
const Fallback = @This();

pub const kind: Node.Kind = .control;

current_child: usize = 0,

pub fn tick(fb: *Fallback, node: *Node) Node.Status {
    const control = &node.data.control;

    if (fb.current_child >= control.numChildren()) return .failure;

    while (fb.current_child < control.numChildren()) {
        const child_status = control.getChild(fb.current_child).tick();
        switch (child_status) {
            .failure => fb.current_child += 1,
            .running, .success => return child_status,
            .idle => {
                log.err("Node '{s}' returned Idle from tick()", .{control.getChild(fb.current_child).name});
                return .failure;
            },
        }
    }

    if (fb.current_child == control.numChildren()) {
        fb.halt(node);
        return .failure;
    }

    return .running;
}

/// Reset to the first child (children are halted automatically)
pub fn halt(fb: *Fallback, node: *Node) void {
    fb.current_child = 0;
    node.data.control.halt();
}

const Node = @import("../../Node.zig");
const Context = @import("../../Context.zig");
const NodeImpl = @import("../../node_impl.zig").NodeImpl;

const std = @import("std");
const log = std.log.scoped(.bonzai);

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

test "[Fallback] run to success" {
    const alloc = std.testing.allocator;
    const AlwaysSuccess = @import("../conditions/AlwaysSuccess.zig");
    const AlwaysFailure = @import("../conditions/AlwaysFailure.zig");

    var ctx = try Context.create(std.testing.io, alloc);
    defer ctx.deinit();

    const name = "run-to-success";
    const fb: *Node = try NodeImpl(Fallback).create(alloc, ctx, name);
    defer fb.deinit(alloc);

    try std.testing.expectEqualStrings(fb.name, name);

    // Create a few child nodes to add to the Fallback
    const f1 = try NodeImpl(AlwaysFailure).create(alloc, ctx, "failure-1");
    const f2 = try NodeImpl(AlwaysFailure).create(alloc, ctx, "failure-2");
    const s1 = try NodeImpl(AlwaysSuccess).create(alloc, ctx, "success-1");

    try fb.data.control.addChild(alloc, f1);
    try fb.data.control.addChild(alloc, f2);
    try fb.data.control.addChild(alloc, s1);

    try std.testing.expectEqual(.success, fb.tick());
}

test "[Fallback] run to failure" {
    const alloc = std.testing.allocator;
    const AlwaysFailure = @import("../conditions/AlwaysFailure.zig");

    var ctx = try Context.create(std.testing.io, alloc);
    defer ctx.deinit();

    const name = "run-to-failure";
    const fb: *Node = try NodeImpl(Fallback).create(alloc, ctx, name);
    defer fb.deinit(alloc);

    try std.testing.expectEqualStrings(fb.name, name);

    // Create a few child nodes to add to the Fallback
    const f1 = try NodeImpl(AlwaysFailure).create(alloc, ctx, "failure-1");
    const f2 = try NodeImpl(AlwaysFailure).create(alloc, ctx, "failure-2");
    const f3 = try NodeImpl(AlwaysFailure).create(alloc, ctx, "failure-3");

    try fb.data.control.addChild(alloc, f1);
    try fb.data.control.addChild(alloc, f2);
    try fb.data.control.addChild(alloc, f3);

    try std.testing.expectEqual(.failure, fb.tick());
}
