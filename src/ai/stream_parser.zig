//! SSE streaming parser for OpenAI-compatible chat completions.
//!
//! Extracted from openai_compatible.zig. Pure parsing logic: consumes SSE
//! data lines via `stream_part.Source`, accumulates content/reasoning/tool-call
//! deltas through a `std.json.Scanner`, and emits observer callbacks. No HTTP,
//! no Client state — just the wire format → `ai.Turn` projection.

const std = @import("std");
const log = std.log.scoped(.ai);

const ai = @import("../ai.zig");
const stream_part = @import("stream_part.zig");

const Scanner = std.json.Scanner;

/// Hard upper bound for fixed-size remap/index arrays in ToolCallStream
/// and ChunkChange. The runtime-configurable gate is `max_parallel_tool_calls`
/// in ai.Config (default 16); this cap just sizes the stack arrays.
pub const tool_call_array_cap: u32 = 64;

pub fn sanitizeToolArguments(raw: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return "{}";

    if (std.mem.startsWith(u8, trimmed, "```")) {
        if (std.mem.indexOf(u8, trimmed, "\n")) |newline_pos| {
            trimmed = std.mem.trim(u8, trimmed[newline_pos + 1 ..], " \t\r\n");
        } else {
            trimmed = std.mem.trim(u8, trimmed[3..], " \t\r\n");
        }
        if (std.mem.endsWith(u8, trimmed, "```")) {
            trimmed = std.mem.trim(u8, trimmed[0 .. trimmed.len - 3], " \t\r\n");
        }
    }

    if (trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') {
        return trimmed;
    }
    return "{}";
}

const ToolCallBuilder = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,

    fn deinit(self: *ToolCallBuilder, gpa: std.mem.Allocator) void {
        self.id.deinit(gpa);
        self.name.deinit(gpa);
        self.arguments.deinit(gpa);
        self.* = undefined;
    }

    /// Finalise the accumulated chunks into a canonical `ai.ToolCall`.
    /// When the server omitted an id, synthesise one from `tool_call_seq`
    /// — the agent never sees an empty id.
    /// Arguments are sanitised (markdown fences stripped, empty → "{}")
    /// so downstream consumers (executor, display) always see valid JSON.
    fn toToolCall(self: *ToolCallBuilder, gpa: std.mem.Allocator, tool_call_seq: *u64) !ai.ToolCall {
        const id = if (self.id.items.len > 0)
            try self.id.toOwnedSlice(gpa)
        else id_blk: {
            const minted = try std.fmt.allocPrint(gpa, "call_{d}", .{tool_call_seq.*});
            tool_call_seq.* += 1;
            break :id_blk minted;
        };
        const raw_args = try self.arguments.toOwnedSlice(gpa);
        const sanitized = sanitizeToolArguments(raw_args);
        const arguments = if (sanitized.ptr == raw_args.ptr and sanitized.len == raw_args.len)
            raw_args
        else blk: {
            const duped = try gpa.dupe(u8, sanitized);
            gpa.free(raw_args);
            break :blk duped;
        };
        return .{
            .call_id = .{ .value = id },
            .name = try self.name.toOwnedSlice(gpa),
            .arguments = arguments,
        };
    }
};

/// Streaming tool-call accumulator with logical-to-physical index remapping.
///
/// Some OpenAI-compatible providers reuse `index: 0` for parallel tool calls
/// instead of incrementing the index per call. This struct detects that by
/// comparing tool-call IDs — which are always unique — and forks a new
/// physical builder slot when a collision is found. Subsequent argument
/// deltas (which carry no ID) route through the remap to the correct slot.
pub const ToolCallStream = struct {
    builders: std.ArrayList(ToolCallBuilder) = .empty,
    remapped_slot: [tool_call_array_cap]u32 = @splat(0),
    is_remapped: [tool_call_array_cap]bool = @splat(false),
    /// Runtime-configurable upper bound on parallel tool calls (from
    /// ai.Config.max_parallel_tool_calls). Indices at or above this
    /// are dropped rather than executed so the remaining calls can still
    /// complete the turn. The hard `tool_call_array_cap` still aborts if it
    /// would overflow the fixed remap arrays.
    max_calls: u32 = 16,
    /// Number of tool-call deltas dropped because their logical index was
    /// at or above `max_calls`. Surfaced at the end of the stream so the
    /// caller can decide whether to inform the model.
    dropped: u32 = 0,
    /// Model id, borrowed and used only so the over-cap reject log can name
    /// which model tripped the cap. Empty in tests / when the caller has no
    /// model id; never affects parsing behaviour.
    model: []const u8 = "",

    fn physicalSlot(self: *const ToolCallStream, logical: u32) u32 {
        return if (self.is_remapped[logical]) self.remapped_slot[logical] else logical;
    }

    pub fn deinit(self: *ToolCallStream, gpa: std.mem.Allocator) void {
        for (self.builders.items) |*b| b.deinit(gpa);
        self.builders.deinit(gpa);
    }
};

