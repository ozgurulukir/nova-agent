//! Tool argument validation against `tools_common.Schema`.
//!
//! Pure functions — no executor, no I/O, no registry access — so the validator
//! is testable in isolation and shared by every dispatch channel (builtin /
//! plugin / MCP). The executor calls `validateArgs` once before dispatching;
//! a non-empty violation list becomes a structured error message back to the
//! model instead of letting the tool run (and fail) on garbage input.
//!
//! v1 scope deliberately narrow: it validates declared properties (presence,
//! type, nullable, enum) but NOT `additionalProperties` (the `Schema` type
//! carries no `additional_properties` flag) and NOT nested object/array
//! element schemas. See the strict-tool-schema plan for the v2 extensions.

const std = @import("std");
const tools_common = @import("common.zig");

/// One property violation. `path` is the field name, `expected` the
/// type/constraint it failed, `got` a short rendering of what was actually
/// sent (null when there was no value — the required-but-missing case).
/// All owned slices are freed by `deinit`.
pub const Violation = struct {
    path: []u8,
    expected: []u8,
    got: ?[]u8 = null,

    pub fn deinit(self: *Violation, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.expected);
        if (self.got) |got| gpa.free(got);
        self.* = undefined;
    }
};

/// The outcome of validating one tool call. Empty `violations` means the
/// arguments are valid. Owned; freed with `deinit`.
pub const ValidationResult = struct {
    violations: std.ArrayList(Violation) = .empty,

    pub fn deinit(self: *ValidationResult, gpa: std.mem.Allocator) void {
        for (self.violations.items) |*v| v.deinit(gpa);
        self.violations.deinit(gpa);
        self.* = undefined;
    }

    pub fn isValid(self: *const ValidationResult) bool {
        return self.violations.items.len == 0;
    }

    /// Join every violation into one model-facing message so a single failed
    /// call reports all problems at once:
    /// `` `command` is required; `timeout` must be integer (got: "abc") ``
    pub fn formatMessage(self: *const ValidationResult, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        for (self.violations.items, 0..) |v, i| {
            if (i > 0) try out.appendSlice(gpa, "; ");
            try out.append(gpa, '`');
            try out.appendSlice(gpa, v.path);
            try out.appendSlice(gpa, "` ");
            try out.appendSlice(gpa, v.expected);
            if (v.got) |got| {
                try out.appendSlice(gpa, " (got: ");
                try out.appendSlice(gpa, got);
                try out.append(gpa, ')');
            }
        }
        return out.toOwnedSlice(gpa);
    }
};

/// Validate a tool call's `arguments` JSON string against a schema. Returns a
/// `ValidationResult`; callers check `isValid()` before dispatching.
///
/// Handles the degenerate inputs `runOne` can receive: an empty string, invalid
/// JSON, and `"{}"` — each becomes a targeted violation rather than a crash.
pub fn validateArgs(
    gpa: std.mem.Allocator,
    schema: tools_common.Schema,
    args_json: []const u8,
) !ValidationResult {
    var result: ValidationResult = .{};
    errdefer result.deinit(gpa);

    const trimmed = std.mem.trim(u8, args_json, " \t\r\n");
    if (trimmed.len == 0) {
        // No arguments at all → only required-missing violations. An empty
        // schema passes as valid.
        for (schema.properties) |prop| {
            if (prop.required) {
                try result.violations.append(gpa, try requiredViolation(gpa, prop.name));
            }
        }
        return result;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{}) catch {
        // Not valid JSON → single targeted violation. `got` is the offending
        // bytes, capped so a giant dump doesn't flood the model's context.
        try result.violations.append(gpa, .{
            .path = try gpa.dupe(u8, "arguments"),
            .expected = try gpa.dupe(u8, "must be valid JSON"),
            .got = try truncateDup(gpa, trimmed, raw_repr_max),
        });
        return result;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        try result.violations.append(gpa, .{
            .path = try gpa.dupe(u8, "arguments"),
            .expected = try gpa.dupe(u8, "must be a JSON object"),
            .got = try gpa.dupe(u8, jsonTypeName(parsed.value)),
        });
        return result;
    }

    const obj = parsed.value.object;
    for (schema.properties) |prop| {
        const value = obj.get(prop.name) orelse {
            if (prop.required) {
                try result.violations.append(gpa, try requiredViolation(gpa, prop.name));
            }
            // Optional-but-missing is valid regardless of `default_value`
            // (TD-2): defaults are the tool's internal business.
            continue;
        };
        try checkProperty(gpa, &result, prop, value);
    }
    // Extra / unknown fields are NOT rejected in v1 (TD-3).
    return result;
}

