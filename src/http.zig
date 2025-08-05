// HTTP barrel file - re-exports all HTTP-related functionality
// This allows you to import everything with: const http = @import("http.zig");

// Re-export HTTP components from the http/ directory
pub const HttpMethod = @import("http/method.zig").HttpMethod;
pub const HttpRequest = @import("http/request.zig").HttpRequest;
pub const HttpResponse = @import("http/response.zig").HttpResponse;
pub const ResponseWriter = @import("http/response_writer.zig").ResponseWriter;

// Re-export HTTP server functionality
pub const Server = @import("http_server.zig").Server;

// Re-export HTTP client functionality
pub const client = @import("http_client.zig");
pub const FetchError = client.FetchError;
pub const fetch = client.fetch;

// For convenience, also expose commonly used types at the top level
pub const Method = HttpMethod;
pub const Request = HttpRequest;
pub const Response = HttpResponse;