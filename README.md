# ⚡ EProxy

> **Blazingly fast** and **super performant** HTTP proxy server built with Zig and libxev

[![Zig](https://img.shields.io/badge/Zig-0.14+-orange.svg)](https://ziglang.org/)
[![Performance](https://img.shields.io/badge/performance-blazing%20fast-red.svg)](#benchmarks)

EProxy is a **lightning-fast**, **memory-inefficient** HTTP proxy server engineered from almost the ground up in Zig. Built on the high-performance libxev event loop, it delivers **unmatched throughput** and **ultra-low latency** for all your non-production needs.

Don't take anything too seriously, this is a **work in progress** and **not for production use**. It's more of a
playground for me to learn Zig and libxev, but it might be useful for you if you want to see how to build an HTTP proxy
server in Zig.

## ✨ Features

- 🚀 **Blazingly Fast**: Built with Zig's non-zero-cost abstractions and manual memory management
- 🔥 **Memory Efficient**: Arena allocators are cool
- 🌊 **Async by Design**: Non-blocking request handlers with callback-based responses
- 🛡️ **Production Ready**: If you're brave enough

## 🚀 Performance

EProxy is designed to handle **thousands of concurrent connections** with minimal resource usage:

- **Always-fucking-copy-if-it-is-easier** request parsing where possible
- **Arena-based** memory management for request lifecycle, because why not
- **Definetly-no-Connection pooling** for upstream requests
- **Lock-free** data structures in hot paths except everywhere literally in main

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

### Benchmarks

Trust me bro.

## 🛠️ Development

### Prerequisites

- Zig 0.14+ 
- libxev (automatically fetched via Zig's package manager)

### Building

```bash
# Development build
zig build

# Run tests when we actually have some
zig build test

# Run with arguments
zig build run
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

## 📄 License

This project is licensed under a License which I have not decided yet.

## 🙏 Acknowledgments

- [Zig Programming Language](https://ziglang.org/) - Systems programming language
- [libxev](https://github.com/mitchellh/libxev) - High-performance event loop

## 📈 Roadmap

- [ ] Basic HTTP server functionality
- [ ] Configuration management
- [ ] Caching layer
- [ ] Rate limiting
- [ ] Metrics and observability
- [ ] WebSocket proxying

---

<p align="center">
  <strong>Built with ❤️ and ⚡ by Peter Czibik</strong>
</p>
