//! Command router for the TUI mode-dispatch switch.
//!
//! Pulled out of `tui.zig` (R2 of `_pm/Projects/tui-split`) — the original
//! `handleCommandKey` dispatched to seven per-mode arm functions
//! (`handleTreePickerKey`, `handleProviderPickerKey`, etc.) which all lived
//! as private methods on `App`. Centralising the dispatch as a free function
//! in a dedicated module makes the mode table visible at a glance and lets
//! each mode evolve into a focused struct with its own state and helpers.
//!
//! Behavioural identity is preserved: every key combo, every side effect
//! matches the pre-refactor implementation. Only the location changed.
//!
//! ## Structure
//!
//! One struct per `App.Mode` variant. Each struct owns a `handle` method
//! that used to be a private method on `App`. Sub-steps R2.1 through R2.8
//! move each arm in turn, replacing this stub with the real implementation
//! and removing the corresponding method from `tui.zig`.
//!
//! ## Why a free dispatcher, not a method
//!
//! `App.handleCommandKey` is invoked from inline tests in `tui.zig:7106-7693`
//! and from `event_router.routeKey`. Keeping a one-line delegate on `App`
//! preserves both call sites without exposing the dispatcher internals.

const std = @import("std");
const vaxis = @import("vaxis");
const tui = @import("../tui.zig");

const App = tui.App;
const Mode = App.Mode;
const provider_model = @import("provider_model.zig");
const clipboard_helper = @import("clipboard_helper.zig");
const help_picker = @import("widgets/help_picker.zig");
const previousIndex = tui.previousIndex;
const nextIndex = tui.nextIndex;

/// Top-level dispatch: routes a key to the per-mode handler for the current
/// `App.mode`. Returns true when visible state changed (caller redraws).
pub fn handleCommandKey(app: *App, key: vaxis.Key) !bool {
    return switch (app.getMode()) {
        .provider_picker => try ProviderPicker.handle(app, key),
        .model_picker => try ModelPicker.handle(app, key),
        .session_picker => try SessionPicker.handle(app, key),
        .tree_picker => try TreePicker.handle(app, key),
        .lanes => try Lanes.handle(app, key),
        .help => try HelpPicker.handle(app, key),
        .command => try CommandMenu.handle(app, key),
        .settings => try SettingsMode.handle(app, key),
        .mcp => try McpMode.handle(app, key),
        .plugins => try PluginsMode.handle(app, key),
        .search => try SearchMode.handle(app, key),
        // The diff viewer owns its keys directly in `captureEvent`; nothing
        // reaches the generic dispatch.
        .diff_viewer => false,
        // The save prompt is a plain text field: Enter/Esc are handled in
        // submit/cancel; every other key falls through to the focused input.
        .save_message => false,
        .normal => try Transcript.handle(app, key),
    };
}

/// File-tree picker mode (overlay search + tree state).
///
/// Keys: up/down move the cursor; left/right cycle the filter; tab toggles
/// the fold state of the currently selected node. Every other key falls
/// through to the input.
const TreePicker = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.up, .{})) {
            app.getTreeState().moveUp();
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            app.getTreeState().moveDown();
            return true;
        }
        if (key.matches(vaxis.Key.left, .{})) {
            const filter = try app.peekPaletteInput();
            defer app.gpa.free(filter);
            try app.getTreeState().cycleFilter(filter, false);
            return true;
        }
        if (key.matches(vaxis.Key.right, .{})) {
            const filter = try app.peekPaletteInput();
            defer app.gpa.free(filter);
            try app.getTreeState().cycleFilter(filter, true);
            return true;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            const filter = try app.peekPaletteInput();
            defer app.gpa.free(filter);
            try app.getTreeState().toggleFoldSelected(filter);
            return true;
        }
        return false;
    }
};

