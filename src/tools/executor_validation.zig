//! Tool argument validation and numeric string coercion for the executor.
//!
//! Extracted from executor.zig: resolves tool schemas across builtin, plugin,
//! and MCP channels, coerces quoted numeric strings from weak models, and validates
//! arguments against JSON schemas before execution.

const std = @import("std");

const ai = @import("../ai.zig");
const mcp_mod = @import("../mcp/manager.zig");
const schema_mod = @import("schema.zig");
const tools = @import("../tools.zig");

/// Resolve the `tools.Schema` for a call across all three channels (MCP, Plugin, Builtin).
/// Returns null when the tool is unknown — validation is then skipped.
pub fn resolveSchema(
    tool_registry: ?*tools.ToolRegistry,
    mcp_manager: ?*mcp_mod.McpManager,
    gpa: std.mem.Allocator,
    call: ai.ToolCall,
) ?tools.Schema {
    // MCP: `mcp__<server>__<tool>` → the connected client's tool schema.
    if (std.mem.startsWith(u8, call.name, "mcp__")) {
        const manager = mcp_manager orelse return null;
        const rest = call.name["mcp__".len..];
        const sep = std.mem.indexOfScalar(u8, rest, '_') orelse return null;
        const after_server = rest[sep + 1 ..];
        if (after_server.len == 0 or after_server[0] != '_') return null;
        const server_name = rest[0..sep];
        for (manager.clients.items) |*client| {
            if (client.status() != .connected) continue;
            if (!std.mem.eql(u8, client.name, server_name)) continue;
            for (client.tools.items) |*tool| {
                if (std.mem.eql(u8, tool.full_name, call.name)) return tool.schema;
            }
        }
        return null;
    }
    // Builtin + plugin: one registry lookup.
    if (tool_registry) |registry| {
        const slice = registry.all(gpa) catch return null;
        for (slice) |tool| {
            if (std.mem.eql(u8, tool.name, call.name)) return tool.schema;
        }
        return null;
    }
    for (tools.builtinRegistry()) |tool| {
        if (std.mem.eql(u8, tool.name, call.name)) return tool.schema;
    }
    return null;
}

pub const CoercedValidation = struct {
    args: []u8,
    coerced: ?[]u8,
    validation: schema_mod.ValidationResult,

    pub fn deinit(self: *CoercedValidation, gpa: std.mem.Allocator) void {
        if (self.coerced) |c| gpa.free(c);
        self.validation.deinit(gpa);
    }
};

/// Coerce numeric string arguments and validate against the tool's schema.
pub fn validateAndCoerceCallArgs(gpa: std.mem.Allocator, schema: tools.Schema, call: ai.ToolCall) !CoercedValidation {
    // Some models emit numbers as strings despite the schema (e.g. `offset:"130"`).
    // Coerce those to real JSON numbers so the call passes validation AND dispatch
    // reaches the tool with proper numeric args.
    const coerced = schema_mod.coerceNumericStrings(gpa, schema, call.arguments) catch return error.OutOfMemory;
    errdefer if (coerced) |c| gpa.free(c);

    const args = coerced orelse call.arguments;
    const validation = schema_mod.validateArgs(gpa, schema, args) catch return error.OutOfMemory;
    return .{
        .args = args,
        .coerced = coerced,
        .validation = validation,
    };
}

