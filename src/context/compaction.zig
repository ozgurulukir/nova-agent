//! compaction.zig — the pure decisions behind automatic context compaction:
//! how big the model's context window is, WHEN the conversation is close
//! enough to full to compact, WHAT prefix to summarize, and HOW that prefix is
//! rendered for the summarizer.
//!
//! Everything here is a pure function of its inputs (boundary-discipline): no
//! threads, no I/O, no allocation beyond an explicit `gpa` for the serialized
//! prefix. The background orchestration (the second client, the worker thread,
//! the history swap) is layered on top of these in the runtime.

const std = @import("std");

const tools_common = @import("../tools/common.zig");
const ai = @import("../ai.zig");
/// Runtime models.dev registry — provides `ModelInfo` for capability lookups.
const modelsdev = @import("../models/registry.zig");

const assert = std.debug.assert;

/// Instruction sent to the summarizer (codex's CONTEXT CHECKPOINT COMPACTION
/// prompt). Combined with the rendered conversation in `buildSummaryRequest`.
pub const compaction_prompt = @embedFile("../prompts/compaction.md");

/// Minimal system prompt for the dedicated summarization client. The full
/// agent system prompt (project rules, skills, plugin prompts) is irrelevant
/// to summarization and on small-window models can push the summary request
/// itself over the limit (C4). Non-empty so codex_responses' init assert
/// passes. The instructions live in `compaction_prompt`, delivered as the
/// single user message — this prompt is only a carrier.
pub const summarizer_system_prompt =
    "You are a conversation summarizer. Follow the summarization instructions exactly.";

/// Handover template stored as the boundary message, so the resuming model
/// knows the summary came from a prior model (codex's summary_prefix). It
/// carries a `${SUMMARY}` placeholder that `buildStoredSummary` replaces with
/// the produced summary.
pub const handover_template = @embedFile("../prompts/handover.md");

/// Placeholder in `handover_template` where the summary is injected. Its
/// position is resolved at compile time; a build fails loudly if the template
/// ever loses the placeholder.
const summary_placeholder = "${SUMMARY}";
const summary_placeholder_index = std.mem.indexOf(u8, handover_template, summary_placeholder) orelse
    @compileError("prompts/handover.md must contain the " ++ summary_placeholder ++ " placeholder");

/// chars-per-token divisor for the size estimate used when a provider reports
/// no usage, and when choosing the cut point. Deliberately conservative (real
/// text is ~3.5–4 chars/token); overestimating tokens compacts slightly early,
/// which is the safe direction.
const tokens_per_char_divisor: u32 = 4;

/// Background summarization starts once the footprint crosses this fraction of
/// the window. Kicking off early gives the summary time to finish before it is
/// needed, so the swap is instant and the agent never blocks.
/// Configurable via `context.compaction.threshold` (default 0.75).
const start_watermark_default: f64 = 0.75;

/// The summary is swapped into history once the footprint crosses this higher
/// fraction. Derived from the start threshold: `threshold + 0.20`, capped at
/// 0.95. Started at the start watermark, the background summary is normally
/// ready by here.
const swap_watermark_margin: f64 = 0.20;
const swap_watermark_cap: f64 = 0.95;

/// Conservative fallback context window when the model id is unknown. Smaller
/// than most real windows on purpose — a low denominator only compacts early.
const context_window_default_tokens: u32 = 128_000;

/// Per-tool-result cap (in bytes) when rendering the prefix for the summarizer,
/// so a single huge command output cannot dominate the summary input.
const tool_output_render_cap_bytes: u32 = 2048;

/// Flat token estimate for an image block. Vision models price images by tile,
/// not by file size; base64 length / 4 overestimates a 5 MB image at ~1.7M
/// tokens (real cost: low thousands) and alone can push a session past the swap
/// watermark with nothing to cut. 1024 covers typical screenshots at common
/// tile pricing; the estimator is only used for watermark decisions, never
/// billing.
const image_estimate_tokens: u32 = 1_024;

/// Context window in tokens for the active model, from the runtime models.dev
/// registry, or a conservative default when the model is not in the registry.
/// When `override` is non-null it wins unconditionally (config-driven
/// `context.overrideContextWindow`).
///
/// When `model_info` is null (model not in the registry, or registry not loaded),
/// falls back to the conservative default — which only compacts early, the safe
/// direction. A model with `context_window = 0` (missing `limit` in api.json)
/// also falls back to the default.
pub fn contextWindowTokens(model_info: ?modelsdev.ModelInfo, override: ?u32) u32 {
    if (override) |v| return v;
    if (model_info) |m| {
        // A model with context_window = 0 (missing `limit` in api.json) falls
        // back to the conservative default — the safe direction (compacts early).
        if (m.context_window > 0) return m.context_window;
    }
    return context_window_default_tokens;
}

