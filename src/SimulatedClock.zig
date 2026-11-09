//! A `std.Io` implementation with a deterministic, manually-controlled clock.
//!
//! `SimulatedClock` wraps another `Io` (e.g. `std.Io.Threaded`), forwarding every operation
//! to it except those involving time:
//!
//! - `now` returns the simulated time (for every `Clock`), which only changes when
//!   `advance()` or `setTime()` is called.
//! - `sleep` (and `Clock.Timestamp.wait`, etc.) blocks until the simulated time reaches the
//!   deadline. Sleeps remain cancelation points.
//! - Futex waits with a timeout (used by e.g. `Io.Event.waitTimeout`) time out according to
//!   the simulated clock.
//!
//! This makes time-dependent behavior (timeouts, delays, background jobs which sleep)
//! reproducible in tests:
//!
//! ```zig
//! var sim: bonzai.SimulatedClock = .init(std.testing.io, .{});
//! var ctx = try bonzai.Context.create(sim.io(), gpa);
//! ...
//! try expectEqual(.running, tree.tick());
//! sim.advance(.fromMilliseconds(500));
//! try expectEqual(.failure, tree.tick()); // e.g. a TryUntilTimeout expired
//! ```
//!
//! Background tasks (e.g. asynchronous Actions) still run on real threads. To advance time
//! only once a task is blocked in a simulated sleep, use `waitForSleepers()`.
//!
//! Do not sleep on the simulated clock from the thread which advances it: nothing would
//! wake it up. Operations taking a timeout which are not listed above (currently only
//! `Batch.awaitConcurrent`) are not supported with a timeout, and panic.
//!
//! The `SimulatedClock` must not be moved after `io()` is called.
const SimulatedClock = @This();

/// The Io implementation that all non-time operations are forwarded to
inner: Io,

/// Simulated time at `offset_ns == 0`
start_ns: i96,

/// Nanoseconds elapsed (in simulated time) since `start_ns`
offset_ns: std.atomic.Value(i64) = .init(0),

/// Incremented whenever the simulated time changes; simulated sleepers wait on this futex
generation: u32 = 0,

/// The number of tasks currently blocked waiting on the simulated clock
sleeper_count: u32 = 0,

pub const Options = struct {
    /// The initial simulated time
    start: Io.Timestamp = .zero,
};

pub fn init(inner: Io, options: Options) SimulatedClock {
    return .{ .inner = inner, .start_ns = options.start.nanoseconds };
}

/// The `Io` interface using the simulated clock
pub fn io(self: *SimulatedClock) Io {
    return .{ .userdata = self, .vtable = &vtable };
}

/// The current simulated time
pub fn now(self: *const SimulatedClock) Io.Timestamp {
    return .{ .nanoseconds = self.nowNs() };
}

/// Advance the simulated time, waking any sleepers whose deadline has passed
pub fn advance(self: *SimulatedClock, duration: Io.Duration) void {
    std.debug.assert(duration.nanoseconds >= 0);
    _ = self.offset_ns.fetchAdd(@intCast(duration.nanoseconds), .acq_rel);
    self.wakeSleepers();
}

/// Set the simulated time, which must not be earlier than the current simulated time
pub fn setTime(self: *SimulatedClock, time: Io.Timestamp) void {
    std.debug.assert(time.nanoseconds >= self.nowNs());
    self.offset_ns.store(@intCast(time.nanoseconds - self.start_ns), .release);
    self.wakeSleepers();
}

/// The number of tasks currently blocked waiting on the simulated clock
pub fn sleepers(self: *const SimulatedClock) u32 {
    return @atomicLoad(u32, &self.sleeper_count, .acquire);
}

/// Block (in real time) until at least `count` tasks are waiting on the simulated clock.
/// Use this to synchronize with background tasks before advancing time.
pub fn waitForSleepers(self: *SimulatedClock, count: u32) Io.Cancelable!void {
    while (true) {
        const current = self.sleepers();
        if (current >= count) return;
        try self.inner.vtable.futexWait(self.inner.userdata, &self.sleeper_count, current, .none);
    }
}

fn nowNs(self: *const SimulatedClock) i96 {
    return self.start_ns + self.offset_ns.load(.acquire);
}

fn wakeSleepers(self: *SimulatedClock) void {
    _ = @atomicRmw(u32, &self.generation, .Add, 1, .release);
    self.inner.vtable.futexWake(self.inner.userdata, &self.generation, std.math.maxInt(u32));
}

fn addSleeper(self: *SimulatedClock, delta: enum { add, remove }) void {
    switch (delta) {
        .add => _ = @atomicRmw(u32, &self.sleeper_count, .Add, 1, .release),
        .remove => _ = @atomicRmw(u32, &self.sleeper_count, .Sub, 1, .release),
    }
    self.inner.vtable.futexWake(self.inner.userdata, &self.sleeper_count, std.math.maxInt(u32));
}

