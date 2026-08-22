//! The status bar widget: right-aligned telemetry segments (velocity, meter,
//! model status).
//!
//! Composed from vxfw layout widgets (`FlexRow`, `Text`, `SizedBox`) so the
//! bar degrades gracefully on narrow terminals: velocity drops first, meter
//! second, model status always visible (ellipsis-truncated if it alone exceeds
//! width).

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../../tui.zig");
const tui_style = @import("../style.zig");
const tui_status = @import("../status.zig");
const telemetry = @import("../telemetry.zig");

const App = tui.App;
const Palette = tui_style.Palette;

/// A single status bar segment descriptor.
pub const Segment = struct {
    text: []const u8,
    style: vaxis.Style,
    width: u16,
};

/// The result of `layoutStatusBar`: which segments survive and their combined
/// width (including the 1-cell gap before the meter, when present).
pub const Layout = struct {
    segments: []const Segment,
    total_width: u16,
};

/// Transparent 1x1 spacer widget: lets the border `─` show through the gap
/// between the left block and the meter.
const spacer_dummy: u8 = 0;
const spacer_widget = vxfw.Widget{
    .userdata = @ptrCast(@constCast(&spacer_dummy)),
    .drawFn = drawSpacer,
};

fn drawSpacer(_: *anyopaque, _: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    return vxfw.Surface{
        .size = .{ .width = 1, .height = 1 },
        .widget = spacer_widget,
        .buffer = &.{},
        .children = &.{},
    };
}

/// Compute which status bar segments survive within `available_width`.
///
/// Priority: status always (ellipsized if alone and too wide); add meter if it
/// fits; add velocity if it fits after that. The left block (velocity+status or
/// just one of them) is separated from the meter by a 1-cell gap.
///
/// Pure: no I/O.
pub fn layoutStatusBar(
    arena: std.mem.Allocator,
    available_width: u16,
    velocity_text: []const u8,
    meter_text: []const u8,
    meter_style: vaxis.Style,
    status_text: []const u8,
    status_style: vaxis.Style,
) Layout {
    if (available_width == 0) {
        return .{ .segments = &.{}, .total_width = 0 };
    }

    const status_width: u16 = @intCast(@min(vaxis.gwidth.gwidth(status_text, .unicode), std.math.maxInt(u16)));
    const meter_width: u16 = @intCast(@min(vaxis.gwidth.gwidth(meter_text, .unicode), std.math.maxInt(u16)));
    const velocity_width: u16 = @intCast(@min(vaxis.gwidth.gwidth(velocity_text, .unicode), std.math.maxInt(u16)));

    const has_velocity = velocity_text.len > 0 and velocity_width > 0;
    const has_status = status_text.len > 0 and status_width > 0;
    const has_meter = meter_text.len > 0 and meter_width > 0;

    const full_left_width: u16 = if (has_velocity and has_status)
        velocity_width + 2 + status_width
    else if (has_velocity)
        velocity_width
    else
        status_width;

    const gap_width: u16 = if (has_meter and full_left_width > 0) 1 else 0;
    const all_three_width = full_left_width + gap_width + (if (has_meter) meter_width else 0);

    // 1. Check if all three (or whatever is present including velocity) fit.
    if (has_velocity and all_three_width <= available_width) {
        const left_text = if (has_status)
            std.fmt.allocPrint(arena, "{s}  {s}", .{ velocity_text, status_text }) catch status_text
        else
            velocity_text;

        var count: usize = 0;
        if (full_left_width > 0) count += 1;
        if (has_meter) count += 1;

        const segs = arena.alloc(Segment, count) catch return .{ .segments = &.{}, .total_width = 0 };
        var idx: usize = 0;
        if (full_left_width > 0) {
            segs[idx] = .{ .text = left_text, .style = status_style, .width = full_left_width };
            idx += 1;
        }
        if (has_meter) {
            segs[idx] = .{ .text = meter_text, .style = meter_style, .width = meter_width };
            idx += 1;
        }
        return .{
            .segments = segs,
            .total_width = all_three_width,
        };
    }

    // 2. Velocity dropped (or not present). Try status + meter.
    const status_gap_width: u16 = if (has_meter and has_status) 1 else 0;
    const status_meter_width = status_width + status_gap_width + (if (has_meter) meter_width else 0);

    if (has_meter and status_meter_width <= available_width) {
        var count: usize = 0;
        if (has_status) count += 1;
        count += 1; // meter

        const segs = arena.alloc(Segment, count) catch return .{ .segments = &.{}, .total_width = 0 };
        var idx: usize = 0;
        if (has_status) {
            segs[idx] = .{ .text = status_text, .style = status_style, .width = status_width };
            idx += 1;
        }
        segs[idx] = .{ .text = meter_text, .style = meter_style, .width = meter_width };
        return .{
            .segments = segs,
            .total_width = status_meter_width,
        };
    }

    // 3. Meter dropped (or not present). Try status only.
    if (status_width <= available_width) {
        if (!has_status) {
            return .{ .segments = &.{}, .total_width = 0 };
        }
        const segs = arena.alloc(Segment, 1) catch return .{ .segments = &.{}, .total_width = 0 };
        segs[0] = .{ .text = status_text, .style = status_style, .width = status_width };
        return .{
            .segments = segs,
            .total_width = status_width,
        };
    }

    // 4. Status alone exceeds available_width: truncate/ellipsize status.
    const segs = arena.alloc(Segment, 1) catch return .{ .segments = &.{}, .total_width = 0 };
    segs[0] = .{ .text = status_text, .style = status_style, .width = available_width };
    return .{
        .segments = segs,
        .total_width = available_width,
    };
}

