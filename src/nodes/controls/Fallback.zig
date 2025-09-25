//! A Fallback node ticks each of its children in series, one child per tick,
//! advancing to the next child only if the previous child returned Failure.
//! If any child returns Success, the Sequence returns Success.
const Fallback = @This();

node: Node,
current_child: usize = 0,

pub fn tick(node: *Node) Node.Status {
    const fb: *Fallback = @alignCast(@fieldParentPtr("node", node));
    var control = node.data.control;

    if (fb.current_child >= control.numChildren()) return .failure;

    // Tick the current child, then handle the result
    const child_status = control.getChild(fb.current_child).tick();

    switch (child_status) {
        .failure => fb.current_child += 1,
        .running, .success => return child_status,
        .idle => {
            std.debug.print("ERROR: Nodes are not allowed to return IDLE\n", .{});
            return .failure;
        },
    }

    if (fb.current_child == control.numChildren())
        return .failure;

    return .running;
}

/// Halt the node and all of its children
pub fn halt(node: *Node) void {
    const fb: *Fallback = @alignCast(@fieldParentPtr("node", node));
    fb.node.data.control.halt();
    fb.current_child = 0;
}

/// Initialize a new Fallback node.
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

/// Deinitialize the node and free all resources
pub fn deinit(node: *Node, alloc: Allocator) void {
    const fb: *Fallback = @alignCast(@fieldParentPtr("node", node));
    alloc.destroy(fb);
}

const Node = @import("../../Node.zig");
const Context = @import("../../Context.zig");

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

    var ctx = try Context.create(alloc, null);
    defer ctx.deinit();

    const name = "run-to-failure";
    const fb: *Node = try Fallback.create(alloc, ctx, name);
    defer fb.deinit(alloc);

    try std.testing.expectEqualStrings(fb.name, name);

    // Create a few child nodes to add to the Fallback
    const f1 = try AlwaysFailure.create(alloc, ctx, "failure-1");
    const f2 = try AlwaysFailure.create(alloc, ctx, "failure-2");
    const s1 = try AlwaysSuccess.create(alloc, ctx, "success-1");

    try fb.data.control.addChild(alloc, f1);
    try fb.data.control.addChild(alloc, f2);
    try fb.data.control.addChild(alloc, s1);

    // We should be able to tick the Fallback 3 times, return Running, Running, Success
    try std.testing.expectEqual(.running, fb.tick());
    try std.testing.expectEqual(.running, fb.tick());
    try std.testing.expectEqual(.success, fb.tick());
}

test "[Fallback] run to failure" {
    const alloc = std.testing.allocator;
    const AlwaysFailure = @import("../conditions/AlwaysFailure.zig");

    var ctx = try Context.create(alloc, null);
    defer ctx.deinit();

    const name = "run-to-success";
    const fb: *Node = try Fallback.create(alloc, ctx, name);
    defer fb.deinit(alloc);

    try std.testing.expectEqualStrings(fb.name, name);

    // Create a few child nodes to add to the Fallback
    const f1 = try AlwaysFailure.create(alloc, ctx, "failure-1");
    const f2 = try AlwaysFailure.create(alloc, ctx, "failure-2");
    const f3 = try AlwaysFailure.create(alloc, ctx, "failure-3");

    try fb.data.control.addChild(alloc, f1);
    try fb.data.control.addChild(alloc, f2);
    try fb.data.control.addChild(alloc, f3);

    // We should be able to tick the Fallback 3 times, return Running, Running, Failure
    try std.testing.expectEqual(.running, fb.tick());
    try std.testing.expectEqual(.running, fb.tick());
    try std.testing.expectEqual(.failure, fb.tick());
}
