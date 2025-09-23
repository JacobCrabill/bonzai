//! A simple, modular Behavior Tree library written in Zig.
const std = @import("std");

pub const Node = @import("Node.zig");
pub const Context = @import("Context.zig");
pub const Tree = @import("Tree.zig");
pub const Factory = @import("Factory.zig");
pub const Logger = @import("Logger.zig");

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
        pub const StatefulAction = @import("nodes/actions/StatefulAction.zig");
        pub const AlwaysRunning = @import("nodes/actions//AlwaysRunning.zig");
    };

    pub const decorators = struct {
        pub const Inverter = @import("nodes/decorators/Inverter.zig");
        pub const RunUntilSuccess = @import("nodes/decorators/RunUntilSuccess.zig");
    };

    pub const controls = struct {
        pub const Sequence = @import("nodes/controls/Sequence.zig");
        pub const Fallback = @import("nodes/controls/Fallback.zig");
    };
};

pub const loggers = struct {
    pub const StdoutLogger = @import("loggers/StdoutLogger.zig");
};

/// Registar all Node types built in to Bonzai
pub fn registerBuiltinTypes(factory: *Factory) !void {
    try factory.registerNode("Sequence", nodes.controls.Sequence.create);
    try factory.registerNode("Fallback", nodes.controls.Fallback.create);
    try factory.registerNode("Inverter", nodes.decorators.Inverter.create);
    try factory.registerNode("RunUntilSuccess", nodes.decorators.RunUntilSuccess.create);
    try factory.registerNode("AlwaysRunning", nodes.actions.AlwaysRunning.create);
    try factory.registerNode("AlwaysSuccess", nodes.conditions.AlwaysSuccess.create);
    try factory.registerNode("AlwaysFailure", nodes.conditions.AlwaysFailure.create);
}

test "All Bonzai Module Tests" {
    std.testing.refAllDecls(@This());
}

test "Parse from JSON File" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const str = @embedFile("tests/json/test-tree.json");

    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, str, .{});

    var stdout = std.fs.File.stdout().writer(&.{});
    const writer = &stdout.interface;
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, writer);

    // Examle of traversing the tree
    const nodelist = value.object.get("nodes").?;
    const root_kind = nodelist.array.items[0].object.get("kind").?.string;
    try std.testing.expectEqualStrings("Sequence", root_kind);
}

// NOTE: Ziggy cannot handle any form of recursive types,
// while basically _all_ of our types are recursive
// test "Parse from Ziggy file" {
//     const ziggy = @import("ziggy");
//     const gpa = std.testing.allocator;
//     var arena_state = std.heap.ArenaAllocator.init(gpa);
//     defer arena_state.deinit();
//     const arena = arena_state.allocator();
//
//     const ZiggyNode = struct {
//         const Self = @This();
//         kind: []const u8,
//         name: []const u8,
//         // children: ?*anyopaque,
//         // children: ?[]const *@This() = null,
//         data: ?std.json.Value = null,
//         // const Child = union {
//         //     child: Self,
//         //     children: []const Self,
//         // };
//     };
//
//     const ZiggyTree = struct {
//         nodes: []const ZiggyNode,
//     };
//
//     const case = @embedFile("tests/ziggy/test-tree.ziggy");
//
//     var diag: ziggy.Diagnostic = .{ .path = null };
//     _ = ziggy.parseLeaky(ZiggyTree, arena, case, .{
//         .diagnostic = &diag,
//     }) catch |err| {
//         if (err != error.Syntax) @panic("wrong error!");
//         std.debug.print("{f}", .{diag.fmt(case)});
//         std.process.exit(1);
//     };
// }
