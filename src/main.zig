const std = @import("std");
const log = std.log;
const xev = @import("xev");
const eproxy = @import("eproxy");
const fetch = eproxy.fetch;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Initialize libxev event loop
    var thread_pool = xev.ThreadPool.init(.{ .max_threads = 2 });
    defer thread_pool.deinit();
    defer thread_pool.shutdown();

    var loop = try xev.Loop.init(.{
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();

    try fetch.doFetch(allocator, &loop, eproxy.Request{ .method = .GET, .host = "httpbin.org", .pathname = "/get" }, struct {
        // Callback to handle the result of the fetch operation
        pub fn callback(result: fetch.Error!std.ArrayList(u8)) void {
            const response = result catch |err| {
                log.err("Fetch failed: {}", .{err});
                return;
            };
            log.info("Fetch completed successfully\n{s}", .{response.items});
            response.deinit();
        }
    }.callback);

    try loop.run(.until_done);
}
