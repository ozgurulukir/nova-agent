//! Wire request payload serializer for the Responses API.
//!
//! Extracted from responses_core.zig: serializes system instructions, message
//! history, tool declarations, prompt cache flags, and dialect-specific reasoning
//! configurations into JSON wire format.

const std = @import("std");

const ai = @import("../ai.zig");
const model_compat = @import("model_compat.zig");
const responses_core = @import("responses_core.zig");
const stream_parser = @import("stream_parser.zig");
const tool_schema = @import("tool_schema.zig");
const tools_mod = @import("../tools.zig");

const log = std.log.scoped(.ai);

pub fn writeRequestPayload(
    out: *std.Io.Writer,
    gpa: std.mem.Allocator,
    config: ai.Config,
    responses_config: responses_core.ResponsesConfig,
    messages: []const ai.MessageView,
    tools_json: []const u8,
) !void {
    try out.writeAll("{\"model\":");
    try std.json.Stringify.value(config.model, .{}, out);
    try out.writeAll(",\"input\":[");
    var written: u32 = 0;
    for (messages) |*view| {
        if (config.system_prompt.len > 0 and view.message().* == .system) continue;
        if (written > 0) try out.writeByte(',');
        try writeInputMessage(
            out,
            view.message().*,
            gpa,
            responses_config.log_name,
            responses_config.scrub_encrypted_reasoning,
        );
        written += 1;
    }
    try out.writeAll("],\"stream\":true,\"store\":false,\"tools\":");
    try out.writeAll(tools_json);
    try out.writeAll(",\"tool_choice\":\"auto\"");
    if (config.system_prompt.len > 0) {
        try out.writeAll(",\"instructions\":");
        try std.json.Stringify.value(config.system_prompt, .{}, out);
    }
    if (config.session_id.len > 0 and !config.disable_prompt_cache) {
        try out.writeAll(",\"prompt_cache_key\":");
        try std.json.Stringify.value(config.session_id, .{}, out);
    }
    if (responses_config.text_verbosity) |verbosity| {
        try out.writeAll(",\"text\":{\"verbosity\":");
        try std.json.Stringify.value(verbosity, .{}, out);
        try out.writeByte('}');
    }
    if (responses_config.parallel_tool_calls) |enabled| {
        try out.writeAll(",\"parallel_tool_calls\":");
        try std.json.Stringify.value(enabled, .{}, out);
    }
    if (config.reasoning) |value| {
        try out.writeAll(",\"reasoning\":{");
        var wrote = false;
        if (value.effort) |effort| {
            // Clip Ollama-incompatible effort values for the minimal dialect,
            // mirroring the chat-completions path (model_compat.wireEffortLabel).
            // The Responses-API site is not dialect-gated for cache fields (C1/C2
            // in AGENTS.md), but effort clipping is cheap and keeps the two wire
            // clients consistent so a provider switch never changes the effort
            // semantics unexpectedly.
            const wire_label = model_compat.clipEffortForModel(
                config.model,
                model_compat.wireEffortLabel(config.wire_dialect, effort),
            );
            if (wire_label) |label| {
                try out.writeAll("\"effort\":");
                try std.json.Stringify.value(label, .{}, out);
                wrote = true;
            }
        }
        if (value.summary) |summary| {
            if (wrote) try out.writeByte(',');
            try out.writeAll("\"summary\":");
            try std.json.Stringify.value(summary.label(), .{}, out);
        }
        // When effort is `.default` and summary is null, this object is empty
        // ("reasoning":{}). With include_encrypted_reasoning=false (Codex) the
        // include array is omitted — the reasoning object itself (effort and
        // summary) is still sent, only the encrypted blob is never requested.
        if (responses_config.include_encrypted_reasoning) {
            try out.writeAll("},\"include\":[\"reasoning.encrypted_content\"]");
        } else {
            try out.writeByte('}');
        }
    }
    try out.writeByte('}');
}

fn writeInputMessage(
    out: *std.Io.Writer,
    message: ai.ChatMessage,
    gpa: std.mem.Allocator,
    log_name: []const u8,
    scrub_encrypted_reasoning: bool,
) !void {
    switch (message) {
        .assistant => return writeAssistantItems(out, message, gpa, log_name, scrub_encrypted_reasoning),
        .tool => return writeToolOutput(out, message),
        .system => {
            try out.writeAll("{\"type\":\"message\",\"role\":\"system\",\"content\":");
            try writeInputContent(out, message.system.content);
            try out.writeByte('}');
        },
        .user => {
            try out.writeAll("{\"type\":\"message\",\"role\":\"user\",\"content\":");
            try writeInputContent(out, message.user.content);
            try out.writeByte('}');
        },
    }
}

