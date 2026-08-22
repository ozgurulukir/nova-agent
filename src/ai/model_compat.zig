//! Model- and dialect-compatibility quirks shared by both wire clients
//! (`openai_request.zig` for chat-completions, `responses_request.zig` for
//! the Responses API).
//!
//! Extracted from `openai_compatible.zig` so the Responses serializer can
//! reach the clipping rules without importing the chat-completions client.
//! Two independent layers live here and must never be folded together:
//! `wireEffortLabel` is the **dialect** layer, `clipEffortForModel` is the
//! **model** layer — callers compose them as
//! `clipEffortForModel(model, wireEffortLabel(dialect, effort))`.

const std = @import("std");

const ai = @import("../ai.zig");

/// Result of `normalizeMessagesForQwen`: the (possibly rebuilt) message list
/// plus a `rebuilt` flag the caller passes to `deinitNormalizedMessages` so the
/// owned system block is only freed when we actually allocated one.
pub const NormalizedMessages = struct {
    list: std.ArrayListUnmanaged(ai.ChatMessage),
    rebuilt: bool,
};

/// Qwen / DashScope rejects requests whose message history contains more than
/// one `system` message, or whose `system` message is not the very first entry
/// (HTTP 400: "System message must be at the beginning"). OpenAI and most
/// OpenAI-compatible servers tolerate multiple/late system messages, but Qwen's
/// Jinja chat template enforces a single leading system block. This normalizes
/// the message array for the DashScope dialect: all `system` messages are merged
/// into one (joined by a blank line) and hoisted to the front.
///
/// When no normalization is needed the returned list is a shallow copy sharing
/// the caller's message storage (`rebuilt = false`); otherwise it owns a merged
/// system block (`rebuilt = true`). Free with `deinitNormalizedMessages`.
pub fn normalizeMessagesForQwen(
    gpa: std.mem.Allocator,
    messages: []const ai.MessageView,
) !NormalizedMessages {
    // Fast path: zero or one system message already at index 0.
    var system_count: u32 = 0;
    for (messages) |view| {
        if (view.message().* == .system) system_count += 1;
    }
    if (system_count <= 1 and (messages.len == 0 or messages[0].message().* == .system)) {
        var passthrough: std.ArrayListUnmanaged(ai.ChatMessage) = .empty;
        for (messages) |view| try passthrough.append(gpa, view.message().*);
        return .{ .list = passthrough, .rebuilt = false };
    }

    // Need a rebuild: merged system first, then all non-system messages in order.
    var result: std.ArrayListUnmanaged(ai.ChatMessage) = .empty;
    errdefer result.deinit(gpa);

    // Merge every system message's text blocks into one content buffer.
    var merged: std.ArrayListUnmanaged(u8) = .empty;
    defer merged.deinit(gpa);
    for (messages) |view| {
        const m = view.message().*;
        if (m != .system) continue;
        if (merged.items.len > 0) try merged.append(gpa, '\n');
        for (m.system.content) |block| {
            if (block == .text) try merged.appendSlice(gpa, block.text.text);
        }
    }
    if (merged.items.len > 0) {
        const owned = try gpa.dupe(u8, merged.items);
        errdefer gpa.free(owned);
        const block = ai.ContentBlock{ .text = .{ .text = owned } };
        const content = try gpa.dupe(ai.ContentBlock, &.{block});
        errdefer gpa.free(content);
        try result.append(gpa, ai.ChatMessage{ .system = .{ .content = content } });
    }

    // Append all non-system messages, preserving order.
    for (messages) |view| {
        const m = view.message().*;
        if (m == .system) continue;
        try result.append(gpa, m);
    }
    return .{ .list = result, .rebuilt = true };
}

/// Free a normalized message list returned by `normalizeMessagesForQwen`.
/// Only frees the owned system block when the list was rebuilt (the caller
/// passes `rebuilt` to indicate that); the passthrough path shares ownership
/// with the caller's input and frees nothing extra.
pub fn deinitNormalizedMessages(gpa: std.mem.Allocator, list: std.ArrayListUnmanaged(ai.ChatMessage), rebuilt: bool) void {
    if (!rebuilt) {
        var mut = list;
        mut.deinit(gpa);
        return;
    }
    // The rebuilt list owns exactly one merged system block (allocated here).
    // Non-system entries are borrowed from the caller's input and must not be
    // freed. Free only the system content buffer, then the slice.
    for (list.items) |*m| {
        if (m.* == .system) {
            const sys = &m.system;
            const block = &sys.content[0];
            gpa.free(block.text.text);
            gpa.free(sys.content);
        }
    }
    var mut_list = list;
    mut_list.deinit(gpa);
}

