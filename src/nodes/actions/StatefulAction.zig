//! A StatefulAction is an Action node which tracks its current state and
//! chooses the correct method to call on each tick().
//!
//! NOTE: This is NOT a concrete node type that can be created, it is only an interface!
const StatefulAction = @This();

node: Node,
vtable: VTable,

pub const VTable = struct {
    /// Called on every tick while the node is Running
    onRunning: *const fn (action: *StatefulAction) Node.Status,
    /// Called when the node first transitions out of Idle
    onStarted: ?*const fn (action: *StatefulAction) Node.Status = null,
    /// Called when the node is transitioned to Idle
    onHalted: ?*const fn (action: *StatefulAction) void = null,
    /// Deinitialize the "derived" type, including destroying the instance
    deinit: *const fn (action: *StatefulAction, alloc: Allocator) void,
};

/// Forward the tick to the correct method based on the current status of the node
pub fn tick(node: *Node) Node.Status {
    const action: *StatefulAction = @alignCast(@fieldParentPtr("node", node));

    const prev_status = node.status;
    switch (prev_status) {
        .idle => {
            node.setStatus(.running);
            return action.onStarted();
        },
        .running => return action.onRunning(),
        .success, .failure => {
            return prev_status;
        },
    }

    unreachable;
}

pub fn halt(node: *Node) void {
    const action: *StatefulAction = @alignCast(@fieldParentPtr("node", node));
    action.onHalted();
}

pub fn deinit(node: *Node, alloc: Allocator) void {
    const action: *StatefulAction = @alignCast(@fieldParentPtr("node", node));
    action.vtable.deinit(action, alloc);
}

pub fn onStarted(action: *StatefulAction) Node.Status {
    if (action.vtable.onStarted) |f| return f(action);
    return .running;
}

pub fn onRunning(action: *StatefulAction) Node.Status {
    return action.vtable.onRunning(action);
}

pub fn onHalted(action: *StatefulAction) void {
    if (action.node.status != .idle) {
        if (action.vtable.onHalted) |f| f(action);
    }
}

pub fn init(self: *@This(), alloc: Allocator, name: []const u8, vtable: VTable) !void {
    self.vtable = vtable;
    self.node = try .init(alloc, name, .action, .{
        .tick = tick,
        .halt = halt,
        .deinit = deinit,
    });
}

pub fn cast(node: *Node, T: anytype) *T {
    const action: *StatefulAction = @alignCast(@fieldParentPtr("node", node));
    return @alignCast(@fieldParentPtr("action", action));
}

const Node = @import("../../Node.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;