pub const StatusBarWidget = struct {
    app: *App,

    pub fn widget(self: *StatusBarWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = draw,
        };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *StatusBarWidget = @ptrCast(@alignCast(ptr));
        const max_width = ctx.max.width orelse ctx.min.width;
        const p = tui_style.activePalette();

        // Resolve segment texts and styles exactly as drawInputBorder did.
        const status_text = if (tui_status.modelStatus(self.app.liveRuntime(), self.app.cached_config)) |status|
            tui_status.formatModelStatus(ctx.arena, status) catch "no model"
        else
            "no model";

        const live_context_max: u32 = if (self.app.liveRuntime()) |rt|
            rt.agent.context_window_tokens
        else if (self.app.metrics.context_tokens_max > 0)
            self.app.metrics.context_tokens_max
        else
            128000;

        const live_context_used: u32 = if (self.app.liveRuntime()) |rt|
            rt.agent.currentContextTokens()
        else if (self.app.metrics.context_tokens_used > 0)
            self.app.metrics.context_tokens_used
        else
            0;

        const tui_cfg = self.app.cached_config.tui;
        var meter_buf: [64]u8 = undefined;
        var meter_text: []const u8 = "";
        var meter_style = p.model_status;
        if (tui_cfg.show_context_meter) {
            const meter = telemetry.TelemetryTracker.formatContextBar(
                @intCast(live_context_used),
                @intCast(live_context_max),
                tui_cfg.context_threshold_warn,
                tui_cfg.context_threshold_alert,
                &meter_buf,
            );
            meter_text = try ctx.arena.dupe(u8, meter.text);
            meter_style = switch (meter.level) {
                .normal => p.success,
                .warn => p.notice,
                .alert => p.error_style,
            };
        }
        var velocity_buf: [32]u8 = undefined;
        var velocity_text: []const u8 = "";
        if (tui_cfg.show_token_velocity) {
            const is_streaming = switch (self.app.thread.turn_view.activity) {
                .writing_response, .thinking => true,
                else => false,
            };
            const vel = telemetry.TelemetryTracker.formatVelocity(self.app.metrics.telemetry.current_tokens_per_sec, is_streaming, &velocity_buf);
            if (vel.len > 0) {
                velocity_text = try ctx.arena.dupe(u8, vel);
            }
        }

        const available_width = max_width -| 2;
        const layout = layoutStatusBar(
            ctx.arena,
            available_width,
            velocity_text,
            meter_text,
            meter_style,
            status_text,
            p.model_status,
        );

        if (layout.segments.len == 0 or layout.total_width == 0) {
            return vxfw.Surface{
                .size = .{ .width = max_width, .height = 1 },
                .widget = self.widget(),
                .buffer = &.{},
                .children = &.{},
            };
        }

        var flex_children_buf: [3]vxfw.FlexItem = undefined;
        var child_count: usize = 0;

        var text_widgets: [2]vxfw.Text = undefined;
        var box_widgets: [2]vxfw.SizedBox = undefined;

        if (layout.segments.len == 1) {
            text_widgets[0] = .{
                .text = layout.segments[0].text,
                .softwrap = false,
                .overflow = .ellipsis,
                .width_basis = .longest_line,
                .style = layout.segments[0].style,
            };
            box_widgets[0] = .{
                .child = text_widgets[0].widget(),
                .size = .{ .width = layout.segments[0].width, .height = 1 },
            };
            flex_children_buf[0] = .{ .widget = box_widgets[0].widget(), .flex = 0 };
            child_count = 1;
        } else if (layout.segments.len == 2) {
            text_widgets[0] = .{
                .text = layout.segments[0].text,
                .softwrap = false,
                .overflow = .ellipsis,
                .width_basis = .longest_line,
                .style = layout.segments[0].style,
            };
            box_widgets[0] = .{
                .child = text_widgets[0].widget(),
                .size = .{ .width = layout.segments[0].width, .height = 1 },
            };
            flex_children_buf[0] = .{ .widget = box_widgets[0].widget(), .flex = 0 };

            flex_children_buf[1] = .{ .widget = spacer_widget, .flex = 0 };

            text_widgets[1] = .{
                .text = layout.segments[1].text,
                .softwrap = false,
                .overflow = .ellipsis,
                .width_basis = .longest_line,
                .style = layout.segments[1].style,
            };
            box_widgets[1] = .{
                .child = text_widgets[1].widget(),
                .size = .{ .width = layout.segments[1].width, .height = 1 },
            };
            flex_children_buf[2] = .{ .widget = box_widgets[1].widget(), .flex = 0 };

            child_count = 3;
        }

        const flex_children = flex_children_buf[0..child_count];
        var flex_row: vxfw.FlexRow = .{ .children = flex_children };
        const flex_surface = try flex_row.widget().draw(ctx);

        const origin_col = (max_width -| 2) -| layout.total_width;
        const child_buf = try ctx.arena.alloc(vxfw.SubSurface, 1);
        child_buf[0] = .{
            .origin = .{ .row = 0, .col = origin_col },
            .surface = flex_surface,
            .z_index = 0,
        };

        return vxfw.Surface{
            .size = .{ .width = max_width, .height = 1 },
            .widget = self.widget(),
            .buffer = &.{},
            .children = child_buf,
        };
    }
};

