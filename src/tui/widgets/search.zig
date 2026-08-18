//! Transcript search overlay widget: the match list shown under the shared
//! palette search row while `Mode.search` is active.
//!
//! The state (`State`) and the pure scan live here; the mode lifecycle
//! (open/close/jump) lives in `search_lifecycle.zig`, mirroring the
//! resume-picker (`widgets/resume_picker.zig` + `session_switcher.zig`) split.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const panel = @import("panel.zig");
const tui_style = @import("../style.zig");
const transcript_mod = @import("../../transcript.zig");

const StylePalette = tui_style.Palette;

/// One transcript match. `snippet` is owned (duped at rebuild time): the
/// overlay does NOT pause streaming — a turn keeps projecting deltas onto the
/// transcript while search is open, and `appendOwned`'s realloc can move (and
/// free) the very body a borrowed snippet pointed into. `role` is a static
/// literal from `searchable` and stays borrowed.
pub const Match = struct {
    message_index: u32,
    role: []const u8,
    snippet: []const u8,
};

pub const State = struct {
    matches: std.ArrayList(Match) = .empty,
    selection: u32 = 0,
    /// True when the palette filter is empty (the overlay shows a usage hint
    /// rather than a "No matching messages" row).
    filter_empty: bool = true,

    pub fn reset(self: *State, gpa: std.mem.Allocator) void {
        self.freeSnippets(gpa);
        self.matches.clearRetainingCapacity();
        self.selection = 0;
        self.filter_empty = true;
    }

    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        self.freeSnippets(gpa);
        self.matches.deinit(gpa);
        self.* = undefined;
    }

    fn freeSnippets(self: *State, gpa: std.mem.Allocator) void {
        for (self.matches.items) |*match| {
            gpa.free(match.snippet);
            match.snippet = "";
        }
    }
};

/// The role label + display title/body a message contributes to search.
/// `.logo`/`.status` carry no searchable content.
pub const Searchable = struct {
    role: []const u8,
    title: []const u8,
    body: []const u8,
};

pub fn searchable(message: transcript_mod.Message) ?Searchable {
    return switch (message) {
        .user => |m| .{ .role = "user", .title = m.title, .body = m.body },
        .agent => |m| .{ .role = "agent", .title = m.title, .body = m.body },
        .notice => |m| .{ .role = "notice", .title = m.title, .body = m.body },
        .success => |m| .{ .role = "success", .title = m.title, .body = m.body },
        .info => |m| .{ .role = "info", .title = m.title, .body = m.body },
        .tool => |t| .{ .role = "tool", .title = t.title, .body = t.body },
        .skill => |m| .{ .role = "skill", .title = m.title, .body = m.body },
        .thinking => |m| .{ .role = "thinking", .title = m.title, .body = m.body },
        .logo, .status => null,
    };
}

pub const Content = struct {
    state: *State,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
        if (width == 0 or height == 0) return surface;

        const matches = self.state.matches.items;
        if (matches.len == 0) {
            // Empty query: hint at the workflow. Non-empty query with no hits:
            // the "No matching messages" row (same house pattern as the command
            // palette's "No matching commands").
            const hint = if (self.state.filter_empty)
                "  Type to search this transcript · Enter jumps · Esc closes"
            else
                "  No matching messages";
            panel.lineStyledAt(&surface, 0, hint, ctx, 1, StylePalette.thinking_body) catch {};
            return surface;
        }

        // Viewport math: only the visible rows are drawn, so a pathological
        // match count can never blow up the overlay.
        const viewport = panel.ViewportWindow.compute(self.state.selection, @intCast(matches.len), height);
        var match_idx = viewport.start_index;
        while (match_idx < viewport.end_index) : (match_idx += 1) {
            const m = matches[match_idx];
            const selected = match_idx == self.state.selection;
            const screen_row = viewport.screenRow(match_idx);
            var label_buf: [64]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "{d} {s}  ", .{ m.message_index, m.role }) catch unreachable;
            try panel.commandLine(&surface, screen_row, label, ctx, selected);
            if (m.snippet.len > 0 and width > 24) {
                const desc_style = if (selected) StylePalette.selected_item else StylePalette.thinking_body;
                _ = panel.writeBorderTextEndingAt(&surface, ctx, screen_row, width -| 2, m.snippet, desc_style);
            }
        }
        return surface;
    }
};

// ---------------------------------------------------------------------------
// Tests

fn readRow(surface: *const vxfw.Surface, row: u16, out: []u8) []const u8 {
    var len: usize = 0;
    var col: u16 = 0;
    while (col < surface.size.width) : (col += 1) {
        const cell = surface.readCell(col, row);
        if (cell.default) continue;
        const grapheme = cell.char.grapheme;
        if (len + grapheme.len > out.len) break;
        @memcpy(out[len..][0..grapheme.len], grapheme);
        len += grapheme.len;
    }
    return out[0..len];
}

test "search content shows a no-matches row for a non-empty query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: State = .{ .filter_empty = false };
    var content: Content = .{ .state = &state };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 60, .height = 5 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try content.widget().draw(ctx);
    var buf: [128]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, readRow(&surface, 0, &buf), "No matching messages") != null);
}

test "search content shows a usage hint when the filter is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: State = .{ .filter_empty = true };
    var content: Content = .{ .state = &state };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 60, .height = 5 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try content.widget().draw(ctx);
    var buf: [128]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, readRow(&surface, 0, &buf), "Type to search") != null);
}
