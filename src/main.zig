const std = @import("std");
const net = std.net;
const print = std.debug.print;

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
        const connection = server.accept() catch |err| {
            print("Failed to accept connection: {}\n", .{err});
            continue;
        };

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        handleRequest(arena.allocator(), connection) catch |err| {
            print("Error handling request: {}\n", .{err});
        };
    }
}

const CHUNK_SIZE = 1024;
const HEADER_SIZE_LIMIT = 16384; // 16KB

fn handleRequest(allocator: std.mem.Allocator, client_connection: net.Server.Connection) !void {
    defer client_connection.stream.close();

    // Read headers with chunked buffering
    var header_list = std.ArrayList(u8).init(allocator);
    defer header_list.deinit();
    var headers_complete = false;
    var chunk_buffer: [CHUNK_SIZE]u8 = undefined;
    var body_start_pos: usize = 0;

    while (!headers_complete) {
        const bytes_read = try client_connection.stream.read(&chunk_buffer);
        if (bytes_read == 0) break;

        const previous_len = header_list.items.len;
        try header_list.appendSlice(chunk_buffer[0..bytes_read]);

        // Look for \r\n\r\n starting from reasonable position to handle boundary cases
        const search_start = if (previous_len >= 3) previous_len - 3 else 0;
        if (std.mem.indexOf(u8, header_list.items[search_start..], "\r\n\r\n")) |relative_pos| {
            headers_complete = true;
            body_start_pos = search_start + relative_pos + 4;
            break;
        }

        if (header_list.items.len > HEADER_SIZE_LIMIT) {
            print("Headers too large (> {})\n", .{std.fmt.fmtIntSizeDec(HEADER_SIZE_LIMIT)});
            return;
        }
    }

    // Extract headers and any body data we accidentally read
    const headers = header_list.items[0..body_start_pos];
    const body_already_read = header_list.items[body_start_pos..];
    print("Received headers:\n{s}\n", .{headers});

    // Parse Content-Length from headers
    var content_length: usize = 0;
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const value_start = std.mem.indexOf(u8, line, ":").? + 1;
            const value = std.mem.trim(u8, line[value_start..], " \t");
            content_length = std.fmt.parseInt(usize, value, 10) catch 0;
            break;
        }
    }

    // Allocate buffer for complete request
    const total_size = body_start_pos + content_length;
    const request_buffer = try allocator.alloc(u8, total_size);
    defer allocator.free(request_buffer);

    // Copy headers
    @memcpy(request_buffer[0..body_start_pos], headers);

    // Copy body data we already read
    @memcpy(request_buffer[body_start_pos .. body_start_pos + body_already_read.len], body_already_read);

    // Read remaining body data if needed
    if (content_length > 0) {
        var body_pos = body_already_read.len;
        while (body_pos < content_length) {
            const bytes_read = try client_connection.stream.read(request_buffer[body_start_pos + body_pos ..]);
            if (bytes_read == 0) break;
            body_pos += bytes_read;
        }
    }

    print("Proxying request ({} bytes: {} headers + {} body, {} pre-read)\n", .{ total_size, headers.len, content_length, body_already_read.len });

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

    _ = try target_connection.writeAll(request_buffer);

    var response_buffer: [8192]u8 = undefined;
    while (true) {
        const response_bytes = target_connection.read(&response_buffer) catch 0;

        if (response_bytes == 0) break;

        _ = try client_connection.stream.writeAll(response_buffer[0..response_bytes]);
    }
}
