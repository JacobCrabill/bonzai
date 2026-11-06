//! A Parallel node ticks all of its children on every tick, and completes once enough of
//! them have succeeded or failed.
//!
//! Params:
//! - `success_threshold` (int, default: all children): the number of children which must
//!   succeed for the Parallel to return Success.
//! - `failure_threshold` (int, default: 1): the number of children which must fail for the
//!   Parallel to return Failure.
//!
//! The Parallel also returns Failure as soon as the success threshold becomes unreachable
//! (too many children have failed). If both thresholds are reached on the same tick, Success
//! takes precedence. Children which have already completed keep their (latched) status until
//! the Parallel completes; at that point all children are halted, stopping any still running.
const Parallel = @This();

pub const kind: Node.Kind = .control;

/// The number of children which must succeed; null means all of them
success_threshold: ?usize = null,

/// The number of children which must fail
failure_threshold: usize = 1,

pub fn configure(self: *Parallel, node: *Node) !void {
    const num_children = node.data.control.numChildren();

    if (try node.getParam(usize, "success_threshold")) |t| self.success_threshold = t;
    if (try node.getParam(usize, "failure_threshold")) |t| self.failure_threshold = t;

    // Each threshold must be between 1 and the number of children
    const success_threshold = self.success_threshold orelse num_children;
    if (success_threshold < 1 or success_threshold > num_children) return error.InvalidSuccessThreshold;
    if (self.failure_threshold < 1 or self.failure_threshold > num_children) return error.InvalidFailureThreshold;
}

pub fn tick(self: *Parallel, node: *Node) Node.Status {
    const control = &node.data.control;
    const num_children = control.numChildren();
    if (num_children == 0) return .failure;

    const success_threshold = self.success_threshold orelse num_children;

    var successes: usize = 0;
    var failures: usize = 0;
    for (control.children.items) |child| {
        switch (child.tick()) {
            .success => successes += 1,
            .failure => failures += 1,
            .running => {},
            .idle => {
                log.err("Node '{s}' returned Idle from tick()", .{child.name});
                failures += 1;
            },
        }
    }

    const result: Node.Status = if (successes >= success_threshold)
        .success
    else if (failures >= self.failure_threshold or num_children - failures < success_threshold)
        .failure
    else
        return .running;

    // Stop any children which are still running, and reset the completed ones
    control.halt();
    return result;
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

/// Create a Parallel with Countdown children given as (ticks, result) pairs
fn testParallel(ctx: *Context, children: []const struct { u32, Node.Status }) !*Node {
    const gpa = std.testing.allocator;
    const par = try NodeImpl(Parallel).create(gpa, ctx, "parallel");
    errdefer par.deinit(gpa);
    for (children, 0..) |c, i| {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "child-{d}", .{i});
        const child = try test_nodes.countdown(gpa, ctx, name, c[0], c[1]);
        errdefer child.deinit(gpa);
        try par.data.control.addChild(gpa, child);
    }
    return par;
}

fn childAt(par: *Node, i: usize) *Countdown {
    return par.data.control.getChild(i).as(Countdown);
}

test "[Parallel] default thresholds: all must succeed" {
    var ctx = try Context.create(std.testing.io, std.testing.allocator);
    defer ctx.deinit();

    const par = try testParallel(ctx, &.{ .{ 1, .success }, .{ 3, .success }, .{ 2, .success } });
    defer par.deinit(std.testing.allocator);
    try par.configure();

    try std.testing.expectEqual(.running, par.tick());
    try std.testing.expectEqual(.running, par.tick());
    try std.testing.expectEqual(.success, par.tick());

    // Children which completed early are not re-ticked while waiting on the others
    try std.testing.expectEqual(@as(u32, 1), childAt(par, 0).total_ticks);
    try std.testing.expectEqual(@as(u32, 2), childAt(par, 2).total_ticks);

    // All children are reset on completion
    for (par.data.control.children.items) |child| try std.testing.expectEqual(.idle, child.status);
}

test "[Parallel] default thresholds: any failure fails" {
    var ctx = try Context.create(std.testing.io, std.testing.allocator);
    defer ctx.deinit();

    const par = try testParallel(ctx, &.{ .{ 5, .success }, .{ 2, .failure } });
    defer par.deinit(std.testing.allocator);
    try par.configure();

    try std.testing.expectEqual(.running, par.tick());
    try std.testing.expectEqual(.failure, par.tick());

    // The still-running child was halted
    try std.testing.expectEqual(.idle, par.data.control.getChild(0).status);
    try std.testing.expectEqual(@as(u32, 1), childAt(par, 0).halts);
}