/// Coerce quoted numeric strings to real JSON numbers for `integer`/`number`
/// properties, returning an owned re-serialized arguments JSON when any value
/// changed (null when nothing did or the args aren't a parseable object).
///
/// Some models emit scalar values as strings despite the schema
/// (`"timeout":"130"`, `"run_in_background":"true"`). Real tool-calling
/// frameworks coerce these; without it such a call fails validation and the
/// model loops retrying the same quoted value. Coercing before dispatch lets the
/// tool actually run on inputs it can already handle. Unsupported strings are
/// left untouched so validation still reports them clearly.
pub fn coerceNumericStrings(
    gpa: std.mem.Allocator,
    schema: tools_common.Schema,
    args_json: []const u8,
) !?[]u8 {
    const trimmed = std.mem.trim(u8, args_json, " \t\r\n");
    if (trimmed.len == 0) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    var changed = false;
    for (schema.properties) |prop| {
        const v = parsed.value.object.getPtr(prop.name) orelse continue;
        if (v.* != .string) continue;
        if (prop.kind == .integer or prop.kind == .number) {
            const num = coerceNumericString(v.string) orelse continue;
            v.* = num;
            changed = true;
            continue;
        }
        if (prop.kind == .boolean) {
            const boolean = coerceBooleanString(v.string) orelse continue;
            v.* = .{ .bool = boolean };
            changed = true;
        }
    }
    if (!changed) return null;

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &buf.writer);
    return try buf.toOwnedSlice();
}

/// Interpret a string as a JSON number, or null when it isn't one. Integer
/// first so a whole number stays an integer; otherwise float.
fn coerceNumericString(s: []const u8) ?std.json.Value {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len == 0) return null;
    if (std.fmt.parseInt(i64, trimmed, 10)) |n| {
        return .{ .integer = n };
    } else |_| {}
    if (std.fmt.parseFloat(f64, trimmed)) |f| {
        return .{ .float = f };
    } else |_| {}
    return null;
}

fn coerceBooleanString(s: []const u8) ?bool {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (std.mem.eql(u8, trimmed, "true")) return true;
    if (std.mem.eql(u8, trimmed, "false")) return false;
    return null;
}

/// One type/nullable/enum check against a present value.
fn checkProperty(
    gpa: std.mem.Allocator,
    result: *ValidationResult,
    prop: tools_common.Schema.Property,
    value: std.json.Value,
) !void {
    if (value == .null) {
        if (!prop.nullable) {
            try appendViolation(gpa, result, prop.name, "must not be null", "null");
        }
        return;
    }

    // Type check (TD-5): JSON integers satisfy both integer and number;
    // floats only number; a quoted "42" is neither.
    const kind_ok = switch (value) {
        .string => prop.kind == .string,
        // `.number_string` is a JSON number that overflows i64 — still a
        // number token, so it satisfies integer and number like `.integer`.
        .integer, .number_string => prop.kind == .integer or prop.kind == .number,
        .float => prop.kind == .number,
        .bool => prop.kind == .boolean,
        .object => prop.kind == .object,
        .array => prop.kind == .array,
        .null => unreachable,
    };
    if (!kind_ok) {
        const expected = try std.fmt.allocPrint(gpa, "must be {s}", .{@tagName(prop.kind)});
        defer gpa.free(expected);
        const got = try valueShortRepr(gpa, value);
        defer gpa.free(got);
        try appendViolation(gpa, result, prop.name, expected, got);
        return;
    }

    // Enum constraint — string-based (TD-5 note): a non-string value already
    // failed the type check above when the kind is string.
    if (value == .string and prop.enum_values != null) {
        const ev = prop.enum_values.?;
        var found = false;
        for (ev) |allowed| {
            if (std.mem.eql(u8, allowed, value.string)) {
                found = true;
                break;
            }
        }
        if (!found) {
            var expected: std.ArrayList(u8) = .empty;
            errdefer expected.deinit(gpa);
            try expected.appendSlice(gpa, "must be one of: ");
            for (ev, 0..) |allowed, i| {
                if (i > 0) try expected.appendSlice(gpa, ", ");
                try expected.appendSlice(gpa, allowed);
            }
            const expected_owned = try expected.toOwnedSlice(gpa);
            defer gpa.free(expected_owned);
            const got = try valueShortRepr(gpa, value);
            defer gpa.free(got);
            try appendViolation(gpa, result, prop.name, expected_owned, got);
        }
    }
}

