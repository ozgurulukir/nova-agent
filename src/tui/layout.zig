//! Top-level transcript + loading + input layout math.
//!
//! Pulled out of `tui.zig` (R5.2c of `_pm/Projects/tui-split`) — the layout
//! arithmetic for `drawRoot`: given the terminal height, the wrapped input
//! row count, and three visibility flags, compute the row ranges for the
//! transcript pane, the loading spinner strip, the modal overlay panel, and
//! the input box.
//!
//! Pure: no I/O, no allocations, no app state — just arithmetic. Both
//! `drawRoot` and the four layout unit tests in `tui.zig` call into it.

const std = @import("std");

const config_mod = @import("../config/config.zig");
const SplitMode = config_mod.SplitMode;

pub const loading_status_rows: u16 = 2;

/// Rows reserved around the content: top border + bottom border + one
/// hint/diff-counts row.
const root_chrome_rows: u16 = 3;
/// The input widget never shrinks below this, even on a tiny terminal.
const input_height_floor: u16 = 6;
/// Panel (diff viewer) height cap when visible.
const panel_height_max: u16 = 7;

/// A single split pane's geometry and the lane it projects. Row/col are
/// relative to the transcript area (whose top-left is the root origin).
pub const ColumnRect = struct {
    row: u16,
    col: u16,
    width: u16,
    height: u16,
    lane_index: usize,
};

/// Compute the split geometry for `lane_count` lanes in `mode`. Single source
/// of truth shared by the render path (`root_layout.drawRoot`) and mouse
/// click-to-focus routing (`event_router.routeMouse`), so the two can never
/// drift. Pure and zero-alloc: writes into `out` (capacity 4) and returns a
/// slice over the populated entries.
///
/// Collapses to a single full-pane column when there is only one lane, the
/// mode is `.tab`, or the terminal is narrower than `min_split_width`. In
/// `.dual` the left pane is ALWAYS the driver (lane 0); the right pane shows
/// the focused worker (lane index >= 1), clamped into `[1, lane_count - 1]`
/// so a focused driver still projects lane 1 and an out-of-range index is
/// capped. `.grid` is the legacy 2x2 tile, extracted verbatim from the old
/// inline `drawRoot` math.
pub fn computeSplitLayout(
    max_width: u16,
    transcript_height: u16,
    mode: SplitMode,
    lane_count: usize,
    focused_worker_index: usize,
    min_split_width: u16,
    out: *[4]ColumnRect,
) []const ColumnRect {
    if (lane_count <= 1 or mode == .tab or max_width < min_split_width) {
        out[0] = .{ .row = 0, .col = 0, .width = max_width, .height = transcript_height, .lane_index = 0 };
        return out[0..1];
    }
    // `.tab` was handled by the early return above; only `.dual` and `.grid`
    // remain. The right pane ALWAYS shows a worker (lane index >= 1) — the
    // driver (lane 0) is always the left pane.
    if (mode == .dual) {
        const left_w = max_width / 2;
        const right_w = max_width - left_w;
        // Clamp into [1, lane_count-1]: a focused driver (index 0) still
        // projects lane 1, and an out-of-range index is capped.
        const worker_idx = @min(@max(focused_worker_index, 1), lane_count - 1);
        out[0] = .{ .row = 0, .col = 0, .width = left_w, .height = transcript_height, .lane_index = 0 };
        out[1] = .{ .row = 0, .col = left_w, .width = right_w, .height = transcript_height, .lane_index = worker_idx };
        return out[0..2];
    }
    // .grid — extracted verbatim from root_layout.zig drawRoot (the legacy tile).
    const rows: u16 = @intCast((lane_count + 1) / 2);
    const cell_h: u16 = transcript_height / rows;
    for (0..lane_count) |i| {
        const r: u16 = @intCast(i / 2);
        const c: u16 = @intCast(i % 2);
        const last_row = r == rows - 1;
        const per_row: u16 = if (last_row and lane_count % 2 == 1) 1 else 2;
        const cell_w: u16 = max_width / per_row;
        const w: u16 = if (c == per_row - 1) max_width - cell_w * (per_row - 1) else cell_w;
        const h: u16 = if (last_row) transcript_height - cell_h * (rows - 1) else cell_h;
        out[i] = .{ .row = r * cell_h, .col = c * cell_w, .width = w, .height = h, .lane_index = i };
    }
    return out[0..lane_count];
}

pub const RootLayout = struct {
    input_height: u16,
    loading_height: u16,
    panel_height: u16,
    transcript_height: u16,
    loading_row: u16,
    panel_row: u16,
    input_row: u16,
};

