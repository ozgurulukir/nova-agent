const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const message = @import("message.zig");
const tui_style = @import("../style.zig");
const config_mod = @import("../../config/config.zig");

const secondary_column: u16 = 52;

pub const Shell = struct {
    child: vxfw.Widget,

    pub fn widget(self: *Shell) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Shell = @ptrCast(@alignCast(ptr));
        const p = tui_style.activePalette();
        var border: vxfw.Border = .{ .child = self.child, .style = p.tool };
        return border.widget().draw(ctx);
    }
};

pub fn listSurface(ctx: vxfw.DrawContext, owner: vxfw.Widget, list: vxfw.Widget) !vxfw.Surface {
    const width = ctx.max.width orelse 0;
    const height = ctx.max.height orelse 0;
    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    children[0] = .{
        .origin = .{ .row = 0, .col = 0 },
        .surface = try list.draw(ctx.withConstraints(
            .{ .width = width, .height = height },
            .{ .width = width, .height = height },
        )),
        .z_index = 0,
    };
    return vxfw.Surface.initWithChildren(ctx.arena, owner, .{ .width = width, .height = height }, children);
}

pub const ViewportWindow = struct {
    scroll_top: u32,
    start_index: u32,
    end_index: u32,
    visible_height: u32,

    pub fn compute(selection: u32, total_count: u32, height: u16) ViewportWindow {
        const visible_height: u32 = height;
        if (visible_height == 0 or total_count == 0) {
            return .{ .scroll_top = 0, .start_index = 0, .end_index = 0, .visible_height = 0 };
        }

        var scroll_top: u32 = 0;
        if (selection >= visible_height) {
            scroll_top = selection - visible_height + 1;
        }

        const end_index = @min(total_count, scroll_top + visible_height);
        return .{
            .scroll_top = scroll_top,
            .start_index = scroll_top,
            .end_index = end_index,
            .visible_height = visible_height,
        };
    }

    pub fn screenRow(self: ViewportWindow, index: u32) u16 {
        return @intCast(index - self.scroll_top);
    }
};

pub fn secondaryColumn(width: u16) u16 {
    return @min(secondary_column, width / 2);
}

pub fn commandLine(surface: *vxfw.Surface, row: u16, text: []const u8, ctx: vxfw.DrawContext, selected: bool) !void {
    try lineAt(surface, row, text, ctx, selected, message.ConversationLayout.left -| 1);
}

