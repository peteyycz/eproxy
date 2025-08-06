const std = @import("std");
const HttpResponse = @import("response.zig").HttpResponse;

pub const ResponseWriter = struct {
    allocator: std.mem.Allocator,
    response: ?HttpResponse,

    pub fn init(allocator: std.mem.Allocator) ResponseWriter {
        return ResponseWriter{
            .allocator = allocator,
            .response = null,
        };
    }

    pub fn writeResponse(self: *ResponseWriter, status_code: u16, body: []const u8) !void {
        self.response = try HttpResponse.init(self.allocator, status_code, body);
    }

    pub fn deinit(self: *ResponseWriter) void {
        if (self.response) |*resp| {
            resp.deinit();
        }
    }
};
