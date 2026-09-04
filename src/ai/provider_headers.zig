//! Single source of truth for headers on an outbound AI request.
//!
//! INV-RESP-1 sibling of `model_compat.zig`: a pure quirk leaf imported by
//! BOTH wire transports (chat-completions and Responses API) and the models
//! probe — never through each other. It owns three things:
//!
//!   1. the header spec type (`Header` / `HeaderValue`),
//!   2. the merge policy (`build`): provider-required auto headers (OpenCode
//!      Zen routing, OpenRouter attribution) overlaid with user-configured
//!      headers, user winning on name collision,
//!   3. the materializer (`HeaderSet`): a zero-allocation stack-buffer
//!      builder that resolves specs into wire headers per request.
//!
//! Headers are transport-layer and orthogonal to `WireDialect` body gating.
//! Zen routing headers in particular are NOT suppressed by
//! `disable_prompt_cache`: the provider requires them regardless of the
//! user's cache-field preference, so `build` never consults that flag.

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.ai);

const ai = @import("../ai.zig");

/// OpenCode Zen endpoints (`https://opencode.ai/zen/v1`, `/zen/go/v1`, …)
/// require a stable per-conversation routing header as of 2026-09-05.
/// Substring detection covers the builtin `opencode_zen` provider, the
/// models.dev dynamic ids `opencode`/`opencode-go`, and hand-written custom
/// providers — mirroring the `WireDialect.resolve` URL heuristics.
pub const zen_url_marker = "opencode.ai/zen";
pub const zen_session_header = "x-opencode-session";
pub const zen_client_header = "x-opencode-client";
pub const zen_client_value = "nova";

/// OpenRouter app attribution (marketplace ranking + rate-limit priority),
/// migrated from the chat client's `app_title` special case.
pub const openrouter_title_header = "X-Title";
pub const openrouter_title_value = "Nova";

/// Hard cap on a `ResponsesConfig.headers` profile table. The codex profile
/// uses 7 of these 8 slots.
pub const max_profile_headers: usize = 8;

/// Parse-time cap on user-configured headers per provider.
pub const max_user_headers: usize = 8;

/// Provider-required auto headers ever emitted by `build`: the zen pair
/// plus the OpenRouter attribution (which never co-occur, but the bound
/// must hold by construction, not by coincidence).
const max_auto_headers: usize = 3;

/// Worst case one request's extra-headers block. Every send site sizes its
/// stack buffer with this; `HeaderSet` drops (with a warn) rather than
/// overflows if a path ever exceeds it.
pub const max_outbound_headers: usize = max_profile_headers + max_user_headers + max_auto_headers;

comptime {
    // The codex profile is 7 entries; the outbound bound must dominate it
    // plus the full user and auto budgets.
    assert(7 + max_user_headers + max_auto_headers <= max_outbound_headers);
}

/// The value of a header spec. Auto headers reference client-owned strings
/// indirectly (resolved per request); user headers are always `.literal`
/// after attach-time `{env:VAR}` expansion.
pub const HeaderValue = union(enum) {
    literal: []const u8,
    session_id,
    account_id,
};

pub const Header = struct {
    name: []const u8,
    value: HeaderValue,
};

/// Per-request resolution context for dynamic header values, read from
/// client-owned strings so spec lists stay immutable across requests.
pub const ValueContext = struct {
    session_id: []const u8 = "",
    account_id: []const u8 = "",
};

/// True when the base URL points at OpenCode Zen. The two-clause match
/// rejects lookalike suffixes (`…/zenith`) while accepting a bare
/// `…/zen` with no trailing slash.
pub fn isZenBaseUrl(base_url: []const u8) bool {
    return std.mem.indexOf(u8, base_url, zen_url_marker ++ "/") != null or
        std.mem.endsWith(u8, base_url, zen_url_marker);
}

/// Merge provider-required auto headers with user-configured headers.
/// Precedence: a user header whose name matches (ASCII case-insensitive,
/// per HTTP semantics) an auto header REPLACES it; non-colliding user
/// headers follow in config order. The result is fully owned (names and
/// literal values duped) — free with `freeHeaders`. Inputs are borrowed.
pub fn build(
    gpa: std.mem.Allocator,
    base_url: []const u8,
    dialect: ai.WireDialect,
    user: []const Header,
) ![]Header {
    assert(user.len <= max_user_headers);

    var auto_buffer: [max_auto_headers]Header = undefined;
    const auto = auto_buffer[0..appendAutoHeaders(&auto_buffer, base_url, dialect)];

    var out: std.ArrayList(Header) = .empty;
    errdefer {
        freeHeaderValues(gpa, out.items);
        out.deinit(gpa);
    }

    for (auto) |auto_header| {
        if (indexOfName(user, auto_header.name)) |user_index| {
            try appendOwned(gpa, &out, user[user_index]);
        } else {
            try appendOwned(gpa, &out, auto_header);
        }
    }
    for (user) |user_header| {
        if (indexOfName(auto, user_header.name) != null) continue;
        try appendOwned(gpa, &out, user_header);
    }
    return out.toOwnedSlice(gpa);
}

