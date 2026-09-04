const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const panel = @import("panel.zig");
const message = @import("message.zig");
const tui_style = @import("../style.zig");
const auth = @import("../../auth/store.zig");
const config_mod = @import("../../config/config.zig");
const modelsdev = @import("../../models/registry.zig");
const command_panel = @import("command_panel.zig");

const assert = std.debug.assert;
pub const Status = enum { unknown, connected, failed };
pub const Stage = enum { list, form };
pub const Column = enum { provider, sign_out };

pub const Action = union(enum) {
    connect_codex,
    sign_out_codex,
    open_entry: ProviderHandle,
};

/// Match result for a filtered provider row.
pub const Match = union(enum) {
    codex,
    entry: ProviderHandle,
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
    /// non-catalogue entries (their badge comes from the API-key map).
    pub fn catalogueIndex(self: ProviderHandle) ?usize {
        const b = switch (self) {
            .builtin => |v| v,
            .dynamic => |d| if (d.catalogue) d.provider else return null,
            else => return null,
        };
        for (config_mod.catalogueProviders(), 0..) |candidate, index| {
            if (candidate == b) return index;
        }
        return null;
    }
};

/// Check if a row matches the given search filter. Null `handle_opt` checks the Codex row.
pub fn matchesRow(handle_opt: ?ProviderHandle, filter: []const u8) bool {
    if (filter.len == 0) return true;
    if (handle_opt) |handle| {
        return command_panel.containsIgnoreCase(handle.displayName(), filter) or
            command_panel.containsIgnoreCase(handle.id(), filter) or
            command_panel.containsIgnoreCase(handle.description(), filter);
    } else {
        return command_panel.containsIgnoreCase("OpenAI Codex", filter) or
            command_panel.containsIgnoreCase("codex", filter) or
            command_panel.containsIgnoreCase("chatgpt", filter) or
            command_panel.containsIgnoreCase("OpenAI ChatGPT & Codex OAuth authentication", filter);
    }
}

/// Count the number of visible matching rows for the given filter.
pub fn countMatching(entries: []const ProviderHandle, filter: []const u8) u32 {
    if (filter.len == 0) return 1 + @as(u32, @intCast(entries.len));
    var count: u32 = 0;
    if (matchesRow(null, filter)) count += 1;
    for (entries) |entry| {
        if (matchesRow(entry, filter)) count += 1;
    }
    return count;
}

/// Look up the matching item at index `index` in the filtered list.
pub fn getMatchAt(entries: []const ProviderHandle, filter: []const u8, index: u32) ?Match {
    if (filter.len == 0) {
        if (index == 0) return .codex;
        const entry_idx = index - 1;
        if (entry_idx < entries.len) return .{ .entry = entries[entry_idx] };
        return null;
    }
    var current: u32 = 0;
    if (matchesRow(null, filter)) {
        if (current == index) return .codex;
        current += 1;
    }
    for (entries) |entry| {
        if (matchesRow(entry, filter)) {
            if (current == index) return .{ .entry = entry };
            current += 1;
        }
    }
    return null;
}

