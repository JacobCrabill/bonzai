pub const Factory = @This();

/// A BuilderFn creates a specific Node type with the given name and returns a
/// pointer to the "base-class" Node field within it.
/// TODO: Create error union for the 'create' method.
pub const BuilderFn = *const fn (alloc: std.mem.Allocator, ctx: *Context, name: []const u8) anyerror!*Node;

io: std.Io,

/// We store our own Allocator to ensure all nodes get created & destroyed with the same one
gpa: Allocator,

/// The registry maps the name of the type (e.g. "Sequence") to the function which creates it
registry: std.StringArrayHashMapUnmanaged(BuilderFn),

/// Initialize a Factory. It will not contain any types yet.
pub fn init(io: std.Io, alloc: Allocator) !Factory {
    return .{
        .io = io,
        .gpa = alloc,
        .registry = try std.StringArrayHashMapUnmanaged(BuilderFn).init(alloc, &.{}, &.{}),
    };
}

pub fn deinit(factory: *Factory) void {
    factory.registry.deinit(factory.gpa);
}

/// Register a builder function. Prefer `register()` for types using `NodeImpl`.
pub fn registerNode(factory: *Factory, typename: []const u8, func: BuilderFn) !void {
    try factory.registry.put(factory.gpa, typename, func);
}

/// Register a Node implementation type (see `NodeImpl`) under the given type name
pub fn register(factory: *Factory, typename: []const u8, comptime T: type) !void {
    try factory.registerNode(typename, NodeImpl(T).create);
}

/// Create a new Node of the given type.
pub fn createNode(factory: *const Factory, ctx: *Context, kind: []const u8, name: []const u8) !*Node {
    if (factory.registry.get(kind)) |func| {
        return try func(factory.gpa, ctx, name);
    }
    return error.UnknownNodeType;
}

/// Errors specific to loading a tree definition from JSON.
/// Loading may also return `error.OutOfMemory`, or any error from a registered BuilderFn.
pub const LoadError = error{
    /// The input is not syntactically valid JSON
    InvalidJson,
    /// The top-level value is not an object with a "root" node object
    MissingRoot,
    /// A "params" entry is not an object, or contains an unsupported value type
    InvalidParams,
    /// A node definition is not an object, or lacks a string "kind" or "name"
    InvalidNode,
    /// A node's "kind" has not been registered with the Factory
    UnknownNodeType,
    /// Two nodes in the tree share the same "name"
    DuplicateNodeName,
    /// A Control node has no "children", or "children" is not a non-empty array
    MissingChildren,
    /// A Decorator node has no "child"
    MissingChild,
    /// A node has "child" or "children" that its kind does not allow
    UnexpectedChildren,
};

/// Optional, detailed information about why `loadFromJsonDiag()` failed.
pub const Diagnostics = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,
    /// 1-based position of a JSON syntax error; 0 for all other errors
    line: u64 = 0,
    column: u64 = 0,

    /// A human-readable description of the error, including the JSON path
    /// of the offending element (e.g. `root.children[1].child`).
    pub fn message(diag: *const Diagnostics) []const u8 {
        return diag.buf[0..diag.len];
    }

    fn set(diag: ?*Diagnostics, comptime fmt: []const u8, args: anytype) void {
        const d = diag orelse return;
        var w: std.Io.Writer = .fixed(&d.buf);
        w.print(fmt, args) catch {}; // truncate overly long messages
        d.len = w.end;
    }
};

/// Load and instantiate a Behavior Tree from a JSON string.
/// See `loadFromJsonDiag()` to get a description of any error.
pub fn loadFromJson(factory: *Factory, ctx: *Context, json: []const u8) !Tree {
    return factory.loadFromJsonDiag(ctx, json, null);
}

