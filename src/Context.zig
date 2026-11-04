//! The Context struct is shared among all nodes in a Tree,
//! and stores contextual information about the execution of the behavior tree.
const Context = @This();

/// General-purpose allocator shared across the tree
gpa: std.mem.Allocator,

/// All nodes in the tree have access to this global key/value store
blackboard: Blackboard,

/// Optional custom data to use throughout a behavior tree.
/// Any resources here are not managed by the Context.
data: ?*anyopaque,

/// Initialize a new Context struct
pub fn create(alloc: std.mem.Allocator) !*Context {
    var self = try alloc.create(Context);
    self.gpa = alloc;
    self.blackboard = Blackboard.init(self.gpa);
    self.data = null;
    return self;
}

/// Initialize a new Context struct with a custom 'data' field.
pub fn createWithData(alloc: std.mem.Allocator, data: ?*anyopaque) !*Context {
    var self = try alloc.create(Context);
    self.gpa = alloc;
    self.blackboard = Blackboard.init(self.gpa);
    self.data = data;
    return self;
}

/// Free all resources, including string values in the Blackboard.
/// Does not deinit the `data` field. If you need to handle custom cleanup on your `data`
/// object, use `deinitWithData()`.
pub fn deinit(self: *Context) void {
    var iter = self.blackboard.iterator();
    while (iter.next()) |elem| {
        switch (elem.value_ptr.*) {
            .string => |s| self.gpa.free(s),
            else => {},
        }
        self.gpa.free(elem.key_ptr.*);
    }
    self.blackboard.deinit();
    self.gpa.destroy(self);
}

/// Free all resources, including string values in the Blackboard.
/// If the 'data' type has a deinit method, calls it as well.
///
/// @param T: Type of the 'data' field
///
/// The 'deinit()' method must take the form of either:
///   `pub fn deinit(d: *T) void`
/// or:
///   `pub fn deinit(d: *T, std.mem.Allocator) void`
pub fn deinitWithData(self: *Context, T: type) void {
    if (self.data) |d_ptr| {
        if (std.meta.hasFn(T, "deinit")) {
            const info = @typeInfo(@TypeOf(@field(T, "deinit"))).@"fn";
            if (info.attrs.varargs)
                @compileError("Cannot inspect argument types for variadic function");

            const ptypes = info.param_types;
            if (ptypes.len < 1 or ptypes[0] == null or ptypes[0].? != *T) {
                @compileError("Context.data.deinit() must take one argument, 'd: *@This()'");
            }

            var d: *T = @ptrCast(@alignCast(d_ptr));
            if (ptypes.len == 1) {
                d.deinit();
            } else if (ptypes.len == 2 and ptypes[1] != null and ptypes[1].? == std.mem.Allocator) {
                d.deinit(self.gpa);
            } else {
                @compileError("Context.data.deinit() must take either (d: *@This()) or (d: *@This(), m: Allocator)");
            }
        }
    }
    self.deinit();
}

/// Get a value from the Blackboard, returning null if not found
pub fn getBlackboardValue(self: *const Context, key: []const u8) ?Value {
    return self.blackboard.get(key);
}

/// Put a value into the blackboard.
/// Takes ownership of all string values, and automatically frees them
/// when they go out of scope.
pub fn putBlackboardValue(self: *Context, key: []const u8, value: Value) !void {
    if (self.blackboard.get(key)) |current| {
        switch (current) {
            .string => |s| self.gpa.free(s),
            else => {},
        }
    }

    switch (value) {
        .string => |s| {
            const owned = try self.gpa.dupe(u8, s);
            try self.blackboard.put(key, owned);
        },
        else => try self.blackboard.put(key, value),
    }
}

// TODO: add useful methods such as:
// - active node
// -

/// A generic Value to be stored in the Blackboard.
/// We limit ourselves to types which may easily be loaded from JSON.
pub const Value = union(enum(u8)) {
    int: i64,
    float: f64,
    bool: bool,
    string: []const u8,
};

/// A generic key:value store for contextual data within the behavior tree
pub const Blackboard = std.StringHashMap(Value);

const std = @import("std");
