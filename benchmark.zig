const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const iterations = 100_000;

    var timer = try std.time.Timer.start();

    // Original approach
    var sum_len_alloc: usize = 0;
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        const role = "agent";
        const label = try std.fmt.allocPrint(allocator, "{d} {s}  ", .{ i, role });
        sum_len_alloc += label.len;
    }
    const alloc_time = timer.read();

    // Restart timer
    timer.reset();

    // Optimized approach
    var sum_len_buf: usize = 0;
    i = 0;
    while (i < iterations) : (i += 1) {
        var buf: [64]u8 = undefined;
        const role = "agent";
        const label = try std.fmt.bufPrint(&buf, "{d} {s}  ", .{ i, role });
        sum_len_buf += label.len;
    }
    const buf_time = timer.read();

    std.debug.print("Baseline (allocPrint): {d} ns\n", .{alloc_time});
    std.debug.print("Optimized (bufPrint):  {d} ns\n", .{buf_time});
    std.debug.print("Speedup: {d:.2}x\n", .{@as(f64, @floatFromInt(alloc_time)) / @as(f64, @floatFromInt(buf_time))});
}
