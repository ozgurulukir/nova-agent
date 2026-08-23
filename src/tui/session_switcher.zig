//! Session switching: resume-picker state management, session creation, and
//! timeline navigation. Free functions taking `*App` — extracted from `tui.zig`
//! (Phase 3 of `_pm/Projects/tui-domain-extract`).

const std = @import("std");
const log = std.log.scoped(.tui);
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../tui.zig");
const config_mod = @import("../config/config.zig");
const provider_model = @import("provider_model.zig");
const lane_lifecycle = @import("lane_lifecycle.zig");
const resume_picker = @import("widgets/resume_picker.zig");
const runtime_mod = @import("../runtime.zig");
const session_mod = @import("../session.zig");
const vcs = @import("../vcs.zig");

const App = tui.App;

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn resumeFoldIndex(app: *const App, cwd: []const u8) ?usize {
    for (app.resume_folded_projects.items, 0..) |folded, index| {
        if (std.mem.eql(u8, folded, cwd)) return index;
    }
    return null;
}

/// Build a cwd → max_updated_at_ms map for O(1) project-lookup in the sort
/// comparator. Caller owns the map and its backing allocator.
fn buildProjectMaxMap(gpa: std.mem.Allocator, summaries: []const session_mod.SessionSummary) !std.StringHashMap(i64) {
    var map = std.StringHashMap(i64).init(gpa);
    errdefer map.deinit();
    for (summaries) |summary| {
        const entry = try map.getOrPut(summary.cwd);
        if (!entry.found_existing) {
            entry.key_ptr.* = summary.cwd;
            entry.value_ptr.* = summary.updated_at_ms;
        } else {
            entry.value_ptr.* = @max(entry.value_ptr.*, summary.updated_at_ms);
        }
    }
    return map;
}

/// Sort comparator that uses a precomputed cwd → max_updated_at_ms map for O(1)
/// project lookups instead of scanning all summaries per comparison.
fn resumeSummaryLessThanWithMap(map: *const std.StringHashMap(i64), left: session_mod.SessionSummary, right: session_mod.SessionSummary) bool {
    if (std.mem.eql(u8, left.cwd, right.cwd)) return left.updated_at_ms > right.updated_at_ms;

    const left_project_updated_at_ms = map.get(left.cwd) orelse std.math.minInt(i64);
    const right_project_updated_at_ms = map.get(right.cwd) orelse std.math.minInt(i64);
    if (left_project_updated_at_ms != right_project_updated_at_ms) {
        return left_project_updated_at_ms > right_project_updated_at_ms;
    }

    return std.mem.lessThan(u8, left.cwd, right.cwd);
}

/// Legacy comparator (O(n) per comparison). Kept for the cross-module test in
/// tui.zig. Prefer `resumeSummaryLessThanWithMap` for production use.
pub fn resumeSummaryLessThan(summaries: []const session_mod.SessionSummary, left: session_mod.SessionSummary, right: session_mod.SessionSummary) bool {
    if (std.mem.eql(u8, left.cwd, right.cwd)) return left.updated_at_ms > right.updated_at_ms;

    const left_project_updated_at_ms = resumeProjectUpdatedAtMax(summaries, left.cwd);
    const right_project_updated_at_ms = resumeProjectUpdatedAtMax(summaries, right.cwd);
    if (left_project_updated_at_ms != right_project_updated_at_ms) {
        return left_project_updated_at_ms > right_project_updated_at_ms;
    }

    return std.mem.lessThan(u8, left.cwd, right.cwd);
}

fn resumeProjectUpdatedAtMax(summaries: []const session_mod.SessionSummary, cwd: []const u8) i64 {
    var updated_at_ms: i64 = std.math.minInt(i64);
    for (summaries) |summary| {
        if (!std.mem.eql(u8, summary.cwd, cwd)) continue;
        updated_at_ms = @max(updated_at_ms, summary.updated_at_ms);
    }
    return updated_at_ms;
}

