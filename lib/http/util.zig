const std = @import("std");
const xev = @import("xev");

pub fn closeSocket(
    comptime ContextType: type,
    ctx: *ContextType,
    loop: *xev.Loop,
    socket: xev.TCP,
) void {
    socket.close(loop, &ctx.close_completion, ContextType, ctx, closeCallback(ContextType));
}

fn closeCallback(comptime ContextType: type) *const fn (?*ContextType, *xev.Loop, *xev.Completion, xev.TCP, xev.CloseError!void) xev.CallbackAction {
    const Impl = struct {
        pub fn callback(
            ctx_opt: ?*ContextType,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.TCP,
            _: xev.CloseError!void,
        ) xev.CallbackAction {
            const ctx = ctx_opt orelse return .disarm;
            ctx.deinit();
            return .disarm;
        }
    };
    return Impl.callback;
}

pub fn shutdownSocket(
    comptime ContextType: type,
    ctx: *ContextType,
    loop: *xev.Loop,
    socket: xev.TCP,
) void {
    socket.shutdown(loop, &ctx.shutdown_completion, ContextType, ctx, shutdownCallback(ContextType));
}

fn shutdownCallback(comptime ContextType: type) *const fn (?*ContextType, *xev.Loop, *xev.Completion, xev.TCP, xev.ShutdownError!void) xev.CallbackAction {
    const Impl = struct {
        pub fn callback(
            ctx_opt: ?*ContextType,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.TCP,
            result: xev.ShutdownError!void,
        ) xev.CallbackAction {
            const ctx = ctx_opt orelse return .disarm;
            result catch {
                ctx.deinit();
                return .disarm;
            };
            ctx.deinit();
            return .disarm;
        }
    };
    return Impl.callback;
}