/// Load and instantiate a Behavior Tree from a JSON string.
///
/// On error, nothing is leaked, the Context is left unmodified, and, if `diag` is
/// non-null, it is filled with a description of the problem.
/// On success, any tree-level "params" are written to the Context's Blackboard.
pub fn loadFromJsonDiag(factory: *Factory, ctx: *Context, json: []const u8, diag: ?*Diagnostics) anyerror!Tree {
    if (diag) |d| d.* = .{};

    var arena_state = std.heap.ArenaAllocator.init(factory.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var scanner = std.json.Scanner.initCompleteInput(arena, json);
    var json_diag: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&json_diag);
    const value = std.json.parseFromTokenSourceLeaky(std.json.Value, arena, &scanner, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            Diagnostics.set(diag, "invalid JSON at line {d}, column {d}: {t}", .{
                json_diag.getLine(), json_diag.getColumn(), err,
            });
            if (diag) |d| {
                d.line = json_diag.getLine();
                d.column = json_diag.getColumn();
            }
            return error.InvalidJson;
        },
    };

    if (value != .object) {
        Diagnostics.set(diag, "top-level JSON value must be an object", .{});
        return error.MissingRoot;
    }
    const root_def = value.object.get("root") orelse {
        Diagnostics.set(diag, "missing \"root\" node", .{});
        return error.MissingRoot;
    };

    // Validate tree-level params up front so a bad tree never modifies the Context
    const tree_params = value.object.get("params");
    if (tree_params) |params| try validateParams(params, "params", diag);

    var tree = Tree.init(factory.io, factory.gpa, ctx);
    errdefer tree.deinit();

    try factory.parseNode(&tree, arena, null, root_def, "root", diag);

    if (tree_params) |params| {
        var iter = params.object.iterator();
        while (iter.next()) |elem| {
            try ctx.putBlackboardValue(elem.key_ptr.*, paramValue(elem.value_ptr.*).?);
        }
    }

    return tree;
}

/// Recursively instantiate the node defined by `value` and all of its children,
/// attaching it to `parent` (or making it the tree's root).
///
/// Ownership: the new node is freed here if an error occurs before it is attached;
/// once attached, it is freed by `Tree.deinit()`.
fn parseNode(
    factory: *Factory,
    tree: *Tree,
    arena: Allocator,
    parent: ?*Node,
    value: std.json.Value,
    path: []const u8,
    diag: ?*Diagnostics,
) anyerror!void {
    if (value != .object) {
        Diagnostics.set(diag, "{s}: node definition must be an object", .{path});
        return error.InvalidNode;
    }
    const obj = value.object;
    const kind = try getString(obj, "kind", path, diag);
    const name = try getString(obj, "name", path, diag);

    for (tree.nodes.items) |existing| {
        if (std.mem.eql(u8, existing.name, name)) {
            Diagnostics.set(diag, "{s}: duplicate node name '{s}'", .{ path, name });
            return error.DuplicateNodeName;
        }
    }

    const params = obj.get("params");
    if (params) |p| {
        const params_path = try std.fmt.allocPrint(arena, "{s}.params", .{path});
        try validateParams(p, params_path, diag);
    }

    const node = factory.createNode(tree.context, kind, name) catch |err| {
        switch (err) {
            error.UnknownNodeType => Diagnostics.set(diag, "{s}: unknown node kind '{s}' (node '{s}')", .{ path, kind, name }),
            else => Diagnostics.set(diag, "{s}: failed to create node '{s}' of kind '{s}': {t}", .{ path, name, kind, err }),
        }
        return err;
    };
    var attached = false;
    errdefer if (!attached) node.deinit(factory.gpa);

    if (params) |p| {
        var iter = p.object.iterator();
        while (iter.next()) |elem| {
            try node.putValue(elem.key_ptr.*, paramValue(elem.value_ptr.*).?);
        }
    }

    // Check the node's child / children against its kind before attaching it
    const child_def = obj.get("child");
    const children_def = obj.get("children");
    switch (node.data) {
        .control => {
            if (child_def != null) {
                Diagnostics.set(diag, "{s}: Control node '{s}' takes \"children\", not \"child\"", .{ path, name });
                return error.UnexpectedChildren;
            }
            const ok = if (children_def) |c| c == .array and c.array.items.len > 0 else false;
            if (!ok) {
                Diagnostics.set(diag, "{s}: Control node '{s}' requires a non-empty \"children\" array", .{ path, name });
                return error.MissingChildren;
            }
        },
        .decorator => {
            if (children_def != null) {
                Diagnostics.set(diag, "{s}: Decorator node '{s}' takes a single \"child\", not \"children\"", .{ path, name });
                return error.UnexpectedChildren;
            }
            if (child_def == null) {
                Diagnostics.set(diag, "{s}: Decorator node '{s}' requires a \"child\"", .{ path, name });
                return error.MissingChild;
            }
        },
        .action, .condition => {
            if (child_def != null or children_def != null) {
                Diagnostics.set(diag, "{s}: {t} node '{s}' cannot have children", .{ path, node.kind(), name });
                return error.UnexpectedChildren;
            }
        },
    }

    // Hand ownership of the node to its parent (or the tree)
    if (parent) |pnode| {
        switch (pnode.data) {
            .control => |*c| try c.addChild(factory.gpa, node),
            .decorator => |*d| d.child = node,
            // Only Controls and Decorators recurse into children
            .action, .condition => unreachable,
        }
    } else {
        tree.root = node;
    }
    attached = true;

    try tree.addNode(node);

    switch (node.data) {
        .control => for (children_def.?.array.items, 0..) |child, i| {
            const child_path = try std.fmt.allocPrint(arena, "{s}.children[{d}]", .{ path, i });
            try factory.parseNode(tree, arena, node, child, child_path, diag);
        },
        .decorator => {
            const child_path = try std.fmt.allocPrint(arena, "{s}.child", .{path});
            try factory.parseNode(tree, arena, node, child_def.?, child_path, diag);
        },
        .action, .condition => {},
    }
}