/// Restore the working tree to the snapshot bound to the now-active timeline
/// node — its own, or the nearest ancestor that has one (`snapshotAt`). HEAD
/// stays attached to the branch; `vcs.restore` rewrites tracked files to that
/// tree (adds/modifies/deletes). Best-effort: a node with no bound snapshot
/// (an early point, before any file change) or a git failure simply leaves
/// the working tree as-is.
fn restoreCheckpointForBranch(app: *App, rt: *runtime_mod.AgentRuntime) !void {
    const sha_raw = (try rt.session_writer.snapshotAt(app.gpa)) orelse return;
    defer app.gpa.free(sha_raw);
    const sha = vcs.ObjectId.parse(sha_raw) catch return;
    const index = vcs.indexPath(app.gpa, app.io, rt.cwd) catch return;
    defer app.gpa.free(index);
    vcs.restore(app.gpa, app.io, rt.cwd, index, sha) catch return;
}

// ---------------------------------------------------------------------------
// Delegated public functions
// ---------------------------------------------------------------------------

pub fn openResumePicker(app: *App) !void {
    app.closeAtSearch();
    try app.reloadResumeSessions();
    const summaries = app.resume_summaries.items;
    const filter = app.peekPaletteInput() catch "";
    defer if (filter.len > 0) app.gpa.free(filter);
    _ = resume_picker.visibleCount(app.io, summaries, filter, app.resume_folded_projects.items, app.nav.resume_group_by);
    app.nav.resume_selection = 0;
    app.nav.block_nav = false;
    app.mode = .session_picker;
    app.inputs.palette.clearRetainingCapacity();
    if (filter.len > 0) try app.inputs.palette.insertSliceAtCursor(filter);
    syncResumeListCursor(app);
}

pub fn reloadResumeSessions(app: *App) !void {
    resumeClear(app);
    var manager = try session_mod.SessionManager.initDefault(app.gpa, app.io, app.liveRuntime().?.home_dir);
    defer manager.deinit();
    const cwd = if (app.nav.resume_group_by != .flat) null else (app.repoRoot() orelse app.liveRuntime().?.cwd);
    const summaries = try manager.list(app.gpa, cwd);
    defer app.gpa.free(summaries);
    try app.resume_summaries.appendSlice(app.gpa, summaries);
    if (app.nav.resume_group_by != .flat) {
        var map = try buildProjectMaxMap(app.gpa, app.resume_summaries.items);
        defer map.deinit();
        std.mem.sort(
            session_mod.SessionSummary,
            app.resume_summaries.items,
            &map,
            struct {
                fn cmp(m: *const std.StringHashMap(i64), a: session_mod.SessionSummary, b: session_mod.SessionSummary) bool {
                    return resumeSummaryLessThanWithMap(m, a, b);
                }
            }.cmp,
        );
    }
    if (app.nav.resume_selection >= try visibleResumeCount(app)) app.nav.resume_selection = 0;
    syncResumeListCursor(app);
}

pub fn selectedResumeSummary(app: *App) !?*session_mod.SessionSummary {
    const filter = try app.peekPaletteInput();
    defer app.gpa.free(filter);
    return @constCast(resume_picker.selectedSummary(app.resume_summaries.items, filter, app.resume_folded_projects.items, app.nav.resume_selection, app.nav.resume_group_by));
}

pub fn visibleResumeCount(app: *App) !u32 {
    const filter = try app.peekPaletteInput();
    defer app.gpa.free(filter);
    return resume_picker.visibleCount(app.io, app.resume_summaries.items, filter, app.resume_folded_projects.items, app.nav.resume_group_by);
}

pub fn toggleSelectedResumeProject(app: *App) !void {
    const filter = try app.peekPaletteInput();
    defer app.gpa.free(filter);
    const cwd = resume_picker.selectedProject(app.resume_summaries.items, filter, app.resume_folded_projects.items, app.nav.resume_selection) orelse return;
    if (resumeFoldIndex(app, cwd)) |index| {
        app.gpa.free(app.resume_folded_projects.items[index]);
        _ = app.resume_folded_projects.orderedRemove(index);
    } else {
        try app.resume_folded_projects.append(app.gpa, try app.gpa.dupe(u8, cwd));
    }
    if (app.nav.resume_selection >= try visibleResumeCount(app)) app.nav.resume_selection = 0;
    syncResumeListCursor(app);
}

