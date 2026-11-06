//! Support for asynchronous Actions: nodes whose work runs in the background (via
//! `std.Io.concurrent`) without blocking the ticking of the tree.
//!
//! An Action becomes asynchronous by declaring a `run` hook instead of `tick`:
//!
//! ```zig
//! const AsyncFoo = struct {
//!     pub const kind: bonzai.Node.Kind = .action;
//!
//!     input: u32 = 0,
//!     output: u32 = 0,
//!
//!     // Optional, on the tick thread: prepare inputs before the job starts.
//!     // An error here finishes the node immediately (see `finish`).
//!     pub fn prepare(self: *AsyncFoo, node: *bonzai.Node) !void {
//!         self.input = (try node.getParam(u32, "input")) orelse 1;
//!     }
//!
//!     // Required, in the background: do the work, storing results in `self`.
//!     // Use `io` for blocking operations (sleep, files, network, ...); these are
//!     // "cancelation points" which return `error.Canceled` if the node is halted.
//!     pub fn run(self: *AsyncFoo, io: std.Io) !void {
//!         try io.sleep(.fromMilliseconds(100), .awake);
//!         self.output = self.input * 2;
//!     }
//!
//!     // Optional, on the tick thread: called each tick while the job is still running.
//!     // Return .running to keep waiting, or another status to cancel the job and finish.
//!     pub fn poll(self: *AsyncFoo, node: *bonzai.Node) bonzai.Node.Status { ... }
//!
//!     // Optional, on the tick thread: called once the job has completed, with its result.
//!     // Returns the node's final status (default: Success, or Failure on error).
//!     pub fn finish(self: *AsyncFoo, node: *bonzai.Node, result: anyerror!void) bonzai.Node.Status {
//!         result catch return .failure;
//!         return if (self.output > 10) .success else .failure;
//!     }
//!
//!     // Optional, on the tick thread: called when halted, after any running job has stopped.
//!     pub fn halt(self: *AsyncFoo) void { ... }
//! };
//! ```
//!
//! As with other hooks, the `node` parameter is optional (as is `io` for `run`), and
//! `prepare` and `run` may return either `void` or `!void`.
//!
//! The job is started on the first tick after the node is Idle, and the node returns
//! Running until the job completes. Completion is detected without blocking; the job's
//! writes to `self` are visible to `finish` once it is called.
//!
//! ## Thread safety
//!
//! `run` executes on another thread, concurrently with the tree. While a job is running,
//! the tick-thread hooks (`poll`, `halt`) must not access fields which `run` writes (unless
//! they are atomics), and `run` must not access the Node, its Blackboard, or the Context
//! (copy what it needs in `prepare`).
//!
//! ## Cancelation
//!
//! Halting or destroying the node (or `poll` returning a terminal status) cancels a running
//! job and *waits* for it to stop. Jobs which only perform `Io` operations stop promptly;
//! long CPU-bound jobs should call `io.checkCancel()` periodically, or halting will block
//! the tree until they complete.
//!
//! ## Requirements
//!
//! The Context's `Io` must support concurrency (e.g. `std.Io.Threaded`). If it does not,
//! or no more concurrent tasks are available, `finish` receives `error.ConcurrencyUnavailable`.

/// Per-instance state of an asynchronous Action
pub const State = struct {
    /// The running job, if any
    future: ?Io.Future(void) = null,
    /// Set by the job (with release semantics) once it has completed
    done: Io.Event = .unset,
    /// The job's result; valid once `done` is set
    result: anyerror!void = {},

    /// True if a job has been started and not yet collected
    pub fn isPending(state: *const State) bool {
        return state.future != null;
    }

    /// Cancel the running job (if any), waiting for it to stop.
    /// THIS BLOCKS UNTIL CANCELLATION COMPLETES.
    pub fn cancel(state: *State, io: Io) void {
        if (state.future) |*f| {
            f.cancel(io);
            state.future = null;
        }
    }
};

/// True if `T` implements the asynchronous Action hooks
pub fn isAsync(comptime T: type) bool {
    return @hasDecl(T, "run");
}

