const std = @import("std");
const clap = @import("clap");
const http = std.http;

pub fn main() !void {
    var concurrency: usize = 10;
    var requests: usize = 1_000_000;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() != .ok) @panic("leak");
    const allocator = gpa.allocator();

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
        .allocator = gpa.allocator(),
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
        requests = n;

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

    var parent_progress_node = std.Progress.start(.{ .root_name = "Making requests...", .estimated_total_items = requests });

    // TODO: Use HdrHistogram for better memory consumption?
    var response_times: []u64 = try allocator.alloc(u64, requests);
    defer allocator.free(response_times);

    for (0..requests) |i| {
        pool.spawnWg(&wg, struct {
            fn run(c: *http.Client, target: std.Uri, progress: *std.Progress.Node, time: *u64) void {
                defer progress.completeOne();

                var timer = std.time.Timer.start() catch @panic("need timer to work");

                var req = c.request(.GET, target, .{}) catch @panic("http client failed to initialize request");
                defer req.deinit();

                req.sendBodiless() catch @panic("http client failed to send bodiless request");

                var redirect_buffer: [1024]u8 = undefined;
                var resp = req.receiveHead(&redirect_buffer) catch @panic("http client failed to read headers");
                _ = resp.reader(&.{}).discardRemaining() catch @panic("http client failed to discard body");

                time.* = timer.lap();
            }
        }.run, .{ &client, uri, &parent_progress_node, &response_times[i] });
    }
    wg.wait();
    parent_progress_node.end();

    std.mem.sort(u64, response_times, {}, comptime std.sort.asc(u64));

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

    std.debug.print("Min    : {d:6.3}µs\n", .{@as(f32, @floatFromInt(response_times[0])) / 1_000});
    std.debug.print("Median : {d:6.3}µs\n", .{@as(f32, @floatFromInt(response_times[requests / 2])) / 1_000});
    std.debug.print("p90    : {d:6.3}µs\n", .{@as(f32, @floatFromInt(response_times[requests * 90 / 100])) / 1_000});
    std.debug.print("p99    : {d:6.3}µs\n", .{@as(f32, @floatFromInt(response_times[requests * 99 / 100])) / 1_000});
    std.debug.print("p99.9  : {d:6.3}µs\n", .{@as(f32, @floatFromInt(response_times[requests * 999 / 1000])) / 1_000});
    std.debug.print("p99.99 : {d:6.3}µs\n", .{@as(f32, @floatFromInt(response_times[requests * 9999 / 10000])) / 1_000});
    std.debug.print("Max    : {d:6.3}µs\n", .{@as(f32, @floatFromInt(response_times[requests - 1])) / 1_000});
}
