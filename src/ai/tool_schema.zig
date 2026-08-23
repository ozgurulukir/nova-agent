//! Shared tool-definition serialization for the AI adapters.
//!
//! The two OpenAI-style wire formats serialize a `tools_common.Tool` /
//! `ai.McpToolSchema` into a `tools` JSON array in almost identical ways. The
//! only structural difference is the outer envelope: Chat Completions wraps
//! each definition in a `"function"` object while the Responses API keeps it
//! flat. Everything else — property kinds, nullable unions, enum constraints,
//! raw-JSON defaults, object/array markers, the strict-gated `required` list,
//! and the `{{hsep}}` → `~` description substitution — is byte-identical
//! across both. This module is the single implementation, parameterized by
//! `Envelope`, so a tool-schema change lands in one place instead of two.

const std = @import("std");
const ai = @import("../ai.zig");
const tools_common = @import("../tools/common.zig");
const tools_mod = @import("../tools.zig");

/// The only structural difference between the two provider APIs: how a tool
/// definition is wrapped. Chat Completions (`chat/completions`) nests the
/// definition inside a `"function"` object; the Responses API emits it flat.
pub const Envelope = enum { completions, responses };

/// Build the OpenAI `tools` JSON array from builtin tools, registry plugin
/// tools, and MCP tool schemas, for the given wire-format envelope.
/// Substitutes `{{hsep}}` → `~` in each tool's description template.
/// The caller owns the returned slice.
pub fn buildAllToolsJson(
    gpa: std.mem.Allocator,
    tools: []const tools_common.Tool,
    mcp_tools: []const ai.McpToolSchema,
    registry: ?*tools_mod.ToolRegistry,
    strict: bool,
    envelope: Envelope,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const writer = &aw.writer;
    try writer.writeByte('[');
    var first = true;
    for (tools) |tool| {
        if (!first) try writer.writeByte(',');
        first = false;
        try writeToolDefinition(gpa, writer, tool.name, tool.description, tool.schema, strict, envelope);
    }
    if (registry) |r| {
        const plugin_slice = try r.all(gpa);
        for (plugin_slice) |tool| {
            if (!first) try writer.writeByte(',');
            first = false;
            try writeToolDefinition(gpa, writer, tool.name, tool.description, tool.schema, strict, envelope);
        }
    }
    for (mcp_tools) |mcp| {
        if (!first) try writer.writeByte(',');
        first = false;
        try writeToolDefinition(gpa, writer, mcp.name, mcp.description, mcp.schema, strict, envelope);
    }
    try writer.writeByte(']');
    return aw.toOwnedSlice();
}

fn writeToolDefinition(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    name: []const u8,
    description: []const u8,
    schema: tools_common.Schema,
    strict: bool,
    envelope: Envelope,
) !void {
    const desc = try std.mem.replaceOwned(u8, gpa, description, "{{hsep}}", "~");
    defer gpa.free(desc);
    switch (envelope) {
        .completions => try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":"),
        .responses => try writer.writeAll("{\"type\":\"function\",\"name\":"),
    }
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(desc, .{}, writer);
    // Strict structured-outputs mode is OpenAI-only. Gateways that don't
    // support it silently break function-calling, so it's opt-in via
    // `ai.Config.strict`. The leading comma is always written so the next
    // `parameters` key is a valid object member regardless of strict.
    if (strict) {
        try writer.writeAll(",\"strict\":true,\"parameters\":");
    } else {
        try writer.writeAll(",\"parameters\":");
    }
    try writeParameters(writer, schema, strict);
    switch (envelope) {
        // Close the inner `function` object (the outer tool object is closed
        // by the common `}` below; the Responses envelope has no inner object).
        .completions => try writer.writeByte('}'),
        .responses => {},
    }
    try writer.writeByte('}');
}