pub fn fillRow(surface: *vxfw.Surface, row: u16, style: vaxis.Style) void {
    if (row >= surface.size.height) return;
    var col: u16 = 0;
    while (col < surface.size.width) : (col += 1) {
        surface.writeCell(col, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
    }
}

pub fn lineAt(surface: *vxfw.Surface, row: u16, text: []const u8, ctx: vxfw.DrawContext, selected: bool, start_col: u16) !void {
    const p = tui_style.activePalette();
    if (selected) fillRow(surface, row, p.selected);
    const active_style = if (selected) p.selected_item else p.thinking_body;
    try lineStyledAt(surface, row, text, ctx, start_col, active_style);
}

pub fn lineStyledAt(surface: *vxfw.Surface, row: u16, text: []const u8, ctx: vxfw.DrawContext, start_col: u16, active_style: vaxis.Style) !void {
    if (row >= surface.size.height) return;
    if (start_col >= surface.size.width) return;
    const stable_text = try ctx.arena.dupe(u8, text);
    // A trailing `…` marks an overflow instead of silently dropping the tail.
    // The last column is reserved for it, so only `width - start_col - 1` cells
    // of text fit before truncation kicks in.
    const text_width: u16 = @intCast(@min(ctx.stringWidth(stable_text), std.math.maxInt(u16)));
    const truncated = text_width > surface.size.width -| start_col -| 1;
    var col: u16 = start_col;
    var iter = ctx.graphemeIterator(stable_text);
    while (iter.next()) |grapheme| {
        if (col + 1 >= surface.size.width) break;
        const bytes = grapheme.bytes(stable_text);
        const width: u8 = @intCast(ctx.stringWidth(bytes));
        if (width == 0) continue;
        // A truncated wide grapheme must not straddle the ellipsis column.
        if (truncated and col + width >= surface.size.width) break;
        surface.writeCell(col, row, .{
            .char = .{ .grapheme = bytes, .width = width },
            .style = active_style,
        });
        col += width;
    }
    if (truncated) {
        surface.writeCell(surface.size.width - 1, row, .{
            .char = .{ .grapheme = "…", .width = 1 },
            .style = active_style,
        });
    }
}

pub fn right(surface: *vxfw.Surface, row: u16, text: []const u8, ctx: vxfw.DrawContext, selected: bool) !void {
    const p = tui_style.activePalette();
    const active_style = if (selected) p.selected_item else p.thinking_body;
    try rightStyled(surface, row, text, ctx, active_style);
}

pub fn rightStyled(surface: *vxfw.Surface, row: u16, text: []const u8, ctx: vxfw.DrawContext, active_style: vaxis.Style) !void {
    if (row >= surface.size.height) return;
    const stable_text = try ctx.arena.dupe(u8, text);
    const text_width: u16 = @intCast(@min(ctx.stringWidth(stable_text), std.math.maxInt(u16)));
    const end_col = surface.size.width -| message.ConversationLayout.right;
    if (end_col == 0) return;
    if (text_width >= end_col) {
        // Right-aligned text is suffix-anchored: keep the tail and mark an
        // overflow with a leading `…` instead of letting the column vanish.
        const visible: u16 = end_col -| 1;
        const start = tailStart(stable_text, ctx, visible);
        surface.writeCell(0, row, .{
            .char = .{ .grapheme = "…", .width = 1 },
            .style = active_style,
        });
        var col: u16 = 1;
        var iter = ctx.graphemeIterator(stable_text[start..]);
        while (iter.next()) |grapheme| {
            if (col >= end_col) break;
            const bytes = grapheme.bytes(stable_text[start..]);
            const width: u16 = @intCast(ctx.stringWidth(bytes));
            if (width == 0) continue;
            if (col + width > end_col) break;
            surface.writeCell(col, row, .{
                .char = .{ .grapheme = bytes, .width = @intCast(width) },
                .style = active_style,
            });
            col += width;
        }
        return;
    }
    var col = end_col - text_width;
    var iter = ctx.graphemeIterator(stable_text);
    while (iter.next()) |grapheme| {
        if (col >= surface.size.width) return;
        const bytes = grapheme.bytes(stable_text);
        const width: u8 = @intCast(ctx.stringWidth(bytes));
        if (width == 0) continue;
        if (col + width > surface.size.width) return;
        surface.writeCell(col, row, .{
            .char = .{ .grapheme = bytes, .width = width },
            .style = active_style,
        });
        col += width;
    }
}

/// Byte offset into `text` of the longest suffix whose display width is at most
/// `max_cols`, never splitting a grapheme. Walks graphemes from the front,
/// dropping them until the remaining tail fits; assumes the whole text is wider
/// than `max_cols` (callers gate on that).
fn tailStart(text: []const u8, ctx: vxfw.DrawContext, max_cols: u16) usize {
    if (max_cols == 0) return text.len;
    const total: u16 = @intCast(@min(ctx.stringWidth(text), std.math.maxInt(u16)));
    var end: usize = 0;
    var dropped: u16 = 0;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const width: u16 = @intCast(ctx.stringWidth(bytes));
        const remaining = total -| dropped -| width;
        end += bytes.len;
        dropped += width;
        if (remaining <= max_cols) return end;
    }
    return text.len;
}

