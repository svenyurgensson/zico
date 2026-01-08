const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zico_module = b.addModule("zico", .{
        .root_source_file = b.path("src/zico.zig"),
        .target = target,
        .optimize = optimize,
    });

    // TESTS
    const sync_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sync.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sync_tests.root_module.addImport("zico", zico_module);
    const run_sync_tests = b.addRunArtifact(sync_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_sync_tests.step);
}
