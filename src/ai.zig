const std = @import("std");
const tools_common = @import("tools/common.zig");
const tools_mod = @import("tools.zig");

pub const codex_responses = @import("ai/codex_responses.zig");
pub const websocket = @import("websocket");
pub const openai_compatible = @import("ai/openai_compatible.zig");
pub const openai_responses = @import("ai/openai_responses.zig");
pub const provider_headers = @import("ai/provider_headers.zig");
pub const text_tool_call = @import("ai/text_tool_call.zig");

pub const Tool = tools_common.Tool;

/// Schema-only representation of an MCP tool, used for serialization into
/// the provider's `tools` JSON array. MCP tools lack the `run`/`display`
/// function pointers that `Tool` requires — they are dispatched through the
/// MCP transport instead.
pub const McpToolSchema = struct {
    name: []const u8,
    description: []const u8,
    schema: tools_common.Schema,
};

pub const ReasoningEffort = enum {
    /// Don't override the model's default reasoning behaviour — no
    /// `reasoning_effort` parameter is sent in the request.
    default,
    minimal,
    low,
    none,
    medium,
    high,
    xhigh,
    /// Highest reasoning effort (OpenRouter extension). The official OpenAPI
    /// enum is `["max","xhigh","high","medium","low","minimal","none"]`; `max`
    /// is the top level, above `xhigh`. OpenAI-native dialects ignore it.
    max,

    pub fn label(self: ReasoningEffort) []const u8 {
        return @tagName(self);
    }

    /// Parse a persisted effort label back into the enum. Mirrors
    /// `Role.fromString`: a string match → enum or error. Used to restore
    /// session-scoped reasoning effort from the DB on resume. An unknown
    /// label (e.g. from a newer schema or hand-edited data) errors instead
    /// of silently mapping to a wrong level.
    pub fn fromString(text: []const u8) !ReasoningEffort {
        return std.meta.stringToEnum(ReasoningEffort, text) orelse error.InvalidReasoningEffort;
    }
};

pub const ReasoningSummary = enum {
    auto,
    concise,
    detailed,

    pub fn label(self: ReasoningSummary) []const u8 {
        return @tagName(self);
    }
};

pub const Reasoning = struct {
    effort: ?ReasoningEffort = .medium,
    summary: ?ReasoningSummary = .auto,
};

/// Wire-format dialect: which vendor-specific request fields a provider
/// accepts beyond the baseline OpenAI Chat Completions schema. Providers
/// not explicitly mapped fall through to `.minimal`, which sends only
/// universally-safe fields (`reasoning_effort` for reasoning control).
pub const WireDialect = enum {
    /// OpenAI native: `prompt_cache_key` ✓, `reasoning_effort` ✓.
    openai,
    /// OpenRouter: top-level `cache_control` (auto breakpoint) ✓,
    /// native `session_id` (sticky routing) ✓, `reasoning` object with
    /// `effort`+`summary` ✓, `reasoning_effort` shorthand ✓.
    openrouter,
    /// Qwen / DashScope: top-level `enable_thinking` ✓,
    /// `reasoning_effort` ✓.
    dashscope,
    /// Safe default for Ollama, Groq, vLLM, Together, DeepSeek, and
    /// any unknown provider. Only `reasoning_effort` is emitted; all
    /// vendor-specific cache/thinking fields are suppressed.
    minimal,

    /// Resolve the wire dialect from available provider identity.
    /// First match wins: builtin enum → dynamic id string → base URL
    /// heuristic → `.minimal` fallback.
    pub fn resolve(
        builtin: ?@import("config/provider.zig").Provider,
        provider_id: []const u8,
        base_url: []const u8,
    ) WireDialect {
        // 1. Builtin provider enum.
        if (builtin) |p| {
            return switch (p) {
                .openai => .openai,
                .openrouter => .openrouter,
                .alibaba => .dashscope,
                else => .minimal,
            };
        }
        // 2. Dynamic provider id (models.dev registry key).
        const id_lower = provider_id;
        if (std.mem.eql(u8, id_lower, "openrouter")) return .openrouter;
        if (std.mem.eql(u8, id_lower, "openai")) return .openai;
        if (std.mem.eql(u8, id_lower, "dashscope") or
            std.mem.eql(u8, id_lower, "qwen") or
            std.mem.eql(u8, id_lower, "tongyi") or
            std.mem.eql(u8, id_lower, "alibaba")) return .dashscope;
        // 3. Base URL heuristic (covers user-defined providers).
        if (std.mem.indexOf(u8, base_url, "openrouter.ai") != null) return .openrouter;
        if (std.mem.indexOf(u8, base_url, "api.openai.com") != null) return .openai;
        // DashScope / Qwen-compatible gateways serve Alibaba Qwen models and
        // require the `enable_thinking` field instead of `reasoning_effort`
        // (the latter returns HTTP 400). Match both the official endpoint and
        // known third-party gateways that proxy Qwen (runinfra.ai).
        if (std.mem.indexOf(u8, base_url, "dashscope.aliyuncs.com") != null or
            std.mem.indexOf(u8, base_url, "aliyuncs.com") != null or
            std.mem.indexOf(u8, base_url, "runinfra.ai") != null) return .dashscope;
        // 4. Safe fallback.
        return .minimal;
    }

    /// Whether top-level `cache_control` (automatic breakpoint) should be
    /// emitted. OpenRouter applies the cache directive at the request level,
    /// auto-marking the last cacheable block; this supersedes the old
    /// message-level (system-only) approach.
    pub fn allowsTopLevelCacheControl(self: WireDialect) bool {
        return self == .openrouter;
    }

    /// Whether the native top-level `session_id` (sticky provider routing +
    /// cache grouping) should be emitted instead of OpenAI's
    /// `prompt_cache_key`. OpenRouter's `session_id` doubles as a cache key
    /// and an observability/routing key.
    pub fn usesNativeSessionId(self: WireDialect) bool {
        return self == .openrouter;
    }

    /// Whether top-level `prompt_cache_key` should be emitted. Used by the
    /// OpenAI-native dialect only — OpenRouter uses `session_id` instead.
    pub fn allowsPromptCacheKey(self: WireDialect) bool {
        return self == .openai;
    }

    /// Whether top-level `enable_thinking` (DashScope-style) should be
    /// used instead of the standard `reasoning_effort` field.
    pub fn usesEnableThinking(self: WireDialect) bool {
        return self == .dashscope;
    }
};

