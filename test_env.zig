const std = @import("std");
pub fn main() !void {
    const text = "Spawning python script is generally safe because no user arguments are included in the command. Still, creating a child process without explicit control points or sandboxing could be a long-term risk. Fixing this is easy (Confidence 1).";
    std.debug.print("{s}\n", .{text});
}
