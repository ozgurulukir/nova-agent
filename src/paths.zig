//! Platform-tolerant path helpers.
//!
//! Two concerns live here:
//!   1. Path comparison (`pathsEqual`) — the single source of truth for
//!      matching workspace/worktree paths across git's forward-slash reporting
//!      and platform-native storage.
//!   2. The platform-aware global config directory (`platformConfigDir`) —
//!      the single base every global Nova path (config, worktrees, logs,
//!      session DB) is derived from, so Windows maps to `%APPDATA%\nova`
//!      consistently with the plugin-discovery probe.
//!
//! Extracted from `tui/lanes.zig` so the execution layer (`tools/pwsh.zig`,
//! `background.zig`) can compare paths without importing the TUI module —
//! that import pulled the whole App into the executor's dependency closure.
//! `tui/lanes.zig` re-exports these symbols for its in-TUI callers; never
//! re-introduce a `tui/` import from the execution layer to reach them.

const std = @import("std");
const os = @import("os.zig");

/// Final path segment, tolerant of both `/` and `\` separators and trailing
/// slashes. Used to match worktree paths across git's forward-slash reporting
/// and the platform-native paths Nova stores.
pub fn lastPathSegment(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and (path[end - 1] == '/' or path[end - 1] == '\\')) end -= 1;
    var start = end;
    while (start > 0 and path[start - 1] != '/' and path[start - 1] != '\\') start -= 1;
    return path[start..end];
}

/// True when two filesystem paths point to the same location, tolerant of
/// mixed `/` and `\` separators, redundant slashes, trailing slashes, and
/// case-insensitivity on Windows. Allocator-free.
pub fn pathsEqual(a: []const u8, b: []const u8) bool {
    return pathsEqualInternal(a, b, os.is_windows);
}

pub fn pathsEqualInternal(a: []const u8, b: []const u8, is_windows: bool) bool {
    if (a.len == 0 or b.len == 0) return a.len == b.len;

    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const ca = a[i];
        const cb = b[j];
        const is_sep_a = (ca == '/' or ca == '\\');
        const is_sep_b = (cb == '/' or cb == '\\');

        if (is_sep_a and is_sep_b) {
            while (i + 1 < a.len and (a[i + 1] == '/' or a[i + 1] == '\\')) i += 1;
            while (j + 1 < b.len and (b[j + 1] == '/' or b[j + 1] == '\\')) j += 1;
        } else {
            const eq = if (is_windows)
                std.ascii.toLower(ca) == std.ascii.toLower(cb)
            else
                ca == cb;
            if (!eq) return false;
        }
        i += 1;
        j += 1;
    }
    while (i < a.len and (a[i] == '/' or a[i] == '\\')) i += 1;
    while (j < b.len and (b[j] == '/' or b[j] == '\\')) j += 1;
    return i == a.len and j == b.len;
}

test "lastPathSegment: empty, trailing slashes, mixed separators, root" {
    try std.testing.expectEqualStrings("", lastPathSegment(""));
    try std.testing.expectEqualStrings("bar", lastPathSegment("/foo/bar"));
    try std.testing.expectEqualStrings("bar", lastPathSegment("/foo/bar/"));
    try std.testing.expectEqualStrings("bar", lastPathSegment("/foo\\bar\\"));
    try std.testing.expectEqualStrings("worktrees", lastPathSegment("/home/nova/.config/nova/worktrees/"));
    try std.testing.expectEqualStrings("", lastPathSegment("/"));
    try std.testing.expectEqualStrings("", lastPathSegment("\\"));
    try std.testing.expectEqualStrings("wt-1", lastPathSegment("C:\\Users\\nova\\worktrees\\wt-1"));
    try std.testing.expectEqualStrings("repo", lastPathSegment("repo"));
}

test "pathsEqual: identical paths and separator permutations" {
    try std.testing.expect(pathsEqual("/foo/bar", "/foo/bar"));
    try std.testing.expect(pathsEqual("C:/Users/nova/worktrees/1", "C:\\Users\\nova\\worktrees\\1"));
    try std.testing.expect(pathsEqual("C:/Users//nova///worktrees/1", "C:\\Users\\nova\\worktrees\\1"));
    try std.testing.expect(pathsEqual("/foo/bar/", "/foo/bar"));
    try std.testing.expect(pathsEqual("C:\\repo\\", "C:/repo"));
    try std.testing.expect(pathsEqual("", ""));
    try std.testing.expect(!pathsEqual("", "/"));
    try std.testing.expect(!pathsEqual("/", ""));
    try std.testing.expect(!pathsEqual("", "\\"));
    try std.testing.expect(!pathsEqual("/foo/bar", "/foo/baz"));
    try std.testing.expect(!pathsEqual("/foo/bar", "/foo/bar/sub"));
}

