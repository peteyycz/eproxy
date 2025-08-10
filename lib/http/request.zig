const std = @import("std");
const log = std.log;

// We only support GET method, but you can extend it to support more methods.
pub const Method = enum {
    GET,

    pub fn print(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
        };
    }
};

const request_line_template = "{s} {s} HTTP/1.1";
const header_template = "{s}: {s}";
const crlf = "\r\n";

pub const Request = struct {
    allocator: std.mem.Allocator,

    method: Method = .GET,
    pathname: []const u8,
    headers: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, method: Method, pathname: []const u8, host: []const u8) !Request {
        var headers = std.StringHashMap([]const u8).init(allocator);
        // Do not support keepalive for now
        try headers.put("Connection", "close");
        try headers.put("Host", host);
        return Request{
            .method = method,
            .headers = headers,
            .pathname = pathname,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Request) void {
        self.headers.deinit();
    }

    pub fn getHost(self: *const Request) ?[]const u8 {
        return self.headers.get("Host");
    }

    pub fn allocPrint(self: *const Request, allocator: std.mem.Allocator) ![]const u8 {
        // Well this is not zero copy but getting there
        var result = std.ArrayList(u8).init(allocator);
        const writer = result.writer();

        try writer.print(request_line_template ++ crlf, .{ self.method.print(), self.pathname });
        var iter = self.headers.iterator();
        while (iter.next()) |header| {
            if (header.value_ptr.*.len == 0) continue; // skip empty headers
            try writer.print(header_template ++ crlf, .{ header.key_ptr.*, header.value_ptr.* });
        }

        try writer.writeAll(crlf); // End of headers

        return result.toOwnedSlice();
    }

    pub const ParseError = error{
        InvalidUrl,
        UnsupportedScheme,
        EmptyHost,
    };

    // We should probably consider copying the URL to avoid lifetime issues
    pub fn allocFromUrl(allocator: std.mem.Allocator, method: Method, url: []const u8) !Request {
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
            return Request.init(
                allocator, // Use default allocator
                method,
                pathname,
                host,
            );
        } else {
            // No path, use root
            return Request.init(
                allocator, // Use default allocator
                method,
                "/",
                remaining,
            );
        }
    }
};

// TODO: Continue with returning a proper Request type from the parser
pub fn parseRequest(allocator: std.mem.Allocator, request: []u8) !Request {
    if (request.len == 0) return error.InvalidRequest;

    var request_iterator = std.mem.splitSequence(u8, request[0..], crlf ++ crlf);
    const headers = request_iterator.next() orelse return error.IncompleteRequest;
    const body = request_iterator.next() orelse return error.IncompleteRequest;

    var headers_iterator = std.mem.tokenizeSequence(u8, headers, crlf);
    const request_line = headers_iterator.next() orelse return error.IncompleteRequest;
    var request_parts_iterator = std.mem.splitSequence(u8, request_line, " ");
    const method_str = request_parts_iterator.next() orelse return error.InvalidRequest;
    const method = std.meta.stringToEnum(Method, method_str) orelse return error.InvalidRequest;
    const pathname = request_parts_iterator.next() orelse return error.InvalidRequest;

    var headers_hash = std.StringHashMap([]const u8).init(allocator);
    while (headers_iterator.next()) |header| {
        var header_parts_iterator = std.mem.splitSequence(u8, header, ": ");
        const key = header_parts_iterator.next() orelse return error.InvalidRequest;
        const value = header_parts_iterator.next() orelse return error.InvalidRequest;
        try headers_hash.put(key, value);
    }

    // TODO: Add further validation for the request
    if (method == .GET) {
        if (body.len > 0) {
            return error.InvalidRequest;
        }
    } else {
        if (headers_hash.get("Content-Length")) |content_length_str| {
            const content_length = std.fmt.parseInt(u8, content_length_str, 10) orelse return error.InvalidRequest;
            if (content_length > body.len) {
                return error.IncompleteRequest;
            }
        }
    }
    return Request{
        .allocator = allocator,
        .method = method,
        .pathname = pathname,
        .headers = headers_hash,
    };
}

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

