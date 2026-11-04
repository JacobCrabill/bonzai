//! Key/value storage shared by the Context (global) and each Node (private).
//!
//! A Blackboard owns all of its keys and string values; always modify it through
//! `put()` and release it with `deinit()` so that ownership stays consistent.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// A generic Value to be stored in a Blackboard.
/// We limit ourselves to types which may easily be loaded from JSON.
pub const Value = union(enum(u8)) {
    int: i64,
    float: f64,
    bool: bool,
    string: []const u8,
};

/// A generic key:value store for contextual data within the behavior tree
pub const Blackboard = std.StringHashMap(Value);

/// Insert or replace a value, copying the key (if new) and any string value
/// with the Blackboard's allocator. On error the Blackboard is left unchanged.
pub fn put(bb: *Blackboard, key: []const u8, value: Value) Allocator.Error!void {
    const gpa = bb.allocator;

    const owned_value: Value = switch (value) {
        .string => |s| .{ .string = try gpa.dupe(u8, s) },
        else => value,
    };
    errdefer freeValue(gpa, owned_value);

    const owned_key = try gpa.dupe(u8, key);
    const gop = bb.getOrPut(owned_key) catch |err| {
        gpa.free(owned_key);
        return err;
    };
    if (gop.found_existing) {
        // The map keeps its existing key; release the old value
        gpa.free(owned_key);
        freeValue(gpa, gop.value_ptr.*);
    }
    gop.value_ptr.* = owned_value;
}

/// Free all keys, string values, and the map itself.
pub fn deinit(bb: *Blackboard) void {
    var iter = bb.iterator();
    while (iter.next()) |elem| {
        freeValue(bb.allocator, elem.value_ptr.*);
        bb.allocator.free(elem.key_ptr.*);
    }
    bb.deinit();
}

fn freeValue(gpa: Allocator, value: Value) void {
    switch (value) {
        .string => |s| gpa.free(s),
        else => {},
    }
}

test "[Blackboard] put copies and replaces without leaking" {
    var bb = Blackboard.init(std.testing.allocator);
    defer deinit(&bb);

    var key_buf = "key".*;
    try put(&bb, &key_buf, .{ .string = "one" });
    key_buf[0] = 'X'; // caller's buffer may change after put()
    try put(&bb, "key", .{ .string = "two" });
    try put(&bb, "key", .{ .int = 3 });
    try put(&bb, "other", .{ .string = "four" });

    try std.testing.expectEqual(@as(usize, 2), bb.count());
    try std.testing.expectEqual(@as(i64, 3), bb.get("key").?.int);
    try std.testing.expectEqualStrings("four", bb.get("other").?.string);
}

test "[Blackboard] put is leak-free under allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var bb = Blackboard.init(gpa);
            defer deinit(&bb);
            try put(&bb, "a", .{ .string = "x" });
            try put(&bb, "a", .{ .string = "y" });
            try put(&bb, "b", .{ .float = 1.5 });
        }
    }.run, .{});
}
