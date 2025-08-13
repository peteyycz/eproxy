const std = @import("std");
const log = std.log;
const xev = @import("xev");
const eproxy = @import("eproxy");
const fetch = eproxy.fetch;
const createServer = eproxy.createServer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Initialize libxev event loop
    var thread_pool = xev.ThreadPool.init(.{ .max_threads = 4 });
    defer thread_pool.deinit();
    defer thread_pool.shutdown();

    var loop = try xev.Loop.init(.{
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();

    const port: u16 = 8080;
    log.info("Server listening on http://localhost:{}", .{port});
    try eproxy.createServer(allocator, &loop, port);

    // const request = try eproxy.Request.allocFromUrl(allocator, .GET, "http://httpbin.org/get");
    // try fetch.doFetch(allocator, &loop, request, struct {
    //     pub fn callback(a: std.mem.Allocator, l: *xev.Loop, result: fetch.Error!std.ArrayList(u8)) void {
    //         const response = result catch |err| {
    //             log.err("Fetch failed: {}", .{err});
    //             return;
    //         };
    //         defer response.deinit();
    //         log.debug("Fetch completed successfully\n{}", .{response.items.len});
    //
    //         const r = eproxy.Request.allocFromUrl(a, .GET, "http://httpbin.org/get") catch |err| {
    //             log.err("Failed to create request: {}", .{err});
    //             return;
    //         };
    //         fetch.doFetch(a, l, r, struct {
    //             pub fn callback(_: std.mem.Allocator, _: *xev.Loop, inner_result: fetch.Error!std.ArrayList(u8)) void {
    //                 const inner_response = inner_result catch |err| {
    //                     log.err("Fetch failed: {}", .{err});
    //                     return;
    //                 };
    //                 defer inner_response.deinit();
    //                 log.debug("Fetch completed successfully\n{}", .{inner_response.items.len});
    //             }
    //         }.callback) catch |err| {
    //             log.err("Error in nested fetch: {}", .{err});
    //         };
    //     }
    // }.callback);

    try loop.run(.until_done);
}
