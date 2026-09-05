//! App lifecycle entrypoints — deinit and the periodic tick handler.
//!
//! Pulled out of `tui.zig` (R6.3 of `_pm/Projects/tui-split`) — free functions
//! taking `*App` so the two directions of the `App`/module boundary stay clean:
//! the function reads `App` fields and calls pub methods; `tui.zig` keeps a
//! one-line delegate so existing inline tests resolve via the struct.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../tui.zig");
const agent_mod = @import("../agent.zig");
const BoundedList = @import("bounded_list.zig").BoundedList;
const agent_worker = @import("agent_worker.zig");
const auth = @import("../auth/store.zig");
const blackhole = @import("../tui/blackhole.zig");
const provider_model = @import("provider_model.zig");
const registry_job = @import("registry_job.zig");
const diff_lifecycle = @import("diff_lifecycle.zig");
const diff_utils = @import("diff_utils.zig");
const compaction_lifecycle = @import("compaction_lifecycle.zig");
const lane_lifecycle = @import("lane_lifecycle.zig");
const toast = @import("toast.zig");
const vcs = @import("../vcs.zig");

const App = tui.App;
const RootWidget = tui.RootWidget;
const Thread = tui.Thread;
const max_threads = tui.max_threads;

/// Tear down every lane, background job, picker, cache, and input buffer.
/// Called once at clean exit (or when switching to a new `initRuntime` session).
pub fn deinitApp(self: *App) void {
    std.debug.assert(self.threads.len() > 0);
    std.debug.assert(self.threads.len() <= max_threads);

    // Stop all worker threads first; nothing below may dereference a live
    // worker while it is still running.
    deinitWorkersTop(self);

    // Shared services that other teardown steps may reference during cleanup.
    deinitSharedServices(self);

    // Heap-owned UI and lane state. Order mirrors init: search/inputs last,
    // lanes second-to-last, bridge/limiter absolute last.
    deinitOwnedState(self);

    self.* = undefined;
}

/// Cancel every lane's in-flight turn and naming operation.  Background lanes
/// may still be running, so cancelling their futures joins them before the App
/// goes away.
fn deinitWorkersTop(self: *App) void {
    for (self.threads.slice()) |lane| {
        if (lane.turn_future) |*future| {
            if (lane.worker_context) |*worker| worker.requestCancel();
            _ = future.cancel(self.io);
            lane.turn_future = null;
        }
        self.cancelLaneNaming(lane);
    }
}

/// Tear down background jobs, pickers, providers, managers, and the lane
/// bridge / request limiter.  Workers are already joined, so nothing here can
/// be blocked on a permit or a bridge response.
fn deinitSharedServices(self: *App) void {
    // Jobs hold a stable lane generation, so this is independent of
    // lane/agent teardown order.
    if (self.background) |manager| {
        manager.deinit();
        self.gpa.destroy(manager);
        self.background = null;
    }
    for (self.background_modal_state.pending.items) |*delivery| self.freeDelivery(delivery);
    self.background_modal_state.pending.deinit(self.gpa);

    provider_model.cancelModelLoad(self);
    registry_job.cancel(self);
    self.pickers.tree.deinit();
    self.pickers.search.deinit(self.gpa);
    self.pickers.models.deinit(self.gpa);
    self.cancelDiffRefresh();

    auth.freeApiKeyMap(self.gpa, &self.provider_state.api_keys);
    if (self.provider_state.modelsdev_registry) |*r| {
        r.deinit(self.gpa);
        self.provider_state.modelsdev_registry = null;
    }
    if (self.provider_state.entries_slice) |slice| {
        self.gpa.free(slice);
        self.provider_state.entries_slice = null;
    }

    self.mcp_manager.deinit(self.io);
    self.plugin_manager.deinit();
    self.tool_registry.deinit(self.gpa);
    self.gpa.destroy(self.tool_registry);
    self.theme_registry.deinit(self.gpa);
    if (self.cached_config_owned) {
        self.cached_config.deinit(self.gpa);
        self.cached_config_owned = false;
    }

    if (self.async_worktree_job) |job| {
        job.deinit();
        self.async_worktree_job = null;
    }

    // No worker is blocked on the bridge or holds a permit now.
    if (self.lane_bridge) |bridge| {
        self.gpa.destroy(bridge);
        self.lane_bridge = null;
    }
    if (self.request_limiter) |limiter| {
        self.gpa.destroy(limiter);
        self.request_limiter = null;
    }
}

