// This build script is intentionally a no-op.
// The library is meant to be consumed by a parent project's build script,
// which is responsible for creating the module from the source files.
pub fn build(_: *const @import("std").build.Builder) void {}
