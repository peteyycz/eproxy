# eproxy TODO - Architectural Improvements

## Critical Issues (P0 - Must Fix)

- [ ] **Single-threaded blocking architecture** - Each request blocks the entire server. One slow client kills throughput.
- [ ] **Memory inefficiency** - We're buffering entire requests in memory. A 1GB POST request = 1GB RAM per connection.
- [ ] **No connection pooling** - Creating new TCP connections to backend for every request adds significant latency.
- [ ] **Synchronous I/O** - No async/await or event loop. Can't handle concurrent connections efficiently.

## Reliability & Error Handling (P1 - High Priority)

- [ ] **No timeouts** - Malicious clients can hold connections indefinitely
- [ ] **No request size limits** - `content_length` parsing has no bounds checking
- [ ] **Poor error propagation** - Generic error handling loses context
- [ ] **No graceful shutdown** - Server can't drain connections cleanly

## Performance Bottlenecks (P2 - Medium Priority)

- [ ] **Arena allocator per request** - Wasteful for simple forwarding
- [ ] **Multiple memory copies** - Headers copied 2-3 times unnecessarily
- [ ] **No streaming** - Should pipe data through without full buffering
- [ ] **DNS lookups on hot path** - `tcpConnectToHost` does DNS every time

## Security Concerns (P1 - High Priority)

- [ ] **No request validation** - Malformed HTTP could crash or exploit
- [ ] **Missing security headers** - No protection against common attacks
- [ ] **No rate limiting** - Vulnerable to DoS attacks
- [ ] **Debug logging in production** - Headers printed to stdout

## Architectural Improvements (P2-P3 - Future Work)

- [ ] **Event-driven architecture** - Use epoll/kqueue for async I/O
- [ ] **Connection pooling** - Reuse backend connections
- [ ] **Streaming proxy** - Forward data without full buffering
- [ ] **Worker thread pool** - Handle requests concurrently
- [ ] **Configuration system** - Hardcoded constants need to be configurable
- [ ] **Proper logging** - Structured logging instead of print statements
- [ ] **Health checks** - Monitor backend availability
- [ ] **Metrics/monitoring** - Request counts, latency, error rates

## Implementation Notes

**Immediate Priority**: Fix the single-threaded blocking model - this is a fundamental scalability issue that makes the proxy unusable under any meaningful load.

**Architecture Decision**: Consider using Zig's async/await or implementing a thread pool model for handling concurrent connections.

**Memory Strategy**: Implement streaming proxy to avoid buffering large requests/responses in memory.

**Security**: Add basic request validation and size limits before moving to production.