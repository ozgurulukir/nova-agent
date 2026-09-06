//! Top-level `drawRoot` layout.
//!
//! Pulled out of `tui.zig` (R6.2 of `_pm/Projects/tui-split`) — the RootWidget's
//! `draw` callback. Decides, per frame, what the screen shows: a single transcript
//! column or a 2-wide tiled grid, the loading spinner strip when a turn is
//! running, the bordered input box, and (stacked above the input by descending
//! priority) the centered mode overlay, the permission prompt, the background-jobs
//! modal, and the at-mention search popup.
//!
//! The diff viewer short-circuits this layout entirely via `drawDiffViewer`.
//!
//! Free function taking `*App` and the outer `vxfw.Widget` handle, matching the
//! pattern R5.2b established for `drawDiffViewer`.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../tui.zig");
const root_layout = @import("layout.zig");
const lane_column = @import("lane_column.zig");
const diff_viewer_overlay = @import("diff_viewer_overlay.zig");
const tui_status = @import("status.zig");
const tx_widget = @import("widgets/transcript.zig");
const loading = @import("widgets/loading.zig");
const input_mod = @import("widgets/input.zig");
const permission = @import("widgets/permission.zig");
const background_jobs = @import("widgets/background_jobs.zig");
const at_search = @import("widgets/at_search.zig");
const overlay = @import("widgets/overlay.zig");
const toast = @import("toast.zig");
const at_search_mod = @import("at_search.zig");
const search_mod = @import("../search.zig");

const App = tui.App;

const log = std.log.scoped(.root_layout);

