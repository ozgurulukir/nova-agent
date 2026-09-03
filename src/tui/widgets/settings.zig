//! Settings panel widget.
//!
//! Displayed when the user opens `/settings`. Shows a multi-section
//! configuration screen with live toggle controls and a multi-line
//! system-prompt editor. Sections:
//!
//!   General   — use_responses_endpoint
//!   Prompt    — system_prompt multi-line editor
//!   Advanced  — bash_classifier_url
//!   About     — version, config paths
//!
//! Navigation: Tab/Shift-Tab cycle sections; Up/Down move the selection
//! within a section; Enter/Space toggle booleans or enter edit mode;
//! Ctrl+S (handled upstream) saves the in-progress edits.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const panel = @import("panel.zig");
const tui_style = @import("../style.zig");
const config_mod = @import("../../config/config.zig");
const input = @import("input.zig");

const assert = std.debug.assert;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const Tab = enum(u8) {
    general = 0,
    prompt = 1,
    advanced = 2,
    about = 3,

    pub fn next(self: Tab) Tab {
        return @enumFromInt((@intFromEnum(self) + 1) % tab_count);
    }

    pub fn previous(self: Tab) Tab {
        const i = @intFromEnum(self);
        return @enumFromInt(if (i == 0) tab_count - 1 else i - 1);
    }

    pub fn label(self: Tab) []const u8 {
        return switch (self) {
            .general => "General",
            .prompt => "System Prompt",
            .advanced => "Advanced",
            .about => "About",
        };
    }
};

const tab_count: u8 = @typeInfo(Tab).@"enum".fields.len;

/// Tracks the row selected within each tab's item list.
pub const TabSelection = [tab_count]u32;

pub const EditTarget = enum { none, system_prompt, bash_classifier_url };

pub const State = struct {
    tab: Tab = .general,
    selection: TabSelection = @splat(0),
    edit_target: EditTarget = .none,
    /// Pending (unsaved) edits — null means use the live cached_config value.
    pending_use_responses_endpoint: ?bool = null,
    /// Pending system prompt text (owned by App, edited via the settings input).
    pending_system_prompt: ?[]const u8 = null,
    /// Pending bash classifier URL.
    pending_bash_classifier_url: ?[]const u8 = null,
    /// Pending toast-notifications toggle.
    pending_toast_enabled: ?bool = null,
    /// True when there are unsaved changes.
    dirty: bool = false,

    pub fn reset(self: *State) void {
        const tab = self.tab;
        self.* = .{ .tab = tab };
    }

    pub fn hasPendingEdits(self: *const State) bool {
        return self.dirty;
    }

    pub fn itemCount(_: *const State, tab: Tab) u32 {
        return switch (tab) {
            .general => general_item_count,
            .prompt => prompt_item_count,
            .advanced => advanced_item_count,
            .about => about_item_count,
        };
    }

    pub fn currentSelection(self: *const State) u32 {
        return self.selection[@intFromEnum(self.tab)];
    }

    pub fn moveUp(self: *State) void {
        const idx = @intFromEnum(self.tab);
        const count = self.itemCount(self.tab);
        if (count == 0) return;
        const sel = self.selection[idx];
        self.selection[idx] = if (sel == 0) count - 1 else sel - 1;
    }

    pub fn moveDown(self: *State) void {
        const idx = @intFromEnum(self.tab);
        const count = self.itemCount(self.tab);
        if (count == 0) return;
        const sel = self.selection[idx];
        self.selection[idx] = if (sel + 1 >= count) 0 else sel + 1;
    }

    pub fn handleKey(self: *State, key: vaxis.Key) bool {
        // Tab section cycling.
        if (key.matches(vaxis.Key.tab, .{})) {
            self.tab = self.tab.next();
            self.edit_target = .none;
            return true;
        }
        if (key.matches(vaxis.Key.tab, .{ .shift = true })) {
            self.tab = self.tab.previous();
            self.edit_target = .none;
            return true;
        }
        if (key.matches(vaxis.Key.up, .{})) {
            self.moveUp();
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            self.moveDown();
            return true;
        }
        return false;
    }
};