/// Copy `json` with any top-level `"encrypted_content"` field removed.
/// Returns null when the input carries no such field (caller falls back to
/// writing the original bytes) or on any parse/serialize failure (never
/// reject replayed history over a scrub failure — upstream guidance is
/// skip-not-fail, openai/codex#25290).
fn scrubEncryptedContent(
    gpa: std.mem.Allocator,
    json: []const u8,
) ?[]u8 {
    return scrubEncryptedContentOrError(gpa, json) catch null;
}

fn scrubEncryptedContentOrError(
    gpa: std.mem.Allocator,
    json: []const u8,
) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;
    if (!obj.contains("encrypted_content")) return null;
    // Re-serialize by iteration instead of removing through a map copy:
    // mutating a copied ArrayHashMap corrupts state shared with the original.
    var buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer buf.deinit();
    const w = &buf.writer;
    try w.writeByte('{');
    var it = obj.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "encrypted_content")) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try std.json.Stringify.value(entry.key_ptr.*, .{}, w);
        try w.writeByte(':');
        try std.json.Stringify.value(entry.value_ptr.*, .{}, w);
    }
    try w.writeByte('}');
    return try buf.toOwnedSlice();
}

fn writeAssistantItems(
    out: *std.Io.Writer,
    message: ai.ChatMessage,
    gpa: std.mem.Allocator,
    log_name: []const u8,
    scrub_encrypted_reasoning: bool,
) !void {
    var first = true;
    for (message.assistant.content) |block| {
        if (!first) try out.writeByte(',');
        first = false;
        switch (block) {
            .text => |text| {
                try out.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\"");
                if (text.responses_item_id) |id| {
                    try out.writeAll(",\"id\":");
                    try std.json.Stringify.value(id, .{}, out);
                }
                try out.writeAll(",\"content\":[{\"type\":\"output_text\",\"text\":");
                try std.json.Stringify.value(text.text, .{}, out);
                try out.writeAll(",\"annotations\":[]}]}");
            },
            .reasoning => |reasoning| {
                if (reasoning.responses_item_json) |json| {
                    if (scrub_encrypted_reasoning) {
                        if (scrubEncryptedContent(gpa, json)) |clean| {
                            defer gpa.free(clean);
                            log.info("responses.replay.scrubbed_encrypted_content client={s}", .{log_name});
                            try out.writeAll(clean);
                        } else {
                            try out.writeAll(json);
                        }
                    } else {
                        try out.writeAll(json);
                    }
                } else {
                    try out.writeAll("{\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":");
                    try std.json.Stringify.value(reasoning.text, .{}, out);
                    try out.writeAll("}]}");
                }
            },
            .tool_call => |call| try writeFunctionCall(out, call),
            .image => try out.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}"),
        }
    }
    if (first) try out.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"content\":\"\"}");
}

fn writeFunctionCall(out: *std.Io.Writer, call: ai.ToolCall) !void {
    try out.writeAll("{\"type\":\"function_call\",\"call_id\":");
    try std.json.Stringify.value(call.call_id.slice(), .{}, out);
    if (call.responses_item_id) |id| {
        try out.writeAll(",\"id\":");
        try std.json.Stringify.value(id, .{}, out);
    }
    try out.writeAll(",\"name\":");
    try std.json.Stringify.value(call.name, .{}, out);
    try out.writeAll(",\"arguments\":");
    const args = stream_parser.sanitizeToolArguments(call.arguments);
    try std.json.Stringify.value(args, .{}, out);
    try out.writeByte('}');
}

fn writeToolOutput(out: *std.Io.Writer, message: ai.ChatMessage) !void {
    try out.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
    try std.json.Stringify.value(message.tool.call_id.slice(), .{}, out);
    try out.writeAll(",\"output\":");
    try std.json.Stringify.value(message.text(), .{}, out);
    try out.writeByte('}');
}