pub fn readStream(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    observer: anytype,
    tool_call_seq: *u64,
    max_calls: u32,
    model: []const u8,
) !ai.Turn {
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    // Pre-size the body buffers from the first delta as a sizing hint, so long
    // generations (100s of KB) don't realloc repeatedly during the stream.
    // `appendStringValue` grew the ArrayList on that first delta, so the flags
    // (not `capacity == 0`) are the reliable one-shot signal.
    var content_sized: bool = false;
    var reasoning_sized: bool = false;
    var stream: ToolCallStream = .{ .max_calls = max_calls, .model = model };
    defer stream.deinit(gpa);

    // Parse and apply each chunk inline (rather than via `processStreamChunk`)
    // so the final usage-only chunk's `change.usage` reaches the Turn. The
    // server emits at most one usage chunk; the last one observed wins.
    var usage: ?ai.Usage = null;
    var source: stream_part.Source = .{ .reader = reader };
    while (try source.next(gpa)) |data| {
        defer gpa.free(data);
        const change = try parseStreamChunk(gpa, data, &content, &reasoning, &stream);
        if (change.usage) |chunk_usage| usage = chunk_usage;
        if (!content_sized and content.items.len > 0) {
            try content.ensureTotalCapacity(gpa, content.items.len * 4);
            content_sized = true;
        }
        if (!reasoning_sized and reasoning.items.len > 0) {
            try reasoning.ensureTotalCapacity(gpa, reasoning.items.len * 4);
            reasoning_sized = true;
        }
        try applyChunkCallbacks(change, content.items, reasoning.items, stream.builders.items, observer);
    }

    var blocks: std.ArrayList(ai.ContentBlock) = .empty;
    errdefer {
        for (blocks.items) |*block| block.deinit(gpa);
        blocks.deinit(gpa);
    }
    if (reasoning.items.len > 0) {
        try blocks.append(gpa, .{ .reasoning = .{ .text = try reasoning.toOwnedSlice(gpa) } });
    }
    if (content.items.len > 0) {
        try blocks.append(gpa, .{ .text = .{ .text = try content.toOwnedSlice(gpa) } });
    }
    for (stream.builders.items, 0..) |*builder, i| {
        if (builder.name.items.len == 0) continue;
        log.info(
            "readStream.builder[{d}] name={s} id_len={d} args_len={d}",
            .{ i, builder.name.items, builder.id.items.len, builder.arguments.items.len },
        );
        try blocks.append(gpa, .{ .tool_call = try builder.toToolCall(gpa, tool_call_seq) });
    }
    if (stream.dropped > 0) {
        log.warn("readStream.dropped dropped={d} max_calls={d} model={s}", .{ stream.dropped, stream.max_calls, stream.model });
    }
    log.info("readStream.done content_len={d} reasoning_len={d} blocks={d}", .{ content.items.len, reasoning.items.len, blocks.items.len });
    return .{ .assistant = .{ .assistant = .{ .content = try blocks.toOwnedSlice(gpa) } }, .usage = usage };
}

pub const ChunkChange = struct {
    content_start: ?u32 = null,
    reasoning_start: ?u32 = null,
    tool_call_indexes: [tool_call_array_cap]u32 = @splat(0),
    tool_call_count: u32 = 0,
    /// Token usage when this chunk was the final usage-only chunk; otherwise
    /// null. Does not affect `empty()` — a usage chunk emits no callbacks.
    usage: ?ai.Usage = null,

    pub fn empty(self: *const ChunkChange) bool {
        if (self.content_start != null) return false;
        if (self.reasoning_start != null) return false;
        if (self.tool_call_count > 0) return false;
        return true;
    }

    fn recordToolCall(self: *ChunkChange, index: u32) void {
        for (self.tool_call_indexes[0..self.tool_call_count]) |existing| {
            if (existing == index) return;
        }
        std.debug.assert(self.tool_call_count < tool_call_array_cap);
        self.tool_call_indexes[self.tool_call_count] = index;
        self.tool_call_count += 1;
    }
};

fn applyChunkCallbacks(
    change: ChunkChange,
    content: []const u8,
    reasoning: []const u8,
    builders: []const ToolCallBuilder,
    observer: anytype,
) !void {
    if (change.content_start) |start| {
        try observer.on_content(observer.ctx, content[start..]);
    }
    if (change.reasoning_start) |start| {
        try observer.on_reasoning(observer.ctx, reasoning[start..]);
    }
    for (change.tool_call_indexes[0..change.tool_call_count]) |idx| {
        const builder = builders[idx];
        try observer.on_tool_delta(observer.ctx, .{
            .index = idx,
            .name = builder.name.items,
            .arguments = builder.arguments.items,
        });
    }
    if (change.empty()) return;
    try observer.on_delta_end(observer.ctx);
}

