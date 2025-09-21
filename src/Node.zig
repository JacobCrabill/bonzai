//! The Node is the base unit of a Behavior Tree.
//!
//! Each Node type must, at a minimum, implement a 'tick' method which returns
//! a Status of either Running, Success, or Failure.
const Node = @This();

pub const Status = enum(u8) {
    idle,
    running,
    success,
    failure,
};

pub const Kind = enum(u8) {
    action,
    condition,
    decorator,
    control,
};

pub const TickCb = *const fn (node: *Node, prev_status: Status, status: Status) void;

kind: Kind,
status: Status = .idle,

/// The unique name of the specific node instance.
/// There should not be two nodes with the same name in a Tree.
/// The name must be a heap-allocated string; it will be freed in deinit().
name: []const u8,

vtable: VTable,

pre_tick_cbs: std.ArrayList(TickCb) = .empty,
post_tick_cbs: std.ArrayList(TickCb) = .empty,
status_changed_cbs: std.ArrayList(TickCb) = .empty,

pub const VTable = struct {
    /// The node-specific implementation of the behavior tree Tick
    tick: *const fn (node: *Node) Status,
    /// Halt the node, resetting its status (and that of any children it may have) to Idle
    halt: ?*const fn (node: *Node) void = null,
    /// Deinitialize the node, freeing any resources it may have
    deinit: ?*const fn (node: *Node, alloc: Allocator) void = null,
};

pub fn tick(node: *Node) Status {
    const prev_status = node.status;

    for (node.pre_tick_cbs.items) |cb| cb(node, prev_status, prev_status);

    // The status gets latched once a node either suceeds or fails
    if (prev_status == .success or prev_status == .failure)
        return prev_status;

    // TODO: pre-tick callback

    const new_status = node.vtable.tick(node);
    if (new_status != prev_status) {
        node.setStatus(new_status);
    }

    for (node.post_tick_cbs.items) |cb| cb(node, prev_status, prev_status);

    return new_status;
}

pub fn setStatus(node: *Node, status: Status) void {
    if (status != node.status) {
        for (node.status_changed_cbs.items) |cb| cb(node, node.status, status);
    }
    node.status = status;
}

pub fn halt(node: *Node) void {
    if (node.vtable.halt) |h| h(node);
    node.setStatus(.idle);
}

/// Create a new Node. Copies the given name string.
pub fn init(alloc: Allocator, name: []const u8, kind: Kind, vtable: VTable) !Node {
    return .{
        .name = try alloc.dupe(u8, name),
        .kind = kind,
        .vtable = vtable,
    };
}

pub fn deinit(node: *Node, alloc: Allocator) void {
    if (node.vtable.deinit) |d| d(node, alloc);
    alloc.free(node.name);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
