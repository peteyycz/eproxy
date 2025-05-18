const std = @import("std");
const xev = @import("xev");

// Global variable for timer completion to demonstrate the event loop
var timer_completed = false;

// Our userdata structure
const TimerContext = struct {
    completed: *bool,
};

// Timer callback function
fn timerCallback(
    ud: ?*TimerContext,
    l: *xev.Loop,
    c: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = l;
    _ = c;
    _ = result catch |err| {
        std.debug.print("Timer error: {}\n", .{err});
        return .disarm;
    };

    if (ud) |context| {
        std.debug.print("Timer fired!\n", .{});
        context.completed.* = true;
    }

    return .disarm;
}

// Set up the read completion callback
const ReadContext = struct {
    buffer: []u8,
    allocator: std.mem.Allocator,
};

fn read_callback(ud: ?*ReadContext, l: *xev.Loop, c: *xev.Completion, s: xev.File, b: xev.ReadBuffer, result: xev.ReadError!usize) xev.CallbackAction {
    _ = ud;
    _ = l;
    _ = c;
    _ = s;
    _ = b;
    const res = result catch |err| {
        if (err == xev.ReadError.EOF) {
            return .disarm;
        }
        std.debug.print("Read error: {}\n", .{err});
        return .disarm;
    };

    std.log.debug("Read res, {}\n", .{res});
    if (res > 0) {
        // std.debug.print("Read result {s}\n", .{b.slice});
        return .rearm;
    }

    return .disarm;
}

pub fn main() !void {
    // Initialize the allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Print startup message
    std.debug.print("Initializing libxev...\n", .{});

    // Initialize the event loop
    var loop = try xev.Loop.init(.{
        .entries = 16, // Number of events to process at once
    });
    defer loop.deinit();

    const file = try std.fs.cwd().openFile("src/main.zig", .{});
    defer file.close();

    const fd = xev.File.initFd(file.handle);
    const buffer_size = 2048;
    const buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(buffer);

    const read_buffer = xev.ReadBuffer{ .slice = buffer[0..] };

    var read_context = ReadContext{
        .buffer = buffer,
        .allocator = allocator,
    };

    var read_completion: xev.Completion = .{};
    fd.read(&loop, &read_completion, read_buffer, ReadContext, &read_context, read_callback);

    // Create our timer context
    var timer_context = TimerContext{
        .completed = &timer_completed,
    };
    // Create and initialize a timer
    var timer = try xev.Timer.init();
    defer timer.deinit();

    // Start the timer for 1000ms (1 second)
    const duration_ms = 1000;
    var timer_completion: xev.Completion = .{};
    timer.run(
        &loop,
        &timer_completion,
        duration_ms,
        TimerContext,
        &timer_context,
        timerCallback,
    );

    std.debug.print("Timer started for {}ms...\n", .{duration_ms});

    try loop.run(.until_done);

    std.debug.print("libxev demo completed successfully.\n", .{});
}
