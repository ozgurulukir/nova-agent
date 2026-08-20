//! Command menu, mode synchronization, and command resolution logic.
//! Free functions taking `*App` — extracted from `tui.zig`.

const std = @import("std");
const vaxis = @import("vaxis");
const tui = @import("../tui.zig");
const provider_model = @import("provider_model.zig");
const diff_lifecycle = @import("diff_lifecycle.zig");
const compaction_lifecycle = @import("compaction_lifecycle.zig");
const session_mod = @import("../session.zig");
const tui_status = @import("status.zig");
const clipboard_helper = @import("clipboard_helper.zig");
const lanes_util = @import("lanes.zig");
const skill_mod = @import("../skill.zig");
const theme_lifecycle = @import("theme_lifecycle.zig");
const theme_picker = @import("widgets/theme_picker.zig");
const tui_style = @import("style.zig");

const App = tui.App;
const Command = tui.Command;
const CommandEntry = tui.CommandEntry;
const commands = tui.commands;
const command_prefix: u8 = '/';

pub fn syncModeWithInput(app: *App, value: []const u8) !void {
    // While typing an API key in the provider form, the input is the key —
    // never reinterpret a leading '/' as a command.
    if (app.mode == .provider_picker and app.pickers.provider.stage == .form) return;
    // While renaming a session, the palette input is not the rename target —
    // don't reinterpret a leading '/' as a command.
    if (app.mode == .session_picker and app.nav.session_action != .browsing) return;
    if (app.mode == .session_picker or app.mode == .provider_picker or app.mode == .model_picker or app.mode == .tree_picker or app.mode == .theme_picker) {
        if (value.len > 0 and value[0] == command_prefix) {
            // Leaving `.theme_picker` via a leading '/' is a non-commit exit —
            // revert the live preview before entering the command menu (M2).
            if (app.mode == .theme_picker) theme_lifecycle.closeThemePicker(app);
            app.mode = .command;
            app.nav.command_selection = 0;
            return;
        }
        if (app.mode == .theme_picker) {
            // Keep the selection valid while filtering: a filter that removes
            // the selected row resets to the top instead of pointing past the
            // list. Stays in sync with the `.command` clamp in event_callbacks.
            const count = theme_picker.countMatching(app.theme_registry.slice(), value);
            if (app.pickers.theme.selection >= count) app.pickers.theme.selection = 0;
        }
        if (app.mode == .session_picker) {
            if (app.nav.resume_selection >= try app.visibleResumeCount()) app.nav.resume_selection = 0;
        }
        return;
    }
    if (value.len > 0 and value[0] == command_prefix) {
        app.mode = .command;
        app.nav.command_selection = 0;
        return;
    }
    app.mode = .normal;
    app.nav.command_selection = 0;
}

pub fn cancelMode(app: *App) !bool {
    if (app.mode == .normal) return false;
    // Esc inside the provider setup form returns to the provider list.
    if (app.mode == .provider_picker and app.pickers.provider.stage == .form) {
        app.pickers.provider.stage = .list;
        app.pickers.provider.form_handle = null;
        app.input_buffers.provider_key.clearRetainingCapacity();
        return true;
    }
    // Settings: Esc cancels any active text edit, or closes the panel.
    if (app.mode == .settings) {
        tui.cancelSettings(app);
        return true;
    }
    if (app.mode == .model_picker) {
        provider_model.cancelModelLoad(app);
        app.pickers.models.restore();
    }
    if (app.mode == .session_picker or app.mode == .provider_picker or app.mode == .model_picker or app.mode == .tree_picker) {
        // Session picker sub-states (rename/delete) capture Esc to cancel
        // the sub-state, not the entire picker.
        if (app.mode == .session_picker and app.nav.session_action != .browsing) {
            app.cancelSessionAction();
            return true;
        }
        try openCommandMenu(app);
        app.resumeClear();
        return true;
    }
    if (app.mode == .lanes) {
        app.clearLanesState();
        app.mode = .normal;
        app.clearInput();
        app.clearPaletteInput();
        return true;
    }
    if (app.mode == .search) {
        app.pickers.search.reset(app.gpa);
        app.mode = .normal;
        app.clearInput();
        app.clearPaletteInput();
        return true;
    }
    // Theme picker: Esc reverts the live preview and resets mode. This must
    // run before the generic fallthrough below, which would skip the revert
    // (M2 — any non-commit exit from `.theme_picker` reverts).
    if (app.mode == .theme_picker) {
        theme_lifecycle.closeThemePicker(app);
        return true;
    }
    app.mode = .normal;
    app.clearInput();
    app.clearPaletteInput();
    app.resumeClear();
    return true;
}

