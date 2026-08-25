//! SSE event decoding and block accumulation for the Responses API.
//!
//! Extracted from responses_core.zig: parses SSE data events, extracts usage
//! information, tracks parallel function call deltas, and updates the assistant
//! message block state.

const std = @import("std");
const log = std.log.scoped(.ai);

const ai = @import("../ai.zig");

pub const ToolBuilder = struct {
    call_id: std.ArrayList(u8) = .empty,
    item_id: std.ArrayList(u8) = .empty,
    output_index: ?u32 = null,
    block_index: u32 = 0,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *ToolBuilder, gpa: std.mem.Allocator) void {
        self.call_id.deinit(gpa);
        self.item_id.deinit(gpa);
        self.name.deinit(gpa);
        self.arguments.deinit(gpa);
        self.* = undefined;
    }
};

pub const StreamState = struct {
    blocks: std.ArrayList(ai.ContentBlock) = .empty,
    tools: std.ArrayList(ToolBuilder) = .empty,
    completed: bool = false,
    usage: ?ai.Usage = null,

    pub fn deinit(self: *StreamState, gpa: std.mem.Allocator) void {
        for (self.tools.items) |*tool| tool.deinit(gpa);
        self.tools.deinit(gpa);
    }

    pub fn deinitBlocks(self: *StreamState, gpa: std.mem.Allocator) void {
        for (self.blocks.items) |*block| block.deinit(gpa);
        self.blocks.deinit(gpa);
    }

    pub fn processJson(self: *StreamState, gpa: std.mem.Allocator, data: []const u8, observer: anytype, call_seq: *u64) !void {
        try processEvent(gpa, data, &self.blocks, &self.tools, observer, call_seq, &self.completed, &self.usage);
    }

    pub fn finish(self: *StreamState, gpa: std.mem.Allocator, call_seq: *u64) !ai.Turn {
        if (!self.completed) return error.ResponseIncomplete;
        try syncToolBlocks(gpa, &self.blocks, self.tools.items, call_seq);
        const content = try self.blocks.toOwnedSlice(gpa);
        self.blocks = .empty;
        return .{ .assistant = .{ .assistant = .{ .content = content } }, .usage = self.usage };
    }
};

pub fn processEvent(
    gpa: std.mem.Allocator,
    data: []const u8,
    blocks: *std.ArrayList(ai.ContentBlock),
    tools: *std.ArrayList(ToolBuilder),
    observer: anytype,
    call_seq: *u64,
    completed: *bool,
    usage: *?ai.Usage,
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const type_value = parsed.value.object.get("type") orelse return;
    if (type_value != .string) return;
    const event_type = responseEventFromString(type_value.string) orelse {
        log.warn("responses.response.ignored_event type={s}", .{type_value.string});
        return;
    };
    switch (event_type) {
        .provider_error => return error.ProviderError,
        .completed => {
            completed.* = true;
            usage.* = parseResponseUsage(parsed.value);
            return;
        },
        .lifecycle => return,
        .output_item_added => return onItemAdded(gpa, parsed.value, blocks, tools, call_seq),
        .content_part_added => return onContentPartAdded(gpa, parsed.value, blocks),
        .output_text_delta => return onTextDelta(gpa, parsed.value, blocks, observer),
        .refusal_delta => return onTextDelta(gpa, parsed.value, blocks, observer),
        .reasoning_text_delta => return onReasoningDelta(gpa, parsed.value, blocks, observer),
        .reasoning_summary_text_delta => return onReasoningDelta(gpa, parsed.value, blocks, observer),
        .reasoning_summary_part_done => return onReasoningSummaryPartDone(gpa, blocks, observer),
        .function_call_arguments_delta => return onArgumentsDelta(gpa, parsed.value, blocks, tools, observer),
        .function_call_arguments_done => return onArgumentsDone(gpa, parsed.value, blocks, tools, observer),
        .output_item_done => return onItemDone(gpa, parsed.value, blocks, tools, observer),
    }
}