/// Whether the model supports reasoning, from the runtime models.dev registry.
/// Unknown models default to `false` — the safe direction, since the
/// reasoning-specific wire fields are only emitted when this is true.
pub fn isReasoningModel(model_info: ?modelsdev.ModelInfo) bool {
    if (model_info) |m| return m.reasoning;
    return false;
}

/// Target tokens of recent conversation to keep verbatim during compaction.
/// Scaled dynamically based on `context_window` so small-context models keep
/// a proportionate window and can always compact cleanly below their swap
/// watermark. `config_keep` is the user-configured ceiling
/// (`context.compaction.keepRecentTokens`, default 8 000).
pub fn keepRecentTokens(context_window: u32, config_keep: u32) u32 {
    if (context_window == 0) return config_keep;
    const target: u32 = @intCast(@as(u64, context_window) * 35 / 100);
    return @max(1000, @min(config_keep, target));
}

/// Scale the keep-recent budget by the ratio of the provider's real token
/// count to this estimator's, so languages where chars/4 undercounts
/// (CJK ≈ 1.5 chars/token) keep fewer messages and still compact below the
/// swap watermark (TD-6). Only ever shrinks the budget; falls back to
/// `base_keep` when either count is zero. Ratio clamped to [0.25, 2.0]
/// (×1000 fixed point).
pub fn calibrateKeepBudget(base_keep: u32, real_tokens: u32, estimated_tokens: u32) u32 {
    if (real_tokens == 0 or estimated_tokens == 0) return base_keep;
    const ratio_x1000 = @divFloor(@as(u64, real_tokens) * 1000, estimated_tokens);
    const clamped = @min(2000, @max(250, ratio_x1000)); // [0.25, 2.0]
    if (clamped <= 1000) return base_keep; // never grow
    const scaled = @as(u64, base_keep) * 1000 / clamped;
    return @max(1000, @as(u32, @intCast(scaled)));
}

/// True once `used_tokens` crosses the start watermark: begin producing the
/// background summary. `threshold` is the configurable fraction
/// (`context.compaction.threshold`, default 0.75). Accepted range [0.1, 0.90]:
/// anything above the ceiling (parse-clamped anyway) would let the swap
/// watermark fall at or below the start watermark (C3).
pub fn shouldStartSummary(used_tokens: u32, context_window: u32, threshold: f64) bool {
    assert(context_window > 0);
    const effective = if (threshold >= 0.1 and threshold <= 0.90) threshold else start_watermark_default;
    const limit: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(context_window)) * effective));
    return used_tokens > limit;
}

/// True once `used_tokens` crosses the swap watermark: install the background
/// summary. The swap watermark is `threshold + 0.20`, capped at 0.95.
pub fn shouldSwap(used_tokens: u32, context_window: u32, threshold: f64) bool {
    assert(context_window > 0);
    const effective = if (threshold >= 0.1 and threshold <= 0.90) threshold else start_watermark_default;
    const swap = @min(effective + swap_watermark_margin, swap_watermark_cap);
    const limit: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(context_window)) * swap));
    return used_tokens > limit;
}

/// Summarize `prefix_text` with `client`: one user message (instruction +
/// conversation) so it works across providers without relying on per-provider
/// system handling, taking only the model's text. Caller owns the result. Safe
/// to call off the main thread provided `client` is not the one driving the
/// live turn.
pub fn summarize(gpa: std.mem.Allocator, client: ai.LanguageModel, prefix_text: []const u8) ![]u8 {
    const request = try buildSummaryRequest(gpa, prefix_text);
    const blocks = gpa.alloc(ai.ContentBlock, 1) catch |err| {
        gpa.free(request);
        return err;
    };
    blocks[0] = .{ .text = .{ .text = request } };
    var message: ai.ChatMessage = .{ .user = .{ .content = blocks } };
    defer message.deinit(gpa);

    var turn = try client.prompt(&.{.{ .borrowed = &message }}, ai.streamNoop());
    defer turn.deinit(gpa);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (turn.assistant.assistant.content) |block| {
        if (block == .text) try out.appendSlice(gpa, block.text.text);
    }
    return out.toOwnedSlice(gpa);
}

/// Estimate the token cost of one message from the byte length of its content
/// (chars/4, rounded up). A fallback for when the provider omits usage and the
/// unit used to choose the cut point. Images estimate flat (TD-11).
pub fn estimateMessageTokens(message: ai.ChatMessage) u32 {
    const content: []const ai.ContentBlock = switch (message) {
        inline .system, .user, .assistant => |m| m.content,
        .tool => |t| t.content,
    };
    var tokens: u32 = 0;
    for (content) |block| {
        tokens +|= blockTokens(block);
    }
    return tokens;
}

