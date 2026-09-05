//! MCP server configuration types and `{env:VAR}` expansion.
//!
//! Self-contained: no dependency on Provider, Config, or the parse
//! pipeline. Imported by `config.zig` (which re-exports the public
//! surface) and directly by the MCP manager/client.

const std = @import("std");
const log = std.log.scoped(.mcp);
const platform = @import("platform");

/// An extra HTTP header sent with every remote MCP request (e.g. an API key).
/// Both fields are owned. Values support `{env:VAR}` expansion at parse time so
/// secrets stay in the environment, not config.json.
pub const McpHeader = struct {
    name: []u8,
    value: []u8,
};

/// Deep-copy a header list. Returns the empty static slice for an empty input.
pub fn cloneHeaders(gpa: std.mem.Allocator, headers: []const McpHeader) ![]McpHeader {
    if (headers.len == 0) return &.{};
    const out = try gpa.alloc(McpHeader, headers.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(out);
    }
    for (headers, 0..) |h, i| {
        out[i] = .{
            .name = try gpa.dupe(u8, h.name),
            .value = try gpa.dupe(u8, h.value),
        };
        done += 1;
    }
    return out;
}

/// Free a header list produced by `cloneHeaders` (or the parser). No-op for the
/// empty static slice.
pub fn freeHeaders(gpa: std.mem.Allocator, headers: []McpHeader) void {
    for (headers) |h| {
        gpa.free(h.name);
        gpa.free(h.value);
    }
    if (headers.len > 0) gpa.free(headers);
}

pub const McpServerConfig = struct {
    name: []u8,
    enabled: bool = true,
    /// Per-server request timeout in milliseconds (post-connect I/O only —
    /// the connect phase is not bounded). `null` → the client's default (30s).
    /// Applied as SO_RCVTIMEO/SO_SNDTIMEO for the Streamable HTTP transport
    /// and as the stdio poll timeout.
    request_timeout_ms: ?u32 = null,
    /// How the server is reached. Variants make illegal combinations
    /// unrepresentable: a stdio server must have command+args, an sse
    /// server must have a url.
    transport: union(enum) {
        stdio: struct {
            command: []u8,
            args: [][]u8 = &.{},
        },
        sse: struct {
            url: []u8,
            /// Extra HTTP headers sent with every request (e.g. API keys).
            headers: []McpHeader = &.{},
        },
    },

    pub fn deinit(self: *McpServerConfig, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        switch (self.transport) {
            .stdio => |t| {
                gpa.free(t.command);
                for (t.args) |arg| gpa.free(arg);
                if (t.args.len > 0) gpa.free(t.args);
            },
            .sse => |t| {
                gpa.free(t.url);
                freeHeaders(gpa, t.headers);
            },
        }
        self.* = undefined;
    }

    pub fn clone(self: McpServerConfig, gpa: std.mem.Allocator) !McpServerConfig {
        return .{
            .name = try gpa.dupe(u8, self.name),
            .enabled = self.enabled,
            .request_timeout_ms = self.request_timeout_ms,
            .transport = switch (self.transport) {
                .stdio => |t| blk: {
                    var args = try gpa.alloc([]u8, t.args.len);
                    errdefer gpa.free(args);
                    for (t.args, 0..) |arg, i| args[i] = try gpa.dupe(u8, arg);
                    break :blk .{ .stdio = .{
                        .command = try gpa.dupe(u8, t.command),
                        .args = args,
                    } };
                },
                .sse => |t| .{ .sse = .{
                    .url = try gpa.dupe(u8, t.url),
                    .headers = try cloneHeaders(gpa, t.headers),
                } },
            },
        };
    }
};

/// Build a remote (Streamable HTTP) MCP server config from a name and a raw URL.
/// The URL is stored verbatim (any `{env:VAR}` placeholder is expanded later, at
/// connect time, by `expandMcpServer`). Used by the TUI's "add server by URL"
/// flow. Caller owns the result; free with `McpServerConfig.deinit`.
pub fn mcpServerFromUrl(gpa: std.mem.Allocator, name: []const u8, raw_url: []const u8) !McpServerConfig {
    return .{
        .name = try gpa.dupe(u8, name),
        .enabled = true,
        .transport = .{ .sse = .{ .url = try gpa.dupe(u8, raw_url) } },
    };
}

