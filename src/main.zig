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

        handleRequest(allocator, connection) catch |err| {
            print("Error handling request: {}\n", .{err});
        };
    }
}

fn handleRequest(allocator: std.mem.Allocator, client_connection: net.Server.Connection) !void {
    defer client_connection.stream.close();

    var buffer: [8192]u8 = undefined;
    const bytes_read = try client_connection.stream.read(&buffer);

    if (bytes_read == 0) return;

    const request = buffer[0..bytes_read];
    print("Proxying request ({} bytes)\n", .{bytes_read});

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

    _ = try target_connection.writeAll(request);

    var response_buffer: [8192]u8 = undefined;
    while (true) {
        const response_bytes = target_connection.read(&response_buffer) catch 0;

        if (response_bytes == 0) break;

        _ = try client_connection.stream.writeAll(response_buffer[0..response_bytes]);
    }
}