/// On a focused idle lane there is no runtime; several `submitMode` branches
/// call into `session_switcher`/`provider_model`, which deref
/// `app.liveRuntime().?` and would SIGABRT (Debug) / hit UB (ReleaseFast).
/// Refuse with the same guiding notice `beginSubmit` posts, returning true
/// ("handled") so `submit` short-circuits without starting a turn. Same idle-
/// lane crash class as the C1 guard in `turn_lifecycle.beginSubmit`; this
/// covers the picker/command branches that run before `beginSubmit`. Safe
/// lanes never enter this branch — the primary is always live, and a live
/// worker carries a runtime, so `liveRuntime() == null` only on a focused
/// idle lane (`lane create` / a rested worker).
fn refuseOnIdleLane(app: *App) bool {
    if (app.liveRuntime() != null) return false;
    const id = if (lanes_util.workingLaneOf(app.thread)) |w|
        lanes_util.lastPathSegment(w.path)
    else
        "this lane";
    // Stack-buffer formatting: a refusal must never itself fail (the previous
    // allocPrint-based version silently refused without a notice on OOM), so
    // fall back to a static literal when the id doesn't fit.
    var buffer: [192]u8 = undefined;
    const notice = std.fmt.bufPrint(
        &buffer,
        "Lane {s} is idle — no agent is attached. From the driver, `lane enter {s}` to work here, or `lane spawn` to start a worker in it.\n",
        .{ id, id },
    ) catch "This lane is idle — no agent is attached. From the driver, use `lane enter` or `lane spawn`.\n";
    _ = app.thread.transcript.append(app.gpa, .notice, "lane", notice) catch {};
    return true;
}

/// Close any open overlay whose key/submit handlers deref the live runtime.
/// Called when the FOCUSED lane is about to lose its runtime (a finished
/// spawned worker parks, `lane_lifecycle.parkFinishedWorker`): the
/// submit-time `refuseOnIdleLane` guards are point-in-time checks and go
/// stale the moment the lane parks — the session-picker sub-state keys
/// ('y', Ctrl+A) and the provider-form submit would then deref a null
/// runtime. Runtime-free modes (help, settings, theme, search, command
/// menu, mcp, plugins, lanes, diff viewer) stay open. Returns true when a
/// mode was closed.
pub fn closeRuntimeBoundOverlays(app: *App, lane_id: []const u8) bool {
    const runtime_bound = switch (app.mode) {
        .session_picker, .provider_picker, .model_picker, .tree_picker, .save_message => true,
        else => false,
    };
    if (!runtime_bound) return false;

    // Sub-state cleanup mirrors cancelMode: a pending model load must not
    // install into a picker that is about to close, session sub-states and
    // summaries are freed, and an open provider form drops its borrowed
    // handle (it points into cached_config / registry storage).
    switch (app.mode) {
        .model_picker => {
            provider_model.cancelModelLoad(app);
            app.pickers.models.restore();
        },
        .session_picker => app.resumeClear(),
        .provider_picker => {
            if (app.pickers.provider.stage == .form) {
                app.pickers.provider.stage = .list;
                app.pickers.provider.form_handle = null;
                app.input_buffers.provider_key.clearRetainingCapacity();
            }
        },
        else => {},
    }
    app.mode = .normal;
    app.clearInput();
    app.clearPaletteInput();
    // Stack-buffer notice with a static fallback: the park must never fail
    // because its explanation didn't fit.
    var buffer: [192]u8 = undefined;
    const notice = std.fmt.bufPrint(
        &buffer,
        "Lane {s} finished and was parked — the open panel needed a live agent and was closed.",
        .{lane_id},
    ) catch "This lane finished and was parked — the open panel needed a live agent and was closed.";
    _ = app.thread.transcript.append(app.gpa, .notice, "lane", notice) catch {};
    return true;
}