pub fn processStreamChunk(
    gpa: std.mem.Allocator,
    data: []const u8,
    content: *std.ArrayList(u8),
    reasoning: *std.ArrayList(u8),
    stream: *ToolCallStream,
    observer: anytype,
) !void {
    const change = try parseStreamChunk(gpa, data, content, reasoning, stream);
    try applyChunkCallbacks(change, content.items, reasoning.items, stream.builders.items, observer);
}

pub fn parseStreamChunk(
    gpa: std.mem.Allocator,
    data: []const u8,
    content: *std.ArrayList(u8),
    reasoning: *std.ArrayList(u8),
    stream: *ToolCallStream,
) !ChunkChange {
    // Empty payloads carry no chunk (keep-alive lines). Return early rather than
    // feeding the scanner an empty document.
    if (data.len == 0) return .{};

    var scanner = Scanner.initCompleteInput(gpa, data);
    defer scanner.deinit();

    var change: ChunkChange = .{};
    try expectObjectBegin(&scanner);
    while (try nextObjectKey(&scanner)) |key| {
        if (std.mem.eql(u8, key, "choices")) {
            try parseChoicesArray(gpa, &scanner, content, reasoning, stream, &change);
        } else if (std.mem.eql(u8, key, "usage")) {
            try parseUsageValue(&scanner, &change.usage);
        } else {
            try scanner.skipValue();
        }
    }
    return change;
}

/// Parse the chat-completions `usage` value. Content chunks carry `usage:null`
/// (consumed and ignored); the final usage-only chunk carries the object.
fn parseUsageValue(scanner: *Scanner, usage: *?ai.Usage) !void {
    const peeked = try scanner.peekNextTokenType();
    if (peeked == .null) {
        _ = try scanner.next();
        return;
    }
    usage.* = try parseUsageObject(scanner);
}

/// Parse the chat-completions usage object. Captures the top-level totals
/// plus the optional `*_tokens_details` sub-objects (cached input tokens and
/// reasoning output tokens), mirroring the Responses API parser so both wire
/// dialects populate `ai.Usage` consistently.
fn parseUsageObject(scanner: *Scanner) !ai.Usage {
    try expectObjectBegin(scanner);
    var input_tokens: i64 = 0;
    var output_tokens: i64 = 0;
    var total_tokens: i64 = 0;
    var cached_input_tokens: i64 = 0;
    var reasoning_tokens: i64 = 0;
    while (try nextObjectKey(scanner)) |key| {
        if (std.mem.eql(u8, key, "prompt_tokens")) {
            input_tokens = try nextInteger(scanner);
        } else if (std.mem.eql(u8, key, "completion_tokens")) {
            output_tokens = try nextInteger(scanner);
        } else if (std.mem.eql(u8, key, "total_tokens")) {
            total_tokens = try nextInteger(scanner);
        } else if (std.mem.eql(u8, key, "prompt_tokens_details")) {
            cached_input_tokens = try parseNestedInteger(scanner, "cached_tokens");
        } else if (std.mem.eql(u8, key, "completion_tokens_details")) {
            reasoning_tokens = try parseNestedInteger(scanner, "reasoning_tokens");
        } else {
            try scanner.skipValue();
        }
    }
    return .{
        .input_tokens = ai.clampTokenCount(input_tokens),
        .output_tokens = ai.clampTokenCount(output_tokens),
        .total_tokens = ai.clampTokenCount(total_tokens),
        .cached_input_tokens = ai.clampTokenCount(cached_input_tokens),
        .reasoning_tokens = ai.clampTokenCount(reasoning_tokens),
    };
}

/// Parse an integer field from a nested object, skipping the rest of the
/// object. Returns 0 when the field is absent, not an integer, or the nested
/// value is not an object (some providers send `prompt_tokens_details: null`).
/// Mirrors the Responses API parser's leniency so a malformed details object
/// never fails the whole stream.
fn parseNestedInteger(scanner: *Scanner, field_name: []const u8) !i64 {
    const peeked = try scanner.peekNextTokenType();
    if (peeked != .object_begin) {
        try scanner.skipValue();
        return 0;
    }
    try expectObjectBegin(scanner);
    var value: i64 = 0;
    while (try nextObjectKey(scanner)) |key| {
        if (std.mem.eql(u8, key, field_name)) {
            value = try nextInteger(scanner);
        } else {
            try scanner.skipValue();
        }
    }
    return value;
}

fn parseChoicesArray(
    gpa: std.mem.Allocator,
    scanner: *Scanner,
    content: *std.ArrayList(u8),
    reasoning: *std.ArrayList(u8),
    stream: *ToolCallStream,
    change: *ChunkChange,
) !void {
    try expectArrayBegin(scanner);
    var saw_first = false;
    while (true) {
        const peeked = try scanner.peekNextTokenType();
        if (peeked == .array_end) {
            _ = try scanner.next();
            return;
        }
        if (saw_first) {
            try scanner.skipValue();
            continue;
        }
        try expectObjectBegin(scanner);
        try parseChoiceObject(gpa, scanner, content, reasoning, stream, change);
        saw_first = true;
    }
}