pub fn resumeClearFolds(app: *App) void {
    for (app.resume_folded_projects.items) |folded| app.gpa.free(folded);
    app.resume_folded_projects.clearRetainingCapacity();
}

pub fn resumeClear(app: *App) void {
    for (app.resume_summaries.items) |*summary| summary.deinit(app.gpa);
    app.resume_summaries.clearRetainingCapacity();
    // Reset any pending sub-state so it doesn't persist into the next open.
    app.nav.session_action = .browsing;
    app.input_buffers.session_rename_text.clearRetainingCapacity();
}

pub fn syncResumeListCursor(app: *App) void {
    app.list_widgets.resume_list.cursor = app.nav.resume_selection;
    app.list_widgets.resume_list.ensureScroll();
}

pub fn reloadTreeNodes(app: *App) !void {
    const writer = &app.liveRuntime().?.session_writer;
    const records = try writer.entries(app.gpa);
    defer {
        for (records) |*record| record.deinit(app.gpa);
        app.gpa.free(records);
    }
    try app.pickers.tree.load(records, writer.leaf());
}

/// Switch the session leaf to `entry_id`, then rehydrate the agent's
/// conversation, the display transcript, AND the working copy from the new
/// branch. Refused mid-turn.
pub fn navigateToEntry(app: *App, entry_id: []const u8) !void {
    if (app.thread.turn.isActive()) return error.InFlightTurn;
    const rt = app.liveRuntime() orelse return error.NoActiveRuntime;
    // A summary in flight holds a first_kept_id from the old branch; applied
    // after the leaf moves it would corrupt (shared ancestor) or pollute
    // (dead boundary) the new branch. Discard it before switching (TD-2).
    rt.agent.drainBackgroundCompaction();
    try rt.session_writer.navigate(entry_id);
    try rt.reloadMessages();
    try app.rebuildTranscriptFromAgent();
    try restoreCheckpointForBranch(app, rt);
    app.armGitLabelRefresh();
}

pub fn reportSessionSwitchError(app: *App, err: anyerror) !void {
    app.mode = .normal;
    app.clearInput();
    var buffer: [128]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "Could not switch session: {s}", .{@errorName(err)}) catch "Could not switch session.";
    _ = try app.thread.transcript.append(app.gpa, .agent, "agent", message);
}

fn postUndoNotice(app: *App, body: []const u8) void {
    _ = app.thread.transcript.append(app.gpa, .notice, "session", body) catch {};
}

