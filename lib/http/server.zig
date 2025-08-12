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

pub fn createServer(allocator: std.mem.Allocator, loop: *xev.Loop) !void {
    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8080);
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

    bytes_written: usize = 0,

    read_completion: xev.Completion = undefined,
    write_completion: xev.Completion = undefined,
    shutdown_completion: xev.Completion = undefined,
    close_completion: xev.Completion = undefined,

    pub fn init(allocator: std.mem.Allocator, loop: *xev.Loop) !*ClientContext {
        const ctx = try allocator.create(ClientContext);
        ctx.request_buffer = std.ArrayList(u8).init(allocator);
        ctx.allocator = allocator;
        ctx.loop = loop;
        ctx.bytes_written = 0;
        return ctx;
    }

    pub fn deinit(self: *ClientContext) void {
        self.request_buffer.deinit();
        self.allocator.destroy(self);
    }
};

// TODO: move this to utils and use it
const response = "HTTP/1.1 200 OK\r\nContent-Length: 13\r\nConnection: close\n\r\nHello, World!";
// const response = "HTTP/1.1 200 OK\r\nContent-Length: 13\r\nConnection: keep-alive\n\r\nHello, World!";

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

    // TODO: In a keepalive connection the buffer can grow indefinitely, so we should keep track of only the last
    // request
    var req = request.parseRequest(ctx.allocator, ctx.request_buffer.items) catch |err| switch (err) {
        .ParseRequestError.IncompleteRequest => {
            return .rearm;
        },
        else => {
            util.closeSocket(ClientContext, ctx, loop, socket);
            return .disarm;
        },
    };
    defer req.deinit();
    log.debug("Received request: {s}", .{req.pathname});

    const write_buffer = response[0..@min(response.len, chunk_size)];
    socket.write(loop, &ctx.write_completion, .{ .slice = write_buffer }, ClientContext, ctx, clientWriteCallback);

    // This is only needed for keepalive connections, so we can read the next request
    return .rearm;
}

// Right now we don't close the connection after the write but wait for the client to close the connection
fn clientWriteCallback(ctx_opt: ?*ClientContext, loop: *xev.Loop, _: *xev.Completion, socket: xev.TCP, _: xev.WriteBuffer, r: xev.WriteError!usize) xev.CallbackAction {
    const ctx = ctx_opt orelse return .disarm;
    const bytes_written = r catch {
        return .disarm;
    };

    ctx.bytes_written += bytes_written;
    if (ctx.bytes_written >= response.len) {
        return .disarm;
    }
    const from = ctx.bytes_written;
    const to = @min(ctx.bytes_written + chunk_size, response.len);
    const write_buffer = response[from..to];
    socket.write(loop, &ctx.write_completion, .{ .slice = write_buffer }, ClientContext, ctx, clientWriteCallback);

    return .disarm;
}