/// Draw `text` on `row` so its last cell ends at `end_col` (inclusive), filling
/// leftward. Returns the first column the text occupies — or `end_col + 1` when
/// nothing was drawn — so a caller can place another label further left.
///
/// NOTE: Kept for list-row trailing text / marks (fuzzy list rows, pickers), NOT for widget layout.
pub fn writeBorderTextEndingAt(surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16, end_col: u16, text: []const u8, style: vaxis.Style) u16 {
    if (text.len == 0 or row >= surface.size.height or end_col == 0) return end_col + 1;
    const text_w: u16 = @intCast(@min(ctx.stringWidth(text), std.math.maxInt(u16)));
    if (text_w == 0) return end_col + 1;
    if (text_w > end_col + 1) {
        // This helper right-anchors its text at `end_col`; keep the rightmost
        // `end_col` cells of an overlong label and mark the cut with `…` instead
        // of dropping the description entirely (callers rely on the right edge
        // staying put — descriptions hug the right border).
        const tail = tailStart(text, ctx, end_col);
        surface.writeCell(0, row, .{
            .char = .{ .grapheme = "…", .width = 1 },
            .style = style,
        });
        var col: u16 = 1;
        var iter = ctx.graphemeIterator(text[tail..]);
        while (iter.next()) |grapheme| {
            // The last cell must land on `end_col` (inclusive) — the same right
            // edge the fits-path uses — so truncation never shortens the block.
            if (col > end_col) break;
            const bytes = grapheme.bytes(text[tail..]);
            const width: u16 = @intCast(ctx.stringWidth(bytes));
            if (width == 0) continue;
            if (col + width > end_col + 1) break;
            surface.writeCell(col, row, .{
                .char = .{ .grapheme = bytes, .width = @intCast(width) },
                .style = style,
            });
            col += width;
        }
        return 0;
    }
    const start = end_col + 1 - text_w;
    var col = start;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const width: u16 = @intCast(ctx.stringWidth(bytes));
        if (width == 0) continue;
        if (col + width > end_col + 1) break;
        surface.writeCell(col, row, .{
            .char = .{ .grapheme = bytes, .width = @intCast(width) },
            .style = style,
        });
        col += width;
    }
    return start;
}

/// Greedy left-to-right subsequence match: for each query rune, find its first
/// occurrence at/after the cursor in `text`. Returns the number of matched byte
/// offsets written to `positions` (bounded by `positions.len`). Case-insensitive
/// on ASCII; non-ASCII runes compare by exact codepoint. No gpa allocation.
pub fn fuzzyMatchPositions(query: []const u8, text: []const u8, positions: []usize) usize {
    var matched: usize = 0;
    var text_offset: usize = 0;
    var q: usize = 0;
    while (q < query.len and matched < positions.len) {
        const q_len = std.unicode.utf8ByteSequenceLength(query[q]) catch break;
        const q_rune = query[q .. q + q_len];
        var found = false;
        while (text_offset < text.len) {
            const t_len = std.unicode.utf8ByteSequenceLength(text[text_offset]) catch break;
            const t_rune = text[text_offset .. text_offset + t_len];
            if (runeMatches(q_rune, t_rune)) {
                positions[matched] = text_offset;
                matched += 1;
                text_offset += t_len;
                found = true;
                break;
            }
            text_offset += t_len;
        }
        if (!found) break;
        q += q_len;
    }
    return matched;
}

/// Compare two decoded runes (as byte slices) for the fuzzy matcher: single-byte
/// (ASCII) runes compare case-insensitively; multi-byte runes compare exactly.
fn runeMatches(query: []const u8, text: []const u8) bool {
    if (query.len != text.len) return false;
    if (query.len == 1) return std.ascii.toLower(query[0]) == std.ascii.toLower(text[0]);
    return std.mem.eql(u8, query, text);
}

/// Options for `drawFuzzyListRow` — the shared row renderer for the five search
/// pickers. `start_col` is the leftmost cell (commandLine starts at col 1;
/// at_search draws at col 0). `base_style` overrides the default selected/
/// unselected base (model_picker passes its column-focus style).
pub const ListRowOptions = struct {
    prefix: []const u8 = "",
    text: []const u8,
    trailing_mark: ?[]const u8 = null,
    query: []const u8 = "",
    selected: bool = false,
    base_style: ?vaxis.Style = null,
    start_col: u16 = 1,
    highlight_enabled: bool = true,
    highlight_style: config_mod.FuzzyHighlightStyle = .accent,
};

