const std = @import("std");
const ch32 = @import("ch32");

pub fn build(b: *std.Build) void {
    const ch32_dep = b.dependency("ch32", .{});
    const zico_dep = b.dependency("zico", .{});

    const name = "semaphore";
    const targets: []const ch32.Target = &.{
        .{ .chip = .{ .series = .ch32v003 } },
    };

    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSmall;

    // --- Create Modules from Dependencies ---
    const hal_module = ch32_dep.module("hal");

    const zico_module = b.createModule(.{
        .root_source_file = zico_dep.path("src/zico.zig"),
        .imports = &.{
            .{ .name = "task", .source_file = zico_dep.path("src/task.zig") },
            .{ .name = "message", .source_file = zico_dep.path("src/message.zig") },
        },
    });

    for (targets) |target| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_source_file = b.path("src/main.zig"),
            .target = ch32.zigTarget(target),
            .optimize = optimize,
        });
        exe.setLinkerScript(ch32.linkerScript(b, target));

        exe.addModule("hal", hal_module);
        exe.addModule("zico", zico_module);

        // --- Installation and Flashing ---
        const fw_bin = ch32.installFirmware(b, exe, .{});
        ch32.printFirmwareSize(b, fw_bin);
        _ = ch32.installFirmware(b, exe, .{ .format = .elf });
    }

    // --- Standard Steps ---
    const clean_step = b.step("clean", "Clean up");
    clean_step.dependOn(&b.addRemoveDirTree(.{ .cwd_relative = b.install_path }).step);
    clean_step.dependOn(&b.addRemoveDirTree(.{ .cwd_relative = b.pathFromRoot(".zig-cache") }).step);

    const minichlink_step = b.step("minichlink", "minichlink");
    ch32.addMinichlink(b, ch32_dep, minichlink_step);
}