/// Estimate the token cost of one message, capping each text block at
/// `cap_bytes` before counting. Used by the pruning-aware watermark estimator
/// (TD-9) so the estimate matches what the pruned request actually sends.
pub fn estimateMessageTokensCapped(message: ai.ChatMessage, cap_bytes: u32) u32 {
    const content: []const ai.ContentBlock = switch (message) {
        inline .system, .user, .assistant => |m| m.content,
        .tool => |t| t.content,
    };
    var tokens: u32 = 0;
    for (content) |block| {
        tokens +|= blockTokensCapped(block, cap_bytes);
    }
    return tokens;
}

fn blockTokens(block: ai.ContentBlock) u32 {
    return switch (block) {
        .text => |text| divCeil(saturatingLen(text.text), tokens_per_char_divisor),
        .reasoning => |reasoning| divCeil(saturatingLen(reasoning.text), tokens_per_char_divisor),
        .image => image_estimate_tokens,
        .tool_call => |call| divCeil(saturatingLen(call.name) +| saturatingLen(call.arguments), tokens_per_char_divisor),
    };
}

fn blockTokensCapped(block: ai.ContentBlock, cap_bytes: u32) u32 {
    return switch (block) {
        .text => |text| divCeil(@min(saturatingLen(text.text), cap_bytes), tokens_per_char_divisor),
        .reasoning => |reasoning| divCeil(@min(saturatingLen(reasoning.text), cap_bytes), tokens_per_char_divisor),
        .image => image_estimate_tokens,
        .tool_call => |call| divCeil(saturatingLen(call.name) +| saturatingLen(call.arguments), tokens_per_char_divisor),
    };
}

/// Index of the first message to keep verbatim. Messages before it are the
/// prefix to summarize; index 0 means everything fits and nothing should be
/// compacted. Three rules, applied in order by this parent so the leaves stay
/// branch-free:
///   1. keep the most recent `keep_recent_tokens` of messages,
///   2. pull the cut back to keep the most recent user message (the live
///      request) unless that would retain too much,
///   3. back up past a leading tool result so a kept `.tool` message never
///      loses the assistant tool-call it answers.
pub fn findCutIndex(messages: []const ai.ChatMessage, keep_recent_tokens: u32) u32 {
    assert(keep_recent_tokens > 0);
    var cut = cutByTokenBudget(messages, keep_recent_tokens);
    cut = keepRecentUserMessage(messages, cut, keep_recent_tokens *| 2);
    cut = avoidOrphanToolResult(messages, cut);
    return cut;
}

/// First index of the most-recent `keep_recent_tokens` of messages.
fn cutByTokenBudget(messages: []const ai.ChatMessage, keep_recent_tokens: u32) u32 {
    var index: u32 = @intCast(messages.len);
    var accumulated: u32 = 0;
    while (index > 0) {
        index -= 1;
        accumulated +|= estimateMessageTokens(messages[index]);
        if (accumulated >= keep_recent_tokens) break;
    }
    return index;
}

/// Pull `cut` back to the most recent user message so a large tool result can't
/// push the user's current request into the summary — unless keeping from there
/// would retain more than `kept_tokens_max` (a stale, long tool-only run still
/// compacts rather than being kept whole).
fn keepRecentUserMessage(messages: []const ai.ChatMessage, cut: u32, kept_tokens_max: u32) u32 {
    const last_user = lastUserIndex(messages) orelse return cut;
    if (last_user >= cut) return cut;
    var kept: u32 = 0;
    var index: usize = last_user;
    while (index < messages.len) : (index += 1) {
        kept +|= estimateMessageTokens(messages[index]);
    }
    if (kept > kept_tokens_max) return cut;
    return last_user;
}

/// Back `cut` up past a leading tool result so the kept window never starts on
/// a `.tool` message orphaned from its assistant tool-call.
fn avoidOrphanToolResult(messages: []const ai.ChatMessage, cut: u32) u32 {
    var index = cut;
    while (index > 0 and messages[index] == .tool) {
        index -= 1;
    }
    return index;
}

fn lastUserIndex(messages: []const ai.ChatMessage) ?u32 {
    var index: u32 = @intCast(messages.len);
    while (index > 0) {
        index -= 1;
        if (messages[index] == .user) return index;
    }
    return null;
}

