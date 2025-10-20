const Worker = @This();
const std = @import("std");
const c = @cImport({
    @cInclude("hdr/hdr_histogram.h");
});

allocator: std.mem.Allocator,
client: std.http.Client,
target: std.Uri,
response_time_histogram: [*c]c.hdr_histogram = undefined,
progress: std.Progress.Node,

failed_requsts: usize = 0,

fn makeRequest(self: *Worker, redirect_buffer: []u8) !u64 {
    var timer = try std.time.Timer.start();

    var req = try self.client.request(.GET, self.target, .{});
    defer req.deinit();

    _ = try req.sendBodiless();

    var resp = try req.receiveHead(redirect_buffer);
    _ = try resp.reader(&.{}).discardRemaining();

    return timer.lap();
}

pub fn run(self: *Worker, requests_count: usize) void {
    var redirect_buffer: [1024]u8 = undefined;

    for (0..requests_count) |_| {
        defer self.progress.completeOne();
        const response_time = self.makeRequest(&redirect_buffer) catch blk: {
            self.failed_requsts += 1;
            break :blk 0;
        };

        if (!c.hdr_record_value(self.response_time_histogram, @as(i64, @intCast(response_time)))) {
            @panic("failed to record response time to histogram");
        }
    }
}

pub fn init(allocator: std.mem.Allocator, target: std.Uri, progress: std.Progress.Node) !Worker {
    var worker: Worker = .{
        .allocator = allocator,
        .client = std.http.Client{ .allocator = allocator },
        .target = target,
        .progress = progress,
    };
    if (c.hdr_init(1, c.INT64_C(10_000_000000), 3, &worker.response_time_histogram) != 0) {
        @panic("failed to initalize hdrhistogram");
    }
    return worker;
}

pub fn deinit(self: *Worker) void {
    c.hdr_close(self.response_time_histogram);
    self.client.deinit();
}
