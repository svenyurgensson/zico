const std = @import("std");

pub const TaskDefT = *const fn () void;
/// Defines a task for the scheduler at compile-time.
pub const TaskDef = struct {
    /// The name of the task, used to generate the TaskID enum.
    name: []const u8,
    /// A pointer to the task's function. Must be `fn() void`.
    func: TaskDefT,
    /// Additional stack size required by the task, in bytes.
    stack_size: u8,
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

pub const TaskState = enum(u4) {
    idle = 0,
    ready = 1,
    suspended = 2,
    waiting_on_timer = 3,
    waiting_on_semaphore = 4,
    waiting_on_channel_send = 5,
    waiting_on_channel_receive = 6,
};

pub const TaskFlags = packed struct {
    state: TaskState,
    has_message: bool,
    priority: u3,
};

pub const TSS = extern struct {
    sp: u32,
    next_addr: u32,
    delay_timer: u16,
    flags: TaskFlags,
    _padding: u8 = 0,

    pub fn init(entry_point: u32, stack_ptr: u32) TSS {
        return .{
            .sp = stack_ptr,
            .next_addr = entry_point,
            .flags = .{ .state = .idle, .has_message = false, .priority = 0 },
            .delay_timer = 0,
        };
    }

    pub inline fn getState(self: *const TSS) TaskState {
        return self.flags.state;
    }
    pub inline fn setState(self: *TSS, new_state: TaskState) void {
        self.flags.state = new_state;
    }
    pub inline fn getDelayTimer(self: *const TSS) u16 {
        return self.delay_timer;
    }
    pub inline fn setDelayTimer(self: *TSS, timer: u16) void {
        self.delay_timer = timer;
    }
};