/// Mirrored defaults for `Config` fields that `runtime.zig` re-supplies via
/// `orelse` fallbacks — one source so the fallbacks can never drift from the
/// field defaults below.
pub const default_request_timeout_seconds: u32 = 300;
pub const default_max_parallel_tool_calls: u32 = 16;

pub const Config = struct {
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    tools: []const Tool = &.{},
    mcp_tools: []const McpToolSchema = &.{},
    reasoning: ?Reasoning = .{},
    /// Maximum tokens per generation turn. Sent as `max_tokens` in the
    /// request body when non-null. Sourced from per-model config
    /// (`providers.<name>.models.<id>.maxOutputTokens`) or global
    /// `context.maxOutputTokens`.
    max_output_tokens: ?u32 = null,
    /// Upper bound on parallel tool calls the stream parser will accept.
    /// Providers that exceed this get a logged error instead of silent
    /// truncation. Hard array capacity is 64; this is the runtime gate.
    max_parallel_tool_calls: u32 = default_max_parallel_tool_calls,
    /// Socket-level read timeout in seconds for streaming responses.
    /// Prevents indefinite hangs when the server stops mid-stream.
    request_timeout_seconds: u32 = default_request_timeout_seconds,
    /// Structured-outputs mode. `true` only works against the OpenAI API;
    /// gateways (OpenRouter/Ollama/vLLM/Together) reject or silently break
    /// strict schemas, which disables function-calling — the model then
    /// emits tool calls as plain text instead of `tool_calls` deltas.
    /// Default `false` keeps tool-calling working everywhere.
    strict: bool = false,
    /// Wire-format dialect: gates vendor-specific request fields
    /// (`cache_control`, `prompt_cache_key`, `enable_thinking`).
    /// Resolved at client-attach time from provider identity.
    /// Default `.minimal` is safe for all providers.
    wire_dialect: WireDialect = .minimal,
    /// Whether the active model is a reasoning model (o-series, gpt-5, etc.),
    /// from the runtime models.dev registry. Reasoning models ignore the
    /// legacy `max_tokens` field, so the OpenAI-native dialect emits
    /// `max_completion_tokens` instead. Default `false` — the safe direction.
    is_reasoning_model: bool = false,
    /// Disable provider prompt-caching fields entirely (C1). When true,
    /// neither top-level `cache_control` nor native `session_id` (OpenRouter)
    /// nor `prompt_cache_key` (OpenAI) is emitted, in BOTH wire clients
    /// (chat-completions and Responses API), regardless of dialect. Use for
    /// OpenRouter models that reject these fields with HTTP 400 (some `:free`
    /// / gateway-fronted models). The flag is the durable
    /// escape hatch; C2's downgrade retry auto-recovers for users who
    /// haven't set it.
    disable_prompt_cache: bool = false,
    /// Maximum number of retries for transient HTTP errors (429 + 5xx).
    /// 0 disables retries entirely (single attempt — the legacy behavior).
    /// Only head-phase statuses are retried; once the response body streams,
    /// an error is never retried (partial deltas may already be visible).
    max_retries: u32 = 2,
    /// Base delay for exponential retry backoff, in milliseconds. The actual
    /// delay is `base * 2^attempt`, capped; a server-sent `Retry-After` header
    /// (integer seconds) takes precedence over the backoff.
    retry_base_delay_ms: u64 = 500,
    account_id: []const u8 = "",
    session_id: []const u8 = "",
    /// Resolved provider headers for this client: provider-required auto
    /// headers (OpenCode Zen routing, OpenRouter attribution) merged with
    /// the user's `providers.<name>.headers`, user winning on name
    /// collision (`provider_headers.build`, called once at attach time —
    /// `{env:VAR}` placeholders are already expanded by then). BORROWED at
    /// init: each client deep-dupes what it keeps via
    /// `provider_headers.cloneHeaders`.
    headers: []const provider_headers.Header = &.{},
    system_prompt: []const u8 = "You are a helpful assistant.",
};

pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn label(self: Role) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(role: []const u8) !Role {
        if (std.mem.eql(u8, role, "system")) return .system;
        if (std.mem.eql(u8, role, "user")) return .user;
        if (std.mem.eql(u8, role, "assistant")) return .assistant;
        if (std.mem.eql(u8, role, "tool")) return .tool;
        return error.InvalidRole;
    }
};

pub const TextBlock = struct {
    text: []u8,
    responses_item_id: ?[]u8 = null,
    responses_phase: ?[]u8 = null,

    pub fn deinit(self: *TextBlock, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        if (self.responses_item_id) |id| gpa.free(id);
        if (self.responses_phase) |phase| gpa.free(phase);
        self.* = undefined;
    }
};

pub const ImageBlock = struct {
    mime_type: []u8,
    data_base64: []u8,

    pub fn deinit(self: *ImageBlock, gpa: std.mem.Allocator) void {
        gpa.free(self.mime_type);
        gpa.free(self.data_base64);
        self.* = undefined;
    }
};

pub const ReasoningBlock = struct {
    text: []u8,
    responses_item_json: ?[]u8 = null,

    pub fn deinit(self: *ReasoningBlock, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        if (self.responses_item_json) |json| gpa.free(json);
        self.* = undefined;
    }
};

/// Branded wrapper for an LLM-generated tool call identifier. Carries an
/// owned `[]u8` slice. The brand prevents accidental cross-wiring with
/// other `[]u8` id fields (e.g. `model_id`, `account_id`) at call sites
/// across module boundaries. Use `.slice()` to bridge to `[]const u8`
/// parameters; use `.value` for direct `gpa.free` / `gpa.dupe`.
pub const CallId = struct {
    value: []u8,

    pub fn slice(self: *const CallId) []const u8 {
        return self.value;
    }
};

pub const ToolCall = struct {
    call_id: CallId,
    responses_item_id: ?[]u8 = null,
    name: []u8,
    arguments: []u8,

    pub fn deinit(self: *ToolCall, gpa: std.mem.Allocator) void {
        gpa.free(self.call_id.value);
        if (self.responses_item_id) |id| gpa.free(id);
        gpa.free(self.name);
        gpa.free(self.arguments);
        self.* = undefined;
    }
};