/// Extract `response.usage` from a `response.completed` event. Returns null
/// when the event carries no usage (e.g. the synthetic completed events in
/// tests). The Responses API names tokens `input_tokens`/`output_tokens`,
/// unlike Chat Completions — see `ai.Usage`.
pub fn parseResponseUsage(event: std.json.Value) ?ai.Usage {
    const response = event.object.get("response") orelse return null;
    if (response != .object) return null;
    const usage = response.object.get("usage") orelse return null;
    if (usage != .object) return null;
    return .{
        .input_tokens = usageInteger(usage, "input_tokens"),
        .output_tokens = usageInteger(usage, "output_tokens"),
        .total_tokens = usageInteger(usage, "total_tokens"),
        .cached_input_tokens = usageNestedInteger(usage, "input_tokens_details", "cached_tokens"),
        .reasoning_tokens = usageNestedInteger(usage, "output_tokens_details", "reasoning_tokens"),
    };
}

fn usageInteger(usage: std.json.Value, name: []const u8) u32 {
    const field = usage.object.get(name) orelse return 0;
    if (field != .integer) return 0;
    return ai.clampTokenCount(field.integer);
}

fn usageNestedInteger(usage: std.json.Value, object_name: []const u8, field_name: []const u8) u32 {
    const nested = usage.object.get(object_name) orelse return 0;
    if (nested != .object) return 0;
    const field = nested.object.get(field_name) orelse return 0;
    if (field != .integer) return 0;
    return ai.clampTokenCount(field.integer);
}

pub const ResponseEvent = enum {
    provider_error,
    completed,
    lifecycle,
    output_item_added,
    content_part_added,
    output_text_delta,
    refusal_delta,
    reasoning_text_delta,
    reasoning_summary_text_delta,
    reasoning_summary_part_done,
    function_call_arguments_delta,
    function_call_arguments_done,
    output_item_done,
};

pub const ResponseEventSpec = struct {
    name: []const u8,
    event: ResponseEvent,
};

pub const response_event_specs = [_]ResponseEventSpec{
    .{ .name = "error", .event = .provider_error },
    .{ .name = "response.failed", .event = .provider_error },
    .{ .name = "response.completed", .event = .completed },
    // Lifecycle/telemetry events carry no assistant content. Recognize them so
    // Codex does not turn normal WebSocket protocol traffic into warnings.
    .{ .name = "response.created", .event = .lifecycle },
    .{ .name = "response.in_progress", .event = .lifecycle },
    .{ .name = "response.content_part.done", .event = .lifecycle },
    .{ .name = "response.output_text.done", .event = .lifecycle },
    .{ .name = "response.reasoning_summary_part.added", .event = .lifecycle },
    .{ .name = "response.reasoning_summary_text.done", .event = .lifecycle },
    .{ .name = "codex.rate_limits", .event = .lifecycle },
    .{ .name = "codex.response.metadata", .event = .lifecycle },
    .{ .name = "responsesapi.websocket_timing", .event = .lifecycle },
    .{ .name = "response.output_item.added", .event = .output_item_added },
    .{ .name = "response.content_part.added", .event = .content_part_added },
    .{ .name = "response.output_text.delta", .event = .output_text_delta },
    .{ .name = "response.refusal.delta", .event = .refusal_delta },
    .{ .name = "response.reasoning_text.delta", .event = .reasoning_text_delta },
    .{ .name = "response.reasoning_summary_text.delta", .event = .reasoning_summary_text_delta },
    .{ .name = "response.reasoning_summary_part.done", .event = .reasoning_summary_part_done },
    .{ .name = "response.function_call_arguments.delta", .event = .function_call_arguments_delta },
    .{ .name = "response.function_call_arguments.done", .event = .function_call_arguments_done },
    .{ .name = "response.output_item.done", .event = .output_item_done },
};

pub fn responseEventFromString(name: []const u8) ?ResponseEvent {
    for (response_event_specs) |spec| {
        if (std.mem.eql(u8, name, spec.name)) return spec.event;
    }
    return null;
}

