const std = @import("std");
const log = std.log;
const HeaderMap = @import("header_map.zig").HeaderMap;

// Extended method support for better HTTP compliance
pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    HEAD,
    OPTIONS,
    PATCH,

    pub fn print(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
            .PATCH => "PATCH",
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
    headers: HeaderMap,

    pub fn init(allocator: std.mem.Allocator, method: Method, pathname: []const u8, host: []const u8) !Request {
        var headers = HeaderMap.init(allocator);
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

pub const ParseRequestError = error{
    InvalidRequest,
    IncompleteRequest,
    TooManyHeaders,
    MissingHostHeader,
    UnsupportedTransferEncoding,
    InvalidHttpVersion,
    HeaderTooLarge,
    OutOfMemory,
};

pub const ParseResult = struct {
    request: Request,
    end_index: u64,
};

// Enhanced HTTP request parser with robust validation and security checks
pub fn parseRequest(allocator: std.mem.Allocator, request: []u8) ParseRequestError!ParseResult {
    if (request.len == 0) return ParseRequestError.InvalidRequest;

    // Check if we have the complete headers section (double CRLF)
    const headers_end_idx = std.mem.indexOf(u8, request, crlf ++ crlf) orelse return ParseRequestError.IncompleteRequest;

    const headers_section = request[0..headers_end_idx];
    const body_start = headers_end_idx + 4; // Skip the double CRLF
    const body = if (body_start < request.len) request[body_start..] else "";

    var end_index: u64 = headers_end_idx + 3;

    // Validate that we have at least a request line
    var headers_iterator = std.mem.tokenizeSequence(u8, headers_section, crlf);
    const request_line = headers_iterator.next() orelse return ParseRequestError.IncompleteRequest;

    // Parse and validate request line format - must have exactly 3 parts
    var request_parts_iterator = std.mem.splitSequence(u8, request_line, " ");
    const method_str = request_parts_iterator.next() orelse return ParseRequestError.InvalidRequest;
    const pathname = request_parts_iterator.next() orelse return ParseRequestError.InvalidRequest;
    const http_version = request_parts_iterator.next() orelse return ParseRequestError.InvalidRequest;

    // Ensure no extra parts in request line
    if (request_parts_iterator.next() != null) return ParseRequestError.InvalidRequest;

    // Validate HTTP version
    if (!std.mem.eql(u8, http_version, "HTTP/1.1") and !std.mem.eql(u8, http_version, "HTTP/1.0")) {
        return ParseRequestError.InvalidHttpVersion;
    }

    // Validate method
    const method = std.meta.stringToEnum(Method, method_str) orelse return ParseRequestError.InvalidRequest;

    // Basic URI validation - must start with /
    if (pathname.len == 0 or pathname[0] != '/') {
        return ParseRequestError.InvalidRequest;
    }

    var headers_hash = HeaderMap.init(allocator);
    errdefer headers_hash.deinit(); // Clean up on error
    var header_count: u32 = 0;
    const max_headers = 100; // Security limit
    const max_header_size = 8 * 1024; // 8KB per header

    while (headers_iterator.next()) |header| {
        header_count += 1;
        if (header_count > max_headers) return ParseRequestError.TooManyHeaders;
        if (header.len > max_header_size) return ParseRequestError.HeaderTooLarge;

        // Find colon separator (more flexible than ": ")
        const colon_idx = std.mem.indexOf(u8, header, ":") orelse return ParseRequestError.InvalidRequest;
        const key = std.mem.trim(u8, header[0..colon_idx], " \t");
        const value = std.mem.trim(u8, header[colon_idx + 1 ..], " \t");

        if (key.len == 0) return ParseRequestError.InvalidRequest;

        try headers_hash.put(key, value);
    }

    // Check for required Host header in HTTP/1.1 (case-insensitive)
    if (std.mem.eql(u8, http_version, "HTTP/1.1")) {
        if (!headers_hash.contains("host")) {
            return ParseRequestError.MissingHostHeader;
        }
    }

    // Validate Content-Length and check for complete body
    if (headers_hash.get("content-length")) |content_length_str| {
        const content_length = std.fmt.parseInt(u64, content_length_str, 10) catch return ParseRequestError.InvalidRequest;

        // Check if we have received the complete body
        if (content_length > body.len) {
            return ParseRequestError.IncompleteRequest;
        }
        if (content_length > 0) {
            end_index = body_start + content_length - 1;
        }

        // For methods that shouldn't have a body, validate Content-Length is 0
        if ((method == .GET or method == .HEAD or method == .DELETE) and content_length > 0) {
            return ParseRequestError.InvalidRequest;
        }
    } else if (method != .GET and method != .HEAD and method != .DELETE) {
        // Non-body-less methods without Content-Length might be incomplete
        // unless they use chunked encoding
        if (headers_hash.get("transfer-encoding")) |encoding| {
            if (!std.mem.eql(u8, encoding, "chunked")) {
                return ParseRequestError.UnsupportedTransferEncoding;
            }
            // TODO: Implement chunked encoding validation
            // For now, assume chunked requests are complete if we have double CRLF
        }
    }

    return ParseResult{
        .request = Request{
            .allocator = allocator,
            .method = method,
            .pathname = pathname,
            .headers = headers_hash,
        },
        .end_index = end_index,
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
        "Host: example.com\r\n" ++
        "Connection: close\r\n\r\n";
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
        "Host: api.example.com\r\n" ++
        "Connection: close\r\n\r\n";
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
        "Host: example.com\r\n" ++
        "Connection: close\r\n\r\n";
    try testing.expectEqualStrings(expected, request_str);
}

// Tests for parseRequest function

test "parseRequest with empty request" {
    const allocator = std.testing.allocator;
    var empty_request = [_]u8{};
    const err = parseRequest(allocator, &empty_request);
    try testing.expectError(ParseRequestError.InvalidRequest, err);
}

test "parseRequest with incomplete request - no headers end" {
    const allocator = std.testing.allocator;
    var incomplete_request = "GET /test HTTP/1.1\r\nHost: example.com".*;
    const err = parseRequest(allocator, &incomplete_request);
    try testing.expectError(ParseRequestError.IncompleteRequest, err);
}

test "parseRequest with incomplete request - only request line" {
    const allocator = std.testing.allocator;
    var incomplete_request = "GET /test HTTP/1.1".*;
    const err = parseRequest(allocator, &incomplete_request);
    try testing.expectError(ParseRequestError.IncompleteRequest, err);
}

test "parseRequest with incomplete request - missing double CRLF" {
    const allocator = std.testing.allocator;
    var incomplete_request = "GET /test HTTP/1.1\r\nHost: example.com\r\n".*;
    const err = parseRequest(allocator, &incomplete_request);
    try testing.expectError(ParseRequestError.IncompleteRequest, err);
}

test "parseRequest with valid GET request" {
    const allocator = std.testing.allocator;
    var valid_request = "GET /test HTTP/1.1\r\nHost: example.com\r\n\r\n".*;
    var result = try parseRequest(allocator, &valid_request);
    defer result.request.deinit();

    const req = result.request;
    try testing.expectEqual(Method.GET, req.method);
    try testing.expectEqualStrings("/test", req.pathname);
    try testing.expectEqualStrings("example.com", req.headers.get("host").?);
    try testing.expectEqual(@as(u64, valid_request.len - 1), result.end_index);
}

test "parseRequest with valid POST request with body" {
    const allocator = std.testing.allocator;
    var valid_request = "POST /api/data HTTP/1.1\r\nHost: api.example.com\r\nContent-Length: 13\r\n\r\nHello, World!".*;
    var result = try parseRequest(allocator, &valid_request);
    defer result.request.deinit();

    const req = result.request;
    try testing.expectEqual(Method.POST, req.method);
    try testing.expectEqualStrings("/api/data", req.pathname);
    try testing.expectEqualStrings("api.example.com", req.headers.get("host").?);
    try testing.expectEqualStrings("13", req.headers.get("content-length").?);
    try testing.expectEqual(@as(u64, valid_request.len - 1), result.end_index);
}

test "parseRequest with invalid request line - missing parts" {
    const allocator = std.testing.allocator;
    var invalid_request = "GET HTTP/1.1\r\nHost: example.com\r\n\r\n".*;
    const err = parseRequest(allocator, &invalid_request);
    try testing.expectError(ParseRequestError.InvalidRequest, err);
}

test "parseRequest with invalid request line - too many parts" {
    const allocator = std.testing.allocator;
    var invalid_request = "GET /test HTTP/1.1 extra\r\nHost: example.com\r\n\r\n".*;
    const err = parseRequest(allocator, &invalid_request);
    try testing.expectError(ParseRequestError.InvalidRequest, err);
}

test "parseRequest with invalid HTTP version" {
    const allocator = std.testing.allocator;
    var invalid_request = "GET /test HTTP/2.0\r\nHost: example.com\r\n\r\n".*;
    const err = parseRequest(allocator, &invalid_request);
    try testing.expectError(ParseRequestError.InvalidHttpVersion, err);
}

test "parseRequest with invalid method" {
    const allocator = std.testing.allocator;
    var invalid_request = "INVALID /test HTTP/1.1\r\nHost: example.com\r\n\r\n".*;
    const err = parseRequest(allocator, &invalid_request);
    try testing.expectError(ParseRequestError.InvalidRequest, err);
}

test "parseRequest with invalid pathname - not starting with slash" {
    const allocator = std.testing.allocator;
    var invalid_request = "GET test HTTP/1.1\r\nHost: example.com\r\n\r\n".*;
    const err = parseRequest(allocator, &invalid_request);
    try testing.expectError(ParseRequestError.InvalidRequest, err);
}

test "parseRequest with missing Host header in HTTP/1.1" {
    const allocator = std.testing.allocator;
    var invalid_request = "GET /test HTTP/1.1\r\nConnection: close\r\n\r\n".*;
    const err = parseRequest(allocator, &invalid_request);
    try testing.expectError(ParseRequestError.MissingHostHeader, err);
}

test "parseRequest with HTTP/1.0 without Host header - should pass" {
    const allocator = std.testing.allocator;
    var valid_request = "GET /test HTTP/1.0\r\nConnection: close\r\n\r\n".*;
    var result = try parseRequest(allocator, &valid_request);
    defer result.request.deinit();

    const req = result.request;
    try testing.expectEqual(Method.GET, req.method);
    try testing.expectEqualStrings("/test", req.pathname);
    try testing.expectEqual(@as(u64, valid_request.len - 1), result.end_index);
}

test "parseRequest with too many headers" {
    const allocator = std.testing.allocator;
    var request_builder = std.ArrayList(u8).init(allocator);
    defer request_builder.deinit();

    try request_builder.appendSlice("GET /test HTTP/1.1\r\nHost: example.com\r\n");
    
    // Add 101 headers (exceeds the 100 limit)
    var i: u32 = 0;
    while (i < 101) : (i += 1) {
        try request_builder.writer().print("Header{}: value{}\r\n", .{ i, i });
    }
    try request_builder.appendSlice("\r\n");

    const err = parseRequest(allocator, request_builder.items);
    try testing.expectError(ParseRequestError.TooManyHeaders, err);
}

test "parseRequest with header too large" {
    const allocator = std.testing.allocator;
    var request_builder = std.ArrayList(u8).init(allocator);
    defer request_builder.deinit();

    try request_builder.appendSlice("GET /test HTTP/1.1\r\nHost: example.com\r\n");
    
    // Create a header larger than 8KB
    try request_builder.appendSlice("Large-Header: ");
    var j: u32 = 0;
    while (j < 9000) : (j += 1) {
        try request_builder.append('x');
    }
    try request_builder.appendSlice("\r\n\r\n");

    const err = parseRequest(allocator, request_builder.items);
    try testing.expectError(ParseRequestError.HeaderTooLarge, err);
}

test "parseRequest with invalid header format - no colon" {
    const allocator = std.testing.allocator;
    var invalid_request = "GET /test HTTP/1.1\r\nHost example.com\r\n\r\n".*;
    const err = parseRequest(allocator, &invalid_request);
    try testing.expectError(ParseRequestError.InvalidRequest, err);
}

test "parseRequest with invalid header format - empty key" {
    const allocator = std.testing.allocator;
    var invalid_request = "GET /test HTTP/1.1\r\nHost: example.com\r\n: empty-key\r\n\r\n".*;
    const err = parseRequest(allocator, &invalid_request);
    try testing.expectError(ParseRequestError.InvalidRequest, err);
}

test "parseRequest with GET request having Content-Length - should fail" {
    const allocator = std.testing.allocator;
    var invalid_request = "GET /test HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nhello".*;
    const err = parseRequest(allocator, &invalid_request);
    try testing.expectError(ParseRequestError.InvalidRequest, err);
}

test "parseRequest with POST request with incomplete body" {
    const allocator = std.testing.allocator;
    var incomplete_request = "POST /test HTTP/1.1\r\nHost: example.com\r\nContent-Length: 10\r\n\r\nhello".*;
    const err = parseRequest(allocator, &incomplete_request);
    try testing.expectError(ParseRequestError.IncompleteRequest, err);
}

test "parseRequest with POST request with complete body" {
    const allocator = std.testing.allocator;
    var valid_request = "POST /test HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nhello".*;
    var result = try parseRequest(allocator, &valid_request);
    defer result.request.deinit();

    const req = result.request;
    try testing.expectEqual(Method.POST, req.method);
    try testing.expectEqualStrings("/test", req.pathname);
    try testing.expectEqualStrings("5", req.headers.get("content-length").?);
    try testing.expectEqual(@as(u64, valid_request.len - 1), result.end_index);
}

test "parseRequest with chunked transfer encoding" {
    const allocator = std.testing.allocator;
    var valid_request = "POST /test HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n".*;
    var result = try parseRequest(allocator, &valid_request);
    defer result.request.deinit();

    const req = result.request;
    try testing.expectEqual(Method.POST, req.method);
    try testing.expectEqualStrings("chunked", req.headers.get("transfer-encoding").?);
    try testing.expectEqual(@as(u64, valid_request.len - 1), result.end_index);
}

test "parseRequest with unsupported transfer encoding" {
    const allocator = std.testing.allocator;
    var invalid_request = "POST /test HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: gzip\r\n\r\n".*;
    const err = parseRequest(allocator, &invalid_request);
    try testing.expectError(ParseRequestError.UnsupportedTransferEncoding, err);
}

test "parseRequest with multiple requests in one chunk - first request only" {
    const allocator = std.testing.allocator;
    // Two complete requests concatenated
    var multiple_requests = "GET /first HTTP/1.1\r\nHost: example.com\r\n\r\nGET /second HTTP/1.1\r\nHost: example.com\r\n\r\n".*;
    var result = try parseRequest(allocator, &multiple_requests);
    defer result.request.deinit();

    // Should only parse the first request
    const req = result.request;
    try testing.expectEqual(Method.GET, req.method);
    try testing.expectEqualStrings("/first", req.pathname);
    try testing.expectEqualStrings("example.com", req.headers.get("host").?);
    try testing.expectEqual(41, result.end_index);
}

test "parseRequest with headers containing whitespace" {
    const allocator = std.testing.allocator;
    var valid_request = "GET /test HTTP/1.1\r\n  Host  :  example.com  \r\nUser-Agent: test-agent\r\n\r\n".*;
    var result = try parseRequest(allocator, &valid_request);
    defer result.request.deinit();

    const req = result.request;
    try testing.expectEqualStrings("example.com", req.headers.get("Host").?);
    try testing.expectEqualStrings("test-agent", req.headers.get("User-Agent").?);
    try testing.expectEqual(@as(u64, valid_request.len - 1), result.end_index);
}

test "parseRequest with various HTTP methods" {
    const allocator = std.testing.allocator;
    
    const methods = [_]struct { str: []const u8, method: Method }{
        .{ .str = "PUT", .method = .PUT },
        .{ .str = "DELETE", .method = .DELETE },
        .{ .str = "HEAD", .method = .HEAD },
        .{ .str = "OPTIONS", .method = .OPTIONS },
        .{ .str = "PATCH", .method = .PATCH },
    };

    for (methods) |test_case| {
        var request_builder = std.ArrayList(u8).init(allocator);
        defer request_builder.deinit();
        
        try request_builder.writer().print("{s} /test HTTP/1.1\r\nHost: example.com\r\n\r\n", .{test_case.str});
        
        var result = try parseRequest(allocator, request_builder.items);
        defer result.request.deinit();
        const req = result.request;
        
        try testing.expectEqual(test_case.method, req.method);
        try testing.expectEqual(@as(u64, request_builder.items.len - 1), result.end_index);
    }
}
