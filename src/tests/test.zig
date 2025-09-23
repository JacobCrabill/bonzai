test "Additional Library Tests" {
    _ = @import("DummyAction.zig");
}

const std = @import("std");
const bonzai = @import("bonzai");

const DummyAction = @import("DummyAction.zig");

test "[Tree] Tick tree with lgoger" {
    const alloc = std.testing.allocator;

    var tree = bonzai.Tree.init(alloc);
    defer tree.deinit(alloc);

    const seq_node: *bonzai.Node = try bonzai.nodes.controls.Sequence.create(alloc, "root");
    tree.root = seq_node;

    var logger = bonzai.loggers.StdoutLogger.init();
    try tree.addLogger(alloc, &logger.logger);

    try std.testing.expectEqual(.failure, tree.tick());
}
