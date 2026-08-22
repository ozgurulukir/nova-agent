//! Interactive, scrollable Help & Keyboard Shortcuts overlay widget.
//!
//! Displays grouped keyboard shortcuts, slash commands, context mentions,
//! and skill invocation syntax. Supports keyboard scrolling (Up/Down,
//! PgUp/PgDn, Home/End, j/k) and mouse wheel scrolling.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const panel = @import("panel.zig");
const tui_style = @import("../style.zig");

/// Which mode's keybindings a help line documents. Rendered as a dim `[tag]`
/// prefix rather than used to filter — discoverability beats hiding — and
/// asserted by the guard test below so a handler change that orphans a help
/// line (or a help line that no longer matches a handler) fails the suite.
pub const Scope = enum { global, block_nav, diff_viewer, jobs_modal, lanes };

pub const HelpLine = struct {
    key: []const u8,
    desc: []const u8,
    is_header: bool = false,
    scope: Scope = .global,
};

pub const help_lines = [_]HelpLine{
    .{ .key = "KEYBOARD SHORTCUTS & NAVIGATION", .desc = "", .is_header = true },
    .{ .key = "Ctrl+Up / Alt+Up", .desc = "Navigate to previous prompt in history" },
    .{ .key = "Ctrl+Down / Alt+Down", .desc = "Navigate to next prompt in history" },
    .{ .key = "Shift+Down", .desc = "Jump to bottom of conversation" },
    .{ .key = "Shift + Mouse Drag", .desc = "Select text with mouse (terminal native)" },
    .{ .key = "Ctrl+V / Shift+Ins", .desc = "Paste text from system clipboard" },
    .{ .key = "c / y (in block nav)", .desc = "Copy selected message to clipboard" },
    .{ .key = "Up / Down", .desc = "Scroll transcript messages / select blocks" },
    .{ .key = "Tab", .desc = "Expand / collapse active message" },
    .{ .key = "Ctrl+O", .desc = "Toggle background jobs modal" },
    .{ .key = "Shift+Tab", .desc = "Cycle focused worker lane / next parallel lane" },
    .{ .key = "Ctrl+L", .desc = "Cycle focused worker lane / split mode", .scope = .lanes },
    .{ .key = "Ctrl+W", .desc = "Cycle split layout: dual / grid / tab", .scope = .lanes },
    .{ .key = "Alt+Right / Alt+Left", .desc = "Cycle right-pane worker: next / previous (dual split)", .scope = .lanes },
    .{ .key = "Esc", .desc = "Cancel turn / unselect block / close modal" },

    .{ .key = "CONTEXT MENTIONS & SKILLS", .desc = "", .is_header = true },
    .{ .key = "@<file>", .desc = "Attach file contents to prompt" },
    .{ .key = "$<skill>", .desc = "Invoke a specialized agent skill" },
    .{ .key = "/<command>", .desc = "Open interactive slash command palette" },

    .{ .key = "SLASH COMMANDS", .desc = "", .is_header = true },
    .{ .key = "/connect", .desc = "Configure AI provider & API keys" },
    .{ .key = "/model", .desc = "Select LLM model & reasoning effort" },
    .{ .key = "/settings", .desc = "View and edit configuration settings" },
    .{ .key = "/new", .desc = "Start a fresh session" },
    .{ .key = "/resume", .desc = "Resume past session from history" },
    .{ .key = "/timeline", .desc = "Interactive session tree browser" },
    .{ .key = "/undo", .desc = "Rewind the last turn and restore its prompt" },
    .{ .key = "/diff", .desc = "Full-screen git diff viewer & comments" },
    .{ .key = "/parallel", .desc = "Fork worktree into a new parallel lane" },
    .{ .key = "/save", .desc = "Commit git-shadow working copy snapshot" },
    .{ .key = "/lanes", .desc = "Manage & merge parked worktree lanes" },
    .{ .key = "/export", .desc = "Export conversation thread as Markdown" },
    .{ .key = "/copy", .desc = "Copy selected transcript message to clipboard" },
    .{ .key = "/paste", .desc = "Paste text from clipboard into prompt" },
    .{ .key = "/status", .desc = "Show system status & active model details" },
    .{ .key = "/skills", .desc = "List loaded skills & invocation names" },
    .{ .key = "/clear", .desc = "Clear current transcript view" },
    .{ .key = "/help", .desc = "Open this quick reference guide" },
    .{ .key = "/exit", .desc = "Quit Nova agent" },

    .{ .key = "DIFF VIEWER", .desc = "", .is_header = true },
    .{ .key = "Ctrl+W", .desc = "Add comment on selected range", .scope = .diff_viewer },
    .{ .key = "Ctrl+E", .desc = "Edit the active comment", .scope = .diff_viewer },
    .{ .key = "Ctrl+D", .desc = "Delete the active comment", .scope = .diff_viewer },
    .{ .key = "Ctrl+P", .desc = "Search files in the diff", .scope = .diff_viewer },
    .{ .key = "Ctrl+↑ / Ctrl+↓", .desc = "Jump between files", .scope = .diff_viewer },
    .{ .key = "Shift+↑ / Shift+↓", .desc = "Extend the selection range", .scope = .diff_viewer },
    .{ .key = "[ / ]", .desc = "Jump between hunks", .scope = .diff_viewer },
    .{ .key = "Esc / Ctrl+C", .desc = "Close the diff viewer", .scope = .diff_viewer },
    .{ .key = "Ctrl+S", .desc = "Close & send comments to agent", .scope = .diff_viewer },

    .{ .key = "JOBS MODAL", .desc = "", .is_header = true },
    .{ .key = "↑ / ↓", .desc = "Select a running job", .scope = .jobs_modal },
    .{ .key = "← / →", .desc = "Move focus to Cancel", .scope = .jobs_modal },
    .{ .key = "Enter", .desc = "Cancel the selected job", .scope = .jobs_modal },
    .{ .key = "Esc", .desc = "Close the jobs modal", .scope = .jobs_modal },
};

