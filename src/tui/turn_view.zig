//! TurnView owns the visible state of the current agent turn.
//!
//! The durable transcript lives in `transcript.zig`. This type only remembers the
//! streaming positions needed to turn `Agent.Event`s into transcript mutations
//! and synthetic UI state such as the loading spinner.

const std = @import("std");

const agent_mod = @import("../agent.zig");
const ai = @import("../ai.zig");
const os = @import("../os.zig");
const transcript_mod = @import("../transcript.zig");
const tools_mod = @import("../tools.zig");
const tool_policy = @import("tool_policy.zig");

const assert = std.debug.assert;

pub const loading_spinners = [12][]const u8{ "Firing Neurons", "Multiplying Matrices", "brr..brr...", "Warping", "Hailing the machine god", "Tokenmaxxing", "Uploading consciousness", "Brain dancing", "Resisting psychosis", "Wait a minute...", "beep... boop...", "Uhhh" };

pub const TurnView = struct {
    agent_index: ?u32 = null,
    thinking_index: ?u32 = null,
    /// Chosen when the turn starts. The spinner itself is synthetic and is
    /// drawn outside the transcript while `activity == .awaiting_model`.
    loading_word_index: u8 = 0,
    activity: Activity = .idle,
    tool_seen_in_response: bool = false,
    pending_redraw: bool = false,
    tool_indexes: std.ArrayList(?u32) = .empty,

    pub const Activity = union(enum) {
        idle,
        awaiting_model,
        thinking: u32,
        writing_response: u32,
        calling_tools,
    };

    pub fn deinit(self: *TurnView, gpa: std.mem.Allocator) void {
        self.tool_indexes.deinit(gpa);
        self.* = undefined;
    }

    pub fn reset(self: *TurnView, io: std.Io) void {
        self.agent_index = null;
        self.thinking_index = null;
        self.loading_word_index = chooseLoadingWordIndex(io);
        self.activity = .idle;
        self.tool_seen_in_response = false;
        self.pending_redraw = false;
        self.tool_indexes.clearRetainingCapacity();
    }

    pub fn apply(
        self: *TurnView,
        gpa: std.mem.Allocator,
        transcript: *transcript_mod.Transcript,
        event: agent_mod.Agent.Event,
    ) !bool {
        switch (event) {
            .turn_started => return false,
            .response_delta => |delta| return try self.applyResponseDelta(gpa, transcript, delta),
            .thinking_delta => |delta| return try self.applyThinkingDelta(gpa, transcript, delta),
            .tool_delta => |tool| return try self.applyToolDelta(gpa, transcript, tool),
            .delta_end => return self.takePendingRedraw(),
            .tool_call_finished => |tool| return try self.applyToolFinished(gpa, transcript, tool),
            .tool_batch_finished => return try self.applyToolBatchFinished(gpa, transcript),
            .queued_messages_flushed => return false,
            .turn_failed => |message| return try self.applyTurnFailed(gpa, transcript, message),
            .turn_finished => return try self.applyTurnFinished(gpa, transcript),
            .history_compacted => |info| return try self.applyHistoryCompacted(gpa, transcript, info),
            .compaction_notice => |notice| return try self.applyCompactionNotice(gpa, transcript, notice),
            .tool_budget_exhausted => |limit| return try self.applyToolBudgetExhausted(gpa, transcript, limit),
        }
    }

    pub fn awaitingOutput(self: *const TurnView) bool {
        return self.activity == .awaiting_model;
    }

    /// Begin waiting for the next chunk of model output. The spinner is drawn
    /// outside the transcript; no transcript mutation.
    pub fn awaitModel(self: *TurnView) void {
        assert(self.loading_word_index < loading_spinners.len);
        self.activity = .awaiting_model;
    }

    fn applyResponseDelta(
        self: *TurnView,
        gpa: std.mem.Allocator,
        transcript: *transcript_mod.Transcript,
        delta: []const u8,
    ) !bool {
        if (delta.len == 0) return false;
        _ = try self.finishThinking(gpa, transcript);
        try self.applyContentDelta(gpa, transcript, delta);
        self.activity = .{ .writing_response = self.agent_index.? };
        self.pending_redraw = true;
        return true;
    }

    fn applyThinkingDelta(
        self: *TurnView,
        gpa: std.mem.Allocator,
        transcript: *transcript_mod.Transcript,
        delta: []const u8,
    ) !bool {
        if (try self.applyReasoningDelta(gpa, transcript, delta)) self.pending_redraw = true;
        if (self.thinking_index) |index| self.activity = .{ .thinking = index };
        return false;
    }

    fn applyToolDelta(
        self: *TurnView,
        gpa: std.mem.Allocator,
        transcript: *transcript_mod.Transcript,
        tool: ai.ToolDelta,
    ) !bool {
        const thinking_finished = try self.finishThinking(gpa, transcript);
        if (try self.applyToolPreview(gpa, transcript, tool)) {
            self.activity = .calling_tools;
            self.pending_redraw = true;
        }
        if (thinking_finished) self.pending_redraw = true;
        return false;
    }

    fn applyToolFinished(
        self: *TurnView,
        gpa: std.mem.Allocator,
        transcript: *transcript_mod.Transcript,
        tool: agent_mod.Agent.Event.ToolCallFinished,
    ) !bool {
        const thinking_finished = try self.finishThinking(gpa, transcript);
        self.activity = .calling_tools;
        return thinking_finished or try self.finishTool(gpa, transcript, tool);
    }

    fn applyToolBatchFinished(
        self: *TurnView,
        gpa: std.mem.Allocator,
        transcript: *transcript_mod.Transcript,
    ) !bool {
        _ = try self.finishThinking(gpa, transcript);
        self.agent_index = null;
        self.thinking_index = null;
        self.tool_seen_in_response = false;
        self.tool_indexes.clearRetainingCapacity();
        // The batch is done; wait for the next response segment.
        self.activity = .awaiting_model;
        return true;
    }

    fn applyTurnFailed(
        self: *TurnView,
        gpa: std.mem.Allocator,
        transcript: *transcript_mod.Transcript,
        message: []const u8,
    ) !bool {
        self.activity = .idle;
        _ = transcript.stopRunningTools();
        _ = try transcript.append(gpa, .notice, "notice", message);
        return true;
    }

    fn applyTurnFinished(
        self: *TurnView,
        gpa: std.mem.Allocator,
        transcript: *transcript_mod.Transcript,
    ) !bool {
        self.activity = .idle;
        _ = try self.finishThinking(gpa, transcript);
        _ = transcript.stopRunningTools();
        return true;
    }

    fn applyHistoryCompacted(
        self: *TurnView,
        gpa: std.mem.Allocator,
        transcript: *transcript_mod.Transcript,
        info: agent_mod.Agent.Event.HistoryCompacted,
    ) !bool {
        _ = self;
        var buffer: [128]u8 = undefined;
        const text = std.fmt.bufPrint(
            &buffer,
            "compacted context ~{d} -> ~{d} tokens",
            .{ info.tokens_before, info.tokens_after },
        ) catch "compacted context";
        _ = try transcript.append(gpa, .info, "notice", text);
        return true;
    }

    fn applyCompactionNotice(
        self: *TurnView,
        gpa: std.mem.Allocator,
        transcript: *transcript_mod.Transcript,
        notice: agent_mod.Agent.Event.CompactionNotice,
    ) !bool {
        _ = self;
        const text = switch (notice) {
            .breaker_tripped => "automatic compaction disabled for this session after 3 failures — use /compact to retry manually",
            .stuck => "context is full but nothing can be summarized — start a new session or raise context.overrideContextWindow",
            .waiting => "waiting for background summary before continuing…",
        };
        _ = try transcript.append(gpa, .notice, "compaction", text);
        return true;
    }

    /// Amber attention row (`.notice`, not `.info`): the budget stop needs the
    /// user to act (send a message to resume), unlike routine compaction info.
    fn applyToolBudgetExhausted(
        self: *TurnView,
        gpa: std.mem.Allocator,
        transcript: *transcript_mod.Transcript,
        limit: u32,
    ) !bool {
        _ = self;
        var buffer: [128]u8 = undefined;
        const text = std.fmt.bufPrint(
            &buffer,
            "tool-call budget reached ({d} calls) — turn stopped early; send a message to continue",
            .{limit},
        ) catch "tool-call budget reached — turn stopped early; send a message to continue";
        _ = try transcript.append(gpa, .notice, "budget", text);
        return true;
    }

    fn takePendingRedraw(self: *TurnView) bool {
        const redraw = self.pending_redraw;
        self.pending_redraw = false;
        return redraw;
    }

    fn applyContentDelta(
        self: *TurnView,
        gpa: std.mem.Allocator,
        transcript: *transcript_mod.Transcript,
        delta: []const u8,
    ) !void {
        assert(delta.len > 0);
        const selected = transcript.selected;
        if (self.agent_index) |index| {
            try transcript.appendAgentDelta(gpa, index, delta);
        } else {
            self.agent_index = try transcript.append(gpa, .agent, "agent", delta);
        }
        if (self.tool_seen_in_response) {
            if (selected) |index| transcript.select(index);
        } else {
            selectGeneratedMessage(transcript, self.agent_index.?);
        }
    }

    fn finishThinking(self: *TurnView, gpa: std.mem.Allocator, transcript: *transcript_mod.Transcript) !bool {
        const index = self.thinking_index orelse return false;
        if (index >= transcript.messages.items.len) return false;
        if (std.mem.eql(u8, transcript.messages.items[index].mirror().title, "Thoughts")) return false;
        try transcript.finishThinking(gpa, index);
        return true;
    }

    fn applyReasoningDelta(
        self: *TurnView,
        gpa: std.mem.Allocator,
        transcript: *transcript_mod.Transcript,
        delta: []const u8,
    ) !bool {
        if (delta.len == 0) return false;
        var visible_change = false;
        if (self.thinking_index) |index| {
            try transcript.appendThinkingDelta(gpa, index, delta);
        } else if (self.agent_index) |agent_index| {
            self.thinking_index = try transcript.insert(gpa, agent_index, .thinking, "Thinking...", delta);
            self.agent_index = agent_index + 1;
            transcript.select(self.thinking_index.?);
            visible_change = true;
        } else {
            self.thinking_index = try transcript.append(gpa, .thinking, "Thinking...", delta);
            visible_change = true;
        }
        if (self.agent_index == null and !self.tool_seen_in_response) selectGeneratedMessage(transcript, self.thinking_index.?);
        return visible_change;
    }

    fn applyToolPreview(
        self: *TurnView,
        gpa: std.mem.Allocator,
        transcript: *transcript_mod.Transcript,
        tool: ai.ToolDelta,
    ) !bool {
        // Streaming deltas can arrive with an empty name before the provider
        // sends the tool-call name chunk. Skip until the name is populated.
        if (tool.name.len == 0) return false;
        if (std.mem.eql(u8, tool.name, "skill")) {
            const JsonArgs = struct {
                name: ?[]const u8 = null,
                skill: ?[]const u8 = null,
                command: ?[]const u8 = null,
            };
            const parsed = std.json.parseFromSlice(JsonArgs, gpa, tool.arguments, .{ .ignore_unknown_fields = true }) catch return false;
            defer parsed.deinit();
            const raw_name = parsed.value.name orelse parsed.value.skill orelse parsed.value.command orelse return false;
            const skill_name = std.mem.trim(u8, raw_name, " \t\r\n$");
            if (skill_name.len > 0) {
                return try self.applySkillPreview(gpa, transcript, tool.index, skill_name);
            }
        }
        // Known limitation (Phase 9): this skill-preview branch is keyed off
        // the canonical shell name (`.bash` on POSIX, `.pwsh` on Windows) so
        // the render rules fire for the host shell, but `skillNameFromBashRead`
        // parses BASH command syntax — it recognizes `cat` of skill files, not
        // PowerShell's `Get-Content`. The branch is therefore gated on
        // `!os.is_windows` (bash hosts); on Windows the skill preview for
        // `<tool>/<skill>` read commands will NOT fire, and the call falls
        // through to the generic display path below. Accepted and documented;
        // a pwsh-aware parser is a follow-up, not part of this change.
        if (std.mem.eql(u8, tool.name, tools_mod.shell_tool.name) and !os.is_windows) {
            const command = agent_mod.parseCommand(gpa, tool.arguments) catch return false;
            gpa.free(command);
            if (try skillNameFromBashRead(gpa, tool.arguments)) |skill_name| {
                defer gpa.free(skill_name);
                return try self.applySkillPreview(gpa, transcript, tool.index, skill_name);
            }
        }
        var display = try agent_mod.formatToolDisplay(
            gpa,
            tools_mod.lookupIn(tools_mod.builtinRegistry(), tool.name),
            tool.arguments,
        );
        defer display.deinit(gpa);
        if (std.mem.eql(u8, tool.name, tools_mod.shell_tool.name) and display.expanded_label == null) return false;

        // Reached only once arguments parse — partial tool args return above,
        // keeping the spinner up. Clearing it here counts as a visible change.
        const was_awaiting = self.awaitingOutput();

        var visible_change = false;
        if (self.toolTranscriptIndex(tool.index)) |index| {
            visible_change = !toolDisplayMatches(transcript.messages.items[index], display);
            try transcript.updateToolExpanded(gpa, index, display.label, display.expanded_label);
        } else {
            const index = try transcript.startTool(gpa, display.label);
            try transcript.updateToolExpanded(gpa, index, display.label, display.expanded_label);
            try self.putToolTranscriptIndex(gpa, tool.index, index);
            visible_change = true;
        }
        self.tool_seen_in_response = true;
        self.agent_index = null;
        return was_awaiting or visible_change;
    }

    fn setSkillMessage(gpa: std.mem.Allocator, transcript: *transcript_mod.Transcript, index: u32, title: []const u8) !void {
        assert(index < transcript.messages.items.len);
        const message = &transcript.messages.items[index];
        const owned_title = try gpa.dupe(u8, title);
        errdefer gpa.free(owned_title);
        const owned_body = try gpa.dupe(u8, "");
        errdefer gpa.free(owned_body);
        // Free whatever payload the previous variant owned.
        switch (message.*) {
            inline .user, .agent, .skill, .logo, .thinking, .status, .notice, .success, .info => |m| {
                gpa.free(m.title);
                gpa.free(m.body);
            },
            .tool => |*t| {
                gpa.free(t.title);
                gpa.free(t.body);
                if (t.stderr) |stderr| gpa.free(stderr);
                if (t.expanded_title) |expanded_title| gpa.free(expanded_title);
                if (t.expanded_title_formatted) |f| gpa.free(f);
                for (t.parts) |*part| part.deinit(gpa);
                if (t.parts.len > 0) gpa.free(t.parts);
            },
        }
        message.* = .{
            .skill = .{
                .title = owned_title,
                .body = owned_body,
                .expanded = false,
            },
        };
    }

    fn applySkillPreview(
        self: *TurnView,
        gpa: std.mem.Allocator,
        transcript: *transcript_mod.Transcript,
        tool_index: u32,
        skill_name: []const u8,
    ) !bool {
        const title = try std.fmt.allocPrint(gpa, "[SKILL] {s}", .{skill_name});
        defer gpa.free(title);

        const was_awaiting = self.awaitingOutput();
        var visible_change = false;
        if (self.toolTranscriptIndex(tool_index)) |index| {
            const m = transcript.messages.items[index].mirror();
            visible_change = m.kind != .skill or !std.mem.eql(u8, m.title, title);
            if (visible_change) try setSkillMessage(gpa, transcript, index, title);
        } else {
            const index = try transcript.append(gpa, .skill, title, "");
            try self.putToolTranscriptIndex(gpa, tool_index, index);
            visible_change = true;
        }
        self.tool_seen_in_response = true;
        self.agent_index = null;
        return was_awaiting or visible_change;
    }

    fn finishTool(
        self: *TurnView,
        gpa: std.mem.Allocator,
        transcript: *transcript_mod.Transcript,
        tool: agent_mod.Agent.Event.ToolCallFinished,
    ) !bool {
        const policy = tool_policy.forName(tool.name);
        const existing_index = self.toolTranscriptIndex(tool.index);
        if (std.mem.eql(u8, tool.name, "skill")) {
            const target_index = if (existing_index) |idx| idx: {
                if (idx < transcript.messages.items.len and transcript.messages.items[idx] != .skill) {
                    const skill_name = if (tool.display_expanded_label) |exp|
                        (if (std.mem.startsWith(u8, exp, "skill: ")) exp[7..] else exp)
                    else
                        (if (std.mem.startsWith(u8, tool.display_label, "Read ") and std.mem.endsWith(u8, tool.display_label, " skill"))
                            tool.display_label[5 .. tool.display_label.len - 6]
                        else
                            tool.display_label);
                    const title = try std.fmt.allocPrint(gpa, "[SKILL] {s}", .{skill_name});
                    defer gpa.free(title);
                    try setSkillMessage(gpa, transcript, idx, title);
                }
                break :idx idx;
            } else idx: {
                const skill_name = if (tool.display_expanded_label) |exp|
                    (if (std.mem.startsWith(u8, exp, "skill: ")) exp[7..] else exp)
                else
                    (if (std.mem.startsWith(u8, tool.display_label, "Read ") and std.mem.endsWith(u8, tool.display_label, " skill"))
                        tool.display_label[5 .. tool.display_label.len - 6]
                    else
                        tool.display_label);
                const title = try std.fmt.allocPrint(gpa, "[SKILL] {s}", .{skill_name});
                defer gpa.free(title);
                const created = try transcript.append(gpa, .skill, title, "");
                try self.putToolTranscriptIndex(gpa, tool.index, created);
                break :idx created;
            };
            try transcript.finishSkill(gpa, target_index, tool.display_body, tool.failed);
            self.tool_seen_in_response = true;
            self.agent_index = null;
            return true;
        }
        if (existing_index) |index| {
            if (index < transcript.messages.items.len and transcript.messages.items[index].mirror().kind == .skill) {
                try transcript.finishSkill(gpa, index, tool.display_body, tool.failed);
                self.tool_seen_in_response = true;
                self.agent_index = null;
                return true;
            }
        }
        const index = if (existing_index) |index| index else index: {
            const created = try transcript.startTool(gpa, tool.display_label);
            try transcript.updateToolExpanded(gpa, created, tool.display_label, tool.display_expanded_label);
            try self.putToolTranscriptIndex(gpa, tool.index, created);
            break :index created;
        };

        const visible_before = toolFinishVisibleChange(transcript, index, tool.display_label);
        const was_expanded = transcript.messages.items[index].mirror().expanded;
        const was_running = transcript.messages.items[index].mirror().tool_running;
        // M4: compute the render before finishTool — it now consumes it. A diff
        // body keeps diff rendering; a plain body gets JSON/text classification.
        const is_diff = tool.display_kind == .diff;
        const render: transcript_mod.Render = if (is_diff) .diff else policy.render;
        try transcript.updateToolExpanded(gpa, index, tool.display_label, tool.display_expanded_label);
        try transcript.finishTool(gpa, index, tool.display_body, tool.stderr, tool.failed, render);
        const expand = policy.expand_by_default or is_diff;
        transcript.setExpanded(index, expand);
        selectGeneratedMessage(transcript, index);
        self.tool_seen_in_response = true;
        self.agent_index = null;
        return existing_index == null or was_running or visible_before or expand != was_expanded;
    }

    fn selectGeneratedMessage(transcript: *transcript_mod.Transcript, index: u32) void {
        assert(index < transcript.messages.items.len);
        if (transcript.selected) |selected| {
            if (selected != index) return;
        }
        transcript.select(index);
    }

    fn toolFinishVisibleChange(transcript: *const transcript_mod.Transcript, index: u32, command: []const u8) bool {
        if (index >= transcript.messages.items.len) return true;
        const message = transcript.messages.items[index];
        if (message != .tool) return true;
        if (message.tool.expanded) return true;
        return !toolTitleMatchesCommand(message.tool.title, command);
    }

    fn toolTranscriptIndex(self: *const TurnView, tool_index: u32) ?u32 {
        if (tool_index >= self.tool_indexes.items.len) return null;
        return self.tool_indexes.items[tool_index];
    }

    fn skillNameFromBashRead(gpa: std.mem.Allocator, arguments: []const u8) !?[]u8 {
        const JsonArgs = struct {
            command: ?[]const u8 = null,
        };
        const parsed = std.json.parseFromSlice(JsonArgs, gpa, arguments, .{ .ignore_unknown_fields = true }) catch return null;
        defer parsed.deinit();
        const command = parsed.value.command orelse return null;
        if (!commandReadsSkill(command)) return null;
        const name = skillNameFromCommand(command) orelse return null;
        return try gpa.dupe(u8, name);
    }

    fn commandReadsSkill(command: []const u8) bool {
        // Verb-agnostic (TD-13): any read tool qualifies; the filename
        // boundary check in `skillNameFromCommand` handles the false positive.
        if (std.mem.indexOf(u8, command, ".agents/") == null) return false;
        return std.mem.indexOf(u8, command, "/SKILL.md") != null;
    }

    fn skillNameFromCommand(command: []const u8) ?[]const u8 {
        const skill_suffix = "/SKILL.md";
        var search_from: usize = 0;
        while (std.mem.indexOfPos(u8, command, search_from, skill_suffix)) |suffix_start| {
            const after = suffix_start + skill_suffix.len;
            const boundary = after >= command.len or isSkillPathBoundary(command[after]);
            if (boundary) {
                var name_start = suffix_start;
                while (name_start > 0) {
                    const byte = command[name_start - 1];
                    if (byte == '/' or byte == '\'' or byte == '"' or std.ascii.isWhitespace(byte)) break;
                    name_start -= 1;
                }
                const name = command[name_start..suffix_start];
                if (name.len > 0 and std.mem.indexOfScalar(u8, name, '/') == null) return name;
            }
            search_from = suffix_start + 1;
        }
        return null;
    }

    fn isSkillPathBoundary(byte: u8) bool {
        return byte == ' ' or byte == '\t' or byte == '\'' or byte == '"' or
            byte == ';' or byte == '|' or byte == '&' or byte == ')' or byte == '\n';
    }

    fn putToolTranscriptIndex(
        self: *TurnView,
        gpa: std.mem.Allocator,
        tool_index: u32,
        transcript_index: u32,
    ) !void {
        while (self.tool_indexes.items.len <= tool_index) {
            try self.tool_indexes.append(gpa, null);
        }
        self.tool_indexes.items[tool_index] = transcript_index;
    }
};

