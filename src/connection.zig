const std = @import("std");
const log = std.log;
const xev = @import("xev");
const headers = @import("headers.zig");
const request_reader = @import("request_reader.zig");
const response = @import("response.zig");

const RequestReader = request_reader.RequestReader;
const RequestState = request_reader.RequestState;
const ReadingSubState = request_reader.ReadingSubState;
const ProcessingSubState = request_reader.ProcessingSubState;
const TerminalSubState = request_reader.TerminalSubState;

pub const CHUNK_SIZE = 4096;

// Backend configuration
const BACKEND_HOST = "127.0.0.1";
const BACKEND_PORT = 9000;

pub const ClientContext = struct {
    client: xev.TCP,
    read_completion: xev.Completion,
    write_completion: xev.Completion,
    shutdown_completion: xev.Completion,
    close_completion: xev.Completion,
    request_buffer: [CHUNK_SIZE]u8,
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    arena_allocator: std.mem.Allocator,

    // Request reading state machine
    reader: RequestReader,

    // Backend connection state
    backend: ?xev.TCP,
    backend_connect_completion: xev.Completion,
    backend_read_completion: xev.Completion,
    backend_write_completion: xev.Completion,
    backend_close_completion: xev.Completion,
    backend_buffer: [CHUNK_SIZE]u8,

    pub fn init(allocator: std.mem.Allocator, client: xev.TCP) !*ClientContext {
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
            .reader = undefined,

            .backend = null,
            .backend_connect_completion = undefined,
            .backend_read_completion = undefined,
            .backend_write_completion = undefined,
            .backend_close_completion = undefined,
            .backend_buffer = undefined,
        };

        // Initialize arena_allocator after arena is in its final location
        ctx.arena_allocator = ctx.arena.allocator();

        // Initialize reader with the properly located arena allocator
        ctx.reader = RequestReader.init(ctx.arena_allocator);

        return ctx;
    }

    pub fn deinit(self: *ClientContext) void {
        // Close backend connection if open
        if (self.backend) |_| {
            // Note: backend socket should already be closed by cleanup logic
        }
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

pub fn closeWithError(ctx: *ClientContext, loop: *xev.Loop, socket: xev.TCP, comptime fmt: []const u8, args: anytype) xev.CallbackAction {
    log.err(fmt, args);
    socket.close(loop, &ctx.close_completion, ClientContext, ctx, clientCloseCallback);
    return .disarm;
}

pub fn readCallback(
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

    // Hierarchical state machine dispatch
    switch (ctx.reader.state) {
        .reading => {
            switch (ctx.reader.reading_substate.?) {
                .headers => return handleHeadersReading(ctx, loop, socket, request_data),
                .body => return handleBodyReading(ctx, loop, socket, request_data, bytes_read),
            }
        },
        .processing => {
            switch (ctx.reader.processing_substate.?) {
                .request => return handleRequestProcessing(ctx, loop, socket),
                .response => return handleResponseProcessing(ctx, loop, socket),
            }
        },
        .terminal => {
            switch (ctx.reader.terminal_substate.?) {
                .completed => return handleCompleted(ctx, loop, socket),
                .failed => return handleFailed(ctx, loop, socket),
            }
        },
    }

    // Should not reach here
    return .disarm;
}

fn handleHeadersReading(ctx: *ClientContext, loop: *xev.Loop, socket: xev.TCP, request_data: []const u8) xev.CallbackAction {
    // Append data to headers buffer
    ctx.reader.headers_buffer.appendSlice(request_data) catch |err| {
        return closeWithError(ctx, loop, socket, "Failed to append to headers buffer: {}", .{err});
    };

    // Look for end of headers (\r\n\r\n)
    if (std.mem.indexOf(u8, ctx.reader.headers_buffer.items, "\r\n\r\n")) |headers_end| {
        log.debug("Headers complete, parsing...", .{});

        // Parse and store headers
        const headers_text = ctx.reader.headers_buffer.items[0 .. headers_end + 4];
        ctx.reader.parsed_headers = headers.parse(ctx.arena_allocator, headers_text) catch |err| {
            return closeWithError(ctx, loop, socket, "Failed to parse headers: {}", .{err});
        };

        const content_length = if (ctx.reader.parsed_headers) |parsed|
            parsed.getContentLength()
        else {
            return closeWithError(ctx, loop, socket, "Headers parsing failed - no parsed headers available", .{});
        };

        ctx.reader.body_bytes_remaining = content_length;

        log.debug("Content-Length: {}", .{content_length});

        if (content_length == 0) {
            // No body, process request immediately
            ctx.reader.transitionTo(.processing, ProcessingSubState.request);
            return handleRequestProcessing(ctx, loop, socket);
        } else {
            // Has body, transition to reading body
            ctx.reader.transitionTo(.reading, ReadingSubState.body);

            // Check if we already have some body data after headers
            const body_start = headers_end + 4;
            if (ctx.reader.headers_buffer.items.len > body_start) {
                const body_data = ctx.reader.headers_buffer.items[body_start..];
                ctx.reader.body_bytes_remaining -= body_data.len;
                log.debug("Already have {} body bytes, remaining: {}", .{ body_data.len, ctx.reader.body_bytes_remaining });

                if (ctx.reader.body_bytes_remaining == 0) {
                    // Complete request received
                    ctx.reader.transitionTo(.processing, ProcessingSubState.request);
                    return handleRequestProcessing(ctx, loop, socket);
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
    ctx.reader.headers_buffer.appendSlice(request_data) catch |err| {
        return closeWithError(ctx, loop, socket, "Failed to append body data: {}", .{err});
    };

    ctx.reader.body_bytes_remaining -= bytes_read;
    log.debug("Body bytes remaining: {}", .{ctx.reader.body_bytes_remaining});

    if (ctx.reader.body_bytes_remaining == 0) {
        // Complete request received
        ctx.reader.transitionTo(.processing, ProcessingSubState.request);
        return handleRequestProcessing(ctx, loop, socket);
    }

    // Continue reading body
    socket.read(loop, &ctx.read_completion, .{ .slice = &ctx.request_buffer }, ClientContext, ctx, readCallback);
    return .disarm;
}

fn handleRequestProcessing(ctx: *ClientContext, loop: *xev.Loop, socket: xev.TCP) xev.CallbackAction {
    log.debug("Processing complete request ({} total bytes)", .{ctx.reader.headers_buffer.items.len});

    if (ctx.reader.parsed_headers) |parsed| {
        log.debug("Host: {s}", .{parsed.getHost() orelse "unknown"});
        log.debug("User-Agent: {s}", .{parsed.getUserAgent() orelse "unknown"});
        log.debug("Content-Type: {s}", .{parsed.getContentType() orelse "none"});
        log.debug("Content-Length: {}", .{parsed.getContentLength()});
    }

    // Connect to backend server
    const backend_addr = std.net.Address.parseIp(BACKEND_HOST, BACKEND_PORT) catch |err| {
        log.err("Failed to parse backend address: {}", .{err});
        const resp = response.buildErrorResponse(502);
        socket.write(loop, &ctx.write_completion, .{ .slice = resp }, ClientContext, ctx, writeCallback);
        return .disarm;
    };

    const backend_socket = xev.TCP.init(backend_addr) catch |err| {
        log.err("Failed to create backend TCP socket: {}", .{err});
        const resp = response.buildErrorResponse(502);
        socket.write(loop, &ctx.write_completion, .{ .slice = resp }, ClientContext, ctx, writeCallback);
        return .disarm;
    };

    ctx.backend = backend_socket;

    log.debug("Connecting to backend server...", .{});
    backend_socket.connect(loop, &ctx.backend_connect_completion, backend_addr, ClientContext, ctx, backendConnectCallback);
    return .disarm;
}

fn handleResponseProcessing(ctx: *ClientContext, loop: *xev.Loop, socket: xev.TCP) xev.CallbackAction {
    // Should not reach here in normal flow during reading
    return closeWithError(ctx, loop, socket, "Unexpected read during response processing", .{});
}

fn handleCompleted(ctx: *ClientContext, loop: *xev.Loop, socket: xev.TCP) xev.CallbackAction {
    return closeWithError(ctx, loop, socket, "Unexpected read in completed state", .{});
}

fn handleFailed(ctx: *ClientContext, loop: *xev.Loop, socket: xev.TCP) xev.CallbackAction {
    return closeWithError(ctx, loop, socket, "Connection in failed state", .{});
}

pub fn writeCallback(
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

    // Transition to completed state
    ctx.reader.transitionTo(.terminal, TerminalSubState.completed);

    // Shutdown write side to signal end of response
    log.debug("Shutting down write side", .{});
    socket.shutdown(loop, &ctx.shutdown_completion, ClientContext, ctx, shutdownCallback);

    return .disarm;
}

pub fn shutdownCallback(
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

pub fn clientCloseCallback(
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

pub fn backendConnectCallback(
    ctx_opt: ?*ClientContext,
    loop: *xev.Loop,
    completion: *xev.Completion,
    socket: xev.TCP,
    result: xev.ConnectError!void,
) xev.CallbackAction {
    _ = completion;

    const ctx = ctx_opt orelse {
        log.err("Missing client context in backend connect callback", .{});
        return .disarm;
    };

    result catch |err| {
        log.err("Failed to connect to backend: {}", .{err});
        const resp = response.buildErrorResponse(502);
        ctx.client.write(loop, &ctx.write_completion, .{ .slice = resp }, ClientContext, ctx, writeCallback);
        return .disarm;
    };

    log.debug("Connected to backend server, forwarding request...", .{});

    // Forward the complete HTTP request to backend
    const request_data = ctx.reader.headers_buffer.items;
    socket.write(loop, &ctx.backend_write_completion, .{ .slice = request_data }, ClientContext, ctx, backendWriteCallback);

    return .disarm;
}

pub fn backendWriteCallback(
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
        log.err("Missing client context in backend write callback", .{});
        return .disarm;
    };

    const bytes_written = result catch |err| {
        log.err("Failed to write to backend: {}", .{err});
        const resp = response.buildErrorResponse(502);
        ctx.client.write(loop, &ctx.write_completion, .{ .slice = resp }, ClientContext, ctx, writeCallback);
        return .disarm;
    };

    log.debug("Wrote {} bytes to backend, reading response...", .{bytes_written});

    // Start reading response from backend
    socket.read(loop, &ctx.backend_read_completion, .{ .slice = &ctx.backend_buffer }, ClientContext, ctx, backendReadCallback);

    return .disarm;
}

pub fn backendReadCallback(
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
        log.err("Missing client context in backend read callback", .{});
        return .disarm;
    };

    const bytes_read = result catch |err| {
        log.err("Failed to read from backend: {}", .{err});
        const resp = response.buildErrorResponse(502);
        ctx.client.write(loop, &ctx.write_completion, .{ .slice = resp }, ClientContext, ctx, writeCallback);
        return .disarm;
    };

    if (bytes_read == 0) {
        log.debug("Backend closed connection (0 bytes read)", .{});
        // Close backend connection
        socket.close(loop, &ctx.backend_close_completion, ClientContext, ctx, backendCloseCallback);
        return .disarm;
    }

    log.debug("Read {} bytes from backend, forwarding to client...", .{bytes_read});

    // Forward response chunk to client
    const response_data = ctx.backend_buffer[0..bytes_read];
    ctx.client.write(loop, &ctx.write_completion, .{ .slice = response_data }, ClientContext, ctx, clientForwardCallback);

    return .disarm;
}

pub fn clientForwardCallback(
    ctx_opt: ?*ClientContext,
    loop: *xev.Loop,
    completion: *xev.Completion,
    socket: xev.TCP,
    buffer: xev.WriteBuffer,
    result: xev.WriteError!usize,
) xev.CallbackAction {
    _ = completion;
    _ = buffer;
    _ = socket;

    const ctx = ctx_opt orelse {
        log.err("Missing client context in client forward callback", .{});
        return .disarm;
    };

    const bytes_written = result catch |err| {
        log.err("Failed to write to client: {}", .{err});
        // Close both connections
        if (ctx.backend) |backend_socket| {
            backend_socket.close(loop, &ctx.backend_close_completion, ClientContext, ctx, backendCloseCallback);
        }
        ctx.client.close(loop, &ctx.close_completion, ClientContext, ctx, clientCloseCallback);
        return .disarm;
    };

    log.debug("Forwarded {} bytes to client, continue reading from backend...", .{bytes_written});

    // Continue reading from backend
    if (ctx.backend) |backend_socket| {
        backend_socket.read(loop, &ctx.backend_read_completion, .{ .slice = &ctx.backend_buffer }, ClientContext, ctx, backendReadCallback);
    }

    return .disarm;
}

pub fn backendCloseCallback(
    ctx_opt: ?*ClientContext,
    loop: *xev.Loop,
    completion: *xev.Completion,
    socket: xev.TCP,
    result: xev.CloseError!void,
) xev.CallbackAction {
    _ = completion;
    _ = socket;

    const ctx = ctx_opt orelse {
        log.err("Missing client context in backend close callback", .{});
        return .disarm;
    };

    result catch |err| {
        log.err("Failed to close backend: {}", .{err});
    };

    log.debug("Backend connection closed", .{});
    ctx.backend = null;

    // Close client connection as well
    ctx.client.close(loop, &ctx.close_completion, ClientContext, ctx, clientCloseCallback);

    return .disarm;
}
