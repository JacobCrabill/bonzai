# Bonzai: Simple Behavior Tree Library in Zig

Bonzai is a general-purpose behavior tree library allowing you to define, register, and create
custom node types, instantiate trees, and tick them from your application. Import it the same way
you would any Zig package:

```zig
const bonzai = b.dependency("bonzai", .{ .target = target, .optimize = optimize });
my_mod.addImport("bonzai", bonzai.module("bonzai"));
```

## Features

Bonzai uses an object-oriented approach (using vtables), which has some pros and cons over a
static-dispatch approach. The vtable approach means that (by some metrics) it is easier to "extend"
the base types which Bonzai provides, while keeping the architecture as simple as possible. Besides,
behavior trees are data structures that map perfectly to OOP.

Custom Context struct types may be given to your trees, providing access to arbitrary shared
read/write data from your custom node types: create the Context with
`bonzai.Context.createWithData(io, gpa, &my_data)`, then retrieve it from any node with
`node.context.getData(MyData)` (which checks the type in safe builds). The Tree also supports a global key/value Blackboard
for read/write access to primitive data types, and each Node has its own private Blackboard as well.

Trees may be defined in JSON, including specifying Blackboard values for both nodes and the overall
tree. This can be useful for reuse of parameterizeable node types such as a timed delay or a node
that ticks up to a retry count.

## Use

Bonzai is built around a generic `Node` type and a `Factory` to register and instantiate specific
node implementations. While Bonzai has a few basic node types included, it is expected that users
will implement their own nodes for their own use case. The built-in types are:

| Kind      | Type              | Behavior                                                                  |
|-----------|-------------------|---------------------------------------------------------------------------|
| Control   | `Sequence`        | Ticks children in order until one fails or is running                     |
| Control   | `Fallback`        | Ticks children in order until one succeeds or is running                  |
| Control   | `Parallel`        | Ticks all children every tick; params `success_threshold` (default: all), `failure_threshold` (default: 1) |
| Decorator | `Inverter`        | Swaps the child's Success and Failure                                     |
| Decorator | `Repeat`          | Repeats the child until it succeeds `num_cycles` times (-1: forever); one cycle per tick |
| Decorator | `TryUntilTimeout` | Passes through the child's status, but fails (halting the child) if it is still Running after `timeout_ms` |
| Decorator | `RunUntilSuccess` | Re-runs the child after each failure until it succeeds                    |
| Action    | `AlwaysRunning`   | Always returns Running                                                    |
| Condition | `AlwaysSuccess`   | Always returns Success                                                    |
| Condition | `AlwaysFailure`   | Always returns Failure                                                    |

### Custom Node types

A custom node is a plain struct. `bonzai.NodeImpl(T)` generates the allocation, vtable, and
destruction code for it, and checks its declarations at compile time:

```zig
const Retry = struct {
    // Required: .action, .condition, .decorator, or .control
    pub const kind: bonzai.Node.Kind = .decorator;

    // Per-instance state; every field needs a default value
    attempts: u32 = 0,
    max_attempts: u32 = 3,

    // Optional: read params once, after the node (and its children) are loaded.
    // Errors are reported by the Factory with the node's location in the JSON.
    pub fn configure(self: *Retry, node: *bonzai.Node) !void {
        self.max_attempts = (try node.getParam(u32, "max_attempts")) orelse self.max_attempts;
    }

    // Required. The `node` parameter is optional if you don't need it.
    pub fn tick(self: *Retry, node: *bonzai.Node) bonzai.Node.Status {
        return switch (node.data.decorator.tick()) {
            .failure => blk: {
                self.attempts += 1;
                if (self.attempts >= self.max_attempts) break :blk .failure;
                node.data.decorator.halt();
                break :blk .running;
            },
            else => |s| s,
        };
    }

    // Optional: reset state when halted (children are halted automatically)
    pub fn halt(self: *Retry) void {
        self.attempts = 0;
    }

    // Optional: free any resources owned by the node
    // pub fn deinit(self: *Retry, gpa: std.mem.Allocator) void {}
};

try factory.register("Retry", Retry);
```

Actions may instead implement `onStarted` (optional), `onRunning`, and `onHalted` (optional),
which are called on the first tick, on subsequent ticks while Running, and when halted.

`node.getParam(T, key)` converts a param to an integer (range-checked), float, bool, string, or
enum (by tag name), returning null if it is absent. When creating nodes directly with
`NodeImpl(T).create()` instead of the Factory, set params with `node.putValue()` and then call
`node.configure()`.

To get from a base `*Node` to your type, use `node.as(Retry)` (asserts the type) or
`node.tryAs(Retry)` (returns null for other types); to go back, use `bonzai.nodeOf(self)`.

### Asynchronous Actions

An Action can run its work in the background, without blocking the ticking of the tree, by
declaring a `run` hook instead of `tick`. On the first tick, `run` is started with
`std.Io.concurrent`; on each later tick the node checks (without blocking) whether it has finished,
returning Running until it has. The job stores its results in the node's own fields, which
`finish` then uses to decide the node's status:

