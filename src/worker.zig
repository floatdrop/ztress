const Worker = @This();
const std = @import("std");

allocator: std.mem.Allocator,
client: std.http.Client,
target: std.Uri,
results: []u64, // TODO: Port HdrHistogram to zig
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

pub fn run(self: *Worker) void {
    var redirect_buffer: [1024]u8 = undefined;

    for (self.results) |*result| {
        defer self.progress.completeOne();
        result.* = self.makeRequest(&redirect_buffer) catch blk: {
            self.failed_requsts += 1;
            break :blk 0;
        };
    }

    std.mem.sort(u64, self.results, {}, comptime std.sort.asc(u64));
}

pub fn init(allocator: std.mem.Allocator, target: std.Uri, requests: usize, progress: std.Progress.Node) !Worker {
    return .{
        .allocator = allocator,
        .client = std.http.Client{ .allocator = allocator },
        .target = target,
        .results = try allocator.alloc(u64, requests),
        .progress = progress,
    };
}

pub fn deinit(self: *Worker) void {
    self.allocator.free(self.results);
    self.client.deinit();
}
