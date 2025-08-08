const std = @import("std");

const request = @import("http/request.zig");
pub const fetch = @import("http/fetch.zig");
pub const createServer = @import("http/server.zig").createServer;

pub const Request = request.Request;
pub const resolveAddress = request.resolveAddress;

test {
    @import("std").testing.refAllDecls(@This());
}
