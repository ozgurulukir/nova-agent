const std = @import("std");
const log = std.log.scoped(.ai);

const ai = @import("../ai.zig");
const core = @import("responses_core.zig");
const http = @import("../http.zig");
const websocket = @import("websocket");
const tools_mod = @import("../tools.zig");
const tools_common = @import("../tools/common.zig");

/// `pub` so `runtime.zig`'s codex client attachments reference the one
/// endpoint instead of re-typing it.
pub const default_codex_endpoint = "https://chatgpt.com/backend-api";
/// Client name sent as the HTTP `User-Agent` (`codex_responses_config`) and
/// the websocket handshake headers. The `originator` header below carries the
/// same name as a separate literal — change them together.
const codex_user_agent = "nova";

/// Upstream Codex CLI identifies itself with a `version` request/handshake
/// header alongside `originator`; send ours too so a future server-side
/// enforcement of that field cannot 403 the whole transport.
const codex_version = @import("build").version;
const websocket_idle_timeout_seconds: u32 = 90;
const websocket_handshake_timeout_ms: u32 = 10_000;
const websocket_message_bytes_max: usize = 8 * 1024 * 1024;
const websocket_buffer_bytes: usize = 16 * 1024;
const websocket_watchdog_poll_ms: u32 = 250;

const codex_responses_config: core.ResponsesConfig = .{
    .base_url_mode = .raw,
    .endpoint_path = "/codex/responses",
    .headers = &.{
        .{ .name = "accept", .value = .{ .literal = http.media_type_event_stream } },
        .{ .name = "chatgpt-account-id", .value = .account_id },
        .{ .name = "originator", .value = .{ .literal = "nova" } },
        .{ .name = "version", .value = .{ .literal = codex_version } },
        .{ .name = "OpenAI-Beta", .value = .{ .literal = "responses=experimental" } },
        .{ .name = "session_id", .value = .session_id },
        .{ .name = "x-client-request-id", .value = .session_id },
    },
    .user_agent = codex_user_agent,
    .text_verbosity = "low",
    .parallel_tool_calls = true,
    .log_name = "codex",
};

fn codexBaseUrl(base_url: []const u8) []const u8 {
    if (base_url.len == 0) return default_codex_endpoint;
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (std.mem.endsWith(u8, trimmed, "/codex/responses")) return trimmed[0 .. trimmed.len - "/codex/responses".len];
    if (std.mem.endsWith(u8, trimmed, "/codex")) return trimmed[0 .. trimmed.len - "/codex".len];
    return trimmed;
}