fn requiredViolation(gpa: std.mem.Allocator, name: []const u8) !Violation {
    return .{
        .path = try gpa.dupe(u8, name),
        .expected = try gpa.dupe(u8, "is required"),
        .got = null,
    };
}

fn appendViolation(
    gpa: std.mem.Allocator,
    result: *ValidationResult,
    path: []const u8,
    expected: []const u8,
    got: []const u8,
) !void {
    try result.violations.append(gpa, .{
        .path = try gpa.dupe(u8, path),
        .expected = try gpa.dupe(u8, expected),
        .got = try gpa.dupe(u8, got),
    });
}

/// Short rendering of a JSON value for the `(got: …)` slot (plan §3.3).
/// Strings are quoted and capped; objects/arrays collapse to a marker.
fn valueShortRepr(gpa: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return switch (value) {
        .string => |s| std.fmt.allocPrint(gpa, "\"{s}\"", .{truncate(s, repr_max)}),
        .integer => |n| std.fmt.allocPrint(gpa, "{d}", .{n}),
        .float => |f| std.fmt.allocPrint(gpa, "{d}", .{f}),
        .number_string => |s| truncateDup(gpa, s, repr_max),
        .bool => |b| gpa.dupe(u8, if (b) "true" else "false"),
        .null => gpa.dupe(u8, "null"),
        .object => gpa.dupe(u8, "{object}"),
        .array => gpa.dupe(u8, "[array]"),
    };
}

fn jsonTypeName(value: std.json.Value) []const u8 {
    return switch (value) {
        .string => "string",
        .integer, .number_string => "integer",
        .float => "number",
        .bool => "boolean",
        .null => "null",
        .object => "object",
        .array => "array",
    };
}

const repr_max: usize = 50;
const raw_repr_max: usize = 80;

/// Borrow a prefix of `s`, never splitting a UTF-8 code point.
fn truncate(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var cut = max;
    while (cut > 0 and (s[cut] & 0xC0) == 0x80) cut -= 1;
    return s[0..cut];
}

