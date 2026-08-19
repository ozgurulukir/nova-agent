//! Turn lifecycle and submission logic.
//! Free functions taking `*App` — extracted from `tui.zig`.

const std = @import("std");
const tui = @import("../tui.zig");
const agent_mod = @import("../agent.zig");
const agent_worker = @import("agent_worker.zig");
const lanes_util = @import("lanes.zig");
const runtime_mod = @import("../runtime.zig");

const App = tui.App;
const Thread = tui.Thread;

pub fn handleInterrupt(app: *App) !void {
    if (app.thread.turn.state != .active) return;
    app.thread.worker_context.?.requestCancel();
    // Show the cancellation notice immediately.
    const message = try app.gpa.dupe(u8, agent_worker.cancel_message);
    var event: agent_mod.Agent.Event = .{ .turn_failed = message };
    defer event.deinit(app.gpa);
    _ = try app.thread.turn_view.apply(app.gpa, &app.thread.transcript, event);
    // Record the interrupt as a failure so a spawned worker's completion
    // delivery reports it honestly ("FAILED — Interrupted.") instead of
    // "final state: done". The event's copy is freed by `event.deinit`; this
    // is a second dupe owned by `turn_failed`. If the user queued messages,
    // `restartTurnForQueuedMessages` starts a fresh turn whose `resetTurnState`
    // clears it — correct, a new turn is running.
    if (app.thread.turn_failed) |old| app.gpa.free(old);
    app.thread.turn_failed = app.gpa.dupe(u8, agent_worker.cancel_message) catch null;
    app.thread.turn.interrupt();
    // Tear the worker down now rather than waiting for it to reach its next
    // cooperative cancellation point. `requestCancel` only takes effect on
    // the worker's next `emit`, but between stream chunks (and for the whole
    // duration of a running tool) the worker is blocked in a read and emits
    // nothing — so a purely cooperative cancel would leave the lane stuck
    // `interrupting`, i.e. reading as still in-flight long after Esc.
    // `cancel` aborts that read and joins the worker; we then drop back to
    // idle and deliver anything the user queued behind the cancelled turn.
    discardAbandonedTurn(app);
    _ = try restartTurnForQueuedMessages(app);
}

pub fn discardAbandonedTurn(app: *App) void {
    if (app.thread.turn.state != .interrupting and app.thread.turn_future == null) return;
    if (app.thread.turn_future) |*future| {
        // `cancel` blocks until the task hits its next cancellation point
        // (typically the network read) and unwinds. On a healthy stream
        // this is near-instant; on a hung connection it forces the OS
        // read to abort.
        _ = future.cancel(app.getIo());
        app.thread.turn_future = null;
    }
    var batch: std.ArrayList(*agent_mod.Agent.Event) = .empty;
    defer batch.deinit(app.thread.worker_context.?.gpa);
    app.thread.worker_context.?.queue.drainInto(
        app.thread.worker_context.?.io,
        app.thread.worker_context.?.gpa,
        &batch,
    ) catch {};
    for (batch.items) |event_ptr| {
        event_ptr.deinit(app.thread.worker_context.?.gpa);
        app.thread.worker_context.?.gpa.destroy(event_ptr);
    }
    if (app.thread.turn.state == .interrupting) app.thread.turn.reset();
}

