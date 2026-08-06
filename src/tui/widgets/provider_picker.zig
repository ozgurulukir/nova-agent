const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const panel = @import("panel.zig");
const message = @import("message.zig");
const tui_style = @import("../style.zig");
const auth = @import("../../auth/store.zig");
const config_mod = @import("../../config/config.zig");
const modelsdev = @import("../../models/registry.zig");
const codex = @import("../../auth/codex.zig");

const StylePalette = tui_style.Palette;
const assert = std.debug.assert;

pub const Status = enum { unknown, connected, failed };

pub const Stage = enum { list, form };
pub const Column = enum { provider, sign_out };

pub const Action = union(enum) {
    connect_codex,
    sign_out_codex,
    open_entry: ProviderHandle,
};

/// Unified handle for any provider source: builtin catalogue, models.dev
/// registry, or user-defined config entry. All three expose the same
/// accessor surface so the picker renders and routes them uniformly.
pub const ProviderHandle = union(enum) {
    builtin: config_mod.Provider,
    dynamic: modelsdev.Provider,
    config: config_mod.ProviderConfig,

    /// Deduplication key: `label()` for builtins, `id` for models.dev,
    /// `name` for config entries.
    pub fn id(self: ProviderHandle) []const u8 {
        return switch (self) {
            .builtin => |b| b.label(),
            .dynamic => |d| d.id,
            .config => |c| c.name,
        };
    }

    pub fn displayName(self: ProviderHandle) []const u8 {
        return switch (self) {
            .builtin => |b| b.displayName(),
            .dynamic => |d| d.name,
            .config => |c| c.name,
        };
    }

    pub fn description(self: ProviderHandle) []const u8 {
        return switch (self) {
            .builtin => |b| b.description(),
            .dynamic => |d| d.description,
            .config => "Custom provider from config",
        };
    }

    pub fn defaultBaseUrl(self: ProviderHandle) ?[]const u8 {
        return switch (self) {
            .builtin => |b| b.defaultBaseUrl(),
            .dynamic => |d| if (d.base_url.len > 0) d.base_url else null,
            .config => |c| switch (c.base_url) {
                .custom => |url| url,
                .default => c.provider.defaultBaseUrl(),
            },
        };
    }

    pub fn requiresApiKey(self: ProviderHandle) bool {
        return switch (self) {
            .builtin => |b| b.requiresApiKey(),
            .dynamic => |d| d.requires_api_key,
            .config => true,
        };
    }

    /// Position within `catalogueProviders()` for badge lookup. Null for
    /// non-builtin entries (their badge comes from the API-key map).
    pub fn catalogueIndex(self: ProviderHandle) ?usize {
        const b = switch (self) {
            .builtin => |v| v,
            else => return null,
        };
        for (config_mod.catalogueProviders(), 0..) |candidate, index| {
            if (candidate == b) return index;
        }
        return null;
    }
};

pub const State = struct {
    stage: Stage = .list,
    selection: u32 = 0,
    column: Column = .provider,
    form_handle: ?ProviderHandle = null,
    form_error: ?[]const u8 = null,
    show_secret: bool = false,
    /// Merged provider list: builtins → models.dev → config (later overrides).
    entries: []const ProviderHandle = &.{},

    pub fn reset(self: *State) void {
        self.* = .{ .entries = self.entries };
    }

    pub fn rowCount(self: *const State) u32 {
        return 1 + @as(u32, @intCast(self.entries.len));
    }

    pub fn handleKey(self: *State, key: vaxis.Key, codex_signed_in: bool) bool {
        if (self.stage == .form) return false;

        const count = self.rowCount();
        if (count == 0) return false;
        assert(self.selection < count);
        if (key.matches(vaxis.Key.left, .{})) {
            self.column = .provider;
            return true;
        }
        if (key.matches(vaxis.Key.right, .{})) {
            if (self.selection == 0 and codex_signed_in) self.column = .sign_out;
            return true;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            if (self.selection == 0 and codex_signed_in) self.column = nextColumn(self.column);
            return true;
        }
        if (key.matches(vaxis.Key.up, .{})) {
            self.selection = previousIndex(self.selection, count);
            self.column = .provider;
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            self.selection = nextIndex(self.selection, count);
            self.column = .provider;
            return true;
        }
        if (key.matches(vaxis.Key.page_up, .{})) {
            self.selection = self.selection -| 10;
            self.column = .provider;
            return true;
        }
        if (key.matches(vaxis.Key.page_down, .{})) {
            self.selection = @min(count - 1, self.selection + 10);
            self.column = .provider;
            return true;
        }
        return false;
    }

    pub fn selectedAction(self: *const State) Action {
        const count = self.rowCount();
        assert(self.selection < count);
        if (self.selection == 0) {
            if (self.column == .sign_out) return .sign_out_codex;
            return .connect_codex;
        }
        return .{ .open_entry = self.entries[self.selection - 1] };
    }
};

