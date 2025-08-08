const std = @import("std");

const crlf = "\r\n";
const headers_end_marker = crlf ++ crlf;
const request_template = "{s} {s} HTTP/1.1" ++ crlf ++ "Host: {s}" ++ crlf ++ "Connection: close" ++ headers_end_marker;

// We only support GET method, but you can extend it to support more methods.
pub const Method = enum {
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

    pub const ParseError = error{
        InvalidUrl,
        UnsupportedScheme,
        EmptyHost,
    };

    pub fn fromUrl(method: Method, url: []const u8) ParseError!Request {
        if (url.len == 0) return ParseError.InvalidUrl;

        var remaining = url;

        // Check and remove scheme
        if (std.mem.startsWith(u8, url, "http://")) {
            remaining = url[7..];
        } else if (std.mem.startsWith(u8, url, "https://")) {
            return ParseError.UnsupportedScheme; // For now
        } else {
            // Assume http:// if no scheme
        }

        if (remaining.len == 0) return ParseError.EmptyHost;

        // Split host and path
        if (std.mem.indexOf(u8, remaining, "/")) |slash_idx| {
            const host = remaining[0..slash_idx];
            if (host.len == 0) return ParseError.EmptyHost;

            const pathname = remaining[slash_idx..];
            return Request.init(method, host, pathname);
        } else {
            // No path, use root
            return Request.init(method, remaining, "/");
        }
    }
};

pub fn resolveAddress(
    allocator: std.mem.Allocator,
    url: []const u8,
) !std.net.Address {
    const address_list = try std.net.getAddressList(allocator, url, 80);
    defer address_list.deinit();
    if (address_list.addrs.len == 0) {
        return error.NoAddressesFound;
    }
    return address_list.addrs[0];
}

const testing = std.testing;

test "fromUrl with valid http url" {
    const req = try Request.fromUrl(.GET, "http://example.com/foo");
    try testing.expectEqualStrings(req.host, "example.com");
    try testing.expectEqualStrings(req.pathname, "/foo");
}

test "fromUrl with valid http url multiple segments" {
    const req = try Request.fromUrl(.GET, "http://example.com/foo/bar");
    try testing.expectEqualStrings(req.host, "example.com");
    try testing.expectEqualStrings(req.pathname, "/foo/bar");
}

test "fromUrl with no scheme" {
    const req = try Request.fromUrl(.GET, "example.com/bar");
    try testing.expectEqualStrings(req.host, "example.com");
    try testing.expectEqualStrings(req.pathname, "/bar");
}

test "fromUrl with https" {
    const err = Request.fromUrl(.GET, "https://example.com/");
    try testing.expectError(Request.ParseError.UnsupportedScheme, err);
}

test "fromUrl with empty url" {
    const err = Request.fromUrl(.GET, "");
    try testing.expectError(Request.ParseError.InvalidUrl, err);
}

test "fromUrl with no path" {
    const req = try Request.fromUrl(.GET, "example.com");
    try testing.expectEqualStrings(req.host, "example.com");
    try testing.expectEqualStrings(req.pathname, "/");
}

test "fromUrl with empty host" {
    const err = Request.fromUrl(.GET, "http:///foo");
    try testing.expectError(Request.ParseError.EmptyHost, err);
}