/// Render `messages` as plain role-tagged text for the summarizer. Text is kept
/// in full; reasoning blocks are dropped (they are not load-bearing once a turn
/// is summarized); tool calls render as `name(args)`; tool results are capped
/// at `tool_output_render_cap_bytes` so one large output cannot dominate. The
/// result is the user content of the compaction request. Caller owns it.
pub fn serializePrefix(gpa: std.mem.Allocator, messages: []const ai.ChatMessage) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (messages) |message| {
        try writeMessage(gpa, &out.writer, message);
    }
    return out.toOwnedSlice();
}

fn writeMessage(gpa: std.mem.Allocator, out: *std.Io.Writer, message: ai.ChatMessage) !void {
    switch (message) {
        .tool => |t| {
            // Sandwich the tool result so the summarizer sees the conclusion
            // (tail), not just the start — head-only truncation dropped errors
            // and results, so a compacted summary lost them.
            const rendered = try cappedToolResult(gpa, firstText(t.content));
            defer gpa.free(rendered);
            try out.print("[tool result]: {s}\n", .{rendered});
        },
        inline .system, .user, .assistant => |m| {
            const label: []const u8 = switch (message) {
                .system => "system",
                .user => "user",
                .assistant => "assistant",
                .tool => unreachable,
            };
            for (m.content) |block| {
                switch (block) {
                    .text => |text| try out.print("[{s}]: {s}\n", .{ label, text.text }),
                    .tool_call => |call| try out.print("[{s} tool_call]: {s}({s})\n", .{ label, call.name, cappedText(call.arguments) }),
                    // Images vanish without a marker today; leave an explicit
                    // placeholder so the summary keeps a positional hint (M6).
                    .image => |image| {
                        _ = image;
                        try out.print("[{s} image omitted]\n", .{label});
                    },
                    .reasoning => {},
                }
            }
        },
    }
}

fn firstText(content: []const ai.ContentBlock) []const u8 {
    for (content) |block| {
        if (block == .text) return block.text.text;
    }
    return "";
}

/// Head-only cap for tool-call ARGUMENTS in the summarizer render. Unlike
/// tool RESULTS (which get a head+tail sandwich via `cappedToolResult` because
/// their load-bearing conclusion lives at the tail), arguments are the model's
/// INPUT to a tool — their start carries the intent and they rarely have a
/// meaningful tail, so head-only is correct here.
fn cappedText(text: []const u8) []const u8 {
    if (text.len <= tool_output_render_cap_bytes) return text;
    return text[0..tool_output_render_cap_bytes];
}

/// Render a tool result for the summarizer as a head+tail sandwich. Thin
/// wrapper over the shared `common.pruneToolText` at this module's render cap.
fn cappedToolResult(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    return tools_common.pruneToolText(gpa, text, tool_output_render_cap_bytes);
}

/// Build the summarizer's user content: the compaction instruction followed by
/// the rendered conversation, wrapped so the model treats it as data to
/// summarize rather than a conversation to continue. Caller owns the result.
pub fn buildSummaryRequest(gpa: std.mem.Allocator, prefix_text: []const u8) ![]u8 {
    // `<nova_transcript>` framing rather than `<conversation>`: a literal
    // `</conversation>` inside tool output (common) would break the wrapper;
    // `nova_transcript` is far rarer in user text (M6).
    return std.fmt.allocPrint(gpa, "{s}\n\n<nova_transcript>\n{s}\n</nova_transcript>", .{ compaction_prompt, prefix_text });
}

/// Inject a produced summary into the handover template's `${SUMMARY}`
/// placeholder, yielding the boundary message stored in the tree. Caller owns
/// the result.
pub fn buildStoredSummary(gpa: std.mem.Allocator, summary: []const u8) ![]u8 {
    assert(summary.len > 0);
    const before = handover_template[0..summary_placeholder_index];
    const after = handover_template[summary_placeholder_index + summary_placeholder.len ..];
    return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ before, summary, after });
}

/// The inner summary text without the handover template's framing, so
/// repeated compactions don't accumulate boilerplate (M7). Returns the input
/// unchanged when the framing tags are absent.
pub fn stripSummaryFraming(text: []const u8) []const u8 {
    const open = std.mem.indexOf(u8, text, "<summary>") orelse return text;
    const close = std.mem.lastIndexOf(u8, text, "</summary>") orelse return text;
    if (close <= open) return text;
    return std.mem.trim(u8, text[open + "<summary>".len .. close], " \n\r");
}

