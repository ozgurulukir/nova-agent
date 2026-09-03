//! Test-only fixtures shared across the TUI test files (`tests.zig`,
//! `queue.zig`, `background_delivery.zig`). Deliberately contains no `test`
//! blocks: registering none keeps test-collection order identical whether or
//! not a file imports this module.

const std = @import("std");

pub const IsolatedHome = struct {
    tmp: std.testing.TmpDir,
    path: []u8,

    /// Frees the path before removing the directory, and must be the last
    /// deferred cleanup of a test so nothing outlives the directory.
    pub fn deinit(self: *IsolatedHome, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        self.tmp.cleanup();
    }
};

/// Disposable absolute home directory under `.zig-cache/tmp`, so runtime
/// fixtures never write the real `~/.config/nova` or the repository tree.
pub fn isolatedHome(gpa: std.mem.Allocator, io: std.Io) !IsolatedHome {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const cwd_abs = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_abs);
    const path = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path });
    return .{ .tmp = tmp, .path = path };
}