/// Start a turn from the current input. Returns true when a turn was
/// started (the caller should then call `startTurn`); false when the
/// prompt was empty, had no provider, or was queued behind a running turn.
pub fn beginSubmit(app: *App) !bool {
    app.closeAtSearch();
    app.nav.block_nav = false;
    // If a previous turn was Esc-interrupted, force-cancel its worker
    // before starting a new one. Two concurrent workers would race on
    // the shared agent message history.
    if (app.thread.turn.state == .interrupting) discardAbandonedTurn(app);
    if (app.thread.turn.isActive()) return try app.enqueueSubmit();
    // A manual `/compact` is mid-flight on this lane: the summarizer will swap
    // the context on the UI thread, so starting a turn now would race that
    // reload. Keep the input — the user can submit once the notice lands.
    if (app.thread.agent) |agent| {
        if (agent.manual_compact_pending) {
            _ = try app.thread.transcript.append(app.gpa, .notice, "compaction", "Compaction in progress — wait for the summary before submitting.");
            return false;
        }
    }
    // C1: an idle lane (from `lane create` or a rested worker) has no
    // worker_context — submitting here would deref null at the
    // `resetCancel`/`dupe` sites below. Refuse with a guiding notice
    // instead of crashing. The guard is before `toOwnedSlice` so the
    // user's typed input is preserved (TD-2).
    if (app.thread.worker_context == null) {
        const id = if (lanes_util.workingLaneOf(app.thread)) |w|
            lanes_util.lastPathSegment(w.path)
        else
            "this lane";
        const notice = std.fmt.allocPrint(
            app.gpa,
            "Lane {s} is idle — no agent is attached. From the driver, `lane enter {s}` to work here, or `lane spawn` to start a worker in it.\n",
            .{ id, id },
        ) catch return false;
        defer app.gpa.free(notice);
        _ = app.thread.transcript.append(app.gpa, .notice, "lane", notice) catch {};
        return false;
    }
    const prompt = try app.inputs.input.toOwnedSlice();
    defer app.gpa.free(prompt);
    if (prompt.len == 0) return false;
    try app.thread.pushPromptHistory(app.gpa, prompt);
    if (app.liveRuntime()) |rt| rt.session_writer.savePromptHistory(prompt) catch {};

    if (app.liveRuntime() != null and app.liveRuntime().?.client == .none) {
        _ = try app.thread.transcript.append(app.gpa, .user, "you", prompt);
        const message = try formatNoProviderMessage(app);
        defer app.gpa.free(message);
        _ = try app.thread.transcript.append(app.gpa, .agent, "agent", message);
        return false;
    }

    resetTurnState(app);
    app.thread.worker_context.?.resetCancel();
    _ = try app.thread.transcript.append(app.gpa, .user, "you", prompt);
    // A worktree lane's first prompt also names its branch: ask the model
    // in parallel, and rename the hex branch when the answer lands.
    if (app.thread.title == null and lanes_util.workingLaneOf(app.thread) != null) {
        app.scheduleLaneNaming(app.thread, prompt) catch {};
    }
    try setLaneTitleIfUnset(app, prompt);
    try app.appendSkillInvocationsToTranscript(prompt);
    app.thread.turn_view.awaitModel();
    // The worker expands `@`-mentions (reading files / images) off the UI
    // thread; stash the raw text for `startTurn` to hand over. The worker
    // owns and frees it, so it must be allocated with the worker's
    // allocator (`worker_context.gpa`), not `app.gpa`.
    app.thread.pending_prompt = try app.thread.worker_context.?.gpa.dupe(u8, prompt);
    app.thread.turn.submit();
    return true;
}

/// Label the lane by its first user prompt (one line, truncated) so split
/// tiles read as the session, not a generic "lane". Owned; freed in deinit.
pub fn setLaneTitleIfUnset(app: *App, prompt: []const u8) !void {
    if (app.thread.title != null) return;
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    if (trimmed.len == 0) return;
    const line_end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    const line = std.mem.trim(u8, trimmed[0..line_end], " \t\r");
    if (line.len == 0) return;
    const max: usize = 40;
    if (line.len <= max) {
        app.thread.title = try app.gpa.dupe(u8, line);
        return;
    }
    var cut: usize = max;
    while (cut > 0 and (line[cut] & 0xC0) == 0x80) cut -= 1;
    app.thread.title = try std.fmt.allocPrint(app.gpa, "{s}…", .{line[0..cut]});
}

