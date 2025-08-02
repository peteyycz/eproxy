const std = @import("std");
const net = std.net;
const print = std.debug.print;
const headers = @import("headers.zig");

const PROXY_HOST = "localhost";
const PROXY_PORT = 9000;
const LISTEN_PORT = 8080;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const address = try net.Address.parseIp("127.0.0.1", LISTEN_PORT);
    var server = try address.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    print("Reverse proxy listening on http://127.0.0.1:{}\n", .{LISTEN_PORT});
    print("Proxying requests to {s}:{}\n", .{ PROXY_HOST, PROXY_PORT });

    while (true) {
        print("Waiting for connection...\n", .{});
        const connection = server.accept() catch |err| {
            print("Failed to accept connection: {}\n", .{err});
            continue;
        };
        print("Accepted connection from {}\n", .{connection.address});

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        handleRequest(arena.allocator(), connection) catch |err| {
            print("Error handling request: {}\n", .{err});
        };
        print("Request completed, ready for next connection\n", .{});
    }
}

fn handleRequest(allocator: std.mem.Allocator, client_connection: net.Server.Connection) !void {
    defer {
        print("Closing client connection\n", .{});
        client_connection.stream.close();
    }

    print("Starting to read headers...\n", .{});
    // Read headers using the refactored function
    const header_result = headers.readHeaders(allocator, client_connection.stream) catch |err| {
        print("Failed to read headers: {}\n", .{err});
        return;
    };
    defer header_result.deinit();
    print("Headers read successfully\n", .{});

    const request_headers = header_result.headers;
    const body_already_read = header_result.body_overshoot;

    // Parse request headers into a map
    var request_header_map = headers.parseHeaderMap(allocator, request_headers) catch |err| {
        print("Failed to parse request headers: {}\n", .{err});
        return;
    };
    defer request_header_map.deinit();

    // Parse Content-Length from headers
    const content_length = request_header_map.getContentLength();

    // Allocate buffer for complete request
    const total_size = request_headers.len + content_length;
    const request_buffer = try allocator.alloc(u8, total_size);
    defer allocator.free(request_buffer);

    // Copy headers
    @memcpy(request_buffer[0..request_headers.len], request_headers);

    // Copy body data we already read
    @memcpy(request_buffer[request_headers.len .. request_headers.len + body_already_read.len], body_already_read);

    // TODO: Read the rest of the body in chunks instead of all at once, better yet start streaming
    if (content_length > 0) {
        var body_pos = body_already_read.len;
        while (body_pos < content_length) {
            const bytes_read = try client_connection.stream.read(request_buffer[request_headers.len + body_pos ..]);
            if (bytes_read == 0) break;
            body_pos += bytes_read;
        }
    }

    print("Proxying request ({} bytes: {} headers + {} body, {} pre-read)\n", .{ total_size, request_headers.len, content_length, body_already_read.len });

    print("Attempting to connect to {s}:{}\n", .{ PROXY_HOST, PROXY_PORT });
    const target_connection = net.tcpConnectToHost(allocator, PROXY_HOST, PROXY_PORT) catch |err| {
        print("Failed to connect to target server: {}\n", .{err});
        const error_response =
            \\HTTP/1.1 502 Bad Gateway
            \\Content-Type: text/plain
            \\Content-Length: 19
            \\Connection: close
            \\
            \\502 Bad Gateway
        ;
        _ = try client_connection.stream.writeAll(error_response);
        return;
    };
    defer target_connection.close();
    print("Connected to target server successfully\n", .{});

    print("Sending request to target ({} bytes)\n", .{request_buffer.len});
    _ = try target_connection.writeAll(request_buffer);
    print("Request sent, reading response headers\n", .{});

    // Read response headers first
    const response_header_result = headers.readHeaders(allocator, target_connection) catch |err| {
        print("Failed to read response headers: {}\n", .{err});
        return;
    };
    defer response_header_result.deinit();

    print("Response headers read, forwarding to client\n", .{});

    // Forward response headers to client
    _ = try client_connection.stream.writeAll(response_header_result.headers);

    // Forward any response body we already read
    if (response_header_result.body_overshoot.len > 0) {
        _ = try client_connection.stream.writeAll(response_header_result.body_overshoot);
    }

    // Parse response headers into a map
    var response_header_map = headers.parseHeaderMap(allocator, response_header_result.headers) catch |err| {
        print("Failed to parse response headers: {}\n", .{err});
        return;
    };
    defer response_header_map.deinit();

    // Parse response to determine how to handle body
    const response_content_length = response_header_map.getContentLength();
    const should_close = response_header_map.shouldCloseConnection();

    print("Response: Content-Length={}, Connection-Close={}\n", .{ response_content_length, should_close });

    // Handle response body based on Content-Length
    if (response_content_length > 0) {
        // Read exactly content_length bytes
        var remaining = response_content_length - response_header_result.body_overshoot.len;
        var response_buffer: [8192]u8 = undefined;
        while (remaining > 0) {
            const to_read = @min(remaining, response_buffer.len);
            const response_bytes = target_connection.read(response_buffer[0..to_read]) catch 0;
            if (response_bytes == 0) break;
            _ = try client_connection.stream.writeAll(response_buffer[0..response_bytes]);
            remaining -= response_bytes;
        }
        print("Response body forwarded ({} bytes)\n", .{response_content_length});
    } else {
        // No content-length, read until connection closes
        print("No content-length, reading until close\n", .{});
        var response_buffer: [8192]u8 = undefined;
        while (true) {
            const response_bytes = target_connection.read(&response_buffer) catch 0;
            if (response_bytes == 0) break;
            _ = try client_connection.stream.writeAll(response_buffer[0..response_bytes]);
        }
    }
}
