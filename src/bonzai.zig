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
    pub const Sequence = @import("nodes/controls/Sequence.zig");
    pub const Fallback = @import("nodes/controls/Fallback.zig");
    pub const StatefulAction = @import("nodes/actions/StatefulAction.zig");
    pub const Inverter = @import("nodes/decorators/Inverter.zig");
    pub const RunUntilSuccess = @import("nodes/decorators/RunUntilSuccess.zig");
};

pub const loggers = struct {
    pub const StdoutLogger = @import("loggers/StdoutLogger.zig");
};

test "All Bonzai Module Tests" {
    _ = nodes.Sequence;
    _ = nodes.Fallback;
    _ = nodes.StatefulAction;
    _ = nodes.Inverter;
    _ = nodes.RunUntilSuccess;

    std.testing.refAllDecls(@This());
}
