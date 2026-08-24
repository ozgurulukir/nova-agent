//! Mode overlay popup: the centered bordered box shown in command, session,
//! provider, model, tree, save-message, and lanes modes.
//!
//! Pulled out of `tui.zig` (R7.1 of `_pm/Projects/tui-split`) — the overlay
//! widget delegates the inner content to the per-mode picker widgets via
//! `OverlayInner.drawInner`, which is a mode switch over `App.mode` that
//! instantiates the right picker. The border label is set by `overlayLabel`,
//! and the popup size by `overlaySize`.
//!
//! Instantiated by `drawRoot` in `tui/root_layout.zig` and published as
//! `pub const OverlayWidget` via `tui.zig` re-export.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const ai = @import("../../ai.zig");
const tui = @import("../../tui.zig");
const tui_style = @import("../style.zig");
const panel = @import("panel.zig");
const command_panel = @import("command_panel.zig");
const help_picker = @import("help_picker.zig");
const lanes_picker = @import("lanes_picker.zig");
const search_widget = @import("search.zig");
const model_picker = @import("model_picker.zig");
const provider_picker = @import("provider_picker.zig");
const resume_picker = @import("resume_picker.zig");
const tree_selector = @import("tree_selector.zig");
const tui_status = @import("../status.zig");
const codex = @import("../../auth/codex.zig");
const settings_widget = @import("settings.zig");
const theme_picker = @import("theme_picker.zig");

const App = tui.App;

const OverlaySize = struct { width: u16, height: u16 };

fn overlaySize(mode: App.Mode) OverlaySize {
    return switch (mode) {
        .normal => .{ .width = 0, .height = 0 },
        .command => .{ .width = 64, .height = 16 },
        .provider_picker => .{ .width = 72, .height = 16 },
        .session_picker => .{ .width = 80, .height = 16 },
        .model_picker => .{ .width = 90, .height = 16 },
        .tree_picker => .{ .width = 90, .height = 20 },
        .save_message => .{ .width = 60, .height = 3 },
        .lanes => .{ .width = 80, .height = 16 },
        .help => .{ .width = 90, .height = help_picker.help_overlay_height },
        .settings => .{ .width = 90, .height = 22 },
        .mcp => .{ .width = 90, .height = 20 },
        .plugins => .{ .width = 80, .height = 16 },
        .search => .{ .width = 90, .height = 20 },
        .theme_picker => .{ .width = 64, .height = 16 },
        .diff_viewer => .{ .width = 0, .height = 0 },
    };
}

fn overlayLabel(app: *const App) []const u8 {
    return switch (app.mode) {
        .normal => "",
        .command => "Command",
        .session_picker => switch (app.nav.session_action) {
            .browsing => "Search for Sessions",
            .renaming => "Rename Session",
            .deleting => "Delete Session",
            .blocked => "Cannot Delete Active Session",
        },
        .provider_picker => "Connect to Provider",
        .model_picker => "Select Model",
        .tree_picker => "Session Timeline",
        .save_message => "Commit Message",
        .help => "Help & Keyboard Shortcuts",
        .settings => "Settings",
        .mcp => "Model Context Protocol (MCP)",
        .plugins => "Lua Plugins",
        .search => "Search Transcript",
        .theme_picker => "Select Theme",
        .lanes => switch (app.nav.lanes_purpose) {
            .manage => "Parallel Lanes",
            .merge_dest => "Merge Into",
        },
        .diff_viewer => "",
    };
}

fn writeBorderLabel(surface: *vxfw.Surface, ctx: vxfw.DrawContext, text: []const u8) void {
    const p = tui_style.activePalette();
    writeBorderLabelLeft(surface, ctx, 0, text, p.border_label);
}

fn writeBorderLabelLeft(surface: *vxfw.Surface, ctx: vxfw.DrawContext, row: u16, text: []const u8, style: vaxis.Style) void {
    if (text.len == 0 or row >= surface.size.height) return;
    var col: u16 = 1;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const width: u16 = @intCast(ctx.stringWidth(bytes));
        if (width == 0) continue;
        if (col + width >= surface.size.width) break;
        surface.writeCell(col, row, .{
            .char = .{ .grapheme = bytes, .width = @intCast(width) },
            .style = style,
        });
        col += width;
    }
}

