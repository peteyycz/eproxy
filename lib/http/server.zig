const std = @import("std");
const xev = @import("xev");
const log = std.log;
const util = @import("util.zig");

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

const read_buffer_size = 10;

const ClientContext = struct {
    allocator: std.mem.Allocator,
    loop: *xev.Loop,

    read_buffer: [read_buffer_size]u8 = undefined,
    request_buffer: std.ArrayList(u8),

    read_completion: xev.Completion = undefined,
    write_completion: xev.Completion = undefined,
    shutdown_completion: xev.Completion = undefined,
    close_completion: xev.Completion = undefined,

    pub fn init(allocator: std.mem.Allocator, loop: *xev.Loop) !*ClientContext {
        const ctx = try allocator.create(ClientContext);
        ctx.request_buffer = std.ArrayList(u8).init(allocator);
        ctx.allocator = allocator;
        ctx.loop = loop;
        return ctx;
    }

    pub fn deinit(self: *ClientContext) void {
        self.request_buffer.deinit();
        self.allocator.destroy(self);
    }
};

const response = "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello, World!";

fn clientReadCallback(ctx_opt: ?*ClientContext, loop: *xev.Loop, _: *xev.Completion, socket: xev.TCP, read_buffer: xev.ReadBuffer, r: xev.ReadError!usize) xev.CallbackAction {
    const ctx = ctx_opt orelse return .disarm;
    const bytes_read = r catch |err| {
        // EOF indicates the client has closed the connection
        if (err == xev.ReadError.EOF) {
            log.info("End of stream reached {s}", .{ctx.request_buffer.items});
            // Handle the request here, e.g., parse HTTP request, pass to a handler, etc.
            util.shutdownSocket(ClientContext, ctx, loop, socket);
        } else {
            util.closeSocket(ClientContext, ctx, loop, socket);
        }
        return .disarm;
    };

    // TODO: Maybe handle 0 bytes read as a special case
    const request_chunk = read_buffer.slice[0..bytes_read];
    ctx.request_buffer.appendSlice(request_chunk) catch {
        util.closeSocket(ClientContext, ctx, loop, socket);
        return .disarm;
    };

    // Somehow we need to figure out when the request is complete, fuck that
    socket.write(loop, &ctx.write_completion, .{ .slice = response }, ClientContext, ctx, clientWriteCallback);

    return .disarm;
    // Chunked reading should be better tho
    // return .rearm;
}

fn clientWriteCallback(ctx_opt: ?*ClientContext, loop: *xev.Loop, _: *xev.Completion, socket: xev.TCP, _: xev.WriteBuffer, r: xev.WriteError!usize) xev.CallbackAction {
    const ctx = ctx_opt orelse return .disarm;
    _ = r catch {
        util.closeSocket(ClientContext, ctx, loop, socket);
        return .disarm;
    };

    // Close the connection after sending the response
    // TODO: Send data in chunks with using .rearm and keep track of the writing state
    util.closeSocket(ClientContext, ctx, loop, socket);
    return .disarm;
}