fn saturatingLen(slice: []const u8) u32 {
    if (slice.len > std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(slice.len);
}

fn divCeil(numerator: u32, denominator: u32) u32 {
    assert(denominator > 0);
    return (numerator + denominator - 1) / denominator;
}

test "contextWindowTokens uses model info with override and default fallback" {
    // Unknown/null model falls back to the conservative default.
    try std.testing.expectEqual(context_window_default_tokens, contextWindowTokens(null, null));
    // A known model resolves to its context window.
    const m: modelsdev.ModelInfo = .{ .id = "gpt-5", .reasoning = true, .context_window = 400_000 };
    try std.testing.expectEqual(@as(u32, 400_000), contextWindowTokens(m, null));
    // Override wins unconditionally.
    try std.testing.expectEqual(@as(u32, 32_000), contextWindowTokens(m, 32_000));
    // Override wins even when model_info is null.
    try std.testing.expectEqual(@as(u32, 32_000), contextWindowTokens(null, 32_000));
}

test "isReasoningModel uses model info with false default" {
    const reasoning: modelsdev.ModelInfo = .{ .id = "gpt-5", .reasoning = true, .context_window = 400_000 };
    const non_reasoning: modelsdev.ModelInfo = .{ .id = "gpt-4o", .reasoning = false, .context_window = 128_000 };
    try std.testing.expect(isReasoningModel(reasoning));
    try std.testing.expect(!isReasoningModel(non_reasoning));
    // Unknown models default to false (the safe direction).
    try std.testing.expect(!isReasoningModel(null));
}

test "summary starts at the threshold and swaps at threshold + margin" {
    const window: u32 = 100_000;
    // Default threshold 0.75 → start at 75_000, swap at 95_000.
    try std.testing.expect(!shouldStartSummary(75_000, window, 0.75));
    try std.testing.expect(shouldStartSummary(75_001, window, 0.75));
    try std.testing.expect(!shouldStartSummary(0, window, 0.75));
    // Swap = 0.75 + 0.20 = 0.95 → 95_000.
    try std.testing.expect(!shouldSwap(95_000, window, 0.75));
    try std.testing.expect(shouldSwap(95_001, window, 0.75));
    try std.testing.expect(!shouldSwap(80_000, window, 0.75));
}

test "summary watermarks respect custom threshold" {
    const window: u32 = 100_000;
    // threshold 0.70 → start at 70_000, swap at 90_000 (old behavior).
    try std.testing.expect(!shouldStartSummary(70_000, window, 0.70));
    try std.testing.expect(shouldStartSummary(70_001, window, 0.70));
    try std.testing.expect(!shouldSwap(90_000, window, 0.70));
    try std.testing.expect(shouldSwap(90_001, window, 0.70));
}

test "estimate message tokens from content bytes" {
    const gpa = std.testing.allocator;
    var message = try textMessage(gpa, .user, "12345678"); // 8 bytes -> 2 tokens
    defer message.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), estimateMessageTokens(message));
}

test "cut index keeps recent budget and never orphans a tool result" {
    const gpa = std.testing.allocator;
    // 4 messages, each ~25 tokens (100 bytes). keep_recent of 60 tokens keeps
    // the last 3 (75 tokens >= 60 reached at index 1).
    var messages: [4]ai.ChatMessage = undefined;
    messages[0] = try textMessage(gpa, .user, "u" ** 100);
    messages[1] = try textMessage(gpa, .assistant, "a" ** 100);
    messages[2] = try toolMessage(gpa, "t" ** 100);
    messages[3] = try textMessage(gpa, .assistant, "b" ** 100);
    defer for (&messages) |*m| m.deinit(gpa);

    const cut = findCutIndex(&messages, 60);
    // Reached budget at index 1, which is the assistant — not a tool result —
    // so the kept window does not start on an orphaned tool result.
    try std.testing.expect(cut <= 1);
    try std.testing.expect(messages[cut] != .tool);
}

test "stored summary injects into the handover placeholder" {
    const gpa = std.testing.allocator;
    const stored = try buildStoredSummary(gpa, "GOAL: ship it");
    defer gpa.free(stored);

    // The summary replaces the placeholder (which is gone), inside the tags.
    try std.testing.expect(std.mem.indexOf(u8, stored, summary_placeholder) == null);
    try std.testing.expect(std.mem.indexOf(u8, stored, "GOAL: ship it") != null);
    const open = std.mem.indexOf(u8, stored, "<summary>").?;
    const body = std.mem.indexOf(u8, stored, "GOAL: ship it").?;
    const close = std.mem.indexOf(u8, stored, "</summary>").?;
    try std.testing.expect(open < body);
    try std.testing.expect(body < close);
}