/// Resolve a reasoning effort to the wire label for the given dialect, or `null`
/// when the parameter should be omitted entirely (the `default` level means
/// "don't override the model's behaviour").
///
/// This is the **dialect** layer only: it knows how each wire format names and
/// accepts effort values. It deliberately knows nothing about which model is
/// being served — model-specific constraints (e.g. Qwen rejecting `high`/`max`)
/// live in `clipEffortForModel`, and the caller composes the two.
///
/// Ollama's `/v1/chat/completions` validates `reasoning_effort` strictly: only
/// `high`/`medium`/`low`/`max`/`none` are accepted. Sending `xhigh` or `minimal`
/// returns HTTP 400 (`"invalid reasoning value"`), and both values are reachable
/// via the global picker list (the Ollama Cloud builtin declares no per-model
/// `reasoning_options`), so the `.minimal` dialect — used by Ollama Cloud, local
/// Ollama, Groq, vLLM, etc. — rewrites each to the nearest accepted value. The
/// OpenAI-native dialect keeps raw labels (gpt-5 honours `xhigh`/`max`;
/// `minimal` is valid there).
pub fn wireEffortLabel(dialect: ai.WireDialect, effort: ai.ReasoningEffort) ?[]const u8 {
    return switch (effort) {
        .default => null, // omit the parameter entirely
        // Ollama's minimal dialect rejects `xhigh`/`minimal`; map each to the
        // nearest value its validator accepts.
        .xhigh => if (dialect == .minimal) "max" else effort.label(),
        .minimal => if (dialect == .minimal) "low" else effort.label(),
        else => effort.label(),
    };
}

/// Qwen model-id gate shared by the effort clip and the message normalizer.
/// Matches every id style: DashScope (`qwen3-8-27b`), Ollama (`qwen2.5:7b`),
/// OpenRouter (`qwen/qwen3-...`) and HuggingFace/vLLM (`Qwen/Qwen3-32B`,
/// `QwQ-32B`). Case-insensitive because HF org ids are capitalized — a
/// byte-level `startsWith` would miss exactly the vLLM-hosted Qwens whose Jinja
/// template enforces a single leading system message.
pub fn isQwenModel(model: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(model, "qwen") or std.ascii.startsWithIgnoreCase(model, "qwq");
}

/// The **model** layer: clip an already-dialect-resolved effort label to what the
/// model accepts. Knows nothing about wire dialects — it only encodes per-model
/// constraints. Qwen / DashScope rejects `high`, `max`, and `minimal` (HTTP 400),
/// keeping only `low`/`medium`/`none`/`xhigh`. A `null` input (dialect omitted
/// the field) stays `null`.
pub fn clipEffortForModel(model: []const u8, label: ?[]const u8) ?[]const u8 {
    if (!isQwenModel(model)) return label;
    const l = label orelse return null;
    // Qwen-valid effort set: low/medium/none/xhigh. Map the rejected levels
    // to the nearest valid one.
    if (std.mem.eql(u8, l, "high") or std.mem.eql(u8, l, "max")) return "medium";
    if (std.mem.eql(u8, l, "minimal")) return "low";
    return l; // low / medium / none / xhigh — already valid for Qwen
}

