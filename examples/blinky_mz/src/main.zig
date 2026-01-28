const std = @import("std");
const microzig = @import("microzig");
const zico = @import("zico");
const hal = microzig.hal;
const cpu = microzig.cpu;
const peripherals = microzig.chip.peripherals;
const PFIC = peripherals.PFIC;
const RCC = peripherals.RCC;

const led = if (cpu.cpu_name == .@"qingkev2-rv32ec")
    hal.gpio.Pin.init(3, 4) // PD4
else
    hal.gpio.Pin.init(0, 3); // PA3

pub const microzig_options: microzig.Options = .{
    .overwrite_hal_interrupts = true,
    .interrupts = .{
        .SysTick = sys_tick_handler,
        .HardFault = zico.InterruptHandler,
    },
};

const SysTicksPer = packed struct(u32) {
    us: u8 = 0, // 1 - 144
    ms: u24 = 0, // 1_000 - 144_000
};
var systicks_per = SysTicksPer{};
var systick_millis: u32 = 0;

fn sys_tick_handler() callconv(cpu.riscv_calling_convention) void {
    PFIC.STK_CMPLR.raw +%= systicks_per.ms;
    // Clear the trigger state for the next interrupt.
    PFIC.STK_SR.modify(.{ .CNTIF = 0 });

    systick_millis +%= 1;
}

const hsi_frequency: u32 = 24_000_000;

fn sys_tick_setup() void {
    systicks_per.us = @truncate(hsi_frequency / 1_000_000);
    systicks_per.ms = @truncate(hsi_frequency / 1_000_00);

    hal.rcc_init_hsi_pll();

    // Configure SysTick
    // Reset configuration.
    PFIC.STK_CTLR.raw = 0;
    // Reset the Count Register.
    PFIC.STK_CNTL.raw = 0;
    // Set the compare register to trigger once per second.
    PFIC.STK_CMPLR.raw = systicks_per.ms - 1;
    // Set the SysTick Configuration.
    PFIC.STK_CTLR.modify(.{
        // Turn on the system counter STK
        .STE = 1,
        // Enable counter interrupt.
        .STIE = 1,
        // HCLK for time base.
        .STCLK = 1,
        // Re-counting from 0 after counting up to the comparison value.
        .STRE = 1,
    });
    // Clear the trigger state for the next interrupt.
    PFIC.STK_SR.modify(.{ .CNTIF = 0 });

    // Enable SysTick interrupt.
    cpu.interrupt.enable(.SysTick);
}

pub inline fn millis() u32 {
    return systick_millis;
}

fn led_task() void {
    while (true) {
        scheduler.yield();

        led.toggle();
        scheduler.delay(500);
        scheduler.suspendTask(.debug);
        scheduler.delay(500);
        scheduler.resumeTask(.debug);
    }
}

fn debug_task() void {
    while (true) {
        scheduler.delay(1000);
    }
}

// Создаем comptime-массив с определениями задач и стеком для каждой (в байтах)
const AppTaskDefs = [_]zico.TaskDef{
    .{ .name = "led", .func = &led_task, .stack_size = 4 * 16 },
    .{ .name = "debug", .func = &debug_task, .stack_size = 4 * 8 },
};

// Генерируем тип планировщика, передавая конфигурацию времени
pub const Scheduler = zico.Zico(&AppTaskDefs);
// Глобальная переменная для экземпляра планировщика
pub var scheduler: Scheduler = undefined;

pub fn main() !void {
    // Enable Port
    if (cpu.cpu_name == .@"qingkev2-rv32ec")
        peripherals.RCC.APB2PCENR.modify(.{ .IOPDEN = 1 })
    else
        peripherals.RCC.APB2PCENR.modify(.{ .IOPAEN = 1 });

    // Set the LED pin as output.
    led.set_output_mode(.general_purpose_push_pull, .max_50MHz);
    sys_tick_setup();

    scheduler = Scheduler.init(.{
        .get_time_ms = millis,
    });

    cpu.interrupt.enable_interrupts();

    scheduler.runLoop();
}