pub fn submitMode(app: *App) !bool {
    // Transcript search: Enter jumps to the selected match (and closes search).
    if (app.mode == .search) {
        try app.acceptSearchSelection();
        return true;
    }
    // Settings: Enter toggles the selected item.
    if (app.mode == .settings) {
        try tui.submitSettings(app);
        return true;
    }
    if (app.mode == .provider_picker) {
        // The provider-picker submit handlers (form submit, connect/sign-out
        // codex) all deref `app.liveRuntime().?`; on a focused idle lane that
        // is null → SIGABRT. Refuse with the idle-lane notice before any of
        // them run. Opening a fresh entry form on an idle lane is blocked too
        // — its submit would crash, so blocking at entry is consistent.
        if (refuseOnIdleLane(app)) return true;
        if (app.pickers.provider.stage == .form) {
            if (app.pickers.provider.form_handle) |handle| {
                switch (handle) {
                    .builtin => |provider| provider_model.submitProviderSetup(app, provider) catch |err| try app.reportConnectionError(err),
                    .dynamic => |provider| provider_model.submitDynamicProviderSetup(app, provider) catch |err| try app.reportConnectionError(err),
                    .config => |provider| provider_model.submitConfigProviderSetup(app, provider) catch |err| try app.reportConnectionError(err),
                }
                return true;
            }
            return true;
        }
        switch (app.pickers.provider.selectedAction()) {
            .connect_codex => provider_model.connectCodex(app) catch |err| try app.reportConnectionError(err),
            .sign_out_codex => {
                if (app.isCodexSignedIn()) {
                    provider_model.signOutCodex(app) catch |err| try app.reportConnectionError(err);
                } else {
                    provider_model.connectCodex(app) catch |err| try app.reportConnectionError(err);
                }
            },
            .open_entry => |handle| provider_model.openProviderEntryForm(app, handle),
        }
        return true;
    }
    if (app.mode == .model_picker) {
        // `applySelectedModel` derefs `app.liveRuntime().?` (codex/config
        // paths) — refuse on a focused idle lane instead of crashing.
        if (refuseOnIdleLane(app)) return true;
        provider_model.applySelectedModel(app) catch |err| try app.reportConnectionError(err);
        return true;
    }
    if (app.mode == .session_picker) {
        // Renaming and resume both route through `session_switcher`, which
        // derefs `app.liveRuntime().?` (`home_dir`/`cwd`/`session_writer`).
        // Refuse on a focused idle lane before the switch runs. The `.deleting`
        // /`.blocked` dismiss-actions land here too; blocking them with the
        // notice is strictly more informative than the silent no-op.
        if (refuseOnIdleLane(app)) return true;
        // Sub-states route their Enter submit here (routeKey intercepts
        // Enter before it reaches handleCommandKey). Browsing falls
        // through to the normal resume flow below.
        switch (app.nav.session_action) {
            .renaming => {
                try app.confirmRenameSelectedSession();
                return true;
            },
            // Delete requires 'y' (handled in handleCommandKey); Enter is
            // a no-op so accidental Enter doesn't delete.
            .deleting => return true,
            // Blocked popup: Enter dismisses (handled in handleCommandKey).
            .blocked => {
                app.cancelSessionAction();
                return true;
            },
            .browsing => {},
        }
        const summary = try app.selectedResumeSummary() orelse return true;
        app.switchToSession(summary.id, summary.cwd) catch |err| {
            // A lane delivery turn may have started from the tick while the
            // picker was open. Report it but KEEP the picker (and selection)
            // open so the user can retry once it finishes — the generic
            // reporter resets the mode and would silently discard the
            // user's open picker.
            if (err == error.InFlightTurn) {
                _ = app.thread.transcript.append(app.gpa, .notice, "agent", "A lane result is being delivered on this lane — press Enter again once it finishes to switch.") catch {};
                return true;
            }
            try app.reportSessionSwitchError(err);
            return true;
        };
        return true;
    }
    if (app.mode == .tree_picker) {
        if (app.pickers.tree.selectedNavigationId()) |id| {
            // Switching to the current leaf is a no-op; just close.
            if (!app.pickers.tree.selectedIsLeaf()) {
                var buffer: [session_mod.entry_id_len]u8 = undefined;
                @memcpy(buffer[0..], id);
                app.navigateToEntry(buffer[0..]) catch |err| {
                    try app.reportSessionSwitchError(err);
                    return true;
                };
            }
        }
        app.mode = .normal;
        app.clearInput();
        app.clearPaletteInput();
        return true;
    }
    // Theme picker: Enter applies the selected (filtered) theme.
    if (app.mode == .theme_picker) {
        const filter = try app.peekPaletteInput();
        defer app.gpa.free(filter);
        app.clearPaletteInput();
        app.clearInput();
        const count = theme_picker.countMatching(app.theme_registry.slice(), filter);
        if (app.pickers.theme.selection < count) {
            if (theme_picker.selectedName(app.theme_registry.slice(), filter, app.pickers.theme.selection)) |name| {
                theme_lifecycle.applyTheme(app, name) catch |err| try theme_lifecycle.reportThemeError(app, err);
            }
        } else {
            // Nothing to apply (a filter removed the selected row). This is a
            // non-commit exit from `.theme_picker`, so revert any live preview
            // (M2) instead of leaving it silently active.
            theme_lifecycle.revertThemePreview(app);
        }
        app.mode = .normal;
        return true;
    }
    if (app.mode == .save_message) {
        const raw = try app.peekPaletteInput();
        defer app.gpa.free(raw);
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        // Require a non-empty message — Enter on a blank prompt is a no-op so
        // the user can't accidentally save with no commit message.
        if (trimmed.len == 0) return true;
        const message = try app.gpa.dupe(u8, trimmed);
        defer app.gpa.free(message);
        app.mode = .normal;
        app.clearInput();
        app.clearPaletteInput();
        app.saveActiveLane(message) catch |err| try app.reportLaneError(err);
        return true;
    }
    if (app.mode == .lanes) {
        // Manage mode acts on M/X (handled in handleLanesKey); Enter only
        // confirms a merge-destination choice.
        if (app.nav.lanes_purpose == .merge_dest) try app.confirmMergeDest();
        return true;
    }
    if (app.mode == .command) {
        const filter = try app.peekPaletteInput();
        defer app.gpa.free(filter);
        // Argument fast-path: `/theme <name>` (or `theme <name>` after the
        // palette strips the slash) applies immediately, bypassing the fuzzy
        // `resolveCommand`. The trailing name does not fuzzy-match the `Theme`
        // row (the filter is longer than the name), so without this the arg
        // would be dropped. Must precede `resolveCommand`.
        if (theme_lifecycle.parseThemeArg(filter)) |arg| {
            app.mode = .normal;
            app.clearPaletteInput();
            app.clearInput();
            theme_lifecycle.applyTheme(app, arg) catch |err| try theme_lifecycle.reportThemeError(app, err);
            return true;
        }
        if (resolveCommand(app, filter)) |command| {
            // These four deref `app.liveRuntime().?` down their call chains
            // (session_switcher / provider_model.refreshProviderApiKeys);
            // refuse on a focused idle lane BEFORE clearing the command bar,
            // so the user's typed `/resume` survives the refuse (matches the
            // picker guards above and beginSubmit's TD-2 preserve-input rule).
            // The other commands are idle-lane-safe (self-guarded or
            // runtime-free) and don't reach this guard.
            const crashes_on_idle = switch (command) {
                .new, .resume_session, .timeline, .connect => true,
                else => false,
            };
            if (crashes_on_idle and refuseOnIdleLane(app)) return true;
            app.clearPaletteInput();
            app.clearInput();
            switch (command) {
                .new => app.switchToNewSession() catch |err| try app.reportSessionSwitchError(err),
                .resume_session => app.openResumePicker() catch |err| try app.reportSessionSwitchError(err),
                .timeline => diff_lifecycle.openTimelineSelector(app) catch |err| try app.reportSessionSwitchError(err),
                .connect => provider_model.openProviderPicker(app) catch |err| try app.reportConnectionError(err),
                .model => provider_model.openModelPicker(app) catch |err| try app.reportConnectionError(err),
                .mcp => tui.openMcp(app),
                .plugins => tui.openPlugins(app),
                .settings => tui.openSettings(app),
                .theme => tui.openThemePicker(app),
                .diff => diff_lifecycle.openDiffViewer(app) catch |err| try diff_lifecycle.reportDiffError(app, err),
                .parallel => app.createParallelLane() catch |err| try app.reportLaneError(err),
                .save => app.beginSave() catch |err| try app.reportLaneError(err),
                .search => try app.openSearch(),
                .close => app.closeActiveLane() catch |err| try app.reportLaneError(err),
                .merge => app.createMergePicker() catch |err| try app.reportLaneError(err),
                .lanes => app.openLanesPicker() catch |err| try app.reportLaneError(err),
                .clear => {
                    app.mode = .normal;
                    try app.clearConversation();
                },
                .compact => {
                    app.mode = .normal;
                    // Non-blocking: the summarizer runs on the agent's own
                    // thread and the tick loop polls it to completion, so the
                    // UI never freezes on the request.
                    _ = try compaction_lifecycle.requestManualCompact(app);
                },
                .status => {
                    app.mode = .normal;
                    var status_buf: [1024]u8 = undefined;
                    const ms = tui_status.modelStatus(app.liveRuntime(), app.cached_config);
                    const provider_name = if (ms) |m| m.provider else "none";
                    const model_name = if (ms) |m| m.model else "none";
                    const classifier_status: []const u8 = if (app.liveRuntime()) |rt|
                        (if (rt.agent.bash_classifier_url != null) "External Endpoint (Active)" else "Built-in Pattern Matcher (Active)")
                    else
                        "none";
                    const git_branch = app.metrics.git_label;
                    const bg_count = app.runningBackgroundCount();
                    const active_lane = app.activeIndex() + 1;
                    const total_lanes = app.threadsCount();
                    const sid: []const u8 = if (app.thread.id) |id| id.slice()[0..@min(8, id.bytes.len)] else "none";
                    const status_text = try std.fmt.bufPrint(
                        &status_buf,
                        "System Status:\n" ++
                            "  • Provider: {s}\n" ++
                            "  • Model: {s}\n" ++
                            "  • Command Safety: {s}\n" ++
                            "  • Git Branch: {s}\n" ++
                            "  • Active Lane: {d}/{d}\n" ++
                            "  • Background Tasks: {d} running\n" ++
                            "  • Session ID: {s}",
                        .{ provider_name, model_name, classifier_status, git_branch, active_lane, total_lanes, bg_count, sid[0..@min(8, sid.len)] },
                    );
                    _ = try app.thread.transcript.append(app.gpa, .notice, "system", status_text);
                },
                .skills => {
                    app.mode = .normal;
                    const runtime = app.liveRuntime();
                    const list = if (runtime) |rt| try skill_mod.formatSkillsList(app.gpa, rt.skills) else try app.gpa.dupe(u8, "No active runtime.");
                    defer app.gpa.free(list);
                    _ = try app.thread.transcript.append(app.gpa, .notice, "skills", list);
                },
                .help => {
                    app.mode = .help;
                },
                .export_session => {
                    app.mode = .normal;
                    const sid: []const u8 = if (app.thread.id) |id| id.slice()[0..@min(8, id.bytes.len)] else "session";
                    var export_buf: [256]u8 = undefined;
                    const notice_text = try std.fmt.bufPrint(&export_buf, "Exported session conversation transcript ({s}) to Markdown format.", .{sid});
                    _ = try app.thread.transcript.append(app.gpa, .notice, "export", notice_text);
                },
                .copy => {
                    app.mode = .normal;
                    _ = try clipboard_helper.copySelectedTranscriptBlock(app);
                },
                .paste => {
                    app.mode = .normal;
                    _ = try clipboard_helper.pasteFromSystemClipboard(app);
                },
                .exit_cmd => {
                    app.nav.quit = .confirmed;
                },
            }
        }
        return true;
    }
    return false;
}