/// Provider picker mode (provider list + API-key setup form).
/// Check if a key event corresponds to Enter/Return across terminal protocols and encodings.
pub fn isEnterKey(key: vaxis.Key) bool {
    if (key.matches(vaxis.Key.enter, .{})) return true;
    if (key.codepoint == '\r' or key.codepoint == '\n') return true;
    if (key.codepoint == vaxis.Key.enter) return true;
    if (key.text) |text| {
        if (std.mem.eql(u8, text, "\r") or std.mem.eql(u8, text, "\n") or std.mem.eql(u8, text, "\r\n")) return true;
    }
    return false;
}

const ProviderPicker = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        if (app.getProviderPicker().stage == .form) {
            app.getProviderPicker().form_error = null;
            if (key.matches(vaxis.Key.escape, .{})) return false;
            if (isEnterKey(key)) return false;

            if (key.matches(vaxis.Key.backspace, .{})) {
                app.popProviderKeyInput();
                return true;
            }
            if (key.codepoint == 'h' and key.mods.ctrl) {
                app.getProviderPicker().show_secret = !app.getProviderPicker().show_secret;
                return true;
            }
            if (key.text) |text| {
                const trimmed = std.mem.trim(u8, text, "\r\n");
                if (trimmed.len > 0) {
                    try app.getProviderKeyInput().appendSlice(app.gpa, trimmed);
                    return true;
                }
            } else if (key.codepoint >= 32 and key.codepoint <= 126 and !key.mods.ctrl and !key.mods.alt and !key.mods.super) {
                const byte: u8 = @intCast(key.codepoint);
                try app.getProviderKeyInput().append(app.gpa, byte);
                return true;
            }
            // Swallow everything else (arrows, tab) — Enter/Esc are handled upstream.
            return true;
        }
        return app.getProviderPicker().handleKey(key, app.isCodexSignedIn());
    }
};

/// Model picker mode (column switcher + row navigation + reasoning/scope).
///
/// Left/right move between model columns; tab cycles the active column's
/// value (column -> reasoning -> scope -> column); up/down step the
/// selection through filtered entries.
const ModelPicker = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        const models = app.getModels();
        if (key.matches(vaxis.Key.left, .{})) {
            models.model_column = models.model_column.previous();
            return true;
        }
        if (key.matches(vaxis.Key.right, .{})) {
            if (models.len() > 0) models.model_column = models.model_column.next();
            return true;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            switch (models.model_column) {
                .model => models.model_column = models.model_column.next(),
                .reasoning => try provider_model.cycleSelectedReasoning(app),
            }
            return true;
        }
        // Ctrl+S cycles the save scope (global → project → session) from the
        // picker. The scope no longer has a table column — it's shown in the
        // footer status line instead.
        if (key.matches('s', .{ .ctrl = true })) {
            provider_model.cycleModelScope(app);
            return true;
        }
        if (key.matches(vaxis.Key.up, .{})) {
            try provider_model.stepModelSelection(app, false);
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            try provider_model.stepModelSelection(app, true);
            return true;
        }
        return false;
    }
};