pub fn formatNoProviderMessage(app: *App) ![]u8 {
    if (app.liveRuntime()) |rt| {
        for (rt.diagnostics) |d| {
            switch (d) {
                .config_parse_error => |e| return std.fmt.allocPrint(
                    app.gpa,
                    "Failed to load {s}: {s}",
                    .{ e.path, e.reason },
                ),
                .bad_env_model => |raw| return std.fmt.allocPrint(
                    app.gpa,
                    "Invalid OPENAI_MODEL: expected <provider>/<model>, got '{s}'",
                    .{raw},
                ),
            }
        }
    }
    if (app.cached_config.model_selection) |ms| {
        const p = ms.provider();
        if (p.adapter() == null) {
            return std.fmt.allocPrint(
                app.gpa,
                "Provider '{s}' is not yet supported in Nova.",
                .{p.label()},
            );
        }
        if (p == .openai) {
            if (app.liveRuntime()) |rt| {
                if (rt.codex_connection_expired) return app.gpa.dupe(u8, runtime_mod.codex_connection_expired_message);
            }
            return app.gpa.dupe(u8, "No OpenAI Codex session — type /connect to sign in.");
        }
    }
    return app.gpa.dupe(
        u8,
        "No provider connected. Type /connect to pick one, or set OPENAI_MODEL=<provider>/<model>.",
    );
}

pub fn resetTurnState(app: *App) void {
    app.thread.turn_view.reset(app.getIo());
    app.metrics.loading_frame = 0;
    // A fresh turn invalidates the previous turn's failure record.
    if (app.thread.turn_failed) |old| {
        app.gpa.free(old);
        app.thread.turn_failed = null;
    }
    // Turn-start bookkeeping for the model-driven `lane` ops: a fresh turn
    // has made no progress yet, so anchor the activity clock now (a worker
    // is legitimately silent while its first model request is in flight)
    // and reset the tool-call tally + stall-warning latch.
    app.thread.last_activity_ms = std.Io.Clock.now(.awake, app.getIo()).toMilliseconds();
    app.thread.turn_tool_calls = 0;
    app.thread.stall_warned = false;
}

pub fn startTurn(app: *App) !void {
    const prompt = app.thread.pending_prompt;
    app.thread.pending_prompt = null;
    errdefer if (prompt) |p| app.thread.worker_context.?.gpa.free(p);
    app.thread.turn_future = try app.getIo().concurrent(agent_worker.runAgentTurn, .{
        app.thread.agent.?,
        &app.thread.worker_context.?,
        prompt,
        false,
    });
}

/// After a user interrupt has fully unwound (worker joined, queue stranded),
/// deliver any queued messages as a fresh turn: the worker drains the whole
/// queue into history (leading messages as context, the last as the latest
/// user message the model answers). Returns true if a turn was started.
pub fn restartTurnForQueuedMessages(app: *App) !bool {
    if (app.thread.queued.items.len == 0) return false;
    // No connected provider to run a turn: surface the queued text in the
    // transcript and drop the queue rather than spin up a doomed worker.
    if (app.liveRuntime() != null and app.liveRuntime().?.client == .none) {
        try app.flushQueuedUserMessagesToTranscript(@intCast(app.thread.queued.items.len));
        app.thread.agent.?.clearQueue();
        return true;
    }
    resetTurnState(app);
    app.thread.worker_context.?.resetCancel();
    app.thread.turn_view.awaitModel();
    // Free any prompt left over from a failed `startTurn` (the window is
    // theoretical — beginSubmit→startTurn are contiguous — but the cleanup
    // costs nothing). Messages travel via `drain_queue_first`, so no prompt
    // is handed over here.
    if (app.thread.pending_prompt) |p| {
        app.thread.worker_context.?.gpa.free(p);
        app.thread.pending_prompt = null;
    }
    app.thread.turn.submit();
    app.thread.turn_future = try app.getIo().concurrent(agent_worker.runAgentTurn, .{
        app.thread.agent.?,
        &app.thread.worker_context.?,
        @as(?[]u8, null),
        true,
    });
    return true;
}

