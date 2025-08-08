const std = @import("std");
const xev = @import("xev");
const log = std.log;
const util = @import("util.zig");

const Context = struct {
    allocator: std.mem.Allocator,
    loop: *xev.Loop,
    socket: xev.TCP,

    accept_completion: xev.Completion = undefined,
    close_completion: xev.Completion = undefined,

    pub fn init(allocator: std.mem.Allocator, loop: *xev.Loop, socket: xev.TCP) !*Context {
        const ctx = try allocator.create(Context);
        ctx.allocator = allocator;
        ctx.loop = loop;
        ctx.socket = socket;
        return ctx;
    }

    pub fn deinit(self: *Context) void {
        self.allocator.destroy(self);
    }
};

pub fn createServer(allocator: std.mem.Allocator, loop: *xev.Loop) !void {
    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8080);
    const socket = try xev.TCP.init(address);
    try socket.bind(address);
    try socket.listen(128); // Listen backlog size

    const ctx = try Context.init(allocator, loop, socket);

    socket.accept(loop, &ctx.accept_completion, Context, ctx, acceptCallback);
}

fn acceptCallback(
    ctx_opt: ?*Context,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.AcceptError!xev.TCP,
) xev.CallbackAction {
    const ctx = ctx_opt orelse return .disarm;
    _ = r catch {
        // Accept failed, close the socket and return
        util.closeSocket(Context, ctx, ctx.loop, ctx.socket);
        return .disarm;
    };

    log.info("Connection accepted", .{});

    util.closeSocket(Context, ctx, ctx.loop, ctx.socket);

    return .disarm;
}