fn writeParameters(writer: *std.Io.Writer, schema: tools_common.Schema, strict: bool) !void {
    try writer.writeAll("{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{");
    for (schema.properties, 0..) |prop, p| {
        if (p > 0) try writer.writeByte(',');
        try std.json.Stringify.value(prop.name, .{}, writer);
        try writer.writeAll(":{\"type\":");
        const kind_str: []const u8 = switch (prop.kind) {
            .string => "string",
            .integer => "integer",
            .number => "number",
            .object => "object",
            .array => "array",
            .boolean => "boolean",
        };
        if (prop.nullable or !prop.required) {
            try std.json.Stringify.value(&[_][]const u8{ kind_str, "null" }, .{}, writer);
        } else {
            try std.json.Stringify.value(kind_str, .{}, writer);
        }
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(prop.description, .{}, writer);
        // Emit enum constraint when present.
        if (prop.enum_values) |ev| {
            if (ev.len > 0) {
                try writer.writeAll(",\"enum\":[");
                for (ev, 0..) |v, ei| {
                    if (ei > 0) try writer.writeByte(',');
                    try std.json.Stringify.value(v, .{}, writer);
                }
                try writer.writeByte(']');
            }
        }
        // Emit default value when present (already a raw JSON fragment).
        if (prop.default_value) |dv| {
            try writer.writeAll(",\"default\":");
            try writer.writeAll(dv);
        }
        if (prop.kind == .object) {
            try writer.writeAll(",\"additionalProperties\":true");
        } else if (prop.kind == .array) {
            try writer.writeAll(",\"items\":{}");
        }
        try writer.writeByte('}');
    }
    // In strict mode OpenAI requires EVERY property in `required` (optional
    // ones are made nullable above). Outside strict mode list only the
    // genuinely-required properties so optional parameters stay optional —
    // listing all of them forces the model to fill every field.
    try writer.writeAll("},\"required\":[");
    var required_first = true;
    for (schema.properties) |prop| {
        // Strict mode: all properties required. Non-strict: only required ones.
        if (!strict and !prop.required) continue;
        if (!required_first) try writer.writeByte(',');
        required_first = false;
        try std.json.Stringify.value(prop.name, .{}, writer);
    }
    try writer.writeAll("]}");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_tools = [_]tools_common.Tool{
    .{
        .name = "configure",
        .description = "Configure a {{hsep}} server",
        .schema = .{
            .properties = &.{
                .{ .name = "mode", .kind = .string, .description = "Run mode", .required = true, .nullable = false, .enum_values = &.{ "fast", "slow" }, .default_value = "\"fast\"" },
                .{ .name = "env", .kind = .object, .description = "Extra env", .required = false, .nullable = true },
                .{ .name = "items", .kind = .array, .description = "Item list", .required = false, .nullable = true },
                .{ .name = "count", .kind = .integer, .description = "Count", .required = false, .nullable = true },
            },
        },
        .run = undefined,
        .display = undefined,
    },
};

const test_mcp_tools = [_]ai.McpToolSchema{
    .{
        .name = "mcp__srv__ping",
        .description = "Ping",
        .schema = .{ .properties = &.{} },
    },
};

test "buildAllToolsJson emits every plugin+builtin+MCP tool at production scale" {
    // Tersine mühendislik yerine servis katmanını doğrudan çalıştırıp, gerçek
    // kurulum ölçeğinde (28 plugin tool + 2 builtin + N MCP tool) hiçbir
    // tool'un enjeksiyon sırasında truncate edilmediğini / düşmediğini kanıtlar.
    const gpa = std.testing.allocator;

    var registry = try tools_mod.ToolRegistry.init(gpa, tools_mod.builtinRegistry());
    defer registry.deinit(gpa);

    const plugin_names = [_][]const u8{
        "lua__file-tools__read",            "lua__file-tools__write",
        "lua__file-tools__edit",            "lua__search-tools__grep",
        "lua__search-tools__glob",          "lua__path-tools__create_directory",
        "lua__path-tools__copy_path",       "lua__path-tools__move_path",
        "lua__path-tools__delete_path",     "lua__git-tools__git_status",
        "lua__git-tools__git_diff",         "lua__git-tools__git_log",
        "lua__git-tools__git_branch",       "lua__git-tools__git_commit",
        "lua__todo__todo_list",             "lua__todo__todo_add",
        "lua__todo__todo_done",             "lua__todo__todo_delete",
        "lua__todo__todo_prioritize",       "lua__todo__todo_write",
        "lua__todo__todo_get_plan",         "lua__todo__todo_set_plan",
        "lua__todo__todo_check_step",       "lua__file-watcher__file_stats",
        "lua__file-watcher__track_file_op", "lua__hello-world__greet",
        "lua__hello-world__current_time",
    };
    for (plugin_names) |name| {
        const owned_name = try gpa.dupe(u8, name);
        const owned_desc = try std.fmt.allocPrint(gpa, "Plugin tool {{hsep}} for {{hsep}} testing", .{});
        try registry.addPluginTool(gpa, .{
            .name = owned_name,
            .description = owned_desc,
            .schema = .{
                .properties = &.{
                    .{ .name = "path", .kind = .string, .description = "A path", .required = true, .nullable = false },
                    .{ .name = "recursive", .kind = .boolean, .description = "Recurse", .required = false, .nullable = true },
                },
            },
            .run = undefined,
            .display = undefined,
        });
    }
    const mcp_tools = [_]ai.McpToolSchema{
        .{ .name = "mcp__tavily__search", .description = "Web search", .schema = .{ .properties = &.{} } },
        .{ .name = "mcp__tavily__extract", .description = "URL extract", .schema = .{ .properties = &.{} } },
        .{ .name = "mcp__chrome-devtools__click", .description = "Click element", .schema = .{ .properties = &.{} } },
    };

    const json = try buildAllToolsJson(gpa, &.{}, &mcp_tools, &registry, false, .completions);
    defer gpa.free(json);

    // Her tool adı çıktıda tam olarak bir kez geçmeli — hiçbiri kesilmemiş.
    for (plugin_names) |name| {
        try std.testing.expectEqual(@as(usize, 1), countSubstr(json, name));
    }
    for ([_][]const u8{ tools_mod.shellToolName, "lane", "background", "skill" }) |builtin| {
        const needle = try std.fmt.allocPrint(gpa, "\"name\":\"{s}\"", .{builtin});
        defer gpa.free(needle);
        try std.testing.expectEqual(@as(usize, 1), countSubstr(json, needle));
    }
    for ([_][]const u8{ "mcp__tavily__search", "mcp__tavily__extract", "mcp__chrome-devtools__click" }) |mcp| {
        try std.testing.expectEqual(@as(usize, 1), countSubstr(json, mcp));
    }
    try std.testing.expectEqual(@as(usize, plugin_names.len + 4 + mcp_tools.len), countSubstr(json, "\"type\":\"function\""));
}

fn countSubstr(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, idx, needle)) |pos| {
        count += 1;
        idx = pos + 1;
    }
    return count;
}

