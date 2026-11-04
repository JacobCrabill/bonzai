//! `NodeImpl(T)` generates all of the boilerplate needed to turn a plain struct into a
//! Node type: allocation, the vtable, destruction, and type-checked casting.
//!
//! The implementation struct `T` declares:
//!
//! ```zig
//! const MyAction = struct {
//!     // Required: one of .action, .condition, .decorator, .control
//!     pub const kind: bonzai.Node.Kind = .action;
//!
//!     // Per-instance state. Every field must have a default value.
//!     count: u32 = 0,
//!
//!     // Required (unless using the stateful hooks below): called on every tick.
//!     pub fn tick(self: *MyAction, node: *bonzai.Node) bonzai.Node.Status { ... }
//!
//!     // Optional: called when the node is halted (reset to Idle).
//!     // Children of Controls and Decorators are halted automatically.
//!     pub fn halt(self: *MyAction, node: *bonzai.Node) void { ... }
//!
//!     // Optional: release any resources owned by `self`.
//!     pub fn deinit(self: *MyAction, gpa: std.mem.Allocator) void { ... }
//! };
//! ```
//!
//! Instead of `tick`, an Action may implement the "stateful" hooks:
//!
//! - `onStarted` (optional): first tick after being Idle; returns the new Status (default: Running).
//! - `onRunning` (required): every subsequent tick while Running.
//! - `onHalted`  (optional): called when halted while not Idle.
//!
//! Every hook takes `self: *T` as its first parameter, and may optionally take
//! `node: *Node` as its second; `deinit` may optionally take an Allocator instead.
//!
//! Register the type with `factory.register("MyAction", MyAction)`, create one directly
//! with `NodeImpl(MyAction).create(...)`, get the `*MyAction` back from a `*Node` with
//! `MyAction.cast(node)` or `node.tryAs(MyAction)`, and the `*Node` from a `*MyAction`
//! with `bonzai.nodeOf(self)`.

/// The concrete type generated for each Node implementation `T`.
pub fn NodeImpl(comptime T: type) type {
    comptime validate(T);

    return struct {
        const Self = @This();

        node: Node,
        impl: T,

        /// The user-defined implementation type
        pub const Impl = T;

        const stateful = @hasDecl(T, "onRunning");

        /// The vtable shared by all instances of this type. Its `type_id` identifies the
        /// type of a `*Node` at runtime (see `isInstance()`).
        pub const vtable: Node.VTable = .{
            .tick = tick,
            .halt = if (@hasDecl(T, "halt") or @hasDecl(T, "onHalted")) halt else null,
            .deinit = deinit,
            .type_id = typeId(T),
            .type_name = @typeName(T),
        };

        /// Create a new instance, returning a pointer to its base Node.
        /// Matches the signature of `Factory.BuilderFn`.
        pub fn create(gpa: Allocator, ctx: *Context, name: []const u8) anyerror!*Node {
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            self.* = .{
                .node = try Node.init(gpa, ctx, name, T.kind, vtable),
                .impl = .{},
            };
            return &self.node;
        }

        /// True if `node` was created by this NodeImpl type
        pub fn isInstance(node: *const Node) bool {
            return node.vtable.type_id == typeId(T);
        }

        /// Get the implementation from a base Node. Panics (in safe builds) if the node
        /// is not of this type.
        pub fn cast(node: *Node) *T {
            if (std.debug.runtime_safety and !isInstance(node)) {
                std.debug.panic("Node '{s}' is of type '{s}', not '{s}'", .{ node.name, node.vtable.type_name, @typeName(T) });
            }
            return &fromNode(node).impl;
        }

        /// Get the base Node from the implementation
        pub fn nodeOf(impl: *T) *Node {
            const self: *Self = @alignCast(@fieldParentPtr("impl", impl));
            return &self.node;
        }

        fn fromNode(node: *Node) *Self {
            return @alignCast(@fieldParentPtr("node", node));
        }

        fn tick(node: *Node) Node.Status {
            const impl = &fromNode(node).impl;
            if (!stateful) return call(T.tick, impl, node);

            return switch (node.status) {
                .idle => if (@hasDecl(T, "onStarted")) call(T.onStarted, impl, node) else .running,
                .running => call(T.onRunning, impl, node),
                .success, .failure => |s| s,
            };
        }

        fn halt(node: *Node) void {
            const impl = &fromNode(node).impl;
            if (@hasDecl(T, "halt")) call(T.halt, impl, node);
            if (@hasDecl(T, "onHalted") and node.status != .idle) call(T.onHalted, impl, node);
        }

        fn deinit(node: *Node, gpa: Allocator) void {
            const self = fromNode(node);
            if (@hasDecl(T, "deinit")) {
                const params = @typeInfo(@TypeOf(T.deinit)).@"fn".param_types;
                if (params.len == 2) T.deinit(&self.impl, gpa) else T.deinit(&self.impl);
            }
            gpa.destroy(self);
        }

        fn call(comptime f: anytype, impl: *T, node: *Node) ReturnType(f) {
            const params = @typeInfo(@TypeOf(f)).@"fn".param_types;
            return if (params.len == 2) f(impl, node) else f(impl);
        }
    };
}

