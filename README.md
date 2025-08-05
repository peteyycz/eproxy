# ⚡ EProxy

> **Blazingly fast** and **super performant** HTTP proxy server built with Zig and libxev

[![Zig](https://img.shields.io/badge/Zig-0.14+-orange.svg)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Performance](https://img.shields.io/badge/performance-blazing%20fast-red.svg)](#benchmarks)

EProxy is a **lightning-fast**, **memory-efficient** HTTP proxy server engineered from the ground up in Zig. Built on the high-performance libxev event loop, it delivers **unmatched throughput** and **ultra-low latency** for production workloads.

Don't take anything too seriously, this is a **work in progress** and **not for production use**. It's more of a
playground for me to learn Zig and libxev, but it might be useful for you if you want to see how to build an HTTP proxy
server in Zig.

## ✨ Features

- 🚀 **Blazingly Fast**: Built with Zig's non-zero-cost abstractions and manual memory management
- ⚡ **Super Performant**: Async I/O with libxev event loop for maximum throughput
- 🔥 **Memory Efficient**: Arena allocators are cool
- 🌊 **Async by Design**: Non-blocking request handlers with callback-based responses
- 🛡️ **Production Ready**: If you're brave enough
- 🔧 **Zero Dependencies**: I just couldn't find any

## 🏃‍♂️ Quick Start

```bash
# Clone the repository
git clone https://github.com/peteyycz/eproxy.git
cd eproxy

# Build in release mode for maximum performance
zig build

# Run the server
./zig-out/bin/eproxy
```

The server will start on `http://localhost:8080` with the following endpoints:

- `/` - Welcome message
- `/hello` - Simple greeting
- `/proxy` - External HTTP request proxy demonstration

## 🚀 Performance

EProxy is designed to handle **thousands of concurrent connections** with minimal resource usage:

- **Always-fucking-copy-if-it-is-easier** request parsing where possible
- **Arena-based** memory management for request lifecycle, because why not
- **Definetly-no-Connection pooling** for upstream requests
- **Lock-free** data structures in hot paths except everywhere literally in main

### Benchmarks

Trust me bro.

```bash
# Basic load test (replace with your actual benchmarks)
wrk -t4 -c100 -d30s http://localhost:8080/hello
```

*Benchmarks coming soon...*

## 🏗️ Architecture

EProxy follows a **modern async architecture**:

```
┌─────────────────┐    ┌─────────────────────────────────┐    ┌─────────────────────────────────────────┐
│   Client        │───▶│   Something mitchellh has done  │───▶│   Making fucking requests Upstream      │
│   Requests      │    │   Event Loop                    │    │            Services                     │
└─────────────────┘    └─────────────────────────────────┘    └─────────────────────────────────────────┘
```

### Key Components:

- **HTTP Server**: Async TCP server with libxev integration
- **Request Parser**: Maybe-sometimes-copy HTTP/1.1 parser
- **Response Handler**: Callback-based async response system which I maybe have copied from nodejs
- **HTTP Client**: Built-in client for upstream requests

## 🔧 Configuration

EProxy supports various build-time configurations (so it actually doesn't have any runtime configuration, but at some
point I might add it):

```bash
# Debug build with verbose logging
zig build -Doptimize=Debug -Dlog-level=debug

# Release build optimized for speed
zig build -Doptimize=ReleaseFast

# Release build optimized for size
zig build -Doptimize=ReleaseSmall
```

## 🛠️ Development

### Prerequisites

- Zig 0.14+ 
- libxev (automatically fetched via Zig's package manager)

### Building

```bash
# Development build
zig build

# Run tests
zig build test

# Run with arguments
zig build run -- --port 9000
```

### Code Style

EProxy follows Zig's standard formatting and conventions:

```bash
# Format code
zig fmt src/
```

## 🤝 Contributing

We welcome contributions! Here's how to get started:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes following our code style
4. Add tests for new functionality
5. Commit your changes (`git commit -m 'Add amazing feature'`)
6. Push to the branch (`git push origin feature/amazing-feature`)
7. Open a Pull Request

### Areas for Contribution

- [ ] HTTP/2 support
- [ ] WebSocket proxying
- [ ] Load balancing algorithms
- [ ] Metrics and monitoring
- [ ] Configuration file support
- [ ] SSL/TLS termination
- [ ] Rate limiting
- [ ] Caching layer
- [ ] Literally anywhere you think it can be improved

## 📊 Monitoring

EProxy provides detailed logging at various levels:

- `debug`: Detailed connection and request information
- `info`: General server status and requests
- `warn`: Non-fatal issues and recoverable errors
- `err`: Critical errors requiring attention

## 📄 License

This project is licensed under a License which I have not decided yet.

## 🙏 Acknowledgments

- [Zig Programming Language](https://ziglang.org/) - Systems programming language
- [libxev](https://github.com/mitchellh/libxev) - High-performance event loop

## 📈 Roadmap

- [x] Basic HTTP server functionality
- [x] Async request handling
- [x] HTTP client for upstream requests
- [ ] HTTP/2 support
- [ ] WebSocket proxying
- [ ] Load balancing
- [ ] Configuration management
- [ ] Metrics and observability
- [ ] Docker containerization
- [ ] Kubernetes deployment

---

<p align="center">
  <strong>Built with ❤️ and ⚡ by Peter Czibik</strong>
</p>

<p align="center">
  <a href="#quick-start">Get Started</a> •
  <a href="#performance">Benchmarks</a> •
  <a href="#contributing">Contribute</a> •
  <a href="https://github.com/peteyycz/eproxy/issues">Report Bug</a>
</p>