/// Tear down per-lane owned data and UI input buffers.  Lanes are destroyed
/// after their dependent state (retired transcripts, resume lists, search
/// state) is freed.
fn deinitOwnedState(self: *App) void {
    self.closeAtSearch();
    self.clearLanesState();

    for (self.retired_transcripts.items) |*transcript| transcript.deinit(self.gpa);
    self.retired_transcripts.deinit(self.gpa);
    self.resumeClear();
    self.resumeClearFolds();
    // `resumeClear` only clears items (keeps capacity for the next open);
    // the backing array itself is freed here. Nothing populated the list in
    // tests before, so the missing deinit was latent.
    self.resume_summaries.deinit(self.gpa);
    self.resume_folded_projects.deinit(self.gpa);

    // Non-empty labels are always heap-allocated by `loadGitLabel`; the
    // empty default is a literal, so guard on length before freeing.
    if (self.metrics.git_label.len > 0) self.gpa.free(self.metrics.git_label);
    if (self.metrics.diff_cache()) |raw| self.gpa.free(raw);

    for (self.threads.slice()) |lane| {
        lane.deinit(self.gpa);
        self.gpa.destroy(lane);
    }
    std.debug.assert(self.threads.len() <= max_threads);
    self.threads.deinit();

    self.diff.deinit(self.gpa);
    self.inputs.input.deinit();
    self.inputs.palette.deinit();
    self.inputs.comment.deinit();

    self.input_buffers.provider_key.deinit(self.gpa);
    self.input_buffers.settings_text.deinit(self.gpa);
    self.input_buffers.mcp_url.deinit(self.gpa);
    self.input_buffers.session_rename_text.deinit(self.gpa);
}

/// Periodic frame-level tick: drain agent events, model loads, diff refreshes,
/// lanes naming, background completion, spinner animation, and the black-hole
/// intro. Re-schedules itself when work is still pending.
pub fn handleTick(root: *RootWidget, ctx: *vxfw.EventContext) !void {
    std.debug.assert(root.app.threads.len() > 0);
    std.debug.assert(root.app.threads.len() <= max_threads);

    // A lane switch changes the active branch, so arm a refresh. `thread` is a
    // pointer, so this is a cheap identity compare — no polling.
    if (root.app.git_label_thread != root.app.thread) {
        root.app.git_label_thread = root.app.thread;
        root.app.git_label_dirty = true;
    }

    // Keep the status-bar git branch in sync with the active branch. `git_label`
    // was only computed once at startup, so both a lane switch and an in-lane
    // `git checkout`/`git switch` (bash tool or external terminal) left the stale
    // branch shown until restart. Refresh is event-driven via `git_label_dirty`
    // (set on lane switch and on every tool call in `armGitLabelRefresh`), so
    // idle time costs zero `git` calls — no polling.
    if (root.app.git_label_dirty) {
        try refreshGitLabel(root.app);
        root.app.git_label_dirty = false;
    }

    // Lazy MCP connect: trigger once after the UI is responsive so startup
    // doesn't block on subprocess spawn / handshake / tool discovery.
    if (root.mcp_connect_pending) {
        root.mcp_connect_pending = false;
        provider_model.refreshMcpTools(root.app);
    }

    var visible_change = try drainAgentEvents(root, ctx);
    // Update the velocity EMA + context meter on the UI tick (lockless: the UI
    // thread is the sole writer; worker threads only append to the transcript
    // via the already-synchronized event queue). `streamed_bytes / 4` is the
    // chars/4 token estimate. `.awake` is CLOCK_MONOTONIC (`.monotonic` does
    // not exist in Zig 0.16).
    {
        const now_ns = std.Io.Timestamp.now(root.app.getIo(), .awake).nanoseconds;
        const alpha = root.app.cached_config.tui.velocity_smoothing_alpha;
        root.app.metrics.telemetry.updateVelocity(now_ns, root.app.metrics.streamed_bytes / 4, alpha);
        if (root.app.liveRuntime()) |rt| {
            root.app.metrics.context_tokens_used = rt.agent.currentContextTokens();
            root.app.metrics.context_tokens_max = rt.agent.context_window_tokens;
        }
    }
    visible_change = try drainToasts() or visible_change;
    visible_change = try drainModelsAndMcp(root) or visible_change;
    visible_change = try drainDiffAndCompactions(root) or visible_change;
    visible_change = try drainBackgroundAndLanes(root) or visible_change;

    try advanceAnimations(root, &visible_change);
    try scheduleDiffRefreshIfPending(root, ctx);
    advanceBlackholeIfVisible(root, &visible_change);

    if (decideShouldTick(root)) {
        try ctx.tick(RootWidget.drain_tick_ms, root.widget());
    } else {
        root.app.metrics.loading_tick_active = false;
    }

    if (visible_change) {
        ctx.consumeAndRedraw();
    } else {
        ctx.consumeEvent();
    }
}

