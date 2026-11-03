//! A simple logger to write status changes to an output stream
const Logger = @This();

io: std.Io,
writer: *std.Io.Writer,

pub fn callback(ctx: *anyopaque, node: *Node, prev_status: Node.Status, status: Node.Status) void {
    const logger: *Logger = @ptrCast(@alignCast(ctx));

    const timestamp = std.Io.Clock.awake.now(logger.io);

    // std.debug.print("[{d}][{s}] {t} -> {t}\n", .{ timestamp, node.name, prev_status, status });

    logger.writer.print("[{d}][{s}] {t} -> {t}\n", .{ timestamp, node.name, prev_status, status }) catch |err| {
        std.log.err("ERROR: Cannot print to writer: {any}", .{err});
        unreachable;
    };
    logger.writer.flush() catch unreachable;
}

const Node = @import("Node.zig");
const std = @import("std");
