const std = @import("std");
const log = std.log;
const xev = @import("xev");

// Node.js-style callback interface for HTTP operations on top of libxev
//
// Example usage:
//   fetchUrl("http://example.com", myCallback);
//
//   fn myCallback(err: ?FetchError, response: ?HttpResponse) void {
//       if (err) |error_info| {
//           log.err("Request failed: {}", .{error_info});
//           return;
//       }
//       if (response) |resp| {
//           log.info("Status: {}, Body: {s}", .{resp.status_code, resp.body});
//       }
//   }

pub const FetchError = union(enum) {
    connect_failed: anyerror,
    dns_failed: anyerror,
    write_failed: xev.WriteError,
    read_failed: xev.ReadError,
    invalid_url: void,
    timeout: void,
    out_of_memory: std.mem.Allocator.Error,
    invalid_response: void,
};

pub const HttpResponse = struct {
    status_code: u16,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HttpResponse) void {
        self.headers.deinit();
        self.allocator.free(self.body);
    }
};

pub const FetchCallback = *const fn (err: ?FetchError, response: ?HttpResponse) void;

// Internal context for managing the async request
const FetchContext = struct {
    allocator: std.mem.Allocator,
    loop: *xev.Loop,
    callback: FetchCallback,

    // Connection state
    socket: ?xev.TCP,
    connect_completion: xev.Completion,
    write_completion: xev.Completion,
    read_completion: xev.Completion,
    close_completion: xev.Completion,

    // Request/response data
    request_data: []const u8,
    response_buffer: std.ArrayList(u8),
    response: ?HttpResponse,

    // Parsing state
    headers_complete: bool,
    content_length: ?usize,

    // Error state for cleanup
    pending_error: ?FetchError,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, loop: *xev.Loop, callback: FetchCallback) !*Self {
        const ctx = try allocator.create(Self);
        ctx.* = Self{
            .allocator = allocator,
            .loop = loop,
            .callback = callback,
            .socket = null,
            .connect_completion = undefined,
            .write_completion = undefined,
            .read_completion = undefined,
            .close_completion = undefined,
            .request_data = undefined,
            .response_buffer = std.ArrayList(u8).init(allocator),
            .response = null,
            .headers_complete = false,
            .content_length = null,
            .pending_error = null,
        };
        return ctx;
    }

    pub fn deinit(self: *Self) void {
        if (self.response) |*resp| {
            resp.deinit();
        }
        self.response_buffer.deinit();
        self.allocator.free(self.request_data);
        self.allocator.destroy(self);
    }

    fn callCallback(self: *Self, err: ?FetchError, response: ?HttpResponse) void {
        self.callback(err, response);
        self.deinit();
    }
};

// Parse a simple URL into host, port, and path
const ParsedUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
};

