//! The Context struct is shared among all nodes in a Tree,
//! and stores contextual information about the execution of the behavior tree.
const Context = @This();

/// The Io implementation shared across the tree, e.g. for timers and background work
io: std.Io,

/// General-purpose allocator shared across the tree
gpa: std.mem.Allocator,

/// All nodes in the tree have access to this global key/value store
blackboard: Blackboard,

/// Optional custom data to use throughout a behavior tree; access it with `getData(T)`.
/// The data is borrowed: it is only cleaned up by `deinitWithData()`.
data: ?*anyopaque = null,

/// Identifies the type of `data`, so that `getData(T)` can verify it
data_type: ?TypeId = null,

/// The name of the type of `data`, for error messages
data_type_name: []const u8 = "",

/// Type-erased `deinit` method of the `data` type, if it has one
data_deinit: ?*const fn (data: *anyopaque, gpa: Allocator) void = null,

/// Initialize a new Context struct
pub fn create(io: std.Io, gpa: Allocator) !*Context {
    const self = try gpa.create(Context);
    self.* = .{
        .io = io,
        .gpa = gpa,
        .blackboard = Blackboard.init(gpa),
    };
    return self;
}

/// Initialize a new Context struct with custom data, given as a pointer (e.g. `&my_data`).
/// The data is not copied, and must outlive the Context.
///
/// If the data type has a `deinit` method, `deinitWithData()` will call it. The method must
/// take the form of either `pub fn deinit(self: *T) void` or
/// `pub fn deinit(self: *T, gpa: std.mem.Allocator) void`.
pub fn createWithData(io: std.Io, gpa: Allocator, data: anytype) !*Context {
    const T = DataType(@TypeOf(data));
    const self = try create(io, gpa);
    self.data = @ptrCast(data);
    self.data_type = typeId(T);
    self.data_type_name = @typeName(T);
    self.data_deinit = dataDeinitFn(T);
    return self;
}

/// Get the custom data given to `createWithData()`, or null if there is none.
/// Panics (in safe builds) if the data is not of type `T`.
pub fn getData(self: *const Context, comptime T: type) ?*T {
    const d_ptr = self.data orelse return null;
    if (std.debug.runtime_safety and self.data_type != typeId(T)) {
        std.debug.panic("Context.getData: data is of type '{s}', not '{s}'", .{ self.data_type_name, @typeName(T) });
    }
    return @ptrCast(@alignCast(d_ptr));
}

/// Free all resources, including string values in the Blackboard.
/// Does not deinit the `data` field; to also clean up `data`, use `deinitWithData()`.
pub fn deinit(self: *Context) void {
    bb.deinit(&self.blackboard);
    self.gpa.destroy(self);
}

/// Free all resources, and call the `data` type's `deinit` method (if it has one).
pub fn deinitWithData(self: *Context) void {
    if (self.data) |d| {
        if (self.data_deinit) |deinit_fn| deinit_fn(d, self.gpa);
    }
    self.deinit();
}

/// Get a value from the Blackboard, returning null if not found
pub fn getBlackboardValue(self: *const Context, key: []const u8) ?Value {
    return self.blackboard.get(key);
}

/// Put a value into the blackboard, replacing any existing value.
/// The key and any string value are copied; the caller retains ownership of its arguments.
pub fn putBlackboardValue(self: *Context, key: []const u8, value: Value) !void {
    try bb.put(&self.blackboard, key, value);
}

// TODO: add useful methods such as:
// - active node
// -

/// A generic Value to be stored in the Blackboard.
/// We limit ourselves to types which may easily be loaded from JSON.
pub const Value = bb.Value;

/// A generic key:value store for contextual data within the behavior tree
pub const Blackboard = bb.Blackboard;

/// Validate the pointer type given to `createWithData()`, returning the pointee type
fn DataType(comptime P: type) type {
    const info = @typeInfo(P);
    if (info != .pointer or info.pointer.size != .one or info.pointer.attrs.@"const" or
        @typeInfo(info.pointer.child) == .@"opaque")
    {
        @compileError("Context.createWithData: expected a mutable pointer to the data (e.g. `&my_data`), found " ++ @typeName(P));
    }
    return info.pointer.child;
}

/// Generate a type-erased wrapper around `T.deinit`, or null if T has no deinit method
fn dataDeinitFn(comptime T: type) ?*const fn (*anyopaque, Allocator) void {
    if (!std.meta.hasFn(T, "deinit")) return null;

    const sig_error = "Context data: " ++ @typeName(T) ++ ".deinit must be `pub fn deinit(self: *" ++
        @typeName(T) ++ ") void` or `pub fn deinit(self: *" ++ @typeName(T) ++ ", gpa: Allocator) void`";
    const info = @typeInfo(@TypeOf(T.deinit)).@"fn";
    const params = info.param_types;
    const ok = info.return_type == void and switch (params.len) {
        1 => params[0] == *T,
        2 => params[0] == *T and params[1] == Allocator,
        else => false,
    };
    if (!ok) @compileError(sig_error);

    return struct {
        fn deinit(ptr: *anyopaque, gpa: Allocator) void {
            const d: *T = @ptrCast(@alignCast(ptr));
            if (params.len == 2) d.deinit(gpa) else d.deinit();
        }
    }.deinit;
}

const bb = @import("blackboard.zig");
const TypeId = @import("type_id.zig").TypeId;
const typeId = @import("type_id.zig").typeId;

const std = @import("std");
const Allocator = std.mem.Allocator;

////////////////////////////////////////////////////////////////////////////////
// Unit Tests
////////////////////////////////////////////////////////////////////////////////

test "[Context] getData" {
    const gpa = std.testing.allocator;

    const Data = struct { value: u32 };
    var data: Data = .{ .value = 42 };

    var ctx = try Context.createWithData(std.testing.io, gpa, &data);
    defer ctx.deinit();

    const d = ctx.getData(Data).?;
    try std.testing.expectEqual(&data, d);
    d.value += 1;
    try std.testing.expectEqual(@as(u32, 43), data.value);

    var empty = try Context.create(std.testing.io, gpa);
    defer empty.deinit();
    try std.testing.expect(empty.getData(Data) == null);
}

test "[Context] deinitWithData calls the data's deinit" {
    const gpa = std.testing.allocator;

    // deinit(self: *T, gpa: Allocator)
    const WithAlloc = struct {
        buf: []u8,
        pub fn deinit(self: *@This(), alloc: Allocator) void {
            alloc.free(self.buf);
        }
    };
    var a: WithAlloc = .{ .buf = try gpa.alloc(u8, 16) };
    var ctx_a = try Context.createWithData(std.testing.io, gpa, &a);
    ctx_a.deinitWithData(); // the testing allocator would report a leak otherwise

    // deinit(self: *T)
    const NoAlloc = struct {
        called: bool = false,
        pub fn deinit(self: *@This()) void {
            self.called = true;
        }
    };
    var b: NoAlloc = .{};
    var ctx_b = try Context.createWithData(std.testing.io, gpa, &b);
    ctx_b.deinitWithData();
    try std.testing.expect(b.called);

    // No deinit method at all
    const Plain = struct { x: u32 = 0 };
    var c: Plain = .{};
    var ctx_c = try Context.createWithData(std.testing.io, gpa, &c);
    ctx_c.deinitWithData();

    // Plain deinit() leaves the data alone
    var b2: NoAlloc = .{};
    var ctx_d = try Context.createWithData(std.testing.io, gpa, &b2);
    ctx_d.deinit();
    try std.testing.expect(!b2.called);
}