/// Resume-session picker mode (project grouping + selection navigation).
///
/// Ctrl+A toggles global vs project-scoped resume list (and reloads from
/// disk); tab toggles fold of the selected project when in global mode;
/// up/down step the selection through the visible (filtered) entries.
/// 'd' enters a delete-confirmation sub-state; 'r' enters a rename
/// sub-state with a prefilled text buffer. Sub-states capture all keys
/// until submitted (Enter / y) or cancelled (Esc / n).
const SessionPicker = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        switch (app.nav.session_action) {
            .renaming => return handleRenameInput(app, key),
            .deleting => return handleDeleteConfirm(app, key),
            .blocked => {
                // Any key dismisses the blocked-action popup.
                app.cancelSessionAction();
                return true;
            },
            .browsing => {},
        }

        if (key.matches('a', .{ .ctrl = true })) {
            app.toggleResumeGroupBy();
            app.setResumeSelection(0);
            app.resumeClearFolds();
            try app.reloadResumeSessions();
            return true;
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            // In project mode, tab folds/unfolds the selected project.
            // In date mode, tab is a no-op (no folding by date).
            if (app.getResumeGroupBy() == .project) try app.toggleSelectedResumeProject();
            return true;
        }
        if (key.matches('d', .{})) {
            try app.beginDeleteSelectedSession();
            return true;
        }
        if (key.matches('r', .{})) {
            try app.beginRenameSelectedSession();
            return true;
        }
        if (key.matches(vaxis.Key.up, .{})) {
            const next = previousIndex(app.getResumeSelection(), try app.visibleResumeCount());
            app.setResumeSelection(next);
            app.syncResumeListCursor();
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            const next = nextIndex(app.getResumeSelection(), try app.visibleResumeCount());
            app.setResumeSelection(next);
            app.syncResumeListCursor();
            return true;
        }
        return false;
    }

    /// Text input for the rename form. Enter submits, Esc cancels; printable
    /// keys append to the rename buffer and everything else is swallowed.
    fn handleRenameInput(app: *App, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.escape, .{})) {
            app.cancelSessionAction();
            return true;
        }
        if (isEnterKey(key)) {
            try app.confirmRenameSelectedSession();
            return true;
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            app.popSessionRenameInput();
            return true;
        }
        if (key.text) |text| {
            const trimmed = std.mem.trim(u8, text, "\r\n");
            if (trimmed.len > 0) {
                try app.input_buffers.session_rename_text.appendSlice(app.gpa, trimmed);
                return true;
            }
        } else if (key.codepoint >= 32 and key.codepoint <= 126 and !key.mods.ctrl and !key.mods.alt and !key.mods.super) {
            const byte: u8 = @intCast(key.codepoint);
            try app.input_buffers.session_rename_text.append(app.gpa, byte);
            return true;
        }
        // Swallow everything else (arrows, tab) — the rename buffer is the
        // sole input target while this sub-state is active.
        return true;
    }

    /// Delete confirmation: 'y' confirms, Esc/'n' cancels. All other keys
    /// are swallowed so the user can't accidentally navigate away.
    fn handleDeleteConfirm(app: *App, key: vaxis.Key) !bool {
        if (key.matches('y', .{}) or key.matches('y', .{ .shift = true })) {
            try app.confirmDeleteSelectedSession();
            return true;
        }
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('n', .{}) or key.matches('n', .{ .shift = true })) {
            app.cancelSessionAction();
            return true;
        }
        return true;
    }
};

/// Lanes manager mode (parallel-lane picker + parked-lane management).
///
/// Up/down move the selection; in manage-purpose (parked lanes view)
/// 'm' merges the selected parked lane back into the active lane, and
/// 'x' deletes it. Lane errors are routed through the existing reporter.
const Lanes = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.up, .{})) {
            if (app.getLanesSelection() > 0) {
                app.setLanesSelection(app.getLanesSelection() - 1);
            }
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            const count = app.laneEntryCount();
            if (count > 0 and app.getLanesSelection() + 1 < count) {
                app.setLanesSelection(app.getLanesSelection() + 1);
            }
            return true;
        }
        if (app.getLanesPurpose() == .manage) {
            if (key.matches('m', .{}) or key.matches('m', .{ .shift = true })) {
                app.mergeSelectedParked() catch |err| try app.reportLaneError(err);
                return true;
            }
            if (key.matches('x', .{}) or key.matches('x', .{ .shift = true })) {
                app.deleteSelectedParked() catch |err| try app.reportLaneError(err);
                return true;
            }
        }
        return false;
    }
};

/// Slash-command menu mode.
///
/// Up/down move the cursor through the filtered command list. The
/// filter itself is owned by the input widget; this struct only owns
/// the selection.
const CommandMenu = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.up, .{})) {
            const next = previousIndex(app.getCommandSelection(), tui.commandMatchesCount(app));
            app.setCommandSelection(next);
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            const next = nextIndex(app.getCommandSelection(), tui.commandMatchesCount(app));
            app.setCommandSelection(next);
            return true;
        }
        return false;
    }
};

