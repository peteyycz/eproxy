const std = @import("std");

// Re-export all public modules for library users
pub const http = @import("http.zig");
pub const http_server = @import("http_server.zig");

// Core types
pub const Server = http_server.Server;
pub const ResponseContext = http_server.ResponseContext;
pub const HandlerCallback = http_server.HandlerCallback;

// HTTP types
pub const Request = http.Request;
pub const Response = http.Response;
pub const Method = http.Method;

// Convenience function to create a server
pub fn createServer(allocator: std.mem.Allocator, loop: anytype, handler: HandlerCallback(ResponseContext)) Server {
    return Server.init(allocator, loop, handler);
}

test "library exports" {
    // Test that all main types are accessible
    _ = Server;
    _ = ResponseContext;
    _ = HandlerCallback;
    _ = Request;
    _ = Response;
    _ = Method;
}