// --- Tests ---

test "layoutStatusBar keeps all three when they fit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const meter_style: vaxis.Style = .{ .fg = .{ .index = 2 } };
    const status_style: vaxis.Style = .{ .fg = .{ .index = 7 } };

    const layout = layoutStatusBar(
        arena.allocator(),
        50,
        "⚡ 5.0",
        "[███░░░] 50%",
        meter_style,
        "openai · gpt-4",
        status_style,
    );
    try std.testing.expectEqual(@as(usize, 2), layout.segments.len);
    try std.testing.expectEqualStrings("⚡ 5.0  openai · gpt-4", layout.segments[0].text);
    try std.testing.expectEqual(@as(u16, 22), layout.segments[0].width);
    try std.testing.expectEqualStrings("[███░░░] 50%", layout.segments[1].text);
    try std.testing.expectEqual(@as(u16, 12), layout.segments[1].width);
    try std.testing.expectEqual(@as(u16, 35), layout.total_width);
}

test "layoutStatusBar drops velocity when all three do not fit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const meter_style: vaxis.Style = .{ .fg = .{ .index = 2 } };
    const status_style: vaxis.Style = .{ .fg = .{ .index = 7 } };

    // available_width = 30: 34 (all three) doesn't fit, but 27 (status + gap + meter = 14 + 1 + 12) fits.
    const layout = layoutStatusBar(
        arena.allocator(),
        30,
        "⚡ 5.0",
        "[███░░░] 50%",
        meter_style,
        "openai · gpt-4",
        status_style,
    );
    try std.testing.expectEqual(@as(usize, 2), layout.segments.len);
    try std.testing.expectEqualStrings("openai · gpt-4", layout.segments[0].text);
    try std.testing.expectEqual(@as(u16, 14), layout.segments[0].width);
    try std.testing.expectEqualStrings("[███░░░] 50%", layout.segments[1].text);
    try std.testing.expectEqual(@as(u16, 12), layout.segments[1].width);
    try std.testing.expectEqual(@as(u16, 27), layout.total_width);
}