pub const ContentBlock = union(enum) {
    text: TextBlock,
    image: ImageBlock,
    reasoning: ReasoningBlock,
    tool_call: ToolCall,

    pub fn deinit(self: *ContentBlock, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .text => |*block| block.deinit(gpa),
            .image => |*block| block.deinit(gpa),
            .reasoning => |*block| block.deinit(gpa),
            .tool_call => |*block| block.deinit(gpa),
        }
        self.* = undefined;
    }

    /// Error set for decoding a block from Nova's persistence JSON.
    pub const DecodeError = error{CorruptPayload} || std.mem.Allocator.Error;

    /// Encode and decode for Nova's canonical *persistence* JSON — the form the
    /// session store keeps on disk. This is NOT a provider's wire format;
    /// adapters in `ai/` own those. The two directions live together so a new
    /// variant cannot be added to one without the other (a round-trip test in
    /// session.zig guards the symmetry). If versioned/migrated payloads ever
    /// arrive, introduce a codec module that wraps these rather than spreading
    /// the version envelope across both halves.
    pub fn writeJson(self: ContentBlock, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .text => |text| {
                try writer.writeAll("{\"type\":\"text\",\"text\":");
                try std.json.Stringify.value(@as([]const u8, text.text), .{}, writer);
                if (text.responses_item_id) |id| {
                    try writer.writeAll(",\"responses_item_id\":");
                    try std.json.Stringify.value(id, .{}, writer);
                }
                if (text.responses_phase) |phase| {
                    try writer.writeAll(",\"responses_phase\":");
                    try std.json.Stringify.value(phase, .{}, writer);
                }
                try writer.writeByte('}');
            },
            .image => |image| {
                try writer.writeAll("{\"type\":\"image\",\"mime_type\":");
                try std.json.Stringify.value(image.mime_type, .{}, writer);
                try writer.writeAll(",\"data_base64\":");
                try std.json.Stringify.value(image.data_base64, .{}, writer);
                try writer.writeByte('}');
            },
            .reasoning => |reasoning| {
                try writer.writeAll("{\"type\":\"reasoning\",\"text\":");
                try std.json.Stringify.value(@as([]const u8, reasoning.text), .{}, writer);
                if (reasoning.responses_item_json) |json| {
                    try writer.writeAll(",\"responses_item_json\":");
                    try std.json.Stringify.value(json, .{}, writer);
                }
                try writer.writeByte('}');
            },
            .tool_call => |call| {
                try writer.writeAll("{\"type\":\"tool_call\",\"call_id\":");
                try std.json.Stringify.value(call.call_id.slice(), .{}, writer);
                if (call.responses_item_id) |id| {
                    try writer.writeAll(",\"responses_item_id\":");
                    try std.json.Stringify.value(id, .{}, writer);
                }
                try writer.writeAll(",\"name\":");
                try std.json.Stringify.value(call.name, .{}, writer);
                try writer.writeAll(",\"arguments\":");
                try std.json.Stringify.value(call.arguments, .{}, writer);
                try writer.writeByte('}');
            },
        }
    }

    pub fn fromJson(gpa: std.mem.Allocator, value: std.json.Value) DecodeError!ContentBlock {
        if (value != .object) return error.CorruptPayload;
        const kind = value.object.get("type") orelse return error.CorruptPayload;
        if (kind != .string) return error.CorruptPayload;
        if (std.mem.eql(u8, kind.string, "text")) {
            const text = value.object.get("text") orelse return error.CorruptPayload;
            const text_str = if (text == .string)
                try gpa.dupe(u8, text.string)
            else if (text == .array)
                try jsonByteArrayToString(gpa, text.array.items)
            else
                return error.CorruptPayload;

            return .{ .text = .{
                .text = text_str,
                .responses_item_id = try jsonOptionalString(gpa, value, "responses_item_id"),
                .responses_phase = try jsonOptionalString(gpa, value, "responses_phase"),
            } };
        }
        if (std.mem.eql(u8, kind.string, "image")) {
            const mime = value.object.get("mime_type") orelse return error.CorruptPayload;
            const data = value.object.get("data_base64") orelse return error.CorruptPayload;
            if (mime != .string) return error.CorruptPayload;
            if (data != .string) return error.CorruptPayload;
            return .{ .image = .{ .mime_type = try gpa.dupe(u8, mime.string), .data_base64 = try gpa.dupe(u8, data.string) } };
        }
        if (std.mem.eql(u8, kind.string, "reasoning")) {
            const text = value.object.get("text") orelse return error.CorruptPayload;
            const text_str = if (text == .string)
                try gpa.dupe(u8, text.string)
            else if (text == .array)
                try jsonByteArrayToString(gpa, text.array.items)
            else
                return error.CorruptPayload;

            return .{ .reasoning = .{ .text = text_str, .responses_item_json = try jsonOptionalString(gpa, value, "responses_item_json") } };
        }
        if (std.mem.eql(u8, kind.string, "tool_call")) {
            const call_id = value.object.get("call_id") orelse return error.CorruptPayload;
            const name = value.object.get("name") orelse return error.CorruptPayload;
            const arguments = value.object.get("arguments") orelse return error.CorruptPayload;
            if (call_id != .string) return error.CorruptPayload;
            if (name != .string) return error.CorruptPayload;
            if (arguments != .string) return error.CorruptPayload;
            return .{ .tool_call = .{
                .call_id = .{ .value = try gpa.dupe(u8, call_id.string) },
                .responses_item_id = try jsonOptionalString(gpa, value, "responses_item_id"),
                .name = try gpa.dupe(u8, name.string),
                .arguments = try gpa.dupe(u8, arguments.string),
            } };
        }
        return error.CorruptPayload;
    }
};