/// The `tick` implementation for an asynchronous Action
pub fn tick(comptime T: type, impl: *T, state: *State, node: *Node) Node.Status {
    const io = node.context.io;
    switch (node.status) {
        .idle => {
            if (@hasDecl(T, "prepare")) {
                callPrepare(T, impl, node) catch |err| return finish(T, impl, node, err);
            }
            state.done.reset();
            state.result = {};
            state.future = io.concurrent(job(T), .{ impl, state, io }) catch |err| {
                return finish(T, impl, node, err);
            };
            return check(T, impl, state, node);
        },
        .running => return check(T, impl, state, node),
        .success, .failure => |s| return s,
    }
}

/// The `halt` implementation for an asynchronous Action: stops any running job
pub fn halt(state: *State, node: *Node) void {
    state.cancel(node.context.io);
}

/// Check for completion of the job, without blocking
fn check(comptime T: type, impl: *T, state: *State, node: *Node) Node.Status {
    const io = node.context.io;

    if (state.done.isSet()) {
        // The job has completed, so this does not block
        state.future.?.await(io);
        state.future = null;
        return finish(T, impl, node, state.result);
    }

    if (!@hasDecl(T, "poll")) return .running;

    const status = call(T.poll, impl, node);
    if (status != .running) state.cancel(io);
    return status;
}

fn finish(comptime T: type, impl: *T, node: *Node, result: anyerror!void) Node.Status {
    if (@hasDecl(T, "finish")) {
        const params = @typeInfo(@TypeOf(T.finish)).@"fn".param_types;
        return if (params.len == 3) T.finish(impl, node, result) else T.finish(impl, result);
    }
    result catch return .failure;
    return .success;
}

/// The function run in the background for implementation type T
fn job(comptime T: type) fn (*T, *State, Io) void {
    return struct {
        fn run(impl: *T, state: *State, io: Io) void {
            state.result = callRun(T, impl, io);
            state.done.set(io);
        }
    }.run;
}

fn callRun(comptime T: type, impl: *T, io: Io) anyerror!void {
    const params = @typeInfo(@TypeOf(T.run)).@"fn".param_types;
    const result = if (params.len == 2) T.run(impl, io) else T.run(impl);
    if (@TypeOf(result) != void) try result;
}

fn callPrepare(comptime T: type, impl: *T, node: *Node) anyerror!void {
    const result = call(T.prepare, impl, node);
    if (@TypeOf(result) != void) try result;
}

fn call(comptime f: anytype, impl: anytype, node: *Node) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    const params = @typeInfo(@TypeOf(f)).@"fn".param_types;
    return if (params.len == 2) f(impl, node) else f(impl);
}

/// Produce clear compile errors for malformed asynchronous Action types
pub fn validate(comptime T: type) void {
    const name = @typeName(T);
    const prefix = "NodeImpl(" ++ name ++ "): ";
    const kind: Node.Kind = T.kind;

    if (kind != .action) @compileError(prefix ++ "asynchronous hooks (run) are only supported for kind = .action");
    if (@hasDecl(T, "tick") or @hasDecl(T, "onStarted") or @hasDecl(T, "onRunning") or @hasDecl(T, "onHalted"))
        @compileError(prefix ++ "asynchronous Actions (with `run`) must not declare tick/onStarted/onRunning/onHalted");

    {
        const f = fnInfo(T, "run");
        const ok = voidOrErrorVoid(f.return_type) and switch (f.param_types.len) {
            1 => f.param_types[0] == *T,
            2 => f.param_types[0] == *T and f.param_types[1] == Io,
            else => false,
        };
        if (!ok) @compileError(prefix ++ "run must be `pub fn run(self: *" ++ name ++
            ", io: std.Io) !void` (the `io` parameter and the error union are optional)");
    }

    if (@hasDecl(T, "prepare")) {
        const f = fnInfo(T, "prepare");
        const ok = voidOrErrorVoid(f.return_type) and selfAndOptionalNode(T, f.param_types);
        if (!ok) @compileError(prefix ++ "prepare must be `pub fn prepare(self: *" ++ name ++
            ", node: *Node) !void` (the `node` parameter and the error union are optional)");
    }

    if (@hasDecl(T, "poll")) {
        const f = fnInfo(T, "poll");
        const ok = f.return_type == Node.Status and selfAndOptionalNode(T, f.param_types);
        if (!ok) @compileError(prefix ++ "poll must be `pub fn poll(self: *" ++ name ++
            ", node: *Node) Node.Status` (the `node` parameter is optional)");
    }

    if (@hasDecl(T, "finish")) {
        const f = fnInfo(T, "finish");
        const p = f.param_types;
        const ok = f.return_type == Node.Status and switch (p.len) {
            2 => p[0] == *T and p[1] == anyerror!void,
            3 => p[0] == *T and p[1] == *Node and p[2] == anyerror!void,
            else => false,
        };
        if (!ok) @compileError(prefix ++ "finish must be `pub fn finish(self: *" ++ name ++
            ", node: *Node, result: anyerror!void) Node.Status` (the `node` parameter is optional)");
    }
}