// Item counts per section (used for wrapping navigation).
const general_item_count: u32 = 2; // use_responses_endpoint, toast_enabled
const prompt_item_count: u32 = 1; // system_prompt editor entry
const advanced_item_count: u32 = 1; // bash_classifier_url
const about_item_count: u32 = 0; // read-only info

// ---------------------------------------------------------------------------
// Content widget (outer drawing entry point)
// ---------------------------------------------------------------------------

/// Live config snapshot passed in per draw. No owned memory; caller
/// holds the config and the state.
pub const Content = struct {
    state: *State,
    config: *const config_mod.Config,
    home_dir: []const u8,
    cwd: []const u8,
    system_prompt_input: []const u8 = "",
    bash_classifier_input: []const u8 = "",
    version_string: []const u8 = @import("build").version,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(
            ctx.arena,
            self.widget(),
            .{ .width = width, .height = height },
            &.{},
        );

        try drawTabBar(&surface, ctx, self.state.tab);
        // Separator after tab bar.
        drawHorizontalRule(&surface, ctx, 1);

        // Section content starts at row 2.
        const section_height: u16 = height -| 2;
        _ = section_height;
        switch (self.state.tab) {
            .general => try self.drawGeneral(&surface, ctx),
            .prompt => try self.drawPrompt(&surface, ctx),
            .advanced => try self.drawAdvanced(&surface, ctx),
            .about => try self.drawAbout(&surface, ctx),
        }

        // Bottom hint row.
        try drawBottomHint(&surface, ctx, self.state);
        return surface;
    }

    // -----------------------------------------------------------------------
    // Tab bar (row 0)
    // -----------------------------------------------------------------------

    fn drawTabBar(surface: *vxfw.Surface, ctx: vxfw.DrawContext, active: Tab) !void {
        const p = tui_style.activePalette();
        const start_col: u16 = 2;
        var col: u16 = start_col;
        inline for (@typeInfo(Tab).@"enum".fields) |field| {
            const tab: Tab = @enumFromInt(field.value);
            const label = tab.label();
            const is_active = tab == active;
            const style: vaxis.Style = if (is_active)
                p.settings_active_tab
            else
                p.thinking_body;
            try panel.lineStyledAt(surface, 0, label, ctx, col, style);
            col += @intCast(ctx.stringWidth(label) + 2);
        }
    }

    // -----------------------------------------------------------------------
    // General section
    // -----------------------------------------------------------------------

    fn drawGeneral(self: *const Content, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        const p = tui_style.activePalette();
        const sel = self.state.selection[@intFromEnum(Tab.general)];

        // Row 2: section header.
        try panel.lineStyledAt(surface, 2, "GENERAL SETTINGS", ctx, left_col, p.panel_header);

        // Row 4: use_responses_endpoint toggle.
        {
            const selected = sel == 0;
            if (selected) panel.fillRow(surface, 4, p.selected);
            const value = self.state.pending_use_responses_endpoint orelse
                (if (self.config.model_selection) |ms| ms.useResponsesEndpoint() else false);
            const label = try std.fmt.allocPrint(ctx.arena, "  Use Responses Endpoint  {s}", .{boolBadge(value)});
            const style = if (selected) p.selected_item else p.thinking_body;
            try panel.lineStyledAt(surface, 4, label, ctx, left_col, style);
            const desc = "Route completions through the OpenAI Responses API instead of Chat Completions.";
            try self.drawDescription(surface, ctx, 5, desc, selected);
        }

        // Row 7: toast notifications toggle.
        {
            const selected = sel == 1;
            if (selected) panel.fillRow(surface, 7, p.selected);
            const value = self.state.pending_toast_enabled orelse
                (self.config.toast.enabled orelse true);
            const label = try std.fmt.allocPrint(ctx.arena, "  Toast Notifications  {s}", .{boolBadge(value)});
            const style = if (selected) p.selected_item else p.thinking_body;
            try panel.lineStyledAt(surface, 7, label, ctx, left_col, style);
            const desc = "Show transient notifications (e.g. warnings) in the top-right corner.";
            try self.drawDescription(surface, ctx, 8, desc, selected);
        }
    }

    // -----------------------------------------------------------------------
    // System Prompt section
    // -----------------------------------------------------------------------

    fn drawPrompt(self: *const Content, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        const p = tui_style.activePalette();
        const sel = self.state.selection[@intFromEnum(Tab.prompt)];
        const is_editing = self.state.edit_target == .system_prompt;

        // Row 2: section header.
        try panel.lineStyledAt(surface, 2, "SYSTEM PROMPT", ctx, left_col, p.panel_header);
        try panel.lineStyledAt(surface, 3, "Custom instructions prepended to every conversation.", ctx, left_col, p.thinking_body);

        // Row 5: prompt editor area.
        const selected = sel == 0;
        const border_style: vaxis.Style = if (is_editing)
            p.border_label
        else if (selected)
            p.selected_item
        else
            p.thinking_body;

        // Draw a simple bordered box for the prompt.
        drawBox(surface, ctx, 5, left_col, surface.size.width -| left_col -| 2, 7, border_style);

        // Show the active text (pending edit or config value).
        const text = if (is_editing)
            self.system_prompt_input
        else
            self.state.pending_system_prompt orelse
                (if (self.config.model_selection) |ms|
                    (ms.systemPrompt() orelse "")
                else
                    "");

        try drawWrappedText(surface, ctx, 6, left_col + 1, surface.size.width -| left_col -| 4, text, 5, p.info);

        if (is_editing) {
            const cursor_pos = input.wrappedPosition(text, text.len, surface.size.width -| left_col -| 4);
            surface.cursor = .{
                .row = @min(6 + cursor_pos.row, 10), // start_row + max_rows - 1
                .col = left_col + 1 + cursor_pos.col,
            };
        }

        // Edit hint row below the box.
        const hint_row: u16 = 13;
        if (is_editing) {
            try panel.lineStyledAt(surface, hint_row, "  Ctrl+S  Save prompt · Esc  Cancel", ctx, left_col, p.thinking_body);
        } else {
            try panel.lineStyledAt(surface, hint_row, "  Enter   Edit prompt · Del  Clear prompt", ctx, left_col, p.thinking_body);
        }
    }

    // -----------------------------------------------------------------------
    // Advanced section
    // -----------------------------------------------------------------------

    fn drawAdvanced(self: *const Content, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        const p = tui_style.activePalette();
        const sel = self.state.selection[@intFromEnum(Tab.advanced)];

        // Row 2: section header.
        try panel.lineStyledAt(surface, 2, "ADVANCED SETTINGS", ctx, left_col, p.panel_header);

        // Row 4: bash classifier URL.
        {
            const selected = sel == 0;
            if (selected) panel.fillRow(surface, 4, p.selected);
            const is_editing = self.state.edit_target == .bash_classifier_url;
            const url_text = if (is_editing)
                self.bash_classifier_input
            else
                self.state.pending_bash_classifier_url orelse
                    (if (self.config.model_selection) |ms|
                        (ms.bashClassifierUrl() orelse "")
                    else
                        "");
            const style = if (selected) p.selected_item else p.thinking_body;
            const label = "  Bash Classifier URL";
            try panel.lineStyledAt(surface, 4, label, ctx, left_col, style);
            const url_col = left_col + @as(u16, @intCast(ctx.stringWidth(label))) + 2;
            const display_url = if (url_text.len > 0) url_text else "(not set)";
            const url_style: vaxis.Style = if (selected) p.selected_item else p.model_status;
            try panel.lineStyledAt(surface, 4, display_url, ctx, url_col, url_style);
            if (is_editing) {
                const w = @as(u16, @intCast(ctx.stringWidth(url_text)));
                surface.cursor = .{ .row = 4, .col = url_col + w };
            }
            const desc = "Override the remote bash-safety classifier endpoint (leave empty to use built-in).";
            try self.drawDescription(surface, ctx, 5, desc, selected);
        }
    }

    // -----------------------------------------------------------------------
    // About section
    // -----------------------------------------------------------------------

    fn drawAbout(self: *const Content, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        const p = tui_style.activePalette();
        _ = self.state;
        try panel.lineStyledAt(surface, 2, "ABOUT NOVA", ctx, left_col, p.panel_header);
        try panel.lineStyledAt(surface, 4, self.version_string, ctx, left_col, p.info);

        // Config file paths.
        try panel.lineStyledAt(surface, 6, "Configuration Files", ctx, left_col, p.panel_header);

        const global_path = try std.fmt.allocPrint(ctx.arena, "  Global config : {s}/.config/nova/config.json", .{self.home_dir});
        try panel.lineStyledAt(surface, 7, global_path, ctx, left_col, p.thinking_body);

        const project_path = try std.fmt.allocPrint(ctx.arena, "  Project config: {s}/.nova/config.json", .{self.cwd});
        try panel.lineStyledAt(surface, 8, project_path, ctx, left_col, p.thinking_body);

        const auth_path = try std.fmt.allocPrint(ctx.arena, "  API keys      : {s}/.config/nova/auth.json", .{self.home_dir});
        try panel.lineStyledAt(surface, 9, auth_path, ctx, left_col, p.thinking_body);

        try panel.lineStyledAt(surface, 11, "Config Layer Priority  (later overrides earlier)", ctx, left_col, p.panel_header);
        try panel.lineStyledAt(surface, 12, "  1. Built-in defaults", ctx, left_col, p.thinking_body);
        try panel.lineStyledAt(surface, 13, "  2. Global config  (~/.config/nova/config.json)", ctx, left_col, p.thinking_body);
        try panel.lineStyledAt(surface, 14, "  3. Project config (.nova/config.json)", ctx, left_col, p.thinking_body);
        try panel.lineStyledAt(surface, 15, "  4. Environment variables (OPENAI_MODEL, OPENAI_API_KEY, …)", ctx, left_col, p.thinking_body);
    }

    // -----------------------------------------------------------------------
    // Shared helpers
    // -----------------------------------------------------------------------

    fn drawDescription(
        self: *const Content,
        surface: *vxfw.Surface,
        ctx: vxfw.DrawContext,
        row: u16,
        text: []const u8,
        selected: bool,
    ) !void {
        _ = self;
        const p = tui_style.activePalette();
        const style = if (selected) p.thinking_body else p.thinking_body;
        try panel.lineStyledAt(surface, row, text, ctx, left_col + 2, style);
    }
};

