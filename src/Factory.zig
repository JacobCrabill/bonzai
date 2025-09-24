pub const Factory = @This();

/// A BuilderFn creates a specific Node type with the given name and returns a
/// pointer to the "base-class" Node field within it.
/// TODO: Create error union for the 'create' method.
/// TODO: Take in a Context type.
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
pub fn registerNode(factory: *Factory, typename: []const u8, func: BuilderFn) !void {
    try factory.registry.put(factory.gpa, typename, func);
}

/// Create a new Node of the given type.
/// TODO: Take in a Context struct.
pub fn createNode(factory: *const Factory, kind: []const u8, name: []const u8) !*Node {
    if (factory.registry.get(kind)) |func| {
        return try func(factory.gpa, name);
    }
    return error.UnknownNodeType;
}

/// Load and instantiate a Behavior Tree from a JSON string
pub fn loadFromJson(factory: *Factory, json: []const u8) !Tree {
    var arena = std.heap.ArenaAllocator.init(factory.gpa);
    defer arena.deinit();

    const value: std.json.Value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});

    std.debug.assert(value.object.get("root") != null);
    std.debug.assert(value.object.get("root").? == .object);
    const root_def = value.object.get("root").?.object;

    // TODO: separate allocator for the tree? idk
    var tree = Tree.init(factory.gpa);
    try factory.parseJsonValue(&tree, null, .{ .object = root_def });
    return tree;
}

fn parseJsonValue(factory: *Factory, tree: *Tree, parent: ?*Node, value: std.json.Value) !void {
    if (!isValidJsonNode(value)) {
        std.debug.print("Invalid JSON Node: {any}\n", .{value});
        return error.InvalidNode;
    }

    //  Instantiate the node
    const kind = value.object.get("kind").?.string;
    const name = value.object.get("name").?.string;
    const node = try factory.createNode(kind, name);

    // Add the node to its parent
    // TODO: think about the order of allocations for efficiency
    if (parent) |pnode| {
        switch (pnode.*.data) {
            .control => |*c| {
                try c.*.addChild(factory.gpa, node);
            },
            .decorator => |*d| d.child = node,
            else => {
                var stdout = std.fs.File.stderr().writer(&.{});
                try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &stdout.interface);
                // error! actions and condition nodes can't be parents
                return error.InvalidParentType;
            },
        }
    }

    try tree.addNode(node);
    if (tree.root == null) tree.root = node;

    // Check for a child / children of the node
    switch (node.data) {
        .control => {
            if (!isControl(value)) {
                std.debug.print("Error: Kind is a Control, but no children given\n", .{});
                return error.InvalidControl;
            }
            const children = value.object.get("children").?.array.items;
            for (children) |child| {
                try factory.parseJsonValue(tree, node, child);
            }
        },
        .decorator => {
            if (!isDecorator(value)) {
                std.debug.print("Error: Kind is a Decorator, but no child given\n", .{});
                return error.InvalidControl;
            }
            const child = value.object.get("child").?;
            try factory.parseJsonValue(tree, node, child);
        },
        else => {
            // no children, nothing to do
        },
    }
}

/// Check that the Value defines a Node
fn isValidJsonNode(value: std.json.Value) bool {
    if (value != .object) return false;
    if (value.object.get("kind") == null) return false;
    if (value.object.get("kind").? != .string) return false;
    if (value.object.get("name") == null) return false;
    if (value.object.get("name").? != .string) return false;
    return true;
}

/// Check if the JSON Node is a decorator (single child)
fn isDecorator(value: std.json.Value) bool {
    return value.object.get("child") != null;
}

/// Check if the JSON Node is a control (multiple children)
fn isControl(value: std.json.Value) bool {
    if (value != .object) return false;
    if (value.object.get("children") == null) return false;
    if (value.object.get("children").? != .array) return false;
    if (value.object.get("children").?.array.items.len < 1) return false;
    return true;
}

const Node = @import("Node.zig");
const Tree = @import("Tree.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;

test "[Factory] Register & Create Nodes" {
    const gpa = std.testing.allocator;
    var factory = try Factory.init(gpa);
    defer factory.deinit();

    const Sequence = @import("nodes/controls/Sequence.zig");
    const AlwaysRunning = @import("nodes/actions/AlwaysRunning.zig");

    try factory.registerNode("Sequence", Sequence.create);
    try factory.registerNode("AlwaysRunning", AlwaysRunning.create);

    const seq_node: *Node = try factory.createNode("Sequence", "seq-1");
    const ar_node: *Node = try factory.createNode("AlwaysRunning", "run-1");
    defer seq_node.deinit(gpa);
    defer ar_node.deinit(gpa);
}

test "[Factory] Load from JSON" {
    const gpa = std.testing.allocator;
    var factory = try Factory.init(gpa);
    defer factory.deinit();

    const Sequence = @import("nodes/controls/Sequence.zig");
    const Inverter = @import("nodes/decorators/Inverter.zig");
    const AlwaysSuccess = @import("nodes/conditions/AlwaysSuccess.zig");
    const AlwaysFailure = @import("nodes/conditions/AlwaysFailure.zig");

    try factory.registerNode("Sequence", Sequence.create);
    try factory.registerNode("Inverter", Inverter.create);
    try factory.registerNode("AlwaysFailure", AlwaysFailure.create);
    try factory.registerNode("AlwaysSuccess", AlwaysSuccess.create);

    const json = @embedFile("tests/json/test-tree.json");

    var tree = try factory.loadFromJson(json);
    defer tree.deinit();

    try std.testing.expectEqual(.running, tree.tick());
    try std.testing.expectEqual(.success, tree.tick());
}