fn parseUrl(url: []const u8) !ParsedUrl {
    // Simple HTTP URL parser - just supports http://host:port/path format
    if (!std.mem.startsWith(u8, url, "http://")) {
        return error.InvalidUrl;
    }

    const without_protocol = url[7..]; // Remove "http://"

    // Find the first '/' to separate host:port from path
    const path_start = std.mem.indexOf(u8, without_protocol, "/") orelse without_protocol.len;
    const host_port = without_protocol[0..path_start];
    const path = if (path_start < without_protocol.len) without_protocol[path_start..] else "/";

    // Parse host:port
    if (std.mem.indexOf(u8, host_port, ":")) |colon_pos| {
        const host = host_port[0..colon_pos];
        const port_str = host_port[colon_pos + 1 ..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidUrl;
        return ParsedUrl{ .host = host, .port = port, .path = path };
    } else {
        // Default to port 80
        return ParsedUrl{ .host = host_port, .port = 80, .path = path };
    }
}

// Main fetchUrl function with Node.js-style callback
pub fn fetchUrl(allocator: std.mem.Allocator, loop: *xev.Loop, url: []const u8, callback: FetchCallback) !void {
    // Parse URL
    const parsed = parseUrl(url) catch {
        callback(FetchError.invalid_url, null);
        return;
    };

    // Create context
    const ctx = FetchContext.init(allocator, loop, callback) catch |err| {
        callback(FetchError{ .out_of_memory = err }, null);
        return;
    };

    // Build HTTP request
    const request_fmt = "GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n";
    ctx.request_data = std.fmt.allocPrint(allocator, request_fmt, .{ parsed.path, parsed.host }) catch |err| {
        ctx.callCallback(FetchError{ .out_of_memory = err }, null);
        return;
    };

    // Resolve hostname and connect
    const address = blk: {
        // Try parsing as IP address first
        if (std.net.Address.parseIp(parsed.host, parsed.port)) |addr| {
            break :blk addr;
        } else |_| {
            // If not an IP, resolve hostname via DNS
            const addr_list = std.net.getAddressList(allocator, parsed.host, parsed.port) catch |err| {
                ctx.callCallback(FetchError{ .dns_failed = err }, null);
                return;
            };
            defer addr_list.deinit();

            if (addr_list.addrs.len == 0) {
                ctx.callCallback(FetchError{ .dns_failed = error.NameNotFound }, null);
                return;
            }

            break :blk addr_list.addrs[0];
        }
    };

    // Create TCP socket
    ctx.socket = xev.TCP.init(address) catch |err| {
        ctx.callCallback(FetchError{ .connect_failed = err }, null);
        return;
    };

    // Start async connection
    ctx.socket.?.connect(loop, &ctx.connect_completion, address, FetchContext, ctx, connectCallback);
}

fn connectCallback(
    ctx_opt: ?*FetchContext,
    loop: *xev.Loop,
    completion: *xev.Completion,
    socket: xev.TCP,
    result: xev.ConnectError!void,
) xev.CallbackAction {
    _ = completion;

    const ctx = ctx_opt orelse return .disarm;

    result catch |err| {
        // Close socket before calling callback
        if (ctx.socket) |sock| {
            ctx.pending_error = FetchError{ .connect_failed = err };
            sock.close(loop, &ctx.close_completion, FetchContext, ctx, closeCallback);
            return .disarm;
        }
        ctx.callCallback(FetchError{ .connect_failed = err }, null);
        return .disarm;
    };

    log.debug("Connected, sending request...", .{});

    // Send HTTP request
    socket.write(loop, &ctx.write_completion, .{ .slice = ctx.request_data }, FetchContext, ctx, writeCallback);
    return .disarm;
}

fn writeCallback(
    ctx_opt: ?*FetchContext,
    loop: *xev.Loop,
    completion: *xev.Completion,
    socket: xev.TCP,
    buffer: xev.WriteBuffer,
    result: xev.WriteError!usize,
) xev.CallbackAction {
    _ = completion;
    _ = buffer;

    const ctx = ctx_opt orelse return .disarm;

    const bytes_written = result catch |err| {
        // Close socket before calling callback
        if (ctx.socket) |sock| {
            ctx.pending_error = FetchError{ .write_failed = err };
            sock.close(loop, &ctx.close_completion, FetchContext, ctx, closeCallback);
            return .disarm;
        }
        ctx.callCallback(FetchError{ .write_failed = err }, null);
        return .disarm;
    };

    log.debug("Wrote {} bytes, reading response...", .{bytes_written});

    // Start reading response
    var read_buffer: [4096]u8 = undefined;
    socket.read(loop, &ctx.read_completion, .{ .slice = &read_buffer }, FetchContext, ctx, readCallback);
    return .disarm;
}

fn readCallback(
    ctx_opt: ?*FetchContext,
    loop: *xev.Loop,
    completion: *xev.Completion,
    socket: xev.TCP,
    buffer: xev.ReadBuffer,
    result: xev.ReadError!usize,
) xev.CallbackAction {
    _ = completion;

    const ctx = ctx_opt orelse return .disarm;

    const bytes_read = result catch |err| {
        switch (err) {
            error.EOF => { // EOF indicates end of response
                log.debug("Response complete, parsing...", .{});

                const response = parseHttpResponse(ctx.allocator, ctx.response_buffer.items) catch |parseError| {
                    const fetch_error = switch (parseError) {
                        error.OutOfMemory => FetchError{ .out_of_memory = error.OutOfMemory },
                        error.InvalidResponse => FetchError{ .invalid_response = {} },
                    };
                    // Error parsing response - close socket then call callback
                    if (ctx.socket) |sock| {
                        ctx.pending_error = fetch_error;
                        sock.close(loop, &ctx.close_completion, FetchContext, ctx, closeCallback);
                        return .disarm;
                    }
                    ctx.callCallback(fetch_error, null);
                    return .disarm;
                };

                // Success case - close socket then call callback
                if (ctx.socket) |sock| {
                    ctx.response = response;
                    sock.close(loop, &ctx.close_completion, FetchContext, ctx, closeCallback);
                    return .disarm;
                }
                ctx.callCallback(null, response);
                return .disarm;
            },
            else => {},
        }
        // Close socket before calling callback
        if (ctx.socket) |sock| {
            ctx.pending_error = FetchError{ .read_failed = err };
            sock.close(loop, &ctx.close_completion, FetchContext, ctx, closeCallback);
            return .disarm;
        }
        ctx.callCallback(FetchError{ .read_failed = err }, null);
        return .disarm;
    };

    if (bytes_read == 0) {
        // EOF - parse complete response and call callback
    }

    // Append data to response buffer
    const data = buffer.slice[0..bytes_read];
    ctx.response_buffer.appendSlice(data) catch |err| {
        if (ctx.socket) |sock| {
            ctx.pending_error = FetchError{ .out_of_memory = err };
            sock.close(loop, &ctx.close_completion, FetchContext, ctx, closeCallback);
            return .disarm;
        }
        ctx.callCallback(FetchError{ .out_of_memory = err }, null);
        return .disarm;
    };

    log.debug("Read {} bytes, continuing...", .{bytes_read});

    // Continue reading
    var read_buffer: [4096]u8 = undefined;
    socket.read(loop, &ctx.read_completion, .{ .slice = &read_buffer }, FetchContext, ctx, readCallback);
    return .disarm;
}

fn closeCallback(
    ctx_opt: ?*FetchContext,
    loop: *xev.Loop,
    completion: *xev.Completion,
    socket: xev.TCP,
    result: xev.CloseError!void,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    _ = socket;
    result catch |err| {
        log.debug("Socket close error: {}", .{err});
    };

    const ctx = ctx_opt orelse return .disarm;

    // Socket is now closed, call the user callback
    if (ctx.response) |response| {
        // Success case - we stored the response before closing
        ctx.callCallback(null, response);
    } else if (ctx.pending_error) |err| {
        // Error case - we stored the error before closing
        ctx.callCallback(err, null);
    } else {
        // Fallback error case
        ctx.callCallback(FetchError{ .read_failed = error.EOF }, null);
    }

    return .disarm;
}

fn parseHttpResponse(allocator: std.mem.Allocator, raw_response: []const u8) !HttpResponse {
    // Find end of headers
    const headers_end = std.mem.indexOf(u8, raw_response, "\r\n\r\n") orelse return error.InvalidResponse;
    const headers_part = raw_response[0..headers_end];
    const body_part = raw_response[headers_end + 4 ..];

    // Parse status line
    var lines = std.mem.splitSequence(u8, headers_part, "\r\n");
    const status_line = lines.next() orelse return error.InvalidResponse;

    // Extract status code (e.g., "HTTP/1.1 200 OK")
    var status_parts = std.mem.splitSequence(u8, status_line, " ");
    _ = status_parts.next(); // Skip "HTTP/1.1"
    const status_str = status_parts.next() orelse return error.InvalidResponse;
    const status_code = std.fmt.parseInt(u16, status_str, 10) catch return error.InvalidResponse;

    // Parse headers
    var headers = std.StringHashMap([]const u8).init(allocator);
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
            const name = std.mem.trim(u8, line[0..colon_pos], " \t");
            const value = std.mem.trim(u8, line[colon_pos + 1 ..], " \t");
            try headers.put(name, value);
        }
    }

    // Copy body
    const body = try allocator.dupe(u8, body_part);

    return HttpResponse{
        .status_code = status_code,
        .headers = headers,
        .body = body,
        .allocator = allocator,
    };
}