fn parseChoiceObject(
    gpa: std.mem.Allocator,
    scanner: *Scanner,
    content: *std.ArrayList(u8),
    reasoning: *std.ArrayList(u8),
    stream: *ToolCallStream,
    change: *ChunkChange,
) !void {
    while (try nextObjectKey(scanner)) |key| {
        if (std.mem.eql(u8, key, "delta")) {
            try parseDeltaObject(gpa, scanner, content, reasoning, stream, change);
        } else {
            try scanner.skipValue();
        }
    }
}

fn parseDeltaObject(
    gpa: std.mem.Allocator,
    scanner: *Scanner,
    content: *std.ArrayList(u8),
    reasoning: *std.ArrayList(u8),
    stream: *ToolCallStream,
    change: *ChunkChange,
) !void {
    try expectObjectBegin(scanner);
    while (try nextObjectKey(scanner)) |key| {
        if (std.mem.eql(u8, key, "content")) {
            const before: u32 = @intCast(content.items.len);
            const appended = try appendStringValue(scanner, gpa, content, .allow_null);
            if (appended) {
                if (content.items.len > before) change.content_start = before;
            }
        } else if (std.mem.eql(u8, key, "reasoning") or
            std.mem.eql(u8, key, "reasoning_content") or
            std.mem.eql(u8, key, "thinking"))
        {
            // `reasoning`/`reasoning_content` are the OpenAI-compatible field
            // names (Ollama's /v1/chat/completions uses `reasoning` in the
            // delta; DeepSeek and others use `reasoning_content`). `thinking`
            // is Ollama's native /api/chat name — never on the /v1 path we
            // use, but some OpenAI-compatible proxies forward it verbatim, so
            // recognise it as a fallback to avoid silently dropping reasoning.
            const before: u32 = @intCast(reasoning.items.len);
            const appended = try appendStringValue(scanner, gpa, reasoning, .allow_null);
            if (appended) {
                if (reasoning.items.len > before) change.reasoning_start = before;
            }
        } else if (std.mem.eql(u8, key, "tool_calls")) {
            try parseToolCallsArray(gpa, scanner, stream, change);
        } else {
            try scanner.skipValue();
        }
    }
}

fn parseToolCallsArray(
    gpa: std.mem.Allocator,
    scanner: *Scanner,
    stream: *ToolCallStream,
    change: *ChunkChange,
) !void {
    try expectArrayBegin(scanner);
    while (true) {
        const peeked = try scanner.peekNextTokenType();
        if (peeked == .array_end) {
            _ = try scanner.next();
            return;
        }
        try expectObjectBegin(scanner);
        try parseToolCallObject(gpa, scanner, stream, change);
    }
}

