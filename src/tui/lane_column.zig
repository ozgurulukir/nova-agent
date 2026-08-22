//! Per-lane column widget: a bordered transcript pane, one per open lane.
//!
//! Pulled out of `tui.zig` (R5.2a of `_pm/Projects/tui-split`) — `drawLaneColumn`
//! is a 14-line wrapper that wraps the per-lane `TranscriptWidget` in a border
//! whose label shows the lane title prefixed with an active (●) / inactive (○)
//! marker. Used by `drawRoot` when tiling multiple lanes side-by-side.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../tui.zig");
const tui_style = @import("style.zig");
const tui_status = @import("status.zig");
const lanes_util = @import("lanes.zig");
const tx_widget = @import("widgets/transcript.zig");
const tui_message = @import("widgets/message.zig");

const App = tui.App;
const Thread = tui.Thread;

/// The driver's workspace borrow, if any — the lane whose worktree path the
/// driver (threads[0]) entered. Only the driver enters lanes, so its agent is
/// the only one that can hold a workspace.
fn driverWorkspacePath(app: *const App) ?[]const u8 {
    if (app.threads.len() == 0) return null;
    const agent = app.threads.at(0).agent orelse return null;
    return agent.workspaceBorrow();
}

pub fn drawLaneColumn(app: *App, ctx: vxfw.DrawContext, lane: *Thread, width: u16, height: u16, active: bool, focused: bool) std.mem.Allocator.Error!vxfw.Surface {
    // INV-WIDGET-1: leaf widgets take scalars, computed here per frame. The
    // model flag mirrors the pre-scalarization behavior: always the ACTIVE
    // lane's runtime, never the rendered lane's.
    const has_model = tui_status.modelStatus(app.liveRuntime(), app.cached_config) != null;
    var transcript_view: tx_widget.TranscriptWidget = .{
        .thread = lane,
        .gpa = app.gpa,
        .has_model_configured = has_model,
        .loading_frame = app.metrics.loading_frame,
        .blackhole_frame = app.metrics.blackhole_frame,
        .blackhole_visible = &app.metrics.blackhole_visible,
    };
    const title = if (lane.title) |t| t else "untitled";
    // Active-view marker (●/○) + turn-state marker (S14): a spinner frame
    // while the lane's turn is running, a stop glyph while interrupting, a
    // quiet dot when idle. A manual /compact on this lane spins the same
    // frame — the "lane is busy" signal the model watches for.
    const compacting = if (lane.agent) |agent| agent.manual_compact_pending else false;
    const state_glyph: []const u8 = if (compacting)
        tui_message.loading_frames[app.metrics.loading_frame % tui_message.loading_frames.len]
    else switch (lane.turn.state) {
        .active => tui_message.loading_frames[app.metrics.loading_frame % tui_message.loading_frames.len],
        .interrupting => "■",
        .idle => "·",
    };
    // Distinct marker on the lane the driver's workspace currently points at —
    // the "active lane tracking" the model needs to see at a glance.
    const ws_marker: []const u8 = if (driverWorkspacePath(app)) |ws| blk: {
        if (lanes_util.workingLaneOf(lane)) |w| {
            if (lanes_util.pathsEqual(ws, w.path)) break :blk " ⇄";
        }
        break :blk "";
    } else "";
    const label_text = try std.fmt.allocPrint(ctx.arena, "{s}{s} {s}{s}", .{
        if (active) "● " else "○ ",
        state_glyph,
        title,
        ws_marker,
    });
    var border: vxfw.Border = .{
        .child = transcript_view.widget(),
        .labels = &.{.{ .text = label_text, .alignment = .top_left }},
        .style = if (active) .{} else .{ .dim = true },
    };
    // The focused column — the right pane's worker in `.dual`, `app.thread` in
    // `.grid` — gets a high-contrast accent border when the knob is enabled.
    // `active` and `focused` are distinct: `active` marks the ●/dim state,
    // `focused` is the single column whose border is highlighted.
    if (focused and app.cached_config.tui.highlight_focused_border) {
        border.style = tui_style.activePalette().border_label;
    }
    return border.widget().draw(ctx.withConstraints(
        .{ .width = width, .height = height },
        .{ .width = width, .height = height },
    ));
}

pub const LaneColumnWidget = struct {
    app: *App,
    lane: *Thread,
    width: u16,
    height: u16,
    active: bool,
    focused: bool,

    pub fn widget(self: *LaneColumnWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = draw,
        };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *LaneColumnWidget = @ptrCast(@alignCast(ptr));
        return drawLaneColumn(self.app, ctx, self.lane, self.width, self.height, self.active, self.focused);
    }
};