fn onItemAdded(gpa: std.mem.Allocator, value: std.json.Value, blocks: *std.ArrayList(ai.ContentBlock), tools: *std.ArrayList(ToolBuilder), call_seq: *u64) !void {
    const item = value.object.get("item") orelse return;
    if (item != .object) return;
    const kind = item.object.get("type") orelse return;
    if (kind != .string) return;
    if (std.mem.eql(u8, kind.string, "message")) {
        try blocks.append(gpa, .{ .text = .{ .text = try gpa.alloc(u8, 0), .responses_item_id = try optionalString(gpa, item, "id") } });
    } else if (std.mem.eql(u8, kind.string, "reasoning")) {
        const raw = try std.json.Stringify.valueAlloc(gpa, item, .{});
        try blocks.append(gpa, .{ .reasoning = .{ .text = try gpa.alloc(u8, 0), .responses_item_json = raw } });
    } else if (std.mem.eql(u8, kind.string, "function_call")) {
        var builder: ToolBuilder = .{};
        errdefer builder.deinit(gpa);
        builder.output_index = optionalU32(value, "output_index");
        if (try optionalString(gpa, item, "call_id")) |id| {
            defer gpa.free(id);
            try builder.call_id.appendSlice(gpa, id);
        }
        if (try optionalString(gpa, item, "id")) |id| {
            defer gpa.free(id);
            try builder.item_id.appendSlice(gpa, id);
        }
        if (try optionalString(gpa, item, "name")) |name| {
            defer gpa.free(name);
            try builder.name.appendSlice(gpa, name);
        }
        if (try optionalString(gpa, item, "arguments")) |args| {
            defer gpa.free(args);
            try builder.arguments.appendSlice(gpa, args);
        }
        if (builder.call_id.items.len == 0) {
            const minted = try std.fmt.allocPrint(gpa, "call_{d}", .{call_seq.*});
            defer gpa.free(minted);
            try builder.call_id.appendSlice(gpa, minted);
            call_seq.* += 1;
        }
        builder.block_index = @intCast(blocks.items.len);
        try blocks.append(gpa, .{ .tool_call = .{
            .call_id = .{ .value = try gpa.dupe(u8, builder.call_id.items) },
            .responses_item_id = if (builder.item_id.items.len > 0) try gpa.dupe(u8, builder.item_id.items) else null,
            .name = try gpa.dupe(u8, builder.name.items),
            .arguments = try gpa.dupe(u8, builder.arguments.items),
        } });
        try tools.append(gpa, builder);
    }
}

fn onContentPartAdded(gpa: std.mem.Allocator, value: std.json.Value, blocks: *std.ArrayList(ai.ContentBlock)) !void {
    const part = value.object.get("part") orelse return;
    if (part != .object) return;
    const kind = part.object.get("type") orelse return;
    if (kind != .string) return;
    if (!std.mem.eql(u8, kind.string, "output_text")) {
        if (!std.mem.eql(u8, kind.string, "refusal")) return;
    }
    if (blocks.items.len > 0) {
        if (blocks.items[blocks.items.len - 1] == .text) return;
    }
    try blocks.append(gpa, .{ .text = .{ .text = try gpa.alloc(u8, 0) } });
}

fn onItemDone(gpa: std.mem.Allocator, value: std.json.Value, blocks: *std.ArrayList(ai.ContentBlock), tools: *std.ArrayList(ToolBuilder), observer: anytype) !void {
    const item = value.object.get("item") orelse return;
    if (item != .object) return;
    const kind = item.object.get("type") orelse return;
    if (kind != .string) return;
    if (std.mem.eql(u8, kind.string, "message")) {
        const text = outputTextFromItem(item) orelse return;
        try finishTextBlock(gpa, blocks, observer, text);
        return;
    }
    if (std.mem.eql(u8, kind.string, "reasoning")) {
        const raw = try std.json.Stringify.valueAlloc(gpa, item, .{});
        errdefer gpa.free(raw);
        const index = lastReasoningBlock(blocks.items) orelse return;
        if (blocks.items[index].reasoning.responses_item_json) |old| gpa.free(old);
        blocks.items[index].reasoning.responses_item_json = raw;
        return;
    }
    if (std.mem.eql(u8, kind.string, "function_call")) {
        const index = (try updateToolFromItem(gpa, item, tools.items)) orelse return;
        try syncOneToolBlock(gpa, blocks, &tools.items[index]);
        try observer.on_tool_delta(observer.ctx, .{ .index = index, .name = tools.items[index].name.items, .arguments = tools.items[index].arguments.items });
        try observer.on_delta_end(observer.ctx);
    }
}

