const std = @import("std");
const log = std.log;
const xev = @import("xev");
const http = @import("http.zig");

// Global context accessible to request handlers
var g_allocator: std.mem.Allocator = undefined;
var g_loop: *xev.Loop = undefined;

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

    log.info("Starting HTTP server with proxy capability...", .{});

    // Create server
    var server = http.Server.init(allocator, &loop, struct {
        fn handleRequest(request: http.Request, response_writer: *http.ResponseWriter) void {
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

                http.fetch(g_allocator, g_loop, "http://httpbin.org/get", struct {
                    fn handleResponse(err: ?http.FetchError, response: ?http.client.HttpResponse) void {
                        if (err) |error_info| {
                            log.err("External request failed: {any}", .{error_info});
                            return;
                        }

                        if (response) |resp| {
                            log.info("=== External HTTP Response ===", .{});
                            log.info("Status: {d}", .{resp.status_code});
                            log.info("Body length: {d} bytes", .{resp.body.len});
                            log.info("Body preview: {s}", .{resp.body[0..@min(resp.body.len, 200)]});
                        }
                    }
                }.handleResponse) catch |err| {
                    log.err("Failed to initiate external request: {any}", .{err});
                };

                // For now, send immediate response (in a real proxy, you'd wait for the external response)
                response_writer.writeResponse(200, "Proxy request initiated - check logs for external response") catch |err| {
                    log.err("Failed to write response: {any}", .{err});
                };
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

            response_writer.writeResponse(status_code, response_body) catch |err| {
                log.err("Failed to write response: {any}", .{err});
            };
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

// Example of how you might use this in the main proxy application:
//
// fn proxyRequestToBackend(request_data: []const u8) void {
//     // Instead of direct TCP connection, use the async HTTP interface
//     async_http.fetchUrl(allocator, &loop, "http://backend-server/api", handleProxyResponse);
// }
//
// fn handleProxyResponse(err: ?async_http.FetchError, response: ?async_http.HttpResponse) void {
//     if (err) |error_info| {
//         // Send 502 Bad Gateway to client
//         sendErrorToClient(502);
//         return;
//     }
//
//     if (response) |resp| {
//         // Forward the response back to the client
//         forwardResponseToClient(resp);
//     }
// }
