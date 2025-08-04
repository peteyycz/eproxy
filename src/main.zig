const std = @import("std");
const net = std.net;
const log = std.log;
const build_options = @import("build_options");
const xev = @import("xev");
const server = @import("server.zig");

pub const std_options: std.Options = .{
    .log_level = @enumFromInt(@intFromEnum(build_options.log_level)),
};

const PROXY_HOST = "localhost";
const PROXY_PORT = 9000;
const LISTEN_PORT = 8080;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize thread pool and event loop
    var thread_pool = xev.ThreadPool.init(.{ .max_threads = 4 });
    defer thread_pool.deinit();

    var loop = try xev.Loop.init(.{
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();

    // Bind to address
    const addr = try std.net.Address.parseIp("127.0.0.1", LISTEN_PORT);

    // Create libxev TCP server with address
    var tcp_server = try xev.TCP.init(addr);
    try tcp_server.bind(addr);
    try tcp_server.listen(128); // backlog

    log.info("Reverse proxy listening on http://127.0.0.1:{}", .{LISTEN_PORT});
    log.info("Proxying requests to {s}:{}", .{ PROXY_HOST, PROXY_PORT });
    log.info("Server socket bound and listening, starting accept...", .{});

    // Start accepting connections asynchronously
    var accept_ctx = server.AcceptContext{ .allocator = allocator };
    var accept_completion: xev.Completion = undefined;
    tcp_server.accept(&loop, &accept_completion, server.AcceptContext, &accept_ctx, server.acceptCallback);

    // Run event loop
    log.info("Starting event loop...", .{});
    try loop.run(.until_done);
    log.info("Event loop exited", .{});
}