/// The simulated deadline of a timeout, in nanoseconds; null for no timeout
fn deadlineNs(self: *const SimulatedClock, timeout: Io.Timeout) ?i96 {
    return switch (timeout) {
        .none => null,
        .duration => |d| self.nowNs() + d.raw.nanoseconds,
        .deadline => |d| d.raw.nanoseconds,
    };
}

fn fromUserdata(userdata: ?*anyopaque) *SimulatedClock {
    return @ptrCast(@alignCast(userdata.?));
}

////////////////////////////////////////////////////////////////////////////////
// Io VTable
////////////////////////////////////////////////////////////////////////////////

const vtable: Io.VTable = blk: {
    var v: Io.VTable = undefined;
    for (@typeInfo(Io.VTable).@"struct".field_names) |name| {
        @field(v, name) = forward(name);
    }
    v.now = simNow;
    v.clockResolution = simClockResolution;
    v.sleep = simSleep;
    v.futexWait = simFutexWait;
    v.batchAwaitConcurrent = simBatchAwaitConcurrent;
    break :blk v;
};

fn simNow(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
    _ = clock;
    return fromUserdata(userdata).now();
}

fn simClockResolution(userdata: ?*anyopaque, clock: Io.Clock) Io.Clock.ResolutionError!Io.Duration {
    _ = userdata;
    _ = clock;
    return .fromNanoseconds(1);
}

fn simSleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
    const self = fromUserdata(userdata);
    const deadline = self.deadlineNs(timeout);

    self.addSleeper(.add);
    defer self.addSleeper(.remove);

    while (true) {
        // Read the generation before the time, so an advance in between is not missed
        const generation = @atomicLoad(u32, &self.generation, .acquire);
        if (deadline) |d| if (self.nowNs() >= d) return;
        try self.inner.vtable.futexWait(self.inner.userdata, &self.generation, generation, .none);
    }
}

fn simFutexWait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
    const self = fromUserdata(userdata);
    const deadline = self.deadlineNs(timeout) orelse
        return self.inner.vtable.futexWait(self.inner.userdata, ptr, expected, .none);

    self.addSleeper(.add);
    defer self.addSleeper(.remove);

    // We cannot block on both `ptr` and the simulated clock at once, so wait on `ptr` in short
    // real-time slices, returning only once its value changes or the simulated deadline passes.
    const slice: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } };
    while (true) {
        if (@atomicLoad(u32, ptr, .acquire) != expected) return;
        if (self.nowNs() >= deadline) return;
        try self.inner.vtable.futexWait(self.inner.userdata, ptr, expected, slice);
    }
}

fn simBatchAwaitConcurrent(userdata: ?*anyopaque, batch: *Io.Batch, timeout: Io.Timeout) Io.Batch.AwaitConcurrentError!void {
    const self = fromUserdata(userdata);
    if (timeout != .none) @panic("SimulatedClock: Batch.awaitConcurrent with a timeout is not supported");
    return self.inner.vtable.batchAwaitConcurrent(self.inner.userdata, batch, timeout);
}

/// Generate a function which forwards the VTable entry `name` to the inner Io
fn forward(comptime name: []const u8) @FieldType(Io.VTable, name) {
    const F = @typeInfo(@FieldType(Io.VTable, name)).pointer.child;
    const info = @typeInfo(F).@"fn";
    const P = info.param_types;
    const R = info.return_type.?;

    const Fwd = struct {
        fn inner(ud: ?*anyopaque) struct { Io, @FieldType(Io.VTable, name) } {
            const s = fromUserdata(ud);
            return .{ s.inner, @field(s.inner.vtable, name) };
        }
        fn f1(ud: ?*anyopaque) R {
            const i, const f = inner(ud);
            return f(i.userdata);
        }
        fn f2(ud: ?*anyopaque, a: P[1].?) R {
            const i, const f = inner(ud);
            return f(i.userdata, a);
        }
        fn f3(ud: ?*anyopaque, a: P[1].?, b: P[2].?) R {
            const i, const f = inner(ud);
            return f(i.userdata, a, b);
        }
        fn f4(ud: ?*anyopaque, a: P[1].?, b: P[2].?, c: P[3].?) R {
            const i, const f = inner(ud);
            return f(i.userdata, a, b, c);
        }
        fn f5(ud: ?*anyopaque, a: P[1].?, b: P[2].?, c: P[3].?, d: P[4].?) R {
            const i, const f = inner(ud);
            return f(i.userdata, a, b, c, d);
        }
        fn f6(ud: ?*anyopaque, a: P[1].?, b: P[2].?, c: P[3].?, d: P[4].?, e: P[5].?) R {
            const i, const f = inner(ud);
            return f(i.userdata, a, b, c, d, e);
        }
        fn f7(ud: ?*anyopaque, a: P[1].?, b: P[2].?, c: P[3].?, d: P[4].?, e: P[5].?, g: P[6].?) R {
            const i, const f = inner(ud);
            return f(i.userdata, a, b, c, d, e, g);
        }
    };

    return switch (P.len) {
        1 => &Fwd.f1,
        2 => &Fwd.f2,
        3 => &Fwd.f3,
        4 => &Fwd.f4,
        5 => &Fwd.f5,
        6 => &Fwd.f6,
        7 => &Fwd.f7,
        else => @compileError("SimulatedClock: unsupported arity for Io.VTable." ++ name),
    };
}