fn outputTextFromItem(item: std.json.Value) ?[]const u8 {
    const content = item.object.get("content") orelse return null;
    if (content != .array) return null;
    for (content.array.items) |part| {
        if (part != .object) continue;
        const kind = part.object.get("type") orelse continue;
        if (kind != .string) continue;
        if (std.mem.eql(u8, kind.string, "output_text")) {
            const text = part.object.get("text") orelse return null;
            if (text != .string) return null;
            return text.string;
        }
        if (std.mem.eql(u8, kind.string, "refusal")) {
            const refusal = part.object.get("refusal") orelse return null;
            if (refusal != .string) return null;
            return refusal.string;
        }
    }
    return null;
}

fn onTextDelta(gpa: std.mem.Allocator, value: std.json.Value, blocks: *std.ArrayList(ai.ContentBlock), observer: anytype) !void {
    const delta = stringField(value, "delta") orelse return;
    var index = blocks.items.len;
    while (index > 0) {
        index -= 1;
        if (blocks.items[index] != .text) continue;
        const old = blocks.items[index].text.text;
        blocks.items[index].text.text = try appendOwned(gpa, old, delta);
        try observer.on_content(observer.ctx, delta);
        try observer.on_delta_end(observer.ctx);
        return;
    }
}

fn onReasoningDelta(gpa: std.mem.Allocator, value: std.json.Value, blocks: *std.ArrayList(ai.ContentBlock), observer: anytype) !void {
    const delta = stringField(value, "delta") orelse return;
    var index = blocks.items.len;
    while (index > 0) {
        index -= 1;
        if (blocks.items[index] != .reasoning) continue;
        const old = blocks.items[index].reasoning.text;
        blocks.items[index].reasoning.text = try appendOwned(gpa, old, delta);
        try observer.on_reasoning(observer.ctx, delta);
        try observer.on_delta_end(observer.ctx);
        return;
    }
}

fn onArgumentsDelta(gpa: std.mem.Allocator, value: std.json.Value, blocks: *std.ArrayList(ai.ContentBlock), tools: *std.ArrayList(ToolBuilder), observer: anytype) !void {
    const delta = stringField(value, "delta") orelse return;
    const index = toolIndexForEvent(value, tools.items) orelse return;
    try tools.items[index].arguments.appendSlice(gpa, delta);
    try syncOneToolBlock(gpa, blocks, &tools.items[index]);
    try observer.on_tool_delta(observer.ctx, .{ .index = index, .name = tools.items[index].name.items, .arguments = tools.items[index].arguments.items });
    try observer.on_delta_end(observer.ctx);
}

fn onArgumentsDone(gpa: std.mem.Allocator, value: std.json.Value, blocks: *std.ArrayList(ai.ContentBlock), tools: *std.ArrayList(ToolBuilder), observer: anytype) !void {
    const arguments = stringField(value, "arguments") orelse return;
    const index = toolIndexForEvent(value, tools.items) orelse return;
    tools.items[index].arguments.clearRetainingCapacity();
    try tools.items[index].arguments.appendSlice(gpa, arguments);
    try syncOneToolBlock(gpa, blocks, &tools.items[index]);
    try observer.on_tool_delta(observer.ctx, .{ .index = index, .name = tools.items[index].name.items, .arguments = tools.items[index].arguments.items });
    try observer.on_delta_end(observer.ctx);
}

fn toolIndexForEvent(value: std.json.Value, tools: []const ToolBuilder) ?u32 {
    if (tools.len == 0) return null;
    if (stringField(value, "item_id")) |item_id| {
        for (tools, 0..) |tool, index| {
            if (std.mem.eql(u8, tool.item_id.items, item_id)) return @intCast(index);
        }
    }
    if (stringField(value, "call_id")) |call_id| {
        for (tools, 0..) |tool, index| {
            if (std.mem.eql(u8, tool.call_id.items, call_id)) return @intCast(index);
        }
    }
    if (optionalU32(value, "output_index")) |output_index| {
        for (tools, 0..) |tool, index| {
            if (tool.output_index) |tool_output_index| {
                if (tool_output_index == output_index) return @intCast(index);
            }
        }
    }
    if (tools.len == 1) return 0;
    return null;
}

