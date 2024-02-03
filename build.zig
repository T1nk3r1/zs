const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});
    _ = b.addModule(
        "zs",
        .{
            .root_source_file = .{ .path = "src/zs.zig" },
            .target = target,
            .optimize = optimize,
        },
    );

    const zigser_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/zs.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_zigser_unit_tests = b.addRunArtifact(zigser_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_zigser_unit_tests.step);
}