pub const Content = struct {
    state: State,
    codex_signed_in: bool,
    statuses: []const Status,
    key_input: []const u8 = "",
    api_keys: ?*const auth.ApiKeyMap = null,

    pub fn widget(self: *Content) vxfw.Widget {
        return .{ .userdata = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Content = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse 0;
        const height = ctx.max.height orelse 0;
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, &.{});
        if (self.state.stage == .form) {
            try self.drawForm(&surface, ctx);
        } else {
            try self.drawList(&surface, ctx);
        }
        return surface;
    }

    fn drawList(self: *const Content, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        const total_count = 1 + @as(u32, @intCast(self.state.entries.len));
        const viewport = panel.ViewportWindow.compute(self.state.selection, total_count, surface.size.height);
        if (viewport.visible_height == 0) return;

        var i: u32 = viewport.start_index;
        while (i < viewport.end_index) : (i += 1) {
            const row = viewport.screenRow(i);
            if (i == 0) {
                try self.drawCodex(surface, ctx, row);
                continue;
            }
            const entry = self.state.entries[i - 1];
            const focused = self.state.selection == i and self.state.column == .provider;
            const base = try std.fmt.allocPrint(ctx.arena, "  {s}", .{entry.displayName()});
            try panel.commandLine(surface, row, base, ctx, focused);

            // Badge: builtins use the catalogue status array; everything else
            // derives connectivity from the API-key map.
            const status: Status = if (entry.catalogueIndex()) |ci|
                (if (ci < self.statuses.len) self.statuses[ci] else .unknown)
            else if (self.api_keys) |keys|
                (if (keys.get(entry.id()) != null) .connected else .unknown)
            else
                .unknown;
            try drawBadge(surface, ctx, row, base, status, focused);

            const desc_style = if (focused) StylePalette.selected_item else StylePalette.thinking_body;
            _ = panel.writeBorderTextEndingAt(surface, ctx, row, surface.size.width -| 2, entry.description(), desc_style);
        }
    }

    fn drawBadge(
        surface: *vxfw.Surface,
        ctx: vxfw.DrawContext,
        row: u16,
        base: []const u8,
        status: Status,
        focused: bool,
    ) !void {
        const text: []const u8 = switch (status) {
            .connected => " [CONNECTED]",
            .failed => " [DISCONNECTED]",
            .unknown => return,
        };
        const style: vaxis.Style = switch (status) {
            .connected => StylePalette.success,
            .failed => StylePalette.tool_failed,
            .unknown => unreachable,
        };
        const badge_col: u16 = (message.ConversationLayout.left -| 1) +
            @as(u16, @intCast(@min(ctx.stringWidth(base), @as(usize, std.math.maxInt(u16)))));
        try panel.lineStyledAt(surface, row, text, ctx, badge_col, tui_style.onSelectionBg(style, focused));
    }

    fn drawCodex(self: *const Content, surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16) !void {
        const row_selected = self.state.selection == 0;
        const provider_focused = row_selected and self.state.column == .provider;
        if (row_selected) panel.fillRow(surface, row, StylePalette.selected);

        const prefix = "  ";
        const base = try std.fmt.allocPrint(ctx.arena, "{s}OpenAI Codex", .{prefix});
        const base_style = if (provider_focused) StylePalette.selected_item else tui_style.onSelectionBg(StylePalette.thinking_body, row_selected);
        try panel.lineStyledAt(surface, row, base, ctx, message.ConversationLayout.left -| 1, base_style);
        if (self.codex_signed_in) {
            const badge_col: u16 = (message.ConversationLayout.left -| 1) +
                @as(u16, @intCast(@min(ctx.stringWidth(base), @as(usize, std.math.maxInt(u16)))));
            try panel.lineStyledAt(surface, row, " [CONNECTED]", ctx, badge_col, tui_style.onSelectionBg(StylePalette.success, row_selected));
            try self.drawSignOut(surface, ctx, row, row_selected);
        } else {
            const desc_style = if (provider_focused) StylePalette.selected_item else StylePalette.thinking_body;
            _ = panel.writeBorderTextEndingAt(surface, ctx, row, surface.size.width -| 2, "OpenAI ChatGPT & Codex OAuth authentication", desc_style);
        }
    }

    fn drawSignOut(self: *const Content, surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16, row_selected: bool) !void {
        const focused = row_selected and self.state.column == .sign_out;
        const prefix = "  ";
        const text = try std.fmt.allocPrint(ctx.arena, "{s}Sign Out", .{prefix});
        const style = if (focused) StylePalette.selected_item else tui_style.onSelectionBg(StylePalette.thinking_body, row_selected);
        try panel.lineStyledAt(surface, row, text, ctx, panel.secondaryColumn(surface.size.width), style);
    }

    fn drawForm(self: *const Content, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        const handle = self.state.form_handle orelse return;
        const display_name = handle.displayName();
        const desc = handle.description();
        const base_url = handle.defaultBaseUrl();
        const requires_key = handle.requiresApiKey();

        const start_col = message.ConversationLayout.left -| 1;
        try panel.lineStyledAt(surface, 1, display_name, ctx, start_col, StylePalette.model_status);

        try panel.lineStyledAt(surface, 2, desc, ctx, start_col, StylePalette.thinking_body);

        if (base_url) |url| {
            const url_text = try std.fmt.allocPrint(ctx.arena, "Endpoint: {s}", .{url});
            try panel.lineStyledAt(surface, 3, url_text, ctx, start_col, StylePalette.thinking_body);
        }

        const key_row: u16 = if (base_url != null) 5 else 4;
        const label = if (requires_key) "API Key: " else "API Key (optional): ";
        try panel.lineStyledAt(surface, key_row, label, ctx, start_col, StylePalette.panel_header);
        const key_col = start_col + @as(u16, @intCast(@min(ctx.stringWidth(label), @as(usize, std.math.maxInt(u16)))));
        // TUX02: never render the secret in plaintext — mask it for display.
        // The real value stays in the input buffer; submit reads the buffer.
        // A user toggle (Ctrl+H) skips masking so they can verify paste correctness.
        const shown = if (self.state.show_secret)
            try std.fmt.allocPrint(ctx.arena, "{s}\u{2588}", .{self.key_input})
        else
            try std.fmt.allocPrint(ctx.arena, "{s}\u{2588}", .{maskSecret(ctx.arena, self.key_input)});

        try panel.lineStyledAt(surface, key_row, shown, ctx, key_col, StylePalette.panel_header);

        const hint_row = key_row + 2;
        if (self.state.form_error) |err_msg| {
            try panel.lineStyledAt(surface, hint_row, err_msg, ctx, start_col, StylePalette.tool_failed);
        } else {
            const hint = if (requires_key and self.key_input.len == 0)
                "Type or paste your API key, then press Enter to connect (Esc to cancel)"
            else if (requires_key)
                "Press Enter to submit and connect (Ctrl+H to reveal, Esc to cancel)"
            else
                "Press Enter to submit and connect (Esc to cancel)";
            try panel.lineStyledAt(surface, hint_row, hint, ctx, start_col, StylePalette.thinking_body);
        }
    }
};