/// Draw one picker list row: an optional prefix, the fuzzy-highlighted text, and
/// an optional right-anchored trailing mark. The default base style is
/// `p.thinking_body` (unselected) / `p.selected_item` (selected); `base_style`
/// overrides both. Text spans are passed as sub-slices to `lineStyledAt` (no
/// gpa allocation; the arena-bumped per-span dupes are cheap).
pub fn drawFuzzyListRow(surface: *vxfw.Surface, screen_row: u16, ctx: vxfw.DrawContext, options: ListRowOptions) !void {
    if (screen_row >= surface.size.height) return;
    const p = tui_style.activePalette();
    const base_style = options.base_style orelse (if (options.selected) p.selected_item else p.thinking_body);
    if (options.selected) fillRow(surface, screen_row, p.selected);

    const prefix_width: u16 = @intCast(@min(ctx.stringWidth(options.prefix), std.math.maxInt(u16)));
    const text_col: u16 = options.start_col + prefix_width;

    if (options.prefix.len > 0) {
        try lineStyledAt(surface, screen_row, options.prefix, ctx, options.start_col, base_style);
    }

    var pos_buf: [64]usize = undefined;
    const match_count = if (options.highlight_enabled and options.query.len > 0 and options.query.len <= pos_buf.len)
        fuzzyMatchPositions(options.query, options.text, &pos_buf)
    else
        0;

    if (match_count == 0) {
        try lineStyledAt(surface, screen_row, options.text, ctx, text_col, base_style);
    } else {
        const match_style = matchStyle(base_style, options.highlight_style);
        var span_start: usize = 0;
        for (pos_buf[0..match_count]) |match_byte| {
            if (match_byte > span_start) {
                const seg_col = textCol(ctx, text_col, options.text, span_start);
                try lineStyledAt(surface, screen_row, options.text[span_start..match_byte], ctx, seg_col, base_style);
            }
            const rlen = std.unicode.utf8ByteSequenceLength(options.text[match_byte]) catch 1;
            const match_col = textCol(ctx, text_col, options.text, match_byte);
            try lineStyledAt(surface, screen_row, options.text[match_byte .. match_byte + rlen], ctx, match_col, match_style);
            span_start = match_byte + rlen;
        }
        if (span_start < options.text.len) {
            const seg_col = textCol(ctx, text_col, options.text, span_start);
            try lineStyledAt(surface, screen_row, options.text[span_start..], ctx, seg_col, base_style);
        }
    }

    if (options.trailing_mark) |mark| {
        const mark_style = if (options.selected) p.selected_item else p.thinking_body;
        _ = writeBorderTextEndingAt(surface, ctx, screen_row, surface.size.width -| 1, mark, mark_style);
    }
}

/// The display column in `text` at a byte offset, relative to `base_col`.
fn textCol(ctx: vxfw.DrawContext, base_col: u16, text: []const u8, byte_offset: usize) u16 {
    const w: u16 = @intCast(@min(ctx.stringWidth(text[0..byte_offset]), std.math.maxInt(u16)));
    return base_col + w;
}

/// The style for matched runes, from a configurable `FuzzyHighlightStyle`.
fn matchStyle(base: vaxis.Style, style: config_mod.FuzzyHighlightStyle) vaxis.Style {
    const p = tui_style.activePalette();
    return switch (style) {
        .accent => .{ .fg = p.selected_item.fg, .bg = base.bg },
        .bold => .{ .fg = base.fg, .bold = true, .bg = base.bg },
        .underline => .{ .fg = base.fg, .ul_style = .single, .bg = base.bg },
    };
}

// ---------------------------------------------------------------------------
// Tests
//
// The panel drawing helpers used to drop overflowing text silently (a long
// command name just ended mid-air; a right-aligned column wider than its space
// vanished entirely). These tests lock in the truncation contract — the `…`
// marker, cell-level (not byte-level) boundaries for wide graphemes, and the
// right-anchored suffix semantics of `rightStyled` / `writeBorderTextEndingAt`.

fn testSurface(arena: std.mem.Allocator, width: u16, height: u16) !vxfw.Surface {
    return vxfw.Surface.init(arena, .{ .userdata = undefined, .drawFn = undefined }, .{ .width = width, .height = height });
}

/// Reconstruct a row's written graphemes, skipping default (never-written)
/// cells, so tests can assert on the rendered text without inspecting styles.
pub fn readRow(surface: *const vxfw.Surface, row: u16, out: []u8) []const u8 {
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

test "lineStyledAt fits exact-width text without an ellipsis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 12, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    var surface = try testSurface(arena.allocator(), 12, 1);
    try lineStyledAt(&surface, 0, "abcdef", ctx, 0, .{});
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("abcdef", readRow(&surface, 0, &buf));
}

test "lineStyledAt truncates with an ellipsis when text overflows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 7, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    // Overflow by one cell: six cells of text + the reserved ellipsis cell.
    var surface = try testSurface(arena.allocator(), 7, 1);
    try lineStyledAt(&surface, 0, "abcdefgh", ctx, 0, .{});
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("abcdef…", readRow(&surface, 0, &buf));

    // Overflow by many: the tail is cut to the available cells.
    var surface2 = try testSurface(arena.allocator(), 5, 1);
    try lineStyledAt(&surface2, 0, "abcdefghij", ctx, 0, .{});
    try std.testing.expectEqualStrings("abcd…", readRow(&surface2, 0, &buf));
}