fn writeInputContent(out: *std.Io.Writer, blocks: []const ai.ContentBlock) !void {
    try out.writeByte('[');
    var count: u32 = 0;
    for (blocks) |block| {
        switch (block) {
            .text => |text| {
                if (count > 0) try out.writeByte(',');
                try out.writeAll("{\"type\":\"input_text\",\"text\":");
                try std.json.Stringify.value(text.text, .{}, out);
                try out.writeByte('}');
                count += 1;
            },
            .image => |image| {
                if (count > 0) try out.writeByte(',');
                try out.writeAll("{\"type\":\"input_image\",\"detail\":\"auto\",\"image_url\":");
                try out.writeByte('"');
                try out.writeAll("data:");
                try out.writeAll(image.mime_type);
                try out.writeAll(";base64,");
                try out.writeAll(image.data_base64);
                try out.writeByte('"');
                try out.writeByte('}');
                count += 1;
            },
            .reasoning, .tool_call => {},
        }
    }
    try out.writeByte(']');
}

test "writeRequestPayload puts system prompt in instructions for standard mode" {
    const gpa = std.testing.allocator;
    const empty_content = try gpa.alloc(ai.ContentBlock, 0);
    defer gpa.free(empty_content);
    const system_message: ai.ChatMessage = .{ .system = .{ .content = empty_content } };
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-test",
        .session_id = "session-abc",
        .system_prompt = "You are Nova.",
        .reasoning = null,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(&payload.writer, gpa, config, .{}, &.{.{ .borrowed = &system_message }}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"instructions\":\"You are Nova.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"prompt_cache_key\":\"session-abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"input\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "verbosity") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "parallel_tool_calls") == null);
}

test "writeRequestPayload keeps configured verbosity hint" {
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-5.5",
        .session_id = "session-xyz",
        .system_prompt = "You are Nova.",
        .reasoning = null,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(&payload.writer, gpa, config, .{ .text_verbosity = "low", .parallel_tool_calls = true }, &.{}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"instructions\":\"You are Nova.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"prompt_cache_key\":\"session-xyz\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"verbosity\":\"low\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"parallel_tool_calls\":true") != null);
}

test "writeRequestPayload emits reasoning effort none" {
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-test",
        .session_id = "",
        .system_prompt = "",
        .reasoning = .{ .effort = .none, .summary = null },
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(&payload.writer, gpa, config, .{}, &.{}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"none\"}") != null);
}

test "writeRequestPayload omits reasoning effort when set to default" {
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-test",
        .session_id = "",
        .system_prompt = "",
        .reasoning = .{ .effort = .default, .summary = null },
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(&payload.writer, gpa, config, .{}, &.{}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"effort\"") == null);
}

test "writeRequestPayload emits reasoning summary even with default effort (Responses API)" {
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-test",
        .session_id = "",
        .system_prompt = "",
        .reasoning = .{ .effort = .default, .summary = .detailed },
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(&payload.writer, gpa, config, .{}, &.{}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"summary\":\"detailed\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "effort") == null);
}

test "writeRequestPayload omits prompt_cache_key when no session id is set" {
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-test",
        .session_id = "",
        .system_prompt = "You are Nova.",
        .reasoning = null,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(&payload.writer, gpa, config, .{}, &.{}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "prompt_cache_key") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"instructions\":\"You are Nova.\"") != null);
}

test "writeRequestPayload omits prompt_cache_key when disable_prompt_cache is true" {
    // C1: this site is NOT dialect-gated (it emits whenever session_id is
    // non-empty), so the flag is the sole gate. When set, prompt_cache_key
    // must be suppressed even with a non-empty session id.
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-test",
        .session_id = "session-abc",
        .system_prompt = "You are Nova.",
        .reasoning = null,
        .disable_prompt_cache = true,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(&payload.writer, gpa, config, .{}, &.{}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "prompt_cache_key") == null);
}