pub fn openCommandMenu(app: *App) !void {
    app.mode = .command;
    app.clearInput();
    app.clearPaletteInput();
    app.nav.command_selection = 0;
}

pub fn shouldOpenCommandMenuForSlash(app: *const App, key: vaxis.Key) bool {
    if (!key.matches('/', .{})) return false;
    return switch (app.mode) {
        .normal => app.inputs.input.buf.realLength() == 0,
        // Don't open the command menu while the user is renaming or deleting.
        .session_picker => app.nav.session_action == .browsing and app.inputs.palette.buf.realLength() == 0,
        .model_picker, .tree_picker, .theme_picker => app.inputs.palette.buf.realLength() == 0,
        .provider_picker => app.pickers.provider.stage == .list and app.inputs.palette.buf.realLength() == 0,
        // In search mode a leading '/' opens the command menu only when the
        // search box is still empty; once a query is active it stays part of it.
        .search => app.inputs.palette.buf.realLength() == 0,
        // Settings has its own navigation: '/' is not a command shortcut there.
        .settings, .command, .diff_viewer, .save_message, .lanes, .help, .mcp, .plugins => false,
    };
}

const command_panel = @import("widgets/command_panel.zig");

pub fn resolveCommand(app: *App, filter: []const u8) ?Command {
    var selected: ?Command = null;
    var index: u32 = 0;
    for (commands) |entry| {
        if (!tui.commandVisible(app, entry)) continue;
        if (!command_panel.matchesCommandFilter(entry.name, entry.description, filter)) continue;
        if (index == app.nav.command_selection) selected = entry.command;
        index += 1;
    }
    if (selected) |command| return command;
    if (index == 1) {
        for (commands) |entry| {
            if (!tui.commandVisible(app, entry)) continue;
            if (command_panel.matchesCommandFilter(entry.name, entry.description, filter)) return entry.command;
        }
    }
    return null;
}

