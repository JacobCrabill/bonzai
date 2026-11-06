//! The DummyAction runs for `max_ticks` ticks then returns Success (See the tests).
//!
//! It is a "stateful" Action: instead of a single `tick` method, it implements the
//! onStarted, onRunning, and onHalted hooks, which `bonzai.NodeImpl` dispatches to
//! based on the node's current status. It also implements `configure` to read its
//! parameters once, when the tree is loaded.
const DummyAction = @This();
const CustomContext = @import("CustomContext.zig");

pub const kind: Node.Kind = .action;

tick_count: usize = 0,
max_ticks: usize = 2,

/// Called once after the node is created and its params are loaded.
/// `max_ticks` comes from the "max_ticks" param if given, else from the Context's
/// CustomContext data, else the default.
pub fn configure(self: *DummyAction, node: *Node) !void {
    if (try node.getParam(usize, "max_ticks")) |max_ticks| {
        self.max_ticks = max_ticks;
    } else if (node.context.getData(CustomContext)) |ctx| {
        self.max_ticks = ctx.num_ticks;
    }
    if (self.max_ticks == 0) return error.InvalidMaxTicks;

    std.debug.print("Configured '{s}' with max_ticks = {d}\n", .{ node.name, self.max_ticks });
}

/// Called on the first tick after being Idle
pub fn onStarted(self: *DummyAction, node: *Node) Node.Status {
    std.debug.print("Starting myself!\n", .{});
    self.tick_count = 1;

    // Access the custom contextual data
    if (node.context.getData(CustomContext)) |ctx| {
        std.debug.print("Found CustomContext data: {s}\n", .{ctx.some_other_data});
    }

    std.debug.print("Private blackboard values:\n", .{});
    var iter = node.blackboard.iterator();
    while (iter.next()) |elem| {
        const key = elem.key_ptr.*;
        switch (elem.value_ptr.*) {
            .string => |s| std.debug.print("  {s}: {s}\n", .{ key, s }),
            .float => |f| std.debug.print("  {s}: {d}\n", .{ key, f }),
            .int => |i| std.debug.print("  {s}: {d}\n", .{ key, i }),
            .bool => |b| std.debug.print("  {s}: {any}\n", .{ key, b }),
        }
    }
    return if (self.tick_count >= self.max_ticks) .success else .running;
}

/// Called on every subsequent tick while Running
pub fn onRunning(self: *DummyAction) Node.Status {
    self.tick_count += 1;
    std.debug.print("Tick count: {d}\n", .{self.tick_count});
    return if (self.tick_count >= self.max_ticks) .success else .running;
}

/// Called when halted while Running (or after completing)
pub fn onHalted(_: *DummyAction) void {
    std.debug.print("Halting myself!\n", .{});
}

const bonzai = @import("bonzai");
const Node = bonzai.Node;
const Context = bonzai.Context;

const std = @import("std");

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

test "[DummyAction] run to success" {
    const alloc = std.testing.allocator;

    var ctx = try Context.create(alloc);
    defer ctx.deinit();

    const name = "run-to-success";
    const dummy: *Node = try bonzai.NodeImpl(DummyAction).create(alloc, ctx, name);
    defer dummy.deinit(alloc);

    // "Cast" the base Node pointer to the DummyAction implementation, and back
    const d: *DummyAction = dummy.as(DummyAction);
    try std.testing.expectEqual(dummy, bonzai.nodeOf(d));

    try std.testing.expectEqualStrings(dummy.name, name);

    // When creating nodes manually (rather than via the Factory), set any params
    // and then call configure() yourself
    try dummy.putValue("max_ticks", .{ .int = 4 });
    try dummy.configure();
    try std.testing.expectEqual(@as(usize, 4), d.max_ticks);

    // We should be able to tick the DummyAction 4 times:
    // - The first tick calls onStarted(), which returns Running
    // - Subsequent ticks call onRunning(), which returns Running, Running, Success
    try std.testing.expectEqual(.running, dummy.tick());
    try std.testing.expectEqual(.running, dummy.tick());
    try std.testing.expectEqual(.running, dummy.tick());
    try std.testing.expectEqual(.success, dummy.tick());
    try std.testing.expectEqual(@as(usize, 4), d.tick_count);

    dummy.halt();

    try std.testing.expectEqual(.idle, dummy.status);

    // Ensure that it resets as expected
    try std.testing.expectEqual(.running, dummy.tick());
    try std.testing.expectEqual(.running, dummy.tick());
    try std.testing.expectEqual(.running, dummy.tick());
    try std.testing.expectEqual(.success, dummy.tick());
}

test "[DummyAction] invalid max_ticks param" {
    const alloc = std.testing.allocator;

    var ctx = try Context.create(alloc);
    defer ctx.deinit();

    const dummy: *Node = try bonzai.NodeImpl(DummyAction).create(alloc, ctx, "bad");
    defer dummy.deinit(alloc);

    try dummy.putValue("max_ticks", .{ .int = 0 });
    try std.testing.expectError(error.InvalidMaxTicks, dummy.configure());

    try dummy.putValue("max_ticks", .{ .int = -3 });
    try std.testing.expectError(error.ParamOutOfRange, dummy.configure());
}
