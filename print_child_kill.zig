const std = @import("std");
pub fn main() !void {
    const info = @typeInfo(std.process.Child);
    for (info.@"struct".decls) |decl| {
        std.debug.print("{s}\n", .{decl.name});
    }
}
