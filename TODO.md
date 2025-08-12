# HTTP Request Parser Improvements

## parseRequest Function Issues

- [ ] **Incomplete Request Detection**: Improve detection of incomplete requests beyond just checking for `\r\n\r\n` separator
- [ ] **Header Parsing Flexibility**: Fix header parsing to accept just colon followed by optional whitespace, not requiring `": "` (colon-space)
- [ ] **Case Insensitive Headers**: Implement case-insensitive header name comparison as per HTTP spec
- [ ] **Content-Length Data Type**: Change Content-Length parsing from `u8` to larger integer type (e.g., `u64`) to support content larger than 255 bytes
- [ ] **Memory Safety**: Copy strings instead of storing slices to avoid use-after-free issues when request buffer is freed
- [ ] **HTTP Version Validation**: Add validation for HTTP version in request line
- [ ] **URI Validation**: Implement pathname validation for invalid characters and proper encoding
- [ ] **Method Flexibility**: Make method parsing more flexible beyond just GET
- [ ] **Request Line Parsing**: Handle multiple spaces in request line properly
- [ ] **Security Limits**: Add limits on header count and size to prevent DoS attacks
- [ ] **Streaming Parser**: Consider implementing streaming parser for large requests

## Additional Improvements

- [ ] Add comprehensive error handling for malformed requests
- [ ] Implement proper HTTP/1.1 compliance testing
- [ ] Add support for chunked transfer encoding
- [ ] Implement request timeout handling
