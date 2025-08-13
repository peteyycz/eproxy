const std = @import("std");
const xev = @import("xev");
const log = std.log;
const util = @import("util.zig");
const request = @import("request.zig");
const HeaderMap = @import("header_map.zig").HeaderMap;

const parseRequest = request.parseRequest;

// TODO: Consider pooling like https://github.com/dylanblokhuis/xev-http/blob/master/src/main.zig
const Context = struct {
    allocator: std.mem.Allocator,
    loop: *xev.Loop,
    socket: xev.TCP,

    accept_completion: xev.Completion = undefined,
    close_completion: xev.Completion = undefined,

    pub fn init(allocator: std.mem.Allocator, loop: *xev.Loop, socket: xev.TCP) !*Context {
        const ctx = try allocator.create(Context);
        ctx.allocator = allocator;
        ctx.loop = loop;
        ctx.socket = socket;
        return ctx;
    }

    pub fn deinit(self: *Context) void {
        self.allocator.destroy(self);
    }
};

pub fn createServer(allocator: std.mem.Allocator, loop: *xev.Loop, port: u16) !void {
    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const socket = try xev.TCP.init(address);
    try socket.bind(address);
    try socket.listen(128); // Listen backlog size

    const ctx = try Context.init(allocator, loop, socket);

    socket.accept(loop, &ctx.accept_completion, Context, ctx, serverAcceptCallback);
}

fn serverAcceptCallback(
    ctx_opt: ?*Context,
    loop: *xev.Loop,
    _: *xev.Completion,
    r: xev.AcceptError!xev.TCP,
) xev.CallbackAction {
    const ctx = ctx_opt orelse return .disarm;
    const client_socket = r catch {
        // Accept failed, close the socket and return
        util.closeSocket(Context, ctx, ctx.loop, ctx.socket);
        return .disarm;
    };

    // TODO: Intialize an arena allocator for the client context and don't use the global allocator
    const client_ctx = ClientContext.init(ctx.allocator, loop) catch {
        return .disarm;
    };
    client_socket.read(loop, &client_ctx.read_completion, .{ .slice = &client_ctx.read_buffer }, ClientContext, client_ctx, clientReadCallback);

    return .rearm;
}

const chunk_size = 10; // 4 KiB read buffer

const ClientContext = struct {
    allocator: std.mem.Allocator,
    loop: *xev.Loop,

    read_buffer: [chunk_size]u8 = undefined,
    request_buffer: std.ArrayList(u8),

    current_request_start: usize = 0,

    read_completion: xev.Completion = undefined,
    shutdown_completion: xev.Completion = undefined,
    close_completion: xev.Completion = undefined,

    pub fn init(allocator: std.mem.Allocator, loop: *xev.Loop) !*ClientContext {
        const ctx = try allocator.create(ClientContext);
        ctx.request_buffer = std.ArrayList(u8).init(allocator);
        ctx.allocator = allocator;
        ctx.loop = loop;
        ctx.current_request_start = 0;
        return ctx;
    }

    pub fn deinit(self: *ClientContext) void {
        self.request_buffer.deinit();
        self.allocator.destroy(self);
    }
};

// TODO: move this to utils and use it
// const response = "HTTP/1.1 200 OK\r\nContent-Length: 13\r\nConnection: close\r\n\r\nHello, World!";
const response = "HTTP/1.1 200 OK\r\nContent-Length: 13\r\nConnection: keep-alive\r\n\r\nHello, World!";

const HandlerContext = struct {
    allocator: std.mem.Allocator,
    req: request.Request,
    client_ctx: *ClientContext,
    socket: xev.TCP,
    bytes_written: usize = 0,
    write_completion: xev.Completion = undefined,

    pub fn init(allocator: std.mem.Allocator, req: request.Request, client_ctx: *ClientContext, socket: xev.TCP) !*HandlerContext {
        const ctx = try allocator.create(HandlerContext);
        ctx.allocator = allocator;
        ctx.req = req;
        ctx.client_ctx = client_ctx;
        ctx.socket = socket;
        ctx.bytes_written = 0;
        return ctx;
    }

    pub fn deinit(self: *HandlerContext) void {
        self.req.deinit();
        self.allocator.destroy(self);
    }
};

fn handleRequest(handler_ctx: *HandlerContext, loop: *xev.Loop) void {}

fn clientReadCallback(ctx_opt: ?*ClientContext, loop: *xev.Loop, _: *xev.Completion, socket: xev.TCP, read_buffer: xev.ReadBuffer, r: xev.ReadError!usize) xev.CallbackAction {
    const ctx = ctx_opt orelse return .disarm;
    const bytes_read = r catch |err| switch (err) {
        xev.ReadError.EOF => {
            log.debug("Client closed the connection, because I asked it do to so probably", .{});
            util.closeSocket(ClientContext, ctx, loop, socket);
            return .disarm;
        },
        else => {
            util.closeSocket(ClientContext, ctx, loop, socket);
            return .disarm;
        },
    };

    // TODO: Maybe handle 0 bytes read as a special case (No maybe don't)
    const request_chunk = read_buffer.slice[0..bytes_read];
    ctx.request_buffer.appendSlice(request_chunk) catch {
        util.closeSocket(ClientContext, ctx, loop, socket);
        return .disarm;
    };

    // Parse request starting from current_request_start for keepalive support
    const current_request_data = ctx.request_buffer.items[ctx.current_request_start..];
    const req = request.parseRequest(ctx.allocator, current_request_data) catch |err| switch (err) {
        request.ParseRequestError.IncompleteRequest => {
            return .rearm;
        },
        else => {
            util.closeSocket(ClientContext, ctx, loop, socket);
            return .disarm;
        },
    };

    // Create handler context and handle the request
    const handler_ctx = HandlerContext.init(ctx.allocator, req, ctx, socket) catch {
        util.closeSocket(ClientContext, ctx, loop, socket);
        return .disarm;
    };

    // Fork happens in the road
    log.debug("Handling request: {s}", .{handler_ctx.req.pathname});

    const write_buffer = response[0..@min(response.len, chunk_size)];
    handler_ctx.socket.write(loop, &handler_ctx.write_completion, .{ .slice = write_buffer }, HandlerContext, handler_ctx, handlerWriteCallback);

    // This is only needed for keepalive connections, so we can read the next request
    return .rearm;
}

// Right now we don't close the connection after the write but wait for the client to close the connection
fn handlerWriteCallback(handler_ctx_opt: ?*HandlerContext, loop: *xev.Loop, _: *xev.Completion, socket: xev.TCP, _: xev.WriteBuffer, r: xev.WriteError!usize) xev.CallbackAction {
    const handler_ctx = handler_ctx_opt orelse return .disarm;
    const bytes_written = r catch {
        handler_ctx.deinit();
        return .disarm;
    };

    handler_ctx.bytes_written += bytes_written;
    if (handler_ctx.bytes_written >= response.len) {
        handler_ctx.deinit();
        return .disarm;
    }
    const from = handler_ctx.bytes_written;
    const to = @min(handler_ctx.bytes_written + chunk_size, response.len);
    const write_buffer = response[from..to];
    socket.write(loop, &handler_ctx.write_completion, .{ .slice = write_buffer }, HandlerContext, handler_ctx, handlerWriteCallback);

    return .disarm;
}
