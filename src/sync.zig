const std = @import("std");
const net = std.net;
const log = std.log;
const headers = @import("headers.zig");

const PROXY_HOST = "localhost";
const PROXY_PORT = 9000;

pub fn handleRequest(arena_allocator: std.mem.Allocator, client_connection: net.Server.Connection) !void {
    defer {
        log.debug("Closing client connection", .{});
        client_connection.stream.close();
    }

    // Read headers using the refactored function
    const header_result = headers.read(arena_allocator, client_connection.stream) catch |err| {
        log.err("Failed to read headers: {}", .{err});
        return;
    };
    defer header_result.deinit();

    const raw_request_headers = header_result.headers;
    const body_already_read = header_result.body_overshoot;

    // Parse request headers into a map
    var request_headers = headers.parse(arena_allocator, raw_request_headers) catch |err| {
        log.err("Failed to parse request headers: {}", .{err});
        return;
    };
    defer request_headers.deinit();

    // Parse Content-Length from headers
    const content_length = request_headers.getContentLength();

    // Allocate buffer for complete request
    const total_size = raw_request_headers.len + content_length;
    const request_buffer = try arena_allocator.alloc(u8, total_size);

    // Copy headers
    @memcpy(request_buffer[0..raw_request_headers.len], raw_request_headers);

    // Copy body data we already read
    @memcpy(request_buffer[raw_request_headers.len .. raw_request_headers.len + body_already_read.len], body_already_read);

    // TODO: Read the rest of the body in chunks instead of all at once, better yet start streaming
    if (content_length > 0) {
        var body_pos = body_already_read.len;
        while (body_pos < content_length) {
            const bytes_read = try client_connection.stream.read(request_buffer[raw_request_headers.len + body_pos ..]);
            if (bytes_read == 0) break;
            body_pos += bytes_read;
        }
    }

    const target_connection = net.tcpConnectToHost(arena_allocator, PROXY_HOST, PROXY_PORT) catch |err| {
        log.err("Failed to connect to target server: {}", .{err});
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

    _ = try target_connection.writeAll(request_buffer);

    // Read response headers first
    const response_header_result = headers.read(arena_allocator, target_connection) catch |err| {
        log.err("Failed to read response headers: {}", .{err});
        return;
    };
    defer response_header_result.deinit();

    // Forward response headers to client
    _ = try client_connection.stream.writeAll(response_header_result.headers);

    // Forward any response body we already read
    if (response_header_result.body_overshoot.len > 0) {
        _ = try client_connection.stream.writeAll(response_header_result.body_overshoot);
    }

    // Parse response headers into a map
    var response_headers = headers.parse(arena_allocator, response_header_result.headers) catch |err| {
        log.err("Failed to parse response headers: {}", .{err});
        return;
    };
    defer response_headers.deinit();

    // Parse response to determine how to handle body
    const response_content_length = response_headers.getContentLength();

    // Handle response body based on Content-Length
    if (response_content_length > 0) {
        // Read exactly content_length bytes
        var remaining = response_content_length - response_header_result.body_overshoot.len;
        var response_buffer: [8192]u8 = undefined;
        while (remaining > 0) {
            // TODO: Chunked reading
            const to_read = @min(remaining, response_buffer.len);
            const response_bytes = target_connection.read(response_buffer[0..to_read]) catch 0;
            if (response_bytes == 0) break;
            _ = try client_connection.stream.writeAll(response_buffer[0..response_bytes]);
            remaining -= response_bytes;
        }
        log.info("Response body forwarded ({} bytes)", .{response_content_length});
    } else {
        // No content-length, read until connection closes
        log.debug("No content-length, reading until close", .{});
        var response_buffer: [8192]u8 = undefined;
        while (true) {
            const response_bytes = target_connection.read(&response_buffer) catch 0;
            if (response_bytes == 0) break;
            _ = try client_connection.stream.writeAll(response_buffer[0..response_bytes]);
        }
    }
}