test "Request.allocFromUrl with valid http url" {
    const allocator = std.testing.allocator;
    var req = try Request.allocFromUrl(allocator, .GET, "http://example.com/foo");
    defer req.deinit();
    const host = req.headers.get("Host") orelse unreachable;
    try testing.expectEqualStrings(host, "example.com");
    try testing.expectEqualStrings(req.pathname, "/foo");
}

test "Request.allocFromUrl with valid http url multiple segments" {
    const allocator = std.testing.allocator;
    var req = try Request.allocFromUrl(allocator, .GET, "http://example.com/foo/bar");
    defer req.deinit();
    const host = req.headers.get("Host") orelse unreachable;
    try testing.expectEqualStrings(host, "example.com");
    try testing.expectEqualStrings(req.pathname, "/foo/bar");
}

test "Request.allocFromUrl with no scheme" {
    const allocator = std.testing.allocator;
    var req = try Request.allocFromUrl(allocator, .GET, "example.com/bar");
    defer req.deinit();
    const host = req.headers.get("Host") orelse unreachable;
    try testing.expectEqualStrings(host, "example.com");
    try testing.expectEqualStrings(req.pathname, "/bar");
}

test "Request.allocFromUrl with https" {
    const allocator = std.testing.allocator;
    const err = Request.allocFromUrl(allocator, .GET, "https://example.com/");
    try testing.expectError(Request.ParseError.UnsupportedScheme, err);
}

test "Request.allocFromUrl with empty url" {
    const allocator = std.testing.allocator;
    const err = Request.allocFromUrl(allocator, .GET, "");
    try testing.expectError(Request.ParseError.InvalidUrl, err);
}

test "Request.allocFromUrl with no path" {
    const allocator = std.testing.allocator;
    var req = try Request.allocFromUrl(allocator, .GET, "example.com");
    defer req.deinit();
    const host = req.headers.get("Host") orelse unreachable;
    try testing.expectEqualStrings(host, "example.com");
    try testing.expectEqualStrings(req.pathname, "/");
}

test "Request.allocFromUrl with empty host" {
    const allocator = std.testing.allocator;
    const err = Request.allocFromUrl(allocator, .GET, "http:///foo");
    try testing.expectError(Request.ParseError.EmptyHost, err);
}

test "Request.allocPrint with basic request" {
    const allocator = std.testing.allocator;
    var req = try Request.allocFromUrl(allocator, .GET, "http://example.com/test");
    defer req.deinit();

    const request_str = try req.allocPrint(allocator);
    defer allocator.free(request_str);

    const expected =
        "GET /test HTTP/1.1\r\n" ++
        "Connection: close\r\n" ++
        "Host: example.com\r\n\r\n";
    try testing.expectEqualStrings(expected, request_str);
}

test "Request.allocPrint with root path" {
    const allocator = std.testing.allocator;
    var req = try Request.allocFromUrl(allocator, .GET, "http://api.example.com");
    defer req.deinit();

    const request_str = try req.allocPrint(allocator);
    defer allocator.free(request_str);

    const expected =
        "GET / HTTP/1.1\r\n" ++
        "Connection: close\r\n" ++
        "Host: api.example.com\r\n\r\n";
    try testing.expectEqualStrings(expected, request_str);
}

test "Request.allocPrint with complex path" {
    const allocator = std.testing.allocator;
    var req = try Request.allocFromUrl(allocator, .GET, "http://example.com/api/v1/users?id=123");
    defer req.deinit();

    const request_str = try req.allocPrint(allocator);
    defer allocator.free(request_str);

    const expected =
        "GET /api/v1/users?id=123 HTTP/1.1\r\n" ++
        "Connection: close\r\n" ++
        "Host: example.com\r\n\r\n";
    try testing.expectEqualStrings(expected, request_str);
}