fn parseToolCallObject(
    gpa: std.mem.Allocator,
    scanner: *Scanner,
    stream: *ToolCallStream,
    change: *ChunkChange,
) !void {
    var pending: ToolCallBuilder = .{};
    defer pending.deinit(gpa);
    var has_pending_id = false;
    var has_pending_name = false;
    var has_pending_arguments = false;
    var resolved_index: ?u32 = null;
    var accept = true;

    while (try nextObjectKey(scanner)) |key| {
        if (std.mem.eql(u8, key, "index")) {
            const index = try nextInteger(scanner);
            if (index < 0) return error.InvalidToolCallIndex;
            if (index >= tool_call_array_cap) return error.TooManyToolCalls;
            if (index >= stream.max_calls) {
                log.warn("parseToolCall.reject index={d} exceeds max_parallel_tool_calls={d} model={s}", .{ index, stream.max_calls, stream.model });
                stream.dropped += 1;
                accept = false;
                continue;
            }
            resolved_index = @intCast(index);
        } else if (std.mem.eql(u8, key, "id")) {
            // runinfra's DashScope-hosted Qwen emits `"id": null` on every
            // tool_call delta EXCEPT the first (which carries the real id),
            // and sometimes `"name": null` too. Treat null as "not provided":
            // don't set the has_pending flag so a later real value wins, and
            // `toToolCall` falls back to a synthetic `call_{seq}` id when the
            // whole call streamed without one. `.reject_null` used to raise
            // error.UnexpectedToken here, aborting the ENTIRE turn after
            // thinking had streamed (user-visible: "agent turn failed:
            // UnexpectedToken", no final message).
            if (try appendStringValue(scanner, gpa, &pending.id, .allow_null)) {
                has_pending_id = true;
            }
        } else if (std.mem.eql(u8, key, "function")) {
            try parseToolCallFunction(gpa, scanner, &pending, &has_pending_name, &has_pending_arguments);
        } else {
            try scanner.skipValue();
        }
    }

    if (!accept) return;

    // Some OpenAI-compatible providers (e.g. Google Gemini via the OpenAI
    // compatibility layer) omit the `index` field entirely. Append such calls
    // to the end so a missing index never silently drops the tool call. The
    // same cap that guards explicit indices applies here — the remap arrays
    // are sized `tool_call_array_cap`, so an unbounded append would overflow
    // them.
    const logical = resolved_index orelse blk: {
        const next: u32 = @intCast(stream.builders.items.len);
        if (next >= tool_call_array_cap) return error.TooManyToolCalls;
        if (next >= stream.max_calls) {
            log.warn("parseToolCall.reject index={d} exceeds max_parallel_tool_calls={d} model={s}", .{ next, stream.max_calls, stream.model });
            stream.dropped += 1;
            accept = false;
            break :blk 0;
        }
        break :blk next;
    };

    if (!accept) return;
    while (stream.builders.items.len <= logical) try stream.builders.append(gpa, .{});

    // Detect ID collision: same logical index but a different tool-call ID.
    // This happens when a provider reuses index 0 for parallel tool calls.
    // Fork a new physical slot and remap this logical index to it.
    //
    // Also detect ID duplication: different logical index but the same ID.
    // Some providers (Qwen/DashScope) echo the same tool-call ID across
    // multiple indices. Remap this logical index to the existing builder
    // so argument chunks accumulate in one place instead of creating an
    // empty duplicate.
    if (has_pending_id) {
        // Merge: same ID already lives in another physical slot.
        for (stream.builders.items, 0..) |*existing, i| {
            if (existing.id.items.len == 0) continue;
            if (!std.mem.eql(u8, existing.id.items, pending.id.items)) continue;
            const existing_physical: u32 = @intCast(i);
            if (existing_physical != stream.physicalSlot(logical)) {
                log.info("parseToolCall.merge logical={d} → physical={d} id={s}", .{ logical, existing_physical, pending.id.items });
                stream.remapped_slot[logical] = existing_physical;
                stream.is_remapped[logical] = true;
            }
            break;
        }
        // Fork: same logical index, different ID → new physical slot.
        const current = stream.physicalSlot(logical);
        const existing = &stream.builders.items[@as(usize, current)];
        if (existing.id.items.len > 0 and !std.mem.eql(u8, existing.id.items, pending.id.items)) {
            const new_slot: u32 = @intCast(stream.builders.items.len);
            // The fork creates a builder just like the explicit-index and
            // index-less paths above, so it honours the same cap — otherwise a
            // provider reusing `index: 0` for many parallel calls would fork
            // past max_parallel_tool_calls while `dropped` stays 0 (the literal
            // index is always 0, so the line-`index` guard never trips) and
            // every forked builder would be emitted by the final assembly loop.
            if (new_slot >= stream.max_calls) {
                log.warn("parseToolCall.fork.reject new_slot={d} exceeds max_parallel_tool_calls={d} model={s}", .{ new_slot, stream.max_calls, stream.model });
                stream.dropped += 1;
                return; // `pending` freed by the defer above; do not append or remap.
            }
            log.info("parseToolCall.fork logical={d} → new_slot={d} old_id={s} new_id={s}", .{ logical, new_slot, existing.id.items, pending.id.items });
            try stream.builders.append(gpa, .{});
            stream.remapped_slot[logical] = new_slot;
            stream.is_remapped[logical] = true;
        }
    }

    const physical = stream.physicalSlot(logical);
    const target = &stream.builders.items[@as(usize, physical)];

    // Names and IDs are atomic in streaming — first complete value wins.
    if (has_pending_id and target.id.items.len == 0) {
        try target.id.appendSlice(gpa, pending.id.items);
    }
    if (has_pending_name and target.name.items.len == 0) {
        try target.name.appendSlice(gpa, pending.name.items);
    }
    if (has_pending_arguments) try target.arguments.appendSlice(gpa, pending.arguments.items);
    change.recordToolCall(physical);
}

fn parseToolCallFunction(
    gpa: std.mem.Allocator,
    scanner: *Scanner,
    pending: *ToolCallBuilder,
    has_pending_name: *bool,
    has_pending_arguments: *bool,
) !void {
    try expectObjectBegin(scanner);
    while (try nextObjectKey(scanner)) |key| {
        if (std.mem.eql(u8, key, "name")) {
            // See parseToolCallObject: providers may stream `"name": null`
            // on continuation deltas. Null must not raise or clear state;
            // only a real string marks the name as seen.
            if (try appendStringValue(scanner, gpa, &pending.name, .allow_null)) {
                has_pending_name.* = true;
            }
        } else if (std.mem.eql(u8, key, "arguments")) {
            // Same reasoning as name: only a real string contributes. Some
            // providers emit an explicit `"arguments": null` alongside the
            // id/name nulls in what is otherwise a pure bookkeeping delta.
            if (try appendStringValue(scanner, gpa, &pending.arguments, .allow_null)) {
                has_pending_arguments.* = true;
            }
        } else {
            try scanner.skipValue();
        }
    }
}

fn expectObjectBegin(scanner: *Scanner) !void {
    const token = try scanner.next();
    if (token != .object_begin) return error.UnexpectedToken;
}

fn expectArrayBegin(scanner: *Scanner) !void {
    const token = try scanner.next();
    if (token != .array_begin) return error.UnexpectedToken;
}