/// Get the base Node of any `*T` that was created by `NodeImpl(T)`.
pub fn nodeOf(impl: anytype) *Node {
    const T = @typeInfo(@TypeOf(impl)).pointer.child;
    return NodeImpl(T).nodeOf(impl);
}

fn ReturnType(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?;
}

/// Produce clear compile errors for malformed implementation types
fn validate(comptime T: type) void {
    const name = @typeName(T);
    if (@typeInfo(T) != .@"struct") @compileError("NodeImpl(" ++ name ++ "): must be a struct");

    if (!@hasDecl(T, "kind"))
        @compileError("NodeImpl(" ++ name ++ "): missing `pub const kind: bonzai.Node.Kind`");
    const kind: Node.Kind = T.kind;

    const info = @typeInfo(T).@"struct";
    for (info.field_names, info.field_attrs) |field, attrs| {
        if (attrs.default_value_ptr == null)
            @compileError("NodeImpl(" ++ name ++ "): field '" ++ field ++ "' must have a default value");
    }

    const has_tick = @hasDecl(T, "tick");
    const has_stateful = @hasDecl(T, "onRunning") or @hasDecl(T, "onStarted") or @hasDecl(T, "onHalted");
    if (has_tick and has_stateful)
        @compileError("NodeImpl(" ++ name ++ "): declare either `tick` or the stateful hooks (onStarted/onRunning/onHalted), not both");
    if (has_stateful and !@hasDecl(T, "onRunning"))
        @compileError("NodeImpl(" ++ name ++ "): stateful nodes must declare `onRunning`");
    if (!has_tick and !has_stateful)
        @compileError("NodeImpl(" ++ name ++ "): missing `pub fn tick(self: *" ++ name ++ ", node: *Node) Node.Status`");
    if (has_stateful and kind != .action)
        @compileError("NodeImpl(" ++ name ++ "): stateful hooks are only supported for kind = .action");

    if (has_tick) checkHook(T, "tick", Node.Status);
    if (@hasDecl(T, "halt")) checkHook(T, "halt", void);
    if (@hasDecl(T, "onStarted")) checkHook(T, "onStarted", Node.Status);
    if (@hasDecl(T, "onRunning")) checkHook(T, "onRunning", Node.Status);
    if (@hasDecl(T, "onHalted")) checkHook(T, "onHalted", void);

    if (@hasDecl(T, "deinit")) {
        const sig = "`pub fn deinit(self: *" ++ name ++ ") void` or `pub fn deinit(self: *" ++ name ++ ", gpa: Allocator) void`";
        const f = fnInfo(T, "deinit");
        const ok = f.return_type == void and switch (f.param_types.len) {
            1 => f.param_types[0] == *T,
            2 => f.param_types[0] == *T and f.param_types[1] == Allocator,
            else => false,
        };
        if (!ok) @compileError("NodeImpl(" ++ name ++ "): deinit must be " ++ sig);
    }
}

fn checkHook(comptime T: type, comptime hook: []const u8, comptime Ret: type) void {
    const name = @typeName(T);
    const sig = "`pub fn " ++ hook ++ "(self: *" ++ name ++ ", node: *Node) " ++ @typeName(Ret) ++
        "` (the `node` parameter is optional)";
    const f = fnInfo(T, hook);
    const ok = f.return_type == Ret and switch (f.param_types.len) {
        1 => f.param_types[0] == *T,
        2 => f.param_types[0] == *T and f.param_types[1] == *Node,
        else => false,
    };
    if (!ok) @compileError("NodeImpl(" ++ name ++ "): " ++ hook ++ " must be " ++ sig);
}

fn fnInfo(comptime T: type, comptime decl: []const u8) std.lang.Type.Fn {
    const info = @typeInfo(@TypeOf(@field(T, decl)));
    if (info != .@"fn") @compileError("NodeImpl(" ++ @typeName(T) ++ "): '" ++ decl ++ "' must be a function");
    return info.@"fn";
}