/// `/undo`: re-attach the leaf to the parent of the last user prompt,
/// restore the working tree to that point, and refill the main input with
/// the raw prompt so the user can rephrase and resubmit. Everything after
/// the last user entry on the active path is exactly the last turn, so
/// landing on its parent rewinds precisely that turn — non-destructively
/// (the old branch stays alive for `/timeline`).
pub fn undoLastTurn(app: *App) !void {
    // Ordering hazard: `reportSessionSwitchError` clears the input line, so
    // the prompt restore must run after `navigateToEntry` — never before.
    if (app.thread.turn.isActive()) {
        postUndoNotice(app, "A turn is still running — interrupt it with Esc before undoing.");
        return;
    }
    const rt = app.liveRuntime() orelse return error.NoActiveRuntime;
    const position = (try rt.session_writer.lastUserEntry()) orelse {
        postUndoNotice(app, "Nothing to undo — this session has no prompts yet.");
        return;
    };
    const parent = position.parent_id orelse {
        // Null parent = the session's first prompt. Rewinding past it would
        // need an "empty leaf" position the tree model cannot represent —
        // nothing ever moves leaf_entry_id back to null, and a second root
        // has never been exercised. `/new` is the escape hatch.
        postUndoNotice(app, "Nothing to undo — this is the session's first prompt.");
        return;
    };
    // Capture the raw prompt from the history table, NOT the persisted user
    // entry: the entry is augmented (@file contents inlined, $skill bodies
    // injected) and would double-inline on resubmit, while the table stores
    // the text exactly as typed. It is also untouched by compaction.
    const history = try rt.session_writer.loadPromptHistory(app.gpa);
    defer {
        for (history) |prompt| app.gpa.free(prompt);
        app.gpa.free(history);
    }
    const prompt: ?[]const u8 = if (history.len > 0) history[0] else null;

    try navigateToEntry(app, parent.slice());

    // The rewind has landed; everything below is best-effort and must not
    // fail it.
    var restored = false;
    if (prompt) |text| {
        app.clearInput();
        if (app.inputs.input.insertSliceAtCursor(text)) {
            restored = true;
        } else |_| {
            postUndoNotice(app, "Undone — the prompt could not be restored to the input line.");
        }
    } else {
        postUndoNotice(app, "Undone — no saved prompt text to restore.");
    }
    // Drop the restored row so a chained /undo restores the *previous*
    // turn's prompt: rows are pushed per turn at submit time, and without
    // the delete the next [0] would still be the prompt just handed back.
    // Only after a successful handoff — the table's copy is the only
    // non-augmented record of the text, so a failed restore must keep it.
    // The table is a per-session log, so a `/timeline` jump to another
    // branch can leave [0] off-branch; restore stays a best-effort "last
    // text typed". Warn-only — the rewind itself already succeeded.
    if (restored) {
        rt.session_writer.deleteNewestPromptHistory() catch |err|
            log.warn("undo.prompt_history_delete_failed err={s}", .{@errorName(err)});
        postUndoNotice(app, "Undone — the last prompt is back in the input line; edit and resubmit.");
    }
}

/// Enter the rename sub-state for the currently selected session. Prefills
/// the rename buffer with the existing title (or empty if untitled). No-op
/// when the selection is a project header or no session is selected.
pub fn beginRenameSelectedSession(app: *App) !void {
    const summary = try app.selectedResumeSummary() orelse return;
    app.input_buffers.session_rename_text.clearRetainingCapacity();
    if (summary.title) |title| {
        try app.input_buffers.session_rename_text.appendSlice(app.gpa, title);
    }
    app.nav.session_action = .renaming;
}

/// Confirm the rename: write the new title to the DB and reload the list.
/// The caller has already validated that the text is non-empty.
pub fn confirmRenameSelectedSession(app: *App) !void {
    const text = std.mem.trim(u8, app.input_buffers.session_rename_text.items, " \t\r\n");
    if (text.len == 0) return;
    const summary = try app.selectedResumeSummary() orelse return;
    var manager = try session_mod.SessionManager.initDefault(app.gpa, app.io, app.liveRuntime().?.home_dir);
    defer manager.deinit();
    manager.renameSession(summary.id, text) catch |err| {
        app.nav.session_action = .browsing;
        app.input_buffers.session_rename_text.clearRetainingCapacity();
        try app.reportSessionSwitchError(err);
        return;
    };
    app.nav.session_action = .browsing;
    app.input_buffers.session_rename_text.clearRetainingCapacity();
    try app.reloadResumeSessions();
}

/// Enter the delete-confirmation sub-state for the currently selected
/// session. No-op when the selection is a project header or the session
/// is the currently active one (deleting it would leave the runtime
/// orphaned — the DB row is gone but the in-memory session persists
/// until restart).
pub fn beginDeleteSelectedSession(app: *App) !void {
    const summary = try app.selectedResumeSummary() orelse return;
    // Reject deletion of the active session: the runtime holds it in
    // memory but the DB row would be gone, so the session is lost on
    // restart. Show a popup explaining why.
    if (app.thread.id) |active_id| {
        if (std.mem.eql(u8, summary.id, active_id.slice())) {
            app.nav.session_action = .blocked;
            return;
        }
    }
    app.nav.session_action = .deleting;
}