fn toolDisplayMatches(message: transcript_mod.Message, display: tools_mod.ToolDisplay) bool {
    if (message != .tool) return false;
    if (!toolTitleMatchesText(message.tool.title, display.label)) return false;
    if (display.expanded_label) |label| {
        const title = message.tool.expanded_title orelse return false;
        return toolTitleMatchesText(title, label);
    }
    return message.tool.expanded_title == null;
}

fn toolTitleMatchesCommand(title: []const u8, command: []const u8) bool {
    return toolTitleMatchesText(title, command);
}

fn toolTitleMatchesText(title: []const u8, text: []const u8) bool {
    const prefix = "🛠  ";
    return std.mem.startsWith(u8, title, prefix) and std.mem.eql(u8, title[prefix.len..], text);
}

pub fn chooseLoadingWordIndex(io: std.Io) u8 {
    assert(loading_spinners.len > 0);
    // Note: @mod(nanoseconds, len) has a slight bias when 1e9 % len != 0
    // (indices 0..(1e9 % len - 1) are marginally more likely). Negligible for
    // visual variety at len=12 (bias ~4e-9). If len changes or uniformity
    // becomes required, use a rejection-sampled range or seed from a wider
    // clock field.
    const timestamp: std.Io.Timestamp = .now(io, .awake);
    const index = @mod(timestamp.nanoseconds, loading_spinners.len);
    return @intCast(index);
}