```zig
const AsyncFoo = struct {
    pub const kind: bonzai.Node.Kind = .action;

    delay_ms: i64 = 100,
    answer: u32 = 0,

    // Optional, on the tick thread: copy inputs before the job starts
    pub fn prepare(self: *AsyncFoo, node: *bonzai.Node) !void {
        self.delay_ms = (try node.getParam(i64, "delay_ms")) orelse self.delay_ms;
    }

    // Required, in the background: `io` operations are cancelation points if the node is halted
    pub fn run(self: *AsyncFoo, io: std.Io) !void {
        try io.sleep(.fromMilliseconds(self.delay_ms), .awake);
        self.answer = 42;
    }

    // Optional, on the tick thread: called once the job completes (default: Success unless it failed)
    pub fn finish(self: *AsyncFoo, result: anyerror!void) bonzai.Node.Status {
        result catch return .failure;
        return if (self.answer == 42) .success else .failure;
    }
};

try factory.register("AsyncFoo", AsyncFoo);
```

An optional `poll` hook is called on each tick while the job is still running; returning anything
other than Running (e.g. on a timeout) cancels the job. Halting or destroying the node also cancels
the job and waits for it to stop. The Context's `Io` must support concurrency (e.g.
`std.Io.Threaded`); see `src/async_action.zig` for details, including the thread-safety rules.

### Deterministic time

Nodes measure and wait for time through the Context's `std.Io` (e.g. `TryUntilTimeout`, or an
asynchronous Action which sleeps). `bonzai.SimulatedClock` is an `Io` implementation which forwards
everything to another `Io`, except that time only passes when you say so, which makes
time-dependent trees fully reproducible in tests:

```zig
var sim: bonzai.SimulatedClock = .init(std.testing.io, .{});
var ctx = try bonzai.Context.create(sim.io(), gpa);
// ... load a tree with a TryUntilTimeout (timeout_ms = 20) around a long-running child

try expectEqual(.running, tree.tick());
sim.advance(.fromMilliseconds(19));
try expectEqual(.running, tree.tick());
sim.advance(.fromMilliseconds(1));
try expectEqual(.failure, tree.tick()); // timed out, exactly at 20ms
```

Sleeps (including those in background jobs) wake when the simulated time passes their deadline,
and remain cancelable. Since background jobs run on real threads, use `sim.waitForSleepers(n)`
to wait until they are blocked on the simulated clock before advancing it.

See `DummyAction.zig` and `src/tests/test.zig` for an example of a stateful Action making use of a
custom Context data type, registering it with the Factory, loading it via JSON, and making use of it
from within a Tree.

### Example

Tree definition (JSON):

```json
{
  "root": {
    "kind": "Sequence",
    "name": "root",
    "children": [
      {
        "kind": "Inverter",
        "name": "inverter-1",
        "child": {
          "kind": "AlwaysFailure",
          "name": "!failure"
        }
      },
      {
        "kind": "AlwaysSuccess",
        "name": "success!"
      },
      {
        "kind": "DummyAction",
        "name": "do-stuff",
        "params": {
          "max_ticks": 3,
          "some_value": 1.234,
          "hello": "world",
          "ok": true
        }
      }
    ]
  },
  "params": {
    "some-global-value": "Hello, Bonzai!"
  }
}
```

Loading and ticking a JSON-defined tree with a custom Context type:

```zig
test "[Tree] Tick tree with logger" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    // Create the global Context struct with custom data
    var custom_context = CustomContext{
        .num_ticks = 4,
        .some_other_data = "Hello, bonzai!",
    };
    var ctx = try bonzai.Context.createWithData(io, gpa, &custom_context);
    defer ctx.deinitWithData();

    // Initialize the Factory
    var factory = try bonzai.Factory.init(io, gpa);
    defer factory.deinit();

    // Register the built-in and custom Node types
    try bonzai.registerBuiltinTypes(&factory);
    try factory.register("DummyAction", DummyAction);

    const json = @embedFile("json/test-dummy-action.json");

    // Instantiate a new Tree from a JSON string
    var tree = try factory.loadFromJson(ctx, json);
    defer tree.deinit();

    var logger: bonzai.loggers.StdoutLogger = .init(io);

    // Add a simple logger to show the progress of the tree
    try tree.addLogger(logger.interface());

    // Tick the tree to completion
    // The DummyAction was configured from its "max_ticks" param (3), which takes
    // precedence over `custom_context.num_ticks`
    const dummy = tree.root.?.data.control.getChild(0).as(DummyAction);
    try std.testing.expectEqual(@as(usize, 3), dummy.max_ticks);

    for (1..dummy.max_ticks) |_| {
        try std.testing.expectEqual(.running, tree.tick());
    }
    try std.testing.expectEqual(.success, tree.tick());
}
```
