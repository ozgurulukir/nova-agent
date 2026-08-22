//! Lane merge-source helpers — extracted from `tui.zig` (R7.4 of tui-split).
//!
//! Types and helpers for the parallel-lane merge workflow: identifying
//! the worktree backing a lane (`workingLaneOf`), and formatting merge
//! errors for the model-status bar (`laneErrorText`). The pure path
//! helpers (`pathsEqual`, `lastPathSegment`) live in the root leaf
//! `src/paths.zig` and are re-exported here for in-TUI callers — the
//! execution layer imports the leaf directly and must never reach them
//! through this file (it would pull the whole App into the executor's
//! dependency closure).

const std = @import("std");
const vcs = @import("../vcs.zig");
const paths = @import("../paths.zig");

const Thread = @import("../tui.zig").Thread;

pub const pathsEqual = paths.pathsEqual;
pub const lastPathSegment = paths.lastPathSegment;

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
