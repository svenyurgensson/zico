const std = @import("std");
const hal = @import("hal");
const zico = @import("zico");

// --- Определение задач ---
const led = hal.Pin.init(.GPIOD, 4);

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
    .{ .name = "debug", .func = &debug_task, .stack_size = 4 * 3 },
};

// Генерируем тип планировщика
pub const Scheduler = zico.Zico(&AppTaskDefs);
// Глобальная переменная для экземпляра планировщика
pub var scheduler: Scheduler = undefined;

// Экспортируем таблицу прерываний, чтобы она была доступна HAL
pub const interrupts: hal.interrupts.VectorTable = .{
    .SysTick = hal.time.sysTickHandler,
    .SW = Scheduler.SoftwareInterruptHandler,
};

pub fn main() void {
    const clock = hal.clock.setOrGet(.hsi_max);
    hal.time.init(clock);

    led.enablePort();
    led.asOutput(.{ .speed = .max_50mhz, .mode = .push_pull });

    scheduler = Scheduler.init();
    //zico.g_zico_instance = &scheduler;

    hal.interrupts.globalEnable();

    scheduler.runLoop();
}
