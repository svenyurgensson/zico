const std = @import("std");
const microzig = @import("microzig");
const MicroBuild = microzig.MicroBuild(.{
    .ch32v = true,
});

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const zico_dep = b.dependency("zico", .{});
    const zico_module = zico_dep.module("zico");
    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    const target = mb.ports.ch32v.chips.ch32v003x4;
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSmall;

    const name = "blinky_mz";
    const firmware = mb.add_firmware(.{
        .name = name,
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });
    if (firmware.artifact.root_module.import_table.get("app")) |app_module| {
        app_module.addImport("zico", zico_module);
    } else {
        firmware.artifact.root_module.addImport("zico", zico_module);
    }
    //firmware.artifact.root_module.addImport("zico", zico_module);

    mb.install_firmware(firmware, .{ .format = .elf });

    const installAssembly = b.addInstallBinFile(firmware.artifact.getEmittedAsm(), name ++ ".s");
    b.getInstallStep().dependOn(&installAssembly.step);

    const run_objdump = b.addSystemCommand(&.{ "riscv-none-elf-size", "-G" });
    run_objdump.addFileArg(firmware.emitted_elf.?);
    b.getInstallStep().dependOn(&run_objdump.step);

    // Use GNU objcopy instead of LLVM objcopy to avoid 512MB binary issue.
    // LLVM objcopy includes LOAD segments for NOLOAD sections, causing the binary
    // to span from flash (0x0) to RAM (0x20000000) = 512MB of zeros.
    const gnu_objcopy = b.findProgram(&.{"riscv64-unknown-elf-objcopy"}, &.{}) catch null;

    if (gnu_objcopy) |objcopy_path| {
        const bin_filename = b.fmt("{s}.bin", .{name});
        const objcopy_run = b.addSystemCommand(&.{objcopy_path});
        objcopy_run.addArgs(&.{ "-O", "binary" });
        objcopy_run.addArtifactArg(firmware.artifact);
        const bin_output = objcopy_run.addOutputFileArg(bin_filename);
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            bin_output,
            .{ .custom = "firmware" },
            bin_filename,
        ).step);
    }

    const clean_step = b.step("clean", "Clean up");
    clean_step.dependOn(&b.addRemoveDirTree(.{ .cwd_relative = b.install_path }).step);
    clean_step.dependOn(&b.addRemoveDirTree(.{ .cwd_relative = b.pathFromRoot(".zig-cache") }).step);
}