test "cut keeps a recent user message a large tool result pushed out of the tail" {
    const gpa = std.testing.allocator;
    // old assistant turn, then the user's current ask, then a large tool result
    // that alone fills the keep-recent budget and would otherwise exclude the ask.
    var messages: [3]ai.ChatMessage = undefined;
    messages[0] = try textMessage(gpa, .assistant, "z" ** 400); // ~100 tokens
    messages[1] = try textMessage(gpa, .user, "current ask"); // ~3 tokens
    messages[2] = try toolMessage(gpa, "x" ** 400); // ~100 tokens
    defer for (&messages) |*m| m.deinit(gpa);

    // budget 80 keeps only the tool (100t); the user ask sits just before it.
    const cut = findCutIndex(&messages, 80);
    try std.testing.expectEqual(@as(u32, 1), cut); // pulled back to the user ask
    try std.testing.expect(messages[cut] == .user);
}

test "cut does not force-keep an ancient user message behind heavy tool output" {
    const gpa = std.testing.allocator;
    // one old user ask, then heavy assistant output far exceeding the extend cap.
    var messages: [3]ai.ChatMessage = undefined;
    messages[0] = try textMessage(gpa, .user, "old ask"); // ~2 tokens
    messages[1] = try textMessage(gpa, .assistant, "x" ** 2000); // ~500 tokens
    messages[2] = try textMessage(gpa, .assistant, "y" ** 2000); // ~500 tokens
    defer for (&messages) |*m| m.deinit(gpa);

    // budget 300, extend cap 600; keeping from the user ask would retain ~1002.
    const cut = findCutIndex(&messages, 300);
    try std.testing.expect(cut > 0); // the ancient ask is summarized, not kept
}

test "serialize prefix drops reasoning and tags roles" {
    const gpa = std.testing.allocator;
    var user = try textMessage(gpa, .user, "hello");
    defer user.deinit(gpa);
    var tool = try toolMessage(gpa, "output");
    defer tool.deinit(gpa);

    const text = try serializePrefix(gpa, &.{ user, tool });
    defer gpa.free(text);
    try std.testing.expectEqualStrings("[user]: hello\n[tool result]: output\n", text);
}

test "keepRecentTokens returns config_keep when context_window is zero" {
    try std.testing.expectEqual(@as(u32, 8_000), keepRecentTokens(0, 8_000));
    try std.testing.expectEqual(@as(u32, 500), keepRecentTokens(0, 500));
}

test "keepRecentTokens enforces minimum floor of 1000 tokens for small context windows" {
    // 35% of 2,000 = 700 tokens, which is below floor -> returns 1,000
    try std.testing.expectEqual(@as(u32, 1_000), keepRecentTokens(2_000, 8_000));
    // 35% of 1,000 = 350 tokens -> returns 1,000
    try std.testing.expectEqual(@as(u32, 1_000), keepRecentTokens(1_000, 8_000));
}

test "keepRecentTokens scales proportionally at 35 percent of context window" {
    // 35% of 32,000 = 11,200
    try std.testing.expectEqual(@as(u32, 11_200), keepRecentTokens(32_000, 20_000));
    // 35% of 16,000 = 5,600
    try std.testing.expectEqual(@as(u32, 5_600), keepRecentTokens(16_000, 20_000));
    // 35% of 8,000 = 2,800
    try std.testing.expectEqual(@as(u32, 2_800), keepRecentTokens(8_000, 20_000));
}

test "keepRecentTokens clamps to config_keep ceiling" {
    // 35% of 200,000 = 70,000, capped at config_keep (8,000 or 20,000)
    try std.testing.expectEqual(@as(u32, 20_000), keepRecentTokens(200_000, 20_000));
    try std.testing.expectEqual(@as(u32, 8_000), keepRecentTokens(200_000, 8_000));
    try std.testing.expectEqual(@as(u32, 8_000), keepRecentTokens(32_000, 8_000));
}

test "keepRecentTokens handles config_keep smaller than minimum floor" {
    // When config_keep is 500 and target (35% of 2000) is 700: min(500, 700) = 500, max(1000, 500) = 1000
    try std.testing.expectEqual(@as(u32, 1_000), keepRecentTokens(2_000, 500));
}

test "contextWindowTokens is pure — same ModelInfo yields same result" {
    const m: modelsdev.ModelInfo = .{ .id = "gpt-4o", .reasoning = false, .context_window = 128_000 };
    const tokens1 = contextWindowTokens(m, null);
    const tokens2 = contextWindowTokens(m, null);
    try std.testing.expectEqual(tokens1, tokens2);
}

test "summarizer system prompt is non-empty and small" {
    // Non-empty so codex_responses' init assert passes; small so it can't push
    // the summary request itself over a small context window (C4).
    try std.testing.expect(summarizer_system_prompt.len > 0);
    try std.testing.expect(summarizer_system_prompt.len <= 200);
}