fn finishTextBlock(gpa: std.mem.Allocator, blocks: *std.ArrayList(ai.ContentBlock), observer: anytype, text: []const u8) !void {
    const index = lastTextBlock(blocks.items) orelse return;
    const old = blocks.items[index].text.text;
    if (std.mem.startsWith(u8, text, old)) {
        const suffix = text[old.len..];
        if (suffix.len > 0) {
            blocks.items[index].text.text = try appendOwned(gpa, old, suffix);
            try observer.on_content(observer.ctx, suffix);
            try observer.on_delta_end(observer.ctx);
            return;
        }
    } else {
        const replacement = try gpa.dupe(u8, text);
        gpa.free(old);
        blocks.items[index].text.text = replacement;
        if (text.len > 0) {
            try observer.on_content(observer.ctx, text);
            try observer.on_delta_end(observer.ctx);
        }
    }
}

fn onReasoningSummaryPartDone(gpa: std.mem.Allocator, blocks: *std.ArrayList(ai.ContentBlock), observer: anytype) !void {
    const index = lastReasoningBlock(blocks.items) orelse return;
    const old = blocks.items[index].reasoning.text;
    blocks.items[index].reasoning.text = try appendOwned(gpa, old, "\n\n");
    try observer.on_reasoning(observer.ctx, "\n\n");
    try observer.on_delta_end(observer.ctx);
}

fn lastTextBlock(blocks: []const ai.ContentBlock) ?u32 {
    var index = blocks.len;
    while (index > 0) {
        index -= 1;
        if (blocks[index] == .text) return @intCast(index);
    }
    return null;
}

fn lastReasoningBlock(blocks: []const ai.ContentBlock) ?u32 {
    var index = blocks.len;
    while (index > 0) {
        index -= 1;
        if (blocks[index] == .reasoning) return @intCast(index);
    }
    return null;
}

fn updateToolFromItem(gpa: std.mem.Allocator, item: std.json.Value, tools: []ToolBuilder) !?u32 {
    const call_id = stringField(item, "call_id") orelse return null;
    for (tools, 0..) |*tool, index| {
        if (!std.mem.eql(u8, tool.call_id.items, call_id)) continue;
        if (stringField(item, "name")) |name| {
            tool.name.clearRetainingCapacity();
            try tool.name.appendSlice(gpa, name);
        }
        if (stringField(item, "arguments")) |arguments| {
            tool.arguments.clearRetainingCapacity();
            try tool.arguments.appendSlice(gpa, arguments);
        }
        return @intCast(index);
    }
    return null;
}

fn syncToolBlocks(gpa: std.mem.Allocator, blocks: *std.ArrayList(ai.ContentBlock), tools: []ToolBuilder, call_seq: *u64) !void {
    for (tools) |*tool| {
        if (tool.name.items.len == 0) continue;
        if (tool.call_id.items.len == 0) {
            const minted = try std.fmt.allocPrint(gpa, "call_{d}", .{call_seq.*});
            defer gpa.free(minted);
            try tool.call_id.appendSlice(gpa, minted);
            call_seq.* += 1;
        }
        try syncOneToolBlock(gpa, blocks, tool);
    }
}

fn syncOneToolBlock(gpa: std.mem.Allocator, blocks: *std.ArrayList(ai.ContentBlock), tool: *const ToolBuilder) !void {
    if (tool.block_index >= blocks.items.len) return;
    if (blocks.items[tool.block_index] != .tool_call) return;
    const block = &blocks.items[tool.block_index].tool_call;
    try replaceSlice(gpa, &block.call_id.value, tool.call_id.items);
    const next_item_id = if (tool.item_id.items.len > 0) try gpa.dupe(u8, tool.item_id.items) else null;
    if (block.responses_item_id) |id| gpa.free(id);
    block.responses_item_id = next_item_id;
    try replaceSlice(gpa, &block.name, tool.name.items);
    try replaceSlice(gpa, &block.arguments, tool.arguments.items);
}

fn replaceSlice(gpa: std.mem.Allocator, target: *[]u8, source: []const u8) !void {
    const next = try gpa.dupe(u8, source);
    gpa.free(target.*);
    target.* = next;
}

fn appendOwned(gpa: std.mem.Allocator, old: []u8, suffix: []const u8) ![]u8 {
    const next = try gpa.alloc(u8, old.len + suffix.len);
    @memcpy(next[0..old.len], old);
    @memcpy(next[old.len..], suffix);
    gpa.free(old);
    return next;
}

