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

fn handleRequest(allocator: std.mem.Allocator, client_connection: net.Server.Connection) !void {
    defer {
        log.debug("Closing client connection", .{});
        client_connection.stream.close();
    }

    // Read headers using the refactored function
    const header_result = headers.read(allocator, client_connection.stream) catch |err| {
        log.err("Failed to read headers: {}", .{err});
        return;
    };
    defer header_result.deinit();

    const raw_request_headers = header_result.headers;
    const body_already_read = header_result.body_overshoot;

    // Parse request headers into a map
    var request_headers = headers.parse(allocator, raw_request_headers) catch |err| {
        log.err("Failed to parse request headers: {}", .{err});
        return;
    };
    defer request_headers.deinit();

    // Parse Content-Length from headers
    const content_length = request_headers.getContentLength();

    // Allocate buffer for complete request
    const total_size = raw_request_headers.len + content_length;
    const request_buffer = try allocator.alloc(u8, total_size);
    defer allocator.free(request_buffer);

    // Copy headers
    @memcpy(request_buffer[0..raw_request_headers.len], raw_request_headers);

    // Copy body data we already read
    @memcpy(request_buffer[raw_request_headers.len .. raw_request_headers.len + body_already_read.len], body_already_read);

    // TODO: Read the rest of the body in chunks instead of all at once, better yet start streaming
    if (content_length > 0) {
        var body_pos = body_already_read.len;
        while (body_pos < content_length) {
            const bytes_read = try client_connection.stream.read(request_buffer[raw_request_headers.len + body_pos ..]);
            if (bytes_read == 0) break;
            body_pos += bytes_read;
        }
    }

    const target_connection = net.tcpConnectToHost(allocator, PROXY_HOST, PROXY_PORT) catch |err| {
        log.err("Failed to connect to target server: {}", .{err});
        const error_response =
            \\HTTP/1.1 502 Bad Gateway
            \\Content-Type: text/plain
            \\Content-Length: 19
            \\Connection: close
            \\
            \\502 Bad Gateway
        ;
        _ = try client_connection.stream.writeAll(error_response);
        return;
    };
    defer target_connection.close();

    _ = try target_connection.writeAll(request_buffer);

    // Read response headers first
    const response_header_result = headers.read(allocator, target_connection) catch |err| {
        log.err("Failed to read response headers: {}", .{err});
        return;
    };
    defer response_header_result.deinit();

    // Forward response headers to client
    _ = try client_connection.stream.writeAll(response_header_result.headers);

    // Forward any response body we already read
    if (response_header_result.body_overshoot.len > 0) {
        _ = try client_connection.stream.writeAll(response_header_result.body_overshoot);
    }

    // Parse response headers into a map
    var response_headers = headers.parse(allocator, response_header_result.headers) catch |err| {
        log.err("Failed to parse response headers: {}", .{err});
        return;
    };
    defer response_headers.deinit();

    // Parse response to determine how to handle body
    const response_content_length = response_headers.getContentLength();

    // Handle response body based on Content-Length
    if (response_content_length > 0) {
        // Read exactly content_length bytes
        var remaining = response_content_length - response_header_result.body_overshoot.len;
        var response_buffer: [8192]u8 = undefined;
        while (remaining > 0) {
            // TODO: Chunked reading
            const to_read = @min(remaining, response_buffer.len);
            const response_bytes = target_connection.read(response_buffer[0..to_read]) catch 0;
            if (response_bytes == 0) break;
            _ = try client_connection.stream.writeAll(response_buffer[0..response_bytes]);
            remaining -= response_bytes;
        }
        log.info("Response body forwarded ({} bytes)", .{response_content_length});
    } else {
        // No content-length, read until connection closes
        log.debug("No content-length, reading until close", .{});
        var response_buffer: [8192]u8 = undefined;
        while (true) {
            const response_bytes = target_connection.read(&response_buffer) catch 0;
            if (response_bytes == 0) break;
            _ = try client_connection.stream.writeAll(response_buffer[0..response_bytes]);
        }
    }
}

const AcceptContext = struct {
    allocator: std.mem.Allocator,
};

const ClientContext = struct {
    client: xev.TCP,
    read_completion: xev.Completion,
    write_completion: xev.Completion,
    shutdown_completion: xev.Completion,
    close_completion: xev.Completion,
    request_buffer: [4096]u8,
    allocator: std.mem.Allocator,

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
        };
        return ctx;
    }

    fn deinit(self: *ClientContext) void {
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

    // Log the request (first line only)
    const request_data = ctx.request_buffer[0..bytes_read];
    if (std.mem.indexOf(u8, request_data, "\r\n")) |end| {
        log.debug("HTTP Request: {s}", .{request_data[0..end]});
    } else {
        log.debug("HTTP Request (no CRLF found): {s}", .{request_data[0..@min(100, bytes_read)]});
    }

    // Send a proper HTTP/1.1 response with correct Content-Length
    const body = "Hello from libxev proxy!";
    // body.len = 24, which matches our Content-Length header
    const response =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 24\r\n" ++
        "Connection: close\r\n" ++
        "Server: libxev-proxy/1.0\r\n" ++
        "\r\n" ++
        body;

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