pub fn rootLayout(max_height: u16, panel_visible: bool, input_text_rows: u16, loading_visible: bool, queued_visible: bool) RootLayout {
    // Reserve: top border + bottom border + one hint/diff-counts row (the `3`),
    // the wrapped input text, and — when a steered message is queued — the extra
    // line the InputWidget draws above the border for it. Omitting the queued row
    // here starves the InputWidget so it silently drops the hint + diff counts.
    const desired: u16 = root_chrome_rows + input_text_rows + @intFromBool(queued_visible);
    const max_allowed: u16 = @max(input_height_floor, max_height -| root_chrome_rows);
    const input_height: u16 = @min(max_height, @min(desired, max_allowed));
    const above_input_height: u16 = max_height - input_height;
    const loading_height: u16 = if (loading_visible) @min(loading_status_rows, above_input_height) else 0;
    const transcript_height: u16 = above_input_height - loading_height;
    const panel_height: u16 = if (panel_visible) @min(transcript_height, panel_height_max) else 0;
    return .{
        .input_height = input_height,
        .loading_height = loading_height,
        .panel_height = panel_height,
        .transcript_height = transcript_height,
        .loading_row = transcript_height,
        .panel_row = transcript_height - panel_height,
        .input_row = transcript_height + loading_height,
    };
}

test "computeSplitLayout single lane collapses to a full pane" {
    var out: [4]ColumnRect = undefined;
    const cols = computeSplitLayout(200, 40, .dual, 1, 1, 140, &out);
    try std.testing.expectEqual(@as(usize, 1), cols.len);
    try std.testing.expectEqual(@as(usize, 0), cols[0].lane_index);
    try std.testing.expectEqual(@as(u16, 200), cols[0].width);
    try std.testing.expectEqual(@as(u16, 40), cols[0].height);
}

test "computeSplitLayout tab mode collapses regardless of lane count" {
    var out: [4]ColumnRect = undefined;
    const cols = computeSplitLayout(200, 40, .tab, 3, 1, 140, &out);
    try std.testing.expectEqual(@as(usize, 1), cols.len);
    try std.testing.expectEqual(@as(u16, 200), cols[0].width);
}

test "computeSplitLayout narrow width collapses to a full pane" {
    var out: [4]ColumnRect = undefined;
    const cols = computeSplitLayout(100, 40, .dual, 3, 1, 140, &out);
    try std.testing.expectEqual(@as(usize, 1), cols.len);
    try std.testing.expectEqual(@as(u16, 100), cols[0].width);
}

test "computeSplitLayout dual splits driver and focused worker" {
    var out: [4]ColumnRect = undefined;
    const cols = computeSplitLayout(200, 40, .dual, 3, 2, 140, &out);
    try std.testing.expectEqual(@as(usize, 2), cols.len);
    try std.testing.expectEqual(@as(usize, 0), cols[0].lane_index);
    try std.testing.expectEqual(@as(u16, 100), cols[0].width); // left half
    try std.testing.expectEqual(@as(u16, 40), cols[0].height);
    try std.testing.expectEqual(@as(usize, 2), cols[1].lane_index);
    try std.testing.expectEqual(@as(u16, 100), cols[1].width); // right half
    try std.testing.expectEqual(@as(u16, 100), cols[1].col); // starts after the left pane
}

test "computeSplitLayout dual clamps a focused driver (index 0) to lane 1" {
    var out: [4]ColumnRect = undefined;
    const cols = computeSplitLayout(200, 40, .dual, 3, 0, 140, &out);
    try std.testing.expectEqual(@as(usize, 2), cols.len);
    try std.testing.expectEqual(@as(usize, 1), cols[1].lane_index);
}

test "computeSplitLayout dual clamps an out-of-range worker to lane_count-1" {
    var out: [4]ColumnRect = undefined;
    const cols = computeSplitLayout(200, 40, .dual, 3, 99, 140, &out);
    try std.testing.expectEqual(@as(usize, 2), cols.len);
    try std.testing.expectEqual(@as(usize, 2), cols[1].lane_index); // lane_count-1
}

test "computeSplitLayout grid tiles 2x2 with equal cells" {
    var out: [4]ColumnRect = undefined;
    const cols = computeSplitLayout(200, 40, .grid, 4, 1, 140, &out);
    try std.testing.expectEqual(@as(usize, 4), cols.len);
    // 2 rows, cell_h = 20, cell_w = 100.
    try std.testing.expectEqual(@as(u16, 0), cols[0].row);
    try std.testing.expectEqual(@as(u16, 0), cols[0].col);
    try std.testing.expectEqual(@as(u16, 100), cols[0].width);
    try std.testing.expectEqual(@as(u16, 20), cols[0].height);
    try std.testing.expectEqual(@as(u16, 100), cols[1].col);
    try std.testing.expectEqual(@as(u16, 20), cols[2].row);
    try std.testing.expectEqual(@as(u16, 100), cols[2].width);
}

test "computeSplitLayout grid spans a trailing odd lane across its row" {
    var out: [4]ColumnRect = undefined;
    const cols = computeSplitLayout(200, 40, .grid, 3, 1, 140, &out);
    try std.testing.expectEqual(@as(usize, 3), cols.len);
    // The odd trailing lane (index 2) spans the full second row width.
    try std.testing.expectEqual(@as(u16, 20), cols[2].row);
    try std.testing.expectEqual(@as(u16, 0), cols[2].col);
    try std.testing.expectEqual(@as(u16, 200), cols[2].width);
    try std.testing.expectEqual(@as(u16, 20), cols[2].height);
}
