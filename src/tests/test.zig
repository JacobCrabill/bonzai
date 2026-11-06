test "Additional Library Tests" {
    _ = @import("DummyAction.zig");
}

const std = @import("std");
const bonzai = @import("bonzai");

const DummyAction = @import("DummyAction.zig");
const CustomContext = @import("CustomContext.zig");

test "[Tree] Tick tree with logger" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Create the global Context struct with custom data
    var custom_context = CustomContext{
        .num_ticks = 4,
        .some_other_data = "Hello, bonzai!",
    };
    var ctx = try bonzai.Context.createWithData(std.testing.io, alloc, &custom_context);
    defer ctx.deinitWithData();

    // Initialize the Factory
    var factory = try bonzai.Factory.init(io, alloc);
    defer factory.deinit();

    try bonzai.registerBuiltinTypes(&factory);
    try factory.register("DummyAction", DummyAction);

    const json = @embedFile("json/test-dummy-action.json");

    var tree = try factory.loadFromJson(ctx, json);
    defer tree.deinit();

    var logger: bonzai.loggers.StdoutLogger = .init(io);
    try tree.addLogger(logger.interface());

    // The DummyAction was configured from its "max_ticks" param (3), which takes
    // precedence over `custom_context.num_ticks`
    const dummy = tree.root.?.data.control.getChild(0).as(DummyAction);
    try std.testing.expectEqual(@as(usize, 3), dummy.max_ticks);

    for (1..dummy.max_ticks) |_| {
        try std.testing.expectEqual(.running, tree.tick());
    }
    try std.testing.expectEqual(.success, tree.tick());
}