/// Normal-mode transcript navigation (block nav, @-mention popup, lane switch).
///
/// The largest arm — split into three sub-handlers (R2.8a/b/c) that each
/// own one concern: mention popup selection, block navigation, and
/// multi-lane switching. Each sub-handler returns true if it consumed
/// the key; Transcript.handle short-circuits and returns. The full arm
/// body still lives in `App.handleTranscriptKey` for the bits not yet
/// extracted.
pub const Transcript = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        // Prompt history navigation: Ctrl+Up / Alt+Up (previous prompt), Ctrl+Down / Alt+Down (next prompt).
        if (key.matches(vaxis.Key.up, .{ .ctrl = true }) or key.matches(vaxis.Key.up, .{ .alt = true })) {
            if (try app.navigatePromptHistory(.up)) return true;
        }
        if (key.matches(vaxis.Key.down, .{ .ctrl = true }) or key.matches(vaxis.Key.down, .{ .alt = true })) {
            if (try app.navigatePromptHistory(.down)) return true;
        }
        // R2.8a: @-mention popup owns up/down while active.
        if (try MentionPopup.handle(app, key)) return true;
        // R2.8b: block navigation owns shift+down and plain up/down.
        if (try BlockNav.handle(app, key)) return true;
        // R2.8c: lane switching and transcript toggle.
        if (try LaneSwitch.handle(app, key)) return true;
        return false;
    }
};

/// R2.8a: @-mention popup selection.
///
/// When the @-mention popup is open with results, up/down move the
/// selection through the result list. Other keys fall through.
pub const MentionPopup = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        if (!app.isAtSearchActive() or !app.atSearchHasResults()) return false;
        if (key.matches(vaxis.Key.up, .{})) {
            const next = previousIndex(app.getAtSelection(), @intCast(app.atResultsLen()));
            app.setAtSelection(next);
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            const next = nextIndex(app.getAtSelection(), @intCast(app.atResultsLen()));
            app.setAtSelection(next);
            return true;
        }
        return false;
    }
};

/// R2.8b: Block navigation through the transcript.
///
/// Shift+Down jumps to the bottom (re-entering the input when needed).
/// Plain Up/Down walks blocks: stepping down past the last block (when
/// it can't scroll further) re-enters the input and traps the cursor
/// there. Auto-scroll follows the navigation state.
pub const BlockNav = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        // Copy selected message block to clipboard via 'y', 'c', or Ctrl+C in block nav.
        if (app.getBlockNav()) {
            if (key.matches('y', .{}) or key.matches('c', .{}) or key.matches('c', .{ .ctrl = true })) {
                if (try clipboard_helper.copySelectedTranscriptBlock(app)) return true;
            }
        }
        if (key.matches(vaxis.Key.down, .{ .shift = true })) {
            app.jumpTranscriptToBottom();
            return true;
        }
        if (key.matches(vaxis.Key.up, .{})) {
            _ = app.navigateTranscript(.previous);
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            // Stepping down past the last block (when it can't scroll further)
            // re-enters the input and traps the cursor there again.
            if (app.getBlockNav() and app.selectionIsLastMessage() and !app.selectedMessageCanScrollDown()) {
                app.setBlockNav(false);
                app.setThreadAutoScroll(true);
                _ = try app.moveInputCursorVertical(.down);
                return true;
            }
            const scrolled = app.navigateTranscript(.next);
            app.setThreadAutoScroll(!scrolled and app.selectionIsLastMessage() and !app.selectedMessageIsLong());
            return true;
        }
        return false;
    }
};

/// R2.8c: Lane switching and transcript toggle.
///
/// With multiple lanes, Shift+Tab/Shift+Right cycle forward, Shift+Left
/// cycles back. Plain Tab toggles the currently selected transcript
/// block (used to copy from the transcript).
pub const LaneSwitch = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        if (app.threadsCount() > 1) {
            if (key.matches(vaxis.Key.tab, .{ .shift = true }) or key.matches(vaxis.Key.right, .{ .shift = true })) {
                app.cycleLane(1);
                return true;
            }
            if (key.matches(vaxis.Key.left, .{ .shift = true })) {
                app.cycleLane(-1);
                return true;
            }
        }
        if (key.matches(vaxis.Key.tab, .{})) {
            app.toggleSelectedTranscriptBlock();
            return true;
        }
        return false;
    }
};