fn optionalString(gpa: std.mem.Allocator, value: std.json.Value, name: []const u8) !?[]u8 {
    const field = value.object.get(name) orelse return null;
    if (field != .string) return null;
    return try gpa.dupe(u8, field.string);
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    const field = value.object.get(name) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn optionalU32(value: std.json.Value, name: []const u8) ?u32 {
    const field = value.object.get(name) orelse return null;
    if (field != .integer) return null;
    if (field.integer < 0) return null;
    if (field.integer > std.math.maxInt(u32)) return null;
    return @intCast(field.integer);
}

test "openresponses emits final item text when no delta arrived" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);

    const Seen = struct {
        text: std.ArrayList(u8) = .empty,

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.text.deinit(allocator);
        }

        fn onContent(ctx: *@This(), delta: []const u8) anyerror!void {
            try ctx.text.appendSlice(std.testing.allocator, delta);
        }
        fn noopBytes(_: *@This(), _: []const u8) anyerror!void {}
        fn noopToolDelta(_: *@This(), _: ai.ToolDelta) anyerror!void {}
        fn noopVoid(_: *@This()) anyerror!void {}
    };
    var seen: Seen = .{};
    defer seen.deinit(gpa);
    const observer: ai.StreamObserver(Seen) = .{
        .ctx = &seen,
        .on_content = Seen.onContent,
        .on_reasoning = Seen.noopBytes,
        .on_tool_delta = Seen.noopToolDelta,
        .on_delta_end = Seen.noopVoid,
    };

    var call_seq: u64 = 0;
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\"}}", observer, &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"hello\"}]}}", observer, &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.completed\"}", observer, &call_seq);

    var turn = try state.finish(gpa, &call_seq);
    defer turn.deinit(gpa);
    try std.testing.expectEqualStrings("hello", seen.text.items);
    try std.testing.expectEqualStrings("hello", turn.assistant.assistant.content[0].text.text);
}

test "openresponses preserves text tool text block order" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);

    var call_seq: u64 = 0;
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\"}}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.output_text.delta\",\"delta\":\"before\"}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_a\",\"id\":\"item_a\",\"name\":\"bash\"}}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.function_call_arguments.done\",\"output_index\":1,\"arguments\":\"{\\\"command\\\":\\\"pwd\\\"}\"}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.output_text.delta\",\"delta\":\"after\"}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.completed\"}", ai.streamNoop(), &call_seq);

    var turn = try state.finish(gpa, &call_seq);
    defer turn.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), turn.assistant.assistant.content.len);
    try std.testing.expectEqualStrings("before", turn.assistant.assistant.content[0].text.text);
    try std.testing.expectEqualStrings("bash", turn.assistant.assistant.content[1].tool_call.name);
    try std.testing.expectEqualStrings("after", turn.assistant.assistant.content[2].text.text);
}

test "openresponses parses usage from completed event" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);

    var call_seq: u64 = 0;
    try state.processJson(gpa, "{\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":2000,\"input_tokens_details\":{\"cached_tokens\":1500},\"output_tokens\":420,\"output_tokens_details\":{\"reasoning_tokens\":256},\"total_tokens\":2420}}}", ai.streamNoop(), &call_seq);

    var turn = try state.finish(gpa, &call_seq);
    defer turn.deinit(gpa);
    try std.testing.expect(turn.usage != null);
    try std.testing.expectEqual(@as(u32, 2000), turn.usage.?.input_tokens);
    try std.testing.expectEqual(@as(u32, 1500), turn.usage.?.cached_input_tokens);
    try std.testing.expectEqual(@as(u32, 420), turn.usage.?.output_tokens);
    try std.testing.expectEqual(@as(u32, 256), turn.usage.?.reasoning_tokens);
    try std.testing.expectEqual(@as(u32, 2420), turn.usage.?.total_tokens);
}

test "openresponses completed event without usage leaves null" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);

    var call_seq: u64 = 0;
    try state.processJson(gpa, "{\"type\":\"response.completed\"}", ai.streamNoop(), &call_seq);

    var turn = try state.finish(gpa, &call_seq);
    defer turn.deinit(gpa);
    try std.testing.expect(turn.usage == null);
}

