const std = @import("std");
const log = std.log;
const xev = @import("xev");
const async_http_server = @import("src/async_http_server.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize libxev event loop
    var thread_pool = xev.ThreadPool.init(.{ .max_threads = 4 });
    defer thread_pool.deinit();

    var loop = try xev.Loop.init(.{
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();

    log.info("Starting HTTP server test...", .{});

    // Create server
    var server = async_http_server.Server.init(allocator, &loop, struct {
        fn handleRequest(request: async_http_server.HttpRequest, response_writer: *async_http_server.ResponseWriter) void {
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

    log.info("Server started. Test with: curl http://localhost:8080/hello", .{});
    log.info("Press Ctrl+C to stop", .{});

    // Run the event loop
    try loop.run(.until_done);

    // Explicitly shutdown the thread pool
    thread_pool.shutdown();
}