test "resolveSchema correctly resolves builtin tools" {
    const gpa = std.testing.allocator;
    const call: ai.ToolCall = .{
        .call_id = .{ .value = try gpa.dupe(u8, "call_1") },
        .name = try gpa.dupe(u8, tools.shell_tool.name),
        .arguments = try gpa.dupe(u8, "{}"),
    };
    defer {
        gpa.free(call.call_id.value);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    const schema = resolveSchema(null, null, gpa, call);
    try std.testing.expect(schema != null);
    try std.testing.expect(schema.?.properties.len > 0);
}

test "resolveSchema returns null for unknown tool names" {
    const gpa = std.testing.allocator;
    const call: ai.ToolCall = .{
        .call_id = .{ .value = try gpa.dupe(u8, "call_unknown") },
        .name = try gpa.dupe(u8, "nonexistent_custom_tool_404"),
        .arguments = try gpa.dupe(u8, "{}"),
    };
    defer {
        gpa.free(call.call_id.value);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    const schema = resolveSchema(null, null, gpa, call);
    try std.testing.expect(schema == null);
}

test "resolveSchema handles malformed MCP tool names gracefully" {
    const gpa = std.testing.allocator;
    const malformed_names = [_][]const u8{
        "mcp__",
        "mcp__server",
        "mcp__server_tool",
        "mcp__server__",
    };

    for (malformed_names) |name| {
        const call: ai.ToolCall = .{
            .call_id = .{ .value = try gpa.dupe(u8, "call_mcp_malformed") },
            .name = try gpa.dupe(u8, name),
            .arguments = try gpa.dupe(u8, "{}"),
        };
        defer {
            gpa.free(call.call_id.value);
            gpa.free(call.name);
            gpa.free(call.arguments);
        }

        const schema = resolveSchema(null, null, gpa, call);
        try std.testing.expect(schema == null);
    }
}

test "validateAndCoerceCallArgs rejects non-object JSON payloads" {
    const gpa = std.testing.allocator;
    const props = [_]tools.Schema.Property{
        .{ .name = "path", .kind = .string, .description = "File path", .required = true },
    };
    const schema: tools.Schema = .{ .properties = &props };

    const invalid_payloads = [_][]const u8{
        "[1, 2, 3]",
        "123",
        "\"just a string\"",
        "true",
    };

    for (invalid_payloads) |payload| {
        const call: ai.ToolCall = .{
            .call_id = .{ .value = try gpa.dupe(u8, "call_invalid") },
            .name = try gpa.dupe(u8, "test_tool"),
            .arguments = try gpa.dupe(u8, payload),
        };
        defer {
            gpa.free(call.call_id.value);
            gpa.free(call.name);
            gpa.free(call.arguments);
        }

        var result = try validateAndCoerceCallArgs(gpa, schema, call);
        defer result.deinit(gpa);

        try std.testing.expect(!result.validation.isValid());
        const msg = try result.validation.formatMessage(gpa);
        defer gpa.free(msg);
        try std.testing.expect(std.mem.indexOf(u8, msg, "must be a JSON object") != null or std.mem.indexOf(u8, msg, "must be valid JSON") != null);
    }
}

test "validateAndCoerceCallArgs handles empty arguments string" {
    const gpa = std.testing.allocator;
    const props = [_]tools.Schema.Property{
        .{ .name = "command", .kind = .string, .description = "Shell command", .required = true },
    };
    const schema: tools.Schema = .{ .properties = &props };

    const call: ai.ToolCall = .{
        .call_id = .{ .value = try gpa.dupe(u8, "call_empty") },
        .name = try gpa.dupe(u8, "bash"),
        .arguments = try gpa.dupe(u8, ""),
    };
    defer {
        gpa.free(call.call_id.value);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    var result = try validateAndCoerceCallArgs(gpa, schema, call);
    defer result.deinit(gpa);

    try std.testing.expect(!result.validation.isValid());
}

test "validateAndCoerceCallArgs coerces numeric strings but preserves non-numeric strings" {
    const gpa = std.testing.allocator;
    const props = [_]tools.Schema.Property{
        .{ .name = "count", .kind = .integer, .description = "Total count", .required = true },
        .{ .name = "label", .kind = .string, .description = "Label name", .required = false },
    };
    const schema: tools.Schema = .{ .properties = &props };

    // Positive space: coercion succeeds for "count": "42"
    {
        const call: ai.ToolCall = .{
            .call_id = .{ .value = try gpa.dupe(u8, "call_coerce") },
            .name = try gpa.dupe(u8, "count_tool"),
            .arguments = try gpa.dupe(u8, "{\"count\":\"42\",\"label\":\"100\"}"),
        };
        defer {
            gpa.free(call.call_id.value);
            gpa.free(call.name);
            gpa.free(call.arguments);
        }

        var result = try validateAndCoerceCallArgs(gpa, schema, call);
        defer result.deinit(gpa);

        try std.testing.expect(result.coerced != null);
        try std.testing.expect(result.validation.isValid());
        try std.testing.expect(std.mem.indexOf(u8, result.args, "\"count\":42") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.args, "\"label\":\"100\"") != null);
    }

    // Negative space: "count": "not_a_number" cannot be coerced and fails validation
    {
        const call: ai.ToolCall = .{
            .call_id = .{ .value = try gpa.dupe(u8, "call_fail") },
            .name = try gpa.dupe(u8, "count_tool"),
            .arguments = try gpa.dupe(u8, "{\"count\":\"not_a_number\",\"label\":\"abc\"}"),
        };
        defer {
            gpa.free(call.call_id.value);
            gpa.free(call.name);
            gpa.free(call.arguments);
        }

        var result = try validateAndCoerceCallArgs(gpa, schema, call);
        defer result.deinit(gpa);

        try std.testing.expect(!result.validation.isValid());
        const msg = try result.validation.formatMessage(gpa);
        defer gpa.free(msg);
        try std.testing.expect(std.mem.indexOf(u8, msg, "count") != null);
    }
}

test "validateAndCoerceCallArgs coerces quoted booleans" {
    const gpa = std.testing.allocator;
    const props = [_]tools.Schema.Property{
        .{ .name = "run_in_background", .kind = .boolean, .description = "", .required = false },
    };
    const schema: tools.Schema = .{ .properties = &props };
    const call: ai.ToolCall = .{
        .call_id = .{ .value = try gpa.dupe(u8, "call_background") },
        .name = try gpa.dupe(u8, "bash"),
        .arguments = try gpa.dupe(u8, "{\"run_in_background\":\"true\"}"),
    };
    defer {
        gpa.free(call.call_id.value);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    var result = try validateAndCoerceCallArgs(gpa, schema, call);
    defer result.deinit(gpa);
    try std.testing.expect(result.validation.isValid());
    try std.testing.expectEqualStrings("{\"run_in_background\":true}", result.args);
}
