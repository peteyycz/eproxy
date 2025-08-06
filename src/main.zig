const std = @import("std");
const log = std.log;
const xev = @import("xev");
const eproxy = @import("eproxy");

fn getAddressByUrl(
    allocator: std.mem.Allocator,
    url: []const u8,
) !std.net.Address {
    const address_list = try std.net.getAddressList(allocator, url, 80);
    defer address_list.deinit();
    if (address_list.addrs.len == 0) {
        return error.NoAddressesFound;
    }
    return address_list.addrs[0];
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Initialize libxev event loop
    var thread_pool = xev.ThreadPool.init(.{ .max_threads = 2 });
    defer thread_pool.deinit();

    var loop = try xev.Loop.init(.{
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();

    const address = try getAddressByUrl(allocator, "httpbin.org");

    const socket = try xev.TCP.init(address);

    const fetchContext = try FetchContext.init(allocator);
    socket.connect(&loop, &fetchContext.connect_completion, address, FetchContext, fetchContext, connectCallback);

    // Run the event loop to process all async operations
    try loop.run(.until_done);

    log.info("Loop stopped", .{});

    // Explicitly shutdown the thread pool
    thread_pool.shutdown();
}

const FetchContext = struct {
    connect_completion: xev.Completion = undefined,
    write_completion: xev.Completion = undefined,
    read_completion: xev.Completion = undefined,

    response_buffer: std.ArrayList(u8) = undefined,

    allocator: std.mem.Allocator,

    request_string: []const u8 = undefined,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const ctx = try allocator.create(Self);
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
    result catch |err| {
        log.err("Connection failed: {}", .{err});
        ctx.deinit();
        return .disarm;
    };

    log.info("Connected successfully", .{});

    const request = eproxy.Request.init(.GET, "httpbin.org", "/get");
    ctx.request_string = request.allocPrint(ctx.allocator) catch |err| {
        log.err("Failed to create request string: {}", .{err});
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
    const bytes_written = result catch |err| {
        log.err("Write failed: {}", .{err});
        ctx.deinit();
        return .disarm;
    };

    log.info("Bytes written: {}", .{bytes_written});

    var read_buffer: [read_buffer_size]u8 = undefined;
    socket.read(
        loop,
        &ctx.read_completion,
        .{ .slice = &read_buffer },
        FetchContext,
        ctx,
        readCallback,
    );

    return .disarm;
}

fn readCallback(ctx_opt: ?*FetchContext, loop: *xev.Loop, completion: *xev.Completion, socket: xev.TCP, read_buffer: xev.ReadBuffer, result: xev.ReadError!usize) xev.CallbackAction {
    _ = loop;
    _ = completion;
    _ = socket;

    const ctx = ctx_opt orelse return .disarm;
    const bytes_read = result catch |err| {
        if (err == xev.ReadError.EOF) {
            // EOF indicates the server has closed the connection
            log.info("Response is {s}", .{ctx.response_buffer.items});
            ctx.deinit();
        } else {
            log.err("Read error: {}", .{err});
            ctx.deinit();
        }
        return .disarm;
    };

    // Process the response here (for simplicity, just logging it)
    const response_data = read_buffer.slice[0..bytes_read];
    log.debug("{} bytes: {s}", .{ bytes_read, response_data });
    ctx.response_buffer.appendSlice(response_data) catch |err| {
        log.err("Failed to append response data: {}", .{err});
        ctx.deinit();
        return .disarm;
    };

    return .rearm;
}
