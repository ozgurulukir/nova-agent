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
        var line_buf: [256]u8 = undefined;
        for (self.plugins, 0..) |plugin, i| {
            if (row >= height - 2) break;
            const is_selected = i == self.state.selection;
            const style = if (is_selected) p.selected_item else p.thinking_body;
            const status_icon = if (plugin.active) "●" else "○";
            const line = std.fmt.bufPrint(&line_buf, "  {s} {s}", .{ status_icon, plugin.name }) catch continue;
            try panel.lineStyledAt(&surface, row, line, ctx, 2, style);
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


test "plugins_status Content.draw renders plugins list correctly" {
    const CountingAllocator = @import("counting_allocator").CountingAllocator;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var state: State = .{ .selection = 1 };
    const plugins = [_]PluginEntry{
        .{ .name = "hello-world", .active = true },
        .{ .name = "git-tools", .active = false },
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

    var counting: CountingAllocator = .{ .child = arena.allocator() };
    const counting_ctx: vxfw.DrawContext = .{
        .arena = counting.allocator(),
        .min = ctx.min,
        .max = ctx.max,
        .cell_size = ctx.cell_size,
    };

    const surface = try content.widget().draw(counting_ctx);
    try std.testing.expectEqual(@as(u16, 40), surface.size.width);
    try std.testing.expectEqual(@as(u16, 10), surface.size.height);

    // Read row 4 ("  ● hello-world")
    var buf4: [64]u8 = undefined;
    const line4 = panel.readRow(&surface, 4, &buf4);
    try std.testing.expectEqualStrings("  ● hello-world", line4);

    // Read row 5 ("  ○ git-tools")
    var buf5: [64]u8 = undefined;
    const line5 = panel.readRow(&surface, 5, &buf5);
    try std.testing.expectEqualStrings("  ○ git-tools", line5);
}


test "plugins_status Content.draw allocation count benchmark" {
    const CountingAllocator = @import("counting_allocator").CountingAllocator;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var state: State = .{ .selection = 0 };
    // Create 10 plugins
    var plugins_buf: [10]PluginEntry = undefined;
    for (&plugins_buf, 0..) |*p_entry, i| {
        p_entry.* = .{
            .name = "plugin-name-test",
            .active = (i % 2 == 0),
        };
    }

    var content: Content = .{
        .state = &state,
        .plugins = &plugins_buf,
    };

    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 16 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    var counting: CountingAllocator = .{ .child = arena.allocator() };
    const counting_ctx: vxfw.DrawContext = .{
        .arena = counting.allocator(),
        .min = ctx.min,
        .max = ctx.max,
        .cell_size = ctx.cell_size,
    };

    _ = try content.widget().draw(counting_ctx);

    std.debug.print("\n[BENCHMARK] Total Allocations in plugins_status Content.draw (10 plugins): allocs={d}, bytes={d}\n", .{ counting.count, counting.bytes });
}
