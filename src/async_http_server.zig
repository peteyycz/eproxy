const std = @import("std");
const xev = @import("xev");
const log = std.log;

pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,
    HEAD,
    OPTIONS,
    PATCH,

    pub fn fromString(method: []const u8) !HttpMethod {
        if (std.mem.eql(u8, method, "GET")) return .GET;
        if (std.mem.eql(u8, method, "POST")) return .POST;
        if (std.mem.eql(u8, method, "PUT")) return .PUT;
        if (std.mem.eql(u8, method, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, method, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, method, "OPTIONS")) return .OPTIONS;
        if (std.mem.eql(u8, method, "PATCH")) return .PATCH;
        return error.UnknownMethod;
    }

    pub fn toString(self: HttpMethod) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
            .PATCH => "PATCH",
        };
    }
};

pub const HttpRequest = struct {
    method: HttpMethod,
    path: []const u8,
    query_string: ?[]const u8,
    version: []const u8, // e.g., "HTTP/1.1"
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HttpRequest) void {
        self.headers.deinit();
        self.allocator.free(self.body);
        self.allocator.free(self.path);
        if (self.query_string) |qs| {
            self.allocator.free(qs);
        }
        self.allocator.free(self.version);
    }

    pub fn getHeader(self: *const HttpRequest, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }
};

pub const HttpResponse = struct {
    status_code: u16,
    status_text: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, status_code: u16, body: []const u8) !HttpResponse {
        const status_text = switch (status_code) {
            200 => "OK",
            404 => "Not Found",
            500 => "Internal Server Error",
            else => "Unknown",
        };

        var headers = std.StringHashMap([]const u8).init(allocator);
        try headers.put(try allocator.dupe(u8, "Content-Length"), try std.fmt.allocPrint(allocator, "{d}", .{body.len}));
        try headers.put(try allocator.dupe(u8, "Content-Type"), try allocator.dupe(u8, "text/plain"));

        return HttpResponse{
            .status_code = status_code,
            .status_text = status_text,
            .headers = headers,
            .body = try allocator.dupe(u8, body),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HttpResponse) void {
        var iter = self.headers.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();
        self.allocator.free(self.body);
    }

    pub fn toBytes(self: *const HttpResponse, allocator: std.mem.Allocator) ![]u8 {
        var response_parts = std.ArrayList([]const u8).init(allocator);
        defer response_parts.deinit();

        // Status line
        const status_line = try std.fmt.allocPrint(allocator, "HTTP/1.1 {d} {s}\r\n", .{ self.status_code, self.status_text });
        try response_parts.append(status_line);

        // Headers
        var iter = self.headers.iterator();
        while (iter.next()) |entry| {
            const header_line = try std.fmt.allocPrint(allocator, "{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            try response_parts.append(header_line);
        }

        // Empty line before body
        try response_parts.append("\r\n");
        
        // Body
        try response_parts.append(self.body);

        // Concatenate all parts
        var total_len: usize = 0;
        for (response_parts.items) |part| {
            total_len += part.len;
        }

        const result = try allocator.alloc(u8, total_len);
        var pos: usize = 0;
        for (response_parts.items) |part| {
            @memcpy(result[pos..pos + part.len], part);
            pos += part.len;
        }

        return result;
    }
};

pub const HandlerCallback = *const fn (request: HttpRequest, response_writer: *ResponseWriter) void;

pub const ResponseWriter = struct {
    allocator: std.mem.Allocator,
    response: ?HttpResponse,

    pub fn init(allocator: std.mem.Allocator) ResponseWriter {
        return ResponseWriter{
            .allocator = allocator,
            .response = null,
        };
    }

    pub fn writeResponse(self: *ResponseWriter, status_code: u16, body: []const u8) !void {
        self.response = try HttpResponse.init(self.allocator, status_code, body);
    }

    pub fn deinit(self: *ResponseWriter) void {
        if (self.response) |*resp| {
            resp.deinit();
        }
    }
};

const ConnectionContext = struct {
    socket: xev.TCP,
    server: *Server,
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    arena_allocator: std.mem.Allocator,
    
    // I/O state
    read_completion: xev.Completion,
    write_completion: xev.Completion,
    close_completion: xev.Completion,
    
    // Request parsing state
    request_buffer: std.ArrayList(u8),
    headers_complete: bool,
    content_length: usize,
    bytes_read: usize,
    
    pub fn init(allocator: std.mem.Allocator, socket: xev.TCP, server: *Server) !*ConnectionContext {
        const ctx = try allocator.create(ConnectionContext);
        ctx.* = ConnectionContext{
            .socket = socket,
            .server = server,
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .arena_allocator = undefined,
            .read_completion = undefined,
            .write_completion = undefined,
            .close_completion = undefined,
            .request_buffer = std.ArrayList(u8).init(allocator),
            .headers_complete = false,
            .content_length = 0,
            .bytes_read = 0,
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

pub const Server = struct {
    loop: *xev.Loop,
    allocator: std.mem.Allocator,
    handler: HandlerCallback,
    tcp_server: ?xev.TCP,
    accept_completion: xev.Completion,

    pub fn init(allocator: std.mem.Allocator, loop: *xev.Loop, handler: HandlerCallback) Server {
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
        const conn_ctx = ConnectionContext.init(server.allocator, client_socket, server) catch |err| {
            log.err("Failed to create connection context: {any}", .{err});
            // Just log the error and continue - we can't properly close without a completion
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
        const headers_end_marker = "\r\n\r\n";
        const headers_end = std.mem.indexOf(u8, request_data, headers_end_marker) orelse {
            return error.IncompleteRequest;
        };

        const headers_section = request_data[0..headers_end];
        const body_start = headers_end + headers_end_marker.len;

        // Parse request line and headers
        var lines = std.mem.splitSequence(u8, headers_section, "\r\n");
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
            query_string = try ctx.arena_allocator.dupe(u8, uri[query_start + 1..]);
        } else {
            path = try ctx.arena_allocator.dupe(u8, uri);
        }

        // Parse headers
        var headers = std.StringHashMap([]const u8).init(ctx.arena_allocator);
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
                const name = std.mem.trim(u8, line[0..colon_pos], " \t");
                const value = std.mem.trim(u8, line[colon_pos + 1..], " \t");
                try headers.put(
                    try ctx.arena_allocator.dupe(u8, name),
                    try ctx.arena_allocator.dupe(u8, value)
                );
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
        const body = try ctx.arena_allocator.dupe(u8, request_data[body_start..body_start + content_length]);

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

        // Create response writer
        var response_writer = ResponseWriter.init(ctx.arena_allocator);
        defer response_writer.deinit();

        // Call the user handler
        ctx.server.handler(request, &response_writer);

        // Send response
        if (response_writer.response) |*response| {
            sendResponse(ctx, loop, socket, response);
        } else {
            // No response was written, send 500
            sendErrorResponse(ctx, loop, socket, 500);
        }
    }

    fn sendResponse(ctx: *ConnectionContext, loop: *xev.Loop, socket: xev.TCP, response: *HttpResponse) void {
        const response_bytes = response.toBytes(ctx.arena_allocator) catch |err| {
            log.err("Failed to serialize response: {any}", .{err});
            sendErrorResponse(ctx, loop, socket, 500);
            return;
        };

        socket.write(loop, &ctx.write_completion, .{ .slice = response_bytes }, ConnectionContext, ctx, writeCallback);
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
