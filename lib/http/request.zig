const std = @import("std");

const crlf = "\r\n";
const headers_end_marker = crlf ++ crlf;
const request_template = "{s} {s} HTTP/1.1" ++ crlf ++ "Host: {s}" ++ crlf ++ "Connection: close" ++ headers_end_marker;

// We only support GET method for this example, but you can extend it to support more methods.
const Method = enum {
    GET,

    pub fn print(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
        };
    }
};

pub const Request = struct {
    host: []const u8,
    pathname: []const u8,
    method: Method = .GET,

    pub fn init(method: Method, host: []const u8, pathname: []const u8) Request {
        return Request{ .method = method, .host = host, .pathname = pathname };
    }

    pub fn allocPrint(self: *const Request, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, request_template, .{ self.method.print(), self.pathname, self.host });
    }
};