/// Deep-copy a spec list (names + literal values); dynamic tags copy as-is.
/// Returns the empty static slice for an empty input. Mirrors
/// `mcp.cloneHeaders` — this is what clients call to take ownership of the
/// borrowed `ai.Config.headers` slice.
pub fn cloneHeaders(gpa: std.mem.Allocator, headers: []const Header) ![]Header {
    if (headers.len == 0) return &.{};
    const out = try gpa.alloc(Header, headers.len);
    var done: usize = 0;
    errdefer {
        freeHeaderValues(gpa, out[0..done]);
        gpa.free(out);
    }
    for (headers, 0..) |header, index| {
        // Per-field errdefers, discharged once the element lands in `out`:
        // a failure mid-literal must not orphan the already-duped name.
        const name = try gpa.dupe(u8, header.name);
        errdefer gpa.free(name);
        const value: HeaderValue = switch (header.value) {
            .literal => |literal| .{ .literal = try gpa.dupe(u8, literal) },
            .session_id => .session_id,
            .account_id => .account_id,
        };
        errdefer switch (value) {
            .literal => |literal| gpa.free(literal),
            .session_id, .account_id => {},
        };
        out[index] = .{ .name = name, .value = value };
        done += 1;
    }
    return out;
}

/// Free a list produced by `build` or `cloneHeaders` (values + the slice
/// itself). No-op for the empty static slice.
pub fn freeHeaders(gpa: std.mem.Allocator, headers: []Header) void {
    freeHeaderValues(gpa, headers);
    if (headers.len > 0) gpa.free(headers);
}

/// Free only the owned contents of a list whose backing storage belongs to
/// someone else (e.g. an ArrayList still in use).
pub fn freeHeaderValues(gpa: std.mem.Allocator, headers: []Header) void {
    for (headers) |*header| {
        gpa.free(header.name);
        switch (header.value) {
            .literal => |literal| gpa.free(literal),
            .session_id, .account_id => {},
        }
    }
}

/// Zero-allocation per-request materializer: resolves specs into a
/// caller-owned stack buffer of wire headers. The buffer must outlive the
/// HTTP request it is passed to (send sites keep it on their own frame).
pub const HeaderSet = struct {
    buffer: []std.http.Header,
    count: usize = 0,

    pub fn init(buffer: []std.http.Header) HeaderSet {
        return .{ .buffer = buffer };
    }

    /// Append each spec unless its name is already present (ASCII
    /// case-insensitive) — first writer within one materialization wins —
    /// or the buffer is full (dropped with a warn). A value that resolves
    /// empty skips its header entirely: an empty-valued header is itself
    /// often a 400. Values carrying wire-invalid bytes (CR/LF header
    /// injection) are rejected here too — this is the single chokepoint
    /// every send site flows through, so it backstops every producer,
    /// including `{env:VAR}` expansion that runs after parse validation.
    pub fn append(self: *HeaderSet, specs: []const Header, context: ValueContext) void {
        for (specs) |spec| {
            if (self.indexOfName(spec.name) != null) continue;
            const value = resolveValue(spec.value, context) orelse continue;
            if (!isValidHeaderValue(value)) {
                log.warn("provider_headers.reject invalid_value_bytes name={s}", .{spec.name});
                continue;
            }
            if (self.count == self.buffer.len) {
                log.warn("provider_headers.drop buffer_full name={s}", .{spec.name});
                break;
            }
            self.buffer[self.count] = .{ .name = spec.name, .value = value };
            self.count += 1;
        }
    }

    pub fn slice(self: *const HeaderSet) []const std.http.Header {
        return self.buffer[0..self.count];
    }

    fn indexOfName(self: *const HeaderSet, name: []const u8) ?usize {
        for (self.buffer[0..self.count], 0..) |header, index| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) return index;
        }
        return null;
    }
};

