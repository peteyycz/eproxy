const std = @import("std");
const log = std.log;
const xev = @import("xev");
const connection = @import("connection.zig");

const ClientContext = connection.ClientContext;

pub const AcceptContext = struct {
    allocator: std.mem.Allocator,
};

pub fn acceptCallback(
    userdata: ?*AcceptContext,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.AcceptError!xev.TCP,
) xev.CallbackAction {
    _ = completion;

    const accept_ctx = userdata orelse {
        log.err("Missing accept context", .{});
        return .rearm;
    };

    const client = result catch |err| {
        log.err("Failed to accept connection: {}", .{err});
        return .rearm; // Continue accepting
    };

    log.debug("Accepted connection", .{});

    // Create context to keep completions alive
    const ctx = ClientContext.init(accept_ctx.allocator, client) catch |err| {
        log.err("Failed to allocate client context: {}", .{err});
        return .rearm;
    };

    // First, read the HTTP request
    log.debug("Reading HTTP request...", .{});
    // TODO: Use chunked reading for large requests
    client.read(loop, &ctx.read_completion, .{ .slice = &ctx.request_buffer }, ClientContext, ctx, connection.readCallback);

    return .rearm; // Continue accepting more connections
}

