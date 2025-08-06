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

    var loop = try xev.Loop.init(.{
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();

    var connect_completion: xev.Completion = undefined;

    const address_list = std.net.getAddressList(allocator, "pokeapi.co", 443) catch |err| {
        log.err("Failed to resolve address: {}", .{err});
        return err;
    };
    defer address_list.deinit();
    if (address_list.addrs.len == 0) {
        log.err("No addresses found for the given URL", .{});
        return error.NoAddressesFound;
    }
    const address = address_list.addrs[0];
    const socket = try xev.TCP.init(address);

    const fetchContext = try FetchContext.init(allocator);
    try socket.connect(&loop, &connect_completion, address, FetchContext, fetchContext, connectCallback);

    // Run the event loop to process all async operations
    try loop.run(.until_done);

    log.info("Server stopped", .{});

    // Explicitly shutdown the thread pool
    thread_pool.shutdown();
}

const FetchContext = struct {
    connect_completion: *xev.Completion,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const ctx = try allocator.create(Self);
        return ctx;
    }
};

fn connectCallback(
    ctx: ?*FetchContext,
    loop: *xev.Loop,
    completion: *xev.Completion,
    socket: xev.TCP,
    result: xev.ConnectError!void,
) !void {
    _ = ctx;
    _ = loop;
    _ = completion;
    _ = socket;
    _ = try result;

    log.info("Connected successfully", .{});

    // Here you would typically send a request or perform further operations
    // For example, sending an HTTP GET request to the connected server
    // This part is omitted for brevity.
}
