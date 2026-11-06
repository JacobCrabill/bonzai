//! Node types used only by Bonzai's own unit tests.

/// An Action which returns Running for `ticks - 1` ticks, then returns `result`.
/// Tracks how many times it has been ticked, halted, and completed.
pub const Countdown = struct {
    pub const kind: Node.Kind = .action;

    ticks: u32 = 1,
    result: Node.Status = .success,

    count: u32 = 0,
    total_ticks: u32 = 0,
    halts: u32 = 0,

    pub fn configure(self: *Countdown, node: *Node) !void {
        self.ticks = (try node.getParam(u32, "ticks")) orelse self.ticks;
        self.result = (try node.getParam(Node.Status, "result")) orelse self.result;
    }

    pub fn tick(self: *Countdown) Node.Status {
        self.count += 1;
        self.total_ticks += 1;
        return if (self.count >= self.ticks) self.result else .running;
    }

    pub fn halt(self: *Countdown) void {
        self.count = 0;
        self.halts += 1;
    }
};

/// Create a Countdown node with the given settings
pub fn countdown(gpa: Allocator, ctx: *Context, name: []const u8, ticks: u32, result: Node.Status) !*Node {
    const node = try NodeImpl(Countdown).create(gpa, ctx, name);
    const c = node.as(Countdown);
    c.ticks = ticks;
    c.result = result;
    return node;
}

const Node = @import("../Node.zig");
const Context = @import("../Context.zig");
const NodeImpl = @import("../node_impl.zig").NodeImpl;

const std = @import("std");
const Allocator = std.mem.Allocator;