test "writeRequestPayload serializes tool call ids as strings, not objects" {
    const gpa = std.testing.allocator;

    const assistant_blocks = try gpa.alloc(ai.ContentBlock, 1);
    assistant_blocks[0] = .{ .tool_call = .{
        .call_id = .{ .value = try gpa.dupe(u8, "call_xyz789") },
        .name = try gpa.dupe(u8, "read"),
        .arguments = try gpa.dupe(u8, "{\"path\":\"main.zig\"}"),
    } };
    const assistant_msg: ai.ChatMessage = .{ .assistant = .{ .content = assistant_blocks } };

    const tool_blocks = try gpa.alloc(ai.ContentBlock, 1);
    tool_blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "content") } };
    const tool_msg: ai.ChatMessage = .{ .tool = .{
        .call_id = .{ .value = try gpa.dupe(u8, "call_xyz789") },
        .content = tool_blocks,
    } };

    var messages = [_]ai.ChatMessage{ assistant_msg, tool_msg };
    defer for (&messages) |*m| m.deinit(gpa);
    const views = [_]ai.MessageView{
        .{ .borrowed = &messages[0] },
        .{ .borrowed = &messages[1] },
    };

    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-test",
        .session_id = "",
        .system_prompt = "",
        .reasoning = null,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(&payload.writer, gpa, config, .{}, &views, "[{\"type\":\"function\"}]");
    const body = payload.written();

    // function_call call_id must be a string
    try std.testing.expect(std.mem.indexOf(u8, body, "\"call_id\":\"call_xyz789\"") != null);
    // function_call_output call_id must be a string
    try std.testing.expect(std.mem.indexOf(u8, body, "\"call_id\":\"call_xyz789\"") != null);
    // Negative: must NOT serialize CallId as an object
    try std.testing.expect(std.mem.indexOf(u8, body, "\"call_id\":{\"value\":") == null);
}

test "writeRequestPayload clips xhigh reasoning effort for minimal dialect (Responses API)" {
    // Mirrors the chat-completions clipping: Ollama's /v1/chat/completions
    // rejects xhigh/minimal with HTTP 400. The /v1/responses endpoint
    // silently ignores unknown reasoning fields (Go decoder), but clipping
    // keeps the two wire clients consistent and is forward-safe if Ollama
    // adds validation later.
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "ollama-model",
        .reasoning = .{ .effort = .xhigh },
        .wire_dialect = .minimal,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(&payload.writer, gpa, config, .{}, &.{}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"effort\":\"max\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "xhigh") == null);
}

test "writeRequestPayload preserves xhigh reasoning effort for openai dialect (Responses API)" {
    // The openai dialect must NOT clip — gpt-5 honours xhigh/max.
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-5",
        .reasoning = .{ .effort = .xhigh },
        .wire_dialect = .openai,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(&payload.writer, gpa, config, .{}, &.{}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"effort\":\"xhigh\"") != null);
}

test "openresponses tools json is an array" {
    const tools = @import("../tools.zig");
    const gpa = std.testing.allocator;
    const json = try tool_schema.buildAllToolsJson(gpa, tools.builtinRegistry(), &.{}, null, true, .responses);
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"function\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"strict\":true") != null);
}

test "openresponses strict schema includes nullable union types and top-level additionalProperties:false" {
    const gpa = std.testing.allocator;
    const tools = [_]tools_mod.Tool{
        .{
            .name = "demo",
            .description = "Demo tool",
            .schema = .{
                .properties = &.{
                    .{ .name = "id", .kind = .string, .description = "ID", .required = true, .nullable = false },
                    .{ .name = "tag", .kind = .string, .description = "Tag", .required = false, .nullable = true },
                },
            },
            .run = undefined,
            .display = undefined,
        },
    };
    const json = try tool_schema.buildAllToolsJson(gpa, &tools, &.{}, null, true, .responses);
    defer gpa.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"strict\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"additionalProperties\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":{\"type\":\"string\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tag\":{\"type\":[\"string\",\"null\"]") != null);
    // Required array includes ALL properties for strict mode compliance.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"required\":[\"id\",\"tag\"]") != null);
}

test "openresponses omits strict mode and filters required when strict is false (gateway compatibility)" {
    // Regression for function-calling breaking on gateways: strict
    // structured-outputs is OpenAI-only, so it must be omitted when the
    // client is built with strict=false. `required` then lists only the
    // genuinely-required properties.
    const gpa = std.testing.allocator;
    const tools = [_]tools_mod.Tool{
        .{
            .name = "demo",
            .description = "Demo tool",
            .schema = .{
                .properties = &.{
                    .{ .name = "id", .kind = .string, .description = "ID", .required = true, .nullable = false },
                    .{ .name = "tag", .kind = .string, .description = "Tag", .required = false, .nullable = true },
                },
            },
            .run = undefined,
            .display = undefined,
        },
    };
    const json = try tool_schema.buildAllToolsJson(gpa, &tools, &.{}, null, false, .responses);
    defer gpa.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"strict\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"required\":[\"id\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tag\":{\"type\":[\"string\",\"null\"]") != null);
}

