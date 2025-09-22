//! A simple logger to write status changes to an output stream
const Logger = @This();

writer: std.Io.Writer,

pub fn callback(ctx: *anyopaque, node: *Node, prev_status: Node.Status, status: Node.Status) void {
    const logger: *Logger = @ptrCast(@alignCast(ctx));

    // TODO: Should come from a std.Io in the future
    const timestamp = std.time.timestamp();

    logger.writer.print("[{d}][{s}] {t} -> {t}\n", .{ timestamp, node.name, prev_status, status }) catch |err| {
        std.log.err("ERROR: Cannot print to writer: {any}", .{err});
        unreachable;
    };
}

const Node = @import("Node.zig");
const std = @import("std");