/// Dupe an optional string field from a JSON object. Returns null when absent,
/// `error.CorruptPayload` when present but not a string.
fn jsonOptionalString(gpa: std.mem.Allocator, value: std.json.Value, name: []const u8) ContentBlock.DecodeError!?[]u8 {
    const field = value.object.get(name) orelse return null;
    if (field != .string) return error.CorruptPayload;
    return try gpa.dupe(u8, field.string);
}

fn jsonByteArrayToString(gpa: std.mem.Allocator, items: []const std.json.Value) ContentBlock.DecodeError![]u8 {
    var buf = try gpa.alloc(u8, items.len);
    errdefer gpa.free(buf);
    for (items, 0..) |item, i| {
        if (item != .integer or item.integer < 0 or item.integer > 255) return error.CorruptPayload;
        buf[i] = @intCast(item.integer);
    }
    return buf;
}

fn reencode(gpa: std.mem.Allocator, block: ContentBlock) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try block.writeJson(&out.writer);
    return out.toOwnedSlice();
}

test "ContentBlock JSON round-trips every variant" {
    const gpa = std.testing.allocator;
    var blocks = [_]ContentBlock{
        .{ .text = .{ .text = try gpa.dupe(u8, "hello"), .responses_item_id = try gpa.dupe(u8, "id1"), .responses_phase = try gpa.dupe(u8, "final") } },
        .{ .image = .{ .mime_type = try gpa.dupe(u8, "image/png"), .data_base64 = try gpa.dupe(u8, "AAAA") } },
        .{ .reasoning = .{ .text = try gpa.dupe(u8, "thinking"), .responses_item_json = try gpa.dupe(u8, "{}") } },
        .{ .tool_call = .{ .call_id = .{ .value = try gpa.dupe(u8, "c1") }, .name = try gpa.dupe(u8, "bash"), .arguments = try gpa.dupe(u8, "{}") } },
    };
    defer for (&blocks) |*block| block.deinit(gpa);

    for (blocks) |block| {
        const json = try reencode(gpa, block);
        defer gpa.free(json);
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
        defer parsed.deinit();
        var decoded = try ContentBlock.fromJson(gpa, parsed.value);
        defer decoded.deinit(gpa);
        // Decoding then re-encoding must reproduce the bytes exactly — proving
        // the two halves stay symmetric.
        const round_tripped = try reencode(gpa, decoded);
        defer gpa.free(round_tripped);
        try std.testing.expectEqualStrings(json, round_tripped);
    }
}

test "ContentBlock.fromJson rejects malformed payloads" {
    const gpa = std.testing.allocator;
    const cases = [_][]const u8{
        "\"not an object\"",
        "{}",
        "{\"type\":\"text\"}",
        "{\"type\":\"bogus\"}",
        "{\"type\":\"text\",\"text\":5}",
    };
    for (cases) |case| {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, case, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.CorruptPayload, ContentBlock.fromJson(gpa, parsed.value));
    }
}

/// One entry in the conversation projection. Variants make illegal
/// combinations unrepresentable: a `.user` message cannot have a
/// `call_id`, a `.tool` message must have one. `text()` and `deinit()`
/// are the only cross-variant accessors; everything else touches a
/// specific variant via a tag switch.
pub const ChatMessage = union(enum) {
    system: struct {
        content: []ContentBlock,
    },
    user: struct {
        content: []ContentBlock,
    },
    assistant: struct {
        content: []ContentBlock,
    },
    tool: struct {
        call_id: CallId,
        content: []ContentBlock,
        display_label: ?[]u8 = null,
        failed: bool = false,
    },

    /// The first text block in the message's content. Returns "" when
    /// the message is non-text (e.g. all tool calls or images).
    pub fn text(self: ChatMessage) []const u8 {
        const content: []const ContentBlock = switch (self) {
            inline .system, .user, .assistant => |m| m.content,
            .tool => |t| t.content,
        };
        for (content) |block| {
            if (block == .text) return block.text.text;
        }
        return "";
    }

    /// The Role corresponding to this variant. Useful for serialization
    /// and for the few call sites that need to switch on role without
    /// caring about the variant payload.
    pub fn role(self: ChatMessage) Role {
        return switch (self) {
            .system => .system,
            .user => .user,
            .assistant => .assistant,
            .tool => .tool,
        };
    }

    /// Free every owned buffer. Safe to call on undefined memory
    /// after — `self.* = undefined` poisons the slot for use-after-free
    /// detection.
    pub fn deinit(self: *ChatMessage, gpa: std.mem.Allocator) void {
        switch (self.*) {
            inline .system, .user, .assistant => |*m| freeBlocks(gpa, m.content),
            .tool => |*t| {
                gpa.free(t.call_id.value);
                if (t.display_label) |label| gpa.free(label);
                freeBlocks(gpa, t.content);
            },
        }
        self.* = undefined;
    }

    fn freeBlocks(gpa: std.mem.Allocator, blocks: []ContentBlock) void {
        for (blocks) |*block| block.deinit(gpa);
        gpa.free(blocks);
    }
};

