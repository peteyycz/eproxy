const std = @import("std");

const request = @import("http/request.zig");
pub const fetch = @import("http/fetch.zig");

pub const Request = request.Request;
pub const resolveAddress = request.resolveAddress;
