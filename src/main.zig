const std = @import("std");
const log = std.log;
const xev = @import("xev");
const async_http = @import("async_http.zig");

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

    // Example 1: Simple GET request with callback
    try async_http.fetchUrl(allocator, &loop, "http://httpbin.org/get", struct {
        fn handleResponse(err: ?async_http.FetchError, response: ?async_http.HttpResponse) void {
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
