# zico - A Tiny-Coroutine Scheduler for RISC-V MCUs

`zico` is a lightweight, stackful coroutine (task) scheduler designed for resource-constrained microcontrollers, specifically targeting the `CH32V003` RISC-V MCU. It is designed to be used in conjunction with the `ch32_zig` Hardware Abstraction Layer (HAL) library.

It provides a simple, cooperative multitasking environment with minimal memory footprint.

## Features

-   **Stackfull Coroutines:** Tasks have their own stacks, but use minimum RAM for that.
-   **Cooperative Scheduling:** Tasks yield control explicitly, allowing for predictable execution.
-   **Compile-Time Task Definition:** Tasks are defined at compile-time, allowing for optimized memory layout and type-safe task management.
-   **Simple API:** A minimal set of functions for task control.

<details>
<summary><h2>How to use with `ch32_zig` library</h2></summary>


This guide explains how to add `zico` as a dependency to your own Zig project, specifically when using the [ch32_zig](https://github.com/ghostiam/ch32_zig) HAL library.

### 1. Add `zico` and `ch32` to your `build.zig.zon`

First, you need to add `zico` and `ch32` to your project's dependencies in the `build.zig.zon` file.

```zig
.{
    .name = "my-awesome-project",
    .version = "0.0.1",
    .dependencies = .{
        .zico = .{
            // Replace with the path or URL to your zico library.
            // For local development, use a path relative to your project root.
            .path = "../zico", // Example for local development
            // or for a remote dependency:
            // .url = "https://github.com/svenyurgensson/zico/archive/refs/heads/main.zip",
            // .hash = "123456789...", // Replace with correct hash after zig fetch
        },
        .ch32 = .{
            .url = "https://github.com/ghostiam/ch32_zig/archive/refs/heads/master.zip",
            // Replace with the correct hash after fetching
            .hash = "ch32_zig-0.0.0-KNlt8xf_mgDXNfaFumvgABLp5MuEFkSPMJT4sOI0xGRZ", 
        },
    },
    .minimum_zig_version = "0.15.2",
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

After adding this, run `zig build` in your project's root to fetch remote dependencies and get the correct `.hash` values.

### 2. Configure `build.zig`

Next, configure your `build.zig` to make `zico` and `ch32` (especially its `hal` module) available to your firmware executable.

```zig
const std = @import("std");
const ch32 = @import("ch32"); // Import the ch32 build system utilities

pub fn build(b: *std.Build) void {
    // Get the ch32 dependency information
    const ch32_dep = b.dependency("ch32", .{});
    // Get the zico dependency information
    const zico_dep = b.dependency("zico", .{});

    // Define your target microcontroller (e.g., CH32V003)
    const target_chip = .{ .series = .ch32v003 };
    const target = ch32.zigTarget(target_chip);
    const optimize = b.standardOptimizeOption(.{});

    // Create the zico module from its source files
    const zico_module = b.createModule(.{
        .root_source_file = zico_dep.path("src/zico.zig"),
        .imports = &.{
            .{ .name = "task", .source_file = zico_dep.path("src/task.zig"), .stack_size = 4 * 16  },
            .{ .name = "message", .source_file = zico_dep.path("src/message.zig"), .stack_size = 4 * 16  },
        },
    });

    // Get the HAL module from the ch32 dependency
    const hal_module = ch32_dep.module("hal");

    // Create your firmware executable
    const exe = b.addExecutable(.{
        .name = "my-firmware",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Set the linker script provided by the ch32 library
    exe.setLinkerScript(ch32.linkerScript(b, target_chip));
    
    // Add the zico and hal modules to your executable
    exe.addModule("zico", zico_module);
    exe.addModule("hal", hal_module); // Make hal module available

    // Install the executable
    b.installArtifact(exe);

    // Optional: Add flashing, size reporting, etc. using ch32 utilities
    ch32.installFirmware(b, exe, .{}); // for .bin
    ch32.installFirmware(b, exe, .{ .format = .elf }); // for .elf
    ch32.printFirmwareSize(b, exe); // Print size information

    // Add a run step for convenience (e.g., `zig build run`)
    const run_step = b.step("run", "Run firmware (e.g., flash)");
    run_step.dependOn(&ch32.addMinichlink(b, ch32_dep, exe).step);
}
```

### Usage in Your Code (`src/main.zig`)

Now you can import and use `zico` and `hal` in your `src/main.zig`.

To remain library-agnostic, `zico` requires you to provide a function that returns the current time in milliseconds. This is done by passing a configuration struct to the `scheduler.init()` method. The provided function will be used for all time-related operations, such as `scheduler.delay()`.

In the example below, we use the `hal.time.millis` function provided by the `ch32_zig` HAL.

```zig
const std = @import("std");
const hal = @import("hal"); // Import the HAL module provided by ch32_zig
const zico = @import("zico"); // Import the zico scheduler library

// 1. Define your task functions
fn my_task_1() void {
    while (true) {
        // Do something...
        scheduler.delay(100); // Wait for 100ms
    }
}

fn my_task_2() void {
    while (true) {
        // Do something else...
        scheduler.yield(); // Yield to other tasks
    }
}

// 2. Create a compile-time array of task definitions
const AppTaskDefs = [_]zico.TaskDef{
    .{ .name = "task1", .func = &my_task_1, .stack_size = 4 * 16  },
    .{ .name = "task2", .func = &my_task_2, .stack_size = 4 * 16  },
};

// 3. Generate the Scheduler type and create a public instance
// NOTE: This `scheduler` variable must be accessible by your tasks.
// Keeping it `pub` in your main.zig is the simplest way.
pub const Scheduler = zico.Zico(&AppTaskDefs);
pub var scheduler: Scheduler = undefined;

// 4. Define your interrupt vector table using ch32_zig's HAL
pub const interrupts: hal.interrupts.VectorTable = .{
    .SysTick = hal.time.sysTickHandler,
    .HardFault = zico.InterruptHandler, // Use zico's software interrupt handler
};

// 5. Initialize and run the scheduler in main
pub fn main() !void {
    // Hardware initialization using ch32_zig HAL
    const clock = hal.clock.setOrGet(.hsi_max);
    hal.time.init(clock);

    // Initialize the scheduler, providing a timer function.
    // The get_time_ms function must return the current time in milliseconds as a u32.
    scheduler = Scheduler.init(.{
        .get_time_ms = hal.time.millis,
    });

    // Enable interrupts globally
    hal.interrupts.globalEnable();

    // Run the scheduler (this call never returns)
    scheduler.runLoop();
}
```
</details>


<details>
<summary><h2>How to use with `microzig` library</h2></summary>


This guide explains how to add `zico` as a dependency to your own Zig project, specifically when using the [microzig](https://github.com/ZigEmbeddedGroup/microzig) HAL library.

### 1. Add `zico` and `microzig` to your `build.zig.zon`

First, you need to add `zico` and `microzig` to your project's dependencies in the `build.zig.zon` file.

```zig
.{
    .name = .blinky_zico_mz,
    .version = "0.0.0",
    .fingerprint = 0xbb4e0e5807f9be4c, // Changing this has security and trust implications.
    .minimum_zig_version = "0.15.2",
    .dependencies = .{
        .microzig = .{
            .url = "https://github.com/ZigEmbeddedGroup/microzig/archive/refs/heads/master.zip",
            .hash = "microzig-0.15.0-D20YSdPQ2wAcAkdrGfWzHVlfghpoEoncxTYakDSLTbMX",
        },
        .zico = .{
            // zig fetch --save=ch32 https://github.com/svenyurgensson/zico/archive/refs/heads/master.zip
            .path = "../..",
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```
### 2. Configure `build.zig`

Next, configure your `build.zig` to make `zico` and `microzig` available to your firmware executable.

Take a look at example: [mlinky_mz](examples/blinky_mz/build.zig)


### Usage in Your Code (`src/main.zig`)

Take a look at example: [mlinky_mz](examples/blinky_mz/src/main.zig)


</details>

### Debugging with VS Code

For convenient debugging, a `dev_resources/vscode` directory is provided, containing sample VS Code debugger configurations. You can copy these configurations to your project's `.vscode` directory to quickly set up debugging.

## Public API

The scheduler instance provides several methods for task control. These are typically called on a global `scheduler` variable defined in your `main.zig`.

### `scheduler.yield()`

Voluntarily yields control to the scheduler, allowing other tasks to run. The current task is placed back in the ready queue and will run again on a future scheduling cycle.

```zig
fn my_task() void {
    while (true) {
        // Do some work...
        log.info("Task part 1", .{});
        
        // Give other tasks a chance to run
        scheduler.yield();
        
        // Continue work...
        log.info("Task part 2", .{});
        scheduler.yield();
    }
}
```

### `scheduler.delay(milliseconds: u16)`

Pauses the current task for a specified duration in milliseconds. The task will be moved to a waiting state and will not be scheduled again until the timer expires.

```zig
fn led_blinker_task() void {
    const led = // ... initialize GPIO pin
    while (true) {
        led.toggle();
        // Wait for 500ms before toggling again
        scheduler.delay(500);
    }
}
```

### `scheduler.suspendTask(task_id: TaskID)`

Suspends a different task, specified by its `TaskID`. The suspended task will not be scheduled until it is resumed by another task. The `TaskID` is an enum generated at compile-time from the names provided in `AppTaskDefs`.

```zig
const AppTaskDefs = [_]zico.TaskDef{
    .{ .name = "blinker", .func = &blinker_task, .stack_size = 4 * 16  },
    .{ .name = "controller", .func = &controller_task, .stack_size = 4 * 16  },
};

// ... in controller_task ...
// Stop the blinker task
scheduler.suspendTask(.blinker);
```

### `scheduler.resumeTask(task_id: TaskID)`

Resumes a previously suspended task, making it ready to run again.

```zig
// ... in controller_task ...
// Restart the blinker task
scheduler.resumeTask(.blinker);
```

### `scheduler.getTaskState(comptime task_id: TaskID) TaskState`

Returns the current state of a task specified by its `task_id`. The `task_id` must be known at compile time (e.g., `.my_task`). Providing an invalid `task_id` will result in a compile-time error. This method is useful for monitoring or debugging task execution.

```zig
// Get the state of the "blinker" task
const blinker_state = scheduler.getTaskState(.blinker);
switch (blinker_state) {
    .ready => {
        std.log.info("Blinker is ready to run!", .{});
    },
    .suspended => {
        std.log.info("Blinker is currently suspended.", .{});
    },
    .waiting_on_timer => {
        std.log.info("Blinker is delaying.", .{});
    },
    else => {
        std.log.info("Blinker is in state: {}", .{blinker_state});
    },
}
```

### `scheduler.suspendSelf()`

Suspends the currently running task. This is useful for tasks that should only run once or need to be explicitly woken up by another part of the system.

```zig
fn setup_task() void {
    // Perform one-time setup
    setup_i2c();
    setup_spi();

    // This task is done, suspend it forever.
    scheduler.suspendSelf();
}
```

## Synchronization with Semaphores

`zico` provides a basic counting semaphore for synchronizing tasks or controlling access to shared resources.

### `zico.Semaphore.init(initial_count: u8) Semaphore`

Initializes a new semaphore with a given initial count.

### `semaphore.wait()`

Decrements the semaphore's count. If the count is already zero, the calling task will block and be moved to a waiting state until another task signals the semaphore.

### `semaphore.signal()`

Increments the semaphore's count. If any tasks are waiting on the semaphore, one of them will be unblocked and moved to the ready state.

### Example: Producer-Consumer

Here's how to use a semaphore to manage a shared resource between a producer and a consumer task.

```zig
const std = @import("std");
const zico = @import("zico");
const hal = @import("hal");

// A shared resource, e.g., a single-item buffer
var shared_buffer: ?u8 = null;

// A semaphore to signal when the buffer is full
var buffer_full_sem = zico.Semaphore.init(0);
// A semaphore to signal when the buffer is empty
var buffer_empty_sem = zico.Semaphore.init(1);

// Producer task: writes data to the buffer
fn producer_task() void {
    var data: u8 = 0;
    while (true) {
        // Wait until the buffer is empty
        buffer_empty_sem.wait();

        // Write to the shared resource
        shared_buffer = data;
        std.log.info("Produced: {}", .{data});
        data += 1;

        // Signal that the buffer is now full
        buffer_full_sem.signal();
    }
}

// Consumer task: reads data from the buffer
fn consumer_task() void {
    while (true) {
        // Wait until the buffer is full
        buffer_full_sem.wait();

        // Read from the shared resource
        const data = shared_buffer orelse @panic("Buffer should not be null!");
        shared_buffer = null;
        std.log.info("Consumed: {}", .{data});

        // Signal that the buffer is now empty
        buffer_empty_sem.signal();

        // Add a small delay to make the output readable
        scheduler.delay(1000);
    }
}

const AppTaskDefs = [_]zico.TaskDef{
    .{ .name = "producer", .func = &producer_task, .stack_size = 4 * 16  },
    .{ .name = "consumer", .func = &consumer_task, .stack_size = 4 * 16  },
};

// ... main function and scheduler setup ...
```

## Message Channels

`zico` provides generic, fixed-size channels for thread-safe message passing between tasks.

### `zico.Channel(comptime T: type, comptime size: usize) type`

This is a comptime-generic function that returns a `Channel` type configured for a specific message type `T` and buffer `size`.

### `channel.init() Self`

Initializes a new channel instance.

### `channel.send(message: T)`

Sends a `message` to the channel. If the channel's buffer is full, the calling task will block until space becomes available.

### `channel.receive() T`

Receives a message from the channel. If the channel's buffer is empty, the calling task will block until a message is sent.

### Example: Sender-Receiver

Here's how to use a channel for communication between a sender and a receiver task.

```zig
const std = @import("std");
const zico = @import("zico");
const hal = @import("hal");

// Define a channel that can hold 4 `u8` messages.
var data_channel = zico.Channel(u8, 4).init();

// Sender task
fn sender_task() void {
    var count: u8 = 0;
    while (true) {
        data_channel.send(count);
        std.log.info("Sent: {}", .{count});
        count += 1;
        scheduler.delay(300); // Send every 300ms
    }
}

// Receiver task
fn receiver_task() void {
    while (true) {
        const received_value = data_channel.receive();
        std.log.warn("Received: {}", .{received_value});
        scheduler.delay(1000); // Process every 1000ms
    }
}

const AppTaskDefs = [_]zico.TaskDef{
    .{ .name = "sender", .func = &sender_task, .stack_size = 4 * 16  },
    .{ .name = "receiver", .func = &receiver_task, .stack_size = 4 * 16  },
};

// ... main function and scheduler setup ...
```





## Configuration

You can customize certain `zico` parameters at compile-time by defining public constants in your project's root source file (e.g., `src/main.zig`).

### `ZICO_MAX_WAITING_TASKS`

This constant defines the maximum number of tasks that can be waiting on a single semaphore or channel at any given time.

-   **Type:** `usize`
-   **Default:** `8`

If you need to support more waiting tasks for a synchronization object, you can increase this value. Note that this will increase the RAM usage for every `Semaphore` and `Channel` instance.

#### Example

To change the wait queue size to 16, add the following line to the top of your `src/main.zig`:

```zig
// Set the max waiting tasks for all semaphores and channels to 16
pub const ZICO_MAX_WAITING_TASKS = 16;

const std = @import("std");
const hal = @import("hal");
const zico = @import("zico");
// ... rest of your code
```

## Important information!

When writing tasks for the `zico` scheduler, it is crucial to adhere to several important rules and conventions to ensure system stability.


### 1. Stack Size (`stack_size`)

In the `zico.TaskDef` task definition, the `stack_size` field is of type `u8`.

*   This imposes a **compile-time limit of 255 bytes** for the user-defined portion of the task's stack.
*   Attempting to specify a value greater than 255 will result in a **compilation error**.
*   **Important:** The system automatically adds an additional 64 bytes (`MINIMAL_CONTEXT_STACK_SIZE`) to your specified size for the scheduler's own context. Thus, the actual allocated stack size will be `stack_size + 64` bytes.


### 2. Reserved Registers


For the scheduler to operate correctly, certain processor registers are reserved for its internal use. Modifying these registers within your user task code will lead to an immediate system crash.

#### `tp` (Thread Pointer) Register

*   **STATUS: DO NOT USE.**
*   This register is used to store a pointer to the scheduler instance. The `ecall` handler uses it to access the scheduler's state.


#### `mscratch` Register

*   **STATUS: DO NOT USE.**
*   This register is used during context switching to temporarily store stack pointers, facilitating a safe switch to the dedicated scheduler stack.


**Never modify the `tp` and `mscratch` registers in your application code.**

### 3. Timer Granularity

The `scheduler.delay()` function operates with a granularity of **1 millisecond (ms)**. This precision is determined by the underlying `hal.time.millis()` function, which is typically incremented by a SysTick interrupt at a 1ms interval.
Therefore, any delays you specify will be rounded to the nearest millisecond, and the shortest possible delay is 1ms.


## Examples

The `zico` library comes with several examples demonstrating its features. To build and flash them to your CH32V003 microcontroller, navigate to the respective example directory and use `zig build`.

Make sure you have `minichlink` or another compatible programmer for CH32V003 set up and connected.

### Blinky Example

A basic example demonstrating task creation and `scheduler.delay()` to blink an LED.

```bash

cd examples/blinky

zig build

# To flash: zig build minichlink

# To build for release: zig build -Doptimize=ReleaseSmall

# To build for debug: zig build -Doptimize=Debug

```



### Semaphore Example



Demonstrates inter-task synchronization using `zico.Semaphore` with a producer-consumer pattern.



```bash

cd examples/semaphore

zig build

# To flash: zig build minichlink

# To build for release: zig build -Doptimize=ReleaseSmall

# To build for debug: zig build -Doptimize=Debug

```



### Message Channel Example



Illustrates inter-task communication using `zico.Channel` for message passing.



```bash

cd examples/message

zig build

# To flash: zig build minichlink

# To build for release: zig build -Doptimize=ReleaseSmall

# To build for debug: zig build -Doptimize=Debug

```



### Channel Example



Another example demonstrating inter-task communication using `zico.Channel` for message passing.



```bash

cd examples/channel

zig build

# To flash: zig build minichlink

# To build for release: zig build -Doptimize=ReleaseSmall

# To build for debug: zig build -Doptimize=Debug

```



<!-- LICENSE -->

## License



Distributed under the MIT License. See [LICENSE.txt](./LICENSE.txt) for more information.



<!-- ... existing content ... -->

Yury Batenko - jurbat@gmail.com

Project Link: [https://github.com/svenyurgensson/zico](https://github.com/svenyurgensson/zico)