fn voidOrErrorVoid(comptime R: ?type) bool {
    const Ret = R orelse return false;
    return Ret == void or (@typeInfo(Ret) == .error_union and @typeInfo(Ret).error_union.payload == void);
}

fn selfAndOptionalNode(comptime T: type, comptime params: []const ?type) bool {
    return switch (params.len) {
        1 => params[0] == *T,
        2 => params[0] == *T and params[1] == *Node,
        else => false,
    };
}

fn fnInfo(comptime T: type, comptime decl: []const u8) std.lang.Type.Fn {
    const info = @typeInfo(@TypeOf(@field(T, decl)));
    if (info != .@"fn") @compileError("NodeImpl(" ++ @typeName(T) ++ "): '" ++ decl ++ "' must be a function");
    return info.@"fn";
}

const Node = @import("Node.zig");

const std = @import("std");
const Io = std.Io;

////////////////////////////////////////////////////////////////////////////////
// Unit Tests
////////////////////////////////////////////////////////////////////////////////

const NodeImpl = @import("node_impl.zig").NodeImpl;
const Context = @import("Context.zig");
const testing = std.testing;

/// An asynchronous Action whose job blocks until the test opens `gate`
const Gated = struct {
    pub const kind: Node.Kind = .action;

    /// Opened by the test to let the job complete
    gate: Io.Event = .unset,
    /// Input copied from params in `prepare`
    input: u32 = 1,
    /// Written by the job
    output: u32 = 0,
    fail: bool = false,
    saw_cancel: bool = false,

    // Tick-thread bookkeeping
    prepares: u32 = 0,
    polls: u32 = 0,
    max_polls: ?u32 = null,
    halts: u32 = 0,
    finished_with: ?anyerror = null,

    pub fn prepare(self: *Gated, node: *Node) !void {
        self.prepares += 1;
        self.input = (try node.getParam(u32, "input")) orelse self.input;
    }

    pub fn run(self: *Gated, io: Io) !void {
        self.gate.wait(io) catch |err| {
            self.saw_cancel = true;
            return err;
        };
        if (self.fail) return error.JobFailed;
        self.output = self.input * 2;
    }

    pub fn poll(self: *Gated) Node.Status {
        self.polls += 1;
        if (self.max_polls) |max| if (self.polls >= max) return .failure;
        return .running;
    }

    pub fn finish(self: *Gated, result: anyerror!void) Node.Status {
        result catch |err| {
            self.finished_with = err;
            return .failure;
        };
        return if (self.output > 0) .success else .failure;
    }

    pub fn halt(self: *Gated) void {
        self.halts += 1;
        self.gate.reset();
    }
};