fn truncateDup(gpa: std.mem.Allocator, s: []const u8, max: usize) ![]u8 {
    return gpa.dupe(u8, truncate(s, max));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_schema = tools_common.Schema{
    .properties = &.{
        .{ .name = "command", .kind = .string, .description = "", .required = true },
        .{ .name = "timeout", .kind = .integer, .description = "", .required = false, .nullable = true },
        .{ .name = "mode", .kind = .string, .description = "", .required = false, .nullable = true, .enum_values = &.{ "fast", "slow" } },
    },
};

fn expectValid(gpa: std.mem.Allocator, schema: tools_common.Schema, args: []const u8) !void {
    var result = try validateArgs(gpa, schema, args);
    defer result.deinit(gpa);
    if (!result.isValid()) {
        const msg = try result.formatMessage(gpa);
        defer gpa.free(msg);
        std.debug.print("expected valid, got: {s}\n", .{msg});
        return error.TestInvalid;
    }
}

test "empty string with required property is invalid" {
    const gpa = std.testing.allocator;
    var result = try validateArgs(gpa, test_schema, "");
    defer result.deinit(gpa);
    try std.testing.expect(!result.isValid());
    try std.testing.expectEqual(@as(usize, 1), result.violations.items.len);
    try std.testing.expectEqualStrings("command", result.violations.items[0].path);
}

test "empty string with no required properties is valid" {
    const gpa = std.testing.allocator;
    var result = try validateArgs(gpa, .{ .properties = &.{} }, "");
    defer result.deinit(gpa);
    try std.testing.expect(result.isValid());
}

test "invalid JSON is a single violation" {
    const gpa = std.testing.allocator;
    var result = try validateArgs(gpa, test_schema, "{bad");
    defer result.deinit(gpa);
    try std.testing.expect(!result.isValid());
    try std.testing.expectEqual(@as(usize, 1), result.violations.items.len);
    try std.testing.expect(std.mem.indexOf(u8, result.violations.items[0].expected, "valid JSON") != null);
}

test "empty object with required property is invalid" {
    const gpa = std.testing.allocator;
    var result = try validateArgs(gpa, test_schema, "{}");
    defer result.deinit(gpa);
    try std.testing.expect(!result.isValid());
    try std.testing.expectEqualStrings("command", result.violations.items[0].path);
}

test "empty object with no required properties is valid" {
    const gpa = std.testing.allocator;
    var result = try validateArgs(gpa, .{ .properties = &.{} }, "{}");
    defer result.deinit(gpa);
    try std.testing.expect(result.isValid());
}

test "non-object arguments are rejected" {
    const gpa = std.testing.allocator;
    var result = try validateArgs(gpa, .{ .properties = &.{} }, "[1,2,3]");
    defer result.deinit(gpa);
    try std.testing.expect(!result.isValid());
    try std.testing.expect(std.mem.indexOf(u8, result.violations.items[0].expected, "JSON object") != null);
}

test "correct types are valid" {
    const gpa = std.testing.allocator;
    const all_kinds = tools_common.Schema{
        .properties = &.{
            .{ .name = "s", .kind = .string, .description = "", .required = true },
            .{ .name = "i", .kind = .integer, .description = "", .required = true },
            .{ .name = "n", .kind = .number, .description = "", .required = true },
            .{ .name = "b", .kind = .boolean, .description = "", .required = true },
            .{ .name = "o", .kind = .object, .description = "", .required = true },
            .{ .name = "a", .kind = .array, .description = "", .required = true },
        },
    };
    try expectValid(gpa, all_kinds, "{\"s\":\"x\",\"i\":42,\"n\":4.5,\"b\":true,\"o\":{},\"a\":[]}");
}

test "wrong type is a violation naming the field" {
    const gpa = std.testing.allocator;
    var result = try validateArgs(gpa, test_schema, "{\"command\":42}");
    defer result.deinit(gpa);
    try std.testing.expect(!result.isValid());
    try std.testing.expectEqualStrings("command", result.violations.items[0].path);
    try std.testing.expect(std.mem.indexOf(u8, result.violations.items[0].expected, "string") != null);
    try std.testing.expectEqualStrings("42", result.violations.items[0].got.?);
}

test "integer vs number: float fails integer, passes number" {
    const gpa = std.testing.allocator;
    var result = try validateArgs(gpa, test_schema, "{\"command\":\"x\",\"timeout\":42.5}");
    defer result.deinit(gpa);
    try std.testing.expect(!result.isValid());
    try std.testing.expectEqualStrings("timeout", result.violations.items[0].path);

    const number_schema = tools_common.Schema{
        .properties = &.{.{ .name = "n", .kind = .number, .description = "", .required = true }},
    };
    try expectValid(gpa, number_schema, "{\"n\":42.5}");
    try expectValid(gpa, number_schema, "{\"n\":42}");
}

test "quoted number does not satisfy number kind" {
    const gpa = std.testing.allocator;
    const number_schema = tools_common.Schema{
        .properties = &.{.{ .name = "n", .kind = .number, .description = "", .required = true }},
    };
    var result = try validateArgs(gpa, number_schema, "{\"n\":\"42\"}");
    defer result.deinit(gpa);
    try std.testing.expect(!result.isValid());
}

test "nullable true accepts explicit null" {
    const gpa = std.testing.allocator;
    try expectValid(gpa, test_schema, "{\"command\":\"x\",\"timeout\":null}");
}

test "nullable false rejects explicit null" {
    const gpa = std.testing.allocator;
    const non_null = tools_common.Schema{
        .properties = &.{.{ .name = "v", .kind = .string, .description = "", .required = false, .nullable = false }},
    };
    var result = try validateArgs(gpa, non_null, "{\"v\":null}");
    defer result.deinit(gpa);
    try std.testing.expect(!result.isValid());
    try std.testing.expect(std.mem.indexOf(u8, result.violations.items[0].expected, "must not be null") != null);
}

test "optional missing field is valid" {
    const gpa = std.testing.allocator;
    try expectValid(gpa, test_schema, "{\"command\":\"x\"}");
}

test "default_value does not relax a required field (TD-2)" {
    const gpa = std.testing.allocator;
    const schema = tools_common.Schema{
        .properties = &.{.{ .name = "mode", .kind = .string, .description = "", .required = true, .default_value = "\"fast\"" }},
    };
    var result = try validateArgs(gpa, schema, "{}");
    defer result.deinit(gpa);
    try std.testing.expect(!result.isValid());
}

test "default_value with optional missing field is valid (TD-2)" {
    const gpa = std.testing.allocator;
    const schema = tools_common.Schema{
        .properties = &.{.{ .name = "mode", .kind = .string, .description = "", .required = false, .default_value = "\"fast\"" }},
    };
    try expectValid(gpa, schema, "{}");
}

test "enum accepts a listed value" {
    const gpa = std.testing.allocator;
    try expectValid(gpa, test_schema, "{\"command\":\"x\",\"mode\":\"fast\"}");
}

test "enum rejects an unlisted value" {
    const gpa = std.testing.allocator;
    var result = try validateArgs(gpa, test_schema, "{\"command\":\"x\",\"mode\":\"turbo\"}");
    defer result.deinit(gpa);
    try std.testing.expect(!result.isValid());
    try std.testing.expectEqualStrings("mode", result.violations.items[0].path);
    try std.testing.expect(std.mem.indexOf(u8, result.violations.items[0].expected, "fast, slow") != null);
    try std.testing.expectEqualStrings("\"turbo\"", result.violations.items[0].got.?);
}

test "multiple violations are all reported" {
    const gpa = std.testing.allocator;
    var result = try validateArgs(gpa, test_schema, "{\"mode\":\"turbo\",\"timeout\":42.5}");
    defer result.deinit(gpa);
    try std.testing.expect(!result.isValid());
    // command missing + mode enum + timeout float-integer = 3 violations.
    try std.testing.expectEqual(@as(usize, 3), result.violations.items.len);
}

test "formatMessage renders the plan's message shape" {
    const gpa = std.testing.allocator;
    var result = try validateArgs(gpa, test_schema, "{\"command\":42}");
    defer result.deinit(gpa);
    const msg = try result.formatMessage(gpa);
    defer gpa.free(msg);
    try std.testing.expectEqualStrings("`command` must be string (got: 42)", msg);
}

test "coerceNumericStrings converts quoted integers for integer/number props" {
    const gpa = std.testing.allocator;
    // test_schema has `timeout` integer; `command` is string and must be untouched.
    const coerced = try coerceNumericStrings(gpa, test_schema, "{\"command\":\"x\",\"timeout\":\"130\"}");
    defer if (coerced) |c| gpa.free(c);
    try std.testing.expect(coerced != null);
    try std.testing.expectEqualStrings("{\"command\":\"x\",\"timeout\":130}", coerced.?);
    // And the coerced args now validate (the quoted version would not).
    var result = try validateArgs(gpa, test_schema, coerced.?);
    defer result.deinit(gpa);
    try std.testing.expect(result.isValid());
}

test "coerceNumericStrings leaves non-numeric strings and non-number props alone" {
    const gpa = std.testing.allocator;
    // `timeout":"abc"` is not a number -> unchanged -> null (no coercion).
    const n = try coerceNumericStrings(gpa, test_schema, "{\"command\":\"x\",\"timeout\":\"abc\"}");
    defer if (n) |c| gpa.free(c);
    try std.testing.expect(n == null);
    // Integer already a number -> null.
    const m = try coerceNumericStrings(gpa, test_schema, "{\"command\":\"x\",\"timeout\":30}");
    defer if (m) |c| gpa.free(c);
    try std.testing.expect(m == null);
}

test "coerceNumericStrings handles floats and string-typed fields" {
    const gpa = std.testing.allocator;
    const number_schema = tools_common.Schema{
        .properties = &.{
            .{ .name = "n", .kind = .number, .description = "", .required = true },
            .{ .name = "s", .kind = .string, .description = "", .required = true },
        },
    };
    // "42.5" -> 42.5 (float); "42" stays an integer for a number field.
    const a = try coerceNumericStrings(gpa, number_schema, "{\"n\":\"42.5\",\"s\":\"keep\"}");
    defer if (a) |c| gpa.free(c);
    try std.testing.expect(a != null);
    try std.testing.expectEqualStrings("{\"n\":42.5,\"s\":\"keep\"}", a.?);
    // `s` is string-typed; a quoted numeric string for it must NOT be coerced.
    const b = try coerceNumericStrings(gpa, number_schema, "{\"n\":1,\"s\":\"42\"}");
    defer if (b) |c| gpa.free(c);
    try std.testing.expect(b == null);
}

test "coerceNumericStrings converts quoted booleans for boolean props" {
    const gpa = std.testing.allocator;
    const boolean_schema: tools_common.Schema = .{
        .properties = &.{
            .{ .name = "run_in_background", .kind = .boolean, .description = "", .required = false },
        },
    };

    const enabled = try coerceNumericStrings(gpa, boolean_schema, "{\"run_in_background\":\"true\"}");
    defer if (enabled) |c| gpa.free(c);
    try std.testing.expectEqualStrings("{\"run_in_background\":true}", enabled.?);

    const disabled = try coerceNumericStrings(gpa, boolean_schema, "{\"run_in_background\":\"false\"}");
    defer if (disabled) |c| gpa.free(c);
    try std.testing.expectEqualStrings("{\"run_in_background\":false}", disabled.?);

    const invalid = try coerceNumericStrings(gpa, boolean_schema, "{\"run_in_background\":\"yes\"}");
    defer if (invalid) |c| gpa.free(c);
    try std.testing.expect(invalid == null);
}