const Node = @import("Node.zig");
const Context = @import("Context.zig");
const typeId = @import("type_id.zig").typeId;

const std = @import("std");
const Allocator = std.mem.Allocator;

////////////////////////////////////////////////////////////////////////////////
// Unit Tests
////////////////////////////////////////////////////////////////////////////////

const Counter = struct {
    pub const kind: Node.Kind = .action;

    ticks: u32 = 0,
    halted: u32 = 0,
    deinit_called: ?*bool = null,

    pub fn tick(self: *Counter) Node.Status {
        self.ticks += 1;
        return if (self.ticks >= 2) .success else .running;
    }

    pub fn halt(self: *Counter, node: *Node) void {
        std.debug.assert(nodeOf(self) == node);
        self.halted += 1;
        self.ticks = 0;
    }

    pub fn deinit(self: *Counter) void {
        if (self.deinit_called) |flag| flag.* = true;
    }
};

const Stateful = struct {
    pub const kind: Node.Kind = .action;

    started: u32 = 0,
    running: u32 = 0,
    halted: u32 = 0,

    pub fn onStarted(self: *Stateful) Node.Status {
        self.started += 1;
        return .running;
    }

    pub fn onRunning(self: *Stateful, _: *Node) Node.Status {
        self.running += 1;
        return if (self.running >= 2) .success else .running;
    }

    pub fn onHalted(self: *Stateful) void {
        self.halted += 1;
    }
};

test "[NodeImpl] tick, halt, cast, deinit" {
    const gpa = std.testing.allocator;
    var ctx = try Context.create(gpa);
    defer ctx.deinit();

    var deinit_called = false;
    {
        const node = try NodeImpl(Counter).create(gpa, ctx, "counter");
        defer node.deinit(gpa);

        try std.testing.expectEqual(.action, node.kind());
        try std.testing.expectEqualStrings("counter", node.name);

        const counter = node.as(Counter);
        counter.deinit_called = &deinit_called;
        try std.testing.expectEqual(node, nodeOf(counter));
        try std.testing.expect(node.tryAs(Stateful) == null);

        try std.testing.expectEqual(.running, node.tick());
        try std.testing.expectEqual(.success, node.tick());
        try std.testing.expectEqual(@as(u32, 2), counter.ticks);

        node.halt();
        try std.testing.expectEqual(.idle, node.status);
        try std.testing.expectEqual(@as(u32, 1), counter.halted);
        try std.testing.expectEqual(@as(u32, 0), counter.ticks);
    }
    try std.testing.expect(deinit_called);
}

test "[NodeImpl] identical implementations are distinct types" {
    const gpa = std.testing.allocator;
    var ctx = try Context.create(gpa);
    defer ctx.deinit();

    const Yes1 = struct {
        pub const kind: Node.Kind = .condition;
        pub fn tick(_: *@This()) Node.Status {
            return .success;
        }
    };
    const Yes2 = struct {
        pub const kind: Node.Kind = .condition;
        pub fn tick(_: *@This()) Node.Status {
            return .success;
        }
    };

    const node = try NodeImpl(Yes1).create(gpa, ctx, "yes");
    defer node.deinit(gpa);
    try std.testing.expect(node.tryAs(Yes1) != null);
    try std.testing.expect(node.tryAs(Yes2) == null);
}

test "[NodeImpl] stateful hooks" {
    const gpa = std.testing.allocator;
    var ctx = try Context.create(gpa);
    defer ctx.deinit();

    const node = try NodeImpl(Stateful).create(gpa, ctx, "stateful");
    defer node.deinit(gpa);
    const s = node.as(Stateful);

    // Halting an Idle node does not call onHalted
    node.halt();
    try std.testing.expectEqual(@as(u32, 0), s.halted);

    try std.testing.expectEqual(.running, node.tick()); // onStarted
    try std.testing.expectEqual(.running, node.tick()); // onRunning #1
    try std.testing.expectEqual(.success, node.tick()); // onRunning #2
    try std.testing.expectEqual(.success, node.tick()); // latched
    try std.testing.expectEqual(@as(u32, 1), s.started);
    try std.testing.expectEqual(@as(u32, 2), s.running);

    node.halt();
    try std.testing.expectEqual(@as(u32, 1), s.halted);
    try std.testing.expectEqual(.idle, node.status);

    try std.testing.expectEqual(.running, node.tick());
    try std.testing.expectEqual(@as(u32, 2), s.started);
}
