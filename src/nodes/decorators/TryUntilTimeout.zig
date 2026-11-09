//! A TryUntilTimeout node passes through its child's status, unless the child is still
//! Running after `timeout_ms` milliseconds, in which case the child is halted and the
//! TryUntilTimeout returns Failure.
//!
//! Params:
//! - `timeout_ms` (int, required): the timeout in milliseconds; must be positive.
//!
//! The timer starts on the first tick after the node is Idle, and is measured on the
//! monotonic "awake" clock of the Context's Io. The child is ticked before the timeout is
//! checked, so a child which completes on the tick where the timeout expires still passes
//! through its own Success or Failure.
const TryUntilTimeout = @This();

pub const kind: Node.Kind = .decorator;

/// The timeout, in milliseconds
timeout_ms: i64 = 1000,

/// When the current attempt started; null while Idle
start: ?Io.Timestamp = null,

pub fn configure(self: *TryUntilTimeout, node: *Node) !void {
    const timeout_ms = (try node.getParam(i64, "timeout_ms")) orelse return error.MissingTimeout;
    if (timeout_ms <= 0) return error.InvalidTimeout;
    self.timeout_ms = timeout_ms;
}

pub fn tick(self: *TryUntilTimeout, node: *Node) Node.Status {
    const decorator = &node.data.decorator;
    const child = decorator.child orelse return .failure;
    const io = node.context.io;

    const start = self.start orelse blk: {
        const now = Io.Timestamp.now(io, .awake);
        self.start = now;
        break :blk now;
    };

    switch (child.tick()) {
        .success, .failure => |s| {
            self.start = null;
            return s;
        },
        .running => {
            const elapsed = start.durationTo(Io.Timestamp.now(io, .awake));
            if (elapsed.toMilliseconds() < self.timeout_ms) return .running;

            // Timed out: stop the child
            self.start = null;
            decorator.halt();
            return .failure;
        },
        .idle => {
            log.err("Node '{s}' returned Idle from tick()", .{child.name});
            self.start = null;
            decorator.halt();
            return .failure;
        },
    }
}

/// Reset the timer (the child is halted automatically)
pub fn halt(self: *TryUntilTimeout) void {
    self.start = null;
}

const Node = @import("../../Node.zig");
const Context = @import("../../Context.zig");
const NodeImpl = @import("../../node_impl.zig").NodeImpl;
const Factory = @import("../../Factory.zig");
const Tree = @import("../../Tree.zig");
const bonzai = @import("../../bonzai.zig");

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.bonzai);

////////////////////////////////////////////////////////////////////////////////
// Tests
//
// These use a SimulatedClock, so time only passes when a test advances it.
////////////////////////////////////////////////////////////////////////////////

const test_nodes = @import("../test_nodes.zig");
const Countdown = test_nodes.Countdown;
const SimulatedClock = @import("../../SimulatedClock.zig");

fn testTimeout(ctx: *Context, timeout_ms: i64, child_ticks: u32, child_result: Node.Status) !*Node {
    const gpa = std.testing.allocator;
    const node = try NodeImpl(TryUntilTimeout).create(gpa, ctx, "timeout");
    errdefer node.deinit(gpa);
    node.data.decorator.child = try test_nodes.countdown(gpa, ctx, "child", child_ticks, child_result);
    try node.putValue("timeout_ms", .{ .int = timeout_ms });
    try node.configure();
    return node;
}

test "[TryUntilTimeout] passes through success and failure" {
    var sim: SimulatedClock = .init(std.testing.io, .{});
    var ctx = try Context.create(sim.io(), std.testing.allocator);
    defer ctx.deinit();

    inline for (.{ Node.Status.success, Node.Status.failure }) |result| {
        const node = try testTimeout(ctx, 100, 3, result);
        defer node.deinit(std.testing.allocator);

        try std.testing.expectEqual(.running, node.tick());
        sim.advance(.fromMilliseconds(99));
        try std.testing.expectEqual(.running, node.tick());
        try std.testing.expectEqual(result, node.tick());
        try std.testing.expectEqual(@as(?Io.Timestamp, null), node.as(TryUntilTimeout).start);
    }
}

test "[TryUntilTimeout] fails and halts the child exactly when the timeout expires" {
    var sim: SimulatedClock = .init(std.testing.io, .{});
    var ctx = try Context.create(sim.io(), std.testing.allocator);
    defer ctx.deinit();

    const node = try testTimeout(ctx, 20, 1_000_000, .success);
    defer node.deinit(std.testing.allocator);
    const child = node.data.decorator.child.?;

    try std.testing.expectEqual(.running, node.tick());
    sim.advance(.fromMilliseconds(19));
    try std.testing.expectEqual(.running, node.tick());
    sim.advance(.fromMilliseconds(1));
    try std.testing.expectEqual(.failure, node.tick());

    try std.testing.expectEqual(.idle, child.status);
    try std.testing.expectEqual(@as(u32, 1), child.as(Countdown).halts);
    try std.testing.expectEqual(@as(u32, 3), child.as(Countdown).total_ticks);
}

test "[TryUntilTimeout] a child completing on the expiring tick passes through" {
    var sim: SimulatedClock = .init(std.testing.io, .{});
    var ctx = try Context.create(sim.io(), std.testing.allocator);
    defer ctx.deinit();

    const node = try testTimeout(ctx, 20, 2, .success);
    defer node.deinit(std.testing.allocator);

    try std.testing.expectEqual(.running, node.tick());
    sim.advance(.fromMilliseconds(500));
    try std.testing.expectEqual(.success, node.tick());
}