test "lineStyledAt truncates wide graphemes at cell granularity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 5, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    // "日本語です" is 10 cells of width-2 graphemes; only 4 text cells fit.
    var surface = try testSurface(arena.allocator(), 5, 1);
    try lineStyledAt(&surface, 0, "日本語です", ctx, 0, .{});
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("日本…", readRow(&surface, 0, &buf));
}

test "lineStyledAt empty text writes nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 10, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    var surface = try testSurface(arena.allocator(), 10, 1);
    try lineStyledAt(&surface, 0, "", ctx, 0, .{});
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", readRow(&surface, 0, &buf));
}

test "rightStyled keeps the suffix with a leading ellipsis on overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 10, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    var buf: [64]u8 = undefined;

    // Fits: right-aligned, no marker.
    var fits = try testSurface(arena.allocator(), 10, 1);
    try rightStyled(&fits, 0, "ab", ctx, .{});
    try std.testing.expectEqualStrings("ab", readRow(&fits, 0, &buf));

    // Overflow: end_col = 8 (right margin 2), so 7 text cells + leading `…`.
    var overflow = try testSurface(arena.allocator(), 10, 1);
    try rightStyled(&overflow, 0, "abcdefghij", ctx, .{});
    try std.testing.expectEqualStrings("…defghij", readRow(&overflow, 0, &buf));

    // Overflow by many keeps just the tail: end_col = 8 (right margin 2), so
    // 7 text cells + the leading ellipsis.
    var overflow_many = try testSurface(arena.allocator(), 10, 1);
    try rightStyled(&overflow_many, 0, "abcdefghijklmnopqrstuvwxyz", ctx, .{});
    try std.testing.expectEqualStrings("…tuvwxyz", readRow(&overflow_many, 0, &buf));

    // Wide graphemes truncate at cell granularity: the longest suffix fitting 7
    // cells is "語です" (3 chars × 2 cells); "本語です" would need 8.
    var wide = try testSurface(arena.allocator(), 10, 1);
    try rightStyled(&wide, 0, "日本語です", ctx, .{});
    try std.testing.expectEqualStrings("…語です", readRow(&wide, 0, &buf));
}

test "writeBorderTextEndingAt truncates a description instead of dropping it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 20, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    var buf: [64]u8 = undefined;

    // Fits exactly: text ends at end_col, returns its first column.
    var fits = try testSurface(arena.allocator(), 20, 1);
    const start = writeBorderTextEndingAt(&fits, ctx, 0, 7, "abcdefgh", .{});
    try std.testing.expectEqual(@as(u16, 0), start);
    try std.testing.expectEqualStrings("abcdefgh", readRow(&fits, 0, &buf));

    // Overflow-by-one: end_col 4 leaves 4 text cells + ellipsis.
    var overflow = try testSurface(arena.allocator(), 20, 1);
    _ = writeBorderTextEndingAt(&overflow, ctx, 0, 4, "abcdef", .{});
    try std.testing.expectEqualStrings("…cdef", readRow(&overflow, 0, &buf));

    // Overflow-by-many keeps the tail.
    var many = try testSurface(arena.allocator(), 20, 1);
    _ = writeBorderTextEndingAt(&many, ctx, 0, 3, "abcdefghij", .{});
    try std.testing.expectEqualStrings("…hij", readRow(&many, 0, &buf));

    // Wide graphemes truncate at cell granularity.
    var wide = try testSurface(arena.allocator(), 20, 1);
    _ = writeBorderTextEndingAt(&wide, ctx, 0, 3, "日本語です", .{});
    try std.testing.expectEqualStrings("…す", readRow(&wide, 0, &buf));
}

test "writeBorderTextEndingAt empty or out-of-row text draws nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 20, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    var surface = try testSurface(arena.allocator(), 20, 1);
    const empty = writeBorderTextEndingAt(&surface, ctx, 0, 5, "", .{});
    try std.testing.expectEqual(@as(u16, 6), empty);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", readRow(&surface, 0, &buf));
}