test "skill tool invocation renders skill row on both Windows and POSIX" {
    const gpa = std.testing.allocator;
    var view: TurnView = .{};
    defer view.deinit(gpa);
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const changed = try view.applyToolPreview(gpa, &transcript, .{
        .index = 0,
        .name = "skill",
        .arguments = "{\"name\":\"tigerstyle\"}",
    });

    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(usize, 1), transcript.messages.items.len);
    try std.testing.expectEqual(transcript_mod.MessageKind.skill, transcript.messages.items[0].mirror().kind);
    try std.testing.expectEqualStrings("[SKILL] tigerstyle", transcript.messages.items[0].mirror().title);

    const finished = try view.applyToolFinished(gpa, &transcript, .{
        .index = 0,
        .name = "skill",
        .display_label = "Read tigerstyle skill",
        .display_expanded_label = "skill: tigerstyle",
        .display_body = "# Tigerstyle Guidelines",
    });
    try std.testing.expect(finished);
    try std.testing.expectEqualStrings("# Tigerstyle Guidelines", transcript.messages.items[0].mirror().body);
    try std.testing.expect(!transcript.messages.items[0].mirror().expanded);
    transcript.toggleSelected();
    try std.testing.expect(transcript.messages.items[0].mirror().expanded);
}

test "skill tool finished converts existing generic tool row into skill card" {
    const gpa = std.testing.allocator;
    var view: TurnView = .{};
    defer view.deinit(gpa);
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    // Simulate preview as a generic tool before full JSON parsed
    const idx = try transcript.startTool(gpa, "skill");
    try view.putToolTranscriptIndex(gpa, 0, idx);

    const finished = try view.applyToolFinished(gpa, &transcript, .{
        .index = 0,
        .name = "skill",
        .display_label = "Read tigerstyle skill",
        .display_expanded_label = "skill: tigerstyle",
        .display_body = "# Tigerstyle Guidelines",
    });
    try std.testing.expect(finished);
    try std.testing.expectEqual(@as(usize, 1), transcript.messages.items.len);
    try std.testing.expectEqual(transcript_mod.MessageKind.skill, transcript.messages.items[0].mirror().kind);
    try std.testing.expectEqualStrings("[SKILL] tigerstyle", transcript.messages.items[0].mirror().title);
    try std.testing.expectEqualStrings("# Tigerstyle Guidelines", transcript.messages.items[0].mirror().body);
}

