//! A Repeat node ticks its child until it has succeeded `num_cycles` times, halting
//! (resetting) the child after each success so that it starts over.
//!
//! Params:
//! - `num_cycles` (int, required): the number of times the child must succeed, or -1 to
//!   repeat forever.
//!
//! At most one cycle completes per tick: after each success (other than the last), the
//! Repeat returns Running. This guarantees that a child which succeeds immediately cannot
//! block the tree, at the cost of one tick per cycle.
//!
//! If the child fails, the Repeat returns Failure and the cycle count is reset.
const Repeat = @This();

pub const kind: Node.Kind = .decorator;

/// The number of successful cycles required; null means repeat forever
num_cycles: ?u32 = 1,

/// The number of cycles completed so far
count: u32 = 0,

pub fn configure(self: *Repeat, node: *Node) !void {
    const num_cycles = (try node.getParam(i64, "num_cycles")) orelse return error.MissingNumCycles;
    if (num_cycles == -1) {
        self.num_cycles = null;
    } else {
        if (num_cycles < 1) return error.InvalidNumCycles;
        self.num_cycles = std.math.cast(u32, num_cycles) orelse return error.InvalidNumCycles;
    }
}

pub fn tick(self: *Repeat, node: *Node) Node.Status {
    const decorator = &node.data.decorator;
    const child = decorator.child orelse return .failure;

    switch (child.tick()) {
        .running => return .running,
        .success => {
            self.count += 1;
            decorator.halt(); // reset the child for the next cycle
            if (self.num_cycles) |n| {
                if (self.count >= n) {
                    self.count = 0;
                    return .success;
                }
            }
            return .running;
        },
        .failure => {
            self.count = 0;
            decorator.halt();
            return .failure;
        },
        .idle => {
            log.err("Node '{s}' returned Idle from tick()", .{child.name});
            self.count = 0;
            decorator.halt();
            return .failure;
        },
    }
}

/// Reset the cycle count (the child is halted automatically)
pub fn halt(self: *Repeat) void {
    self.count = 0;
}

const Node = @import("../../Node.zig");
const Context = @import("../../Context.zig");
const NodeImpl = @import("../../node_impl.zig").NodeImpl;

const std = @import("std");
const log = std.log.scoped(.bonzai);

////////////////////////////////////////////////////////////////////////////////
// Tests
////////////////////////////////////////////////////////////////////////////////

const test_nodes = @import("../test_nodes.zig");
const Countdown = test_nodes.Countdown;

fn testRepeat(ctx: *Context, num_cycles: i64, child_ticks: u32, child_result: Node.Status) !*Node {
    const gpa = std.testing.allocator;
    const rep = try NodeImpl(Repeat).create(gpa, ctx, "repeat");
    errdefer rep.deinit(gpa);
    rep.data.decorator.child = try test_nodes.countdown(gpa, ctx, "child", child_ticks, child_result);
    try rep.putValue("num_cycles", .{ .int = num_cycles });
    try rep.configure();
    return rep;
}

test "[Repeat] repeats a child which succeeds immediately" {
    var ctx = try Context.create(std.testing.allocator);
    defer ctx.deinit();

    const rep = try testRepeat(ctx, 3, 1, .success);
    defer rep.deinit(std.testing.allocator);
    const child = rep.data.decorator.child.?.as(Countdown);

    try std.testing.expectEqual(.running, rep.tick());
    try std.testing.expectEqual(.running, rep.tick());
    try std.testing.expectEqual(.success, rep.tick());
    try std.testing.expectEqual(@as(u32, 3), child.total_ticks);
    try std.testing.expectEqual(.idle, rep.data.decorator.child.?.status);
}

test "[Repeat] repeats a long-running child" {
    var ctx = try Context.create(std.testing.allocator);
    defer ctx.deinit();

    const rep = try testRepeat(ctx, 2, 2, .success);
    defer rep.deinit(std.testing.allocator);

    // Each cycle takes 2 ticks
    try std.testing.expectEqual(.running, rep.tick());
    try std.testing.expectEqual(.running, rep.tick()); // cycle 1 done
    try std.testing.expectEqual(.running, rep.tick());
    try std.testing.expectEqual(.success, rep.tick()); // cycle 2 done
    try std.testing.expectEqual(@as(u32, 4), rep.data.decorator.child.?.as(Countdown).total_ticks);
}

test "[Repeat] fails when the child fails" {
    var ctx = try Context.create(std.testing.allocator);
    defer ctx.deinit();

    const rep = try testRepeat(ctx, 5, 1, .failure);
    defer rep.deinit(std.testing.allocator);

    try std.testing.expectEqual(.failure, rep.tick());
    try std.testing.expectEqual(@as(u32, 0), rep.as(Repeat).count);
    try std.testing.expectEqual(.idle, rep.data.decorator.child.?.status);
}

test "[Repeat] repeats forever" {
    var ctx = try Context.create(std.testing.allocator);
    defer ctx.deinit();

    const rep = try testRepeat(ctx, -1, 1, .success);
    defer rep.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u32, null), rep.as(Repeat).num_cycles);

    for (0..100) |_| try std.testing.expectEqual(.running, rep.tick());
    try std.testing.expectEqual(@as(u32, 100), rep.as(Repeat).count);
}

test "[Repeat] halting resets the count" {
    var ctx = try Context.create(std.testing.allocator);
    defer ctx.deinit();

    const rep = try testRepeat(ctx, 3, 1, .success);
    defer rep.deinit(std.testing.allocator);

    try std.testing.expectEqual(.running, rep.tick());
    try std.testing.expectEqual(.running, rep.tick());
    rep.halt();
    try std.testing.expectEqual(@as(u32, 0), rep.as(Repeat).count);

    try std.testing.expectEqual(.running, rep.tick());
    try std.testing.expectEqual(.running, rep.tick());
    try std.testing.expectEqual(.success, rep.tick());
}

test "[Repeat] invalid num_cycles" {
    const gpa = std.testing.allocator;
    var ctx = try Context.create(gpa);
    defer ctx.deinit();

    const rep = try NodeImpl(Repeat).create(gpa, ctx, "repeat");
    defer rep.deinit(gpa);

    try std.testing.expectError(error.MissingNumCycles, rep.configure());
    try rep.putValue("num_cycles", .{ .int = 0 });
    try std.testing.expectError(error.InvalidNumCycles, rep.configure());
    try rep.putValue("num_cycles", .{ .int = -2 });
    try std.testing.expectError(error.InvalidNumCycles, rep.configure());
    try rep.putValue("num_cycles", .{ .float = 2.5 });
    try std.testing.expectError(error.InvalidParamType, rep.configure());
}
