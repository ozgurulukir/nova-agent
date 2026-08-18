const std = @import("std");
pub fn main() void {
    const info = @typeInfo(std.process.SpawnOptions);
    inline for (info.@"struct".fields) |field| {
        std.debug.print("{s}\n", .{field.name});
    }
}