fn resolveValue(value: HeaderValue, context: ValueContext) ?[]const u8 {
    return switch (value) {
        // Empty literals arise from unset `{env:VAR}` expansion (parse
        // rejects empty raw values) — skip rather than send an empty-valued
        // header, matching the dynamic arms.
        .literal => |literal| if (literal.len > 0) literal else null,
        .session_id => if (context.session_id.len > 0) context.session_id else null,
        .account_id => if (context.account_id.len > 0) context.account_id else null,
    };
}

/// True when `value` is safe as an HTTP header value on the wire: visible
/// ASCII, space, horizontal tab, or obs-text (RFC 7230 field-vchar). CR/LF
/// (header injection) and every other control byte are rejected. This is
/// the post-expansion backstop — parse-time validation sees only the raw
/// config value, so an env var containing control bytes would otherwise
/// reach the socket verbatim.
pub fn isValidHeaderValue(value: []const u8) bool {
    for (value) |c| {
        switch (c) {
            '\t', ' '...'~', 0x80...0xff => {},
            else => return false,
        }
    }
    return true;
}

fn appendAutoHeaders(buffer: *[max_auto_headers]Header, base_url: []const u8, dialect: ai.WireDialect) usize {
    var count: usize = 0;
    if (isZenBaseUrl(base_url)) {
        buffer[count] = .{ .name = zen_session_header, .value = .session_id };
        count += 1;
        buffer[count] = .{ .name = zen_client_header, .value = .{ .literal = zen_client_value } };
        count += 1;
    }
    if (dialect == .openrouter) {
        buffer[count] = .{ .name = openrouter_title_header, .value = .{ .literal = openrouter_title_value } };
        count += 1;
    }
    assert(count <= max_auto_headers);
    return count;
}

fn appendOwned(gpa: std.mem.Allocator, out: *std.ArrayList(Header), header: Header) !void {
    const name = try gpa.dupe(u8, header.name);
    errdefer gpa.free(name);
    const value: HeaderValue = switch (header.value) {
        .literal => |literal| .{ .literal = try gpa.dupe(u8, literal) },
        .session_id => .session_id,
        .account_id => .account_id,
    };
    errdefer switch (value) {
        .literal => |literal| gpa.free(literal),
        .session_id, .account_id => {},
    };
    try out.append(gpa, .{ .name = name, .value = value });
}

fn indexOfName(headers: []const Header, name: []const u8) ?usize {
    for (headers, 0..) |header, index| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return index;
    }
    return null;
}

test "isZenBaseUrl matches zen endpoints and rejects lookalikes" {
    try std.testing.expect(isZenBaseUrl("https://opencode.ai/zen/v1"));
    try std.testing.expect(isZenBaseUrl("https://opencode.ai/zen/go/v1"));
    try std.testing.expect(isZenBaseUrl("https://opencode.ai/zen"));
    try std.testing.expect(isZenBaseUrl("https://opencode.ai/zen/"));
    try std.testing.expect(!isZenBaseUrl("https://opencode.ai/zenith/v1"));
    try std.testing.expect(!isZenBaseUrl("https://api.openai.com/v1"));
    try std.testing.expect(!isZenBaseUrl("https://openrouter.ai/api"));
    try std.testing.expect(!isZenBaseUrl(""));
}

test "build emits the zen pair for zen URLs regardless of dialect" {
    const gpa = std.testing.allocator;
    const specs = try build(gpa, "https://opencode.ai/zen/v1", .minimal, &.{});
    defer freeHeaders(gpa, specs);

    try std.testing.expectEqual(@as(usize, 2), specs.len);
    try std.testing.expectEqualStrings(zen_session_header, specs[0].name);
    try std.testing.expect(specs[0].value == .session_id);
    try std.testing.expectEqualStrings(zen_client_header, specs[1].name);
    try std.testing.expectEqualStrings(zen_client_value, specs[1].value.literal);
}

test "build user header overrides the auto zen session header" {
    const gpa = std.testing.allocator;
    const specs = try build(gpa, "https://opencode.ai/zen/v1", .minimal, &.{
        .{ .name = "X-OpenCode-Session", .value = .{ .literal = "pinned-session" } },
        .{ .name = "x-custom-trace", .value = .{ .literal = "trace-1" } },
    });
    defer freeHeaders(gpa, specs);

    // The user's casing is preserved; the auto session header is replaced,
    // not duplicated.
    try std.testing.expectEqual(@as(usize, 3), specs.len);
    try std.testing.expectEqualStrings("X-OpenCode-Session", specs[0].name);
    try std.testing.expectEqualStrings("pinned-session", specs[0].value.literal);
    try std.testing.expectEqualStrings(zen_client_header, specs[1].name);
    try std.testing.expectEqualStrings("x-custom-trace", specs[2].name);
}

