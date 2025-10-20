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

    // Test host and port availability
    {
        var host_buf: [std.Uri.host_name_max]u8 = undefined;
        const host = try uri.getHost(&host_buf);
        var stream = std.net.tcpConnectToHost(allocator, host, uri.port.?) catch |err| {
            std.debug.print("failed to connect to {s}:{d} - {}\n", .{ host, uri.port.?, err });
            return;
        };
        stream.close();
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

    const value_scale = 1_000.0; // µs
    std.debug.print("Latency Histogram:\n", .{});

    var iter: c.hdr_iter = undefined;
    c.hdr_iter_percentile_init(&iter, response_time_histogram, 1);

    var prev_cum_count: i64 = 0;
    while (c.hdr_iter_next(&iter)) {
        const count = iter.cumulative_count - prev_cum_count;
        if (count == 0) {
            continue;
        }

        const value = @as(f64, @floatFromInt(iter.highest_equivalent_value)) / value_scale;
        std.debug.print("{d:10.2}µs {d: >6} |", .{ value, @as(usize, @intCast(count)) });
        for (0..(@as(usize, @intCast(count)) * 60 / total_requests)) |_| {
            std.debug.print("■", .{});
        }
        std.debug.print("\n", .{});
        prev_cum_count = iter.cumulative_count;
    }
}
