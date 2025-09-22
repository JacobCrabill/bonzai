const StdoutLogger = @This();

stdout: std.fs.File.Writer,
logger: Logger,

pub fn init() StdoutLogger {
    var logger: StdoutLogger = undefined;
    logger.stdout = std.fs.File.stdout().writer(&.{});
    logger.logger = .{ .writer = logger.stdout.interface };
    return logger;
}

const Logger = @import("../Logger.zig");
const std = @import("std");