/// Start a turn on `app.thread` that drains its agent's queued (background)
/// messages into history and answers them. Mirrors
/// `restartTurnForQueuedMessages` but is gated on the agent queue, not the
/// UI's display queue. Caller must have set `app.thread` to the target lane.
pub fn startDeliveryTurnOnCurrentThread(app: *App) !void {
    if (app.liveRuntime() != null and app.liveRuntime().?.client == .none) {
        // No provider to run a turn — drop the queued notice rather than spin
        // up a doomed worker. Flush the mirror first so it stays 1:1 with the
        // cleared agent queue (raw entries are dropped unrendered; a stray
        // mirror entry would shift every `steerSelectedQueued` index).
        try app.flushQueuedUserMessagesToTranscript(@intCast(app.thread.queued.items.len));
        app.thread.agent.?.clearQueue();
        return;
    }
    resetTurnState(app);
    app.thread.worker_context.?.resetCancel();
    app.thread.turn_view.awaitModel();
    // Free any prompt left over from a failed `startTurn`; messages travel via
    // `drain_queue_first`, so no prompt is handed over here.
    if (app.thread.pending_prompt) |p| {
        app.thread.worker_context.?.gpa.free(p);
        app.thread.pending_prompt = null;
    }
    app.thread.turn.submit();
    app.thread.turn_future = try app.getIo().concurrent(agent_worker.runAgentTurn, .{
        app.thread.agent.?,
        &app.thread.worker_context.?,
        @as(?[]u8, null),
        true,
    });
}

pub fn applyAgentEvent(app: *App, event: agent_mod.Agent.Event) !bool {
    const outcome = app.thread.turn.apply(event);
    // Any event the worker emitted means it is alive — stamp the activity
    // clock `lane read`/`await`/`list` use to detect a stalled worker (one
    // blocked in a hung read emits nothing), clear the stall-warning latch
    // (progress resumed), and tally tool calls.
    app.thread.last_activity_ms = std.Io.Clock.now(.awake, app.getIo()).toMilliseconds();
    app.thread.stall_warned = false;
    switch (event) {
        .tool_call_finished => app.thread.turn_tool_calls += 1,
        .turn_started => app.thread.turn_tool_calls = 0,
        .turn_failed => |message| {
            // Record why the turn failed (the same text lands in the
            // transcript as a notice). Spawned-worker completion delivery
            // reads this so a failed worker isn't reported as "done"; a new
            // turn on the lane resets it.
            if (app.thread.turn_failed) |old| app.gpa.free(old);
            app.thread.turn_failed = try app.gpa.dupe(u8, message);
        },
        else => {},
    }
    if (!outcome.project) {
        // Interrupting: a discarded turn's output must not mutate the
        // transcript. Join the worker once it posts its terminal event, then
        // deliver any messages the user queued behind the cancelled turn as
        // a fresh turn.
        if (outcome.finished) {
            app.awaitTurn();
            // The worker is joined, so any files the cut-short turn wrote are
            // settled on disk. Snapshot them now — otherwise they sit
            // unbound and a later timeline restore can't bring them back.
            app.checkpointFinishedTurn();
            return try restartTurnForQueuedMessages(app);
        }
        return false;
    }
    var visible_change = try app.thread.turn_view.apply(app.gpa, &app.thread.transcript, event);
    switch (event) {
        .queued_messages_flushed => |count| {
            if (count > 0 and app.thread.queued.items.len > 0) {
                try app.flushQueuedUserMessagesToTranscript(count);
                visible_change = true;
            }
        },
        else => {},
    }
    if (outcome.finished) {
        app.awaitTurn();
        app.checkpointFinishedTurn();
        if (app.thread.queued.items.len > 0) {
            app.clearQueuedUserMessages();
            visible_change = true;
        }
    }
    return visible_change;
}