/// Drain the toast bus (UI thread only). Returns true if any toast appeared or expired.
fn drainToasts() !bool {
    var toast_items: [toast.max_items]toast.Item = undefined;
    return toast.global.drain(&toast_items) > 0;
}

/// Service the lane bridge and drain model / MCP notification state.
fn drainModelsAndMcp(root: *RootWidget) !bool {
    // A blocked worker posts no agent events, so the bridge must be serviced
    // every tick to make it progress.
    lane_lifecycle.serviceLaneBridge(root.app);
    var visible_change = false;
    if (try provider_model.drainModelLoad(root.app)) visible_change = true;
    if (try registry_job.drain(root.app)) visible_change = true;
    if (provider_model.drainMcpNotifications(root.app)) visible_change = true;
    if (provider_model.drainMcpConnects(root.app)) visible_change = true;
    return visible_change;
}

/// Drain diff refresh, lane naming, and manual compaction state.
fn drainDiffAndCompactions(root: *RootWidget) !bool {
    var visible_change = false;
    if (try root.app.drainDiffRefresh()) visible_change = true;
    if (try root.app.drainLaneNaming()) visible_change = true;
    if (try compaction_lifecycle.drainManualCompactions(root.app)) visible_change = true;
    return visible_change;
}

/// Poll background jobs and deliver buffered completions to lanes / spawners.
fn drainBackgroundAndLanes(root: *RootWidget) !bool {
    var visible_change = false;
    if (try root.app.pollBackgroundJobs()) visible_change = true;
    if (try root.app.deliverPendingBackground()) visible_change = true;
    if (try lane_lifecycle.deliverPendingLaneCompletions(root.app)) visible_change = true;
    return visible_change;
}

/// Advance spinner frames when a turn or manual compaction is active.
fn advanceAnimations(root: *RootWidget, visible_change: *bool) !void {
    const spinner_active = root.app.anyTurnActive() or
        compaction_lifecycle.manualCompactActive(root.app) or
        lane_lifecycle.anyAsyncWorktreeActive(root.app);
    if (spinner_active) {
        root.spinner_tick_accum += RootWidget.drain_tick_ms;
        if (root.spinner_tick_accum >= RootWidget.spinner_tick_threshold_ms) {
            root.spinner_tick_accum = 0;
            root.app.advanceLoadingFrame();
            visible_change.* = true;
        }
    } else {
        root.spinner_tick_accum = 0;
    }
}

/// If a diff refresh was requested, schedule it once the debounce threshold passes.
fn scheduleDiffRefreshIfPending(root: *RootWidget, ctx: *vxfw.EventContext) !void {
    if (root.diff_refresh_pending) {
        root.diff_tick_accum += RootWidget.drain_tick_ms;
        if (root.diff_tick_accum >= RootWidget.diff_tick_threshold_ms) {
            root.diff_tick_accum = 0;
            root.diff_refresh_pending = false;
            try root.app.scheduleDiffRefresh();
            try ensureTick(root, ctx);
        }
    } else {
        root.diff_tick_accum = 0;
    }
}

/// Advance the black-hole intro animation when it is visible.
fn advanceBlackholeIfVisible(root: *RootWidget, visible_change: *bool) void {
    if (root.app.metrics.blackhole_visible) {
        // Carry the remainder so the average interval tracks ~24 fps even
        // though the host tick (30 ms) is coarser than the frame interval.
        root.blackhole_tick_accum += RootWidget.drain_tick_ms;
        while (root.blackhole_tick_accum >= blackhole.frame_interval_ms) {
            root.blackhole_tick_accum -= blackhole.frame_interval_ms;
            root.app.advanceBlackholeFrame();
            visible_change.* = true;
        }
    } else {
        root.blackhole_tick_accum = 0;
    }
}