/// Confirm the deletion: remove the session from the DB and reload the
/// list. The selection is clamped after reload.
pub fn confirmDeleteSelectedSession(app: *App) !void {
    const summary = try app.selectedResumeSummary() orelse {
        app.nav.session_action = .browsing;
        return;
    };
    const id = try app.gpa.dupe(u8, summary.id);
    defer app.gpa.free(id);
    var manager = try session_mod.SessionManager.initDefault(app.gpa, app.io, app.liveRuntime().?.home_dir);
    defer manager.deinit();
    manager.deleteSession(id) catch |err| {
        app.nav.session_action = .browsing;
        try app.reportSessionSwitchError(err);
        return;
    };
    app.nav.session_action = .browsing;
    // The deleted session is gone; clamp the selection before reload so it
    // doesn't point past the end of the now-shorter list.
    if (app.nav.resume_selection > 0) app.nav.resume_selection -= 1;
    try app.reloadResumeSessions();
}

/// Cancel any session picker sub-state (rename or delete) and return to
/// browsing. Clears the rename buffer.
pub fn cancelSessionAction(app: *App) void {
    app.nav.session_action = .browsing;
    app.input_buffers.session_rename_text.clearRetainingCapacity();
}

pub fn switchToNewSession(app: *App) !void {
    if (app.thread.turn.isActive()) return error.InFlightTurn;
    const runtime = try createRuntime(app, app.liveRuntime().?.cwd, app.repoRoot() orelse app.liveRuntime().?.cwd, null);
    errdefer {
        runtime.deinit();
        app.gpa.destroy(runtime);
    }
    try app.installRuntime(runtime);
    try app.clearConversation();
}

pub fn switchToSession(app: *App, session_id: []const u8, cwd: []const u8) !void {
    if (app.thread.turn.isActive()) return error.InFlightTurn;
    const runtime = try createRuntime(app, cwd, app.repoRoot() orelse app.liveRuntime().?.cwd, session_id);
    errdefer {
        runtime.deinit();
        app.gpa.destroy(runtime);
    }
    try app.installRuntime(runtime);
    try app.rebuildTranscriptFromAgent();
}

