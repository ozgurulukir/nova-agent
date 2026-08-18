const std = @import("std");
pub fn main() !void {
    const info = @typeInfo(std.process.SpawnOptions);
    std.debug.print("{any}\n", .{info.@"struct".fields});
}