fn nextObjectKey(scanner: *Scanner) !?[]const u8 {
    const token = try scanner.next();
    return switch (token) {
        .object_end => null,
        .string => |s| s,
        else => error.UnexpectedToken,
    };
}

fn nextInteger(scanner: *Scanner) !i64 {
    const token = try scanner.next();
    const text = switch (token) {
        .number => |s| s,
        else => return error.UnexpectedToken,
    };
    return try std.fmt.parseInt(i64, text, 10);
}

const NullStringPolicy = enum { allow_null, reject_null };

fn appendStringValue(
    scanner: *Scanner,
    gpa: std.mem.Allocator,
    list: *std.ArrayList(u8),
    null_policy: NullStringPolicy,
) !bool {
    while (true) {
        const token = try scanner.next();
        switch (token) {
            .null => switch (null_policy) {
                .allow_null => return false,
                .reject_null => return error.UnexpectedToken,
            },
            .string => |s| {
                try list.appendSlice(gpa, s);
                return true;
            },
            .partial_string => |s| try list.appendSlice(gpa, s),
            .partial_string_escaped_1 => |bytes| try list.appendSlice(gpa, &bytes),
            .partial_string_escaped_2 => |bytes| try list.appendSlice(gpa, &bytes),
            .partial_string_escaped_3 => |bytes| try list.appendSlice(gpa, &bytes),
            .partial_string_escaped_4 => |bytes| try list.appendSlice(gpa, &bytes),
            else => return error.UnexpectedToken,
        }
    }
}

test "parseStreamChunk handles thinking field in delta" {
    // Ollama's /v1/chat/completions surfaces reasoning in `delta.reasoning`,
    // but its native /api/chat uses `delta.thinking`. Some OpenAI-compatible
    // proxies forward `thinking` verbatim — recognise it so reasoning content
    // is not silently dropped.
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: ToolCallStream = .{};
    defer stream.deinit(gpa);

    const change = try parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"thinking":"let me reason about this"}}]}
    , &content, &reasoning, &stream);
    try std.testing.expect(change.reasoning_start != null);
    try std.testing.expectEqualStrings("let me reason about this", reasoning.items);
    try std.testing.expectEqualStrings("", content.items);
}

test "parseStreamChunk handles reasoning field in delta" {
    // Ollama /v1/chat/completions canonical field name for thinking content.
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: ToolCallStream = .{};
    defer stream.deinit(gpa);

    const change = try parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"reasoning":"step by step"}}]}
    , &content, &reasoning, &stream);
    try std.testing.expect(change.reasoning_start != null);
    try std.testing.expectEqualStrings("step by step", reasoning.items);
}

test "parse streaming tool call with no index appends to the end" {
    // Some OpenAI-compatible providers (Google Gemini via the OpenAI compat
    // layer) omit the `index` field. A missing index must not silently drop
    // the tool call.
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: ToolCallStream = .{};
    defer stream.deinit(gpa);

    _ = try parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"id":"call_1","function":{"name":"bash","arguments":"{\"command\":\"ls\"}"}}]}}]}
    , &content, &reasoning, &stream);

    try std.testing.expectEqual(@as(usize, 1), stream.builders.items.len);
    try std.testing.expectEqualStrings("call_1", stream.builders.items[0].id.items);
    try std.testing.expectEqualStrings("bash", stream.builders.items[0].name.items);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", stream.builders.items[0].arguments.items);
}

test "readStream drops tool calls whose index exceeds max_calls" {
    // Regression guard for the L3 model-attribution change: the new `model`
    // param is accepted and never changes the over-cap drop behaviour.
    // (The logger line itself isn't captured by tests; this asserts the
    // observable contract — the call at index 1 is dropped and the turn
    // returns successfully with zero accepted builders.)
    const gpa = std.testing.allocator;
    // max_calls = 1, but the delta claims index 1 → drop.
    const stream =
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"call_x\",\"function\":{\"name\":\"bash\",\"arguments\":\"{}\"}}]}}]}\n" ++
        "data: [DONE]\n";
    var reader: std.Io.Reader = .fixed(stream);
    var tool_call_seq: u64 = 0;
    var turn = try readStream(gpa, &reader, ai.streamNoop(), &tool_call_seq, 1, "ling-3.0-flash");
    defer turn.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), turn.assistant.assistant.content.len);
}