/// A read-only view of one message destined for the model request.
///
/// Unchanged messages are BORROWED straight from the ContextManager — no byte
/// copy, so base64 images are never duplicated per turn. Only pruned
/// historical tool messages (older than the keep-recent cutoff) are OWNED
/// copies produced by `context_assembly.pruneHistoricalToolResultsViews`.
/// `freePrunedViews` releases only the `.owned` variants.
///
/// Borrowed pointers are valid for the duration of the synchronous
/// `client.prompt` call: the manager appends messages only AFTER the call
/// returns (`takeAssistantMessage`/`takeToolResults`), never mid-call.
pub const MessageView = union(enum) {
    /// Points into the ContextManager's live message list; we do not own it.
    borrowed: *const ChatMessage,
    /// A pruned historical tool message; we own it and free it.
    owned: ChatMessage,

    /// The message this view refers to. `.borrowed` aliases the live message;
    /// `.owned` is the pruned copy stored in the view.
    pub fn message(self: *const MessageView) *const ChatMessage {
        return switch (self.*) {
            .borrowed => |m| m,
            .owned => |*m| m,
        };
    }
};

/// Token accounting for one model response, normalized across provider
/// dialects. Chat Completions reports `prompt_tokens`/`completion_tokens`;
/// the Responses API reports `input_tokens`/`output_tokens`. We store the
/// neutral `input`/`output` naming and parse each dialect at its adapter
/// boundary (see `boundary-discipline`).
///
/// `cached_input_tokens` is a *subset* of `input_tokens` (already counted in
/// it) and is informational only: a cached prompt is still re-sent in full,
/// so it never reduces the size used for context-overflow math.
pub const Usage = struct {
    input_tokens: u32,
    output_tokens: u32,
    total_tokens: u32,
    cached_input_tokens: u32 = 0,
    reasoning_tokens: u32 = 0,
};