const std = @import("std");
const Io = std.Io;

////////////////////////////////////////////////////////////////////////////////
// Unit Tests
////////////////////////////////////////////////////////////////////////////////

const testing = std.testing;

test "[SimulatedClock] time only moves when advanced" {
    var sim: SimulatedClock = .init(testing.io, .{ .start = .fromNanoseconds(1_000) });
    const io_ = sim.io();

    const t0 = Io.Timestamp.now(io_, .awake);
    try testing.expectEqual(@as(i96, 1_000), t0.nanoseconds);
    try testing.expectEqual(t0, Io.Timestamp.now(io_, .real));

    sim.advance(.fromMilliseconds(250));
    try testing.expectEqual(@as(i64, 250), t0.durationTo(Io.Timestamp.now(io_, .awake)).toMilliseconds());

    sim.setTime(.fromNanoseconds(5 * std.time.ns_per_s));
    try testing.expectEqual(@as(i64, 5), Io.Timestamp.now(io_, .boot).toSeconds());
}

test "[SimulatedClock] sleeping tasks wake when time passes their deadline" {
    var sim: SimulatedClock = .init(testing.io, .{});
    const io_ = sim.io();

    const Sleeper = struct {
        fn run(sio: Io, ms: i64, woke_at: *std.atomic.Value(i64)) Io.Cancelable!void {
            try sio.sleep(.fromMilliseconds(ms), .awake);
            woke_at.store(@intCast(@divTrunc(Io.Timestamp.now(sio, .awake).nanoseconds, std.time.ns_per_ms)), .release);
        }
    };

    var woke_a: std.atomic.Value(i64) = .init(-1);
    var woke_b: std.atomic.Value(i64) = .init(-1);
    var a = try io_.concurrent(Sleeper.run, .{ io_, 100, &woke_a });
    defer a.cancel(io_) catch {};
    var b = try io_.concurrent(Sleeper.run, .{ io_, 300, &woke_b });
    defer b.cancel(io_) catch {};

    try sim.waitForSleepers(2);

    sim.advance(.fromMilliseconds(99));
    try sim.waitForSleepers(2); // both still asleep
    try testing.expectEqual(@as(i64, -1), woke_a.load(.acquire));

    sim.advance(.fromMilliseconds(1));
    try a.await(io_);
    try testing.expectEqual(@as(i64, 100), woke_a.load(.acquire));
    try testing.expectEqual(@as(u32, 1), sim.sleepers());

    sim.advance(.fromMilliseconds(500));
    try b.await(io_);
    try testing.expectEqual(@as(i64, 600), woke_b.load(.acquire));
    try testing.expectEqual(@as(u32, 0), sim.sleepers());
}

test "[SimulatedClock] simulated sleeps can be canceled" {
    var sim: SimulatedClock = .init(testing.io, .{});
    const io_ = sim.io();

    const Sleeper = struct {
        fn run(sio: Io) Io.Cancelable!void {
            try sio.sleep(.fromSeconds(3600), .awake);
        }
    };

    var task = try io_.concurrent(Sleeper.run, .{io_});
    try sim.waitForSleepers(1);
    try testing.expectError(error.Canceled, task.cancel(io_));
    try testing.expectEqual(@as(u32, 0), sim.sleepers());
}

test "[SimulatedClock] Event.waitTimeout uses simulated time" {
    var sim: SimulatedClock = .init(testing.io, .{});
    const io_ = sim.io();

    const Waiter = struct {
        fn run(sio: Io, event: *Io.Event) Io.Event.WaitTimeoutError!void {
            return event.waitTimeout(sio, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
        }
    };

    // Times out once 10 simulated seconds pass
    {
        var event: Io.Event = .unset;
        var task = try io_.concurrent(Waiter.run, .{ io_, &event });
        try sim.waitForSleepers(1);
        sim.advance(.fromSeconds(10));
        try testing.expectError(error.Timeout, task.await(io_));
    }

    // Returns as soon as the event is set, without time passing
    {
        var event: Io.Event = .unset;
        var task = try io_.concurrent(Waiter.run, .{ io_, &event });
        try sim.waitForSleepers(1);
        event.set(io_);
        try task.await(io_);
    }
}