test "tool_schema golden: byte-identical output for all envelope × strict combos" {
    // Locks the serialized bytes for the canonical tool set so any future
    // drift (wrong closing brace count, dropped nullable union, missing enum)
    // is caught exactly here. Expected strings cover: completions/responses
    // envelopes × strict on/off, nullable unions, enum + raw-default, nested
    // object/array markers, and the {{hsep}} → ~ substitution.
    const gpa = std.testing.allocator;

    const completions_strict =
        "[{\"type\":\"function\",\"function\":{\"name\":\"configure\",\"description\":\"Configure a ~ server\",\"strict\":true,\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"mode\":{\"type\":\"string\",\"description\":\"Run mode\",\"enum\":[\"fast\",\"slow\"],\"default\":\"fast\"},\"env\":{\"type\":[\"object\",\"null\"],\"description\":\"Extra env\",\"additionalProperties\":true},\"items\":{\"type\":[\"array\",\"null\"],\"description\":\"Item list\",\"items\":{}},\"count\":{\"type\":[\"integer\",\"null\"],\"description\":\"Count\"}},\"required\":[\"mode\",\"env\",\"items\",\"count\"]}}},{\"type\":\"function\",\"function\":{\"name\":\"mcp__srv__ping\",\"description\":\"Ping\",\"strict\":true,\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{},\"required\":[]}}}]";
    const completions_non_strict =
        "[{\"type\":\"function\",\"function\":{\"name\":\"configure\",\"description\":\"Configure a ~ server\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"mode\":{\"type\":\"string\",\"description\":\"Run mode\",\"enum\":[\"fast\",\"slow\"],\"default\":\"fast\"},\"env\":{\"type\":[\"object\",\"null\"],\"description\":\"Extra env\",\"additionalProperties\":true},\"items\":{\"type\":[\"array\",\"null\"],\"description\":\"Item list\",\"items\":{}},\"count\":{\"type\":[\"integer\",\"null\"],\"description\":\"Count\"}},\"required\":[\"mode\"]}}},{\"type\":\"function\",\"function\":{\"name\":\"mcp__srv__ping\",\"description\":\"Ping\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{},\"required\":[]}}}]";
    const responses_strict =
        "[{\"type\":\"function\",\"name\":\"configure\",\"description\":\"Configure a ~ server\",\"strict\":true,\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"mode\":{\"type\":\"string\",\"description\":\"Run mode\",\"enum\":[\"fast\",\"slow\"],\"default\":\"fast\"},\"env\":{\"type\":[\"object\",\"null\"],\"description\":\"Extra env\",\"additionalProperties\":true},\"items\":{\"type\":[\"array\",\"null\"],\"description\":\"Item list\",\"items\":{}},\"count\":{\"type\":[\"integer\",\"null\"],\"description\":\"Count\"}},\"required\":[\"mode\",\"env\",\"items\",\"count\"]}},{\"type\":\"function\",\"name\":\"mcp__srv__ping\",\"description\":\"Ping\",\"strict\":true,\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{},\"required\":[]}}]";
    const responses_non_strict =
        "[{\"type\":\"function\",\"name\":\"configure\",\"description\":\"Configure a ~ server\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"mode\":{\"type\":\"string\",\"description\":\"Run mode\",\"enum\":[\"fast\",\"slow\"],\"default\":\"fast\"},\"env\":{\"type\":[\"object\",\"null\"],\"description\":\"Extra env\",\"additionalProperties\":true},\"items\":{\"type\":[\"array\",\"null\"],\"description\":\"Item list\",\"items\":{}},\"count\":{\"type\":[\"integer\",\"null\"],\"description\":\"Count\"}},\"required\":[\"mode\"]}},{\"type\":\"function\",\"name\":\"mcp__srv__ping\",\"description\":\"Ping\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{},\"required\":[]}}]";

    {
        const json = try buildAllToolsJson(gpa, &test_tools, &test_mcp_tools, null, true, .completions);
        defer gpa.free(json);
        try std.testing.expectEqualStrings(completions_strict, json);
    }
    {
        const json = try buildAllToolsJson(gpa, &test_tools, &test_mcp_tools, null, false, .completions);
        defer gpa.free(json);
        try std.testing.expectEqualStrings(completions_non_strict, json);
    }
    {
        const json = try buildAllToolsJson(gpa, &test_tools, &test_mcp_tools, null, true, .responses);
        defer gpa.free(json);
        try std.testing.expectEqualStrings(responses_strict, json);
    }
    {
        const json = try buildAllToolsJson(gpa, &test_tools, &test_mcp_tools, null, false, .responses);
        defer gpa.free(json);
        try std.testing.expectEqualStrings(responses_non_strict, json);
    }
}