test "[Parallel] success threshold" {
    var ctx = try Context.create(std.testing.io, std.testing.allocator);
    defer ctx.deinit();

    // 2 of 3 must succeed; one child never finishes in time
    const par = try testParallel(ctx, &.{ .{ 100, .success }, .{ 2, .success }, .{ 3, .success } });
    defer par.deinit(std.testing.allocator);
    try par.putValue("success_threshold", .{ .int = 2 });
    try par.configure();

    try std.testing.expectEqual(.running, par.tick());
    try std.testing.expectEqual(.running, par.tick());
    try std.testing.expectEqual(.success, par.tick());
    try std.testing.expectEqual(.idle, par.data.control.getChild(0).status);
}

test "[Parallel] fails once the success threshold is unreachable" {
    var ctx = try Context.create(std.testing.io, std.testing.allocator);
    defer ctx.deinit();

    // 2 of 3 must succeed, and up to 3 may fail; after 2 failures success is impossible
    const par = try testParallel(ctx, &.{ .{ 1, .failure }, .{ 2, .failure }, .{ 100, .success } });
    defer par.deinit(std.testing.allocator);
    try par.putValue("success_threshold", .{ .int = 2 });
    try par.putValue("failure_threshold", .{ .int = 3 });
    try par.configure();

    try std.testing.expectEqual(.running, par.tick());
    try std.testing.expectEqual(.failure, par.tick());
}

test "[Parallel] failure threshold" {
    var ctx = try Context.create(std.testing.io, std.testing.allocator);
    defer ctx.deinit();

    // 1 success is enough, and it takes 2 failures to fail
    const par = try testParallel(ctx, &.{ .{ 1, .failure }, .{ 2, .success } });
    defer par.deinit(std.testing.allocator);
    try par.putValue("success_threshold", .{ .int = 1 });
    try par.putValue("failure_threshold", .{ .int = 2 });
    try par.configure();

    try std.testing.expectEqual(.running, par.tick());
    try std.testing.expectEqual(.success, par.tick());
}

test "[Parallel] success takes precedence when both thresholds are reached" {
    var ctx = try Context.create(std.testing.io, std.testing.allocator);
    defer ctx.deinit();

    const par = try testParallel(ctx, &.{ .{ 1, .failure }, .{ 1, .success } });
    defer par.deinit(std.testing.allocator);
    try par.putValue("success_threshold", .{ .int = 1 });
    try par.configure();

    try std.testing.expectEqual(.success, par.tick());
}

test "[Parallel] restarts after being halted" {
    var ctx = try Context.create(std.testing.io, std.testing.allocator);
    defer ctx.deinit();

    const par = try testParallel(ctx, &.{ .{ 1, .success }, .{ 2, .success } });
    defer par.deinit(std.testing.allocator);
    try par.configure();

    try std.testing.expectEqual(.running, par.tick());
    try std.testing.expectEqual(.success, par.tick());
    try std.testing.expectEqual(.success, par.tick()); // latched

    par.halt();
    try std.testing.expectEqual(.running, par.tick());
    try std.testing.expectEqual(.success, par.tick());
}

test "[Parallel] invalid thresholds" {
    var ctx = try Context.create(std.testing.io, std.testing.allocator);
    defer ctx.deinit();

    const par = try testParallel(ctx, &.{ .{ 1, .success }, .{ 1, .success } });
    defer par.deinit(std.testing.allocator);

    try par.putValue("success_threshold", .{ .int = 3 });
    try std.testing.expectError(error.InvalidSuccessThreshold, par.configure());

    try par.putValue("success_threshold", .{ .int = 0 });
    try std.testing.expectError(error.InvalidSuccessThreshold, par.configure());

    try par.putValue("success_threshold", .{ .int = 1 });
    try par.putValue("failure_threshold", .{ .int = 5 });
    try std.testing.expectError(error.InvalidFailureThreshold, par.configure());

    try par.putValue("failure_threshold", .{ .int = -1 });
    try std.testing.expectError(error.ParamOutOfRange, par.configure());
}