test "openresponses routes parallel argument deltas by output index" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);

    var call_seq: u64 = 0;
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_a\",\"id\":\"item_a\",\"name\":\"bash\"}}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_b\",\"id\":\"item_b\",\"name\":\"bash\"}}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"{\\\"command\\\":\"}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\"{\\\"path\\\":\"}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"\\\"pwd\\\"}\"}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\"\\\"src/main.zig\\\"}\"}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.completed\"}", ai.streamNoop(), &call_seq);

    var turn = try state.finish(gpa, &call_seq);
    defer turn.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), turn.assistant.assistant.content.len);
    try std.testing.expectEqualStrings("{\"command\":\"pwd\"}", turn.assistant.assistant.content[0].tool_call.arguments);
    try std.testing.expectEqualStrings("{\"path\":\"src/main.zig\"}", turn.assistant.assistant.content[1].tool_call.arguments);
    try std.testing.expectEqualStrings("bash", turn.assistant.assistant.content[1].tool_call.name);
}

test "processEvent ignores malformed JSON payloads gracefully" {
    const gpa = std.testing.allocator;
    var blocks: std.ArrayList(ai.ContentBlock) = .empty;
    defer blocks.deinit(gpa);
    var tools: std.ArrayList(ToolBuilder) = .empty;
    defer tools.deinit(gpa);
    var completed = false;
    var usage: ?ai.Usage = null;
    var call_seq: u64 = 0;

    // Truncated / broken JSON should not error or crash
    try processEvent(gpa, "{\"type\": \"response.output_text.delta\", \"delta\":", &blocks, &tools, ai.streamNoop(), &call_seq, &completed, &usage);
    try std.testing.expectEqual(@as(usize, 0), blocks.items.len);
    try std.testing.expectEqual(false, completed);
}

test "processEvent ignores unknown event types without error" {
    const gpa = std.testing.allocator;
    var blocks: std.ArrayList(ai.ContentBlock) = .empty;
    defer blocks.deinit(gpa);
    var tools: std.ArrayList(ToolBuilder) = .empty;
    defer tools.deinit(gpa);
    var completed = false;
    var usage: ?ai.Usage = null;
    var call_seq: u64 = 0;

    try processEvent(gpa, "{\"type\": \"custom_vendor.telemetry_heartbeat\"}", &blocks, &tools, ai.streamNoop(), &call_seq, &completed, &usage);
    try std.testing.expectEqual(false, completed);
    try std.testing.expectEqual(@as(usize, 0), blocks.items.len);
}

test "processEvent treats Codex lifecycle events as recognized no-ops" {
    const gpa = std.testing.allocator;
    var blocks: std.ArrayList(ai.ContentBlock) = .empty;
    defer blocks.deinit(gpa);
    var tools: std.ArrayList(ToolBuilder) = .empty;
    defer tools.deinit(gpa);
    var completed = false;
    var usage: ?ai.Usage = null;
    var call_seq: u64 = 0;

    const events = [_][]const u8{
        "{\"type\":\"response.created\"}",
        "{\"type\":\"response.in_progress\"}",
        "{\"type\":\"response.reasoning_summary_part.added\"}",
        "{\"type\":\"response.reasoning_summary_text.done\"}",
        "{\"type\":\"response.output_text.done\"}",
        "{\"type\":\"response.content_part.done\"}",
        "{\"type\":\"codex.rate_limits\"}",
        "{\"type\":\"codex.response.metadata\"}",
        "{\"type\":\"responsesapi.websocket_timing\"}",
    };
    for (events) |event| {
        const type_start = std.mem.indexOf(u8, event, "\"type\":\"").? + "\"type\":\"".len;
        const type_end = std.mem.indexOfPos(u8, event, type_start, "\"").?;
        try std.testing.expectEqual(ResponseEvent.lifecycle, responseEventFromString(event[type_start..type_end]).?);
        try processEvent(gpa, event, &blocks, &tools, ai.streamNoop(), &call_seq, &completed, &usage);
    }
    try std.testing.expect(!completed);
    try std.testing.expectEqual(@as(usize, 0), blocks.items.len);
}