/// Clamp a provider-reported token count (an arbitrary JSON integer parsed at
/// an adapter boundary) into the `u32` domain `Usage` uses. Negative or absurd
/// values collapse to the nearest representable bound rather than wrapping.
pub fn clampTokenCount(value: i64) u32 {
    if (value < 0) return 0;
    if (value > std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(value);
}

pub const Turn = struct {
    assistant: ChatMessage,
    /// Token usage for this turn, when the provider reported it. `null` means
    /// the provider omitted usage (e.g. a streaming OpenAI-compatible endpoint
    /// without `stream_options.include_usage`); the budget falls back to a
    /// size estimate in that case.
    usage: ?Usage = null,

    pub fn deinit(self: *Turn, gpa: std.mem.Allocator) void {
        self.assistant.deinit(gpa);
        self.* = undefined;
    }
};

pub const ToolDelta = struct {
    index: u32,
    name: []const u8,
    arguments: []const u8,
};

pub const NoopCtx = struct {};

/// Typed stream observer — generic over the consumer's context type.
/// Replaces the old `*anyopaque` + `@ptrCast` vtable. Callers pass their
/// own ctx type; the callbacks receive it typed.
pub fn StreamObserver(comptime Ctx: type) type {
    return struct {
        ctx: *Ctx,
        on_content: *const fn (*Ctx, []const u8) anyerror!void,
        on_reasoning: *const fn (*Ctx, []const u8) anyerror!void,
        on_tool_delta: *const fn (*Ctx, ToolDelta) anyerror!void,
        on_delta_end: *const fn (*Ctx) anyerror!void,
    };
}

var noop_ctx: NoopCtx = .{};

/// Noop stream observer for fire-and-forget prompts. Use `streamNoop()`.
pub fn streamNoop() StreamObserver(NoopCtx) {
    return .{
        .ctx = &noop_ctx,
        .on_content = noopBytes,
        .on_reasoning = noopBytes,
        .on_tool_delta = noopToolDelta,
        .on_delta_end = noopVoid,
    };
}

fn noopBytes(_: *NoopCtx, _: []const u8) anyerror!void {}
fn noopToolDelta(_: *NoopCtx, _: ToolDelta) anyerror!void {}
fn noopVoid(_: *NoopCtx) anyerror!void {}

pub const LanguageModel = union(enum) {
    none,
    codex_responses: *codex_responses.Client,
    openai_compatible: *openai_compatible.Client,
    openai_responses: *openai_responses.Client,

    pub fn prompt(
        self: LanguageModel,
        messages: []const MessageView,
        observer: anytype,
    ) !Turn {
        return switch (self) {
            .none => error.NoProviderConnected,
            .codex_responses => |c| c.prompt(messages, observer),
            .openai_compatible => |c| c.prompt(messages, observer),
            .openai_responses => |c| c.prompt(messages, observer),
        };
    }

    pub fn lastErrorDetail(self: LanguageModel) ?[]const u8 {
        return switch (self) {
            .none => null,
            .openai_compatible => |c| c.last_error_detail,
            .codex_responses => |c| c.core_client.last_error_detail,
            .openai_responses => |c| c.core_client.last_error_detail,
        };
    }

    /// Rebuild the active client's serialized tool definitions after the MCP
    /// tool set changes. No-op when no client is connected. `mcp_tools` is
    /// borrowed only for the duration of the call. `registry`, when
    /// non-null, contributes its builtin + plugin tools so the model sees
    /// them as first-class definitions. `builtin_override` lets the caller
    /// choose what `self.config.tools` contains at call time: most callers
    /// pass `&.{}` because the registry's builtin already covers bash,
    /// and emitting both would create a duplicate name that most APIs
    /// reject (HTTP 400), dropping the entire tool list.
    pub fn updateMcpTools(
        self: LanguageModel,
        mcp_tools: []const McpToolSchema,
        registry: ?*tools_mod.ToolRegistry,
        builtin_override: []const tools_common.Tool,
    ) !void {
        switch (self) {
            .none => {},
            .codex_responses => |c| try c.updateMcpTools(mcp_tools, registry, builtin_override),
            .openai_compatible => |c| try c.updateMcpTools(mcp_tools, registry, builtin_override),
            .openai_responses => |c| try c.updateMcpTools(mcp_tools, registry, builtin_override),
        }
    }
};

test "clampTokenCount clamps negative values to zero" {
    try std.testing.expectEqual(@as(u32, 0), clampTokenCount(-1));
    try std.testing.expectEqual(@as(u32, 0), clampTokenCount(-100));
    try std.testing.expectEqual(@as(u32, 0), clampTokenCount(std.math.minInt(i64)));
}

test "clampTokenCount clamps oversized values to max_u32" {
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), clampTokenCount(std.math.maxInt(u32) + 1));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), clampTokenCount(std.math.maxInt(i64)));
}

test "clampTokenCount passes through valid values" {
    try std.testing.expectEqual(@as(u32, 0), clampTokenCount(0));
    try std.testing.expectEqual(@as(u32, 100), clampTokenCount(100));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), clampTokenCount(std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(u32, 1_000_000), clampTokenCount(1_000_000));
}

test "ReasoningEffort.fromString round-trips labels and rejects unknowns" {
    try std.testing.expectEqual(ReasoningEffort.default, try ReasoningEffort.fromString("default"));
    try std.testing.expectEqual(ReasoningEffort.high, try ReasoningEffort.fromString("high"));
    try std.testing.expectEqual(ReasoningEffort.none, try ReasoningEffort.fromString("none"));
    try std.testing.expectEqual(ReasoningEffort.max, try ReasoningEffort.fromString("max"));
    try std.testing.expectEqualStrings("max", ReasoningEffort.max.label());
    try std.testing.expectError(error.InvalidReasoningEffort, ReasoningEffort.fromString("turbo"));
    try std.testing.expectError(error.InvalidReasoningEffort, ReasoningEffort.fromString(""));
}

