const std = @import("std");

pub fn main() !void {
    // var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    // defer std.debug.assert(gpa_alloc.deinit() == .ok);
    // const gpa = gpa_alloc.allocator();

    const ipAddress = "0.0.0.0";
    const port = 3000;
    const address = try std.net.Address.resolveIp(ipAddress, port);
    std.debug.print("Listening on http://{s}:{d}\n", .{ ipAddress, port });

    var server = try address.listen(.{});

    while (true) {
        const connection = try server.accept();
        defer connection.stream.close();

        var buf: [1024]u8 = undefined;
        _ = try connection.stream.readAll(&buf);

        const response =
            \\HTTP/1.1 200 OK
            \\Content-Type: text/plain
            \\Content-Length: 13
            \\
            \\Hello, World!
        ;

        _ = try server.stream.write(response);
    }
}

test "simple test" {
    try std.testing.expectEqual(42, 42);
}
