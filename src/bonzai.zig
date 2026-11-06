//! A simple, modular Behavior Tree library written in Zig.
const std = @import("std");

pub const Node = @import("Node.zig");
pub const NodeImpl = @import("node_impl.zig").NodeImpl;
pub const nodeOf = @import("node_impl.zig").nodeOf;
pub const Context = @import("Context.zig");
pub const Tree = @import("Tree.zig");
pub const Factory = @import("Factory.zig");
pub const Logger = @import("Logger.zig");
pub const blackboard = @import("blackboard.zig");

pub const base_types = struct {
    pub const Decorator = @import("base_types/Decorator.zig");
    pub const Control = @import("base_types/Control.zig");
};

pub const nodes = struct {
    pub const conditions = struct {
        pub const AlwaysSuccess = @import("nodes/conditions/AlwaysSuccess.zig");
        pub const AlwaysFailure = @import("nodes/conditions/AlwaysFailure.zig");
    };

    pub const actions = struct {
        pub const AlwaysRunning = @import("nodes/actions/AlwaysRunning.zig");
    };

    pub const decorators = struct {
        pub const Inverter = @import("nodes/decorators/Inverter.zig");
        pub const RunUntilSuccess = @import("nodes/decorators/RunUntilSuccess.zig");
        pub const Repeat = @import("nodes/decorators/Repeat.zig");
    };

    pub const controls = struct {
        pub const Sequence = @import("nodes/controls/Sequence.zig");
        pub const Fallback = @import("nodes/controls/Fallback.zig");
        pub const Parallel = @import("nodes/controls/Parallel.zig");
    };
};

pub const loggers = struct {
    pub const StdoutLogger = @import("loggers/StdoutLogger.zig");
};

/// Register all Node types built in to Bonzai
pub fn registerBuiltinTypes(factory: *Factory) !void {
    try factory.register("Sequence", nodes.controls.Sequence);
    try factory.register("Fallback", nodes.controls.Fallback);
    try factory.register("Parallel", nodes.controls.Parallel);
    try factory.register("Inverter", nodes.decorators.Inverter);
    try factory.register("RunUntilSuccess", nodes.decorators.RunUntilSuccess);
    try factory.register("Repeat", nodes.decorators.Repeat);
    try factory.register("AlwaysRunning", nodes.actions.AlwaysRunning);
    try factory.register("AlwaysSuccess", nodes.conditions.AlwaysSuccess);
    try factory.register("AlwaysFailure", nodes.conditions.AlwaysFailure);
}

////////////////////////////////////////////////////////////////////////////////
// Unit Tests
////////////////////////////////////////////////////////////////////////////////

test "All Bonzai Module Tests" {
    std.testing.refAllDecls(@This());
    _ = @import("type_id.zig");
}

test "Parse from JSON File" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const str = @embedFile("tests/json/test-tree.json");

    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, str, .{});

    var stdout = std.Io.File.stdout().writer(std.testing.io, &.{});
    const writer = &stdout.interface;
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, writer);

    // Examle of traversing the tree
    const root = value.object.get("root").?;
    const root_kind = root.object.get("kind").?.string;
    try std.testing.expectEqualStrings("Sequence", root_kind);
}