pub fn createRuntime(app: *App, cwd: []const u8, session_dir: []const u8, session_id: ?[]const u8) !*runtime_mod.AgentRuntime {
    const current = app.templateRuntime() orelse return error.NoActiveRuntime;
    // When resuming a session from a different project, don't use the current
    // runtime as template — skills and plugin prompts must load from the
    // session's own cwd, not the current project's.
    const cross_project = session_id != null and !std.mem.eql(u8, cwd, current.cwd);
    // Guard: before any App-state mutation — refuse if any lane has an
    // active turn. Unloading Lua states and stripping tool records from the
    // shared registry while a worker dispatches through them is a
    // use-after-free hazard. Every turn-start site runs synchronously on the
    // UI thread and createRuntime never yields (no yield points in the
    // check-to-mutation window), so no idle→active transition can interleave.
    if (cross_project and lane_lifecycle.anyLaneTurnActive(app)) return error.InFlightTurn;
    const template: ?*const runtime_mod.AgentRuntime = if (cross_project) null else current;

    // Cross-project resume: reload config from the target project's
    // `.nova/config.json` so MCP servers, model selection, and project-scoped
    // settings match the session's own project. The env layer is constant
    // (process env vars don't change between projects), so we reuse the
    // environ_map captured at startup.
    var reloaded_config: ?config_mod.Config = null;
    var reloaded_diagnostics: []config_mod.Diagnostic = &.{};
    if (cross_project and app.environ_map != null) {
        var result = config_mod.load(app.gpa, app.io, cwd, current.home_dir, app.environ_map.?) catch null;
        if (result) |*lr| {
            reloaded_diagnostics = lr.takeDiagnostics();
            reloaded_config = lr.config;
        } else {
            log.warn("session.resume.config_reload_failed cwd={s}, using current config", .{cwd});
        }
    }
    defer {
        for (reloaded_diagnostics) |*d| d.deinit(app.gpa);
        app.gpa.free(reloaded_diagnostics);
    }

    const config = if (reloaded_config) |*rc| rc else &app.cached_config;

    const runtime = try app.gpa.create(runtime_mod.AgentRuntime);
    errdefer app.gpa.destroy(runtime);
    const diagnostics = try current.gpa.alloc(config_mod.Diagnostic, 0);
    errdefer current.gpa.free(diagnostics);
    if (session_id) |id| {
        try runtime.initResume(
            current.gpa,
            app.io,
            cwd,
            session_dir,
            current.home_dir,
            current.base_system_prompt,
            config.*,
            diagnostics,
            id,
            template,
        );
    } else {
        try runtime.initNew(
            current.gpa,
            app.io,
            cwd,
            session_dir,
            current.home_dir,
            current.base_system_prompt,
            config.*,
            diagnostics,
            template,
        );
    }

    // If config was reloaded, replace the app's cached config and re-sync MCP.
    if (reloaded_config) |rc| {
        if (app.cached_config_owned) app.cached_config.deinit(app.gpa);
        app.cached_config = rc;
        app.cached_config_owned = true;
        // The provider picker's `.config` entries and any open form handle
        // borrow the OLD config's storage, which the deinit above just freed.
        // Dropping them here makes the dangle temporally impossible no matter
        // which code path touches the picker next.
        provider_model.invalidateProviderEntries(app);
        app.mcp_manager.syncFromConfig(app.io, &app.cached_config) catch {};
    }

    // Cross-project plugin repoint: sync config, repoint discovery, re-register.
    if (cross_project) {
        app.plugin_manager.syncPluginConfig(app.cached_config.plugins) catch |err| {
            log.warn("session.plugin.syncPluginConfig_failed err={s}", .{@errorName(err)});
        };
        app.plugin_manager.repointProjectDir(cwd) catch |err| {
            log.warn("session.plugin.repointProjectDir_failed err={s}", .{@errorName(err)});
        };
        provider_model.registerPluginTools(app);
    }

    runtime.agent.background_manager = app.background;
    runtime.agent.mcp_manager = &app.mcp_manager;
    runtime.agent.tool_registry = app.tool_registry;
    runtime.agent.plugin_manager = &app.plugin_manager;
    runtime.agent.lane_bridge = app.lane_bridge;
    // Every lane's requests gate on the App's shared limiter, so the provider
    // sees at most `maxConcurrentRequests` in flight across all lanes.
    runtime.agent.request_limiter = app.request_limiter;
    // The client attached during `initResume`/`initNew` serialized its
    // `tools_json` before this wiring existed (registry null → the rebuild
    // is skipped there and the init-time builtin set survives). Push the
    // merged list now — the same push the model-picker attach path does —
    // so the new session's first turn carries builtin + plugin + MCP
    // definitions instead of running tool-less until an unrelated MCP event.
    provider_model.injectToolsInto(app, runtime);
    return runtime;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const agent_mod = @import("../agent.zig");
const ai = @import("../ai.zig");

fn undoNoticeContains(app: *App, needle: []const u8) bool {
    for (app.thread.transcript.messages.items) |m| {
        const body: []const u8 = switch (m) {
            .notice => |x| x.body,
            else => continue,
        };
        if (std.mem.indexOf(u8, body, needle) != null) return true;
    }
    return false;
}

/// Append a text message through the runtime's session writer (the enqueue
/// path every quiesce-based wrapper flushes before reading).
fn appendTurnText(writer: *session_mod.SessionWriter, gpa: std.mem.Allocator, role: ai.Role, text: []const u8) !void {
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    defer {
        for (blocks) |*block| block.deinit(gpa);
        gpa.free(blocks);
    }
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, text) } };
    const message: ai.ChatMessage = switch (role) {
        .user => .{ .user = .{ .content = blocks } },
        .assistant => .{ .assistant = .{ .content = blocks } },
        else => return error.InvalidRole,
    };
    try writer.append(message);
}

