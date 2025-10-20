# zstress

Zstress is an HTTP(S) benchmarking tool, written in [Zig](https://ziglang.org).

```sh
$ ztress -n 10000 http://localhost:8081/build.zig
Latency Histogram:
     31.68µs      1 |
    113.92µs   4999 |■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
    165.25µs   2502 |■■■■■■■■■■■■■■■
    187.65µs   1250 |■■■■■■■
    212.74µs    624 |■■■
    226.56µs    312 |■
    242.18µs    157 |
    256.77µs     77 |
    269.82µs     39 |
    280.32µs     20 |
   1054.72µs     10 |
   1827.84µs      5 |
   2136.06µs      2 |
   2287.62µs      1 |
   2506.75µs      1 |
```

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
