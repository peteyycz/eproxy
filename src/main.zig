const std = @import("std");
const log = std.log;
const xev = @import("xev");
const http = @import("http.zig");

// Global context accessible to request handlers
var g_allocator: std.mem.Allocator = undefined;
var g_loop: *xev.Loop = undefined;

var g_response_ctx: ?*http.ResponseContext = null;
var response_context_mutex = std.Thread.Mutex{};

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

    var server = http.Server.init(allocator, &loop, struct {
        fn handleRequest(request: http.Request, response_ctx: *http.ResponseContext) void {
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

            // Example: Fetch data from external API when /proxy path is requested
            if (std.mem.eql(u8, request.path, "/proxy")) {
                log.info("Making external HTTP request...", .{});

                // Store response context globally for the callback to access
                response_context_mutex.lock();
                g_response_ctx = response_ctx;
                response_context_mutex.unlock();

                http.fetch(g_allocator, g_loop, "http://httpbin.org/get", struct {
                    fn handleResponse(err: ?http.FetchError, response: ?http.client.HttpResponse) void {
                        // Retrieve the stored response context
                        response_context_mutex.lock();
                        const ctx = g_response_ctx;
                        g_response_ctx = null; // Clear it after use
                        response_context_mutex.unlock();

                        if (ctx) |response_context| {
                            if (err) |error_info| {
                                log.err("External request failed: {any}", .{error_info});
                                response_context.respond(500, "External request failed");
                                return;
                            }

                            if (response) |resp| {
                                // Send the actual external API response back to the client
                                response_context.respond(@intCast(resp.status_code), resp.body);
                            }
                        } else {
                            log.err("Response context was null in callback", .{});
                        }
                    }
                }.handleResponse) catch |err| {
                    log.err("Failed to initiate external request: {any}", .{err});
                    response_ctx.respond(500, "Failed to initiate proxy request");
                };

                // Don't send immediate response - the callback will handle it
                return;
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
        }
    }.handleRequest);

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