// ---------------------------------------------------------------------------
// Bottom hint strip
// ---------------------------------------------------------------------------

fn drawBottomHint(surface: *vxfw.Surface, ctx: vxfw.DrawContext, state: *const State) !void {
    const p = tui_style.activePalette();
    const row = surface.size.height -| 1;
    const dirty_marker: []const u8 = if (state.dirty) " ● unsaved" else "";
    const hint = try std.fmt.allocPrint(ctx.arena, "Tab next section · Up/Down navigate · Enter toggle/edit · Ctrl+S save{s}", .{dirty_marker});
    const style: vaxis.Style = if (state.dirty) p.notice else p.thinking_body;
    try panel.lineStyledAt(surface, row, hint, ctx, left_col, style);
}

// ---------------------------------------------------------------------------
// Drawing utilities
// ---------------------------------------------------------------------------

const left_col: u16 = 1;

fn drawHorizontalRule(surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16) void {
    _ = ctx;
    if (row >= surface.size.height) return;
    const p = tui_style.activePalette();
    var col: u16 = 0;
    while (col < surface.size.width) : (col += 1) {
        surface.writeCell(col, row, .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = p.thinking_body,
        });
    }
}

fn drawBox(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    top_row: u16,
    start_col: u16,
    width: u16,
    height: u16,
    style: vaxis.Style,
) void {
    _ = ctx;
    if (width < 2 or height < 2) return;
    const bottom_row = top_row + height - 1;
    if (bottom_row >= surface.size.height) return;
    const end_col = start_col + width - 1;

    // Top border.
    surface.writeCell(start_col, top_row, .{ .char = .{ .grapheme = "┌", .width = 1 }, .style = style });
    surface.writeCell(end_col, top_row, .{ .char = .{ .grapheme = "┐", .width = 1 }, .style = style });
    var c: u16 = start_col + 1;
    while (c < end_col) : (c += 1) {
        surface.writeCell(c, top_row, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = style });
    }

    // Bottom border.
    surface.writeCell(start_col, bottom_row, .{ .char = .{ .grapheme = "└", .width = 1 }, .style = style });
    surface.writeCell(end_col, bottom_row, .{ .char = .{ .grapheme = "┘", .width = 1 }, .style = style });
    c = start_col + 1;
    while (c < end_col) : (c += 1) {
        surface.writeCell(c, bottom_row, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = style });
    }

    // Side borders.
    var r: u16 = top_row + 1;
    while (r < bottom_row) : (r += 1) {
        surface.writeCell(start_col, r, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = style });
        surface.writeCell(end_col, r, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = style });
    }
}

