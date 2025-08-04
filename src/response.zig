const std = @import("std");

pub fn buildSimpleResponse() []const u8 {
    return "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 25\r\n" ++
        "Connection: close\r\n" ++
        "Server: libxev-proxy/1.0\r\n" ++
        "\r\n" ++
        "Hello from chunked proxy!";
}

pub fn buildErrorResponse(status_code: u16) []const u8 {
    return switch (status_code) {
        400 => "HTTP/1.1 400 Bad Request\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Content-Length: 11\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "Bad Request",
        502 => "HTTP/1.1 502 Bad Gateway\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Content-Length: 19\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "502 Bad Gateway",
        else => "HTTP/1.1 500 Internal Server Error\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Content-Length: 21\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "Internal Server Error",
    };
}

