//! Settings mode lifecycle — key handling, toggle logic, and config
//! persistence for the `/settings` overlay.
//!
//! Keeps all settings-related mutation in one place so `tui.zig` and
//! `command_router.zig` stay thin: they just delegate here.

const std = @import("std");
const log = std.log.scoped(.tui);
const vaxis = @import("vaxis");
const tui = @import("../tui.zig");
const config_mod = @import("../config/config.zig");
const settings_widget = @import("widgets/settings.zig");
const toast = @import("toast.zig");

const App = tui.App;
const State = settings_widget.State;
const Tab = settings_widget.Tab;
const EditTarget = settings_widget.EditTarget;

// ---------------------------------------------------------------------------
// Helper functions
// ---------------------------------------------------------------------------

/// Check if pending values differ from current config values.
fn hasActualChanges(state: *const State, config: *const config_mod.Config) bool {
    if (state.pending_use_responses_endpoint) |v| {
        const current_value = if (config.model_selection) |ms| ms.useResponsesEndpoint() else config.use_responses_endpoint orelse false;
        if (v != current_value) return true;
    }
    if (state.pending_system_prompt) |s| {
        const current_value = if (config.model_selection) |ms| ms.systemPrompt() else config.system_prompt;
        const current_prompt = current_value orelse "";
        if (!std.mem.eql(u8, s, current_prompt)) return true;
    }
    if (state.pending_bash_classifier_url) |s| {
        const current_value = if (config.model_selection) |ms| ms.bashClassifierUrl() else config.bash_classifier_url;
        const current_url = current_value orelse "";
        if (!std.mem.eql(u8, s, current_url)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

const MAX_SYSTEM_PROMPT_LENGTH = 10000;
const MAX_SYSTEM_PROMPT_LENGTH_STR = "10000";

/// Validate bash classifier URL format.
fn validateBashClassifierUrl(url: []const u8) !void {
    if (url.len == 0) return;
    // Must start with http:// or https://
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return error.InvalidUrl;
    }
    // Basic length check
    if (url.len > 2048) return error.UrlTooLong;
}

/// Validate system prompt content.
fn validateSystemPrompt(prompt: []const u8) !void {
    if (prompt.len > MAX_SYSTEM_PROMPT_LENGTH) {
        return error.PromptTooLong;
    }
}

// ---------------------------------------------------------------------------
// Open / close
// ---------------------------------------------------------------------------

pub fn openSettings(app: *App) void {
    app.mode = .settings;
    app.pickers.settings.reset();
    app.clearInput();
    app.clearPaletteInput();
}

pub fn closeSettings(app: *App) void {
    app.mode = .normal;
    app.clearInput();
    app.clearPaletteInput();
}

// ---------------------------------------------------------------------------
// Enter key — toggle or begin editing
// ---------------------------------------------------------------------------

pub fn submitSettings(app: *App) !void {
    const state = &app.pickers.settings;
    switch (state.tab) {
        .general => try submitGeneralItem(app, state),
        .prompt => submitPromptItem(app, state),
        .advanced => submitAdvancedItem(app, state),
        .about => {}, // read-only
    }
}

fn submitGeneralItem(app: *App, state: *State) !void {
    switch (state.selection[@intFromEnum(Tab.general)]) {
        0 => {
            // Toggle use_responses_endpoint.
            const current = state.pending_use_responses_endpoint orelse
                (if (app.cached_config.model_selection) |ms| ms.useResponsesEndpoint() else app.cached_config.use_responses_endpoint orelse false);
            const new_value = !current;
            state.pending_use_responses_endpoint = new_value;
            // Only mark dirty if the new value differs from the config
            const config_value = if (app.cached_config.model_selection) |ms| ms.useResponsesEndpoint() else app.cached_config.use_responses_endpoint orelse false;
            state.dirty = (new_value != config_value);
        },
        1 => {
            // Toggle toast notifications.
            const current = state.pending_toast_enabled orelse
                (app.cached_config.toast.enabled orelse true);
            const new_value = !current;
            state.pending_toast_enabled = new_value;
            const config_value = app.cached_config.toast.enabled orelse true;
            state.dirty = (new_value != config_value);
        },
        else => {},
    }
}

fn submitPromptItem(app: *App, state: *State) void {
    switch (state.selection[@intFromEnum(Tab.prompt)]) {
        0 => {
            // Enter edit mode for system prompt.
            state.edit_target = .system_prompt;
            const current = if (app.cached_config.model_selection) |ms|
                (ms.systemPrompt() orelse "")
            else
                "";
            app.input_buffers.settings_text.clearRetainingCapacity();
            app.input_buffers.settings_text.appendSlice(app.gpa, current) catch {};
        },
        else => {},
    }
}

fn submitAdvancedItem(app: *App, state: *State) void {
    switch (state.selection[@intFromEnum(Tab.advanced)]) {
        0 => {
            // Enter edit mode for bash_classifier_url.
            state.edit_target = .bash_classifier_url;
            const current = if (app.cached_config.model_selection) |ms|
                (ms.bashClassifierUrl() orelse "")
            else
                "";
            app.input_buffers.settings_text.clearRetainingCapacity();
            app.input_buffers.settings_text.appendSlice(app.gpa, current) catch {};
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Delete key — clear a text field
// ---------------------------------------------------------------------------

pub fn clearCurrentField(app: *App) void {
    const state = &app.pickers.settings;
    switch (state.tab) {
        .prompt => {
            // Free pending value if any was set.
            if (state.pending_system_prompt) |old| {
                app.gpa.free(old);
                state.pending_system_prompt = null;
            }
            if (app.cached_config.model_selection != null and
                app.cached_config.model_selection.?.systemPrompt() != null) state.dirty = true;
        },
        .advanced => {
            if (state.pending_bash_classifier_url) |old| {
                app.gpa.free(old);
                state.pending_bash_classifier_url = null;
            }
            if (app.cached_config.model_selection != null and
                app.cached_config.model_selection.?.bashClassifierUrl() != null) state.dirty = true;
        },
        .general, .about => {},
    }
}

// ---------------------------------------------------------------------------
// Ctrl+S — save pending changes
// ---------------------------------------------------------------------------

/// Save all pending settings to the global config file (and the project
/// config if one exists) and update the live cached_config. Returns true
/// if anything was written.
///
/// Only writes the fields that the settings panel manages
/// (use_responses_endpoint, system_prompt, bash_classifier_url). Provider
/// and model selection are managed by the model picker, not here — cloning
/// the merged model_selection would leak project-level overrides into the
/// global config.
pub fn saveSettings(app: *App) !bool {
    const state = &app.pickers.settings;
    if (!state.dirty and state.edit_target == .none) return false;

    // Flush any in-progress text edit before saving.
    if (state.edit_target != .none) try commitTextEdit(app);

    // Check if there are actual changes vs just toggling back.
    if (!hasActualChanges(state, &app.cached_config)) {
        // No real changes, just reset pending state.
        state.dirty = false;
        state.pending_use_responses_endpoint = null;
        state.pending_system_prompt = null;
        state.pending_bash_classifier_url = null;
        _ = try app.thread.transcript.append(app.gpa, .info, "Settings", "No changes to save");
        return false;
    }

    // Validate inputs before saving.
    if (state.pending_bash_classifier_url) |url| {
        validateBashClassifierUrl(url) catch |err| {
            log.warn("settings.validation.url_failed err={s}", .{@errorName(err)});
            const msg = switch (err) {
                error.InvalidUrl => "URL must start with http:// or https://",
                error.UrlTooLong => "URL is too long (max 2048 characters)",
            };
            _ = try app.thread.transcript.append(app.gpa, .notice, "Settings", msg);
            return false;
        };
    }
    if (state.pending_system_prompt) |prompt| {
        validateSystemPrompt(prompt) catch |err| {
            log.warn("settings.validation.prompt_failed err={s}", .{@errorName(err)});
            const msg = switch (err) {
                error.PromptTooLong => "System prompt is too long (max " ++ MAX_SYSTEM_PROMPT_LENGTH_STR ++ " characters)",
            };
            _ = try app.thread.transcript.append(app.gpa, .notice, "Settings", msg);
            return false;
        };
    }

    // Build updates with only the fields the settings panel manages.
    // Do NOT clone model_selection from cached_config — that would
    // copy project-level provider/model overrides into the global config.
    var updates: config_mod.Config = .{};
    defer updates.deinit(app.gpa);
    if (state.pending_use_responses_endpoint) |v| {
        updates.use_responses_endpoint = v;
    }
    if (state.pending_system_prompt) |s| {
        updates.system_prompt = try app.gpa.dupe(u8, s);
    }
    if (state.pending_bash_classifier_url) |s| {
        updates.bash_classifier_url = if (s.len > 0) try app.gpa.dupe(u8, s) else null;
    }
    if (state.pending_toast_enabled) |v| {
        updates.toast.enabled = v;
    }

    const runtime = app.liveRuntime() orelse return false;

    // Write to global config only. Settings are user-level preferences,
    // not project-specific configuration. Provider/model selection can be
    // project-specific, but use_responses_endpoint, system_prompt, etc. should
    // apply globally across all projects.
    config_mod.mergeAndWriteGlobal(app.gpa, app.io, runtime.home_dir, updates) catch |err| {
        log.warn("settings.save.failed err={s}", .{@errorName(err)});
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Failed to save settings: {s}", .{@errorName(err)}) catch "Failed to save settings";
        _ = try app.thread.transcript.append(app.gpa, .notice, "Settings", msg);
        return false;
    };

    // Update the live cached_config so the running agent picks up the
    // changes without a restart.
    try applyToCachedConfig(app, state);
    app.mcp_manager.syncFromConfig(app.io, &app.cached_config) catch {};

    // Apply the toast toggle live to the global bus.
    if (state.pending_toast_enabled) |v| toast.global.enabled = v;

    // Reset pending state.
    if (state.pending_system_prompt) |old| app.gpa.free(old);
    if (state.pending_bash_classifier_url) |old| app.gpa.free(old);
    state.dirty = false;
    state.pending_use_responses_endpoint = null;
    state.pending_system_prompt = null;
    state.pending_bash_classifier_url = null;
    state.pending_toast_enabled = null;
    state.edit_target = .none;

    // Show success feedback to user.
    _ = try app.thread.transcript.append(app.gpa, .success, "Settings", "Settings saved successfully");

    return true;
}

fn commitTextEdit(app: *App) !void {
    const state = &app.pickers.settings;
    const text = app.input_buffers.settings_text.items;
    switch (state.edit_target) {
        .system_prompt => {
            // Validate before committing
            validateSystemPrompt(text) catch |err| {
                log.warn("settings.validation.prompt_failed err={s}", .{@errorName(err)});
                // Don't commit invalid prompt
                return;
            };
            if (state.pending_system_prompt) |old| app.gpa.free(old);
            if (text.len > 0) {
                state.pending_system_prompt = try app.gpa.dupe(u8, text);
            } else {
                state.pending_system_prompt = null;
            }
            state.dirty = true;
        },
        .bash_classifier_url => {
            // Validate before committing
            validateBashClassifierUrl(text) catch |err| {
                log.warn("settings.validation.url_failed err={s}", .{@errorName(err)});
                // Don't commit invalid URL
                return;
            };
            if (state.pending_bash_classifier_url) |old| app.gpa.free(old);
            state.pending_bash_classifier_url = try app.gpa.dupe(u8, text);
            state.dirty = true;
        },
        .none => {},
    }
    state.edit_target = .none;
    app.input_buffers.settings_text.clearRetainingCapacity();
}

fn applyToCachedConfig(app: *App, state: *const State) !void {
    if (!app.cached_config_owned) return;
    if (app.cached_config.model_selection) |*ms| {
        // Model selection exists: update it directly
        switch (ms.*) {
            .builtin => |*b| {
                if (state.pending_use_responses_endpoint) |v| b.use_responses_endpoint = v;
                if (state.pending_system_prompt) |s| {
                    if (b.system_prompt) |old| app.gpa.free(old);
                    b.system_prompt = try app.gpa.dupe(u8, s);
                }
                if (state.pending_bash_classifier_url) |s| {
                    if (b.bash_classifier_url) |old| app.gpa.free(old);
                    b.bash_classifier_url = if (s.len > 0) try app.gpa.dupe(u8, s) else null;
                }
            },
            .custom => |*c| {
                if (state.pending_use_responses_endpoint) |v| c.use_responses_endpoint = v;
                if (state.pending_system_prompt) |s| {
                    if (c.system_prompt) |old| app.gpa.free(old);
                    c.system_prompt = try app.gpa.dupe(u8, s);
                }
                if (state.pending_bash_classifier_url) |s| {
                    if (c.bash_classifier_url) |old| app.gpa.free(old);
                    c.bash_classifier_url = if (s.len > 0) try app.gpa.dupe(u8, s) else null;
                }
            },
        }
    } else {
        // Legacy config: update legacy fields directly
        if (state.pending_use_responses_endpoint) |v| app.cached_config.use_responses_endpoint = v;
        if (state.pending_system_prompt) |s| {
            if (app.cached_config.system_prompt) |old| app.gpa.free(old);
            app.cached_config.system_prompt = try app.gpa.dupe(u8, s);
        }
        if (state.pending_bash_classifier_url) |s| {
            if (app.cached_config.bash_classifier_url) |old| app.gpa.free(old);
            app.cached_config.bash_classifier_url = if (s.len > 0) try app.gpa.dupe(u8, s) else null;
        }
        // Sync legacy field updates to model_selection for consistency
        try config_mod.syncModelSelectionFromLegacy(app.gpa, &app.cached_config);
    }
    // Toast toggle applies regardless of model_selection shape.
    if (state.pending_toast_enabled) |v| app.cached_config.toast.enabled = v;
}

// ---------------------------------------------------------------------------
// Escape — cancel text edit or close
// ---------------------------------------------------------------------------

pub fn cancelSettings(app: *App) void {
    const state = &app.pickers.settings;
    if (state.edit_target != .none) {
        state.edit_target = .none;
        app.input_buffers.settings_text.clearRetainingCapacity();
        return;
    }
    closeSettings(app);
}

// ---------------------------------------------------------------------------
// Text editing key handling (when edit_target != .none)
// ---------------------------------------------------------------------------

/// Returns true when the key was consumed by the text editor.
/// When edit_target is .none this function returns false immediately.
pub fn handleTextEditKey(app: *App, key: vaxis.Key) !bool {
    const state = &app.pickers.settings;
    if (state.edit_target == .none) return false;

    if (key.matches(vaxis.Key.escape, .{})) {
        // Cancel — discard changes.
        state.edit_target = .none;
        app.input_buffers.settings_text.clearRetainingCapacity();
        return true;
    }
    if (key.matches('s', .{ .ctrl = true })) {
        // Ctrl+S while editing: commit + save.
        try commitTextEdit(app);
        _ = try saveSettings(app);
        return true;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        if (state.edit_target == .system_prompt) {
            try app.input_buffers.settings_text.append(app.gpa, '\n');
            return true;
        }
        // Enter commits the text edit without saving to disk (user must
        // press Ctrl+S to persist). This gives a chance to edit multiple
        // fields before saving.
        try commitTextEdit(app);
        return true;
    }
    if (key.matches(vaxis.Key.backspace, .{})) {
        popSettingsTextInput(app);
        return true;
    }
    if (key.text) |text| {
        if (text.len > 0) {
            try app.input_buffers.settings_text.appendSlice(app.gpa, text);
            return true;
        }
    } else if (key.codepoint >= 32 and key.codepoint <= 126 and
        !key.mods.ctrl and !key.mods.alt and !key.mods.super)
    {
        const byte: u8 = @intCast(key.codepoint);
        try app.input_buffers.settings_text.append(app.gpa, byte);
        return true;
    }
    // Swallow all remaining keys while in text-edit mode so they do not
    // propagate to the structural navigation handlers.
    return true;
}

fn popSettingsTextInput(app: *App) void {
    const items = app.input_buffers.settings_text.items;
    if (items.len == 0) return;
    // Walk back over continuation bytes to preserve UTF-8 codepoint boundary.
    var cut = items.len - 1;
    while (cut > 0 and (items[cut] & 0xC0) == 0x80) cut -= 1;
    app.input_buffers.settings_text.shrinkRetainingCapacity(cut);
}