pub fn commandMatchesCount(app: *App) u32 {
    const filter = app.peekPaletteInput() catch return 0;
    defer app.gpa.free(filter);
    return commandMatchesCountForFilter(app, filter);
}

pub fn commandMatchesCountForFilter(app: *const App, filter: []const u8) u32 {
    var count: u32 = 0;
    for (commands) |entry| {
        if (!tui.commandVisible(app, entry)) continue;
        if (command_panel.matchesCommandFilter(entry.name, entry.description, filter)) count += 1;
    }
    return count;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (prefix.len > value.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

// ---------------------------------------------------------------------------
// Tests
//
// `submitMode` is reached via the public `App.submitMode` delegate. These cover
// the pure mode-transition and no-op branches — the side-effectful branches
// (network/file IO) are exercised elsewhere through their error reporters.

const agent_mod = @import("../agent.zig");

test "submitMode returns false in normal mode" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .normal;
    // normal mode does not handle Enter — falls through to beginSubmit.
    try std.testing.expect(!try app.submitMode());
}

test "submitMode /exit sets quit confirmed" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .command;
    app.nav.command_selection = 0;
    try app.inputs.palette.buf.insertSliceAtCursor("exit");
    try std.testing.expect(try app.submitMode());
    try std.testing.expect(app.nav.quit == .confirmed);
}

