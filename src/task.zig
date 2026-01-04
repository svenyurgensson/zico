const std = @import("std");

/// Defines a task for the scheduler at compile-time.
pub const TaskDef = struct {
    /// The name of the task, used to generate the TaskID enum.
    name: []const u8,
    /// A pointer to the task's function. Must be `fn() void`.
    func: *const fn () void,
};

/// A comptime function that creates a tagged union of task function pointers
/// from an array of `TaskDef`s. The union's tag is an enum generated from
/// the task names.
pub fn CreateTaskUnion(comptime definitions: []const TaskDef) type {
    var enum_fields: [definitions.len]std.builtin.Type.EnumField = undefined;
    inline for (definitions, 0..) |def, i| {
        const name_z: [:0]const u8 = def.name[0..def.name.len :0];
        enum_fields[i] = .{ .name = name_z, .value = i };
    }

    const TagType = @Type(.{
        .@"enum" = .{ .tag_type = u8, .fields = &enum_fields, .decls = &.{}, .is_exhaustive = true },
    });

    const FnPtrType = *const fn () void;
    const FnPtrAlign = @alignOf(FnPtrType);
    var union_fields: [definitions.len]std.builtin.Type.UnionField = undefined;

    inline for (definitions, 0..) |def, i| {
        const name_z: [:0]const u8 = def.name[0..def.name.len :0];
        union_fields[i] = .{
            .name = name_z,
            .type = FnPtrType,
            .alignment = FnPtrAlign,
        };
    }

    return @Type(.{
        .@"union" = .{ .layout = .auto, .tag_type = TagType, .fields = &union_fields, .decls = &.{} },
    });
}
