//! Plugins Status Overlay Widget.
//! Displays loaded Lua plugins, their state, and permissions.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const panel = @import("panel.zig");
const tui_style = @import("../style.zig");

pub const State = struct {
    selection: usize = 0,

    pub fn reset(self: *State) void {
        self.selection = 0;
    }

    pub fn moveUp(self: *State) void {
        if (self.selection > 0) self.selection -= 1;
    }

    pub fn moveDown(self: *State, count: usize) void {
        if (count > 0 and self.selection + 1 < count) {
            self.selection += 1;
        }
    }
};

pub const Content = struct {
    state: *State,
    /// Plugin names and their active state, borrowed from the plugin manager.
    plugins: []const PluginEntry = &.{},

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const p = tui_style.activePalette();
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(
            ctx.arena,
            self.widget(),
            .{ .width = width, .height = height },
            &.{},
        );

        try panel.lineStyledAt(&surface, 0, "LUA PLUGINS", ctx, 2, p.panel_header);
        const summary = try std.fmt.allocPrint(ctx.arena, "Loaded: {d}", .{self.plugins.len});
        try panel.lineStyledAt(&surface, 2, summary, ctx, 2, p.info);

        if (self.plugins.len == 0) {
            try panel.lineStyledAt(&surface, 4, "No plugins loaded. Add plugins to ~/.config/nova/plugins/ or .nova/plugins/.", ctx, 2, p.thinking_body);
            try panel.lineStyledAt(&surface, height - 2, "[Esc] Close", ctx, 2, p.thinking_body);
            return surface;
        }

        var row: u16 = 4;
        for (self.plugins, 0..) |plugin, i| {
            if (row >= height - 2) break;
            const is_selected = i == self.state.selection;
            if (is_selected) panel.fillRow(&surface, row, p.selected);
            const style = if (is_selected) p.selected_item else p.thinking_body;
            const status_icon = if (plugin.active) "●" else "○";
            try panel.lineStyledAt(&surface, row, status_icon, ctx, 4, style);
            try panel.lineStyledAt(&surface, row, plugin.name, ctx, 6, style);
            row += 1;
        }

        try panel.lineStyledAt(&surface, height - 2, "[Esc] Close", ctx, 2, p.thinking_body);
        return surface;
    }
};

pub const PluginEntry = struct {
    name: []const u8,
    active: bool,
};


// ---------------------------------------------------------------------------
// Tests

fn readRowGraphemes(surface: *const vxfw.Surface, row: u16, out: []u8) []const u8 {
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

test "plugins_status renders active and inactive plugins without loop allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var state: State = .{ .selection = 0 };
    const plugins = [_]PluginEntry{
        .{ .name = "git_helper", .active = true },
        .{ .name = "linter", .active = false },
    };
    var content: Content = .{
        .state = &state,
        .plugins = &plugins,
    };

    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 40, .height = 10 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    var surface = try content.widget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 40), surface.size.width);
    try std.testing.expectEqual(@as(u16, 10), surface.size.height);

    var buf: [128]u8 = undefined;
    // Header at row 0
    try std.testing.expectEqualStrings("LUA PLUGINS", readRowGraphemes(&surface, 0, &buf));
    // Summary at row 2
    try std.testing.expectEqualStrings("Loaded: 2", readRowGraphemes(&surface, 2, &buf));
    // First plugin entry at row 4: "●" at col 4, "git_helper" at col 6
    try std.testing.expectEqualStrings("●", surface.readCell(4, 4).char.grapheme);
    try std.testing.expectEqualStrings("g", surface.readCell(6, 4).char.grapheme);
    // Second plugin entry at row 5: "○" at col 4, "linter" at col 6
    try std.testing.expectEqualStrings("○", surface.readCell(4, 5).char.grapheme);
    try std.testing.expectEqualStrings("l", surface.readCell(6, 5).char.grapheme);
}
