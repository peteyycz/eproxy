const std = @import("std");
const HttpMethod = @import("method.zig").HttpMethod;

pub const HttpRequest = struct {
    method: HttpMethod,
    path: []const u8,
    query_string: ?[]const u8,
    version: []const u8, // e.g., "HTTP/1.1"
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HttpRequest) void {
        self.headers.deinit();
        self.allocator.free(self.body);
        self.allocator.free(self.path);
        if (self.query_string) |qs| {
            self.allocator.free(qs);
        }
        self.allocator.free(self.version);
    }

    pub fn getHeader(self: *const HttpRequest, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }
};