pub const OverlayWidget = struct {
    app: *App,

    pub fn widget(self: *OverlayWidget) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawOverlay };
    }

    fn drawOverlay(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *OverlayWidget = @ptrCast(@alignCast(ptr));
        const p = tui_style.activePalette();
        const size = if (self.app.mode == .provider_picker and self.app.pickers.provider.stage == .form)
            OverlaySize{ .width = 72, .height = 12 }
        else
            overlaySize(self.app.mode);
        const max_w: u16 = ctx.max.width orelse size.width;
        const max_h: u16 = ctx.max.height orelse size.height;
        const total_w: u16 = @min(size.width, max_w);
        const total_h: u16 = @min(size.height, max_h);
        var inner: OverlayInner = .{ .app = self.app };
        const label_text = overlayLabel(self.app);
        const border_labels: []const vxfw.Border.BorderLabel = if (label_text.len > 0)
            &.{.{ .text = label_text, .alignment = .top_left }}
        else
            &.{};
        var border: vxfw.Border = .{
            .child = inner.widget(),
            .labels = border_labels,
            .style = p.thinking_body,
        };
        return border.widget().draw(ctx.withConstraints(
            .{ .width = total_w, .height = total_h },
            .{ .width = total_w, .height = total_h },
        ));
    }
};

