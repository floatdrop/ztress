const std = @import("std");
const clap = @import("clap");
const Worker = @import("worker.zig");
const http = std.http;

pub fn main() !void {
    var concurrency: usize = 10;
    var total_requests: usize = 1_000_000;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    const parsers = comptime .{
        .URL = clap.parsers.string,
        .usize = clap.parsers.int(usize, 0),
    };

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                  Display this help and exit.
        \\-c, --concurrency <usize>   Number of concurrent requests to make at a time (default: 10).
        \\-n, --number <usize>        Total number of requests to make (default: 1_000_000).
        \\<URL>                       Stress test target url.
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        // Report useful error and exit.
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0 or res.positionals[0] == null) {
        std.debug.print("Usage: zstress ", .{});
        try clap.usageToFile(.stdout(), clap.Help, &params);
        std.debug.print("\n", .{});
        return clap.helpToFile(.stdout(), clap.Help, &params, .{});
    }

    if (res.args.concurrency) |c|
        concurrency = c;
    if (res.args.number) |n|
        total_requests = n;

    const uri = std.Uri.parse(res.positionals[0] orelse unreachable) catch |err| {
        std.debug.print("invalid URL format: {}", .{err});
        return;
    };

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{
        .allocator = allocator,
        .n_jobs = concurrency,
    });
    defer pool.deinit();

    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    // Making first test request
    {
        var test_req = client.request(.GET, uri, .{}) catch |err| {
            std.debug.print("failed to create request to \"{f}\": {}\n", .{ uri, err });
            return;
        };
        defer test_req.deinit();
        try test_req.sendBodiless();
        var test_buffer: [1024]u8 = undefined;
        const test_resp = try test_req.receiveHead(&test_buffer);
        if (test_resp.head.status != .ok) {
            std.debug.print("{f} returned {}, but expected .ok – check that service is ok. bye.\n", .{ uri, test_resp.head.status });
            return;
        }
    }

    var wg: std.Thread.WaitGroup = .{};

    var parent_progress_node = std.Progress.start(.{ .root_name = "Making requests..." });

    const workers = try allocator.alloc(Worker, concurrency);
    defer allocator.free(workers);

    var remaining_requests = total_requests;
    for (workers) |*worker| {
        const worker_requests = @min(total_requests / concurrency, remaining_requests);
        worker.* = try Worker.init(allocator, uri, worker_requests, parent_progress_node);
        pool.spawnWg(&wg, Worker.run, .{worker});
        remaining_requests -= worker_requests;
    }

    wg.wait();

    for (workers) |*worker| {
        worker.deinit();
    }

    parent_progress_node.end();

    // TODO: Make this more like this:
    // Latency Histogram:
    // 141µs  273028  ■■■■■■■■■■■■■■■■■■■■■■■■
    // 177µs  458955  ■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
    // 209µs  204717  ■■■■■■■■■■■■■■■■■■
    // 235µs   26146  ■■
    // 269µs    6029  ■
    // 320µs     721
    // 403µs      58
    // 524µs       3

    // std.debug.print("Min    : {d:6.3}µs\n", .{@as(f32, @floatFromInt(response_times[0])) / 1_000});
    // std.debug.print("Median : {d:6.3}µs\n", .{@as(f32, @floatFromInt(response_times[requests / 2])) / 1_000});
    // std.debug.print("p90    : {d:6.3}µs\n", .{@as(f32, @floatFromInt(response_times[requests * 90 / 100])) / 1_000});
    // std.debug.print("p99    : {d:6.3}µs\n", .{@as(f32, @floatFromInt(response_times[requests * 99 / 100])) / 1_000});
    // std.debug.print("p99.9  : {d:6.3}µs\n", .{@as(f32, @floatFromInt(response_times[requests * 999 / 1000])) / 1_000});
    // std.debug.print("p99.99 : {d:6.3}µs\n", .{@as(f32, @floatFromInt(response_times[requests * 9999 / 10000])) / 1_000});
    // std.debug.print("Max    : {d:6.3}µs\n", .{@as(f32, @floatFromInt(response_times[requests - 1])) / 1_000});
}