/// Get a required string field from a JSON node definition
fn getString(obj: std.json.ObjectMap, field: []const u8, path: []const u8, diag: ?*Diagnostics) LoadError![]const u8 {
    const v = obj.get(field) orelse {
        Diagnostics.set(diag, "{s}: missing required field \"{s}\"", .{ path, field });
        return error.InvalidNode;
    };
    if (v != .string) {
        Diagnostics.set(diag, "{s}: field \"{s}\" must be a string", .{ path, field });
        return error.InvalidNode;
    }
    return v.string;
}

/// Ensure that `params` is an object whose values can all be stored in a Blackboard
fn validateParams(params: std.json.Value, path: []const u8, diag: ?*Diagnostics) LoadError!void {
    if (params != .object) {
        Diagnostics.set(diag, "{s}: must be an object", .{path});
        return error.InvalidParams;
    }
    var iter = params.object.iterator();
    while (iter.next()) |elem| {
        if (paramValue(elem.value_ptr.*) == null) {
            Diagnostics.set(diag, "{s}.{s}: unsupported value type '{t}' (expected integer, float, bool, or string)", .{
                path, elem.key_ptr.*, elem.value_ptr.*,
            });
            return error.InvalidParams;
        }
    }
}

/// Convert a JSON value to a Blackboard Value, or null if the type is unsupported.
/// String values are borrowed from the JSON; the Blackboard copies them.
fn paramValue(v: std.json.Value) ?Value {
    return switch (v) {
        .string => |s| .{ .string = s },
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .null, .number_string, .array, .object => null,
    };
}

