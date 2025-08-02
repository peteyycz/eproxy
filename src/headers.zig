const std = @import("std");
const net = std.net;

// TODO: this should be configurable
const CHUNK_SIZE = 1024;
const HEADER_SIZE_LIMIT = 16384; // 16KB

pub const HeaderMap = std.StringArrayHashMap([]const u8);

pub const ReadHeaderReadResult = struct {
    headers: []const u8,
    body_overshoot: []const u8,
    allocator: std.mem.Allocator,
    buffer: []u8, // Keep reference to the original buffer for cleanup

    // Helper to get total bytes read
    pub fn totalSize(self: @This()) usize {
        return self.headers.len + self.body_overshoot.len;
    }

    // Zig's destructor pattern
    pub fn deinit(self: @This()) void {
        self.allocator.free(self.buffer);
    }
};

const HEADER_KEY_VALUE_SEPARATOR = ":";
const CRLF = "\r\n";
const HEADER_LINE_SEPARATOR = CRLF;
const HEADER_BODY_SEPARATOR = CRLF ++ CRLF;

pub fn read(allocator: std.mem.Allocator, stream: net.Stream) !ReadHeaderReadResult {
    var buffer = std.ArrayList(u8).init(allocator);
    var headers_complete = false;
    var chunk_buffer: [CHUNK_SIZE]u8 = undefined;
    var headers_end_pos: usize = 0;

    while (!headers_complete) {
        const bytes_read = try stream.read(&chunk_buffer);
        if (bytes_read == 0) break;

        const previous_len = buffer.items.len;
        try buffer.appendSlice(chunk_buffer[0..bytes_read]);

        // Look for double CRLF starting from safe position to handle boundary cases
        const search_start = if (previous_len >= 3) previous_len - 3 else 0;
        if (std.mem.indexOf(u8, buffer.items[search_start..], HEADER_BODY_SEPARATOR)) |relative_pos| {
            headers_complete = true;
            headers_end_pos = search_start + relative_pos + 4;
            break;
        }

        if (buffer.items.len > HEADER_SIZE_LIMIT) {
            return error.HeadersTooLarge;
        }
    }

    // Transfer ownership of the buffer to the result
    const owned_buffer = try buffer.toOwnedSlice();

    return ReadHeaderReadResult{
        .headers = owned_buffer[0..headers_end_pos],
        .body_overshoot = owned_buffer[headers_end_pos..],
        .allocator = allocator,
        .buffer = owned_buffer,
    };
}

pub const Headers = struct {
    map: HeaderMap,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *@This()) void {
        // Free all the allocated lowercase header names
        var iterator = self.map.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.map.deinit();
    }

    // Comptime header getter generator
    pub fn getHeader(self: *const @This(), comptime header_name: []const u8) ?[]const u8 {
        // Generate lowercase version at compile time as a constant
        const lowercase_name = comptime blk: {
            var result: [header_name.len]u8 = undefined;
            for (header_name, 0..) |char, i| {
                result[i] = std.ascii.toLower(char);
            }
            break :blk result;
        };

        if (self.map.get(&lowercase_name)) |value| {
            return std.mem.trim(u8, value, " \t");
        }
        return null;
    }

    pub fn getContentLength(self: *const @This()) usize {
        if (self.getHeader("Content-Length")) |value| {
            return std.fmt.parseInt(usize, value, 10) catch 0;
        }
        return 0;
    }

    pub fn shouldCloseConnection(self: *const @This()) bool {
        if (self.getHeader("Connection")) |value| {
            return std.ascii.eqlIgnoreCase(value, "close");
        }
        return false;
    }

    pub fn getHost(self: *const @This()) ?[]const u8 {
        return self.getHeader("Host");
    }

    pub fn getUserAgent(self: *const @This()) ?[]const u8 {
        return self.getHeader("User-Agent");
    }

    pub fn getContentType(self: *const @This()) ?[]const u8 {
        return self.getHeader("Content-Type");
    }
};

pub fn parse(allocator: std.mem.Allocator, headers: []const u8) !Headers {
    var header_map = HeaderMap.init(allocator);
    var lines = std.mem.splitSequence(u8, headers, HEADER_LINE_SEPARATOR);

    // Skip the first line (status line for responses, request line for requests)
    _ = lines.next();

    while (lines.next()) |line| {
        if (line.len == 0) break; // Empty line indicates end of headers

        if (std.mem.indexOf(u8, line, HEADER_KEY_VALUE_SEPARATOR)) |colon_pos| {
            const name = line[0..colon_pos];
            const value = line[colon_pos + 1 ..];

            // Trim header name and store in lowercase for case-insensitive lookup
            const trimmed_name = std.mem.trim(u8, name, " \t");
            var lowercase_name = try allocator.alloc(u8, trimmed_name.len);
            for (trimmed_name, 0..) |char, i| {
                lowercase_name[i] = std.ascii.toLower(char);
            }

            try header_map.put(lowercase_name, value);
        }
    }

    return Headers{
        .map = header_map,
        .allocator = allocator,
    };
}
