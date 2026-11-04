//! The DummyAction runs for 4 ticks then returns Success (See the test).
//!
//! It is a "stateful" Action: instead of a single `tick` method, it implements the
//! onStarted, onRunning, and onHalted hooks, which `bonzai.NodeImpl` dispatches to
//! based on the node's current status.
const DummyAction = @This();
const CustomContext = @import("CustomContext.zig");

pub const kind: Node.Kind = .action;

tick_count: usize = 0,
max_ticks: usize = 2,

/// Called on the first tick after being Idle
pub fn onStarted(self: *DummyAction, node: *Node) Node.Status {
    std.debug.print("Starting myself!\n", .{});
    self.tick_count = 0;

    // Access the custom contextual data
    if (node.context.data) |data_ptr| {
        std.debug.print("context.data is not null; casting to CustomContext\n", .{});
        const ctx: *CustomContext = @ptrCast(@alignCast(data_ptr));
        self.max_ticks = ctx.num_ticks;
        std.debug.print("{s}\n", .{ctx.some_other_data});
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
    return .running;
}

/// Called on every subsequent tick while Running
pub fn onRunning(self: *DummyAction) Node.Status {
    if (self.tick_count >= 2) return .success;
    self.tick_count += 1;
    std.debug.print("Tick count: {d}\n", .{self.tick_count});
    return .running;
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

    // We should be able to tick the DummyAction 4 times:
    // - The first tick calls onStarted()
    //   - This returns Running
    // - Subsequent ticks call onRunning()
    //   - This function should return Running, Running, Success
    try std.testing.expectEqual(.running, dummy.tick());
    try std.testing.expectEqual(.running, dummy.tick());
    try std.testing.expectEqual(.running, dummy.tick());
    try std.testing.expectEqual(.success, dummy.tick());
    try std.testing.expectEqual(@as(usize, 2), d.tick_count);

    dummy.halt();

    try std.testing.expectEqual(.idle, dummy.status);

    // Ensure that it resets as expected
    try std.testing.expectEqual(.running, dummy.tick());
    try std.testing.expectEqual(.running, dummy.tick());
    try std.testing.expectEqual(.running, dummy.tick());
    try std.testing.expectEqual(.success, dummy.tick());
}