test "bash read of skill renders skill row" {
    // The skill-preview branch is deliberately gated to bash hosts
    // (`applyToolPreview` fires it only when `!os.is_windows`); on Windows the
    // host shell is pwsh and a `bash` skill read falls through to the generic
    // tool display, so this rendering assertion is POSIX-only.
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var view: TurnView = .{};
    defer view.deinit(gpa);
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const changed = try view.applyToolPreview(gpa, &transcript, .{
        .index = 0,
        .name = "bash",
        .arguments = "{\"command\":\"cat .agents/skills/tigerstyle/SKILL.md\",\"description\":\"Read the tigerstyle skill instructions\"}",
    });

    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(usize, 1), transcript.messages.items.len);
    try std.testing.expectEqual(transcript_mod.MessageKind.skill, transcript.messages.items[0].mirror().kind);
    try std.testing.expectEqualStrings("[SKILL] tigerstyle", transcript.messages.items[0].mirror().title);

    const finished = try view.applyToolFinished(gpa, &transcript, .{
        .index = 0,
        .name = "bash",
        .display_label = "Read the tigerstyle skill instructions",
        .display_expanded_label = "cat .agents/skills/tigerstyle/SKILL.md",
        .display_body = "skill file contents",
    });
    try std.testing.expect(finished);
    try std.testing.expectEqualStrings("skill file contents", transcript.messages.items[0].mirror().body);
    try std.testing.expect(!transcript.messages.items[0].mirror().expanded);
    transcript.toggleSelected();
    try std.testing.expect(transcript.messages.items[0].mirror().expanded);
}