pub const State = struct {
    stage: Stage = .list,
    selection: u32 = 0,
    column: Column = .provider,
    form_handle: ?ProviderHandle = null,
    form_error: ?[]const u8 = null,
    /// True once the user has typed/pasted into the key field. While false
    /// (a pre-filled existing key), the value stays masked; once true, the
    /// live input renders in plaintext so paste correctness is verifiable.
    key_dirty: bool = false,
    /// Merged provider list: builtins → models.dev → config (later overrides).
    entries: []const ProviderHandle = &.{},

    pub fn reset(self: *State) void {
        self.* = .{ .entries = self.entries };
    }

    pub fn rowCount(self: *const State) u32 {
        return 1 + @as(u32, @intCast(self.entries.len));
    }

    pub fn handleKey(self: *State, key: vaxis.Key, codex_signed_in: bool, filter: []const u8) bool {
        if (self.stage == .form) return false;

        const count = countMatching(self.entries, filter);
        if (count == 0) return false;
        // The background registry refresh or a new filter can shrink `entries`;
        // a stale selection must clamp, not assert.
        if (self.selection >= count) self.selection = 0;

        const current_match = getMatchAt(self.entries, filter, self.selection);
        const is_codex = if (current_match) |m| (m == .codex) else false;

        if (key.matches(vaxis.Key.left, .{})) {
            self.column = .provider;
            return true;
        }
        if (key.matches(vaxis.Key.right, .{})) {
            if (is_codex and codex_signed_in) self.column = .sign_out;
            return true;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            if (is_codex and codex_signed_in) self.column = nextColumn(self.column);
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

    /// Drop the selection back into range after `entries` was rebuilt. A
    /// background registry refresh can shrink the list while the picker is
    /// open; call this from every rebuild site.
    pub fn clampSelection(self: *State) void {
        if (self.selection >= self.rowCount()) self.selection = 0;
    }

    pub fn selectedAction(self: *const State, filter: []const u8) ?Action {
        const match = getMatchAt(self.entries, filter, self.selection) orelse return null;
        return switch (match) {
            .codex => if (self.column == .sign_out) .sign_out_codex else .connect_codex,
            .entry => |entry| .{ .open_entry = entry },
        };
    }
};

pub const Content = struct {
    state: State,
    codex_signed_in: bool,
    statuses: []const Status,
    key_input: []const u8 = "",
    api_keys: ?*const auth.ApiKeyMap = null,
    filter: []const u8 = "",
    highlight_enabled: bool = true,
    highlight_style: config_mod.FuzzyHighlightStyle = .accent,

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
        const p = tui_style.activePalette();
        const total_matches = countMatching(self.state.entries, self.filter);
        if (total_matches == 0) {
            try panel.lineStyledAt(surface, 0, "  No matching providers", ctx, 1, p.thinking_body);
            return;
        }

        const viewport = panel.ViewportWindow.compute(self.state.selection, total_matches, surface.size.height);
        if (viewport.visible_height == 0) return;

        var match_idx: u32 = viewport.start_index;
        while (match_idx < viewport.end_index) : (match_idx += 1) {
            const screen_row = viewport.screenRow(match_idx);
            const match = getMatchAt(self.state.entries, self.filter, match_idx) orelse continue;
            const row_selected = self.state.selection == match_idx;
            const provider_focused = row_selected and self.state.column == .provider;

            switch (match) {
                .codex => {
                    try self.drawCodex(surface, ctx, screen_row, row_selected, provider_focused);
                },
                .entry => |entry| {
                    try self.drawEntry(surface, ctx, screen_row, entry, row_selected, provider_focused);
                },
            }
        }
    }

    fn drawEntry(
        self: *const Content,
        surface: *vxfw.Surface,
        ctx: vxfw.DrawContext,
        row: u16,
        entry: ProviderHandle,
        row_selected: bool,
        provider_focused: bool,
    ) !void {
        const p = tui_style.activePalette();
        const prefix = "  ";
        const base_style = if (provider_focused) p.selected_item else tui_style.onSelectionBg(p.thinking_body, row_selected);

        try panel.drawFuzzyListRow(surface, row, ctx, .{
            .prefix = prefix,
            .text = entry.displayName(),
            .query = self.filter,
            .selected = row_selected,
            .base_style = base_style,
            .start_col = message.ConversationLayout.left -| 1,
            .highlight_enabled = self.highlight_enabled,
            .highlight_style = self.highlight_style,
        });

        // Badge: builtins use the catalogue status array; everything else
        // derives connectivity from the API-key map.
        const status: Status = if (entry.catalogueIndex()) |ci|
            (if (ci < self.statuses.len) self.statuses[ci] else .unknown)
        else if (self.api_keys) |keys|
            (if (keys.get(entry.id()) != null) .connected else .unknown)
        else
            .unknown;
        try self.drawBadge(surface, ctx, row, prefix, entry.displayName(), status, row_selected);

        const desc_style = if (provider_focused) p.selected_item else p.thinking_body;
        _ = panel.writeBorderTextEndingAt(surface, ctx, row, surface.size.width -| 2, entry.description(), desc_style);
    }

    fn drawBadge(
        self: *const Content,
        surface: *vxfw.Surface,
        ctx: vxfw.DrawContext,
        row: u16,
        prefix: []const u8,
        display_name: []const u8,
        status: Status,
        row_selected: bool,
    ) !void {
        _ = self;
        const p = tui_style.activePalette();
        const text: []const u8 = switch (status) {
            .connected => " [CONNECTED]",
            .failed => " [DISCONNECTED]",
            .unknown => return,
        };
        const style: vaxis.Style = switch (status) {
            .connected => p.success,
            .failed => p.tool_failed,
            .unknown => unreachable,
        };
        const text_width = ctx.stringWidth(prefix) + ctx.stringWidth(display_name);
        const badge_col: u16 = (message.ConversationLayout.left -| 1) +
            @as(u16, @intCast(@min(text_width, @as(usize, std.math.maxInt(u16)))));
        try panel.lineStyledAt(surface, row, text, ctx, badge_col, tui_style.onSelectionBg(style, row_selected));
    }

    fn drawCodex(
        self: *const Content,
        surface: *vxfw.Surface,
        ctx: vxfw.DrawContext,
        row: u16,
        row_selected: bool,
        provider_focused: bool,
    ) !void {
        const p = tui_style.activePalette();
        const prefix = "  ";
        const base_style = if (provider_focused) p.selected_item else tui_style.onSelectionBg(p.thinking_body, row_selected);

        try panel.drawFuzzyListRow(surface, row, ctx, .{
            .prefix = prefix,
            .text = "OpenAI Codex",
            .query = self.filter,
            .selected = row_selected,
            .base_style = base_style,
            .start_col = message.ConversationLayout.left -| 1,
            .highlight_enabled = self.highlight_enabled,
            .highlight_style = self.highlight_style,
        });

        if (self.codex_signed_in) {
            const badge_col: u16 = (message.ConversationLayout.left -| 1) +
                @as(u16, @intCast(@min(ctx.stringWidth("  OpenAI Codex"), @as(usize, std.math.maxInt(u16)))));
            try panel.lineStyledAt(surface, row, " [CONNECTED]", ctx, badge_col, tui_style.onSelectionBg(p.success, row_selected));
            try self.drawSignOut(surface, ctx, row, row_selected);
        } else {
            const desc_style = if (provider_focused) p.selected_item else p.thinking_body;
            _ = panel.writeBorderTextEndingAt(surface, ctx, row, surface.size.width -| 2, "OpenAI ChatGPT & Codex OAuth authentication", desc_style);
        }
    }

    fn drawSignOut(self: *const Content, surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16, row_selected: bool) !void {
        const p = tui_style.activePalette();
        const focused = row_selected and self.state.column == .sign_out;
        const prefix = "  ";
        const text = try std.fmt.allocPrint(ctx.arena, "{s}Sign Out", .{prefix});
        const style = if (focused) p.selected_item else tui_style.onSelectionBg(p.thinking_body, row_selected);
        try panel.lineStyledAt(surface, row, text, ctx, panel.secondaryColumn(surface.size.width), style);
    }

    fn drawForm(self: *const Content, surface: *vxfw.Surface, ctx: vxfw.DrawContext) !void {
        const p = tui_style.activePalette();
        const handle = self.state.form_handle orelse return;
        const display_name = handle.displayName();
        const desc = handle.description();
        const base_url = handle.defaultBaseUrl();
        const requires_key = handle.requiresApiKey();

        const start_col = message.ConversationLayout.left -| 1;
        try panel.lineStyledAt(surface, 1, display_name, ctx, start_col, p.model_status);

        try panel.lineStyledAt(surface, 2, desc, ctx, start_col, p.thinking_body);

        if (base_url) |url| {
            const url_text = try std.fmt.allocPrint(ctx.arena, "Endpoint: {s}", .{url});
            try panel.lineStyledAt(surface, 3, url_text, ctx, start_col, p.thinking_body);
        }

        const key_row: u16 = if (base_url != null) 5 else 4;
        const label = if (requires_key) "API Key: " else "API Key (optional): ";
        try panel.lineStyledAt(surface, key_row, label, ctx, start_col, p.panel_header);
        const key_col = start_col + @as(u16, @intCast(@min(ctx.stringWidth(label), @as(usize, std.math.maxInt(u16)))));
        // Show the live input in plaintext once the user is editing it, so a
        // pasted key is verifiable. A pre-filled existing key (form opened to
        // edit) stays masked until the first keystroke.
        const shown = if (self.state.key_dirty)
            try std.fmt.allocPrint(ctx.arena, "{s}\u{2588}", .{self.key_input})
        else
            try std.fmt.allocPrint(ctx.arena, "{s}\u{2588}", .{maskSecret(ctx.arena, self.key_input)});
        try panel.lineStyledAt(surface, key_row, shown, ctx, key_col, p.panel_header);

        const hint_row = key_row + 2;
        if (self.state.form_error) |err_msg| {
            try panel.lineStyledAt(surface, hint_row, err_msg, ctx, start_col, p.tool_failed);
        } else {
            const hint = if (requires_key and self.key_input.len == 0)
                "Type or paste your API key, then press Enter to connect (Esc to cancel)"
            else
                "Press Enter to submit and connect (Esc to cancel)";
            try panel.lineStyledAt(surface, hint_row, hint, ctx, start_col, p.thinking_body);
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
    try std.testing.expect(state.handleKey(.{ .codepoint = vaxis.Key.right }, false, ""));
    try std.testing.expectEqual(Column.provider, state.column);
    try std.testing.expect(state.handleKey(.{ .codepoint = vaxis.Key.right }, true, ""));
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
    try std.testing.expectEqual(tui_style.activePalette().selected.bg, surface.readCell(panel.secondaryColumn(surface.size.width) + 2, 0).style.bg);
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
    try std.testing.expectEqual(tui_style.activePalette().selected.bg, surface.readCell(panel.secondaryColumn(surface.size.width) + 2, 0).style.bg);
}

test "provider picker selecting a catalogue row opens its form" {
    const count = comptime config_mod.catalogueProviders().len;
    var entries: [count]ProviderHandle = undefined;
    for (config_mod.catalogueProviders(), 0..) |b, idx| entries[idx] = .{ .builtin = b };

    var state: State = .{ .entries = &entries };
    try std.testing.expectEqual(Action.connect_codex, state.selectedAction("").?);
    try std.testing.expect(state.handleKey(.{ .codepoint = vaxis.Key.down }, false, ""));
    const action = state.selectedAction("").?;
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
    // builtins + 2 dynamics; selection = count + 2 lands on "Provider 2"
    var entries: [count + 2]ProviderHandle = undefined;
    for (config_mod.catalogueProviders(), 0..) |b, idx| entries[idx] = .{ .builtin = b };
    entries[count] = dyn[0];
    entries[count + 1] = dyn[1];

    var content: Content = .{
        .state = .{ .selection = count + 2, .entries = &entries },
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
    try std.testing.expect(!state.handleKey(.{ .codepoint = 'a' }, false, ""));
    try std.testing.expect(!state.handleKey(.{ .codepoint = vaxis.Key.down }, true, ""));
}

test "selectedAction is total for a stale selection and empty filter" {
    // Entries shrank between key handling and submit (background registry refresh)
    var state: State = .{ .selection = 7 };
    try std.testing.expectEqual(@as(?Action, null), state.selectedAction("nonexistent"));
    // Stale selection on empty filter returns null safely
    try std.testing.expectEqual(@as(?Action, null), state.selectedAction(""));

    // In-range selections keep resolving to the entry.
    const entries = [_]ProviderHandle{.{ .builtin = .openai }};
    var in_range: State = .{ .selection = 1, .entries = &entries };
    try std.testing.expect(std.meta.activeTag(in_range.selectedAction("").?) == .open_entry);
}

test "handleKey clamps a stale selection instead of asserting" {
    var state: State = .{ .selection = 5 };
    // Any navigation key first clamps the stale selection into range.
    try std.testing.expect(state.handleKey(.{ .codepoint = vaxis.Key.up }, false, ""));
    try std.testing.expectEqual(@as(u32, 0), state.selection);
    // clampSelection is the rebuild-site counterpart.
    state.selection = 9;
    state.clampSelection();
    try std.testing.expectEqual(@as(u32, 0), state.selection);
}

test "provider picker matchesRow searches displayName, id, and description" {
    const handle: ProviderHandle = .{ .builtin = .anthropic };
    try std.testing.expect(matchesRow(handle, "anthropic"));
    try std.testing.expect(matchesRow(handle, "Claude"));
    try std.testing.expect(matchesRow(handle, "ANTHROPIC"));
    try std.testing.expect(!matchesRow(handle, "nonexistent_term"));

    // Codex row checks
    try std.testing.expect(matchesRow(null, "codex"));
    try std.testing.expect(matchesRow(null, "chatgpt"));
    try std.testing.expect(matchesRow(null, "OAuth"));
    try std.testing.expect(!matchesRow(null, "anthropic"));
}

test "provider picker countMatching and getMatchAt filter correctly" {
    const entries = [_]ProviderHandle{
        .{ .builtin = .openai },
        .{ .builtin = .anthropic },
        .{ .builtin = .ollama },
    };

    // Empty filter matches Codex + 3 entries = 4
    try std.testing.expectEqual(@as(u32, 4), countMatching(&entries, ""));
    try std.testing.expectEqual(Match.codex, getMatchAt(&entries, "", 0).?);
    try std.testing.expectEqual(config_mod.Provider.openai, getMatchAt(&entries, "", 1).?.entry.builtin);

    // "Claude" matches only Anthropic
    try std.testing.expectEqual(@as(u32, 1), countMatching(&entries, "Claude"));
    const match = getMatchAt(&entries, "Claude", 0).?;
    try std.testing.expectEqual(config_mod.Provider.anthropic, match.entry.builtin);

    // "OAuth" matches only Codex row
    try std.testing.expectEqual(@as(u32, 1), countMatching(&entries, "OAuth"));
    try std.testing.expectEqual(Match.codex, getMatchAt(&entries, "OAuth", 0).?);

    // "codex" matches Codex row + OpenAI entry (whose description mentions Codex) = 2
    try std.testing.expectEqual(@as(u32, 2), countMatching(&entries, "codex"));
    try std.testing.expectEqual(Match.codex, getMatchAt(&entries, "codex", 0).?);
    try std.testing.expectEqual(config_mod.Provider.openai, getMatchAt(&entries, "codex", 1).?.entry.builtin);

    // Non-matching query
    try std.testing.expectEqual(@as(u32, 0), countMatching(&entries, "xyz_not_found"));
    try std.testing.expectEqual(@as(?Match, null), getMatchAt(&entries, "xyz_not_found", 0));
}

test "provider picker filtered navigation and empty list rendering" {
    const entries = [_]ProviderHandle{
        .{ .builtin = .openai },
        .{ .builtin = .anthropic },
    };
    var content: Content = .{
        .state = .{ .entries = &entries },
        .codex_signed_in = false,
        .statuses = &.{},
        .filter = "nonexistent",
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
    const line = try rowText(arena.allocator(), surface, 0);
    try std.testing.expect(std.mem.indexOf(u8, line, "No matching providers") != null);
}
