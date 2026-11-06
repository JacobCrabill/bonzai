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

/// Context from the parent tree
context: *Context,

/// Private Blackboard (key/value map) for this node
blackboard: Blackboard,

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
    /// Configure the node from the values in its Blackboard (e.g. params loaded from JSON).
    /// Called by the Factory once the node and all of its children have been created.
    configure: ?*const fn (node: *Node) anyerror!void = null,
    /// Identifies the implementation type, for checked casts. Set by `NodeImpl`.
    type_id: ?TypeId = null,
    /// The name of the implementation type, for error messages. Set by `NodeImpl`.
    type_name: []const u8 = "<unknown>",
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
pub fn init(alloc: Allocator, ctx: *Context, name: []const u8, node_kind: Kind, vtable: VTable) !Node {
    return .{
        .data = switch (node_kind) {
            .action => .{ .action = {} },
            .condition => .{ .condition = {} },
            .decorator => .{ .decorator = .{} },
            .control => .{ .control = .{} },
        },
        .context = ctx,
        .blackboard = Blackboard.init(alloc),
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
    bb.deinit(&node.blackboard);
    node.vtable.deinit(node, alloc);
}

/// Get a value from the Node's Blackboard
pub fn getValue(node: *const Node, key: []const u8) ?BlackboardValue {
    return node.blackboard.get(key);
}

/// Put a value into the Node's private Blackboard, replacing any existing value.
/// The key and any string value are copied.
pub fn putValue(node: *Node, key: []const u8, value: BlackboardValue) !void {
    try bb.put(&node.blackboard, key, value);
}

/// Configure the node from its Blackboard values by calling its `configure` hook, if any.
/// The Factory calls this automatically when loading a tree; call it yourself after
/// `putValue()` when creating nodes manually.
pub fn configure(node: *Node) !void {
    if (node.vtable.configure) |f| try f(node);
}

pub const ParamError = error{
    /// The value's type cannot be converted to the requested type
    InvalidParamType,
    /// The integer value does not fit in the requested type
    ParamOutOfRange,
};

/// Get a value from the Node's Blackboard, converted to type `T`; null if the key is absent.
///
/// Supported types:
/// - integers: from an int value, with a range check
/// - floats: from a float or int value
/// - bool: from a bool value
/// - []const u8: from a string value (borrowed; valid until the value is replaced or the node is freed)
/// - enums: from a string value matching a tag name
///
/// Example: `const retries = (try node.getParam(u32, "retries")) orelse 3;`
pub fn getParam(node: *const Node, comptime T: type, key: []const u8) ParamError!?T {
    const value = node.blackboard.get(key) orelse return null;
    return try convertParam(T, value);
}

fn convertParam(comptime T: type, value: BlackboardValue) ParamError!T {
    switch (@typeInfo(T)) {
        .int => return switch (value) {
            .int => |i| std.math.cast(T, i) orelse error.ParamOutOfRange,
            else => error.InvalidParamType,
        },
        .float => return switch (value) {
            .float => |f| @floatCast(f),
            .int => |i| @floatFromInt(i),
            else => error.InvalidParamType,
        },
        .bool => return switch (value) {
            .bool => |b| b,
            else => error.InvalidParamType,
        },
        .@"enum" => return switch (value) {
            .string => |s| std.meta.stringToEnum(T, s) orelse error.InvalidParamType,
            else => error.InvalidParamType,
        },
        else => {
            if (T != []const u8) @compileError("Node.getParam: unsupported type " ++ @typeName(T));
            return switch (value) {
                .string => |s| s,
                else => error.InvalidParamType,
            };
        },
    }
}

/// Get the implementation of a Node created by `NodeImpl(T)`.
/// Asserts (in safe builds) that the node really is a `T`.
pub fn as(node: *Node, comptime T: type) *T {
    return NodeImpl(T).cast(node);
}

/// Get the implementation of a Node created by `NodeImpl(T)`, or null if it is not a `T`.
pub fn tryAs(node: *Node, comptime T: type) ?*T {
    return if (NodeImpl(T).isInstance(node)) NodeImpl(T).cast(node) else null;
}

/// Cast a Node pointer to its "derived" type, for types implemented manually
/// (without `NodeImpl`). Assumes the derived type stores the Node in a field named 'node'.
/// Unchecked: prefer `as()` for NodeImpl types.
pub fn cast(node: *Node, comptime T: type) *T {
    return @alignCast(@fieldParentPtr("node", node));
}

const Context = @import("Context.zig");
const NodeImpl = @import("node_impl.zig").NodeImpl;
const TypeId = @import("type_id.zig").TypeId;
const Control = @import("base_types/Control.zig");
const Decorator = @import("base_types/Decorator.zig");
const bb = @import("blackboard.zig");
const Blackboard = bb.Blackboard;
const BlackboardValue = bb.Value;
const Logger = @import("Logger.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;

////////////////////////////////////////////////////////////////////////////////
// Unit Tests
////////////////////////////////////////////////////////////////////////////////

test "[Node] getParam conversions" {
    const gpa = std.testing.allocator;
    var ctx = try Context.create(std.testing.io, gpa);
    defer ctx.deinit();

    const Plain = struct {
        pub const kind: Kind = .action;
        pub fn tick(_: *@This()) Status {
            return .success;
        }
    };
    const node = try NodeImpl(Plain).create(gpa, ctx, "n");
    defer node.deinit(gpa);

    try node.putValue("int", .{ .int = 300 });
    try node.putValue("neg", .{ .int = -1 });
    try node.putValue("float", .{ .float = 1.5 });
    try node.putValue("flag", .{ .bool = true });
    try node.putValue("mode", .{ .string = "running" });

    const t = std.testing;
    try t.expectEqual(@as(?u32, 300), try node.getParam(u32, "int"));
    try t.expectEqual(@as(?f32, 300.0), try node.getParam(f32, "int"));
    try t.expectEqual(@as(?f64, 1.5), try node.getParam(f64, "float"));
    try t.expectEqual(@as(?bool, true), try node.getParam(bool, "flag"));
    try t.expectEqual(@as(?Status, .running), try node.getParam(Status, "mode"));
    try t.expectEqualStrings("running", (try node.getParam([]const u8, "mode")).?);
    try t.expectEqual(@as(?u32, null), try node.getParam(u32, "missing"));

    try t.expectError(error.ParamOutOfRange, node.getParam(u8, "int"));
    try t.expectError(error.ParamOutOfRange, node.getParam(u32, "neg"));
    try t.expectError(error.InvalidParamType, node.getParam(u32, "float"));
    try t.expectError(error.InvalidParamType, node.getParam(bool, "int"));
    try t.expectError(error.InvalidParamType, node.getParam(Kind, "mode"));
}