test "bash skill detection uses command, not reason" {
    const gpa = std.testing.allocator;
    const skill_name = try TurnView.skillNameFromBashRead(gpa, "{\"command\":\"cat .agents/skills/tigerstyle/SKILL.md\",\"description\":\"Read the skill file\"}");
    defer if (skill_name) |name| gpa.free(name);
    try std.testing.expectEqualStrings("tigerstyle", skill_name.?);
}

test "head read of skill renders skill row" {
    const gpa = std.testing.allocator;
    const skill_name = try TurnView.skillNameFromBashRead(gpa, "{\"command\":\"head -50 .agents/skills/tigerstyle/SKILL.md\"}");
    defer if (skill_name) |name| gpa.free(name);
    try std.testing.expectEqualStrings("tigerstyle", skill_name.?);
}

test "SKILL.md.bak does not render skill row" {
    const gpa = std.testing.allocator;
    const skill_name = try TurnView.skillNameFromBashRead(gpa, "{\"command\":\"cat .agents/skills/tigerstyle/SKILL.md.bak\"}");
    defer if (skill_name) |name| gpa.free(name);
    try std.testing.expect(skill_name == null);
}

test "turn view streams content into transcript" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);
    var turn_view: TurnView = .{};
    defer turn_view.deinit(gpa);

    turn_view.awaitModel();
    try std.testing.expect(turn_view.activity == .awaiting_model);

    try std.testing.expect(try turn_view.apply(gpa, &transcript, .{ .response_delta = "hello" }));
    try std.testing.expectEqual(@as(usize, 1), transcript.messages.items.len);
    try std.testing.expectEqualStrings("hello", transcript.messages.items[0].mirror().body);
    try std.testing.expect(turn_view.activity == .writing_response);
    try std.testing.expectEqual(@as(u32, 0), turn_view.activity.writing_response);
}

