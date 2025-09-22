pub const Factory = @This();

/// A BuilderFn creates a specific Node type with the given name and returns a
/// pointer to the "base-class" Node field within it.
/// TODO: Create error union for the 'create' method.
const BuilderFn = *const fn (alloc: std.mem.Allocator, name: []const u8) anyerror!*Node;

/// We store our own Allocator to ensure all nodes get created & destroyed with the same one
gpa: Allocator,

/// The registry maps the name of the type (e.g. "Sequence") to the function which creates it
registry: std.StringArrayHashMapUnmanaged(BuilderFn),

/// Initialize a Factory. It will not contain any types yet.
pub fn init(alloc: Allocator) !Factory {
    return .{
        .gpa = alloc,
        .registry = try std.StringArrayHashMapUnmanaged(BuilderFn).init(alloc, &.{}, &.{}),
    };
}

pub fn deinit(factory: *Factory) void {
    factory.registry.deinit(factory.gpa);
}

/// Register a builder function
pub fn registerNode(factory: *Factory, T: anytype, func: BuilderFn) !void {
    std.debug.print("Registering node type: {s}\n", .{@typeName(T)});
    try factory.registry.put(factory.gpa, @typeName(T), func);
}

/// Create a new Node of the given type
pub fn createNode(factory: *const Factory, kind: []const u8, name: []const u8) !*Node {
    if (factory.registry.get(kind)) |func| {
        return try func(factory.gpa, name);
    }
    return error.UnknownNodeType;
}

const Node = @import("Node.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;

test "[Factory] Register & Create Nodes" {
    const gpa = std.testing.allocator;
    var factory = try Factory.init(gpa);
    defer factory.deinit();

    const Sequence = @import("nodes/controls/Sequence.zig");
    const AlwaysRunning = @import("nodes/actions/AlwaysRunning.zig");

    try factory.registerNode(Sequence, Sequence.create);
    try factory.registerNode(AlwaysRunning, AlwaysRunning.create);

    const seq_node: *Node = try factory.createNode("nodes.controls.Sequence", "seq-1");
    const ar_node: *Node = try factory.createNode("nodes.actions.AlwaysRunning", "run-1");
    defer seq_node.deinit(gpa);
    defer ar_node.deinit(gpa);
}