/// Decide whether another tick should be scheduled.  Each named variable
/// corresponds to one logical reason for continued polling.
fn decideShouldTick(root: *RootWidget) bool {
    const turn_active = root.app.anyTurnActive();
    const model_loading = root.app.pickers.models.load == .loading;
    const diff_loading = root.app.metrics.diff_loading();
    const blackhole_visible = root.app.metrics.blackhole_visible;
    const diff_refresh_pending = root.diff_refresh_pending;
    const background_active = root.app.backgroundActive();
    const naming_active = root.app.namingActive();
    const mcp_connect_pending = root.app.mcp_manager.hasPendingConnects();
    const manual_compact_active = compaction_lifecycle.manualCompactActive(root.app);
    const toasts_visible = toast.global.hasToasts();
    const worktree_async_active = lane_lifecycle.anyAsyncWorktreeActive(root.app);
    const registry_refresh_active = registry_job.active(root.app);

    return turn_active or
        model_loading or
        diff_loading or
        blackhole_visible or
        diff_refresh_pending or
        background_active or
        naming_active or
        mcp_connect_pending or
        manual_compact_active or
        toasts_visible or
        worktree_async_active or
        registry_refresh_active;
}

/// Per-lane byte budget for drain-to-empty: events applied beyond this budget
/// wait for the next tick. Only `response_delta`/`thinking_delta` payload lengths
/// count toward this budget (they are the hot path); `tool_call_finished`,
/// `delta_end`, and `tool_delta` are infrequent and small and do not count.
const drain_byte_budget: usize = 64 * 1024;

/// Drain all agent events queued on every lane's worker and project them onto
/// the relevant lane's thread state. Returns true when any visible state changed.
fn drainAgentEvents(root: *RootWidget, ctx: *vxfw.EventContext) !bool {
    var visible_change = false;
    var refresh_diff = false;
    const active = root.app.thread;
    // Each lane runs its own turn, so drain every lane's queue and apply its
    // events to *that* lane. The Turn machine operates on `self.thread`, so
    // scope-swap it to the lane being processed (UI-thread only) and restore
    // the visible lane afterward.
    for (root.app.threads.slice()) |lane| {
        const worker = if (lane.worker_context) |*wc| wc else continue;
        std.debug.assert(lane.agent != null);

        // Per-lane drain-to-empty loop: drain a bounded batch, process it,
        // then re-drain until the queue is empty or the byte budget is hit.
        // This lets a fast burst catch up in one tick rather than trickling
        // across frames.
        root.app.thread = lane;
        defer root.app.thread = active;
        var lane_bytes: usize = 0;
        while (true) {
            var batch: BoundedList(*agent_mod.Agent.Event, agent_worker.event_batch_max) = .{};
            try worker.queue.drainIntoBounded(worker.io, &batch);
            if (batch.len() == 0) break;

            for (batch.slice()) |event_ptr| {
                defer worker.gpa.destroy(event_ptr);
                defer event_ptr.deinit(worker.gpa);

                // Count applied content bytes toward this lane's budget before
                // the visibility gate so background lanes also respect it.
                switch (event_ptr.*) {
                    .response_delta, .thinking_delta => |text| lane_bytes += text.len,
                    else => {},
                }

                // Accumulate the ACTIVE lane's response-delta and thinking-delta
                // bytes for the velocity gauge. The active lane is the one the
                // user watches, so only it feeds the gauge. The gauge is fed
                // `streamed_bytes / 4` (chars/4 estimate) on the tick.
                if (lane == active) {
                    switch (event_ptr.*) {
                        .response_delta => |text| root.app.metrics.streamed_bytes += text.len,
                        .thinking_delta => |text| root.app.metrics.streamed_bytes += text.len,
                        else => {},
                    }
                }

                // A discarded (interrupted) turn's events are swallowed inside
                // applyAgentEvent — the Turn machine refuses to project them.
                const changed = try root.app.applyAgentEvent(event_ptr.*);
                if (lane != active) continue; // a background lane never touches the view
                if (changed) visible_change = true;
                switch (event_ptr.*) {
                    .tool_call_finished => {
                        refresh_diff = true;
                        armGitLabelRefresh(root.app);
                    },
                    else => {},
                }
                if (lane.turn_view.awaitingOutput()) try ensureTick(root, ctx);
            }

            if (lane_bytes >= drain_byte_budget) break;
        }
    }
    // Reset the velocity accumulator once the active lane's turn is no longer
    // generating text or reasoning (turn end / new turn / tool call), so the
    // next turn's delta is computed from a clean base and the `-|` underflow
    // guard in updateVelocity sees a clean reset.
    const is_generating = switch (active.turn_view.activity) {
        .writing_response, .thinking => true,
        else => false,
    };
    if (!is_generating) {
        root.app.metrics.streamed_bytes = 0;
    }
    if (refresh_diff) {
        root.diff_refresh_pending = true;
    }
    return visible_change;
}