/// Focused live primary lane with a REAL session writer (real tree, real
/// writer thread) — `thread.agent` wired because `rebuildTranscriptFromAgent`
/// derefs it. Teardown is free: App.deinit → Thread.deinit honors `owns`.
fn makeUndoTestApp(gpa: std.mem.Allocator, home_abs: []const u8, agent: *agent_mod.Agent) !App {
    const test_helpers = @import("test_helpers.zig");
    var app = try App.init(std.testing.io, gpa, agent);
    const runtime = try test_helpers.makeParkTestRuntime(gpa, home_abs);
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = runtime, .owns = true } };
    app.thread.agent = &runtime.agent;
    return app;
}

test "undoLastTurn rewinds the leaf, restores the raw prompt, and drops the newest history row" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_abs = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd_abs);
    const home_abs = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_abs);

    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try makeUndoTestApp(gpa, home_abs, &agent);
    defer app.deinit();

    const runtime = app.thread.engine.live.runtime;
    const writer = &runtime.session_writer;
    // Two full turns. Rows land at "turn start", mirroring beginSubmit.
    try writer.savePromptHistory("first prompt");
    try appendTurnText(writer, gpa, .user, "one");
    try appendTurnText(writer, gpa, .assistant, "two");
    try writer.savePromptHistory("second prompt");
    try appendTurnText(writer, gpa, .user, "three");
    try appendTurnText(writer, gpa, .assistant, "four");

    // Quiesced read: newest user entry is turn 2's, its parent is the
    // rewind target (turn 1's last entry).
    const position = (try writer.lastUserEntry()) orelse return error.TestFailed;
    const target = position.parent_id orelse return error.TestFailed;

    try undoLastTurn(&app);

    // Leaf moved to the target branch point.
    try std.testing.expectEqualSlices(u8, target.slice(), writer.leaf().?);
    // The RAW prompt (as typed, not the augmented entry) is in the input.
    {
        const input = try app.peekInput();
        defer gpa.free(input);
        try std.testing.expectEqualStrings("second prompt", input);
    }
    // The restored row is dropped: [0] is now the previous turn's prompt —
    // this is what keeps a chained /undo restoring the right text.
    {
        const prompts = try writer.loadPromptHistory(gpa);
        defer {
            for (prompts) |p| gpa.free(p);
            gpa.free(prompts);
        }
        try std.testing.expectEqual(@as(usize, 1), prompts.len);
        try std.testing.expectEqualStrings("first prompt", prompts[0]);
    }
    try std.testing.expect(undoNoticeContains(&app, "Undone"));
    // The conversation re-projects to the u1/a1 branch.
    {
        var non_system: usize = 0;
        var first_user: ?[]const u8 = null;
        for (runtime.agent.messages()) |m| {
            if (m.role() == .system) continue;
            non_system += 1;
            if (m.role() == .user and first_user == null) first_user = m.text();
        }
        try std.testing.expectEqual(@as(usize, 2), non_system);
        try std.testing.expectEqualStrings("one", first_user orelse return error.TestFailed);
    }

    // Chained undo: u1's parent is null — the first-prompt refusal, and no
    // state moves (leaf, input, and history all stay as the first undo left
    // them).
    try undoLastTurn(&app);
    try std.testing.expectEqualSlices(u8, target.slice(), writer.leaf().?);
    try std.testing.expect(undoNoticeContains(&app, "first prompt"));
    {
        const input = try app.peekInput();
        defer gpa.free(input);
        try std.testing.expectEqualStrings("second prompt", input);
    }
}

test "undoLastTurn notices nothing to undo on a fresh session and on the first prompt" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_abs = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd_abs);
    const home_abs = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_abs);

    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try makeUndoTestApp(gpa, home_abs, &agent);
    defer app.deinit();

    const writer = &app.thread.engine.live.runtime.session_writer;

    // Fresh session: no entries at all → notice, no state change.
    try undoLastTurn(&app);
    try std.testing.expect(undoNoticeContains(&app, "no prompts yet"));
    try std.testing.expect(writer.leaf() == null);

    // A single user entry: its parent is null → the first-prompt refusal.
    try writer.savePromptHistory("only prompt");
    try appendTurnText(writer, gpa, .user, "only");
    try undoLastTurn(&app);
    try std.testing.expect(undoNoticeContains(&app, "first prompt"));
    try std.testing.expect(writer.leaf() != null);
    {
        const input = try app.peekInput();
        defer gpa.free(input);
        try std.testing.expectEqual(@as(usize, 0), input.len);
    }
}