test "build emits OpenRouter attribution and no zen headers for openrouter" {
    const gpa = std.testing.allocator;
    const specs = try build(gpa, "https://openrouter.ai/api", .openrouter, &.{});
    defer freeHeaders(gpa, specs);

    try std.testing.expectEqual(@as(usize, 1), specs.len);
    try std.testing.expectEqualStrings(openrouter_title_header, specs[0].name);
    try std.testing.expectEqualStrings(openrouter_title_value, specs[0].value.literal);
}

test "build with neutral URL and no user headers is empty" {
    const gpa = std.testing.allocator;
    const specs = try build(gpa, "http://localhost:11434", .minimal, &.{});
    defer freeHeaders(gpa, specs);
    try std.testing.expectEqual(@as(usize, 0), specs.len);
}

test "cloneHeaders deep-copies and freeHeaders is a no-op for empty" {
    const gpa = std.testing.allocator;
    var original: [1]Header = .{.{ .name = "x-a", .value = .{ .literal = "1" } }};
    const owned = try cloneHeaders(gpa, original[0..]);
    defer freeHeaders(gpa, owned);

    original[0].value.literal = "mutated";
    try std.testing.expectEqualStrings("1", owned[0].value.literal);

    freeHeaders(gpa, &.{});
}

test "HeaderSet skips empty dynamic values and dedupes names" {
    var buffer: [max_outbound_headers]std.http.Header = undefined;
    var set = HeaderSet.init(&buffer);

    set.append(&.{
        .{ .name = zen_session_header, .value = .session_id },
        .{ .name = zen_client_header, .value = .{ .literal = zen_client_value } },
        .{ .name = "X-OPencode-CLIENT", .value = .{ .literal = "dupe" } },
    }, .{ .session_id = "" });

    // Empty session id skips the session header; the case-insensitive name
    // dedupe keeps the first writer.
    const wire = set.slice();
    try std.testing.expectEqual(@as(usize, 1), wire.len);
    try std.testing.expectEqualStrings(zen_client_header, wire[0].name);

    set.append(&.{.{ .name = "x-late", .value = .{ .literal = "v" } }}, .{});
    try std.testing.expectEqual(@as(usize, 2), set.slice().len);
}

test "HeaderSet drops instead of overflowing a full buffer" {
    var buffer: [2]std.http.Header = undefined;
    var set = HeaderSet.init(&buffer);

    var specs: [4]Header = undefined;
    for (&specs, 0..) |*spec, index| {
        spec.* = .{ .name = "x-h", .value = .{ .literal = "v" } };
        spec.name = switch (index) {
            0 => "x-a",
            1 => "x-b",
            2 => "x-c",
            else => "x-d",
        };
    }
    set.append(&specs, .{});
    try std.testing.expectEqual(@as(usize, 2), set.slice().len);
}

test "HeaderSet resolves account_id from the value context" {
    var buffer: [max_outbound_headers]std.http.Header = undefined;
    var set = HeaderSet.init(&buffer);
    set.append(&.{.{ .name = "chatgpt-account-id", .value = .account_id }}, .{ .account_id = "acct-7" });
    const wire = set.slice();
    try std.testing.expectEqual(@as(usize, 1), wire.len);
    try std.testing.expectEqualStrings("acct-7", wire[0].value);
}

test "isValidHeaderValue accepts wire-safe bytes and rejects control bytes" {
    try std.testing.expect(isValidHeaderValue("token abc~\t\x80"));
    try std.testing.expect(isValidHeaderValue(""));
    try std.testing.expect(!isValidHeaderValue("a\r\nb: injected"));
    try std.testing.expect(!isValidHeaderValue("trailing\n"));
    try std.testing.expect(!isValidHeaderValue("nul\x00"));
    try std.testing.expect(!isValidHeaderValue("del\x7f"));
}

test "HeaderSet rejects injected values and skips empty literals" {
    var buffer: [max_outbound_headers]std.http.Header = undefined;
    var set = HeaderSet.init(&buffer);
    set.append(&.{
        // CR/LF from a post-expansion env value must never reach the wire.
        .{ .name = "x-inject", .value = .{ .literal = "v\r\nHost: evil" } },
        // An empty literal (unset {env:VAR}) is skipped, not sent empty.
        .{ .name = "x-empty", .value = .{ .literal = "" } },
        .{ .name = "x-keep", .value = .{ .literal = "ok" } },
    }, .{});

    const wire = set.slice();
    try std.testing.expectEqual(@as(usize, 1), wire.len);
    try std.testing.expectEqualStrings("x-keep", wire[0].name);
}