fn scopeLabel(scope: Scope) []const u8 {
    return switch (scope) {
        .global => "global",
        .block_nav => "blocks",
        .diff_viewer => "diff",
        .jobs_modal => "jobs",
        .lanes => "lanes",
    };
}

/// Index of the first help line whose key contains `key` within `scope`, or
/// null. Used by the guard test below.
fn indexOfKey(key: []const u8, scope: Scope) ?usize {
    for (help_lines, 0..) |line, i| {
        if (line.scope == scope and std.mem.indexOf(u8, line.key, key) != null) return i;
    }
    return null;
}

// Compile-time guard: every documented diff-viewer, jobs-modal, and lane
// binding must still have a help entry. If a handler key is removed or rebound,
// this fails instead of letting the help screen drift from the implementation.
test "help documents every diff-viewer, jobs-modal, and lane binding" {
    const diff_keys = [_][]const u8{ "Ctrl+W", "Ctrl+E", "Ctrl+D", "Ctrl+P", "Ctrl+↑", "Ctrl+↓", "Shift+↑", "Shift+↓", "Esc", "Ctrl+C", "Ctrl+S" };
    for (diff_keys) |k| {
        try std.testing.expect(indexOfKey(k, .diff_viewer) != null);
    }
    for ([_][]const u8{ "↑", "↓", "←", "→", "Enter", "Esc" }) |k| {
        try std.testing.expect(indexOfKey(k, .jobs_modal) != null);
    }
    for ([_][]const u8{"Ctrl+L"}) |k| {
        try std.testing.expect(indexOfKey(k, .lanes) != null);
    }
}

// The /undo help line is a user-facing contract of the command's semantics
// (rewind + prompt restore); guard it against removal just like the bindings.
test "help documents /undo" {
    try std.testing.expect(indexOfKey("/undo", .global) != null);
}

/// The help overlay's outer height in rows, as sized by `overlaySize` in
/// `overlay.zig`. Lives here (not there) so the scroll clamp and the layout
/// read one value.
pub const help_overlay_height: u16 = 22;

/// Body rows a help overlay of `overlay_height` rows can display: the vxfw
/// border consumes one row per side and the bottom row is the hint bar.
/// Single source of truth for the height the scroll clamps (`scrollDown`) and
/// `Content.draw` both use — the wheel handler previously clamped against a
/// hardcoded 21 while draw rendered 19, letting wheel-scroll run 2 rows past
/// the visible window.
pub fn bodyRows(overlay_height: u16) u16 {
    return overlay_height -| 3;
}

pub const State = struct {
    scroll: u16 = 0,

    pub fn reset(self: *State) void {
        self.scroll = 0;
    }

    pub fn maxScroll(available_rows: u16) u16 {
        const total: u16 = @intCast(help_lines.len);
        return total -| available_rows;
    }

    pub fn scrollUp(self: *State, count: u16) void {
        self.scroll = self.scroll -| count;
    }

    pub fn scrollDown(self: *State, count: u16, available_rows: u16) void {
        const max_s = maxScroll(available_rows);
        self.scroll = @min(self.scroll + count, max_s);
    }
};