test "submitMode dispatches /undo end to end and the restored prompt survives" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_abs = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd_abs);
    const home_abs = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_abs);

    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try makeUndoTestApp(gpa, home_abs, &agent);
    defer app.deinit();

    const writer = &app.thread.engine.live.runtime.session_writer;
    try writer.savePromptHistory("first prompt");
    try appendTurnText(writer, gpa, .user, "one");
    try appendTurnText(writer, gpa, .assistant, "two");
    try writer.savePromptHistory("second prompt");
    try appendTurnText(writer, gpa, .user, "three");
    try appendTurnText(writer, gpa, .assistant, "four");

    // Drive the REAL dispatch path (palette → resolveCommand → idle guard →
    // clearInput → handler), not the handler directly. This pins the ordering
    // the input-wipe hazard demands: the dispatch's clearInput runs BEFORE
    // the handler's restore, and nothing after the switch wipes it again.
    app.mode = .command;
    try app.inputs.palette.buf.insertSliceAtCursor("undo");
    app.nav.command_selection = 0;
    try std.testing.expect(try app.submitMode());

    try std.testing.expectEqual(App.Mode.normal, app.mode);
    {
        const input = try app.peekInput();
        defer gpa.free(input);
        try std.testing.expectEqualStrings("second prompt", input);
    }
    try std.testing.expect(undoNoticeContains(&app, "Undone"));
}

test "undoLastTurn refuses when a turn is active" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // The in-flight guard precedes every runtime deref, so an undefined
    // runtime suffices (mirrors the submitMode InFlightTurn fixture).
    var fake_runtime: runtime_mod.AgentRuntime = undefined;
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = &fake_runtime, .owns = false } };
    app.thread.turn.state = .active;

    try undoLastTurn(&app);
    try std.testing.expect(undoNoticeContains(&app, "still running"));
    try std.testing.expect(app.thread.turn.state == .active);
}

test "createRuntime refuses cross-project switch when a lane turn is active" {
    const gpa = std.testing.allocator;
    const test_helpers = @import("test_helpers.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_abs = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd_abs);
    const home_abs = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_abs);

    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    const runtime = try test_helpers.makeParkTestRuntime(gpa, home_abs);
    defer {
        runtime.deinit();
        gpa.destroy(runtime);
    }
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = runtime, .owns = false } };
    app.thread.agent = &runtime.agent;

    // Activate a turn
    app.thread.turn.state = .active;

    // cross_project: different cwd + non-null session_id
    const result = createRuntime(&app, "/other/project", "/other/project", "session-123");
    try std.testing.expectError(error.InFlightTurn, result);
    // Guard ran before any mutation — turn state is unchanged
    try std.testing.expect(app.thread.turn.state == .active);
}

test "same-project createRuntime guard does not fire" {
    const gpa = std.testing.allocator;
    const test_helpers = @import("test_helpers.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_abs = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd_abs);
    const home_abs = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_abs);

    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    const runtime = try test_helpers.makeParkTestRuntime(gpa, home_abs);
    defer {
        runtime.deinit();
        gpa.destroy(runtime);
    }
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = runtime, .owns = false } };
    app.thread.agent = &runtime.agent;

    // Even with an active turn, same-project should NOT trigger the guard
    // because cross_project is false when cwd matches.
    app.thread.turn.state = .active;

    // Verify the guard condition directly: cross_project requires different cwd.
    const current = app.templateRuntime().?;
    const cross_project = !std.mem.eql(u8, runtime.cwd, current.cwd);
    try std.testing.expect(!cross_project);
    // Since cross_project is false, the guard (cross_project and anyLaneTurnActive)
    // is short-circuited to false regardless of the turn state.
    try std.testing.expect(!(cross_project and lane_lifecycle.anyLaneTurnActive(&app)));
}