/// Draw text that may wrap across multiple rows. At most `max_rows` are drawn.
fn drawWrappedText(
    surface: *vxfw.Surface,
    ctx: vxfw.DrawContext,
    start_row: u16,
    start_col: u16,
    max_width: u16,
    text: []const u8,
    max_rows: u16,
    style: vaxis.Style,
) !void {
    if (max_width == 0 or max_rows == 0) return;
    var row = start_row;
    var col: u16 = start_col;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        if (row >= start_row + max_rows) break;
        if (row >= surface.size.height) break;
        const bytes = grapheme.bytes(text);
        if (std.mem.eql(u8, bytes, "\n")) {
            row += 1;
            col = start_col;
            continue;
        }
        const w: u16 = @intCast(ctx.stringWidth(bytes));
        if (w == 0) continue;
        if (col + w > start_col + max_width) {
            row += 1;
            col = start_col;
            if (row >= start_row + max_rows) break;
        }
        if (col < surface.size.width) {
            surface.writeCell(col, row, .{
                .char = .{ .grapheme = bytes, .width = @intCast(w) },
                .style = style,
            });
        }
        col += w;
    }
}

fn boolBadge(value: bool) []const u8 {
    return if (value) "[ON] " else "[OFF]";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "settings tab cycles forward and back" {
    var state: State = .{};
    try std.testing.expectEqual(Tab.general, state.tab);
    _ = state.handleKey(.{ .codepoint = vaxis.Key.tab });
    try std.testing.expectEqual(Tab.prompt, state.tab);
    _ = state.handleKey(.{ .codepoint = vaxis.Key.tab });
    try std.testing.expectEqual(Tab.advanced, state.tab);
    _ = state.handleKey(.{ .codepoint = vaxis.Key.tab });
    try std.testing.expectEqual(Tab.about, state.tab);
    _ = state.handleKey(.{ .codepoint = vaxis.Key.tab });
    try std.testing.expectEqual(Tab.general, state.tab);
    _ = state.handleKey(.{ .codepoint = vaxis.Key.tab, .mods = .{ .shift = true } });
    try std.testing.expectEqual(Tab.about, state.tab);
}

test "settings selection wraps within section" {
    var state: State = .{};
    try std.testing.expectEqual(@as(u32, 0), state.currentSelection());
    state.moveDown(); // general has two items — moves to the second
    try std.testing.expectEqual(@as(u32, 1), state.currentSelection());
    state.moveDown(); // wraps back to the first
    try std.testing.expectEqual(@as(u32, 0), state.currentSelection());
    state.moveUp(); // wraps to the last
    try std.testing.expectEqual(@as(u32, 1), state.currentSelection());
}

test "settings boolBadge returns correct label" {
    try std.testing.expectEqualStrings("[ON] ", boolBadge(true));
    try std.testing.expectEqualStrings("[OFF]", boolBadge(false));
}