pub const HelpPicker = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        // Same body-row derivation `Content.draw` renders with — the keyboard
        // and mouse clamps must agree or the last items become unreachable.
        const body_height: u16 = help_picker.bodyRows(help_picker.help_overlay_height);
        if (key.matches(vaxis.Key.escape, .{}) or key.matches(vaxis.Key.enter, .{}) or key.matches('q', .{})) {
            app.mode = .normal;
            app.pickers.help.reset();
            app.clearInput();
            app.clearPaletteInput();
            return true;
        }
        if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            app.pickers.help.scrollUp(1);
            return true;
        }
        if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
            app.pickers.help.scrollDown(1, body_height);
            return true;
        }
        if (key.matches(vaxis.Key.page_up, .{})) {
            app.pickers.help.scrollUp(8);
            return true;
        }
        if (key.matches(vaxis.Key.page_down, .{})) {
            app.pickers.help.scrollDown(8, body_height);
            return true;
        }
        if (key.matches(vaxis.Key.home, .{})) {
            app.pickers.help.scroll = 0;
            return true;
        }
        if (key.matches(vaxis.Key.end, .{})) {
            app.pickers.help.scroll = help_picker.State.maxScroll(body_height);
            return true;
        }
        return false;
    }
};

/// Transcript search mode (Ctrl+F / /search).
///
/// Up/down step the match selection. Enter jumps (routed through `submitMode`
/// in `mode_lifecycle`), Esc cancels, and every other key falls through to the
/// palette input, whose `paletteInputChanged` hook re-filters live.
const SearchMode = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        const state = &app.pickers.search;
        if (key.matches(vaxis.Key.up, .{})) {
            if (state.matches.items.len > 0) {
                state.selection = previousIndex(state.selection, @intCast(state.matches.items.len));
            }
            return true;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            if (state.matches.items.len > 0) {
                state.selection = nextIndex(state.selection, @intCast(state.matches.items.len));
            }
            return true;
        }
        return false;
    }
};

/// Settings panel mode — tab navigation, toggle, text edit, save.
const SettingsMode = struct {
    pub fn handle(app: *App, key: vaxis.Key) !bool {
        // Text-edit mode: delegate all keys to the inline editor.
        if (try tui.handleSettingsTextEditKey(app, key)) return true;

        // Ctrl+S: save settings.
        if (key.matches('s', .{ .ctrl = true })) {
            _ = try tui.saveSettings(app);
            return true;
        }
        // Delete / Backspace on a non-editing row: clear the field.
        if (key.matches(vaxis.Key.delete, .{})) {
            tui.clearSettingsField(app);
            return true;
        }
        // Delegate structural navigation to the State's handleKey.
        if (app.pickers.settings.handleKey(key)) return true;
        return false;
    }
};