test "swap never fires before start for every accepted threshold" {
    // Non-circular oracle: sweep every accepted threshold × window × usage and
    // assert shouldSwap(used) ⇒ shouldStartSummary(used). This encodes the
    // ordering directly, without recomputing the watermark formula (C3).
    const windows = [_]u32{ 8_000, 32_000, 128_000, 1_000_000 };
    var threshold_tenths: u32 = 2; // 0.10
    while (threshold_tenths <= 18) : (threshold_tenths += 1) { // ... 0.90
        const threshold: f64 = @as(f64, @floatFromInt(threshold_tenths)) / 20.0;
        for (windows) |window| {
            const step = @max(@as(u32, 1), window / 1000);
            var used: u32 = 0;
            while (used < window) : (used +|= step) {
                if (shouldSwap(used, window, threshold)) {
                    try std.testing.expect(shouldStartSummary(used, window, threshold));
                }
            }
        }
    }
}

test "calibrated keep budget shrinks when real usage outruns the estimate" {
    // ratio 1.6 → budget scaled down 8000 / 1.6 = 5000.
    try std.testing.expectEqual(@as(u32, 5_000), calibrateKeepBudget(8_000, 16_000, 10_000));
    // ratio clamped to 2.0 → 8000 / 2.0 = 4000.
    try std.testing.expectEqual(@as(u32, 4_000), calibrateKeepBudget(8_000, 100_000, 1_000));
    // ratio below 1.0 never grows the budget.
    try std.testing.expectEqual(@as(u32, 8_000), calibrateKeepBudget(8_000, 100, 10_000));
    // Zero counts fall back to the base budget.
    try std.testing.expectEqual(@as(u32, 8_000), calibrateKeepBudget(8_000, 0, 0));
    // The 1000-token floor applies for tiny scaled budgets.
    try std.testing.expectEqual(@as(u32, 1_000), calibrateKeepBudget(1_200, 4_000, 1_000));
}

test "contextWindowTokens respects override over model info" {
    // Override always wins, regardless of the model's context window.
    const m: modelsdev.ModelInfo = .{ .id = "gpt-4", .reasoning = false, .context_window = 8_192 };
    try std.testing.expectEqual(@as(u32, 8_192), contextWindowTokens(m, null));
    try std.testing.expectEqual(@as(u32, 400_000), contextWindowTokens(m, 400_000));
}

test "folded summary strips the handover framing" {
    const gpa = std.testing.allocator;
    const stored = try buildStoredSummary(gpa, "INNER");
    defer gpa.free(stored);
    try std.testing.expectEqualStrings("INNER", stripSummaryFraming(stored));
    // Text without framing passes through unchanged.
    try std.testing.expectEqualStrings("plain", stripSummaryFraming("plain"));
}

test "serialize prefix marks omitted images" {
    const gpa = std.testing.allocator;
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .image = .{
        .mime_type = try gpa.dupe(u8, "image/png"),
        .data_base64 = try gpa.dupe(u8, "aGVsbG8="),
    } };
    var message: ai.ChatMessage = .{ .user = .{ .content = blocks } };
    defer message.deinit(gpa); // frees the blocks array too

    const text = try serializePrefix(gpa, &.{message});
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "[user image omitted]") != null);
}

test "cappedToolResult keeps the conclusion tail for the summarizer" {
    const gpa = std.testing.allocator;

    // A tool result whose load-bearing conclusion lives at the tail (e.g. a
    // build/test run ending in "error: failed"). Head-only truncation dropped
    // the tail, so a compacted summary lost the failure; the sandwich must
    // keep both the start and the conclusion.
    const head_marker = "HEAD";
    const tail_marker = "TAIL: error: failed to compile store.go";
    const big = "x" ** (tool_output_render_cap_bytes + 1000);
    const obs = try std.fmt.allocPrint(gpa, "{s}{s}\n{s}", .{ head_marker, big, tail_marker });
    defer gpa.free(obs);

    const rendered = try cappedToolResult(gpa, obs);
    defer gpa.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, tail_marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, head_marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "elided to save context") != null);
}

test "serializePrefix caps tool call arguments like tool results" {
    const gpa = std.testing.allocator;
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .tool_call = .{
        .call_id = .{ .value = try gpa.dupe(u8, "c1") },
        .name = try gpa.dupe(u8, "write"),
        .arguments = try gpa.dupe(u8, "x" ** 5000),
    } };
    var message: ai.ChatMessage = .{ .assistant = .{ .content = blocks } };
    defer message.deinit(gpa);

    const text = try serializePrefix(gpa, &.{message});
    defer gpa.free(text);
    // The arguments are capped at tool_output_render_cap_bytes.
    const call_at = std.mem.indexOf(u8, text, "[assistant tool_call]: write(").?;
    const args_start = call_at + "[assistant tool_call]: write(".len;
    const args_len = text.len - args_start - 2; // minus the trailing ")\n"
    try std.testing.expectEqual(@as(usize, tool_output_render_cap_bytes), args_len);
}

