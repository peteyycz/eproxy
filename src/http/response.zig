const std = @import("std");

// Static header constants to avoid allocations
const content_length_header: []const u8 = "Content-Length";
const content_type_header: []const u8 = "Content-Type";
const content_type_text_plain: []const u8 = "text/plain";

pub const HttpResponse = struct {
    status_code: u16,
    status_text: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    allocator: std.mem.Allocator,
    // Track which header values need freeing
    allocated_header_values: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, status_code: u16, body: []const u8) !HttpResponse {
        const status_text = switch (status_code) {
            200 => "OK",
            404 => "Not Found",
            500 => "Internal Server Error",
            else => "Unknown",
        };

        var headers = std.StringHashMap([]const u8).init(allocator);
        var allocated_header_values = std.ArrayList([]const u8).init(allocator);

        // Allocate Content-Length value but use static strings for keys and Content-Type value
        const content_length_value = try std.fmt.allocPrint(allocator, "{d}", .{body.len});
        try allocated_header_values.append(content_length_value);

        try headers.put(content_length_header, content_length_value);
        try headers.put(content_type_header, content_type_text_plain);

        return HttpResponse{
            .status_code = status_code,
            .status_text = status_text,
            .headers = headers,
            .body = try allocator.dupe(u8, body),
            .allocator = allocator,
            .allocated_header_values = allocated_header_values,
        };
    }

    pub fn deinit(self: *HttpResponse) void {
        // Only free the values we explicitly allocated
        for (self.allocated_header_values.items) |value| {
            self.allocator.free(value);
        }
        self.allocated_header_values.deinit();
        self.headers.deinit();
        self.allocator.free(self.body);
    }

    pub fn toBytes(self: *const HttpResponse, allocator: std.mem.Allocator) ![]u8 {
        var response_parts = std.ArrayList([]const u8).init(allocator);
        defer response_parts.deinit();

        // Status line
        const status_line = try std.fmt.allocPrint(allocator, "HTTP/1.1 {d} {s}\r\n", .{ self.status_code, self.status_text });
        try response_parts.append(status_line);

        // Headers
        var iter = self.headers.iterator();
        while (iter.next()) |entry| {
            const header_line = try std.fmt.allocPrint(allocator, "{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            try response_parts.append(header_line);
        }

        // Empty line before body
        try response_parts.append("\r\n");

        // Body
        try response_parts.append(self.body);

        // Concatenate all parts
        var total_len: usize = 0;
        for (response_parts.items) |part| {
            total_len += part.len;
        }

        const result = try allocator.alloc(u8, total_len);
        var pos: usize = 0;
        for (response_parts.items) |part| {
            @memcpy(result[pos .. pos + part.len], part);
            pos += part.len;
        }

        return result;
    }
};
