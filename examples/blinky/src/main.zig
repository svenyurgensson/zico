const std = @import("std");
const hal = @import("hal");
const zico = @import("zico");

// --- Определение задач ---
fn led_task() void {
    const led = hal.Pin.init(.GPIOC, 13);
    led.enablePort();
    led.asOutput(.{ .speed = .max_50mhz, .mode = .push_pull });

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

// Создаем comptime-массив с определениями задач
const AppTaskDefs = [_]zico.TaskDef{
    .{ .name = "led", .func = &led_task },
    .{ .name = "debug", .func = &debug_task },
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

pub fn main() !void {
    // 1. Инициализация железа
    const clock = hal.clock.setOrGet(.hsi_max);
    hal.time.init(clock);

    // 3. Инициализация планировщика
    scheduler = Scheduler.init();

    // 4. Включаем прерывания глобально
    hal.interrupts.globalEnable();

    // 5. Запускаем планировщик. Эта функция не возвращает управление.
    scheduler.runLoop();
}