test "[TryUntilTimeout] the timer restarts after halting or completing" {
    var sim: SimulatedClock = .init(std.testing.io, .{});
    var ctx = try Context.create(sim.io(), std.testing.allocator);
    defer ctx.deinit();

    const node = try testTimeout(ctx, 30, 1_000_000, .success);
    defer node.deinit(std.testing.allocator);

    // Halting restarts the timer
    try std.testing.expectEqual(.running, node.tick());
    sim.advance(.fromMilliseconds(50));
    node.halt();
    try std.testing.expectEqual(.running, node.tick());
    sim.advance(.fromMilliseconds(29));
    try std.testing.expectEqual(.running, node.tick());

    // After timing out (and being halted), a new attempt gets the full timeout
    sim.advance(.fromMilliseconds(1));
    try std.testing.expectEqual(.failure, node.tick());
    node.halt();
    try std.testing.expectEqual(.running, node.tick());
    sim.advance(.fromMilliseconds(29));
    try std.testing.expectEqual(.running, node.tick());
}

test "[TryUntilTimeout] invalid timeout_ms" {
    const gpa = std.testing.allocator;
    var ctx = try Context.create(std.testing.io, gpa);
    defer ctx.deinit();

    const node = try NodeImpl(TryUntilTimeout).create(gpa, ctx, "timeout");
    defer node.deinit(gpa);

    try std.testing.expectError(error.MissingTimeout, node.configure());
    try node.putValue("timeout_ms", .{ .int = 0 });
    try std.testing.expectError(error.InvalidTimeout, node.configure());
    try node.putValue("timeout_ms", .{ .int = -5 });
    try std.testing.expectError(error.InvalidTimeout, node.configure());
    try node.putValue("timeout_ms", .{ .string = "soon" });
    try std.testing.expectError(error.InvalidParamType, node.configure());
}

/// An asynchronous Action which sleeps (on the Context's clock) for `delay_ms`
const Sleepy = struct {
    pub const kind: Node.Kind = .action;
    delay_ms: i64 = 0,
    canceled: bool = false,

    pub fn prepare(self: *Sleepy, node: *Node) !void {
        self.delay_ms = (try node.getParam(i64, "delay_ms")) orelse self.delay_ms;
    }

    pub fn run(self: *Sleepy, io: Io) !void {
        io.sleep(.fromMilliseconds(self.delay_ms), .awake) catch |err| {
            self.canceled = true;
            return err;
        };
    }
};

fn loadSleepyTree(sim: *SimulatedClock, ctx: *Context, json: []const u8) !Tree {
    const gpa = std.testing.allocator;
    var factory = try Factory.init(sim.io(), gpa);
    defer factory.deinit();
    try bonzai.registerBuiltinTypes(&factory);
    try factory.register("Sleepy", Sleepy);
    return factory.loadFromJson(ctx, json);
}

/// Tick until the tree completes. The background job runs on a real thread, so yield
/// (in real time) between ticks; simulated time does not move.
fn tickUntilDone(tree: *Tree) !Node.Status {
    for (0..5000) |_| {
        const status = tree.tick();
        if (status != .running) return status;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.TestTimeout;
}

test "[TryUntilTimeout] cancels a slow asynchronous Action" {
    var sim: SimulatedClock = .init(std.testing.io, .{});
    var ctx = try Context.create(sim.io(), std.testing.allocator);
    defer ctx.deinit();

    var tree = try loadSleepyTree(&sim, ctx,
        \\{"root": {"kind": "TryUntilTimeout", "name": "timeout", "params": {"timeout_ms": 20},
        \\          "child": {"kind": "Sleepy", "name": "slow", "params": {"delay_ms": 60000}}}}
    );
    defer tree.deinit();
    const sleepy = tree.root.?.data.decorator.child.?.as(Sleepy);

    try std.testing.expectEqual(.running, tree.tick());
    try sim.waitForSleepers(1); // the job is now sleeping
    sim.advance(.fromMilliseconds(19));
    try std.testing.expectEqual(.running, tree.tick());
    sim.advance(.fromMilliseconds(1));
    try std.testing.expectEqual(.failure, tree.tick());
    try std.testing.expect(sleepy.canceled);
}

test "[TryUntilTimeout] passes through an asynchronous Action which finishes in time" {
    var sim: SimulatedClock = .init(std.testing.io, .{});
    var ctx = try Context.create(sim.io(), std.testing.allocator);
    defer ctx.deinit();

    var tree = try loadSleepyTree(&sim, ctx,
        \\{"root": {"kind": "TryUntilTimeout", "name": "timeout", "params": {"timeout_ms": 100},
        \\          "child": {"kind": "Sleepy", "name": "quick", "params": {"delay_ms": 99}}}}
    );
    defer tree.deinit();

    try std.testing.expectEqual(.running, tree.tick());
    try sim.waitForSleepers(1);
    sim.advance(.fromMilliseconds(99));
    // However long the job takes (in real time) to notice, no simulated time passes
    try std.testing.expectEqual(.success, try tickUntilDone(&tree));
    try std.testing.expect(!tree.root.?.data.decorator.child.?.as(Sleepy).canceled);
}