fn nextColumn(current: Column) Column {
    return switch (current) {
        .provider => .sign_out,
        .sign_out => .provider,
    };
}

/// Render a secret as one bullet per entered grapheme so an API key is never
/// shown in plaintext on screen (shoulder-surfing / screen-share safe). Only
/// the display is masked; length is preserved for typing feedback.
fn maskSecret(arena: std.mem.Allocator, secret: []const u8) []const u8 {
    if (secret.len == 0) return "";
    var out: std.ArrayList(u8) = .empty;
    var iter = vaxis.unicode.graphemeIterator(secret);
    while (iter.next()) |_| {
        out.appendSlice(arena, "•") catch return "";
    }
    return out.toOwnedSlice(arena) catch "";
}

fn nextIndex(current: u32, count: u32) u32 {
    assert(count > 0);
    assert(current < count);
    return if (current + 1 >= count) 0 else current + 1;
}

fn previousIndex(current: u32, count: u32) u32 {
    assert(count > 0);
    assert(current < count);
    return if (current == 0) count - 1 else current - 1;
}

test "provider form masks the API key in the display" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqualStrings("", maskSecret(gpa, ""));
    const masked = maskSecret(gpa, "sk-123");
    defer gpa.free(masked);
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, masked, "•"));
    try std.testing.expect(std.mem.indexOf(u8, masked, "sk") == null);
}

test "provider picker navigation reaches sign out only when signed in" {
    var state: State = .{};
    try std.testing.expect(state.handleKey(.{ .codepoint = vaxis.Key.right }, false));
    try std.testing.expectEqual(Column.provider, state.column);
    try std.testing.expect(state.handleKey(.{ .codepoint = vaxis.Key.right }, true));
    try std.testing.expectEqual(Column.sign_out, state.column);
}

