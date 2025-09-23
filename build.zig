const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bonzai = b.addModule("bonzai", .{
        .root_source_file = b.path("src/bonzai.zig"),
        .target = target,
        .optimize = optimize,
    });

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "bonzai", .module = bonzai },
    };

    const mod_tests = b.addTest(.{
        .root_module = bonzai,
        .test_runner = .{ .path = b.path("tools/test_runner.zig"), .mode = .simple },
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const extra_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
        .test_runner = .{ .path = b.path("tools/test_runner.zig"), .mode = .simple },
    });
    const run_extra_tests = b.addRunArtifact(extra_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_extra_tests.step);
}
