const StdoutLogger = @This();

io: std.Io,
file: std.Io.File,
stdout: std.Io.File.Writer,
logger: Logger,
buf: [1024]u8 = undefined,

pub fn init(io: std.Io) StdoutLogger {
    return .{
        .io = io,
        .file = std.Io.File.stdout(),
        .stdout = undefined,
        .logger = undefined,
    };
}

/// Returns the Logger interface, wiring up the writer's internal pointers.
/// Call this once the StdoutLogger is at its final address; it must not be
/// moved or copied afterwards, since it holds pointers to its own fields.
pub fn interface(self: *StdoutLogger) *Logger {
    self.stdout = self.file.writer(self.io, &self.buf);
    self.logger = .{ .io = self.io, .writer = &self.stdout.interface };
    return &self.logger;
}

const Logger = @import("../Logger.zig");
const std = @import("std");
