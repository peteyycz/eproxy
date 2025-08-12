const std = @import("std");

/// Context for case-insensitive string hashing and equality
const CaseInsensitiveStringContext = struct {
    pub fn hash(self: @This(), s: []const u8) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);
        for (s) |c| {
            hasher.update(&[_]u8{std.ascii.toLower(c)});
        }
        return hasher.final();
    }

    pub fn eql(self: @This(), a: []const u8, b: []const u8) bool {
        _ = self;
        return std.ascii.eqlIgnoreCase(a, b);
    }
};

/// Case-insensitive HashMap for HTTP headers
pub const HeaderMap = std.HashMap([]const u8, []const u8, CaseInsensitiveStringContext, std.hash_map.default_max_load_percentage);

const testing = std.testing;

test "HeaderMap case insensitive operations" {
    var map = HeaderMap.init(testing.allocator);
    defer map.deinit();

    // Test put and get with different cases
    try map.put("Content-Type", "application/json");
    try testing.expect(map.get("content-type") != null);
    try testing.expect(map.get("CONTENT-TYPE") != null);
    try testing.expect(map.get("Content-Type") != null);
    try testing.expectEqualStrings("application/json", map.get("content-type").?);

    // Test contains with different cases
    try testing.expect(map.contains("content-type"));
    try testing.expect(map.contains("CONTENT-TYPE"));
    try testing.expect(map.contains("Content-Type"));

    // Test multiple headers
    try map.put("Host", "example.com");
    try map.put("USER-AGENT", "test-agent");

    try testing.expectEqualStrings("example.com", map.get("host").?);
    try testing.expectEqualStrings("test-agent", map.get("user-agent").?);

    // Test non-existent header
    try testing.expect(map.get("non-existent") == null);
    try testing.expect(!map.contains("non-existent"));

    // Test remove with different case
    try testing.expect(map.remove("HOST"));
    try testing.expect(!map.contains("host"));
    try testing.expect(map.get("host") == null);
}

test "HeaderMap iterator" {
    var map = HeaderMap.init(testing.allocator);
    defer map.deinit();

    try map.put("Content-Type", "text/html");
    try map.put("Content-Length", "1234");

    var count: u32 = 0;
    var iter = map.iterator();
    while (iter.next()) |entry| {
        count += 1;
        // Verify we can access both key and value
        try testing.expect(entry.key_ptr.*.len > 0);
        try testing.expect(entry.value_ptr.*.len > 0);
    }
    try testing.expectEqual(@as(u32, 2), count);
}
