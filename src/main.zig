const std = @import("std");
const clap = @import("clap");
const Worker = @import("worker.zig");
const http = std.http;
const c = @cImport({
    @cInclude("hdr/hdr_histogram.h");
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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

    const concurrency = res.args.concurrency orelse 10;
    const total_requests = res.args.number orelse 1_000_000;

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

    var parent_progress_node = std.Progress.start(.{ .root_name = "Making requests...", .estimated_total_items = total_requests });

    const workers = try allocator.alloc(Worker, concurrency);
    defer allocator.free(workers);

    var remaining_requests = total_requests;
    for (workers) |*worker| {
        const worker_requests = @min(total_requests / concurrency, remaining_requests);
        worker.* = try Worker.init(allocator, uri, parent_progress_node);
        pool.spawnWg(&wg, Worker.run, .{ worker, worker_requests });
        remaining_requests -= worker_requests;
    }

    wg.wait();

    var response_time_histogram: [*c]c.hdr_histogram = undefined;
    if (c.hdr_init(1, c.INT64_C(10_000_000000), 3, &response_time_histogram) != 0) {
        @panic("failed to initalize hdrhistogram");
    }
    defer c.hdr_close(response_time_histogram);

    for (workers) |*worker| {
        if (c.hdr_add(response_time_histogram, @ptrCast(worker.response_time_histogram)) != 0) {
            @panic("failed to summarize histograms");
        }
        worker.deinit();
    }

    parent_progress_node.end();

    std.debug.print("Response time histogram (in ms):\n\n", .{});
    _ = c.hdr_percentiles_print(response_time_histogram, c.stdout(), 1, 1_000_000, c.CLASSIC);

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
}
