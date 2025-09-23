//! The Node is the base unit of a Behavior Tree.
//!
//! Each Node type must, at a minimum, implement a 'tick' method which returns
//! a Status of either Running, Success, or Failure.
const Node = @This();

/// Every node in a Behavior Tree must return a status of Running, Success, or
/// Failure when ticked. Nodes start in the Idle state when inactive.
pub const Status = enum(u8) {
    idle,
    running,
    success,
    failure,
};

/// All Node subtypes must be an Action, Condition, Decorator, or Control.
pub const Kind = enum(u8) {
    action,
    condition,
    decorator,
    control,
};

/// The data from the basis subtypes.
pub const Data = union(Kind) {
    action: void,
    condition: void,
    decorator: Decorator,
    control: Control,
};

/// Nodes may have callback functions to be run pre- or post-tick, or upon status change.
pub const TickCb = struct {
    ctx: *anyopaque,
    callback: *const fn (ctx: *anyopaque, node: *Node, prev_status: Status, status: Status) void,
};

/// The current status of the node
status: Status = .idle,

/// The data implementing the high-level node subtype
data: Data,

/// The vtable implementing the Node subtype
vtable: VTable,

/// Callback functions to be run on this node before it is ticked
pre_tick_cbs: std.ArrayList(TickCb) = .empty,

/// Callback functions to be run on this node after it is ticked
post_tick_cbs: std.ArrayList(TickCb) = .empty,

/// Callback functions to be run on this node when its status changes
status_changed_cbs: std.ArrayList(TickCb) = .empty,

/// The unique name of the specific node instance.
/// There should not be two nodes with the same name in a Tree.
/// The name must be a heap-allocated string; it will be freed in deinit().
name: []const u8,

/// All Node subtypes must implement methoda from the VTable
pub const VTable = struct {
    /// The node-specific implementation of the behavior tree Tick
    tick: *const fn (node: *Node) Status,
    /// Halt the node, resetting its status (and that of any children it may have) to Idle
    halt: ?*const fn (node: *Node) void = null,
    /// Deinitialize the node, freeing any resources it may have, and also deallocating itself
    /// TODO: Split into optional "deinit" (called before anything gets freed) and a required "destroy" (called at the very end)
    deinit: *const fn (node: *Node, alloc: Allocator) void,
};

pub fn kind(node: *const Node) Kind {
    return switch (node.data) {
        .action => .action,
        .condition => .condition,
        .control => .control,
        .decorator => .decorator,
    };
}

/// The entrypoint for all Node types upon being ticked.
/// Calls the tick method from the vtable, and calls any callback functions as applicable.
pub fn tick(node: *Node) Status {
    const prev_status = node.status;

    for (node.pre_tick_cbs.items) |cb| cb.callback(cb.ctx, node, prev_status, prev_status);

    // The status gets latched once a node either suceeds or fails, and
    // remains latched until the node is halted.
    if (prev_status == .success or prev_status == .failure)
        return prev_status;

    const new_status = node.vtable.tick(node);
    node.setStatus(new_status);

    for (node.post_tick_cbs.items) |cb| cb.callback(cb.ctx, node, prev_status, new_status);

    return new_status;
}

pub fn setStatus(node: *Node, status: Status) void {
    if (status != node.status) {
        for (node.status_changed_cbs.items) |cb| cb.callback(cb.ctx, node, node.status, status);
    }
    node.status = status;
}

pub fn halt(node: *Node) void {
    if (node.vtable.halt) |h| h(node);
    switch (node.data) {
        .decorator => |*d| d.*.halt(),
        .control => |*c| c.*.halt(),
        else => {},
    }
    node.setStatus(.idle);
}

/// Create a new Node. Copies the given name string.
pub fn init(alloc: Allocator, name: []const u8, node_kind: Kind, vtable: VTable) !Node {
    return .{
        .data = switch (node_kind) {
            .action => .{ .action = {} },
            .condition => .{ .condition = {} },
            .decorator => .{ .decorator = .{} },
            .control => .{ .control = .{} },
        },
        .vtable = vtable,
        .name = try alloc.dupe(u8, name),
    };
}

/// Deinitialize the Node, freeing all resources.
/// This also calls the type-specific deinit function to destroy the parent object.
pub fn deinit(node: *Node, alloc: Allocator) void {
    node.pre_tick_cbs.deinit(alloc);
    node.post_tick_cbs.deinit(alloc);
    node.status_changed_cbs.deinit(alloc);
    switch (node.data) {
        .control => |*c| c.*.deinit(alloc),
        .decorator => |*d| d.*.deinit(alloc),
        else => {},
    }
    alloc.free(node.name);
    node.vtable.deinit(node, alloc);
}

const Control = @import("base_types/Control.zig");
const Decorator = @import("base_types/Decorator.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