test "readStream drops index-less tool calls beyond max_calls" {
    // The index-less fallback appends to the end; it must respect the same
    // max_parallel_tool_calls cap so the remap arrays can't overflow.
    const gpa = std.testing.allocator;
    // max_calls = 1, but two index-less tool calls arrive → the second append
    // would land at index 1, which exceeds the cap → drop. The first call
    // survives and becomes a content block.
    const stream =
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_1\",\"function\":{\"name\":\"bash\",\"arguments\":\"{}\"}}]}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_2\",\"function\":{\"name\":\"bash\",\"arguments\":\"{}\"}}]}}]}\n" ++
        "data: [DONE]\n";
    var reader: std.Io.Reader = .fixed(stream);
    var tool_call_seq: u64 = 0;
    var turn = try readStream(gpa, &reader, ai.streamNoop(), &tool_call_seq, 1, "ling-3.0-flash");
    defer turn.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), turn.assistant.assistant.content.len);
    try std.testing.expect(turn.assistant.assistant.content[0] == .tool_call);
    try std.testing.expectEqualStrings("bash", turn.assistant.assistant.content[0].tool_call.name);
    try std.testing.expectEqualStrings("call_1", turn.assistant.assistant.content[0].tool_call.call_id.slice());
}

test "readStream drops forked tool calls beyond max_calls (provider reuses index 0)" {
    // A provider that reuses `index: 0` for parallel calls forks each new ID
    // into a fresh physical slot. The fork path must honour
    // max_parallel_tool_calls just like the explicit-index and index-less
    // paths — otherwise the literal index (always 0) never trips the per-index
    // guard and the cap is silently bypassed. max_calls = 1: the first call
    // survives; the second (different ID, same index 0) would fork to slot 1
    // and is dropped.
    const gpa = std.testing.allocator;
    const stream =
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_a\",\"function\":{\"name\":\"bash\",\"arguments\":\"{}\"}}]}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_b\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{}\"}}]}}]}\n" ++
        "data: [DONE]\n";
    var reader: std.Io.Reader = .fixed(stream);
    var tool_call_seq: u64 = 0;
    var turn = try readStream(gpa, &reader, ai.streamNoop(), &tool_call_seq, 1, "ling-3.0-flash");
    defer turn.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), turn.assistant.assistant.content.len);
    try std.testing.expect(turn.assistant.assistant.content[0] == .tool_call);
    try std.testing.expectEqualStrings("bash", turn.assistant.assistant.content[0].tool_call.name);
    try std.testing.expectEqualStrings("call_a", turn.assistant.assistant.content[0].tool_call.call_id.slice());
}

const TestObserverCtx = struct {
    allocator: std.mem.Allocator,
    content: std.ArrayList(u8),
    reasoning: std.ArrayList(u8),
    tool_calls: std.ArrayList(ai.ToolDelta),
    delta_ends: usize = 0,
};

const TestObserver = struct {
    fn onContent(ctx: *TestObserverCtx, bytes: []const u8) !void {
        try ctx.content.appendSlice(ctx.allocator, bytes);
    }

    fn onReasoning(ctx: *TestObserverCtx, bytes: []const u8) !void {
        try ctx.reasoning.appendSlice(ctx.allocator, bytes);
    }

    fn onToolDelta(ctx: *TestObserverCtx, delta: ai.ToolDelta) !void {
        // We have to dupe since the delta strings belong to the stream builder
        const name_duped = try ctx.allocator.dupe(u8, delta.name);
        const args_duped = try ctx.allocator.dupe(u8, delta.arguments);
        try ctx.tool_calls.append(ctx.allocator, .{
            .index = delta.index,
            .name = name_duped,
            .arguments = args_duped,
        });
    }

    fn onDeltaEnd(ctx: *TestObserverCtx) !void {
        ctx.delta_ends += 1;
    }
};

fn createTestObserver(ctx: *TestObserverCtx) ai.StreamObserver(TestObserverCtx) {
    return .{
        .ctx = ctx,
        .on_content = TestObserver.onContent,
        .on_reasoning = TestObserver.onReasoning,
        .on_tool_delta = TestObserver.onToolDelta,
        .on_delta_end = TestObserver.onDeltaEnd,
    };
}

test "processStreamChunk handles content and reasoning correctly" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: ToolCallStream = .{};
    defer stream.deinit(gpa);

    var observer_ctx = TestObserverCtx{
        .content = .empty,
        .reasoning = .empty,
        .tool_calls = .empty,
        .allocator = gpa,
    };
    defer {
        observer_ctx.content.deinit(gpa);
        observer_ctx.reasoning.deinit(gpa);
        for (observer_ctx.tool_calls.items) |delta| {
            gpa.free(delta.name);
            gpa.free(delta.arguments);
        }
        observer_ctx.tool_calls.deinit(gpa);
    }
    const observer = createTestObserver(&observer_ctx);

    const chunk = "{\"choices\":[{\"delta\":{\"content\":\"hello\", \"reasoning\":\"thinking\"}}]}";

    try processStreamChunk(gpa, chunk, &content, &reasoning, &stream, observer);

    try std.testing.expectEqualStrings("hello", observer_ctx.content.items);
    try std.testing.expectEqualStrings("thinking", observer_ctx.reasoning.items);
    try std.testing.expectEqual(@as(usize, 0), observer_ctx.tool_calls.items.len);
    try std.testing.expectEqual(@as(usize, 1), observer_ctx.delta_ends);
}