test "processEvent returns ProviderError on error event" {
    const gpa = std.testing.allocator;
    var blocks: std.ArrayList(ai.ContentBlock) = .empty;
    defer blocks.deinit(gpa);
    var tools: std.ArrayList(ToolBuilder) = .empty;
    defer tools.deinit(gpa);
    var completed = false;
    var usage: ?ai.Usage = null;
    var call_seq: u64 = 0;

    const result = processEvent(gpa, "{\"type\": \"error\", \"error\": {\"message\": \"Rate limit exceeded\"}}", &blocks, &tools, ai.streamNoop(), &call_seq, &completed, &usage);
    try std.testing.expectError(error.ProviderError, result);
}

test "processEvent reassembles split multi-byte UTF-8 deltas" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);

    var call_seq: u64 = 0;
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_utf8\"}}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.output_text.delta\",\"delta\":\"Hello 🚀 \"}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.output_text.delta\",\"delta\":\"World! ✨\"}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.completed\"}", ai.streamNoop(), &call_seq);

    var turn = try state.finish(gpa, &call_seq);
    defer turn.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), turn.assistant.assistant.content.len);
    try std.testing.expectEqualStrings("Hello 🚀 World! ✨", turn.assistant.assistant.content[0].text.text);
}

test "parseResponseUsage handles malformed and out-of-bound usage values safely" {
    const gpa = std.testing.allocator;

    // 1. Negative counts clamp to 0
    {
        const json = "{\"response\":{\"usage\":{\"input_tokens\":-50,\"output_tokens\":-10,\"total_tokens\":-60}}}";
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
        defer parsed.deinit();
        const usage = parseResponseUsage(parsed.value);
        try std.testing.expect(usage != null);
        try std.testing.expectEqual(@as(u32, 0), usage.?.input_tokens);
        try std.testing.expectEqual(@as(u32, 0), usage.?.output_tokens);
        try std.testing.expectEqual(@as(u32, 0), usage.?.total_tokens);
    }

    // 2. Non-integer types fallback to 0
    {
        const json = "{\"response\":{\"usage\":{\"input_tokens\":\"1000\",\"output_tokens\":true,\"input_tokens_details\":\"invalid_shape\"}}}";
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
        defer parsed.deinit();
        const usage = parseResponseUsage(parsed.value);
        try std.testing.expect(usage != null);
        try std.testing.expectEqual(@as(u32, 0), usage.?.input_tokens);
        try std.testing.expectEqual(@as(u32, 0), usage.?.output_tokens);
        try std.testing.expectEqual(@as(u32, 0), usage.?.cached_input_tokens);
    }
}

test "processEvent mints synthetic call_id when omitted from tool call" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);

    var call_seq: u64 = 42;
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.completed\"}", ai.streamNoop(), &call_seq);

    var turn = try state.finish(gpa, &call_seq);
    defer turn.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), turn.assistant.assistant.content.len);
    try std.testing.expectEqualStrings("call_42", turn.assistant.assistant.content[0].tool_call.call_id.slice());
    try std.testing.expectEqualStrings("bash", turn.assistant.assistant.content[0].tool_call.name);
    try std.testing.expectEqual(@as(u64, 43), call_seq);
}

test "finish returns ResponseIncomplete error when stream ends before completed event" {
    const gpa = std.testing.allocator;
    var state: StreamState = .{};
    defer state.deinit(gpa);
    defer state.deinitBlocks(gpa);

    var call_seq: u64 = 0;
    try state.processJson(gpa, "{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\"}}", ai.streamNoop(), &call_seq);
    try state.processJson(gpa, "{\"type\":\"response.output_text.delta\",\"delta\":\"halfway content...\"}", ai.streamNoop(), &call_seq);

    // Call finish without response.completed
    const finish_result = state.finish(gpa, &call_seq);
    try std.testing.expectError(error.ResponseIncomplete, finish_result);
}

test "processEvent handles response.failed as ProviderError" {
    const gpa = std.testing.allocator;
    var blocks: std.ArrayList(ai.ContentBlock) = .empty;
    defer blocks.deinit(gpa);
    var tools: std.ArrayList(ToolBuilder) = .empty;
    defer tools.deinit(gpa);
    var completed = false;
    var usage: ?ai.Usage = null;
    var call_seq: u64 = 0;

    const result = processEvent(gpa, "{\"type\":\"response.failed\",\"response\":{\"status_details\":{\"error\":{\"message\":\"Server overload\"}}}}", &blocks, &tools, ai.streamNoop(), &call_seq, &completed, &usage);
    try std.testing.expectError(error.ProviderError, result);
}