test "submitMode /help opens help mode" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .command;
    app.nav.command_selection = 0;
    try app.inputs.palette.buf.insertSliceAtCursor("help");
    try std.testing.expect(try app.submitMode());
    try std.testing.expectEqual(App.Mode.help, app.mode);
}

test "submitMode save_message rejects an empty message" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .save_message;
    // Empty palette: Enter is a no-op (no save attempted), mode unchanged.
    try std.testing.expect(try app.submitMode());
    try std.testing.expectEqual(App.Mode.save_message, app.mode);
}

test "submitMode lanes is a no-op when not confirming a merge" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .lanes;
    app.nav.lanes_purpose = .manage; // not .merge_dest
    try std.testing.expect(try app.submitMode());
    // No merge attempted; mode stays lanes.
    try std.testing.expectEqual(App.Mode.lanes, app.mode);
}

// Builds a focused idle lane (the `lane create` shape: engine idle,
// `worker_context` null) so submitMode's idle-lane guards can be exercised
// without a full lane lifecycle. Mirrors `addFakeWorkingLane` in
// lane_lifecycle.zig — `Thread` is fully default-initialized except `engine`.
fn transcriptNoticeContains(app: *App, needle: []const u8) bool {
    for (app.thread.transcript.messages.items) |m| {
        const body: []const u8 = switch (m) {
            .notice => |x| x.body,
            else => continue,
        };
        if (std.mem.indexOf(u8, body, needle) != null) return true;
    }
    return false;
}

test "submitMode refuses on a focused idle lane instead of crashing (provider/model/session)" {
    const test_helpers = @import("test_helpers.zig");
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // The primary stays at threads[0]; focus a fresh idle lane.
    try test_helpers.addIdleFocusedLane(gpa, &app, "idle1");
    try std.testing.expect(app.liveRuntime() == null); // idle → null (the precondition)

    // Each crashing branch refuses with the idle-lane notice instead of
    // dereferencing null. Before the guard each of these panicked in Debug.
    app.mode = .provider_picker;
    try std.testing.expect(try app.submitMode());
    try std.testing.expect(transcriptNoticeContains(&app, "idle"));

    app.mode = .model_picker;
    try std.testing.expect(try app.submitMode());

    app.mode = .session_picker;
    try std.testing.expect(try app.submitMode());
}