pub const Client = struct {
    core_client: core.Client,

    pub fn init(target: *Client, gpa: std.mem.Allocator, io: std.Io, config: ai.Config) !void {
        std.debug.assert(config.account_id.len > 0);
        std.debug.assert(config.session_id.len > 0);
        std.debug.assert(config.system_prompt.len > 0);
        var codex_config = config;
        codex_config.base_url = codexBaseUrl(config.base_url);
        try target.core_client.init(gpa, io, codex_config, codex_responses_config);
    }

    pub fn deinit(self: *Client) void {
        self.core_client.deinit();
        self.* = undefined;
    }

    /// Rebuild the serialized tool definitions after the MCP tool set changes.
    pub fn updateMcpTools(
        self: *Client,
        mcp_tools: []const ai.McpToolSchema,
        registry: ?*tools_mod.ToolRegistry,
        builtin_override: []const tools_common.Tool,
    ) !void {
        try self.core_client.updateMcpTools(mcp_tools, registry, builtin_override);
    }

    pub fn prompt(self: *Client, messages: []const ai.MessageView, observer: anytype) !ai.Turn {
        var bridge: ObserverBridge(@TypeOf(observer)) = .{ .observer = observer };
        return self.promptWebSocket(messages, bridge.streamObserver()) catch |err| {
            log.warn("codex.websocket.failure emitted={} error={s}", .{ bridge.emitted, @errorName(err) });
            if (bridge.emitted) return err;
            return self.core_client.prompt(messages, observer);
        };
    }

    fn promptWebSocket(self: *Client, messages: []const ai.MessageView, observer: anytype) !ai.Turn {
        const gpa = self.core_client.gpa;
        const endpoint = try parseWebSocketEndpoint(gpa, self.core_client.url);
        defer endpoint.deinit(gpa);

        var client = try websocket.Client.init(self.core_client.io, gpa, .{
            .host = endpoint.host,
            .port = endpoint.port,
            .tls = endpoint.tls,
            .max_size = websocket_message_bytes_max,
            .buffer_size = websocket_buffer_bytes,
        });
        defer client.deinit();
        defer client.close(.{}) catch {};

        var watchdog: WebSocketWatchdog = undefined;
        try watchdog.start(self.core_client.io, client.stream.stream.socket.handle);
        defer watchdog.stop();

        const headers = try buildHandshakeHeaders(gpa, endpoint.host_header, self.core_client.authorization, self.core_client.config);
        defer gpa.free(headers);

        log.info("codex.websocket.request GET {s} session_id={s}", .{ self.core_client.url, self.core_client.config.session_id });
        watchdog.armMs(websocket_handshake_timeout_ms);
        client.handshake(endpoint.path, .{
            .timeout_ms = websocket_handshake_timeout_ms,
            .headers = headers,
        }) catch |err| return watchdog.timeoutError(err);
        watchdog.armSeconds(websocket_idle_timeout_seconds);
        log.info("codex.websocket.timeout.read_idle_seconds={d}", .{websocket_idle_timeout_seconds});

        var body: std.Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        try body.writer.writeAll("{\"type\":\"response.create\",");
        var payload: std.Io.Writer.Allocating = .init(gpa);
        defer payload.deinit();
        try core.writeRequestPayload(&payload.writer, self.core_client.config, self.core_client.responses_config, messages, self.core_client.tools_json);
        try body.writer.writeAll(payload.written()[1..]);
        log.info("codex.websocket.request.body {s}", .{http.logBytesHead(body.written())});
        try client.writeText(body.written());

        var state: core.StreamState = .{};
        defer state.deinit(gpa);
        errdefer state.deinitBlocks(gpa);
        var event_count: u32 = 0;
        while (event_count < 100_000) : (event_count += 1) {
            const message = (client.read() catch |err| return watchdog.timeoutError(err)) orelse return error.WebSocketReadTimeout;
            defer client.done(message);
            watchdog.armSeconds(websocket_idle_timeout_seconds);
            switch (message.type) {
                .text => {
                    log.info("codex.websocket.response.frame {s}", .{http.logBytesHead(message.data)});
                    try state.processJson(gpa, message.data, observer, &self.core_client.call_seq);
                },
                .binary => return error.UnsupportedWebSocketFrame,
                .close => return error.WebSocketClosed,
                .ping => try client.writePong(message.data),
                .pong => {},
            }
            if (state.completed) break;
        }
        return try state.finish(gpa, &self.core_client.call_seq);
    }
};

const WebSocketWatchdog = struct {
    fd: std.posix.socket_t,
    io: std.Io,
    deadline_ns: std.atomic.Value(i64),
    timed_out: std.atomic.Value(bool),
    future: ?std.Io.Future(void),

    fn start(self: *WebSocketWatchdog, io: std.Io, fd: std.posix.socket_t) !void {
        self.* = .{
            .fd = fd,
            .io = io,
            .deadline_ns = .init(0),
            .timed_out = .init(false),
            .future = null,
        };
        self.future = try io.concurrent(run, .{self});
    }

    fn stop(self: *WebSocketWatchdog) void {
        if (self.future) |*future| {
            _ = future.cancel(self.io);
            self.future = null;
        }
    }

    fn nowNs(self: *WebSocketWatchdog) i64 {
        const ts = std.Io.Clock.Timestamp.now(self.io, .awake);
        return @intCast(ts.raw.nanoseconds);
    }

    fn armMs(self: *WebSocketWatchdog, timeout_ms: u32) void {
        std.debug.assert(timeout_ms > 0);
        const timeout_ns: i64 = @as(i64, timeout_ms) * std.time.ns_per_ms;
        self.deadline_ns.store(self.nowNs() + timeout_ns, .release);
        self.timed_out.store(false, .release);
    }

    fn armSeconds(self: *WebSocketWatchdog, timeout_seconds: u32) void {
        std.debug.assert(timeout_seconds > 0);
        const timeout_ns: i64 = @as(i64, timeout_seconds) * std.time.ns_per_s;
        self.deadline_ns.store(self.nowNs() + timeout_ns, .release);
        self.timed_out.store(false, .release);
    }

    fn timeoutError(self: *WebSocketWatchdog, err: anyerror) anyerror {
        if (self.timed_out.load(.acquire)) return error.WebSocketReadTimeout;
        return err;
    }

    fn run(self: *WebSocketWatchdog) void {
        while (true) {
            const deadline_ns = self.deadline_ns.load(.acquire);
            const remaining_ns: i64 = blk: {
                if (deadline_ns == 0) break :blk websocket_watchdog_poll_ms * std.time.ns_per_ms;
                const now_ns = self.nowNs();
                if (now_ns >= deadline_ns) {
                    self.timed_out.store(true, .release);
                    self.shutdown();
                    return;
                }
                break :blk deadline_ns - now_ns;
            };
            self.io.sleep(std.Io.Duration.fromNanoseconds(remaining_ns), .awake) catch return;
        }
    }

    fn shutdown(self: *WebSocketWatchdog) void {
        const rc = std.c.shutdown(self.fd, std.c.SHUT.RDWR);
        _ = rc;
    }
};