/// The accent fg of the default palette, used to verify matched-rune styling.
fn cellFgRgb(surface: *const vxfw.Surface, row: u16, col: u16) ?tui_style.Rgb {
    const cell = surface.readCell(col, row);
    switch (cell.style.fg) {
        .rgb => |rgb| return rgb,
        else => return null,
    }
}

test "fuzzyMatchPositions finds ASCII subsequence byte offsets" {
    var pos: [16]usize = undefined;
    const n = fuzzyMatchPositions("abc", "xxabcxx", &pos);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(usize, 2), pos[0]);
    try std.testing.expectEqual(@as(usize, 3), pos[1]);
    try std.testing.expectEqual(@as(usize, 4), pos[2]);
}

test "fuzzyMatchPositions is case-insensitive on ASCII" {
    var pos: [16]usize = undefined;
    const n = fuzzyMatchPositions("ABC", "abc", &pos);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(usize, 0), pos[0]);
    try std.testing.expectEqual(@as(usize, 2), pos[2]);
}

test "fuzzyMatchPositions finds multi-byte UTF-8 runes" {
    var pos: [16]usize = undefined;
    const n = fuzzyMatchPositions("語", "日本語", &pos);
    try std.testing.expectEqual(@as(usize, 1), n);
    // 日 = 3 bytes, 本 = 3 bytes, so 語 starts at byte 6.
    try std.testing.expectEqual(@as(usize, 6), pos[0]);
}

test "fuzzyMatchPositions returns 0 when there is no match" {
    var pos: [16]usize = undefined;
    try std.testing.expectEqual(@as(usize, 0), fuzzyMatchPositions("xyz", "abc", &pos));
}

test "fuzzyMatchPositions is bounded by the positions buffer" {
    var pos: [2]usize = undefined;
    const n = fuzzyMatchPositions("abcd", "abcd", &pos);
    try std.testing.expectEqual(@as(usize, 2), n);
}

test "drawFuzzyListRow highlights matched runes in accent and honors start_col" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 20, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    var surface = try testSurface(arena.allocator(), 20, 1);
    try drawFuzzyListRow(&surface, 0, ctx, .{
        .prefix = "  ",
        .text = "tokyo_night",
        .query = "tok",
        .selected = false,
        .start_col = 1,
    });
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("  tokyo_night", readRow(&surface, 0, &buf));
    // start_col=1 + prefix width 2 → text starts at col 3; 't' is matched.
    const p = tui_style.buildPalette(tui_style.default_theme);
    try std.testing.expectEqual(p.selected_item.fg.rgb, cellFgRgb(&surface, 0, 3).?);
    // 'o' (col 4) is also matched by "tok" → accent.
    try std.testing.expectEqual(p.selected_item.fg.rgb, cellFgRgb(&surface, 0, 4).?);
    // The 'y' (col 6) is unmatched → base thinking_body fg.
    try std.testing.expectEqual(p.thinking_body.fg.rgb, cellFgRgb(&surface, 0, 6).?);
}

test "drawFuzzyListRow bold and underline match styles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 20, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    var bold_surface = try testSurface(arena.allocator(), 20, 1);
    try drawFuzzyListRow(&bold_surface, 0, ctx, .{
        .text = "abcd",
        .query = "a",
        .start_col = 0,
        .highlight_style = .bold,
    });
    const bold_cell = bold_surface.readCell(0, 0);
    try std.testing.expect(bold_cell.style.bold);

    var ul_surface = try testSurface(arena.allocator(), 20, 1);
    try drawFuzzyListRow(&ul_surface, 0, ctx, .{
        .text = "abcd",
        .query = "a",
        .start_col = 0,
        .highlight_style = .underline,
    });
    const ul_cell = ul_surface.readCell(0, 0);
    try std.testing.expectEqual(vaxis.Style.Underline.single, ul_cell.style.ul_style);
}

test "drawFuzzyListRow preserves rune alignment for multi-byte text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 20, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    var surface = try testSurface(arena.allocator(), 20, 1);
    try drawFuzzyListRow(&surface, 0, ctx, .{
        .text = "日本語",
        .query = "語",
        .start_col = 0,
    });
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("日本語", readRow(&surface, 0, &buf));
    // The matched rune 語 (3 bytes wide, 2 cells) is at col 4 and styled accent.
    const p = tui_style.buildPalette(tui_style.default_theme);
    try std.testing.expectEqual(p.selected_item.fg.rgb, cellFgRgb(&surface, 0, 4).?);
}
