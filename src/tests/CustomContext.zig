num_ticks: usize,
some_other_data: []const u8,

pub fn deinit(_: @This(), _: std.mem.Allocator) void {
    std.debug.print("Goodbye, World!\n", .{});
}

const std = @import("std");
