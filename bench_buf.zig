const std = @import("std");

pub fn main() !void {
    const iterations = 1_000_000;
    var sum_len: usize = 0;
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        var buf: [64]u8 = undefined;
        const role = "agent";
        const label = try std.fmt.bufPrint(&buf, "{d} {s}  ", .{ i, role });
        sum_len += label.len;
    }
    std.debug.print("Done: {d}\n", .{sum_len});
}