test "layoutStatusBar drops meter when meter+status do not fit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const meter_style: vaxis.Style = .{ .fg = .{ .index = 2 } };
    const status_style: vaxis.Style = .{ .fg = .{ .index = 7 } };

    // available_width = 20: 27 (status + meter) doesn't fit, but 14 (status) fits.
    const layout = layoutStatusBar(
        arena.allocator(),
        20,
        "⚡ 5.0",
        "[███░░░] 50%",
        meter_style,
        "openai · gpt-4",
        status_style,
    );
    try std.testing.expectEqual(@as(usize, 1), layout.segments.len);
    try std.testing.expectEqualStrings("openai · gpt-4", layout.segments[0].text);
    try std.testing.expectEqual(@as(u16, 14), layout.segments[0].width);
    try std.testing.expectEqual(@as(u16, 14), layout.total_width);
}

test "layoutStatusBar truncates/ellipsizes status when alone and too wide" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const meter_style: vaxis.Style = .{ .fg = .{ .index = 2 } };
    const status_style: vaxis.Style = .{ .fg = .{ .index = 7 } };

    // available_width = 10: 14 (status) doesn't fit -> truncated to 10.
    const layout = layoutStatusBar(
        arena.allocator(),
        10,
        "⚡ 5.0",
        "[███░░░] 50%",
        meter_style,
        "openai · gpt-4",
        status_style,
    );
    try std.testing.expectEqual(@as(usize, 1), layout.segments.len);
    try std.testing.expectEqualStrings("openai · gpt-4", layout.segments[0].text);
    try std.testing.expectEqual(@as(u16, 10), layout.segments[0].width);
    try std.testing.expectEqual(@as(u16, 10), layout.total_width);
}

test "layoutStatusBar skips empty velocity and meter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const meter_style: vaxis.Style = .{ .fg = .{ .index = 2 } };
    const status_style: vaxis.Style = .{ .fg = .{ .index = 7 } };

    const layout = layoutStatusBar(
        arena.allocator(),
        20,
        "",
        "",
        meter_style,
        "openai · gpt-4",
        status_style,
    );
    try std.testing.expectEqual(@as(usize, 1), layout.segments.len);
    try std.testing.expectEqualStrings("openai · gpt-4", layout.segments[0].text);
    try std.testing.expectEqual(@as(u16, 14), layout.segments[0].width);
    try std.testing.expectEqual(@as(u16, 14), layout.total_width);
}

test "status bar rightmost segment lands at max_width - 3" {
    const gpa = std.testing.allocator;
    const agent_mod = @import("../../agent.zig");
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.cached_config = .{
        .tui = .{
            .show_token_velocity = true,
            .show_context_meter = true,
            .context_threshold_warn = 0.70,
            .context_threshold_alert = 0.85,
        },
    };
    app.metrics.git_label = try gpa.dupe(u8, "main");
    app.metrics.telemetry.current_tokens_per_sec = 10.0;
    app.thread.turn_view.activity = .{ .writing_response = 0 };

    var widget: StatusBarWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const max_width: u16 = 80;
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = max_width, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try widget.widget().draw(ctx);

    // The FlexRow is the only child, placed at origin.col = (max_width -| 2) -| total_width.
    try std.testing.expectEqual(@as(usize, 1), surface.children.len);
    const flex_origin = surface.children[0].origin.col;
    const available_width = max_width -| 2;
    const expected_origin = available_width -| surface.children[0].surface.size.width;
    try std.testing.expectEqual(expected_origin, flex_origin);

    // Rightmost segment's last cell = origin + width - 1 = max_width - 3.
    const rightmost_cell = flex_origin + surface.children[0].surface.size.width - 1;
    try std.testing.expectEqual(max_width -| 3, rightmost_cell);
}

test "StatusBarWidget renders velocity during thinking activity" {
    const gpa = std.testing.allocator;
    const agent_mod = @import("../../agent.zig");
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.cached_config = .{
        .tui = .{
            .show_token_velocity = true,
            .show_context_meter = true,
            .context_threshold_warn = 0.70,
            .context_threshold_alert = 0.85,
        },
    };
    app.metrics.telemetry.current_tokens_per_sec = 25.0;
    app.thread.turn_view.activity = .{ .thinking = 0 };

    var widget: StatusBarWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const max_width: u16 = 80;
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = max_width, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try widget.widget().draw(ctx);
    try std.testing.expectEqual(@as(usize, 1), surface.children.len);
    try std.testing.expect(surface.children[0].surface.size.width > 0);
}