/// Fork a parallel lane: create a git worktree, new runtime, and a fresh
/// Thread. Max 4 threads total — the driver's main lane + 3 lanes (2×2 grid).
/// Called from the command palette (/parallel) and from `App.submitMode`
/// (command palette dispatch).
pub fn createParallelLane(self: *App) !void {
    std.debug.assert(self.threads.len() > 0);
    std.debug.assert(self.threads.len() <= max_threads);
    if (self.threads.len() >= max_threads) return error.TooManyLanes; // driver + 3 lanes, not 4 extra
    const repo = self.repoRoot() orelse return error.NoActiveRuntime;
    const home = (self.liveRuntime() orelse return error.NoActiveRuntime).home_dir;
    if (!vcs.isRepo(self.gpa, self.io, repo)) return error.NotAGitRepo;

    // Recent parent-lane messages give the branch-naming request context
    // for vague first prompts ("try the other approach").
    const context = try self.captureLaneContext(tui.lane_naming_context_max);
    errdefer {
        for (context) |message| self.gpa.free(message);
        if (context.len > 0) self.gpa.free(context);
    }

    var raw: [6]u8 = undefined;
    self.io.random(&raw);
    const id = std.fmt.bytesToHex(raw, .lower);

    const branch = try self.gpa.alloc(u8, "nova/".len + id.len);
    errdefer self.gpa.free(branch);
    @memcpy(branch[0.."nova/".len], "nova/");
    @memcpy(branch["nova/".len..], &id);

    // Worktrees live under the global `<home>/.config/nova/worktrees`, OUTSIDE the
    // repo, so `git add -A`/snapshots/`/save` never see them.
    const parent = try vcs.globalWorktreesDir(self.gpa, home);
    defer self.gpa.free(parent);
    std.Io.Dir.cwd().createDirPath(self.io, parent) catch {};
    const dest = try std.fs.path.join(self.gpa, &.{ parent, id[0..] });
    errdefer self.gpa.free(dest);

    try vcs.worktreeAdd(self.gpa, self.io, repo, dest, branch);
    errdefer vcs.worktreeRemove(self.gpa, self.io, repo, dest) catch {};

    const runtime = try self.createRuntime(dest, repo, null);
    errdefer {
        runtime.deinit();
        self.gpa.destroy(runtime);
    }
    // A lane's agent needs the App's shared handles (the lane bridge among
    // them) so its own `lane` tool calls can reach the bridge. Mirrors the
    // wiring in `createRuntime` for the primary/new/resume runtimes.
    runtime.agent.lane_bridge = self.lane_bridge;
    // A forked lane worker is root-contained: its bash tool refuses `cd` out
    // of the worktree (L2), keeping its writes out of the main tree.
    runtime.agent.contained = true;

    const lane = try self.gpa.create(Thread);
    errdefer self.gpa.destroy(lane);
    lane.* = Thread.initLive(
        runtime.session_writer.session.id,
        &runtime.agent,
        self.io,
        runtime.gpa,
        context,
        branch,
        dest,
        runtime,
    );
    _ = self.assignLaneGeneration(lane);
    try self.threads.append(lane);
    std.debug.assert(self.threads.len() <= max_threads);

    // Committed: `threads` owns `lane`, which owns `runtime`/`branch`/`dest`.
    // In `.dual` the driver (lane 0) is always the left pane and input routing
    // stays with it — moving `app.thread` to the new worker would route input
    // to a lane no pane displays. Instead, reveal the new lane in the right
    // pane by pointing `focused_worker_index` at it. In `.grid`/`.tab` the new
    // lane becomes the active one as before.
    self.split_mode = self.cached_config.tui.split_mode;
    if (self.split_mode == .dual) {
        self.thread = self.threads.slice()[0];
        self.focused_worker_index = self.threads.len() - 1; // the new lane's index
    } else {
        self.thread = lane;
    }
    self.mode = .normal;
    self.clearInput();
    self.resetTurnState();
}

