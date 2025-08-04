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
        };

        // Initialize arena_allocator after arena is in its final location
        ctx.arena_allocator = ctx.arena.allocator();

        // Initialize reader with the properly located arena allocator
        ctx.reader = RequestReader.init(ctx.arena_allocator);

        return ctx;
    }

    pub fn deinit(self: *ClientContext) void {
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

    // For now, send a simple response
    // TODO: Implement actual proxy logic here using parsed headers
    const resp = response.buildSimpleResponse();

    ctx.reader.transitionTo(.processing, ProcessingSubState.response);
    socket.write(loop, &ctx.write_completion, .{ .slice = resp }, ClientContext, ctx, writeCallback);
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