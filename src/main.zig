const std = @import("std");
const log = std.log;
const xev = @import("xev");
const eproxy = @import("eproxy");

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

    const address = try eproxy.resolveAddress(allocator, "httpbin.org");

    const socket = try xev.TCP.init(address);
    const fetchContext = try eproxy.fetch.Context.init(allocator, struct {
        // Callback to handle the result of the fetch operation
        pub fn callback(result: eproxy.fetch.Error!std.ArrayList(u8)) void {
            const response = result catch |err| {
                log.err("Fetch failed: {}", .{err});
                return;
            };
            log.info("Fetch completed successfully\n{s}", .{response.items});
            response.deinit();
        }
    }.callback);
    socket.connect(&loop, &fetchContext.connect_completion, address, eproxy.fetch.Context, fetchContext, eproxy.fetch.connectCallback);

    try loop.run(.until_done);
}