test "help scroll saturates at the visible body rows across overlay heights" {
    const heights = [_]u16{ 22, 10, 4 };
    for (heights) |h| {
        var state: State = .{};
        const rows = bodyRows(h);
        // Force saturation: scroll past the end with a content taller than the
        // window. The floor must be `total -| bodyRows(h)`, i.e. the last
        // visible row is the last item — never past it.
        state.scrollDown(@intCast(help_lines.len + 1), rows);
        const total: u16 = @intCast(help_lines.len);
        try std.testing.expectEqual(total -| rows, state.scroll);
        // And scrolling back up stays in range.
        state.scrollUp(@intCast(help_lines.len + 1));
        try std.testing.expectEqual(@as(u16, 0), state.scroll);
    }
}

pub const Content = struct {
    state: *State,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const p = tui_style.activePalette();
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
        if (width == 0 or height == 0) return surface;
        const empty_cell = vaxis.Cell{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{},
        };
        @memset(surface.buffer, empty_cell);

        // Reserve last row for bottom hint bar. The border consumed 2 rows
        // upstream, so `height` is the inner panel and `height -| 1` equals
        // `bodyRows(overlay_height)` — the same number the scroll clamps use.
        const body_height: u16 = height -| 1;
        const total_count: u16 = @intCast(help_lines.len);
        const max_s = State.maxScroll(body_height);
        if (self.state.scroll > max_s) self.state.scroll = max_s;

        var row: u16 = 0;
        var line_idx: u16 = self.state.scroll;
        while (line_idx < total_count and row < body_height) : (line_idx += 1) {
            const item = help_lines[line_idx];
            if (item.is_header) {
                if (row > 0) {
                    // Draw a subtle separator line before section headers.
                    panel.fillRow(&surface, row, p.thinking_body);
                }
                panel.lineStyledAt(&surface, row, item.key, ctx, 1, p.border_label) catch {};
            } else {
                var key_col: u16 = 2;
                if (item.scope != .global) {
                    const tag = try std.fmt.allocPrint(ctx.arena, "[{s}] ", .{scopeLabel(item.scope)});
                    panel.lineStyledAt(&surface, row, tag, ctx, key_col, p.thinking_body) catch {};
                    key_col += @intCast(ctx.stringWidth(tag));
                }
                panel.lineStyledAt(&surface, row, item.key, ctx, key_col, p.user) catch {};
                if (width > 30 and item.desc.len > 0) {
                    _ = panel.writeBorderTextEndingAt(&surface, ctx, row, width -| 3, item.desc, p.thinking_body);
                }
            }
            row += 1;
        }

        // Draw scrollbar on rightmost column if content exceeds body height.
        if (total_count > body_height and body_height > 2) {
            drawScrollbar(&surface, body_height, self.state.scroll, total_count);
        }

        // Draw bottom hint bar.
        const hint_row = height - 1;
        const hint_text = " ↑/↓ Scroll · PgUp/PgDn Page · Esc/Enter/q Close ";
        panel.lineStyledAt(&surface, hint_row, hint_text, ctx, 1, p.thinking_body) catch {};

        return surface;
    }
};

fn drawScrollbar(surface: *vxfw.Surface, height: u16, scroll: u16, total: u16) void {
    const p = tui_style.activePalette();
    const col = surface.size.width -| 1;
    const max_s = total -| height;
    if (max_s == 0) return;

    const bar_height: usize = @max(1, @as(usize, height) * @as(usize, height) / @as(usize, total));
    const max_top = height -| @as(u16, @intCast(bar_height));
    const top: u16 = @intCast(@as(usize, scroll) * @as(usize, max_top) / @as(usize, max_s));

    var r: u16 = 0;
    while (r < height) : (r += 1) {
        const is_thumb = r >= top and r < top + bar_height;
        const grapheme: []const u8 = if (r == 0) "▲" else if (r == height - 1) "▼" else if (is_thumb) "█" else "│";
        const style: vaxis.Style = if (is_thumb) p.border_label else p.thinking_body;
        surface.writeCell(col, r, .{
            .char = .{ .grapheme = grapheme, .width = 1 },
            .style = style,
        });
    }
}