const WebSocketEndpoint = struct {
    host: []u8,
    host_header: []u8,
    path: []u8,
    port: u16,
    tls: bool,

    fn deinit(self: *const WebSocketEndpoint, gpa: std.mem.Allocator) void {
        gpa.free(self.host);
        gpa.free(self.host_header);
        gpa.free(self.path);
    }
};

fn ObserverBridge(comptime T: type) type {
    return struct {
        observer: T,
        emitted: bool = false,

        fn streamObserver(self: *@This()) ai.StreamObserver(@This()) {
            return .{
                .ctx = self,
                .on_content = onContent,
                .on_reasoning = onReasoning,
                .on_tool_delta = onToolDelta,
                .on_delta_end = onDeltaEnd,
            };
        }

        fn onContent(ctx: *@This(), delta: []const u8) anyerror!void {
            ctx.emitted = true;
            try ctx.observer.on_content(ctx.observer.ctx, delta);
        }

        fn onReasoning(ctx: *@This(), delta: []const u8) anyerror!void {
            ctx.emitted = true;
            try ctx.observer.on_reasoning(ctx.observer.ctx, delta);
        }

        fn onToolDelta(ctx: *@This(), delta: ai.ToolDelta) anyerror!void {
            ctx.emitted = true;
            try ctx.observer.on_tool_delta(ctx.observer.ctx, delta);
        }

        fn onDeltaEnd(ctx: *@This()) anyerror!void {
            ctx.emitted = true;
            try ctx.observer.on_delta_end(ctx.observer.ctx);
        }
    };
}

fn parseWebSocketEndpoint(gpa: std.mem.Allocator, url: []const u8) !WebSocketEndpoint {
    const uri = try std.Uri.parse(url);
    const tls = if (std.mem.eql(u8, uri.scheme, "https") or std.mem.eql(u8, uri.scheme, "wss"))
        true
    else if (std.mem.eql(u8, uri.scheme, "http") or std.mem.eql(u8, uri.scheme, "ws"))
        false
    else
        return error.UnsupportedWebSocketScheme;
    const port = uri.port orelse if (tls) @as(u16, 443) else @as(u16, 80);
    const host = try uriHost(gpa, uri);
    errdefer gpa.free(host);
    const host_header = try hostHeader(gpa, host, port, tls);
    errdefer gpa.free(host_header);
    const path = try uriPathAndQuery(gpa, uri);
    errdefer gpa.free(path);
    return .{
        .host = host,
        .host_header = host_header,
        .path = path,
        .port = port,
        .tls = tls,
    };
}

fn uriHost(gpa: std.mem.Allocator, uri: std.Uri) ![]u8 {
    const host_component = uri.host orelse return error.UriMissingHost;
    return try componentAlloc(gpa, host_component);
}