const OverlayInner = struct {
    app: *App,

    fn widget(self: *OverlayInner) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawInner };
    }

    fn drawInner(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *OverlayInner = @ptrCast(@alignCast(ptr));
        const p = tui_style.activePalette();
        const iw: u16 = ctx.max.width orelse 0;
        const ih: u16 = ctx.max.height orelse 0;

        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{ .width = iw, .height = ih });
        const empty_cell = vaxis.Cell{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{},
        };
        @memset(surface.buffer, empty_cell);

        // The provider setup form, the settings panel, and the help modal host
        // their own headers/navigation, so they skip the shared search row
        // entirely and fill the panel from the top. `.plugins` matches: its
        // focus stays on root (syncFocus routes it there), so a drawn palette
        // filter row could never receive focus or text.
        const is_full_panel = (self.app.mode == .provider_picker and self.app.pickers.provider.stage == .form) or
            self.app.mode == .settings or self.app.mode == .help or self.app.mode == .mcp or
            self.app.mode == .plugins;
        if (is_full_panel) {
            const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
            children[0] = .{
                .origin = .{ .row = 0, .col = 0 },
                .z_index = 0,
                .surface = try drawContent(self.app, ctx.withConstraints(
                    .{ .width = iw, .height = ih },
                    .{ .width = iw, .height = ih },
                )),
            };
            surface.children = children;
            return surface;
        }

        // Horizontal separator under the search row.
        var sep_col: u16 = 0;
        while (sep_col < iw) : (sep_col += 1) {
            surface.writeCell(sep_col, 1, .{
                .char = .{ .grapheme = "─", .width = 1 },
                .style = p.thinking_body,
            });
        }

        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);

        // Row 0: prompt + shared overlay search input.
        var prompt_text: vxfw.Text = .{ .text = ">", .softwrap = false, .width_basis = .parent };
        var prompt_box: vxfw.SizedBox = .{ .child = prompt_text.widget(), .size = .{ .width = 2, .height = 1 } };
        var input_box: vxfw.SizedBox = .{ .child = self.app.inputs.palette.widget(), .size = .{ .width = iw -| 2, .height = 1 } };
        var search_row: vxfw.FlexRow = .{ .children = &.{
            .{ .widget = prompt_box.widget(), .flex = 0 },
            .{ .widget = input_box.widget(), .flex = 1 },
        } };
        children[0] = .{
            .origin = .{ .row = 0, .col = 0 },
            .z_index = 0,
            .surface = try search_row.widget().draw(ctx.withConstraints(
                .{ .width = iw, .height = 1 },
                .{ .width = iw, .height = 1 },
            )),
        };

        // Rows 2..: mode-specific content area.
        const content_h: u16 = ih -| 2;
        const content_ctx = ctx.withConstraints(
            .{ .width = iw, .height = content_h },
            .{ .width = iw, .height = content_h },
        );
        children[1] = .{
            .origin = .{ .row = 2, .col = 0 },
            .z_index = 0,
            .surface = try drawContent(self.app, content_ctx),
        };

        surface.children = children;
        return surface;
    }

    const mcp_status = @import("mcp_status.zig");
    const plugins_status = @import("plugins_status.zig");

    fn drawContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        return switch (app.mode) {
            .command => drawCommandContent(app, ctx),
            .session_picker => drawSessionContent(app, ctx),
            .provider_picker => drawProviderContent(app, ctx),
            .model_picker => drawModelContent(app, ctx),
            .tree_picker => drawTreeContent(app, ctx),
            .save_message => drawSaveMessageContent(app, ctx),
            .lanes => drawLanesContent(app, ctx),
            .help => drawHelpContent(app, ctx),
            .settings => drawSettingsContent(app, ctx),
            .mcp => drawMcpContent(app, ctx),
            .plugins => drawPluginsContent(app, ctx),
            .search => drawSearchContent(app, ctx),
            .theme_picker => drawThemeContent(app, ctx),
            // The diff viewer is full-screen — `drawRoot` returns before the
            // overlay path, so this is never reached.
            .normal, .diff_viewer => unreachable,
        };
    }

    fn drawSearchContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var content: search_widget.Content = .{ .state = &app.pickers.search };
        return content.widget().draw(ctx);
    }

    fn drawThemeContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const filter = try app.peekPaletteInputArena(ctx.arena);
        const active_name = app.theme_registry.resolve(app.cached_config.theme).name;
        var content: theme_picker.Content = .{
            .themes = app.theme_registry.slice(),
            .selection = app.pickers.theme.selection,
            .active_name = active_name,
            .filter = filter,
            .highlight_enabled = app.cached_config.tui.fuzzy_highlight,
            .highlight_style = app.cached_config.tui.fuzzy_highlight_style,
        };
        return content.widget().draw(ctx);
    }

    fn drawMcpContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var content: mcp_status.Content = .{
            .state = &app.pickers.mcp,
            .manager = &app.mcp_manager,
            .url_input = app.input_buffers.mcp_url.items,
        };
        return content.widget().draw(ctx);
    }

    fn drawPluginsContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        // Build plugin entries from the plugin manager
        var entries: std.ArrayList(plugins_status.PluginEntry) = .empty;
        defer entries.deinit(app.gpa);

        var iter = app.plugin_manager.iterator();
        while (iter.next()) |entry| {
            try entries.append(app.gpa, .{
                .name = entry.value_ptr.*.manifest.name,
                .active = entry.value_ptr.*.active,
            });
        }

        var content: plugins_status.Content = .{
            .state = &app.pickers.plugins,
            .plugins = entries.items,
        };
        return content.widget().draw(ctx);
    }

    fn drawHelpContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var content: help_picker.Content = .{ .state = &app.pickers.help };
        return content.widget().draw(ctx);
    }

    fn drawSettingsContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const runtime = app.liveRuntime();
        var content: settings_widget.Content = .{
            .state = &app.pickers.settings,
            .config = &app.cached_config,
            .home_dir = if (runtime) |r| r.home_dir else "",
            .cwd = if (runtime) |r| r.cwd else ".",
            .system_prompt_input = app.input_buffers.settings_text.items,
            .bash_classifier_input = app.input_buffers.settings_text.items,
        };
        return content.widget().draw(ctx);
    }

    fn drawSaveMessageContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        _ = app;
        // No body — the border label ("Commit Message") and the input row say it all.
        var text: vxfw.Text = .{ .text = "" };
        return text.widget().draw(ctx);
    }

    fn drawTreeContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        var content: tree_selector.Content = .{
            .state = &app.pickers.tree,
            .list = &app.list_widgets.tree_list,
        };
        return content.widget().draw(ctx);
    }

    fn drawLanesContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const entries = try app.buildLaneEntries(ctx.arena);
        var content: lanes_picker.Content = .{
            .list = &app.list_widgets.lanes_list,
            .entries = entries,
            .selection = app.nav.lanes_selection,
            .empty_message = switch (app.nav.lanes_purpose) {
                .manage => "  No parked lanes.",
                .merge_dest => "  No lanes to merge into.",
            },
        };
        return content.widget().draw(ctx);
    }

    fn drawCommandContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        // The filter lives only for this frame's draw; the frame arena bounds
        // its lifetime, so skip the per-frame gpa alloc + free.
        const filter = try app.peekPaletteInputArena(ctx.arena);
        // Build the visible entry list (lane commands appear only with >1 lane);
        // resolveCommand applies the same visibility + filter, so indices align.
        var buf: [tui.commands.len]command_panel.Entry = undefined;
        var n: usize = 0;
        for (tui.commands) |entry| {
            if (!tui.commandVisible(app, entry)) continue;
            buf[n] = .{ .name = entry.name, .description = entry.description };
            n += 1;
        }
        var content: command_panel.Content = .{
            .entries = buf[0..n],
            .filter = filter,
            .selection = app.nav.command_selection,
            .highlight_enabled = app.cached_config.tui.fuzzy_highlight,
            .highlight_style = app.cached_config.tui.fuzzy_highlight_style,
        };
        return content.widget().draw(ctx);
    }

    fn drawSessionContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const filter = try app.peekPaletteInputArena(ctx.arena);
        var content: resume_picker.Content = .{
            .io = app.io,
            .list = &app.list_widgets.resume_list,
            .summaries = app.resume_summaries.items,
            .selection = app.nav.resume_selection,
            .folded_projects = app.resume_folded_projects.items,
            .filter = filter,
            .group_by = app.nav.resume_group_by,
            .action = app.nav.session_action,
            .rename_text = app.input_buffers.session_rename_text.items,
            .highlight_enabled = app.cached_config.tui.fuzzy_highlight,
            .highlight_style = app.cached_config.tui.fuzzy_highlight_style,
        };
        return content.widget().draw(ctx);
    }

    fn drawProviderContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const filter = try app.peekPaletteInputArena(ctx.arena);
        var content: provider_picker.Content = .{
            .state = app.pickers.provider,
            .codex_signed_in = app.isCodexSignedIn(),
            // `conn_status` is indexed by `catalogueProviders()` order, exactly
            // how the picker iterates its rows.
            .statuses = &app.provider_state.conn_status,
            .key_input = app.input_buffers.provider_key.items,
            .api_keys = &app.provider_state.api_keys,
            .filter = filter,
            .highlight_enabled = app.cached_config.tui.fuzzy_highlight,
            .highlight_style = app.cached_config.tui.fuzzy_highlight_style,
        };
        return content.widget().draw(ctx);
    }

    fn drawModelContent(app: *App, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const filter = try app.peekPaletteInputArena(ctx.arena);
        const status = tui_status.modelStatus(app.liveRuntime(), app.cached_config);
        // Project the consolidated entries into the parallel slices the picker
        // widget consumes. Arena-allocated, rebuilt each draw — cheap, and it
        // keeps the picker decoupled from the catalogue's internal layout.
        const entries = app.pickers.models.entries.items;
        const picker_models = try ctx.arena.alloc(codex.Model, entries.len);
        const picker_reasoning = try ctx.arena.alloc(u32, entries.len);
        for (entries, 0..) |entry, i| {
            picker_models[i] = entry.model;
            picker_reasoning[i] = entry.reasoning_index;
        }
        var content: model_picker.Content = .{
            .models = picker_models,
            .list = &app.list_widgets.model_list,
            .selection = app.pickers.models.model_selection,
            .column = app.pickers.models.model_column,
            .active_model = if (status) |value| value.model else null,
            .reasoning_options = tui.activeReasoningOptions(app),
            .reasoning_indexes = picker_reasoning,
            .footer = try buildModelPickerFooter(app, ctx.arena, status),
            .filter = filter,
            .loading = app.pickers.models.load == .loading,
            .error_message = if (app.pickers.models.load == .failed) app.pickers.models.load.failed.message else null,
            .highlight_enabled = app.cached_config.tui.fuzzy_highlight,
            .highlight_style = app.cached_config.tui.fuzzy_highlight_style,
        };
        return content.widget().draw(ctx);
    }

    /// Footer status line for the model picker: the save scope (moved out of
    /// the table, cycled with Ctrl+S) and the wire parameter the selected
    /// model+effort would actually emit (dialect-aware — DashScope uses
    /// `enable_thinking`, everything else `reasoning_effort`).
    fn buildModelPickerFooter(app: *App, arena: std.mem.Allocator, status: ?tui_status.ModelStatus) std.mem.Allocator.Error![]const u8 {
        const scope_text = switch (app.pickers.models.model_scope) {
            .global => "Global",
            .project => "Project",
            .session => "Session",
        };
        const opts = tui.activeReasoningOptions(app);
        const r_index: u32 = if (app.pickers.models.model_selection < app.pickers.models.entries.items.len)
            app.pickers.models.entries.items[app.pickers.models.model_selection].reasoning_index
        else
            0;
        const effort_label = if (r_index < opts.len) opts[r_index].label else "medium";
        const dialect = if (app.liveRuntime()) |rt| rt.wire_dialect else ai.WireDialect.minimal;
        const wire_param: []const u8 = if (dialect.usesEnableThinking()) "enable_thinking" else "reasoning_effort";
        const provider = if (status) |s| s.provider else "unknown provider";
        const refresh = if (app.pickers.models.load == .loading) "  ⟳ refreshing…" else "";
        return std.fmt.allocPrint(arena, "  Scope: {s}  │  Ctrl+S to change      →  {s}:\"{s}\" ({s}){s}", .{ scope_text, wire_param, effort_label, provider, refresh });
    }
};
