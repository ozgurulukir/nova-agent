//! Transcript and session conversation rebuilding logic.
//! Free functions taking `*App` — extracted from `tui.zig`.

const std = @import("std");
const tui = @import("../tui.zig");
const ai = @import("../ai.zig");
const agent_mod = @import("../agent.zig");
const tools_mod = @import("../tools.zig");
const transcript_mod = @import("../transcript.zig");
const runtime_mod = @import("../runtime.zig");
const search_mod = @import("../search.zig");
const skill_mod = @import("../skill.zig");

const App = tui.App;

pub fn installRuntime(app: *App, runtime: *runtime_mod.AgentRuntime) !void {
    // Session switch: only the ACTIVE lane's turn is checked and only the
    // active lane's runtime is swapped. Non-primary lanes keep running against
    // their OWN runtimes/sessions — a deliberate decision, not an oversight:
    // each lane owns its runtime, so a switch must not tear down lanes the
    // user is still working in. Completion routing is generation-safe across
    // the switch (M1: `laneByGeneration`, not a raw `*Agent` pointer), so a
    // worker finishing after the switch still reaches its spawner. See
    // `_plan/plan-lane-worker-hardening-2026-08-05.md` (I4).
    if (app.thread.turn.isActive()) return error.InFlightTurn;
    app.cancelLaneNaming(app.thread);
    // Compare before destroying: the old cwd is freed by deinit.
    const cwd_changed = if (app.liveRuntime()) |old| !std.mem.eql(u8, old.cwd, runtime.cwd) else true;
    if (app.liveRuntime()) |old| {
        // Before destroying the old runtime, reset vxfw focus to the root
        // widget. The focused TextField's userdata points into the old
        // runtime's memory; once it's deinit'd, FocusHandler.update can no
        // longer find it in the surface tree, leaves the focus path empty,
        // and the next key event crashes (App.zig:594). Root is always drawn
        // and runtime-independent, so pinning here is safe. Best-effort: if
        // the framework handle isn't wired (tests), skip silently.
        if (app.fw_app) |fw| {
            if (app.root_widget) |root| fw.wants_focus = root;
        }
        old.deinit();
        app.gpa.destroy(old);
    }
    // Tear down the stale search index and re-index the new project directory.
    // The old walk's worker thread keeps scanning the previous cwd until
    // destroyed; releasing here prevents stale search results and frees the
    // index memory before the new walk allocates.
    if (cwd_changed) search_mod.restart(app.gpa, app.io, runtime.cwd);
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = runtime, .owns = true } };
    app.thread.agent = &runtime.agent;
    app.thread.id = runtime.session_writer.session.id;
    // The label belongs to the departed session; the next first prompt
    // re-derives it.
    if (app.thread.title) |title| app.gpa.free(title);
    app.thread.title = null;
    // Load prompt history from the session DB.
    app.thread.prompt_history_index = null;
    app.thread.prompt_history.deinit(app.gpa);
    app.thread.prompt_history = .empty;
    if (runtime.session_writer.loadPromptHistory(app.gpa)) |prompts| {
        // loadPromptHistory returns newest-first; reverse to oldest-first.
        var i: usize = prompts.len;
        while (i > 0) {
            i -= 1;
            app.thread.prompt_history.append(app.gpa, prompts[i]) catch {};
        }
        app.gpa.free(prompts);
    } else |_| {}
    app.mode = .normal;
    app.clearInput();
    app.resetTurnState();
    app.armGitLabelRefresh();
}

pub fn clearConversation(app: *App) !void {
    if (app.thread.transcript.messages.items.len > 0) {
        try app.retired_transcripts.append(app.gpa, app.thread.transcript);
    }
    app.thread.transcript = .{};
    app.thread.transcript_list.scroll = .{};
}

pub fn rebuildTranscriptFromAgent(app: *App) !void {
    try clearConversation(app);
    for (app.thread.agent.?.messages()) |message| {
        if (message.role() == .system) continue;
        const text = message.text();
        if (message.role() == .user) {
            _ = try app.thread.transcript.append(app.gpa, .user, "you", text);
            const injected = try skill_mod.collectInjectedSkillNames(app.gpa, text);
            defer {
                for (injected) |n| app.gpa.free(n);
                app.gpa.free(injected);
            }
            for (injected) |name| {
                const title = try std.fmt.allocPrint(app.gpa, "[SKILL] {s}", .{name});
                defer app.gpa.free(title);
                _ = try app.thread.transcript.append(app.gpa, .skill, title, "");
            }
        } else if (message.role() == .assistant) {
            if (text.len > 0) _ = try app.thread.transcript.append(app.gpa, .agent, "agent", text);
        } else if (message.role() == .tool) {
            const title = try resumedToolTitle(app, message);
            defer app.gpa.free(title);
            _ = try app.thread.transcript.appendTool(app.gpa, title, text, message.tool.failed);
        }
    }
    if (app.thread.transcript.messages.items.len > 0) app.thread.transcript.selected = @intCast(app.thread.transcript.messages.items.len - 1);
    // A freshly installed (resumed) session left the label unset; re-derive
    // it from the conversation's first user message.
    if (app.thread.title == null) {
        for (app.thread.agent.?.messages()) |message| {
            if (message.role() != .user) continue;
            try app.setLaneTitleIfUnset(message.text());
            break;
        }
    }
}

pub fn resumedToolTitle(app: *App, message: ai.ChatMessage) ![]u8 {
    if (message == .tool) {
        if (message.tool.display_label) |label| return transcript_mod.toolTitle(app.gpa, label);
        const id = message.tool.call_id.slice();
        for (app.thread.agent.?.messages()) |candidate| {
            switch (candidate) {
                .assistant => |a| {
                    for (a.content) |block| {
                        if (block != .tool_call) continue;
                        if (!std.mem.eql(u8, block.tool_call.call_id.slice(), id)) continue;
                        var display = try agent_mod.formatToolDisplay(
                            app.gpa,
                            tools_mod.lookupIn(tools_mod.builtinRegistry(), block.tool_call.name),
                            block.tool_call.arguments,
                        );
                        defer display.deinit(app.gpa);
                        return transcript_mod.toolTitle(app.gpa, display.label);
                    }
                },
                else => {},
            }
        }
        return transcript_mod.toolTitle(app.gpa, id);
    }
    return transcript_mod.toolTitle(app.gpa, "tool");
}
