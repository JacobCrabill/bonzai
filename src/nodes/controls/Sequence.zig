//! A Sequence node ticks each of its children in series, one child per tick,
//! advancing to the next child only if the previous child returned Success.
//! If any child returns Failure, the Sequence returns Failure.
const Sequence = @This();

pub const kind: Node.Kind = .control;

current_child: usize = 0,

pub fn tick(seq: *Sequence, node: *Node) Node.Status {
    const control = &node.data.control;

    if (seq.current_child >= control.numChildren()) return .failure;

    while (seq.current_child < control.numChildren()) {
        const child_status = control.getChild(seq.current_child).tick();
        switch (child_status) {
            .success => seq.current_child += 1,
            .running, .failure => return child_status,
            .idle => {
                log.err("Node '{s}' returned Idle from tick()", .{control.getChild(seq.current_child).name});
                return .failure;
            },
        }
    }

    if (seq.current_child == control.numChildren()) {
        seq.halt(node);
        return .success;
    }

    return .running;
}

/// Reset to the first child (children are halted automatically)
pub fn halt(seq: *Sequence, node: *Node) void {
    seq.current_child = 0;
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

test "[Sequence] run to failure" {
    const alloc = std.testing.allocator;
    const AlwaysSuccess = @import("../conditions/AlwaysSuccess.zig");
    const AlwaysFailure = @import("../conditions/AlwaysFailure.zig");

    var ctx = try Context.create(std.testing.io, alloc);
    defer ctx.deinit();

    const name = "run-to-failure";
    const seq: *Node = try NodeImpl(Sequence).create(alloc, ctx, name);
    defer seq.deinit(alloc);

    try std.testing.expectEqualStrings(seq.name, name);

    // Create a few child nodes to add to the Sequence
    const s1 = try NodeImpl(AlwaysSuccess).create(alloc, ctx, "success-1");
    const s2 = try NodeImpl(AlwaysSuccess).create(alloc, ctx, "success-2");
    const f1 = try NodeImpl(AlwaysFailure).create(alloc, ctx, "failure-1");

    try seq.data.control.addChild(alloc, s1);
    try seq.data.control.addChild(alloc, s2);
    try seq.data.control.addChild(alloc, f1);

    try std.testing.expectEqual(.failure, seq.tick());
}

test "[Sequence] run to success" {
    const alloc = std.testing.allocator;
    const AlwaysSuccess = @import("../conditions/AlwaysSuccess.zig");

    var ctx = try Context.create(std.testing.io, alloc);
    defer ctx.deinit();

    const name = "run-to-success";
    const seq: *Node = try NodeImpl(Sequence).create(alloc, ctx, name);
    defer seq.deinit(alloc);

    try std.testing.expectEqualStrings(seq.name, name);

    // Create a few child nodes to add to the Sequence
    const s1 = try NodeImpl(AlwaysSuccess).create(alloc, ctx, "success-1");
    const s2 = try NodeImpl(AlwaysSuccess).create(alloc, ctx, "success-2");
    const s3 = try NodeImpl(AlwaysSuccess).create(alloc, ctx, "success-3");

    try seq.data.control.addChild(alloc, s1);
    try seq.data.control.addChild(alloc, s2);
    try seq.data.control.addChild(alloc, s3);

    try std.testing.expectEqual(.success, seq.tick());
}
