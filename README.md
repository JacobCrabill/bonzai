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
read/write data from your custom node types. The Tree also supports a global key/value Blackboard
for read/write access to primitive data types, and each Node has its own private Blackboard as well.

Trees may be defined in JSON, including specifying Blackboard values for both nodes and the overall
tree. This can be useful for reuse of parameterizeable node types such as a timed delay or a node
that ticks up to a retry count.

## Use

Bonzai is built around a generic `Node` type and a `Factory` to register and instantiate specific
node implementations. While Bonzai has a few basic node types included (such as Sequence, Fallback,
Inverter), it is expected that users will implement their own nodes for their own use case.

See `DummyAction.zig` and `src/tests/test.zig` for an example of implementing a Stateful Action node
making use of a custom Context data type, registering it with the Factory, loading it via JSON, and
making use of it from within a Tree.

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

Loading and ticking a JSON-defined tree:

```zig
test "[Tree] Tick tree with lgoger" {
    const alloc = std.testing.allocator;

    // Create the global Context struct with custom data
    var custom_context = CustomContext{
        .num_ticks = 4,
        .some_other_data = "Hello, bonzai!",
    };
    var ctx = try bonzai.Context.create(alloc, @ptrCast(&custom_context));
    defer ctx.deinit();

    // Initialize the Factory
    var factory = try bonzai.Factory.init(alloc);
    defer factory.deinit();

    // Register the built-in and custom Node types
    try bonzai.registerBuiltinTypes(&factory);
    try factory.registerNode("DummyAction", DummyAction.create);

    const json = @embedFile("json/test-dummy-action.json");

    // Instantiate a new Tree from a JSON string
    var tree = try factory.loadFromJson(ctx, json);
    defer tree.deinit();

    var logger = bonzai.loggers.StdoutLogger.init();

    // Add a simple logger to show the progress of the tree
    try tree.addLogger(alloc, &logger.logger);

    // Tick the tree to completion
    for (1..custom_context.num_ticks) |_| {
        try std.testing.expectEqual(.running, tree.tick());
    }
    try std.testing.expectEqual(.success, tree.tick());
}
```
