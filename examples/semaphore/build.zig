const std = @import("std");
const ch32 = @import("ch32");

pub fn build(b: *std.Build) void {
    const ch32_dep = b.dependency("ch32", .{});

    const name = "semaphore";
    const targets: []const ch32.Target = &.{
        .{ .chip = .{ .series = .ch32v003 } },
    };

    //      ┌──────────────────────────────────────────────────────────┐
    //      │                          Build                           │
    //      └──────────────────────────────────────────────────────────┘
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSmall;

    // Load the dependencies

    for (targets) |target| {
        const zico_dep = b.dependency("zico", .{
            .target = b.resolveTargetQuery(target.chip.target()),
            .optimize = optimize,
        });
        const zico_module = zico_dep.module("zico");

        const fw = ch32.addFirmware(b, ch32_dep, .{
            .name = b.fmt("{s}_{s}", .{ name, target.chip.string() }),
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        // Get modules from fw
        const app_mod = fw.root_module.import_table.get("app").?;
        const hal_mod = fw.root_module.import_table.get("hal").?;
        const svd_mod = fw.root_module.import_table.get("svd").?;

        // Make zico knows that modules
        zico_module.addImport("hal", hal_mod);
        zico_module.addImport("svd", svd_mod);
        zico_module.addImport("ch32", fw.root_module);

        app_mod.addImport("zico", zico_module);

        // Emit the bin file for flashing.
        const fw_bin = ch32.installFirmware(b, fw, .{});
        ch32.printFirmwareSize(b, fw_bin);

        // Emit the elf file for debugging.
        _ = ch32.installFirmware(b, fw, .{ .format = .elf });
    }

    //      ┌──────────────────────────────────────────────────────────┐
    //      │                          Clean                           │
    //      └──────────────────────────────────────────────────────────┘
    const clean_step = b.step("clean", "Clean up");
    clean_step.dependOn(&b.addRemoveDirTree(.{ .cwd_relative = b.install_path }).step);
    clean_step.dependOn(&b.addRemoveDirTree(.{ .cwd_relative = b.pathFromRoot(".zig-cache") }).step);

    //      ┌──────────────────────────────────────────────────────────┐
    //      │                        minichlink                        │
    //      └──────────────────────────────────────────────────────────┘
    const minichlink_step = b.step("minichlink", "minichlink");
    ch32.addMinichlink(b, ch32_dep, minichlink_step);
}