// Dialect layer only: wireEffortLabel knows nothing about models. The `.dashscope`
// dialect does NOT clip on its own (that constraint belongs to the model layer);
// `.minimal` (Ollama) rewrites the two labels its strict validator rejects:
// `xhigh` -> `max` and `minimal` -> `low`.
test "wireEffortLabel is dialect-only (no model awareness)" {
    // .dashscope: raw labels passthrough (model layer handles Qwen constraints).
    try std.testing.expectEqualStrings("high", wireEffortLabel(.dashscope, .high).?);
    try std.testing.expectEqualStrings("max", wireEffortLabel(.dashscope, .max).?);
    try std.testing.expectEqualStrings("minimal", wireEffortLabel(.dashscope, .minimal).?);
    try std.testing.expectEqualStrings("xhigh", wireEffortLabel(.dashscope, .xhigh).?);
    // .minimal: xhigh -> max and minimal -> low (Ollama's strict validator);
    // the labels it accepts pass through untouched.
    try std.testing.expectEqualStrings("high", wireEffortLabel(.minimal, .high).?);
    try std.testing.expectEqualStrings("max", wireEffortLabel(.minimal, .max).?);
    try std.testing.expectEqualStrings("max", wireEffortLabel(.minimal, .xhigh).?);
    try std.testing.expectEqualStrings("low", wireEffortLabel(.minimal, .minimal).?);
    // .default is always omitted (null) on every dialect.
    try std.testing.expectEqual(@as(?[]const u8, null), wireEffortLabel(.dashscope, .default));
    try std.testing.expectEqual(@as(?[]const u8, null), wireEffortLabel(.minimal, .default));
}

// Model layer only: clipEffortForModel knows nothing about dialects. It clips a
// resolved label to the Qwen-valid set; non-Qwen models are untouched.
test "clipEffortForModel is model-only (no dialect awareness)" {
    // Non-Qwen: every label passes through unchanged (including rejected ones).
    try std.testing.expectEqualStrings("high", clipEffortForModel("gpt-5", "high").?);
    try std.testing.expectEqualStrings("minimal", clipEffortForModel("llama3", "minimal").?);
    // Qwen: high/max -> medium, minimal -> low, xhigh/low/medium/none unchanged.
    try std.testing.expectEqualStrings("medium", clipEffortForModel("qwen3-8-27b", "high").?);
    try std.testing.expectEqualStrings("medium", clipEffortForModel("qwen2.5:7b", "max").?);
    try std.testing.expectEqualStrings("low", clipEffortForModel("qwq-32b", "minimal").?);
    try std.testing.expectEqualStrings("xhigh", clipEffortForModel("qwen2.5:7b", "xhigh").?);
    // The gate is case-insensitive so HuggingFace/vLLM org-style ids match —
    // `Qwen/Qwen3-32B` is the exact id shape from vllm-project/vllm#41114.
    try std.testing.expect(isQwenModel("Qwen/Qwen3-32B"));
    try std.testing.expect(isQwenModel("QwQ-32B"));
    try std.testing.expect(isQwenModel("qwen2.5:7b"));
    try std.testing.expect(!isQwenModel("llama3"));
    try std.testing.expect(!isQwenModel("gpt-5"));
    // null (dialect omitted the field) stays null for any model.
    try std.testing.expectEqual(@as(?[]const u8, null), clipEffortForModel("qwen3-8-27b", null));
}

// Composition: the caller combines the two layers. Ollama (`.minimal`) serving
// Qwen must clip `high` -> `medium` (dialect passes `high` through, model layer
// then clips it) and `xhigh` -> `medium` (dialect rewrites to `max` first, then
// the model layer clips `max`). A non-Qwen model on the same `.minimal` dialect
// keeps `high` and gets the dialect-only `minimal` -> `low` rewrite.
test "compose wireEffortLabel + clipEffortForModel (ollama + qwen)" {
    const qwen_on_ollama = clipEffortForModel("qwen2.5:7b", wireEffortLabel(.minimal, .high));
    try std.testing.expectEqualStrings("medium", qwen_on_ollama.?);
    const qwen_xhigh_ollama = clipEffortForModel("qwen2.5:7b", wireEffortLabel(.minimal, .xhigh));
    try std.testing.expectEqualStrings("medium", qwen_xhigh_ollama.?);
    const qwen_minimal_ollama = clipEffortForModel("qwen2.5:7b", wireEffortLabel(.minimal, .minimal));
    try std.testing.expectEqualStrings("low", qwen_minimal_ollama.?);
    const nonqwen_on_ollama = clipEffortForModel("llama3", wireEffortLabel(.minimal, .high));
    try std.testing.expectEqualStrings("high", nonqwen_on_ollama.?);
    // Regression: the dialect layer's own `minimal` -> `low` rewrite must still
    // apply to non-Qwen models (Ollama rejects `minimal` for every model).
    const nonqwen_minimal_ollama = clipEffortForModel("llama3", wireEffortLabel(.minimal, .minimal));
    try std.testing.expectEqualStrings("low", nonqwen_minimal_ollama.?);
    const qwen_on_dashscope = clipEffortForModel("qwen3-8-27b", wireEffortLabel(.dashscope, .max));
    try std.testing.expectEqualStrings("medium", qwen_on_dashscope.?);
}

