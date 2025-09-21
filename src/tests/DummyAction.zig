const DummyAction = @This();

action: StatefulAction,
tick_count: usize = 0,

pub fn onStarted(action: *StatefulAction) Node.Status {
    _ = action;
    std.debug.print("Starting myself!\n", .{});
    return .running;
}

pub fn onRunning(action: *StatefulAction) Node.Status {
    var dummy: *DummyAction = @alignCast(@fieldParentPtr("action", action));

    if (dummy.tick_count >= 2) return .success;
    dummy.tick_count += 1;
    std.debug.print("Tick count: {d}\n", .{dummy.tick_count});
    return .running;
}

pub fn onHalted(action: *StatefulAction) void {
    _ = action;
    std.debug.print("Halting myself!\n", .{});
}

pub fn init(alloc: Allocator, name: []const u8) !DummyAction {
    return .{
        .action = try .init(alloc, name, .{
            .onStarted = onStarted,
            .onHalted = onHalted,
            .onRunning = onRunning,
        }),
    };
}

const bonzai = @import("bonzai");
const StatefulAction = bonzai.nodes.StatefulAction;
const Node = bonzai.Node;

const std = @import("std");
const Allocator = std.mem.Allocator;

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

test "[DummyAction] run to success" {
    const alloc = std.testing.allocator;

    const name = "run-to-failure";
    var dummy = try DummyAction.init(alloc, name);
    defer dummy.action.node.deinit(alloc);

    try std.testing.expectEqualStrings(dummy.action.node.name, name);

    // We should be able to tick the DummyAction 4 times:
    // - The first tick calls onStarted()
    // - Subsequent ticks call onRunning()
    //   - This function should return Running, Running, Success
    try std.testing.expectEqual(.running, dummy.action.node.tick());
    try std.testing.expectEqual(.running, dummy.action.node.tick());
    try std.testing.expectEqual(.running, dummy.action.node.tick());
    try std.testing.expectEqual(.success, dummy.action.node.tick());

    dummy.action.node.halt();

    try std.testing.expectEqual(.idle, dummy.action.node.status);
}
