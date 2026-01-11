const svd = @import("svd");
const PFIC = svd.peripherals.PFIC;

pub const EcallArgs = struct {
    a0: u32,
    a1: u32,
};
pub var ecall_args: EcallArgs = .{ .a0 = 0, .a1 = 0 };
pub const ecall_args_ptr: *volatile EcallArgs = &ecall_args;

// Temporary commenting out some clobbers, still not convincied that they should be here.
pub const ClobbersForEcall = .{
    .memory = true,
    .x1 = true, // ra
    // .x2 = true, // sp
    // .x3 = true, // gp
    // .x4 = true, // tp
    .x5 = true,
    .x6 = true,
    // .x7 = true, // t0-t2
    // .x8 = true,
    // .x9 = true, // s0-s1
    // .x10 = true,
    // .x11 = true,
    // .x12 = true,
    // .x13 = true,
    // .x14 = true,
    // .x15 = true, // a0-a5
};

pub const EcallType = enum(u8) {
    yield = 0,
    delay = 1,
    suspend_self = 2,
    sem_wait = 3,
    channel_send = 5,
    channel_receive = 6,
};

pub inline fn triggerSoftwareInterrupt() void {
    PFIC.STK_CTLR.modify(.{ .SWIE = 1 });
}

pub inline fn cleanSoftwareInterrupt() void {
    PFIC.STK_CTLR.modify(.{ .SWIE = 0 });
}

pub inline fn enableSoftwareInterrupt() void {
    const PFIC_IENR0: *volatile u32 = @ptrFromInt(0xE000E100);

    // Разрешить прерывание с кодом 14 (бит 14 в регистре IENR0)
    // IENR0 отвечает за прерывания 0-31
    const PFIC_ISR0: *volatile u32 = @ptrFromInt(0xE000E000);
    const current_enabled = PFIC_ISR0.*;
    PFIC_IENR0.* = current_enabled | (1 << 14); // Разрешить Software Interrupt
}