const McpMode = struct {
    fn handle(app: *App, key: vaxis.Key) !bool {
        // The add-server form owns all keys until it is submitted or cancelled.
        if (app.pickers.mcp.adding) return handleAddInput(app, key);
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
            tui.closeMcp(app);
            return true;
        }
        if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            app.pickers.mcp.moveUp();
            return true;
        }
        if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
            app.pickers.mcp.moveDown(app.mcp_manager.clients.items.len);
            return true;
        }
        if (key.matches(' ', .{}) or key.matches(vaxis.Key.enter, .{})) {
            if (app.pickers.mcp.selection < app.mcp_manager.clients.items.len) {
                const client = &app.mcp_manager.clients.items[app.pickers.mcp.selection];
                switch (client.status()) {
                    .connected => {
                        client.stop(app.io);
                        client.lifecycle = .disabled;
                    },
                    .failed => {
                        // Reconnect on toggle when failed
                        app.mcp_manager.reconnectClient(app.io, app.pickers.mcp.selection);
                    },
                    else => {
                        client.markConnecting();
                    },
                }
                provider_model.injectMcpTools(app);
                return true;
            }
        }
        if (key.matches('r', .{ .ctrl = true }) or key.matches('r', .{})) {
            if (app.pickers.mcp.selection < app.mcp_manager.clients.items.len) {
                app.mcp_manager.reconnectClient(app.io, app.pickers.mcp.selection);
                provider_model.injectMcpTools(app);
            }
            return true;
        }
        if (key.matches('d', .{})) {
            if (app.pickers.mcp.selection < app.mcp_manager.clients.items.len) {
                app.mcp_manager.disconnectClient(app.io, app.pickers.mcp.selection);
                provider_model.injectMcpTools(app);
            }
            return true;
        }
        if (key.matches('a', .{})) {
            app.pickers.mcp.adding = true;
            app.input_buffers.mcp_url.clearRetainingCapacity();
            return true;
        }
        return false;
    }

    /// Text input for the "add server by URL" form. Enter submits, Esc cancels;
    /// printable keys append to the URL buffer and everything else is swallowed.
    fn handleAddInput(app: *App, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.escape, .{})) {
            app.pickers.mcp.adding = false;
            app.input_buffers.mcp_url.clearRetainingCapacity();
            return true;
        }
        if (isEnterKey(key)) {
            const url = std.mem.trim(u8, app.input_buffers.mcp_url.items, " \t\r\n");
            if (url.len > 0) provider_model.addMcpServerByUrl(app, url) catch {};
            app.pickers.mcp.adding = false;
            app.input_buffers.mcp_url.clearRetainingCapacity();
            return true;
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            app.popMcpUrlInput();
            return true;
        }
        if (key.text) |text| {
            const trimmed = std.mem.trim(u8, text, "\r\n");
            if (trimmed.len > 0) {
                try app.input_buffers.mcp_url.appendSlice(app.gpa, trimmed);
                return true;
            }
        } else if (key.codepoint >= 32 and key.codepoint <= 126 and !key.mods.ctrl and !key.mods.alt and !key.mods.super) {
            const byte: u8 = @intCast(key.codepoint);
            try app.input_buffers.mcp_url.append(app.gpa, byte);
            return true;
        }
        return true;
    }
};

const PluginsMode = struct {
    fn handle(app: *App, key: vaxis.Key) !bool {
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
            tui.closePlugins(app);
            return true;
        }
        if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            app.pickers.plugins.moveUp();
            return true;
        }
        if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
            app.pickers.plugins.moveDown(0); // count comes from plugin manager
            return true;
        }
        return false;
    }
};

const agent_mod = @import("../agent.zig");

test "provider picker setup form captures key codepoints and text without swallowing Enter" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.pickers.provider.stage = .form;

    try std.testing.expect(try ProviderPicker.handle(&app, .{ .codepoint = 's' }));
    try std.testing.expectEqualStrings("s", app.input_buffers.provider_key.items);

    try std.testing.expect(try ProviderPicker.handle(&app, .{ .codepoint = 'k' }));
    try std.testing.expectEqualStrings("sk", app.input_buffers.provider_key.items);

    try std.testing.expect(try ProviderPicker.handle(&app, .{ .codepoint = vaxis.Key.backspace }));
    try std.testing.expectEqualStrings("s", app.input_buffers.provider_key.items);

    try std.testing.expect(!try ProviderPicker.handle(&app, .{ .codepoint = vaxis.Key.enter }));
}

test "provider picker setup form submit with empty key sets form_error" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .provider_picker;
    app.pickers.provider.stage = .form;
    app.pickers.provider.form_handle = .{ .builtin = .openrouter };

    provider_model.submitProviderSetup(&app, .openrouter) catch {};
    try std.testing.expect(app.pickers.provider.form_error != null);

    _ = try ProviderPicker.handle(&app, .{ .codepoint = 'a' });
    try std.testing.expect(app.pickers.provider.form_error == null);
}
