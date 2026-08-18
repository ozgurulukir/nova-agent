const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const iterations = 1_000_000;
    var sum_len: usize = 0;
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        const role = "agent";
        const label = try std.fmt.allocPrint(allocator, "{d} {s}  ", .{ i, role });
        sum_len += label.len;
    }
    std.debug.print("Done: {d}\n", .{sum_len});
}