/// Route keys while the user is browsing the `/diff` viewer body. Returns
/// without consuming when a key targets the search popup or the comment editor
/// (their own routers handle those).
pub fn handleDiffBrowseKey(root: *RootWidget, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
    const app = root.app;
    std.debug.assert(app.mode == .diff_viewer);
    // Esc / Ctrl+C exit cleanly (comments discarded); Ctrl+S exits and sends.
    if (key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
        try closeDiff(root, ctx, false);
        return;
    }
    if (key.matches('s', .{ .ctrl = true })) {
        try closeDiff(root, ctx, true);
        return;
    }
    // Nothing to navigate or comment on while the diff is still loading (or
    // genuinely empty) — swallow everything except the exit keys above.
    if (app.diff.lines.items.len == 0) {
        ctx.consumeEvent();
        return;
    }
    if (key.matches('w', .{ .ctrl = true })) {
        // Edit the comment on the exact selected range if one exists, else new.
        const prefill = app.diff.beginComment();
        app.inputs.comment.clearRetainingCapacity();
        if (prefill.len > 0) try app.inputs.comment.insertSliceAtCursor(prefill);
        try syncFocus(root, ctx);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('e', .{ .ctrl = true })) {
        if (app.diff.editActiveComment()) |prefill| {
            app.inputs.comment.clearRetainingCapacity();
            if (prefill.len > 0) try app.inputs.comment.insertSliceAtCursor(prefill);
            try syncFocus(root, ctx);
            ctx.consumeAndRedraw();
            return;
        }
        ctx.consumeEvent();
        return;
    }
    if (key.matches('d', .{ .ctrl = true })) {
        if (app.diff.deleteActiveComment(app.gpa)) ctx.consumeAndRedraw() else ctx.consumeEvent();
        return;
    }
    if (key.matches('p', .{ .ctrl = true })) {
        app.diff.sub = .file_search;
        app.diff.search_sel = 0;
        app.clearPaletteInput();
        try app.diff.filterFiles(app.gpa, "");
        try syncFocus(root, ctx);
        ctx.consumeAndRedraw();
        return;
    }
    // File jumps via Ctrl+↑/↓ (Ctrl+Shift+arrows aren't reported reliably).
    if (key.matches(vaxis.Key.up, .{ .ctrl = true })) {
        app.diff.jumpFile(-1);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.down, .{ .ctrl = true })) {
        app.diff.jumpFile(1);
        ctx.consumeAndRedraw();
        return;
    }
    // Hunk-level jumps: `[` / `]` walk the `@@` markers within and across files.
    if (key.matches('[', .{})) {
        app.diff.jumpHunk(-1);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(']', .{})) {
        app.diff.jumpHunk(1);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.up, .{ .shift = true })) {
        app.diff.extendSelection(-1);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.down, .{ .shift = true })) {
        app.diff.extendSelection(1);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.up, .{})) {
        app.diff.moveCursor(-1);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.down, .{})) {
        app.diff.moveCursor(1);
        ctx.consumeAndRedraw();
        return;
    }
    const page: i32 = @intCast(@max(@as(u16, 1), app.diff.viewport_rows));
    if (key.matches(vaxis.Key.page_up, .{})) {
        app.diff.moveCursor(-page);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.page_down, .{})) {
        app.diff.moveCursor(page);
        ctx.consumeAndRedraw();
        return;
    }
    // Swallow anything else so stray keys don't leak to a focused widget.
    ctx.consumeEvent();
}

/// Close the `/diff` viewer, optionally saving any pending comments.
/// When saved comments exist, begins a turn so the agent sees them.
pub fn closeDiff(root: *RootWidget, ctx: *vxfw.EventContext, send: bool) !void {
    const has_comments = try diff_lifecycle.closeDiffViewer(root.app, send);
    try syncFocus(root, ctx);
    if (has_comments) {
        if (try root.app.beginSubmit()) try root.app.startTurn();
        try ensureTick(root, ctx);
    }
    ctx.consumeAndRedraw();
}

