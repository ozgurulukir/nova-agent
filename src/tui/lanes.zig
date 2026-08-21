//! Lane merge-source helpers — extracted from `tui.zig` (R7.4 of tui-split).
//!
//! Types and pure helpers for the parallel-lane merge workflow: identifying
//! the worktree backing a lane (`workingLaneOf`), trimming worktree paths
//! (`lastPathSegment`), and formatting merge errors for the model-status bar
//! (`laneErrorText`).

const std = @import("std");
const os = @import("../os.zig");
const vcs = @import("../vcs.zig");

const Thread = @import("../tui.zig").Thread;

/// A lane being merged away. `branch`/`path` identify its `nova/<id>` worktree;
/// `active_index` is its `threads` slot when it's an open lane (torn down via
/// `abandonLane` after a successful merge), or null for a parked worktree
/// (removed directly). Strings are borrowed for the duration of the merge.
pub const MergeSource = struct {
    branch: []const u8,
    path: []const u8,
    active_index: ?usize,
};

/// The `nova/<id>` worktree of `lane` if it's a working lane, else null (the
/// primary lane carries no dedicated branch/worktree).
pub fn workingLaneOf(lane: *Thread) ?vcs.Lane.Working {
    const lane_ref: *const vcs.Lane = switch (lane.engine) {
        .live => |*live| &live.lane,
        .idle => |*l| l,
    };
    return switch (lane_ref.*) {
        .working => |w| w,
        .primary => null,
    };
}

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

/// Idle-lane refusal notice shared by `beginSubmit` (turn_lifecycle) and
/// `refuseOnIdleLane` (mode_lifecycle). The exact bytes are pinned by the
/// test below — transcript output depends on them.
pub const idle_lane_notice_template = "Lane {s} is idle — no agent is attached. From the driver, `lane enter {s}` to work here, or `lane spawn` to start a worker in it.\n";
/// Fallback for callers whose formatting buffer the id does not fit.
pub const idle_lane_notice_fallback = "This lane is idle — no agent is attached. From the driver, use `lane enter` or `lane spawn`.\n";

/// Display id for an idle-lane notice: the focused lane's worktree name, or
/// `"this lane"` when the focused lane is the primary (no dedicated worktree).
pub fn idleLaneId(lane: *Thread) []const u8 {
    if (workingLaneOf(lane)) |working| return lastPathSegment(working.path);
    return "this lane";
}

test "idle-lane notice template bytes are pinned" {
    var buffer: [256]u8 = undefined;
    const notice = try std.fmt.bufPrint(
        &buffer,
        idle_lane_notice_template,
        .{ "alpha", "alpha" },
    );
    try std.testing.expectEqualStrings(
        "Lane alpha is idle — no agent is attached. From the driver, `lane enter alpha` to work here, or `lane spawn` to start a worker in it.\n",
        notice,
    );
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

/// Friendly text for the lane-operation errors surfaced by `reportLaneError`.
pub fn laneErrorText(err: anyerror) []const u8 {
    return switch (err) {
        error.InFlightTurn => "a turn is still running — wait for it to finish",
        error.MergeConflict => "merge conflict — the lanes changed the same lines (rolled back, nothing lost)",
        error.CannotMergePrimaryLane => "can't merge the primary lane; switch to a working lane first",
        error.CannotClosePrimaryLane => "can't close the primary lane",
        error.NoMergeDestination => "no other lane to merge into",
        error.DirtySourceLane => "the lane has uncommitted changes — commit them first (via the model or `/save`), then merge",
        error.TooManyLanes => "too many lanes (max 4 total: driver + 3)",
        else => @errorName(err),
    };
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