test "history compacted appends a white info notice, not a red error" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);
    var turn_view: TurnView = .{};
    defer turn_view.deinit(gpa);

    try std.testing.expect(try turn_view.apply(gpa, &transcript, .{
        .history_compacted = .{ .tokens_before = 90_000, .tokens_after = 20_000 },
    }));
    try std.testing.expectEqual(@as(usize, 1), transcript.messages.items.len);
    // Neutral `.info` (white), distinct from `.notice` (red error).
    try std.testing.expectEqual(transcript_mod.MessageKind.info, transcript.messages.items[0].mirror().kind);
    try std.testing.expectEqualStrings("compacted context ~90000 -> ~20000 tokens", transcript.messages.items[0].mirror().body);
}

test "tool budget exhausted appends a budget notice row carrying the limit" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);
    var turn_view: TurnView = .{};
    defer turn_view.deinit(gpa);

    try std.testing.expect(try turn_view.apply(gpa, &transcript, .{ .tool_budget_exhausted = 40 }));
    try std.testing.expectEqual(@as(usize, 1), transcript.messages.items.len);
    // Amber attention row (`.notice`) — the stop needs user action, unlike
    // the neutral compaction `.info`.
    try std.testing.expectEqual(transcript_mod.MessageKind.notice, transcript.messages.items[0].mirror().kind);
    try std.testing.expectEqualStrings("budget", transcript.messages.items[0].mirror().title);
    try std.testing.expectEqualStrings(
        "tool-call budget reached (40 calls) — turn stopped early; send a message to continue",
        transcript.messages.items[0].mirror().body,
    );
}
