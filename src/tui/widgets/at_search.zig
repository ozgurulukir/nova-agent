const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const panel = @import("panel.zig");
const tui_style = @import("../style.zig");
const config_mod = @import("../../config/config.zig");

/// Layout policy shared with the floating-panel host (see `tui.zig`). The body
/// shows one row for the empty/status message or up to `max_visible_rows`
/// results, wrapped in a single-cell border on top and bottom.
pub const max_visible_rows = 8;
pub const border_rows = 2;

/// Total panel height, including the border, for the given result count.
pub fn panelHeight(result_count: usize) u16 {
    const rows: u16 = if (result_count == 0)
        1
    else
        @intCast(@min(result_count, max_visible_rows));
    return rows + border_rows;
}

const tui = @import("../../tui.zig");
const App = tui.App;

/// AtSearchWidget — thin wrapper that creates a `Content` from App state and draws it.
pub const AtSearchWidget = struct {
    app: *App,

    pub fn widget(self: *AtSearchWidget) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *AtSearchWidget = @ptrCast(@alignCast(ptr));
        const notice: []const u8 = if (self.app.at_search == .open)
            self.app.at_search.open.notice orelse ""
        else
            "";
        var content: Content = .{
            .results = self.app.at_search.results.items,
            .selection = self.app.at_search.selection,
            .query = self.app.at_search.query,
            .indexing = self.app.at_search.indexing,
            .sigil = if (self.app.at_search.kind == .file) '@' else '$',
            .title = if (self.app.at_search.kind == .file) "Files" else "Skills",
            .notice = notice,
            .highlight_enabled = self.app.cached_config.tui.fuzzy_highlight,
            .highlight_style = self.app.cached_config.tui.fuzzy_highlight_style,
        };
        return content.widget().draw(ctx);
    }
};

/// Index of the first result to render so `selection` is within the `visible`
/// rows. Keeps the selection pinned to the bottom edge once it scrolls past
/// the fold; snaps back to the top while it still fits without scrolling.
fn firstVisible(selection: u32, count: u32, visible: u16) u32 {
    if (visible == 0 or count <= visible) return 0;
    if (selection < visible) return 0;
    return @min(selection - visible + 1, count - visible);
}

pub const Content = struct {
    results: []const []const u8,
    selection: u32,
    query: []const u8,
    indexing: bool = false,
    sigil: u8 = '@',
    title: []const u8 = "Files",
    /// Optional inline notice shown below results (e.g. a search error).
    notice: []const u8 = "",
    highlight_enabled: bool = true,
    highlight_style: config_mod.FuzzyHighlightStyle = .accent,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn emptyMessage(self: *const Content) []const u8 {
        if (self.indexing) return "Indexing…";
        if (self.query.len == 0) {
            if (self.sigil == '$') return "Type a skill after $";
            return "Type a path after @";
        }
        return "No matches";
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const p = tui_style.activePalette();
        var body: Body = .{ .content = self };
        var border: vxfw.Border = .{
            .child = body.widget(),
            .style = p.thinking_body,
            .labels = &.{.{ .text = self.title, .alignment = .top_left }},
        };
        return border.widget().draw(ctx);
    }
};

const Body = struct {
    content: *Content,

    fn widget(self: *Body) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Body = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});

        const content = self.content;
        if (content.results.len == 0) {
            try panel.lineAt(&surface, 0, content.emptyMessage(), ctx, false, 0);
            if (content.notice.len > 0 and surface.size.height > 1) {
                try panel.lineAt(&surface, 1, "! ", ctx, false, 0);
                try panel.lineAt(&surface, 1, content.notice, ctx, false, 2);
            }
            return surface;
        }

        // Scroll the visible window so the selection stays on screen even when
        // there are more results than fit (height < results.len).
        const count: u32 = @intCast(content.results.len);
        const first = firstVisible(content.selection, count, surface.size.height);
        var row: u16 = 0;
        while (row < surface.size.height and first + row < count) : (row += 1) {
            const index = first + row;
            const selected = index == content.selection;
            try panel.drawFuzzyListRow(&surface, row, ctx, .{
                .prefix = "  ",
                .text = content.results[index],
                .query = content.query,
                .selected = selected,
                .start_col = 0,
                .highlight_enabled = content.highlight_enabled,
                .highlight_style = content.highlight_style,
            });
        }
        if (content.notice.len > 0 and row < surface.size.height) {
            try panel.lineAt(&surface, row, "! ", ctx, false, 0);
            try panel.lineAt(&surface, row, content.notice, ctx, false, 2);
        }
        return surface;
    }
};

test "at_search draws a selected result without overrunning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const results = [_][]const u8{ "src/agent.zig", "src/ai.zig", "src/tui.zig" };
    var content: Content = .{ .results = &results, .selection = 1, .query = "src" };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 40, .height = 6 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try content.widget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 40), surface.size.width);
}

test "firstVisible keeps the selection within the window" {
    // Everything fits: no scrolling.
    try std.testing.expectEqual(@as(u32, 0), firstVisible(0, 5, 8));
    try std.testing.expectEqual(@as(u32, 0), firstVisible(4, 5, 8));
    // Selection still above the fold.
    try std.testing.expectEqual(@as(u32, 0), firstVisible(7, 50, 8));
    // Selection past the fold pins to the bottom edge.
    try std.testing.expectEqual(@as(u32, 1), firstVisible(8, 50, 8));
    try std.testing.expectEqual(@as(u32, 12), firstVisible(19, 50, 8));
    // Selection near the end keeps it pinned to the bottom edge / last window.
    try std.testing.expectEqual(@as(u32, 38), firstVisible(45, 50, 8));
    try std.testing.expectEqual(@as(u32, 42), firstVisible(49, 50, 8));
}

test "rendersNotice_whenResultsEmptyAndNoticePresent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const results = [_][]const u8{};
    var content: Content = .{ .results = &results, .selection = 0, .query = "foo", .notice = "Search index building" };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 40, .height = 4 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const outer_surface = try content.widget().draw(ctx);
    try std.testing.expect(outer_surface.children.len > 0);
    const inner_surface = outer_surface.children[0].surface;

    var buf: [64]u8 = undefined;
    var len: usize = 0;
    var col: u16 = 0;
    while (col < inner_surface.size.width) : (col += 1) {
        const cell = inner_surface.readCell(col, 1);
        if (cell.default) continue;
        const grapheme = cell.char.grapheme;
        if (len + grapheme.len > buf.len) break;
        @memcpy(buf[len..][0..grapheme.len], grapheme);
        len += grapheme.len;
    }
    try std.testing.expectEqualStrings("! Search index building", buf[0..len]);
}

test "rendersNotice_whenResultsPresentAndNoticePresent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const results = [_][]const u8{ "src/agent.zig", "src/ai.zig" };
    var content: Content = .{ .results = &results, .selection = 0, .query = "src", .notice = "Search error: timeout" };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 40, .height = 6 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const outer_surface = try content.widget().draw(ctx);
    try std.testing.expect(outer_surface.children.len > 0);
    const inner_surface = outer_surface.children[0].surface;

    // Row 0 and 1 have results, row 2 has the notice.
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    var col: u16 = 0;
    while (col < inner_surface.size.width) : (col += 1) {
        const cell = inner_surface.readCell(col, 2);
        if (cell.default) continue;
        const grapheme = cell.char.grapheme;
        if (len + grapheme.len > buf.len) break;
        @memcpy(buf[len..][0..grapheme.len], grapheme);
        len += grapheme.len;
    }
    try std.testing.expectEqualStrings("! Search error: timeout", buf[0..len]);
}