test "provider picker keeps codex text visible when sign out is focused" {
    var content: Content = .{
        .state = .{ .selection = 0, .column = .sign_out },
        .codex_signed_in = true,
        .statuses = &.{},
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 4 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try content.widget().draw(ctx);

    try std.testing.expectEqualStrings("O", surface.readCell(message.ConversationLayout.left + 1, 0).char.grapheme);
    try std.testing.expectEqualStrings("S", surface.readCell(panel.secondaryColumn(surface.size.width) + 2, 0).char.grapheme);
    try std.testing.expectEqual(StylePalette.selected.bg, surface.readCell(panel.secondaryColumn(surface.size.width) + 2, 0).style.bg);
}

test "provider picker keeps sign out on the selected row background" {
    var content: Content = .{
        .state = .{ .selection = 0, .column = .provider },
        .codex_signed_in = true,
        .statuses = &.{},
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 4 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try content.widget().draw(ctx);

    try std.testing.expectEqualStrings("S", surface.readCell(panel.secondaryColumn(surface.size.width) + 2, 0).char.grapheme);
    try std.testing.expectEqual(StylePalette.selected.bg, surface.readCell(panel.secondaryColumn(surface.size.width) + 2, 0).style.bg);
}

test "provider picker selecting a catalogue row opens its form" {
    const count = comptime config_mod.catalogueProviders().len;
    var entries: [count]ProviderHandle = undefined;
    for (config_mod.catalogueProviders(), 0..) |b, idx| entries[idx] = .{ .builtin = b };

    var state: State = .{ .entries = &entries };
    try std.testing.expectEqual(Action.connect_codex, state.selectedAction());
    try std.testing.expect(state.handleKey(.{ .codepoint = vaxis.Key.down }, false));
    const action = state.selectedAction();
    try std.testing.expect(action == .open_entry);
    try std.testing.expectEqual(config_mod.catalogueProviders()[0], action.open_entry.builtin);
}

fn rowText(arena: std.mem.Allocator, surface: vxfw.Surface, row: u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var col: u16 = 0;
    while (col < surface.size.width) : (col += 1) {
        try out.appendSlice(arena, surface.readCell(col, row).char.grapheme);
    }
    return out.toOwnedSlice(arena);
}

test "provider picker badge reflects connectivity status, not key presence" {
    const count = comptime config_mod.catalogueProviders().len;
    var statuses: [count]Status = @splat(.unknown);
    statuses[0] = .connected;
    statuses[1] = .failed;

    var entries: [count]ProviderHandle = undefined;
    for (config_mod.catalogueProviders(), 0..) |b, idx| entries[idx] = .{ .builtin = b };

    var content: Content = .{
        .state = .{ .entries = &entries },
        .codex_signed_in = false,
        .statuses = &statuses,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = @intCast(content.state.rowCount() + 1) },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try content.widget().draw(ctx);

    // Rows are 1-based: row 1 is the first catalogue provider.
    const connected_row = try rowText(arena.allocator(), surface, 1);
    try std.testing.expect(std.mem.indexOf(u8, connected_row, "[CONNECTED]") != null);

    const failed_row = try rowText(arena.allocator(), surface, 2);
    try std.testing.expect(std.mem.indexOf(u8, failed_row, "[DISCONNECTED]") != null);

    // An unconfigured provider (no credentials) shows no badge at all.
    const unknown_row = try rowText(arena.allocator(), surface, 3);
    try std.testing.expect(std.mem.indexOf(u8, unknown_row, "[") == null);
}

test "provider picker viewport scrolling renders selected dynamic row" {
    const count = comptime config_mod.catalogueProviders().len;
    const dyn = [_]ProviderHandle{
        .{ .dynamic = .{ .id = "p1", .name = "Provider 1", .description = "Desc 1", .base_url = "https://p1.ai", .adapter = .openai_compatible, .requires_api_key = true } },
        .{ .dynamic = .{ .id = "p2", .name = "Provider 2", .description = "Desc 2", .base_url = "https://p2.ai", .adapter = .openai_compatible, .requires_api_key = true } },
    };
    // builtins + 2 dynamics; selection=8 should land on "Provider 2"
    var entries: [count + 2]ProviderHandle = undefined;
    for (config_mod.catalogueProviders(), 0..) |b, idx| entries[idx] = .{ .builtin = b };
    entries[count] = dyn[0];
    entries[count + 1] = dyn[1];

    var content: Content = .{
        .state = .{ .selection = 8, .entries = &entries },
        .codex_signed_in = false,
        .statuses = &.{},
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 4 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try content.widget().draw(ctx);

    const bottom_line = try rowText(arena.allocator(), surface, 3);
    try std.testing.expect(std.mem.indexOf(u8, bottom_line, "Provider 2") != null);
}

test "provider picker form stage defers keys to the input field" {
    var state: State = .{ .stage = .form };
    try std.testing.expect(!state.handleKey(.{ .codepoint = 'a' }, false));
    try std.testing.expect(!state.handleKey(.{ .codepoint = vaxis.Key.down }, true));
}