test "pathsEqualInternal: Windows case-insensitivity control" {
    // Under Windows semantics (is_windows = true):
    try std.testing.expect(pathsEqualInternal("c:\\users\\repo", "C:/USERS/REPO", true));
    try std.testing.expect(pathsEqualInternal("C:/Users/Repo/wt", "c:\\users\\repo\\wt\\", true));

    // Under POSIX semantics (is_windows = false):
    try std.testing.expect(!pathsEqualInternal("c:\\users\\repo", "C:\\users\\repo", false));
    try std.testing.expect(pathsEqualInternal("/home/user/repo", "/home/user/repo/", false));
    try std.testing.expect(!pathsEqualInternal("/home/user/repo", "/Home/user/repo", false));
}

/// Platform-aware global config directory — the single base from which every
/// global Nova path (config.json, worktrees, nova.log, sessions.sqlite) is
/// derived.
///
/// Mirrors the plugin-discovery probe in `plugin_prompt.zig` (which already
/// checks `%APPDATA%\Roaming\nova\plugins` first on Windows) so the whole
/// global tree stays inside one platform-correct root:
///   - Windows: <USERPROFILE>/AppData/Roaming/nova   (== %APPDATA%\nova)
///   - POSIX:   <home>/.config/nova                  (XDG base directory)
///
/// Callers must pass a non-empty `home_dir`: every caller validates this
/// upstream (`globalConfigPath` early-returns, `resolveLogPath` requires
/// HOME/USERPROFILE, `defaultPath` asserts) so an empty home never reaches
/// here. The returned path is therefore always rooted under a real home.
/// Caller owns the returned slice.
pub fn platformConfigDir(gpa: std.mem.Allocator, home_dir: []const u8) ![]u8 {
    if (os.is_windows) {
        return std.fs.path.join(gpa, &.{ home_dir, "AppData", "Roaming", "nova" });
    }
    return std.fs.path.join(gpa, &.{ home_dir, ".config", "nova" });
}

test "platformConfigDir: XDG under POSIX, APPDATA under Windows" {
    const gpa = std.testing.allocator;
    // The platform branch is selected at compile time (os.is_windows), so this
    // test asserts the separator-agnostic *shape* of the path on the host OS.
    const dir = try platformConfigDir(gpa, "HOME");
    defer gpa.free(dir);

    // POSIX host: HOME/.config/nova ; Windows host: HOME/AppData/Roaming/nova.
    // Compare with pathsEqual (slash-agnostic) so the asserted suffix is stable
    // regardless of the host separator.
    const want_suffix = if (os.is_windows) "AppData/Roaming/nova" else ".config/nova";
    const expected = try std.fmt.allocPrint(gpa, "HOME/{s}", .{want_suffix});
    defer gpa.free(expected);
    try std.testing.expect(pathsEqual(dir, expected));
}

test "platformConfigDir: appends the nova segment under the platform base" {
    const gpa = std.testing.allocator;
    const dir = try platformConfigDir(gpa, "PREFIX");
    defer gpa.free(dir);
    // The trailing segment must always be `nova`, never a double separator.
    try std.testing.expect(std.mem.endsWith(u8, dir, "nova"));
    try std.testing.expect(!std.mem.endsWith(u8, dir, "nova/"));
    try std.testing.expect(!std.mem.endsWith(u8, dir, "nova\\"));
}

test "platformConfigDir: rejects a path that drifts from the platform layout" {
    const gpa = std.testing.allocator;
    const dir = try platformConfigDir(gpa, "HOME");
    defer gpa.free(dir);
    // Regression guard: the second-to-last segment must be the platform base
    // (AppData/Roaming on Windows, .config on POSIX), never a typo'd variant.
    // pathsEqual is separator-agnostic, so assert the canonical suffix shape.
    const want_base = if (os.is_windows) "AppData/Roaming" else ".config";
    const expected = try std.fmt.allocPrint(gpa, "HOME/{s}/nova", .{want_base});
    defer gpa.free(expected);
    try std.testing.expect(pathsEqual(dir, expected));
    // The literal 'nova' must appear exactly once, as the final segment.
    var count: u32 = 0;
    var it = std.mem.splitScalar(u8, dir, if (os.is_windows) '\\' else '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "nova")) count += 1;
    }
    try std.testing.expectEqual(count, 1);
}