test "writeRequestPayload handles empty messages and empty tools array" {
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "test-model",
        .session_id = "",
        .system_prompt = "",
        .reasoning = null,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();

    try writeRequestPayload(&payload.writer, gpa, config, .{}, &.{}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"input\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":[]") != null);
}

test "writeRequestPayload skips system messages in history when config system_prompt is set" {
    const gpa = std.testing.allocator;
    const sys_blocks = try gpa.alloc(ai.ContentBlock, 0);
    defer gpa.free(sys_blocks);
    const sys_msg: ai.ChatMessage = .{ .system = .{ .content = sys_blocks } };

    const views = [_]ai.MessageView{
        .{ .borrowed = &sys_msg },
    };
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-test",
        .session_id = "",
        .system_prompt = "Global system instruction",
        .reasoning = null,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();

    try writeRequestPayload(&payload.writer, gpa, config, .{}, &views, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"instructions\":\"Global system instruction\"") != null);
    // History system message is skipped from input array
    try std.testing.expect(std.mem.indexOf(u8, body, "\"input\":[]") != null);
}

test "writeRequestPayload sanitizes empty tool call arguments to empty object" {
    const gpa = std.testing.allocator;
    const assistant_blocks = try gpa.alloc(ai.ContentBlock, 1);
    assistant_blocks[0] = .{ .tool_call = .{
        .call_id = .{ .value = try gpa.dupe(u8, "call_empty_args") },
        .name = try gpa.dupe(u8, "test_tool"),
        .arguments = try gpa.dupe(u8, ""),
    } };
    const assistant_msg: ai.ChatMessage = .{ .assistant = .{ .content = assistant_blocks } };
    var messages = [_]ai.ChatMessage{assistant_msg};
    defer for (&messages) |*m| m.deinit(gpa);

    const views = [_]ai.MessageView{
        .{ .borrowed = &messages[0] },
    };
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-test",
        .session_id = "",
        .system_prompt = "",
        .reasoning = null,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();

    try writeRequestPayload(&payload.writer, gpa, config, .{}, &views, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"arguments\":\"{}\"") != null);
}

test "writeRequestPayload clips minimal reasoning effort for minimal dialect" {
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "ollama-model",
        .reasoning = .{ .effort = .minimal },
        .wire_dialect = .minimal,
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();

    try writeRequestPayload(&payload.writer, gpa, config, .{}, &.{}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"effort\":\"low\"") != null);
}

test "writeRequestPayload omits encrypted reasoning include when disabled" {
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-5.6-sol",
        .reasoning = .{ .effort = .medium },
    };
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();

    try writeRequestPayload(&payload.writer, gpa, config, .{ .include_encrypted_reasoning = false }, &.{}, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "encrypted_content") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"include\"") == null);
    // The reasoning object itself must still be emitted for effort.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{") != null);
}

test "writeRequestPayload scrubs encrypted_content from replayed reasoning items" {
    const gpa = std.testing.allocator;
    const config: ai.Config = .{
        .base_url = "",
        .api_key = "",
        .model = "gpt-5.6-sol",
        .reasoning = null,
    };

    const reasoning_blocks = try gpa.alloc(ai.ContentBlock, 1);
    reasoning_blocks[0] = .{ .reasoning = .{
        .text = try gpa.dupe(u8, "**Planning**"),
        .responses_item_json = try gpa.dupe(u8, "{\"id\":\"rs_x\",\"type\":\"reasoning\",\"content\":[],\"encrypted_content\":\"gAAAAABsecret\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"**Planning**\"}]}"),
    } };

    var message = ai.ChatMessage{ .assistant = .{ .content = reasoning_blocks } };
    // Owns the blocks array and every duped field — single teardown path.
    defer message.deinit(gpa);
    const views = [_]ai.MessageView{.{ .borrowed = &message }};

    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();

    try writeRequestPayload(&payload.writer, gpa, config, .{
        .include_encrypted_reasoning = false,
        .scrub_encrypted_reasoning = true,
    }, &views, "[]");
    const body = payload.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "gAAAAABsecret") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"id\":\"rs_x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "**Planning**") != null);

    payload.clearRetainingCapacity();
    try writeRequestPayload(&payload.writer, gpa, config, .{ .include_encrypted_reasoning = true }, &views, "[]");
    try std.testing.expect(std.mem.indexOf(u8, payload.written(), "gAAAAABsecret") != null);
}

test "scrubEncryptedContent passes through malformed json as null" {
    const gpa = std.testing.allocator;
    const clean = scrubEncryptedContent(gpa, "{not json at all");
    try std.testing.expect(clean == null);
}
