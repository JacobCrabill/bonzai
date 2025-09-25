const std = @import("std");

pub const Value = union(enum(u8)) {
    int: i64,
    float: f64,
    bool: bool,
    string: []const u8,
};

/// A generic key:value store for contextual data within the behavior tree
pub const Blackboard = std.StringHashMap(Value);
