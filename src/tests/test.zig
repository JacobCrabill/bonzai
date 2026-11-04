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
    var ctx = try bonzai.Context.createWithData(alloc, @ptrCast(&custom_context));
    defer ctx.deinitWithData(CustomContext);

    // Initialize the Factory
    var factory = try bonzai.Factory.init(io, alloc);
    defer factory.deinit();

    try bonzai.registerBuiltinTypes(&factory);
    try factory.registerNode("DummyAction", DummyAction.create);

    const json = @embedFile("json/test-dummy-action.json");

    var tree = try factory.loadFromJson(ctx, json);
    defer tree.deinit();

    var logger: bonzai.loggers.StdoutLogger = .init(io);
    try tree.addLogger(logger.interface());

    for (1..custom_context.num_ticks) |_| {
        try std.testing.expectEqual(.running, tree.tick());
    }
    try std.testing.expectEqual(.success, tree.tick());
}