test "processStreamChunk calls observer for tool deltas" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: ToolCallStream = .{};
    defer stream.deinit(gpa);

    var observer_ctx = TestObserverCtx{
        .allocator = gpa,
        .content = .empty,
        .reasoning = .empty,
        .tool_calls = .empty,
    };
    defer {
        observer_ctx.content.deinit(gpa);
        observer_ctx.reasoning.deinit(gpa);
        for (observer_ctx.tool_calls.items) |delta| {
            gpa.free(delta.name);
            gpa.free(delta.arguments);
        }
        observer_ctx.tool_calls.deinit(gpa);
    }
    const observer = createTestObserver(&observer_ctx);

    const chunk1 = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"bash\",\"arguments\":\"\"}}]}}]}";
    const chunk2 = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}}]}}]}";

    try processStreamChunk(gpa, chunk1, &content, &reasoning, &stream, observer);
    try processStreamChunk(gpa, chunk2, &content, &reasoning, &stream, observer);

    try std.testing.expectEqualStrings("", observer_ctx.content.items);
    try std.testing.expectEqualStrings("", observer_ctx.reasoning.items);
    try std.testing.expectEqual(@as(usize, 2), observer_ctx.tool_calls.items.len);
    try std.testing.expectEqualStrings("bash", observer_ctx.tool_calls.items[0].name);
    try std.testing.expectEqualStrings("", observer_ctx.tool_calls.items[0].arguments);
    try std.testing.expectEqualStrings("bash", observer_ctx.tool_calls.items[1].name);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", observer_ctx.tool_calls.items[1].arguments);
    try std.testing.expectEqual(@as(usize, 2), observer_ctx.delta_ends);
}

test "readStream tolerates DashScope null id/name on tool-call continuation deltas" {
    // Live wire format from runinfra's DashScope-hosted Qwen3 with
    // `enable_thinking:true`: the FIRST tool_calls chunk carries the real
    // `id`, every subsequent delta echoes `"id": null` (and often
    // `"name": null`) while streaming `arguments`. The parser used
    // `.reject_null` for id/name/arguments, so any continuation delta
    // aborted the WHOLE turn with error.UnexpectedToken after thinking had
    // streamed — user-visible as "agent turn failed: UnexpectedToken" with
    // no final message. Regression: the full turn must survive with one
    // assembled tool call (first real value wins, args concatenated).
    const gpa = std.testing.allocator;
    const stream =
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking about it\"}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_82d42ab2797b4205b00c8509\",\"index\":0,\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"\"}}]}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":null,\"index\":0,\"type\":\"function\",\"function\":{\"name\":null,\"arguments\":\"{\"}}]}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":null,\"index\":0,\"type\":\"function\",\"function\":{\"arguments\":\"\\\"command\\\":\\\"echo 6\\\"\"}}]}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":null,\"index\":0,\"type\":\"function\",\"function\":{\"arguments\":\"}\"}}]}}]}\n" ++
        "data: [DONE]\n";
    var reader: std.Io.Reader = .fixed(stream);
    var tool_call_seq: u64 = 0;
    var turn = try readStream(gpa, &reader, ai.streamNoop(), &tool_call_seq, 16, "qwen3-8-27b");
    defer turn.deinit(gpa);

    // Reasoning must have streamed into the turn.
    try std.testing.expectEqual(@as(usize, 2), turn.assistant.assistant.content.len);
    try std.testing.expect(turn.assistant.assistant.content[0] == .reasoning);
    try std.testing.expect(turn.assistant.assistant.content[1] == .tool_call);
    const call = turn.assistant.assistant.content[1].tool_call;
    try std.testing.expectEqualStrings("bash", call.name);
    try std.testing.expectEqualStrings("call_82d42ab2797b4205b00c8509", call.call_id.slice());
    try std.testing.expectEqualStrings("{\"command\":\"echo 6\"}", call.arguments);
}

test "processStreamChunk does not call on_delta_end for empty chunks" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: ToolCallStream = .{};
    defer stream.deinit(gpa);

    var observer_ctx = TestObserverCtx{
        .allocator = gpa,
        .content = .empty,
        .reasoning = .empty,
        .tool_calls = .empty,
    };
    defer {
        observer_ctx.content.deinit(gpa);
        observer_ctx.reasoning.deinit(gpa);
        for (observer_ctx.tool_calls.items) |delta| {
            gpa.free(delta.name);
            gpa.free(delta.arguments);
        }
        observer_ctx.tool_calls.deinit(gpa);
    }
    const observer = createTestObserver(&observer_ctx);

    // Empty payload (keep-alive)
    const chunk = "";

    try processStreamChunk(gpa, chunk, &content, &reasoning, &stream, observer);

    try std.testing.expectEqualStrings("", observer_ctx.content.items);
    try std.testing.expectEqualStrings("", observer_ctx.reasoning.items);
    try std.testing.expectEqual(@as(usize, 0), observer_ctx.tool_calls.items.len);
    try std.testing.expectEqual(@as(usize, 0), observer_ctx.delta_ends);
}