test "WireDialect.resolve maps builtin providers correctly" {
    const provider_mod = @import("config/provider.zig");
    // Builtin enum takes priority.
    try std.testing.expectEqual(WireDialect.openai, WireDialect.resolve(.openai, "", ""));
    try std.testing.expectEqual(WireDialect.openrouter, WireDialect.resolve(.openrouter, "", ""));
    try std.testing.expectEqual(WireDialect.dashscope, WireDialect.resolve(.alibaba, "", ""));
    try std.testing.expectEqual(WireDialect.minimal, WireDialect.resolve(.ollama, "", ""));
    try std.testing.expectEqual(WireDialect.minimal, WireDialect.resolve(.ollama_cloud, "", ""));
    try std.testing.expectEqual(WireDialect.minimal, WireDialect.resolve(.cerebras, "", ""));
    try std.testing.expectEqual(WireDialect.minimal, WireDialect.resolve(.anthropic, "", ""));
    _ = provider_mod.Provider.openai; // ensure import is used
}

test "WireDialect.resolve maps dynamic provider ids" {
    // No builtin → falls through to id string matching.
    try std.testing.expectEqual(WireDialect.dashscope, WireDialect.resolve(null, "dashscope", ""));
    try std.testing.expectEqual(WireDialect.dashscope, WireDialect.resolve(null, "qwen", ""));
    try std.testing.expectEqual(WireDialect.dashscope, WireDialect.resolve(null, "tongyi", ""));
    try std.testing.expectEqual(WireDialect.dashscope, WireDialect.resolve(null, "alibaba", ""));
    try std.testing.expectEqual(WireDialect.openrouter, WireDialect.resolve(null, "openrouter", ""));
    try std.testing.expectEqual(WireDialect.openai, WireDialect.resolve(null, "openai", ""));
    // DeepSeek and unknown → minimal.
    try std.testing.expectEqual(WireDialect.minimal, WireDialect.resolve(null, "deepseek", ""));
    try std.testing.expectEqual(WireDialect.minimal, WireDialect.resolve(null, "some-random-provider", ""));
}

test "WireDialect.resolve falls back to base URL heuristic" {
    try std.testing.expectEqual(WireDialect.openrouter, WireDialect.resolve(null, "", "https://openrouter.ai/api/v1"));
    try std.testing.expectEqual(WireDialect.openai, WireDialect.resolve(null, "", "https://api.openai.com/v1"));
    try std.testing.expectEqual(WireDialect.dashscope, WireDialect.resolve(null, "", "https://dashscope.aliyuncs.com/compatible-mode/v1"));
    // Third-party Qwen/DashScope gateways proxy Alibaba Qwen and reject the
    // standard `reasoning_effort` field (HTTP 400) — they must resolve to the
    // `enable_thinking` dialect too. Regression: runinfra.ai returned minimal,
    // so the request failed and the stream parser threw UnexpectedToken.
    try std.testing.expectEqual(WireDialect.dashscope, WireDialect.resolve(null, "", "https://api.runinfra.ai/v1"));
    try std.testing.expectEqual(WireDialect.dashscope, WireDialect.resolve(null, "", "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"));
    // Unknown URL → minimal.
    try std.testing.expectEqual(WireDialect.minimal, WireDialect.resolve(null, "", "https://api.deepseek.com"));
    try std.testing.expectEqual(WireDialect.minimal, WireDialect.resolve(null, "", "http://localhost:11434"));
}

test "WireDialect capability gates" {
    // top-level cache_control: only openrouter
    try std.testing.expect(WireDialect.openrouter.allowsTopLevelCacheControl());
    try std.testing.expect(!WireDialect.openai.allowsTopLevelCacheControl());
    try std.testing.expect(!WireDialect.dashscope.allowsTopLevelCacheControl());
    try std.testing.expect(!WireDialect.minimal.allowsTopLevelCacheControl());
    // native session_id: only openrouter
    try std.testing.expect(WireDialect.openrouter.usesNativeSessionId());
    try std.testing.expect(!WireDialect.openai.usesNativeSessionId());
    try std.testing.expect(!WireDialect.dashscope.usesNativeSessionId());
    try std.testing.expect(!WireDialect.minimal.usesNativeSessionId());
    // prompt_cache_key: openai only (openrouter uses native session_id)
    try std.testing.expect(WireDialect.openai.allowsPromptCacheKey());
    try std.testing.expect(!WireDialect.openrouter.allowsPromptCacheKey());
    try std.testing.expect(!WireDialect.dashscope.allowsPromptCacheKey());
    try std.testing.expect(!WireDialect.minimal.allowsPromptCacheKey());
    // enable_thinking: only dashscope
    try std.testing.expect(WireDialect.dashscope.usesEnableThinking());
    try std.testing.expect(!WireDialect.openai.usesEnableThinking());
    try std.testing.expect(!WireDialect.openrouter.usesEnableThinking());
    try std.testing.expect(!WireDialect.minimal.usesEnableThinking());
}