test "normalizeMessagesForQwen merges multiple system messages and hoists to front" {
    const gpa = std.testing.allocator;
    const sys1 = ai.ChatMessage{ .system = .{ .content = try gpa.dupe(ai.ContentBlock, &.{ai.ContentBlock{ .text = .{ .text = try gpa.dupe(u8, "SYS_A") } }}) } };
    const user = ai.ChatMessage{ .user = .{ .content = try gpa.dupe(ai.ContentBlock, &.{ai.ContentBlock{ .text = .{ .text = try gpa.dupe(u8, "hi") } }}) } };
    const sys2 = ai.ChatMessage{ .system = .{ .content = try gpa.dupe(ai.ContentBlock, &.{ai.ContentBlock{ .text = .{ .text = try gpa.dupe(u8, "SYS_B") } }}) } };
    const chat_messages = [_]ai.ChatMessage{ user, sys1, sys2 };
    var views: [chat_messages.len]ai.MessageView = undefined;
    for (&chat_messages, 0..) |*m, i| views[i] = ai.MessageView{ .borrowed = @ptrCast(@constCast(m)) };
    const messages = views[0..];
    defer {
        gpa.free(sys1.system.content[0].text.text);
        gpa.free(sys1.system.content);
        gpa.free(sys2.system.content[0].text.text);
        gpa.free(sys2.system.content);
        gpa.free(user.user.content[0].text.text);
        gpa.free(user.user.content);
    }

    const norm = try normalizeMessagesForQwen(gpa, messages);
    // norm owns exactly one merged system block; the helper frees it (and only
    // it — non-system entries are borrowed) plus the list storage.
    defer deinitNormalizedMessages(gpa, norm.list, norm.rebuilt);

    // Two system messages merged into one leading system, followed by the user.
    try std.testing.expect(norm.rebuilt);
    try std.testing.expectEqual(@as(usize, 2), norm.list.items.len);
    try std.testing.expect(norm.list.items[0] == .system);
    try std.testing.expect(norm.list.items[1] == .user);
    try std.testing.expectEqualStrings("SYS_A\nSYS_B", norm.list.items[0].system.content[0].text.text);
}

test "normalizeMessagesForQwen passthrough when single leading system" {
    const gpa = std.testing.allocator;
    const sys = ai.ChatMessage{ .system = .{ .content = try gpa.dupe(ai.ContentBlock, &.{ai.ContentBlock{ .text = .{ .text = try gpa.dupe(u8, "SYS") } }}) } };
    const user = ai.ChatMessage{ .user = .{ .content = try gpa.dupe(ai.ContentBlock, &.{ai.ContentBlock{ .text = .{ .text = try gpa.dupe(u8, "hi") } }}) } };
    const chat_messages = [_]ai.ChatMessage{ sys, user };
    var views: [chat_messages.len]ai.MessageView = undefined;
    for (&chat_messages, 0..) |*m, i| views[i] = ai.MessageView{ .borrowed = @ptrCast(@constCast(m)) };
    const messages = views[0..];
    defer {
        gpa.free(sys.system.content[0].text.text);
        gpa.free(sys.system.content);
        gpa.free(user.user.content[0].text.text);
        gpa.free(user.user.content);
    }

    const norm = try normalizeMessagesForQwen(gpa, messages);
    // Passthrough path: norm shares the caller's system/user content, so the
    // helper frees only the list storage, not the inner buffers.
    defer deinitNormalizedMessages(gpa, norm.list, norm.rebuilt);

    // No rebuild → shares the caller's backing storage.
    try std.testing.expect(!norm.rebuilt);
    try std.testing.expectEqual(@as(usize, 2), norm.list.items.len);
}