/// Route keys while the `/diff` file-search popup is open. Esc/Enter exit
/// the search (Enter jumps to the selected file); ↑↓ scroll the match list.
/// Typed text / backspace bubble to the focused palette input.
pub fn handleDiffSearchKey(root: *RootWidget, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
    const app = root.app;
    if (key.matches(vaxis.Key.escape, .{})) {
        app.diff.sub = .browse;
        try syncFocus(root, ctx);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        const matches = app.diff.search_matches.items;
        if (matches.len > 0) app.diff.jumpToFile(matches[@min(app.diff.search_sel, matches.len - 1)]);
        app.diff.sub = .browse;
        try syncFocus(root, ctx);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.up, .{})) {
        app.diff.search_sel = tui.previousIndex(app.diff.search_sel, @intCast(app.diff.search_matches.items.len));
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches(vaxis.Key.down, .{})) {
        app.diff.search_sel = tui.nextIndex(app.diff.search_sel, @intCast(app.diff.search_matches.items.len));
        ctx.consumeAndRedraw();
        return;
    }
    // Typed text / backspace bubbles to the focused palette input; its
    // onChange (paletteInputChanged) refilters the match list.
}

/// Route keys while the `/diff` comment editor is focused. Esc discards the
/// draft and returns to browse mode; Ctrl+S / Enter saves the comment.
pub fn handleDiffCommentKey(root: *RootWidget, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
    const app = root.app;
    if (key.matches(vaxis.Key.escape, .{})) {
        app.diff.sub = .browse;
        app.diff.sel_anchor = null;
        app.inputs.comment.clearRetainingCapacity();
        try syncFocus(root, ctx);
        ctx.consumeAndRedraw();
        return;
    }
    if (key.matches('s', .{ .ctrl = true }) or key.matches(vaxis.Key.enter, .{})) {
        const draft = try app.peekCommentInput();
        defer app.gpa.free(draft);
        _ = try app.diff.saveComment(app.gpa, draft);
        app.inputs.comment.clearRetainingCapacity();
        try syncFocus(root, ctx);
        ctx.consumeAndRedraw();
        return;
    }
    // Typed text / backspace handled by the focused comment input.
}

/// Pin vxfw focus to the root widget before destroying a runtime. The focused
/// TextField's userdata can point into the dying runtime's memory; once it is
/// deinit'd, FocusHandler.update can no longer find it in the surface tree,
/// leaves the focus path empty, and the next key event crashes (vendored
/// App.zig:594, locally patched as NOVA-LOCAL-PATCH). Root is always drawn and
/// runtime-independent, so pinning here is safe. Best-effort: tests have no
/// framework handle wired.
pub fn pinFocusToRoot(app: *App) void {
    if (app.fw_app) |fw| {
        if (app.root_widget) |root| fw.wants_focus = root;
    }
}

/// Re-target focus to the main prompt input after a teardown + overlay close.
/// The input is App-owned (stable across runtimes) and drawn in `.normal`.
pub fn focusPrimaryInput(app: *App) void {
    if (app.fw_app) |fw| fw.wants_focus = app.inputs.input.widget();
}

/// Route focus to the correct widget for the current mode. The provider
/// setup form keeps focus on root (it draws its own editor); the diff
/// viewer routes by sub-state (comment editor / file search / browse).
pub fn syncFocus(root: *RootWidget, ctx: *vxfw.EventContext) !void {
    const app = root.app;
    // The provider setup form draws its own inline editor and intentionally
    // omits the overlay search field. Focusing the (undrawn) palette input
    // would leave the focus path empty and panic on the next event, so keep
    // focus on the root widget — it owns key handling via captureEvent anyway.
    if (app.mode == .provider_picker and app.pickers.provider.stage == .form) {
        try ctx.requestFocus(root.widget());
        return;
    }
    const target = switch (app.mode) {
        .command, .provider_picker, .model_picker, .tree_picker, .save_message, .search, .theme_picker => app.inputs.palette.widget(),
        // The session picker uses the palette input for filtering while
        // browsing, but sub-states (rename/delete) handle keys via the
        // command router — focus stays on root so the palette input
        // doesn't swallow printable keys meant for the rename buffer.
        .session_picker => switch (app.nav.session_action) {
            .browsing => app.inputs.palette.widget(),
            .renaming, .deleting, .blocked => root.widget(),
        },
        // The diff viewer routes focus by sub-state: the comment editor and
        // the file-search field each host a drawn TextField; while browsing
        // the root widget owns every key.
        .diff_viewer => switch (app.diff.sub) {
            .commenting => app.inputs.comment.widget(),
            .file_search => app.inputs.palette.widget(),
            .browse => root.widget(),
        },
        // The lanes overlay owns its keys via captureEvent; the palette input
        // is unused, so keep focus on the root (typed keys are ignored).
        .lanes, .help, .settings, .mcp, .plugins => root.widget(),
        .normal => app.inputs.input.widget(),
    };
    try ctx.requestFocus(target);
}

