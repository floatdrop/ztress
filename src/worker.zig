const Worker = @This();
const std = @import("std");

allocator: std.mem.Allocator,
client: std.http.Client,
target: std.Uri,
results: []u64, // TODO: Port HdrHistogram to zig
progress: std.Progress.Node,

pub fn run(self: *Worker) void {
    var redirect_buffer: [1024]u8 = undefined;

    for (self.results) |*result| {
        defer self.progress.completeOne();

        var timer = std.time.Timer.start() catch @panic("need timer to work");

        var req = self.client.request(.GET, self.target, .{}) catch @panic("http client failed to initialize request");
        defer req.deinit();

        req.sendBodiless() catch @panic("http client failed to send bodiless request");

        var resp = req.receiveHead(&redirect_buffer) catch @panic("http client failed to read headers");
        _ = resp.reader(&.{}).discardRemaining() catch @panic("http client failed to discard body");

        result.* = timer.lap();
    }

    std.mem.sort(u64, self.results, {}, comptime std.sort.asc(u64));
}

pub fn init(allocator: std.mem.Allocator, target: std.Uri, requests: usize, progress: std.Progress.Node) !Worker {
    return .{
        .allocator = allocator,
        .client = std.http.Client{ .allocator = allocator },
        .target = target,
        .results = try allocator.alloc(u64, requests),
        .progress = progress.start("Worker", requests),
    };
}

pub fn deinit(self: *Worker) void {
    self.progress.end();
    self.allocator.free(self.results);
    self.client.deinit();
}
