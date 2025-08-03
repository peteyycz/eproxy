const std = @import("std");
const net = std.net;
const log = std.log;
const headers = @import("headers.zig");
const build_options = @import("build_options");
const xev = @import("xev");

pub const std_options: std.Options = .{
    .log_level = @enumFromInt(@intFromEnum(build_options.log_level)),
};

const PROXY_HOST = "localhost";
const PROXY_PORT = 9000;
const LISTEN_PORT = 8080;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize thread pool and event loop
    var thread_pool = xev.ThreadPool.init(.{ .max_threads = 4 });
    defer thread_pool.deinit();

    var loop = try xev.Loop.init(.{
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();

    // Bind to address
    const addr = try std.net.Address.parseIp("127.0.0.1", LISTEN_PORT);

    // Create libxev TCP server with address
    var server = try xev.TCP.init(addr);
    try server.bind(addr);
    try server.listen(128); // backlog

    log.info("Reverse proxy listening on http://127.0.0.1:{}", .{LISTEN_PORT});
    log.info("Proxying requests to {s}:{}", .{ PROXY_HOST, PROXY_PORT });
    log.info("Server socket bound and listening, starting accept...", .{});

    // Start accepting connections asynchronously
    var accept_ctx = AcceptContext{ .allocator = allocator };
    var accept_completion: xev.Completion = undefined;
    server.accept(&loop, &accept_completion, AcceptContext, &accept_ctx, acceptCallback);

    // Run event loop
    log.info("Starting event loop...", .{});
    try loop.run(.until_done);
    log.info("Event loop exited", .{});
}

const ReadingState = enum {
    reading_headers,
    reading_body,
    processing_complete,
};

const AcceptContext = struct {
    allocator: std.mem.Allocator,
};

const CHUNK_SIZE = 10;

const ClientContext = struct {
    client: xev.TCP,
    read_completion: xev.Completion,
    write_completion: xev.Completion,
    shutdown_completion: xev.Completion,
    close_completion: xev.Completion,
    request_buffer: [CHUNK_SIZE]u8,
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    arena_allocator: std.mem.Allocator,

    // State machine fields
    reading_state: ReadingState,
    headers_buffer: std.ArrayList(u8),
    body_bytes_remaining: usize,
    parsed_headers: ?headers.Headers,

    fn init(allocator: std.mem.Allocator, client: xev.TCP) !*ClientContext {
        const ctx = try allocator.create(ClientContext);
        ctx.* = ClientContext{
            .client = client,
            .read_completion = undefined,
            .write_completion = undefined,
            .shutdown_completion = undefined,
            .close_completion = undefined,
            .request_buffer = undefined,
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .arena_allocator = undefined,
            .reading_state = .reading_headers,
            .headers_buffer = undefined,
            .body_bytes_remaining = 0,
            .parsed_headers = null,
        };

        // Initialize arena_allocator after arena is in its final location
        ctx.arena_allocator = ctx.arena.allocator();

        // Initialize headers_buffer with the properly located arena allocator
        ctx.headers_buffer = std.ArrayList(u8).init(ctx.arena_allocator);

        return ctx;
    }

    fn deinit(self: *ClientContext) void {
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

fn acceptCallback(
    userdata: ?*AcceptContext,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.AcceptError!xev.TCP,
) xev.CallbackAction {
    _ = completion;

    const accept_ctx = userdata orelse {
        log.err("Missing accept context", .{});
        return .rearm;
    };

    const client = result catch |err| {
        log.err("Failed to accept connection: {}", .{err});
        return .rearm; // Continue accepting
    };

    log.debug("Accepted connection", .{});

    // Create context to keep completions alive
    const ctx = ClientContext.init(accept_ctx.allocator, client) catch |err| {
        log.err("Failed to allocate client context: {}", .{err});
        return .rearm;
    };

    // First, read the HTTP request
    log.debug("Reading HTTP request...", .{});
    // TODO: Use chunked reading for large requests
    client.read(loop, &ctx.read_completion, .{ .slice = &ctx.request_buffer }, ClientContext, ctx, readCallback);

    return .rearm; // Continue accepting more connections
}

fn readCallback(
    ctx_opt: ?*ClientContext,
    loop: *xev.Loop,
    completion: *xev.Completion,
    socket: xev.TCP,
    buffer: xev.ReadBuffer,
    result: xev.ReadError!usize,
) xev.CallbackAction {
    _ = completion;
    _ = buffer;

    const ctx = ctx_opt orelse {
        log.err("Missing client context in read callback", .{});
        return .disarm;
    };

    const bytes_read = result catch |err| {
        log.err("Failed to read from client: {}", .{err});
        socket.close(loop, &ctx.close_completion, ClientContext, ctx, clientCloseCallback);
        return .disarm;
    };

    log.debug("Read {} bytes from client", .{bytes_read});

    // Check if client closed connection (0 bytes = EOF)
    if (bytes_read == 0) {
        log.debug("Client closed connection (0 bytes read)", .{});
        socket.close(loop, &ctx.close_completion, ClientContext, ctx, clientCloseCallback);
        return .disarm;
    }

    // State machine for handling chunked request reading
    const request_data = ctx.request_buffer[0..bytes_read];

    switch (ctx.reading_state) {
        .reading_headers => return handleHeadersReading(ctx, loop, socket, request_data),
        .reading_body => return handleBodyReading(ctx, loop, socket, request_data, bytes_read),
        .processing_complete => return handleProcessingComplete(ctx, loop, socket),
    }

    return .disarm;
}

fn closeWithError(ctx: *ClientContext, loop: *xev.Loop, socket: xev.TCP, comptime fmt: []const u8, args: anytype) xev.CallbackAction {
    log.err(fmt, args);
    socket.close(loop, &ctx.close_completion, ClientContext, ctx, clientCloseCallback);
    return .disarm;
}

fn handleHeadersReading(ctx: *ClientContext, loop: *xev.Loop, socket: xev.TCP, request_data: []const u8) xev.CallbackAction {
    // Append data to headers buffer
    ctx.headers_buffer.appendSlice(request_data) catch |err| {
        return closeWithError(ctx, loop, socket, "Failed to append to headers buffer: {}", .{err});
    };

    // Look for end of headers (\r\n\r\n)
    if (std.mem.indexOf(u8, ctx.headers_buffer.items, "\r\n\r\n")) |headers_end| {
        log.debug("Headers complete, parsing...", .{});

        // Parse and store headers
        const headers_text = ctx.headers_buffer.items[0 .. headers_end + 4];
        ctx.parsed_headers = headers.parse(ctx.arena_allocator, headers_text) catch |err| {
            return closeWithError(ctx, loop, socket, "Failed to parse headers: {}", .{err});
        };

        const content_length = ctx.parsed_headers.?.getContentLength();
        ctx.body_bytes_remaining = content_length;

        log.debug("Content-Length: {}", .{content_length});

        if (content_length == 0) {
            // No body, process request immediately
            ctx.reading_state = .processing_complete;
            return processRequest(ctx, loop, socket);
        } else {
            // Has body, transition to reading body
            ctx.reading_state = .reading_body;

            // Check if we already have some body data after headers
            const body_start = headers_end + 4;
            if (ctx.headers_buffer.items.len > body_start) {
                const body_data = ctx.headers_buffer.items[body_start..];
                ctx.body_bytes_remaining -= body_data.len;
                log.debug("Already have {} body bytes, remaining: {}", .{ body_data.len, ctx.body_bytes_remaining });

                if (ctx.body_bytes_remaining == 0) {
                    // Complete request received
                    ctx.reading_state = .processing_complete;
                    return processRequest(ctx, loop, socket);
                }
            }
        }
    }

    // Continue reading
    socket.read(loop, &ctx.read_completion, .{ .slice = &ctx.request_buffer }, ClientContext, ctx, readCallback);
    return .disarm;
}

fn handleBodyReading(ctx: *ClientContext, loop: *xev.Loop, socket: xev.TCP, request_data: []const u8, bytes_read: usize) xev.CallbackAction {
    // Append body data
    ctx.headers_buffer.appendSlice(request_data) catch |err| {
        return closeWithError(ctx, loop, socket, "Failed to append body data: {}", .{err});
    };

    ctx.body_bytes_remaining -= bytes_read;
    log.debug("Body bytes remaining: {}", .{ctx.body_bytes_remaining});

    if (ctx.body_bytes_remaining == 0) {
        // Complete request received
        ctx.reading_state = .processing_complete;
        return processRequest(ctx, loop, socket);
    }

    // Continue reading body
    socket.read(loop, &ctx.read_completion, .{ .slice = &ctx.request_buffer }, ClientContext, ctx, readCallback);
    return .disarm;
}

fn handleProcessingComplete(ctx: *ClientContext, loop: *xev.Loop, socket: xev.TCP) xev.CallbackAction {
    // Should not reach here in normal flow
    return closeWithError(ctx, loop, socket, "Unexpected read in processing_complete state", .{});
}

fn buildSimpleResponse() []const u8 {
    const body = "Hello from chunked proxy!";
    return "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 25\r\n" ++
        "Connection: close\r\n" ++
        "Server: libxev-proxy/1.0\r\n" ++
        "\r\n" ++
        body;
}

fn processRequest(ctx: *ClientContext, loop: *xev.Loop, socket: xev.TCP) xev.CallbackAction {
    log.debug("Processing complete request ({} total bytes)", .{ctx.headers_buffer.items.len});

    if (ctx.parsed_headers) |parsed| {
        log.debug("Host: {s}", .{parsed.getHost() orelse "unknown"});
        log.debug("User-Agent: {s}", .{parsed.getUserAgent() orelse "unknown"});
        log.debug("Content-Type: {s}", .{parsed.getContentType() orelse "none"});
        log.debug("Content-Length: {}", .{parsed.getContentLength()});
    }

    // For now, send a simple response
    // TODO: Implement actual proxy logic here using parsed headers
    const response = buildSimpleResponse();

    socket.write(loop, &ctx.write_completion, .{ .slice = response }, ClientContext, ctx, writeCallback);
    return .disarm;
}

fn writeCallback(
    ctx_opt: ?*ClientContext,
    loop: *xev.Loop,
    completion: *xev.Completion,
    socket: xev.TCP,
    buffer: xev.WriteBuffer,
    result: xev.WriteError!usize,
) xev.CallbackAction {
    _ = completion;
    _ = buffer;

    const ctx = ctx_opt orelse {
        log.err("Missing client context in write callback", .{});
        return .disarm;
    };

    const bytes_written = result catch |err| {
        log.err("Failed to write to client: {}", .{err});
        socket.close(loop, &ctx.close_completion, ClientContext, ctx, clientCloseCallback);
        return .disarm;
    };

    log.debug("Wrote {} bytes to client", .{bytes_written});

    // Shutdown write side to signal end of response
    log.debug("Shutting down write side", .{});
    socket.shutdown(loop, &ctx.shutdown_completion, ClientContext, ctx, shutdownCallback);

    return .disarm;
}

fn shutdownCallback(
    ctx_opt: ?*ClientContext,
    loop: *xev.Loop,
    completion: *xev.Completion,
    socket: xev.TCP,
    result: xev.ShutdownError!void,
) xev.CallbackAction {
    _ = completion;

    const ctx = ctx_opt orelse {
        log.err("Missing client context in shutdown callback", .{});
        return .disarm;
    };

    result catch |err| {
        log.err("Failed to shutdown client: {}", .{err});
        // Still proceed to close
    };

    log.debug("Write side shutdown complete, closing socket", .{});

    // Now close the socket
    socket.close(loop, &ctx.close_completion, ClientContext, ctx, clientCloseCallback);

    return .disarm;
}

fn clientCloseCallback(
    ctx_opt: ?*ClientContext,
    loop: *xev.Loop,
    completion: *xev.Completion,
    socket: xev.TCP,
    result: xev.CloseError!void,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    _ = socket;

    const ctx = ctx_opt orelse {
        log.err("Missing client context in close callback", .{});
        return .disarm;
    };

    result catch |err| {
        log.err("Failed to close client: {}", .{err});
    };

    log.debug("Client connection closed", .{});

    // Clean up the context
    ctx.deinit();

    return .disarm;
}