/// Schedule the shared animation/drain tick if one isn't already pending.
/// Drives the spinner, agent-event draining, and the black-hole intro.
pub fn ensureTick(root: *RootWidget, ctx: *vxfw.EventContext) !void {
    if (root.app.metrics.loading_tick_active) return;
    root.app.metrics.loading_tick_active = true;
    root.spinner_tick_accum = 0;
    try ctx.tick(RootWidget.drain_tick_ms, root.widget());
}

/// Submit the current input: enter closes a picker, command runs the
/// selected action, and normal mode starts a turn with the input text.
pub fn submit(root: *RootWidget, ctx: *vxfw.EventContext) !void {
    if (try root.app.submitMode()) {
        try syncFocus(root, ctx);
        // Keep the tick alive to drain an async model load or diff refresh
        // (e.g. the cold-start "Loading diff…" the /diff command kicked off),
        // or a turn a command started directly (e.g. /sync conflict
        // resolution injects one).
        if (root.app.thread.turn.isActive() or root.app.pickers.models.load == .loading or root.app.metrics.diff_loading() or root.app.mcp_manager.hasPendingConnects() or compaction_lifecycle.manualCompactActive(root.app)) try ensureTick(root, ctx);
        ctx.consumeAndRedraw();
        return;
    }
    if (!try root.app.beginSubmit()) return;
    try root.app.startTurn();
    try ensureTick(root, ctx);
    ctx.consumeAndRedraw();
}

/// Dispatch key events to the per-sub-mode diff viewer handlers.
pub fn handleDiffViewerEvent(root: *RootWidget, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
    switch (root.app.diff.sub) {
        .browse => try handleDiffBrowseKey(root, ctx, key),
        .file_search => try handleDiffSearchKey(root, ctx, key),
        .commenting => try handleDiffCommentKey(root, ctx, key),
    }
}

/// Mark the status-bar git branch label for refresh on the next tick. Called
/// when the active branch may have changed: a lane switch (any `app.thread`
/// reassignment) or any tool call that could have run `git` (e.g. the bash
/// tool). Event-driven — `handleTick` refreshes once and clears the flag, so
/// idle time costs zero `git` calls.
pub fn armGitLabelRefresh(app: *App) void {
    app.git_label_dirty = true;
}

/// Recompute `metrics.git_label` from the active lane's working directory.
/// Only called when `git_label_dirty` is set (see `armGitLabelRefresh`), so it
/// never polls. Skips the realloc when the freshly computed label equals the
/// current `metrics.git_label`.
pub fn refreshGitLabel(app: *App) !void {
    // A live lane (including the primary) roots its tools at `runtime.cwd`; an
    // idle worktree lane carries its path on `engine.idle`. `.primary` has no
    // worktree path, but its live runtime's cwd already points at the repo root.
    // Both live branches are covered first; only an idle worktree lane falls
    // through to `engine.idle.workingPath()` (primary is never idle).
    const cwd: []const u8 = if (app.liveRuntime()) |rt|
        rt.cwd
    else if (app.thread.engine.idle.workingPath()) |p|
        p
    else
        "";
    // No usable worktree path (e.g. an idle primary in a headless/test App) —
    // leave the existing label untouched rather than invoking git with "".
    if (cwd.len == 0) return;
    const new_label = diff_utils.loadGitLabel(app.gpa, app.getIo(), cwd) catch "";

    // Branch unchanged: free the freshly allocated equal string and keep the
    // current copy. Avoids redundant reallocation when a tool call didn't touch
    // the branch.
    if (std.mem.eql(u8, new_label, app.metrics.git_label)) {
        if (new_label.len > 0) app.gpa.free(new_label);
        return;
    }
    if (app.metrics.git_label.len > 0) app.gpa.free(app.metrics.git_label);
    app.metrics.git_label = new_label;
}