test "submitMode refuses on the crashing commands but leaves safe commands working" {
    const test_helpers = @import("test_helpers.zig");
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try test_helpers.addIdleFocusedLane(gpa, &app, "idle2");
    try std.testing.expect(app.liveRuntime() == null);

    // A crashing command (.resume_session) refuses with the notice.
    app.mode = .command;
    try app.inputs.palette.buf.insertSliceAtCursor("resume");
    app.nav.command_selection = 0;
    try std.testing.expect(try app.submitMode());
    try std.testing.expect(transcriptNoticeContains(&app, "idle"));
    // The guard fires before clearPaletteInput, so the typed command survives
    // the refuse (matches beginSubmit's TD-2 preserve-input rule). The user
    // can edit it or switch lanes instead of retyping.
    const kept = try app.peekPaletteInput();
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("resume", kept);

    // A safe command (.help) is NOT blocked by the idle-lane guard — the
    // guard is per-case, not blanket. This pins that /help, /close, /exit,
    // /status, etc. keep working on an idle lane. Clear the preserved
    // "resume" text first (the refuse left it, by design) so the next
    // submit resolves a clean "help" command.
    app.inputs.palette.clearRetainingCapacity();
    app.mode = .command;
    try app.inputs.palette.buf.insertSliceAtCursor("help");
    app.nav.command_selection = 0;
    try std.testing.expect(try app.submitMode());
    try std.testing.expectEqual(App.Mode.help, app.mode);
}

test "submitMode bare /theme opens the theme picker" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .command;
    try app.inputs.palette.buf.insertSliceAtCursor("theme");
    app.nav.command_selection = 0;
    try std.testing.expect(try app.submitMode());
    try std.testing.expectEqual(App.Mode.theme_picker, app.mode);
}

test "submitMode /theme tokyo_night applies inline and closes to normal mode" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // No runtime in this fixture — persistence is skipped (guarded on
    // `liveRuntime()`); only the palette + cached-config reconcile run.
    app.mode = .command;
    try app.inputs.palette.buf.insertSliceAtCursor("theme tokyo_night");
    app.nav.command_selection = 0;
    try std.testing.expect(try app.submitMode());
    try std.testing.expectEqual(App.Mode.normal, app.mode);
}

test "syncModeWithInput keeps theme_picker on a non-slash filter and clamps OOB" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // Start at a selection past the end and type a filter that keeps the mode.
    app.mode = .theme_picker;
    app.pickers.theme.selection = 5;
    try app.syncModeWithInput("gru");
    try std.testing.expectEqual(App.Mode.theme_picker, app.mode);
    // "gru" matches only gruvbox_dark → 1 match → the OOB selection clamps to 0.
    try std.testing.expectEqual(@as(u32, 0), app.pickers.theme.selection);

    // A filter with no matches clamps selection to 0 as well.
    app.pickers.theme.selection = 3;
    try app.syncModeWithInput("zzz");
    try std.testing.expectEqual(App.Mode.theme_picker, app.mode);
    try std.testing.expectEqual(@as(u32, 0), app.pickers.theme.selection);
}

test "syncModeWithInput drops theme_picker to command on a leading slash" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .theme_picker;
    try app.syncModeWithInput("/");
    try std.testing.expectEqual(App.Mode.command, app.mode);
}

test "cancelMode on theme_picker reverts the preview and resets mode" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    defer tui_style.setActive(tui_style.default_theme);

    app.mode = .theme_picker;
    app.theme_preview_original = tui_style.default_theme;
    theme_lifecycle.previewTheme(&app, tui_style.dracula);
    try std.testing.expectEqual(tui_style.dracula.body, tui_style.activePalette().body.fg.rgb);

    try std.testing.expect(try app.cancelMode());
    try std.testing.expectEqual(App.Mode.normal, app.mode);
    try std.testing.expectEqual(tui_style.default_theme.body, tui_style.activePalette().body.fg.rgb);
    try std.testing.expect(app.theme_preview_original == null);
}

test "syncModeWithInput leading slash from theme_picker reverts before entering command" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    defer tui_style.setActive(tui_style.default_theme);

    app.mode = .theme_picker;
    app.theme_preview_original = tui_style.default_theme;
    theme_lifecycle.previewTheme(&app, tui_style.dracula);

    try app.syncModeWithInput("/");
    try std.testing.expectEqual(App.Mode.command, app.mode);
    try std.testing.expectEqual(tui_style.default_theme.body, tui_style.activePalette().body.fg.rgb);
    try std.testing.expect(app.theme_preview_original == null);
}

