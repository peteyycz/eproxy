const std = @import("std");
const xev = @import("xev");
const request_module = @import("request.zig");

const Request = request_module.Request;
const resolveAddress = request_module.resolveAddress;

pub fn doFetch(
    allocator: std.mem.Allocator,
    loop: *xev.Loop,
    request: Request,
    callback: Callback,
) !void {
    const ctx = try Context.init(allocator, request, callback);
    const host = ctx.request.getHost() orelse return Error.NoAddressesFound;
    const address = try resolveAddress(allocator, host);
    const socket = try xev.TCP.init(address);
    socket.connect(
        loop,
        &ctx.connect_completion,
        address,
        Context,
        ctx,
        connectCallback,
    );
}

pub const Error = error{
    ConnectionFailed,
    WriteError,
    ReadError,
    ShutdownError,
    OutOfMemory,
    NoAddressesFound,
};

const Callback = *const fn (
    allocator: std.mem.Allocator,
    loop: *xev.Loop,
    result: Error!std.ArrayList(u8),
) void;

pub const Context = struct {
    connect_completion: xev.Completion = undefined,
    write_completion: xev.Completion = undefined,
    read_completion: xev.Completion = undefined,
    shutdown_completion: xev.Completion = undefined,
    close_completion: xev.Completion = undefined,

    read_buffer: [read_buffer_size]u8 = undefined,
    response_buffer: std.ArrayList(u8) = undefined,

    allocator: std.mem.Allocator,

    request: Request,
    request_string: []const u8 = undefined,

    callback: Callback = undefined,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, request: Request, callback: Callback) !*Self {
        const ctx = try allocator.create(Self);
        ctx.request = request;
        ctx.callback = callback;
        ctx.response_buffer = std.ArrayList(u8).init(allocator);
        ctx.allocator = allocator;
        return ctx;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.request_string);
        self.request.deinit();
        self.allocator.destroy(self);
    }
};

pub fn connectCallback(
    ctx_opt: ?*Context,
    loop: *xev.Loop,
    _: *xev.Completion,
    socket: xev.TCP,
    result: xev.ConnectError!void,
) xev.CallbackAction {
    const ctx = ctx_opt orelse return .disarm;
    result catch {
        closeSocket(ctx, loop, socket);
        ctx.callback(ctx.allocator, loop, Error.ConnectionFailed);
        return .disarm;
    };

    ctx.request_string = ctx.request.allocPrint(ctx.allocator) catch {
        closeSocket(ctx, loop, socket);
        ctx.callback(ctx.allocator, loop, Error.OutOfMemory);
        return .disarm;
    };

    socket.write(
        loop,
        &ctx.write_completion,
        .{ .slice = ctx.request_string },
        Context,
        ctx,
        writeCallback,
    );

    return .disarm;
}

const read_buffer_size = 10;

fn writeCallback(
    ctx_opt: ?*Context,
    loop: *xev.Loop,
    _: *xev.Completion,
    socket: xev.TCP,
    _: xev.WriteBuffer,
    result: xev.WriteError!usize,
) xev.CallbackAction {
    const ctx = ctx_opt orelse return .disarm;
    _ = result catch {
        closeSocket(ctx, loop, socket);
        ctx.callback(ctx.allocator, loop, Error.WriteError);
        return .disarm;
    };

    socket.read(
        loop,
        &ctx.read_completion,
        .{ .slice = &ctx.read_buffer },
        Context,
        ctx,
        readCallback,
    );

    return .disarm;
}

fn readCallback(
    ctx_opt: ?*Context,
    loop: *xev.Loop,
    _: *xev.Completion,
    socket: xev.TCP,
    read_buffer: xev.ReadBuffer,
    result: xev.ReadError!usize,
) xev.CallbackAction {
    const ctx = ctx_opt orelse return .disarm;
    const bytes_read = result catch |err| {
        // EOF indicates the server has closed the connection
        if (err == xev.ReadError.EOF) {
            // Not sure if the callback should be called before shutdown?
            const response_buffer = ctx.response_buffer;
            socket.shutdown(loop, &ctx.shutdown_completion, Context, ctx, shutdownCallback);
            ctx.callback(ctx.allocator, loop, response_buffer);
        } else {
            closeSocket(ctx, loop, socket);
            ctx.callback(ctx.allocator, loop, Error.ReadError);
        }
        return .disarm;
    };

    // Process the response here (for simplicity, just logging it)
    const response_data = read_buffer.slice[0..bytes_read];
    ctx.response_buffer.appendSlice(response_data) catch {
        closeSocket(ctx, loop, socket);
        ctx.callback(ctx.allocator, loop, Error.OutOfMemory);
        return .disarm;
    };

    return .rearm;
}

fn closeSocket(ctx: *Context, loop: *xev.Loop, socket: xev.TCP) void {
    socket.close(loop, &ctx.close_completion, Context, ctx, closeCallback);
}

fn shutdownCallback(ctx_opt: ?*Context, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, result: xev.ShutdownError!void) xev.CallbackAction {
    const ctx = ctx_opt orelse return .disarm;
    result catch {
        // No need to call the callback here, as we already did in readCallback
        ctx.deinit();
        return .disarm;
    };

    ctx.deinit();
    return .disarm;
}

fn closeCallback(ctx_opt: ?*Context, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, _: xev.CloseError!void) xev.CallbackAction {
    const ctx = ctx_opt orelse return .disarm;
    ctx.deinit();
    return .disarm;
}