const Node = @import("Node.zig");
const NodeImpl = @import("node_impl.zig").NodeImpl;
const Context = @import("Context.zig");
const Value = @import("blackboard.zig").Value;
const Tree = @import("Tree.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;

////////////////////////////////////////////////////////////////////////////////
// Unit Tests
////////////////////////////////////////////////////////////////////////////////

test "[Factory] Register & Create Nodes" {
    const gpa = std.testing.allocator;
    var factory = try Factory.init(std.testing.io, gpa);
    defer factory.deinit();

    var ctx = try Context.create(gpa);
    defer ctx.deinit();

    const Sequence = @import("nodes/controls/Sequence.zig");
    const AlwaysRunning = @import("nodes/actions/AlwaysRunning.zig");

    try factory.register("Sequence", Sequence);
    try factory.register("AlwaysRunning", AlwaysRunning);

    const seq_node: *Node = try factory.createNode(ctx, "Sequence", "seq-1");
    const ar_node: *Node = try factory.createNode(ctx, "AlwaysRunning", "run-1");
    defer seq_node.deinit(gpa);
    defer ar_node.deinit(gpa);
}

test "[Factory] Load from JSON" {
    const gpa = std.testing.allocator;
    var factory = try Factory.init(std.testing.io, gpa);
    defer factory.deinit();

    var ctx = try Context.create(gpa);
    defer ctx.deinit();

    const Sequence = @import("nodes/controls/Sequence.zig");
    const Inverter = @import("nodes/decorators/Inverter.zig");
    const AlwaysSuccess = @import("nodes/conditions/AlwaysSuccess.zig");
    const AlwaysFailure = @import("nodes/conditions/AlwaysFailure.zig");

    try factory.register("Sequence", Sequence);
    try factory.register("Inverter", Inverter);
    try factory.register("AlwaysFailure", AlwaysFailure);
    try factory.register("AlwaysSuccess", AlwaysSuccess);

    const json = @embedFile("tests/json/test-tree.json");

    var tree = try factory.loadFromJson(ctx, json);
    defer tree.deinit();

    try std.testing.expectEqualStrings(tree.context.blackboard.get("some-global-value").?.string, "Hello, Bonzai!");

    try std.testing.expectEqual(.running, tree.tick());
    try std.testing.expectEqual(.success, tree.tick());
}

fn testFactory(gpa: Allocator) !Factory {
    var factory = try Factory.init(std.testing.io, gpa);
    errdefer factory.deinit();
    try @import("bonzai.zig").registerBuiltinTypes(&factory);
    return factory;
}

test "[Factory] JSON errors are reported without leaking" {
    const gpa = std.testing.allocator;
    var factory = try testFactory(gpa);
    defer factory.deinit();

    var ctx = try Context.create(gpa);
    defer ctx.deinit();

    const Case = struct { json: []const u8, err: anyerror, msg: []const u8 };
    const cases = [_]Case{
        .{ .json = "{\"root\": ", .err = error.InvalidJson, .msg = "invalid JSON at line 1" },
        .{ .json = "[1, 2]", .err = error.MissingRoot, .msg = "must be an object" },
        .{ .json = "{}", .err = error.MissingRoot, .msg = "missing \"root\"" },
        .{ .json = "{\"root\": 5}", .err = error.InvalidNode, .msg = "root: node definition must be an object" },
        .{ .json = "{\"root\": {\"name\": \"x\"}}", .err = error.InvalidNode, .msg = "missing required field \"kind\"" },
        .{ .json = "{\"root\": {\"kind\": \"Sequence\", \"name\": 1}}", .err = error.InvalidNode, .msg = "\"name\" must be a string" },
        .{
            .json = "{\"root\": {\"kind\": \"Sequence\", \"name\": \"r\", \"children\": [{\"kind\": \"Bogus\", \"name\": \"b\"}]}}",
            .err = error.UnknownNodeType,
            .msg = "root.children[0]: unknown node kind 'Bogus'",
        },
        .{ .json = "{\"root\": {\"kind\": \"Sequence\", \"name\": \"r\"}}", .err = error.MissingChildren, .msg = "non-empty \"children\"" },
        .{ .json = "{\"root\": {\"kind\": \"Sequence\", \"name\": \"r\", \"children\": []}}", .err = error.MissingChildren, .msg = "non-empty \"children\"" },
        .{ .json = "{\"root\": {\"kind\": \"Inverter\", \"name\": \"i\"}}", .err = error.MissingChild, .msg = "requires a \"child\"" },
        .{
            .json = "{\"root\": {\"kind\": \"AlwaysSuccess\", \"name\": \"s\", \"child\": {}}}",
            .err = error.UnexpectedChildren,
            .msg = "condition node 's' cannot have children",
        },
        .{
            .json = "{\"root\": {\"kind\": \"Sequence\", \"name\": \"r\", \"children\": [{\"kind\": \"AlwaysSuccess\", \"name\": \"r\"}]}}",
            .err = error.DuplicateNodeName,
            .msg = "root.children[0]: duplicate node name 'r'",
        },
        .{
            .json = "{\"root\": {\"kind\": \"Inverter\", \"name\": \"i\", \"child\": {\"kind\": \"AlwaysSuccess\", \"name\": \"s\", \"params\": {\"bad\": [1]}}}}",
            .err = error.InvalidParams,
            .msg = "root.child.params.bad: unsupported value type 'array'",
        },
        .{
            .json = "{\"root\": {\"kind\": \"AlwaysSuccess\", \"name\": \"s\"}, \"params\": {\"g\": \"ok\", \"n\": null}}",
            .err = error.InvalidParams,
            .msg = "params.n: unsupported value type 'null'",
        },
    };

    for (cases) |case| {
        var diag: Diagnostics = .{};
        try std.testing.expectError(case.err, factory.loadFromJsonDiag(ctx, case.json, &diag));
        std.testing.expect(std.mem.indexOf(u8, diag.message(), case.msg) != null) catch |err| {
            std.debug.print("expected message containing \"{s}\", got \"{s}\"\n", .{ case.msg, diag.message() });
            return err;
        };
    }

    // A failed load must not modify the Context
    try std.testing.expectEqual(@as(u32, 0), ctx.blackboard.count());
}

test "[Factory] Load same tree twice into one Context" {
    const gpa = std.testing.allocator;
    var factory = try testFactory(gpa);
    defer factory.deinit();

    var ctx = try Context.create(gpa);
    defer ctx.deinit();

    const json = @embedFile("tests/json/test-tree.json");
    var t1 = try factory.loadFromJson(ctx, json);
    defer t1.deinit();
    var t2 = try factory.loadFromJson(ctx, json);
    defer t2.deinit();

    try std.testing.expectEqualStrings("Hello, Bonzai!", ctx.getBlackboardValue("some-global-value").?.string);
}

test "[Factory] Load from JSON is leak-free under allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var factory = try testFactory(gpa);
            defer factory.deinit();

            var ctx = try Context.create(gpa);
            defer ctx.deinit();

            var tree = try factory.loadFromJson(ctx, @embedFile("tests/json/test-tree.json"));
            defer tree.deinit();
        }
    }.run, .{});
}
