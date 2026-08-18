const std = @import("std");

pub fn main() !void {
    const ts = try std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC);
    std.debug.print("time: {d}.{d:0>9}\n", .{ts.tv_sec, ts.tv_nsec});
}
