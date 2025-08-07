const std = @import("std");
const log = std.log;
const xev = @import("xev");
const eproxy = @import("eproxy");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Initialize libxev event loop
    var thread_pool = xev.ThreadPool.init(.{ .max_threads = 2 });
    defer thread_pool.deinit();
    defer thread_pool.shutdown();

    var loop = try xev.Loop.init(.{
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();

    const address = try eproxy.resolveAddress(allocator, "httpbin.org");

    const socket = try xev.TCP.init(address);
    const fetchContext = try FetchContext.init(allocator, struct {
        // Callback to handle the result of the fetch operation
        pub fn callback(result: FetchError![]u8) void {
            const response = result catch |err| {
                log.err("Fetch failed: {}", .{err});
                return;
            };
            log.info("Fetch completed successfully\n{s}", .{response});
        }
    }.callback);
    socket.connect(&loop, &fetchContext.connect_completion, address, FetchContext, fetchContext, connectCallback);

    try loop.run(.until_done);
}

const FetchError = error{
    ConnectionFailed,
    WriteError,
    ReadError,
    ShutdownError,
    OutOfMemory,
    NoAddressesFound,
};

const FetchCallback = *const fn (
    result: FetchError![]u8,
) void;

const FetchContext = struct {
    connect_completion: xev.Completion = undefined,
    write_completion: xev.Completion = undefined,
    read_completion: xev.Completion = undefined,
    shutdown_completion: xev.Completion = undefined,

    read_buffer: [read_buffer_size]u8 = undefined,
    response_buffer: std.ArrayList(u8) = undefined,

    allocator: std.mem.Allocator,

    request_string: []const u8 = undefined,

    callback: FetchCallback = undefined,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, callback: FetchCallback) !*Self {
        const ctx = try allocator.create(Self);
        ctx.callback = callback;
        ctx.response_buffer = std.ArrayList(u8).init(allocator);
        ctx.allocator = allocator;
        return ctx;
    }

    pub fn deinit(self: *Self) void {
        self.response_buffer.deinit();
        self.allocator.free(self.request_string);
        self.allocator.destroy(self);
    }
};

fn connectCallback(
    ctx_opt: ?*FetchContext,
    loop: *xev.Loop,
    completion: *xev.Completion,
    socket: xev.TCP,
    result: xev.ConnectError!void,
) xev.CallbackAction {
    _ = completion;

    const ctx = ctx_opt orelse return .disarm;
    result catch {
        ctx.callback(FetchError.ConnectionFailed);
        ctx.deinit();
        return .disarm;
    };

    const request = eproxy.Request.init(.GET, "httpbin.org", "/get");
    ctx.request_string = request.allocPrint(ctx.allocator) catch {
        ctx.callback(FetchError.OutOfMemory);
        ctx.deinit();
        return .disarm;
    };

    socket.write(
        loop,
        &ctx.write_completion,
        .{ .slice = ctx.request_string },
        FetchContext,
        ctx,
        writeCallback,
    );

    return .disarm;
}

const read_buffer_size = 10;

fn writeCallback(
    ctx_opt: ?*FetchContext,
    loop: *xev.Loop,
    completion: *xev.Completion,
    socket: xev.TCP,
    write_buffer: xev.WriteBuffer,
    result: xev.WriteError!usize,
) xev.CallbackAction {
    _ = completion;
    _ = write_buffer;

    const ctx = ctx_opt orelse return .disarm;
    _ = result catch {
        ctx.callback(FetchError.WriteError);
        ctx.deinit();
        return .disarm;
    };

    socket.read(
        loop,
        &ctx.read_completion,
        .{ .slice = &ctx.read_buffer },
        FetchContext,
        ctx,
        readCallback,
    );

    return .disarm;
}

fn readCallback(ctx_opt: ?*FetchContext, loop: *xev.Loop, completion: *xev.Completion, socket: xev.TCP, read_buffer: xev.ReadBuffer, result: xev.ReadError!usize) xev.CallbackAction {
    _ = completion;

    const ctx = ctx_opt orelse return .disarm;
    const bytes_read = result catch |err| {
        // EOF indicates the server has closed the connection
        if (err == xev.ReadError.EOF) {
            // Not sure if the callback should be called before shutdown?
            ctx.callback(ctx.response_buffer.items);
            socket.shutdown(loop, &ctx.shutdown_completion, FetchContext, ctx, shutdownCallback);
        } else {
            ctx.callback(FetchError.ReadError);
            ctx.deinit();
        }
        return .disarm;
    };

    // Process the response here (for simplicity, just logging it)
    const response_data = read_buffer.slice[0..bytes_read];
    log.debug("{} bytes: {s}", .{ bytes_read, response_data });
    ctx.response_buffer.appendSlice(response_data) catch {
        ctx.callback(FetchError.OutOfMemory);
        ctx.deinit();
        return .disarm;
    };

    return .rearm;
}

fn shutdownCallback(ctx_opt: ?*FetchContext, loop: *xev.Loop, completion: *xev.Completion, socket: xev.TCP, result: xev.ShutdownError!void) xev.CallbackAction {
    _ = loop;
    _ = completion;
    _ = socket;

    const ctx = ctx_opt orelse return .disarm;
    result catch {
        // No need to call the callback here, as we already did in readCallback
        ctx.deinit();
        return .disarm;
    };

    ctx.deinit();
    return .disarm;
}