fn uriPathAndQuery(gpa: std.mem.Allocator, uri: std.Uri) ![]u8 {
    const path = try componentAlloc(gpa, uri.path);
    defer gpa.free(path);
    const query_component = uri.query orelse return try gpa.dupe(u8, path);
    const query = try componentAlloc(gpa, query_component);
    defer gpa.free(query);
    return try std.fmt.allocPrint(gpa, "{s}?{s}", .{ path, query });
}

fn componentAlloc(gpa: std.mem.Allocator, component: std.Uri.Component) ![]u8 {
    return switch (component) {
        .raw => |raw| try gpa.dupe(u8, raw),
        .percent_encoded => |encoded| try gpa.dupe(u8, encoded),
    };
}

fn hostHeader(gpa: std.mem.Allocator, host: []const u8, port: u16, tls: bool) ![]u8 {
    const default_port: u16 = if (tls) 443 else 80;
    if (port == default_port) return try gpa.dupe(u8, host);
    return try std.fmt.allocPrint(gpa, "{s}:{d}", .{ host, port });
}

fn buildHandshakeHeaders(
    gpa: std.mem.Allocator,
    host_header: []const u8,
    authorization: []const u8,
    config: ai.Config,
) ![]u8 {
    return try std.fmt.allocPrint(
        gpa,
        "Host: {s}\r\nAuthorization: {s}\r\nUser-Agent: " ++ codex_user_agent ++ "\r\nchatgpt-account-id: {s}\r\noriginator: nova\r\nversion: " ++ codex_version ++ "\r\nOpenAI-Beta: responses_websockets=2026-02-06\r\nsession_id: {s}\r\nx-client-request-id: {s}\r\n",
        .{
            host_header,
            authorization,
            config.account_id,
            config.session_id,
            config.session_id,
        },
    );
}

test "codex websocket endpoint parses https url" {
    const gpa = std.testing.allocator;
    const endpoint = try parseWebSocketEndpoint(gpa, "https://chatgpt.com/backend-api/codex/responses?x=1");
    defer endpoint.deinit(gpa);
    try std.testing.expectEqualStrings("chatgpt.com", endpoint.host);
    try std.testing.expectEqualStrings("chatgpt.com", endpoint.host_header);
    try std.testing.expectEqualStrings("/backend-api/codex/responses?x=1", endpoint.path);
    try std.testing.expectEqual(@as(u16, 443), endpoint.port);
    try std.testing.expect(endpoint.tls);
}

test "codex websocket endpoint includes non-default port in host header" {
    const gpa = std.testing.allocator;
    const endpoint = try parseWebSocketEndpoint(gpa, "ws://localhost:9224/ws");
    defer endpoint.deinit(gpa);
    try std.testing.expectEqualStrings("localhost:9224", endpoint.host_header);
    try std.testing.expectEqual(@as(u16, 9224), endpoint.port);
    try std.testing.expect(!endpoint.tls);
}

test "codex version header present on websocket handshake and sse request headers" {
    const gpa = std.testing.allocator;
    var client: Client = undefined;
    try client.init(gpa, std.testing.io, .{
        .base_url = ai.codex_responses.default_codex_endpoint,
        .account_id = "acc",
        .session_id = "sess",
        .api_key = "tok",
        .model = "gpt-5.2",
        // system_prompt is asserted non-empty in init; account/session too.
        .system_prompt = "sp",
    });
    defer client.core_client.deinit();

    // WebSocket handshake carries the version header (upstream CLI parity).
    const headers = try buildHandshakeHeaders(gpa, "chatgpt.com:443", "Bearer tok", client.core_client.config);
    defer gpa.free(headers);
    try std.testing.expect(std.mem.indexOf(u8, headers, "\r\nversion: " ++ codex_version ++ "\r\n") != null);

    // HTTP/SSE request headers carry exactly one version entry with the same
    // value, and the array stays within extraHeaders' fixed buffer bound.
    var found: usize = 0;
    for (codex_responses_config.headers) |h| {
        if (std.mem.eql(u8, h.name, "version")) {
            found += 1;
            try std.testing.expectEqualStrings(codex_version, h.value.literal);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), found);
    try std.testing.expect(codex_responses_config.headers.len <= 8);
}

test {
    std.testing.refAllDecls(@This());
}