/// Tick until the node completes, yielding briefly between ticks
fn tickUntilDone(node: *Node) !Node.Status {
    for (0..5000) |_| {
        const status = node.tick();
        if (status != .running) return status;
        try node.context.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.TestTimeout;
}

test "[AsyncAction] runs in the background and finishes with its side effects" {
    const gpa = testing.allocator;
    var ctx = try Context.create(testing.io, gpa);
    defer ctx.deinit();

    const node = try NodeImpl(Gated).create(gpa, ctx, "gated");
    defer node.deinit(gpa);
    const g = node.as(Gated);
    try node.putValue("input", .{ .int = 21 });

    // The job is blocked on the gate, so ticking does not block and keeps returning Running
    for (0..5) |_| try testing.expectEqual(.running, node.tick());
    try testing.expectEqual(@as(u32, 1), g.prepares);
    try testing.expectEqual(@as(u32, 5), g.polls);
    try testing.expectEqual(@as(u32, 0), g.output);

    g.gate.set(ctx.io);
    try testing.expectEqual(.success, try tickUntilDone(node));
    try testing.expectEqual(@as(u32, 42), g.output);
    try testing.expectEqual(@as(?anyerror, null), g.finished_with);

    // Latched until halted; then it runs again
    try testing.expectEqual(.success, node.tick());
    node.halt();
    try testing.expectEqual(.idle, node.status);
    try testing.expectEqual(.running, node.tick());
    try testing.expectEqual(@as(u32, 2), g.prepares);
    g.gate.set(ctx.io);
    try testing.expectEqual(.success, try tickUntilDone(node));
}

test "[AsyncAction] job errors are passed to finish" {
    const gpa = testing.allocator;
    var ctx = try Context.create(testing.io, gpa);
    defer ctx.deinit();

    const node = try NodeImpl(Gated).create(gpa, ctx, "gated");
    defer node.deinit(gpa);
    const g = node.as(Gated);
    g.fail = true;

    try testing.expectEqual(.running, node.tick());
    g.gate.set(ctx.io);
    try testing.expectEqual(.failure, try tickUntilDone(node));
    try testing.expectEqual(@as(?anyerror, error.JobFailed), g.finished_with);
}

test "[AsyncAction] halting cancels a running job" {
    const gpa = testing.allocator;
    var ctx = try Context.create(testing.io, gpa);
    defer ctx.deinit();

    const node = try NodeImpl(Gated).create(gpa, ctx, "gated");
    defer node.deinit(gpa);
    const g = node.as(Gated);

    try testing.expectEqual(.running, node.tick());
    node.halt(); // blocks until the job observes the cancelation

    try testing.expect(g.saw_cancel);
    try testing.expectEqual(@as(u32, 1), g.halts);
    try testing.expectEqual(.idle, node.status);
    try testing.expect(!NodeImpl(Gated).isJobPending(node));
}

test "[AsyncAction] poll can cancel the job (e.g. a timeout)" {
    const gpa = testing.allocator;
    var ctx = try Context.create(testing.io, gpa);
    defer ctx.deinit();

    const node = try NodeImpl(Gated).create(gpa, ctx, "gated");
    defer node.deinit(gpa);
    const g = node.as(Gated);
    g.max_polls = 3;

    try testing.expectEqual(.running, node.tick());
    try testing.expectEqual(.running, node.tick());
    try testing.expectEqual(.failure, node.tick());
    try testing.expect(g.saw_cancel);
    // The job was canceled, not finished
    try testing.expectEqual(@as(?anyerror, null), g.finished_with);
}

test "[AsyncAction] destroying a node cancels its job" {
    const gpa = testing.allocator;
    var ctx = try Context.create(testing.io, gpa);
    defer ctx.deinit();

    const node = try NodeImpl(Gated).create(gpa, ctx, "gated");
    try testing.expectEqual(.running, node.tick());
    node.deinit(gpa); // must not leak, or leave the job writing to freed memory
}

test "[AsyncAction] prepare errors finish without starting a job" {
    const gpa = testing.allocator;
    var ctx = try Context.create(testing.io, gpa);
    defer ctx.deinit();

    const node = try NodeImpl(Gated).create(gpa, ctx, "gated");
    defer node.deinit(gpa);
    const g = node.as(Gated);
    try node.putValue("input", .{ .string = "not a number" });

    try testing.expectEqual(.failure, node.tick());
    try testing.expectEqual(@as(?anyerror, error.InvalidParamType), g.finished_with);
    try testing.expect(!NodeImpl(Gated).isJobPending(node));
}

test "[AsyncAction] minimal implementation, without concurrency available" {
    const gpa = testing.allocator;

    const Minimal = struct {
        pub const kind: Node.Kind = .action;
        ran: bool = false,
        pub fn run(self: *@This()) void {
            self.ran = true;
        }
    };

    // With concurrency, the default finish returns Success
    {
        var ctx = try Context.create(testing.io, gpa);
        defer ctx.deinit();
        const node = try NodeImpl(Minimal).create(gpa, ctx, "minimal");
        defer node.deinit(gpa);
        try testing.expectEqual(.success, try tickUntilDone(node));
        try testing.expect(node.as(Minimal).ran);
    }

    // Without concurrency, the default finish returns Failure
    {
        var threaded: Io.Threaded = .init(gpa, .{ .concurrent_limit = .nothing });
        defer threaded.deinit();
        var ctx = try Context.create(threaded.io(), gpa);
        defer ctx.deinit();
        const node = try NodeImpl(Minimal).create(gpa, ctx, "minimal");
        defer node.deinit(gpa);
        try testing.expectEqual(.failure, node.tick());
        try testing.expect(!node.as(Minimal).ran);
    }
}
