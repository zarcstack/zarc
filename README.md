# zarc

A modern multimedia framework. Safe, embeddable, extensible.

Status: early development. Nothing works yet.

## What it is

zarc is an attempt to build multimedia infrastructure with tools from
this decade instead of the last one. Memory-safe parsers, hermetic
builds, an explicit C ABI, and support for the codecs people actually
use.

It is not trying to replace FFmpeg. It is trying to be good at the
edges FFmpeg is not: embedding, cross-compilation, extensibility,
safety.

## Stack

- Zig for the core runtime and CLI
- Rust for codec bitstream parsers
- C for container demuxers and muxers
- C++ for numerical kernels
- Assembly for hot loops
- WGSL for GPU filters
- Lua for user-defined filters
- Nix for reproducible builds

## Build

    nix develop
    zig build

## Status

Phase 0. The repository is a skeleton. There is no code that
processes audio or video yet.

Roadmap and progress are tracked in `ROADMAP.md`.

## Contributing

Read `CONTRIBUTING.md` before opening a pull request.

## License

LGPL-2.1-or-later. See `LICENSE`.