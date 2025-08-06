const std = @import("std");

// Re-export all public modules for library users
pub const http = @import("http.zig");
pub const http_server = @import("http_server.zig");

// Core types
pub const Server = http_server.Server;
pub const ResponseContext = http_server.ResponseContext;
pub const HandlerCallback = http_server.HandlerCallback;
pub const HandlerContext = http_server.HandlerContext;

// HTTP types
pub const Request = http.Request;
pub const Response = http.Response;
pub const Method = http.Method;

// Convenience function to create a server
pub fn createServer(
    allocator: std.mem.Allocator, 
    loop: anytype, 
    comptime ContextType: type,
    context: *ContextType,
    handler: HandlerCallback(ContextType)
) Server {
    return Server.init(allocator, loop, ContextType, context, handler);
}

test "library exports" {
    // Test that all main types are accessible
    _ = Server;
    _ = ResponseContext;
    _ = HandlerCallback;
    _ = HandlerContext;
    _ = Request;
    _ = Response;
    _ = Method;
}

