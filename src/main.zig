const std = @import("std");
const log = std.log;
const xev = @import("xev");
const eproxy = @import("eproxy");

// Global context accessible to request handlers
var g_allocator: std.mem.Allocator = undefined;
var g_loop: *xev.Loop = undefined;

// Request handler context for completion-based handling
const RequestHandler = struct {
    allocator: std.mem.Allocator,
    loop: *xev.Loop,
    fetch_completion: xev.Completion,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, loop: *xev.Loop) Self {
        return Self{
            .allocator = allocator,
            .loop = loop,
            .fetch_completion = undefined,
        };
    }

    pub fn handleRequest(
        self: ?*Self,
        loop: *xev.Loop,
        completion: *xev.Completion,
        handler_ctx: *eproxy.HandlerContext
    ) xev.CallbackAction {
        _ = completion;

        const handler_self = self orelse {
            log.err("Request handler context is null", .{});
            handler_ctx.response_ctx.respond(500, "Internal server error");
            return .disarm;
        };

        const request = handler_ctx.request;
        const response_ctx = handler_ctx.response_ctx;

        log.info("Received {s} request to {s}", .{ request.method.toString(), request.path });

        if (request.query_string) |qs| {
            log.info("Query string: {s}", .{qs});
        }

        // Print headers
        log.info("Headers:", .{});
        var header_iter = request.headers.iterator();
        while (header_iter.next()) |entry| {
            log.info("  {s}: {s}", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        if (request.body.len > 0) {
            log.info("Body ({d} bytes): {s}", .{ request.body.len, request.body });
        }

        // Handle proxy requests asynchronously
        if (std.mem.eql(u8, request.path, "/proxy")) {
            log.info("Making external HTTP request...", .{});

            eproxy.http.fetch(
                handler_self.allocator,
                loop,
                "http://httpbin.org/get",
                &handler_self.fetch_completion,
                eproxy.ResponseContext,
                response_ctx,
                handleProxyResponse
            ) catch |err| {
                log.err("Failed to initiate external request: {any}", .{err});
                response_ctx.respond(500, "Failed to initiate proxy request");
                return .disarm;
            };

            return .rearm;
        }

        // Regular response handling
        const response_body = if (std.mem.eql(u8, request.path, "/hello"))
            "Hello, World!"
        else if (std.mem.eql(u8, request.path, "/"))
            "Welcome to the HTTP server! Try /proxy to see external HTTP requests."
        else
            "Not Found";

        const status_code: u16 = if (std.mem.eql(u8, response_body, "Not Found")) 404 else 200;
        response_ctx.respond(status_code, response_body);

        return .disarm;
    }

    fn handleProxyResponse(
        response_ctx: ?*eproxy.ResponseContext,
        loop: *xev.Loop,
        completion: *xev.Completion,
        err: ?eproxy.http.FetchError,
        response: ?eproxy.http.client.HttpResponse
    ) xev.CallbackAction {
        _ = loop;
        _ = completion;

        const ctx = response_ctx orelse {
            log.err("Response context was null in proxy callback", .{});
            return .disarm;
        };

        if (err) |error_info| {
            log.err("External request failed: {any}", .{error_info});
            ctx.respond(500, "External request failed");
        } else if (response) |resp| {
            ctx.respond(@intCast(resp.status_code), resp.body);
        }

        return .disarm;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize libxev event loop
    var thread_pool = xev.ThreadPool.init(.{ .max_threads = 2 });
    defer thread_pool.deinit();

    var loop = try xev.Loop.init(.{
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();

    // Set global context for request handlers
    g_allocator = allocator;
    g_loop = &loop;

    log.info("Starting HTTP server...", .{});

    // Create request handler instance
    var request_handler = RequestHandler.init(allocator, &loop);

    // Create server with completion-based handler
    var server = eproxy.createServer(
        allocator, 
        &loop, 
        RequestHandler,
        &request_handler,
        RequestHandler.handleRequest
    );

    // Start listening
    try server.listen(8080);

    log.info("Server started on http://localhost:8080", .{});
    log.info("Try these endpoints:", .{});
    log.info("  /hello - Simple greeting", .{});
    log.info("  /proxy - Makes external HTTP request", .{});
    log.info("Press Ctrl+C to stop", .{});

    // Run the event loop to process all async operations
    try loop.run(.until_done);

    log.info("Server stopped", .{});

    // Explicitly shutdown the thread pool
    thread_pool.shutdown();
}
