const std = @import("std");
const log = std.log;
const xev = @import("xev");
const http_client = @import("http_client.zig");
const HttpRequest = @import("http/request.zig").HttpRequest;
const ResponseWriter = @import("http/response_writer.zig").ResponseWriter;
const Server = @import("http_server.zig").Server;

// Another example callback for chaining requests
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

    log.info("Starting async HTTP requests...", .{});

    try http_client.fetchUrl(allocator, &loop, "http://httpbin.org/get", struct {
        fn handleResponse(err: ?http_client.FetchError, response: ?http_client.HttpResponse) void {
            if (err) |error_info| {
                log.err("Request failed: {}", .{error_info});
                return;
            }

            if (response) |resp| {
                log.info("=== HTTP Response ===", .{});
                log.info("Status: {}", .{resp.status_code});
                log.info("Body length: {} bytes", .{resp.body.len});
                log.info("Body preview: {s}", .{resp.body[0..@min(resp.body.len, 200)]});

                // Print some headers
                var header_iter = resp.headers.iterator();
                log.info("Headers:", .{});
                while (header_iter.next()) |entry| {
                    log.info("  {s}: {s}", .{ entry.key_ptr.*, entry.value_ptr.* });
                }
            }
        }
    }.handleResponse);

    // Create server
    var server = Server.init(allocator, &loop, struct {
        fn handleRequest(request: HttpRequest, response_writer: *ResponseWriter) void {
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

            // Create a simple response based on the path
            const response_body = if (std.mem.eql(u8, request.path, "/hello"))
                "Hello, World!"
            else if (std.mem.eql(u8, request.path, "/"))
                "Welcome to the HTTP server!"
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

    log.info("Requests initiated, running event loop...", .{});

    // Run the event loop to process all async operations
    try loop.run(.until_done);

    log.info("All requests completed", .{});

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
