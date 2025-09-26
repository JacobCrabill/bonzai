//! The DummyAction runs for 3 ticks then returns Success (See the test).
//!
//! It "derives" from the StatefulAction node and hence implements the onStarted,
//! onRunning, onHalted, etc. methods.
const DummyAction = @This();
const CustomContext = @import("CustomContext.zig");

action: StatefulAction,
tick_count: usize = 0,
max_ticks: usize = 2,

pub fn onStarted(action: *StatefulAction) Node.Status {
    std.debug.print("Starting myself!\n", .{});
    var dummy = StatefulAction.cast(&action.node, DummyAction);
    dummy.tick_count = 0;

    // Access the custom contextual data
    if (action.node.context.data) |data_ptr| {
        const ctx: *CustomContext = @ptrCast(@alignCast(data_ptr));
        dummy.max_ticks = ctx.num_ticks;
        std.debug.print("{s}\n", .{ctx.some_other_data});
    }

    std.debug.print("Private blackboard values:\n", .{});
    var iter = action.node.blackboard.iterator();
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

pub fn onRunning(action: *StatefulAction) Node.Status {
    var dummy = StatefulAction.cast(&action.node, DummyAction);

    if (dummy.tick_count >= 2) return .success;
    dummy.tick_count += 1;
    std.debug.print("Tick count: {d}\n", .{dummy.tick_count});
    return .running;
}

pub fn onHalted(_: *StatefulAction) void {
    std.debug.print("Halting myself!\n", .{});
}

pub fn init(self: *@This(), alloc: Allocator, ctx: *Context, name: []const u8) !void {
    self.tick_count = 0;
    try self.action.init(alloc, ctx, name, .{
        .onStarted = onStarted,
        .onHalted = onHalted,
        .onRunning = onRunning,
        .deinit = deinit,
    });
}

/// Destroy this node instance
pub fn deinit(action: *StatefulAction, alloc: Allocator) void {
    const self: *@This() = @alignCast(@fieldParentPtr("action", action));
    alloc.destroy(self);
}

/// Create an instance of this node type
pub fn create(alloc: Allocator, ctx: *Context, name: []const u8) anyerror!*Node {
    var node = try alloc.create(@This());
    try node.init(alloc, ctx, name);
    return &node.action.node;
}

const bonzai = @import("bonzai");
const StatefulAction = bonzai.nodes.actions.StatefulAction;
const Node = bonzai.Node;
const Context = bonzai.Context;

const std = @import("std");
const Allocator = std.mem.Allocator;

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

test "[DummyAction] run to success" {
    const alloc = std.testing.allocator;

    var ctx = try Context.create(alloc, null);
    defer ctx.deinit();

    const name = "run-to-failure";
    const dummy: *Node = try DummyAction.create(alloc, ctx, name);
    defer dummy.deinit(alloc);

    // Example of "casting" the base Node pointer to the derived DummyAction pointer
    const d: *DummyAction = StatefulAction.cast(dummy, DummyAction);
    _ = d;

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

    dummy.halt();

    try std.testing.expectEqual(.idle, dummy.status);

    // Ensure that it resets as expected
    try std.testing.expectEqual(.running, dummy.tick());
    try std.testing.expectEqual(.running, dummy.tick());
    try std.testing.expectEqual(.running, dummy.tick());
    try std.testing.expectEqual(.success, dummy.tick());
}