pub fn drawRoot(app: *App, root_widget: vxfw.Widget, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    // The diff viewer replaces the whole screen (transcript + input + overlay),
    // so it short-circuits the normal layout entirely. Zero the split-rect
    // stash here too — the normal path that clears it is skipped, so otherwise
    // `routeMouse` would keep hit-testing stale split geometry while the diff
    // viewer is up.
    if (app.mode == .diff_viewer) {
        app.split_rect_count = 0;
        return diff_viewer_overlay.drawDiffViewer(app, root_widget, ctx);
    }
    const max_width = ctx.max.width orelse ctx.min.width;
    const max_height = ctx.max.height orelse ctx.min.height;
    const loading_visible = app.thread.turn_view.awaitingOutput();
    const split = app.split_mode != .tab and app.threads.len() > 1;
    // In split view always reserve the loading row so each column keeps a
    // fixed height across turns — the spinner appearing must not reflow.
    const layout = root_layout.rootLayout(max_height, false, try app.inputTextRows(ctx, max_width -| 4), loading_visible or split, app.thread.queued.items.len > 0);
    // Compute the split geometry once and stash it for mouse click-to-focus
    // routing (event_router.routeMouse), so the render path and the mouse
    // handler share one source of truth. `split_rect_count` is set
    // unconditionally so leaving split mode (or the diff viewer early-return)
    // leaves it 0 and the mouse handler stops hit-testing stale geometry.
    var split_cols: []const root_layout.ColumnRect = &.{};
    var split_rects: [4]root_layout.ColumnRect = undefined;
    if (split) {
        split_cols = root_layout.computeSplitLayout(max_width, layout.transcript_height, app.split_mode, app.threads.len(), app.focused_worker_index, app.cached_config.tui.min_split_width, &split_rects);
        app.split_rects = split_rects;
    }
    app.split_rect_count = split_cols.len;
    app.input_surface_row = layout.input_row;
    app.nav.lanes_chip_rect = null;

    // INV-WIDGET-1: leaf widgets take scalars, computed here per frame.
    const has_model = tui_status.modelStatus(app.liveRuntime(), app.cached_config) != null;
    var transcript_view: tx_widget.TranscriptWidget = .{
        .thread = app.thread,
        .gpa = app.gpa,
        .has_model_configured = has_model,
        .loading_frame = app.metrics.loading_frame,
        .blackhole_frame = app.metrics.blackhole_frame,
        .blackhole_visible = &app.metrics.blackhole_visible,
    };
    var loading_view: loading.LoadingWidget = .{
        .awaiting_output = app.thread.turn_view.awaitingOutput(),
        .word_index = app.thread.turn_view.loading_word_index,
        .loading_frame = app.metrics.loading_frame,
    };
    var input_view: input_mod.InputWidget = .{ .app = app };
    var overlay_view: overlay.OverlayWidget = .{ .app = app };

    const overlay_visible = app.mode != .normal;
    const permission_visible = app.permissionPending() and !overlay_visible;
    const background_visible = app.background_modal_state.modal and !overlay_visible and !permission_visible;
    const at_visible = (app.at_search != .closed) and !overlay_visible and !permission_visible and !background_visible;
    const toast_visible = toast.global.hasToasts();

    // Top area: single transcript or split grid/dual columns.
    var transcript_box: vxfw.SizedBox = undefined;
    var dual_lane_widgets: [2]lane_column.LaneColumnWidget = undefined;
    var dual_lane_boxes: [2]vxfw.SizedBox = undefined;
    var dual_flex_items: [2]vxfw.FlexItem = undefined;
    var dual_row: vxfw.FlexRow = undefined;
    var grid_lane_widgets: [4]lane_column.LaneColumnWidget = undefined;
    var grid_lane_boxes: [4]vxfw.SizedBox = undefined;
    var grid_row0_buf: [2]vxfw.FlexItem = undefined;
    var grid_row1_buf: [2]vxfw.FlexItem = undefined;
    var grid_row0_flex: vxfw.FlexRow = undefined;
    var grid_row1_flex: vxfw.FlexRow = undefined;
    var grid_rows_buf: [2]vxfw.FlexItem = undefined;
    var grid_col: vxfw.FlexColumn = undefined;
    var split_box: vxfw.SizedBox = undefined;

    const top_widget = if (split) blk: {
        if (app.split_mode == .dual) {
            for (split_cols, 0..) |col, i| {
                const lane = app.threads.slice()[col.lane_index];
                const worker_focus = @max(@min(app.focused_worker_index, app.threads.len() - 1), 1);
                const active = (col.lane_index == 0) or (col.lane_index == worker_focus);
                const focused = (col.lane_index == worker_focus);
                dual_lane_widgets[i] = .{
                    .app = app,
                    .lane = lane,
                    .width = col.width,
                    .height = col.height,
                    .active = active,
                    .focused = focused,
                };
                dual_lane_boxes[i] = .{
                    .child = dual_lane_widgets[i].widget(),
                    .size = .{ .width = col.width, .height = col.height },
                };
                dual_flex_items[i] = .{ .widget = dual_lane_boxes[i].widget(), .flex = 0 };
            }
            dual_row = .{ .children = dual_flex_items[0..split_cols.len] };
            split_box = .{
                .child = dual_row.widget(),
                .size = .{ .width = max_width, .height = layout.transcript_height },
            };
            break :blk split_box.widget();
        } else {
            var row0_count: usize = 0;
            var row1_count: usize = 0;
            for (split_cols, 0..) |col, i| {
                const lane = app.threads.slice()[col.lane_index];
                const active = (col.lane_index == @as(usize, app.activeIndex()));
                const focused = (col.lane_index == @as(usize, app.activeIndex()));
                grid_lane_widgets[i] = .{
                    .app = app,
                    .lane = lane,
                    .width = col.width,
                    .height = col.height,
                    .active = active,
                    .focused = focused,
                };
                grid_lane_boxes[i] = .{
                    .child = grid_lane_widgets[i].widget(),
                    .size = .{ .width = col.width, .height = col.height },
                };
                if (col.row == 0) {
                    grid_row0_buf[row0_count] = .{ .widget = grid_lane_boxes[i].widget(), .flex = 0 };
                    row0_count += 1;
                } else {
                    grid_row1_buf[row1_count] = .{ .widget = grid_lane_boxes[i].widget(), .flex = 0 };
                    row1_count += 1;
                }
            }
            grid_row0_flex = .{ .children = grid_row0_buf[0..row0_count] };
            grid_rows_buf[0] = .{ .widget = grid_row0_flex.widget(), .flex = 0 };
            var grid_rows_count: usize = 1;
            if (row1_count > 0) {
                grid_row1_flex = .{ .children = grid_row1_buf[0..row1_count] };
                grid_rows_buf[1] = .{ .widget = grid_row1_flex.widget(), .flex = 0 };
                grid_rows_count = 2;
            }
            grid_col = .{ .children = grid_rows_buf[0..grid_rows_count] };
            split_box = .{
                .child = grid_col.widget(),
                .size = .{ .width = max_width, .height = layout.transcript_height },
            };
            break :blk split_box.widget();
        }
    } else blk: {
        transcript_box = .{
            .child = transcript_view.widget(),
            .size = .{ .width = max_width, .height = layout.transcript_height },
        };
        break :blk transcript_box.widget();
    };

    var main_flex_buf: [3]vxfw.FlexItem = undefined;
    var main_flex_count: usize = 0;

    main_flex_buf[main_flex_count] = .{ .widget = top_widget, .flex = 1 };
    main_flex_count += 1;

    const include_loading = split or loading_visible;
    var loading_box: vxfw.SizedBox = undefined;
    if (include_loading) {
        loading_box = .{
            .child = loading_view.widget(),
            .size = .{ .width = max_width, .height = layout.loading_height },
        };
        main_flex_buf[main_flex_count] = .{ .widget = loading_box.widget(), .flex = 0 };
        main_flex_count += 1;
    }

    var input_box: vxfw.SizedBox = .{
        .child = input_view.widget(),
        .size = .{ .width = max_width, .height = layout.input_height },
    };
    main_flex_buf[main_flex_count] = .{ .widget = input_box.widget(), .flex = 0 };
    main_flex_count += 1;

    var main_col: vxfw.FlexColumn = .{ .children = main_flex_buf[0..main_flex_count] };
    const main_surface = try main_col.widget().draw(ctx.withConstraints(
        .{ .width = max_width, .height = max_height },
        .{ .width = max_width, .height = max_height },
    ));

    var child_count: usize = 1;
    if (overlay_visible) child_count += 1;
    if (permission_visible) child_count += 1;
    if (background_visible) child_count += 1;
    if (at_visible) child_count += 1;
    if (toast_visible) child_count += 1;
    const children = try ctx.arena.alloc(vxfw.SubSurface, child_count);
    children[0] = .{
        .origin = .{ .row = 0, .col = 0 },
        .surface = main_surface,
        .z_index = 0,
    };
    var idx: usize = 1;
    if (overlay_visible) {
        var centered_overlay: vxfw.Center = .{ .child = overlay_view.widget() };
        children[idx] = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try centered_overlay.widget().draw(ctx.withConstraints(
                .{ .width = max_width, .height = layout.transcript_height },
                .{ .width = max_width, .height = layout.transcript_height },
            )),
            .z_index = 2,
        };
        idx += 1;
    }
    if (permission_visible) {
        var permission_view: permission.PermissionWidget = .{ .app = app };
        const panel_height: u16 = @min(@as(u16, 12), @max(@as(u16, 5), layout.input_row));
        children[idx] = .{
            .origin = .{ .row = layout.input_row -| panel_height, .col = 0 },
            .surface = try permission_view.widget().draw(ctx.withConstraints(
                .{ .width = max_width, .height = panel_height },
                .{ .width = max_width, .height = panel_height },
            )),
            .z_index = 3,
        };
        idx += 1;
    }
    if (background_visible) {
        var jobs_view: background_jobs.BackgroundJobsWidget = .{ .app = app };
        const rows: u16 = @intCast(@min(@as(usize, 8), app.runningBackgroundCount()));
        const panel_height: u16 = @min(layout.input_row, rows + 4);
        children[idx] = .{
            .origin = .{ .row = layout.input_row -| panel_height, .col = 0 },
            .surface = try jobs_view.widget().draw(ctx.withConstraints(
                .{ .width = max_width, .height = panel_height },
                .{ .width = max_width, .height = panel_height },
            )),
            .z_index = 3,
        };
        idx += 1;
    }
    if (at_visible) {
        // Poll async search results before drawing, so the popup reflects
        // any completed background fuzzy search immediately.
        at_search_mod.pollAtSearch(app) catch |err| {
            // Surface the failure in the popup footer so the user isn't
            // staring at stale/empty results with no hint.
            log.warn("at-search poll failed: {s}", .{@errorName(err)});

            at_search_mod.setSearchNotice(app, @errorName(err));
        };
        // Display any backend failure message when the index is in the failed
        // state but the popup is still open.
        if (app.at_search == .open and app.at_search.open.kind == .file) {
            if (search_mod.backend.lastFailure(app.gpa)) |msg| {
                defer app.gpa.free(msg);
                if (app.at_search.open.notice == null or app.at_search.open.notice.?.len == 0) {
                    at_search_mod.setSearchNotice(app, msg);
                }
            }
        }
        var at_view: tui.AtSearchWidget = .{ .app = app };
        const panel_height = at_search.panelHeight(app.at_search.results().len);
        const panel_width = @min(@as(u16, 72), max_width);
        children[idx] = .{
            .origin = .{ .row = layout.input_row -| panel_height, .col = 0 },
            .surface = try at_view.widget().draw(ctx.withConstraints(
                .{ .width = panel_width, .height = panel_height },
                .{ .width = panel_width, .height = panel_height },
            )),
            .z_index = 1,
        };
        idx += 1;
    }
    if (toast_visible) {
        // Top-right toast stack, above every other child (z_index 4).
        const toast_w: u16 = @min(max_width, 60);
        var toast_view: toast.Widget = .{ .bus = &toast.global };
        children[idx] = .{
            .origin = .{ .row = 0, .col = max_width -| toast_w },
            .surface = try toast_view.widget().draw(ctx.withConstraints(
                .{ .width = toast_w, .height = max_height },
                .{ .width = toast_w, .height = max_height },
            )),
            .z_index = 4,
        };
        idx += 1;
    }

    return .{
        .size = .{ .width = max_width, .height = max_height },
        .widget = root_widget,
        .buffer = &.{},
        .children = children,
    };
}