test "submitMode on theme_picker with no matching filter reverts the preview" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    defer tui_style.setActive(tui_style.default_theme);

    app.mode = .theme_picker;
    app.theme_preview_original = tui_style.default_theme;
    theme_lifecycle.previewTheme(&app, tui_style.dracula);
    try std.testing.expectEqual(tui_style.dracula.body, tui_style.activePalette().body.fg.rgb);
    // A filter with no matches → selection (0) >= count (0), so nothing to apply.
    try app.inputs.palette.buf.insertSliceAtCursor("zzzz");
    app.pickers.theme.selection = 0;

    try std.testing.expect(try app.submitMode());
    try std.testing.expectEqual(App.Mode.normal, app.mode);
    // The preview is reverted (M2): a non-commit exit must restore the look.
    try std.testing.expectEqual(tui_style.default_theme.body, tui_style.activePalette().body.fg.rgb);
    try std.testing.expect(app.theme_preview_original == null);
}

test "closeRuntimeBoundOverlays resets each runtime-bound mode with a notice" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // Session picker: sub-state + summaries cleared.
    app.mode = .session_picker;
    app.nav.session_action = .deleting;
    try std.testing.expect(closeRuntimeBoundOverlays(&app, "w1"));
    try std.testing.expectEqual(App.Mode.normal, app.mode);
    try std.testing.expectEqual(@import("app_state.zig").NavState.SessionAction.browsing, app.nav.session_action);
    try std.testing.expect(transcriptNoticeContains(&app, "parked"));

    // Provider picker form: borrowed handle dropped, back to list stage.
    app.mode = .provider_picker;
    app.pickers.provider.stage = .form;
    app.pickers.provider.form_handle = .{ .builtin = .openai };
    try std.testing.expect(closeRuntimeBoundOverlays(&app, "w1"));
    try std.testing.expectEqual(App.Mode.normal, app.mode);
    try std.testing.expectEqual(@import("widgets/provider_picker.zig").Stage.list, app.pickers.provider.stage);
    try std.testing.expect(app.pickers.provider.form_handle == null);

    // Model picker / tree picker / save message: plain close.
    for ([_]App.Mode{ .model_picker, .tree_picker, .save_message }) |m| {
        app.mode = m;
        try std.testing.expect(closeRuntimeBoundOverlays(&app, "w1"));
        try std.testing.expectEqual(App.Mode.normal, app.mode);
    }
}

test "closeRuntimeBoundOverlays leaves runtime-free modes open" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    inline for (.{ App.Mode.help, App.Mode.settings, App.Mode.search, App.Mode.command, App.Mode.lanes }) |m| {
        app.mode = m;
        try std.testing.expect(!closeRuntimeBoundOverlays(&app, "w1"));
        try std.testing.expectEqual(m, app.mode);
    }
}

test "submitMode keeps the session picker open on InFlightTurn" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // One selectable summary + a delivery turn running on the focused lane
    // (started from the tick while the picker was open).
    try app.resume_summaries.append(gpa, .{
        .id = try gpa.dupe(u8, "sess-1"),
        .title = null,
        .cwd = try gpa.dupe(u8, "/tmp"),
        .created_at_ms = 0,
        .updated_at_ms = 0,
        .leaf_entry_id = null,
        .model_provider = null,
        .model_id = null,
        .reasoning_effort = null,
    });
    // App.init leaves the primary lane idle in tests; make it live so the
    // submit-time idle-lane guard passes. The runtime is never dereferenced
    // on this path (switchToSession refuses on the active turn first).
    const runtime_mod = @import("../runtime.zig");
    var fake_runtime: runtime_mod.AgentRuntime = undefined;
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = &fake_runtime, .owns = false } };
    app.thread.turn.state = .active;
    app.mode = .session_picker;
    app.nav.session_action = .browsing;

    try std.testing.expect(try app.submitMode());

    // The picker (and its data) must survive the refusal so Enter can retry
    // once the turn finishes; the notice names the cause.
    try std.testing.expectEqual(App.Mode.session_picker, app.mode);
    try std.testing.expect(app.nav.session_action == .browsing);
    try std.testing.expectEqual(@as(usize, 1), app.resume_summaries.items.len);
    try std.testing.expect(transcriptNoticeContains(&app, "being delivered"));
}
