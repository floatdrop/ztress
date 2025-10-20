# zstress

Zstress is an HTTP(S) benchmarking tool, written in [Zig](https://ziglang.org).

## Usage

```
Usage: zstress [-h] [-c <usize>] [-n <usize>] <URL>
    -h, --help
            Display this help and exit.

    -c, --concurrency <usize>
            Number of concurrent requests to make at a time (default: 10).

    -n, --number <usize>
            Total number of requests to make (default: 1_000_000).

    <URL>
            Stress test target url.
```

## Building

Download [Zig](https://ziglang.org) and run:

```
zig build
```
