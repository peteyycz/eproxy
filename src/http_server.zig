const std = @import("std");
const xev = @import("xev");
const HttpMethod = @import("http/method.zig").HttpMethod;
const HttpResponse = @import("http/response.zig").HttpResponse;
const HttpRequest = @import("http/request.zig").HttpRequest;
const log = std.log;

const crlf = "\r\n";
const headers_end_marker = crlf ++ crlf;

// Forward declarations to break dependency loops
const ConnectionContext = struct {
    socket: xev.TCP,
    server: *Server,
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    arena_allocator: std.mem.Allocator,
    loop: *xev.Loop,

    // I/O state
    read_completion: xev.Completion,
    write_completion: xev.Completion,
    close_completion: xev.Completion,

    // Request parsing state
    request_buffer: std.ArrayList(u8),
    headers_complete: bool,
    content_length: usize,
    bytes_read: usize,

    // Response state for async handling
    response_sent: bool,

    pub fn init(allocator: std.mem.Allocator, socket: xev.TCP, server: *Server, loop: *xev.Loop) !*ConnectionContext {
        const ctx = try allocator.create(ConnectionContext);
        ctx.* = ConnectionContext{
            .socket = socket,
            .server = server,
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .arena_allocator = undefined,
            .loop = loop,
            .read_completion = undefined,
            .write_completion = undefined,
            .close_completion = undefined,
            .request_buffer = std.ArrayList(u8).init(allocator),
            .headers_complete = false,
            .content_length = 0,
            .bytes_read = 0,
            .response_sent = false,
        };

        ctx.arena_allocator = ctx.arena.allocator();
        return ctx;
    }

    pub fn deinit(self: *ConnectionContext) void {
        self.request_buffer.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

// Async response context - holds everything needed to send a response later
pub const AsyncResponseContext = struct {
    ctx: *ConnectionContext,
    loop: *xev.Loop,
    socket: xev.TCP,

    pub fn respond(self: *AsyncResponseContext, status_code: u16, body: []const u8) void {
        // Prevent double responses
        if (self.ctx.response_sent) {
            log.warn("Attempt to send response twice - ignoring", .{});
            // Clean up self before returning
            self.ctx.allocator.destroy(self);
            return;
        }
        self.ctx.response_sent = true;

        var response = HttpResponse.init(self.ctx.arena_allocator, status_code, body) catch {
            log.err("Failed to create async response", .{});
            // Clean up self before returning
            self.ctx.allocator.destroy(self);
            return;
        };
        defer response.deinit();

        // Inline response sending to avoid function scope issues
        const response_bytes = response.toBytes(self.ctx.arena_allocator) catch |err| {
            log.err("Failed to serialize response: {any}", .{err});
            // Clean up self before returning
            self.ctx.allocator.destroy(self);
            return;
        };

        // Clean up self after initiating the write (the write callback will handle connection cleanup)
        defer self.ctx.allocator.destroy(self);

        self.socket.write(self.loop, &self.ctx.write_completion, .{ .slice = response_bytes }, ConnectionContext, self.ctx, Server.writeCallback);
    }
};

// Async handler callback type - use anyopaque to break circular dependency
pub const AsyncHandlerCallback = *const fn (request: HttpRequest, response_ctx: *anyopaque) void;

pub const Server = struct {
    loop: *xev.Loop,
    allocator: std.mem.Allocator,
    handler: AsyncHandlerCallback,
    tcp_server: ?xev.TCP,
    accept_completion: xev.Completion,

    pub fn init(allocator: std.mem.Allocator, loop: *xev.Loop, handler: AsyncHandlerCallback) Server {
        return Server{
            .loop = loop,
            .allocator = allocator,
            .handler = handler,
            .tcp_server = null,
            .accept_completion = undefined,
        };
    }

    pub fn listen(self: *Server, port: u16) !void {
        const addr = try std.net.Address.parseIp("127.0.0.1", port);
        self.tcp_server = try xev.TCP.init(addr);
        try self.tcp_server.?.bind(addr);
        try self.tcp_server.?.listen(128);

        log.info("HTTP server listening on 127.0.0.1:{d}", .{port});

        // Start accepting connections
        self.tcp_server.?.accept(self.loop, &self.accept_completion, Server, self, acceptCallback);
    }

    fn acceptCallback(
        server_opt: ?*Server,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.AcceptError!xev.TCP,
    ) xev.CallbackAction {
        _ = completion;

        const server = server_opt orelse {
            log.err("Server context is null in accept callback", .{});
            return .disarm;
        };

        const client_socket = result catch |err| {
            log.err("Failed to accept connection: {any}", .{err});
            // Continue accepting
            server.tcp_server.?.accept(loop, &server.accept_completion, Server, server, acceptCallback);
            return .disarm;
        };

        log.debug("New client connection accepted", .{});

        // Create connection context
        const conn_ctx = ConnectionContext.init(server.allocator, client_socket, server, loop) catch |err| {
            log.err("Failed to create connection context: {any}", .{err});
            server.tcp_server.?.accept(loop, &server.accept_completion, Server, server, acceptCallback);
            return .disarm;
        };

        // Start reading from the client
        var read_buffer: [4096]u8 = undefined;
        client_socket.read(loop, &conn_ctx.read_completion, .{ .slice = &read_buffer }, ConnectionContext, conn_ctx, readCallback);

        // Continue accepting new connections
        server.tcp_server.?.accept(loop, &server.accept_completion, Server, server, acceptCallback);
        return .disarm;
    }

    fn readCallback(
        ctx_opt: ?*ConnectionContext,
        loop: *xev.Loop,
        completion: *xev.Completion,
        socket: xev.TCP,
        buffer: xev.ReadBuffer,
        result: xev.ReadError!usize,
    ) xev.CallbackAction {
        _ = completion;

        const ctx = ctx_opt orelse {
            log.err("Connection context is null in read callback", .{});
            return .disarm;
        };

        const bytes_read = result catch |err| {
            log.err("Read error: {any}", .{err});
            ctx.deinit();
            return .disarm;
        };

        if (bytes_read == 0) {
            log.debug("Client disconnected", .{});
            ctx.deinit();
            return .disarm;
        }

        // Append data to request buffer
        const data = buffer.slice[0..bytes_read];
        ctx.request_buffer.appendSlice(data) catch |err| {
            log.err("Failed to append request data: {any}", .{err});
            ctx.deinit();
            return .disarm;
        };

        log.debug("Read {d} bytes from client", .{bytes_read});

        // Try to parse the request
        if (tryParseRequest(ctx)) |request| {
            handleRequest(ctx, loop, socket, request);
        } else |err| switch (err) {
            error.IncompleteRequest => {
                // Continue reading more data
                var read_buffer: [4096]u8 = undefined;
                socket.read(loop, &ctx.read_completion, .{ .slice = &read_buffer }, ConnectionContext, ctx, readCallback);
            },
            else => {
                log.err("Failed to parse request: {any}", .{err});
                sendErrorResponse(ctx, loop, socket, 400);
            },
        }

        return .disarm;
    }

    fn tryParseRequest(ctx: *ConnectionContext) !HttpRequest {
        const request_data = ctx.request_buffer.items;

        // Look for end of headers
        const headers_end = std.mem.indexOf(u8, request_data, headers_end_marker) orelse {
            return error.IncompleteRequest;
        };

        const headers_section = request_data[0..headers_end];
        const body_start = headers_end + headers_end_marker.len;

        // Parse request line and headers
        var lines = std.mem.splitSequence(u8, headers_section, crlf);
        const request_line = lines.next() orelse return error.InvalidRequest;

        // Parse request line: "METHOD /path HTTP/1.1"
        var request_parts = std.mem.splitSequence(u8, request_line, " ");
        const method_str = request_parts.next() orelse return error.InvalidRequest;
        const uri = request_parts.next() orelse return error.InvalidRequest;
        const version = request_parts.next() orelse return error.InvalidRequest;

        const method = HttpMethod.fromString(method_str) catch return error.InvalidRequest;

        // Parse URI into path and query string
        var path: []const u8 = undefined;
        var query_string: ?[]const u8 = null;

        if (std.mem.indexOf(u8, uri, "?")) |query_start| {
            path = try ctx.arena_allocator.dupe(u8, uri[0..query_start]);
            query_string = try ctx.arena_allocator.dupe(u8, uri[query_start + 1 ..]);
        } else {
            path = try ctx.arena_allocator.dupe(u8, uri);
        }

        // Parse headers
        var headers = std.StringHashMap([]const u8).init(ctx.arena_allocator);
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
                const name = std.mem.trim(u8, line[0..colon_pos], " \t");
                const value = std.mem.trim(u8, line[colon_pos + 1 ..], " \t");
                try headers.put(try ctx.arena_allocator.dupe(u8, name), try ctx.arena_allocator.dupe(u8, value));
            }
        }

        // Get content length
        const content_length = blk: {
            if (headers.get("Content-Length")) |cl_str| {
                break :blk std.fmt.parseInt(usize, cl_str, 10) catch 0;
            } else {
                break :blk 0;
            }
        };

        // Check if we have the complete body
        const available_body_bytes = request_data.len - body_start;
        if (available_body_bytes < content_length) {
            return error.IncompleteRequest;
        }

        // Extract body
        const body = try ctx.arena_allocator.dupe(u8, request_data[body_start .. body_start + content_length]);

        return HttpRequest{
            .method = method,
            .path = path,
            .query_string = query_string,
            .version = try ctx.arena_allocator.dupe(u8, version),
            .headers = headers,
            .body = body,
            .allocator = ctx.arena_allocator,
        };
    }

    fn handleRequest(ctx: *ConnectionContext, loop: *xev.Loop, socket: xev.TCP, request: HttpRequest) void {
        log.info("Handling {s} request to {s}", .{ request.method.toString(), request.path });

        // Heap-allocate async response context to prevent stack invalidation
        const response_ctx = ctx.allocator.create(AsyncResponseContext) catch {
            log.err("Failed to allocate AsyncResponseContext", .{});
            sendErrorResponse(ctx, loop, socket, 500);
            return;
        };

        response_ctx.* = AsyncResponseContext{
            .ctx = ctx,
            .loop = loop,
            .socket = socket,
        };

        // Call the async handler (cast to anyopaque to break circular dependency)
        ctx.server.handler(request, @ptrCast(response_ctx));
    }

    fn sendErrorResponse(ctx: *ConnectionContext, loop: *xev.Loop, socket: xev.TCP, status_code: u16) void {
        const error_body = switch (status_code) {
            400 => "Bad Request",
            404 => "Not Found",
            500 => "Internal Server Error",
            else => "Error",
        };

        var error_response = HttpResponse.init(ctx.arena_allocator, status_code, error_body) catch {
            log.err("Failed to create error response", .{});
            ctx.deinit();
            return;
        };
        defer error_response.deinit();

        sendResponse(ctx, loop, socket, &error_response);
    }

    fn sendResponse(ctx: *ConnectionContext, loop: *xev.Loop, socket: xev.TCP, response: *HttpResponse) void {
        const response_bytes = response.toBytes(ctx.arena_allocator) catch |err| {
            log.err("Failed to serialize response: {any}", .{err});
            sendErrorResponse(ctx, loop, socket, 500);
            return;
        };

        socket.write(loop, &ctx.write_completion, .{ .slice = response_bytes }, ConnectionContext, ctx, writeCallback);
    }

    fn writeCallback(
        ctx_opt: ?*ConnectionContext,
        loop: *xev.Loop,
        completion: *xev.Completion,
        socket: xev.TCP,
        buffer: xev.WriteBuffer,
        result: xev.WriteError!usize,
    ) xev.CallbackAction {
        _ = completion;
        _ = buffer;

        const ctx = ctx_opt orelse {
            log.err("Connection context is null in write callback", .{});
            return .disarm;
        };

        const bytes_written = result catch |err| {
            log.err("Write error: {any}", .{err});
            ctx.deinit();
            return .disarm;
        };

        log.debug("Wrote {d} bytes to client", .{bytes_written});

        // Close the connection
        socket.close(loop, &ctx.close_completion, ConnectionContext, ctx, closeCallback);
        return .disarm;
    }

    fn closeCallback(
        ctx_opt: ?*ConnectionContext,
        loop: *xev.Loop,
        completion: *xev.Completion,
        socket: xev.TCP,
        result: xev.CloseError!void,
    ) xev.CallbackAction {
        _ = loop;
        _ = completion;
        _ = socket;
        result catch |err| {
            log.debug("Socket close error: {any}", .{err});
        };

        const ctx = ctx_opt orelse {
            log.err("Connection context is null in close callback", .{});
            return .disarm;
        };

        log.debug("Connection closed", .{});
        ctx.deinit();
        return .disarm;
    }
};