test "image token estimate is flat regardless of base64 size" {
    const gpa = std.testing.allocator;

    const small_blocks = try gpa.alloc(ai.ContentBlock, 1);
    small_blocks[0] = .{ .image = .{
        .mime_type = try gpa.dupe(u8, "image/png"),
        .data_base64 = try gpa.dupe(u8, "aGVsbG8="),
    } };
    var small: ai.ChatMessage = .{ .user = .{ .content = small_blocks } };
    defer small.deinit(gpa);

    const big_blocks = try gpa.alloc(ai.ContentBlock, 1);
    big_blocks[0] = .{ .image = .{
        .mime_type = try gpa.dupe(u8, "image/png"),
        .data_base64 = try gpa.dupe(u8, "x" ** (5 * 1024 * 1024)),
    } };
    var big: ai.ChatMessage = .{ .user = .{ .content = big_blocks } };
    defer big.deinit(gpa);

    // A 10-byte and a 5 MB base64 image estimate identically.
    try std.testing.expectEqual(estimateMessageTokens(small), estimateMessageTokens(big));
    try std.testing.expectEqual(@as(u32, image_estimate_tokens), estimateMessageTokens(small));
}

fn textMessage(gpa: std.mem.Allocator, role: ai.Role, text: []const u8) !ai.ChatMessage {
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    errdefer gpa.free(blocks);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, text) } };
    return switch (role) {
        .system => .{ .system = .{ .content = blocks } },
        .user => .{ .user = .{ .content = blocks } },
        .assistant => .{ .assistant = .{ .content = blocks } },
        .tool => error.InvalidToolRole,
    };
}

fn toolMessage(gpa: std.mem.Allocator, text: []const u8) !ai.ChatMessage {
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    errdefer gpa.free(blocks);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, text) } };
    return .{ .tool = .{ .call_id = .{ .value = try gpa.dupe(u8, "c1") }, .content = blocks } };
}

test "shouldStartSummary_returnsTrue_whenUsedTokensExceedsLimit" {
    // Arrange
    const context_window: u32 = 100_000;
    const threshold: f64 = 0.75; // limit = 75_000
    const used_tokens: u32 = 75_001;

    // Act
    const result = shouldStartSummary(used_tokens, context_window, threshold);

    // Assert
    try std.testing.expect(result);
}

test "shouldStartSummary_returnsFalse_whenUsedTokensAtOrBelowLimit" {
    // Arrange
    const context_window: u32 = 100_000;
    const threshold: f64 = 0.75; // limit = 75_000

    // Act
    const result_exact = shouldStartSummary(75_000, context_window, threshold);
    const result_zero = shouldStartSummary(0, context_window, threshold);
    const result_below = shouldStartSummary(50_000, context_window, threshold);

    // Assert
    try std.testing.expect(!result_exact);
    try std.testing.expect(!result_zero);
    try std.testing.expect(!result_below);
}

test "shouldStartSummary_fallsBackToDefault_whenThresholdOutOfBounds" {
    // Arrange
    const context_window: u32 = 100_000; // default threshold 0.75 => limit = 75_000
    const low_threshold: f64 = 0.05; // < 0.10
    const high_threshold: f64 = 0.95; // > 0.90

    // Act
    const result_low_below = shouldStartSummary(75_000, context_window, low_threshold);
    const result_low_above = shouldStartSummary(75_001, context_window, low_threshold);
    const result_high_below = shouldStartSummary(75_000, context_window, high_threshold);
    const result_high_above = shouldStartSummary(75_001, context_window, high_threshold);

    // Assert
    try std.testing.expect(!result_low_below);
    try std.testing.expect(result_low_above);
    try std.testing.expect(!result_high_below);
    try std.testing.expect(result_high_above);
}

test "shouldStartSummary_handlesBoundaryThresholdsCorrectly" {
    // Arrange
    const context_window: u32 = 100_000;
    const min_threshold: f64 = 0.10; // limit = 10_000
    const max_threshold: f64 = 0.90; // limit = 90_000

    // Act & Assert min_threshold
    try std.testing.expect(!shouldStartSummary(10_000, context_window, min_threshold));
    try std.testing.expect(shouldStartSummary(10_001, context_window, min_threshold));

    // Act & Assert max_threshold
    try std.testing.expect(!shouldStartSummary(90_000, context_window, max_threshold));
    try std.testing.expect(shouldStartSummary(90_001, context_window, max_threshold));
}