/// Resolve every `{env:VAR}` placeholder in a server's command/args/url/header
/// values against the process environment, returning a newly-allocated server
/// ready for actual use (spawning / HTTP). The input keeps its raw placeholders
/// so it stays safe to `serialize` back to config.json; only this expanded copy
/// — held by the MCP client, never written to disk — carries resolved secrets.
/// Caller owns the result; free with `McpServerConfig.deinit`.
pub fn expandMcpServer(gpa: std.mem.Allocator, server: McpServerConfig) !McpServerConfig {
    var env_map = try loadEnvMap(gpa);
    defer env_map.deinit();

    var out: McpServerConfig = .{
        .name = try gpa.dupe(u8, server.name),
        .enabled = server.enabled,
        .request_timeout_ms = server.request_timeout_ms,
        .transport = undefined,
    };
    errdefer out.deinit(gpa);

    switch (server.transport) {
        .stdio => |t| {
            var args: [][]u8 = &.{};
            if (t.args.len > 0) {
                const expanded = try gpa.alloc([]u8, t.args.len);
                var done: usize = 0;
                errdefer {
                    for (expanded[0..done]) |arg| gpa.free(arg);
                    gpa.free(expanded);
                }
                for (t.args, 0..) |arg, i| {
                    expanded[i] = try expandEnvVars(gpa, arg, &env_map);
                    done += 1;
                }
                args = expanded;
            }
            out.transport = .{ .stdio = .{
                .command = try expandEnvVars(gpa, t.command, &env_map),
                .args = args,
            } };
        },
        .sse => |t| {
            var headers: []McpHeader = &.{};
            if (t.headers.len > 0) {
                const expanded = try gpa.alloc(McpHeader, t.headers.len);
                var done: usize = 0;
                errdefer {
                    for (expanded[0..done]) |h| {
                        gpa.free(h.name);
                        gpa.free(h.value);
                    }
                    gpa.free(expanded);
                }
                for (t.headers, 0..) |h, i| {
                    expanded[i] = .{
                        .name = try gpa.dupe(u8, h.name),
                        .value = try expandEnvVars(gpa, h.value, &env_map),
                    };
                    done += 1;
                }
                headers = expanded;
            }
            out.transport = .{ .sse = .{
                .url = try expandEnvVars(gpa, t.url, &env_map),
                .headers = headers,
            } };
        },
    }
    return out;
}

/// POSIX reads the raw environ block via `std.mem.span` (null-safe in
/// multi-threaded contexts); Windows uses the global block. Mirrors the
/// established pattern in `tools/bash.zig:currentEnvMap`.
fn loadEnvMap(gpa: std.mem.Allocator) !std.process.Environ.Map {
    return platform.getEnvMap(gpa);
}

/// Expand `{env:VAR}` placeholders in `input`, looking each name up in
/// `env_map`. Returns a newly-allocated string (caller frees). A placeholder
/// whose variable is unset is replaced with an empty string and a warning is
/// logged, so a missing secret surfaces instead of silently producing a
/// broken URL. Mirrors the `{env:VAR}` convention used by other MCP clients
/// so existing server snippets work unchanged.
fn expandEnvVars(gpa: std.mem.Allocator, input: []const u8, env_map: *const std.process.Environ.Map) ![]u8 {
    // Fast path: no placeholder — dupe as-is.
    if (std.mem.indexOf(u8, input, "{env:") == null) return try gpa.dupe(u8, input);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var rest = input;
    while (std.mem.indexOf(u8, rest, "{env:")) |start| {
        try out.writer.writeAll(rest[0..start]);
        const name_begin = start + "{env:".len;
        const close_rel = std.mem.indexOfScalar(u8, rest[name_begin..], '}') orelse {
            // Unterminated placeholder — emit the remainder verbatim and stop.
            try out.writer.writeAll(rest[start..]);
            rest = "";
            break;
        };
        const name = rest[name_begin .. name_begin + close_rel];
        if (env_map.get(name)) |value| {
            try out.writer.writeAll(value);
        } else {
            log.warn("config: environment variable '{s}' is not set; substituting empty string. Export it or remove the placeholder.", .{name});
        }
        rest = rest[name_begin + close_rel + 1 ..];
    }
    try out.writer.writeAll(rest);
    return out.toOwnedSlice();
}

/// Expand `{env:VAR}` in one standalone config value (e.g. a provider
/// header value) against the process environment. Caller frees. Used by
/// the runtime at AI-client attach time — the same point in the lifecycle
/// where `expandMcpServer` runs for MCP connects.
pub fn expandEnvValue(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    var env_map = try loadEnvMap(gpa);
    defer env_map.deinit();
    return expandEnvVars(gpa, input, &env_map);
}

test "expandEnvVars leaves input without placeholders unchanged" {
    const gpa = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(gpa);
    defer env_map.deinit();

    const out = try expandEnvVars(gpa, "https://example.com/mcp", &env_map);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("https://example.com/mcp", out);
}

test "expandEnvVars substitutes a known variable" {
    const gpa = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(gpa);
    defer env_map.deinit();
    try env_map.put("TAVILY_API_KEY", "secret123");

    const out = try expandEnvVars(gpa, "https://mcp.tavily.com/mcp/?tavilyApiKey={env:TAVILY_API_KEY}", &env_map);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("https://mcp.tavily.com/mcp/?tavilyApiKey=secret123", out);
}

test "expandEnvVars substitutes multiple variables with surrounding text" {
    const gpa = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(gpa);
    defer env_map.deinit();
    try env_map.put("HOST", "example.com");
    try env_map.put("TOKEN", "abc");

    const out = try expandEnvVars(gpa, "https://{env:HOST}/mcp?token={env:TOKEN}&x=1", &env_map);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("https://example.com/mcp?token=abc&x=1", out);
}

test "expandEnvVars replaces an unset variable with an empty string" {
    const gpa = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(gpa);
    defer env_map.deinit();

    const out = try expandEnvVars(gpa, "https://x.com/?key={env:NOVA_TEST_UNSET_VAR}", &env_map);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("https://x.com/?key=", out);
}

test "expandEnvVars emits an unterminated placeholder verbatim" {
    const gpa = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(gpa);
    defer env_map.deinit();
    try env_map.put("FOO", "bar");

    const out = try expandEnvVars(gpa, "https://x.com/?key={env:FOO", &env_map);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("https://x.com/?key={env:FOO", out);
}
