//! Client implementation for the OpenAI Responses API.
//!
//! Subsystem modularization: request serialization lives in `responses_request.zig`
//! and SSE event decoding lives in `responses_events.zig`.

const std = @import("std");
const log = std.log.scoped(.ai);

const ai = @import("../ai.zig");
const http = @import("../http.zig");
const openai_endpoint = @import("openai_endpoint.zig");
const openai_compatible = @import("openai_compatible.zig");
const provider_headers = @import("provider_headers.zig");
const stream_part = @import("stream_part.zig");
const tool_schema = @import("tool_schema.zig");
const tools_common = @import("../tools/common.zig");
const tools_mod = @import("../tools.zig");

pub const responses_request = @import("responses_request.zig");
pub const responses_events = @import("responses_events.zig");

// Re-exports for backwards compatibility
pub const writeRequestPayload = responses_request.writeRequestPayload;
pub const StreamState = responses_events.StreamState;
pub const ToolBuilder = responses_events.ToolBuilder;
pub const processEvent = responses_events.processEvent;
pub const parseResponseUsage = responses_events.parseResponseUsage;
pub const ResponseEvent = responses_events.ResponseEvent;
pub const ResponseEventSpec = responses_events.ResponseEventSpec;
pub const response_event_specs = responses_events.response_event_specs;
pub const responseEventFromString = responses_events.responseEventFromString;

const redirect_buffer_bytes = http.redirect_buffer_bytes;
const transfer_buffer_bytes = http.transfer_buffer_bytes;
const body_buffer_bytes = http.body_buffer_bytes;
/// Upper bound on an error body we will decompress + log (matches the
/// chat-completions client's cap). Prevents a hostile/garbage body from
/// allocating unboundedly.
const response_bytes_max: u32 = 1 * 1024 * 1024;

pub const ResponsesConfig = struct {
    // Transport-protocol header specs, unified with the provider-header
    // vocabulary in `provider_headers.zig` (INV-RESP-1 sibling leaf).
    pub const HeaderValue = provider_headers.HeaderValue;
    pub const Header = provider_headers.Header;

    pub const BaseUrlMode = enum { openai_v1, raw };

    base_url_mode: BaseUrlMode = .openai_v1,
    endpoint_path: []const u8 = "/responses",
    /// Static profile table (codex handshake set); borrowed for the
    /// client's lifetime, so it must reference permanent storage — the
    /// owned, dynamic channel is `Client.provider_headers_owned`.
    headers: []const Header = &.{},
    user_agent: ?[]const u8 = null,
    text_verbosity: ?[]const u8 = null,
    parallel_tool_calls: ?bool = null,
    /// Request `reasoning.encrypted_content` in the include array. Keep true
    /// for the plain Responses API (stateless replay needs the blob). The
    /// ChatGPT Codex backend rejects replayed encrypted reasoning items with
    /// a confusing 400 ("expected an object, but got an integer"), and
    /// upstream clients never re-send them (openai/codex#25290, pi#6023) —
    /// so this transport opts out and relies on summaries only.
    include_encrypted_reasoning: bool = true,
    /// Remove encrypted reasoning from replayed history before serialization.
    /// This is transport-specific and therefore independent of whether the
    /// current request asks the server to include encrypted reasoning.
    scrub_encrypted_reasoning: bool = false,
    log_name: []const u8 = "standard",
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    config: ai.Config,
    url: []u8,
    authorization: []u8,
    tools_json: []u8,
    /// Whether tool definitions carry OpenAI strict structured-outputs mode.
    /// Captured at `init` so `updateMcpTools` can rebuild `tools_json`
    /// consistently. Default `false` — strict mode is OpenAI-only and breaks
    /// function-calling on gateways (OpenRouter/Ollama/vLLM).
    strict: bool = false,
    responses_config: ResponsesConfig,
    /// Owned copy of `ai.Config.headers` (auto provider headers merged with
    /// the user's, precedence already resolved at attach time). Materialized
    /// per request by `extraHeaders` alongside the static profile table.
    provider_headers_owned: []provider_headers.Header = &.{},
    http_client: std.http.Client,
    call_seq: u64 = 0,
    last_error_detail: ?[]u8 = null,

    pub fn init(target: *Client, gpa: std.mem.Allocator, io: std.Io, config: ai.Config, responses_config: ResponsesConfig) !void {
        if (config.base_url.len == 0) return error.EmptyBaseUrl;
        if (config.model.len == 0) return error.EmptyModelId;
        const url = try responsesUrl(gpa, config.base_url, responses_config);
        errdefer gpa.free(url);
        const authorization = try std.fmt.allocPrint(gpa, "{s}{s}", .{ http.bearer_prefix, config.api_key });
        errdefer gpa.free(authorization);
        var owned_config = config;
        owned_config.base_url = "";
        owned_config.api_key = "";
        // Borrowed at init; the deep copy lives in provider_headers_owned.
        // Blank it like base_url/api_key so no future read dangles after the
        // attach frame (which owns the specs) returns.
        owned_config.headers = &.{};
        owned_config.model = try gpa.dupe(u8, config.model);
        errdefer gpa.free(owned_config.model);
        owned_config.account_id = try gpa.dupe(u8, config.account_id);
        errdefer gpa.free(owned_config.account_id);
        owned_config.session_id = try gpa.dupe(u8, config.session_id);
        errdefer gpa.free(owned_config.session_id);
        owned_config.system_prompt = try gpa.dupe(u8, config.system_prompt);
        errdefer gpa.free(owned_config.system_prompt);
        const tools_json = try tool_schema.buildAllToolsJson(gpa, config.tools, config.mcp_tools, null, config.strict, .responses);
        errdefer gpa.free(tools_json);
        const provider_headers_owned = try provider_headers.cloneHeaders(gpa, config.headers);
        errdefer provider_headers.freeHeaders(gpa, provider_headers_owned);
        target.* = .{
            .gpa = gpa,
            .io = io,
            .config = owned_config,
            .url = url,
            .authorization = authorization,
            .tools_json = tools_json,
            .strict = config.strict,
            .responses_config = responses_config,
            .provider_headers_owned = provider_headers_owned,
            .http_client = .{ .allocator = gpa, .io = io },
        };
    }

    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
        self.gpa.free(self.config.model);
        self.gpa.free(self.config.account_id);
        self.gpa.free(self.config.session_id);
        self.gpa.free(self.config.system_prompt);
        self.gpa.free(self.tools_json);
        self.gpa.free(self.authorization);
        self.gpa.free(self.url);
        provider_headers.freeHeaders(self.gpa, self.provider_headers_owned);
        if (self.last_error_detail) |d| self.gpa.free(d);
        self.* = undefined;
    }

    /// Rebuild the serialized tool definitions after the MCP tool set changes.
    /// `mcp_tools` is borrowed only for the duration of the call; the result is
    /// the owned `tools_json`. Call between turns, never mid-turn.
    /// `registry`, when non-null, contributes its builtin + plugin tools so
    /// the model sees them as first-class definitions. When null, only the
    /// builtin slice (`config.tools`) is used — the legacy path used by
    /// tests that don't construct a full registry.
    ///
    /// The caller is responsible for choosing what `self.config.tools`
    /// contains at call time. `attachXxxClient` initializes it with
    /// `builtinRegistry()` so bash is present; the tick-driven
    /// `injectAllTools` path passes an empty slice because the registry's
    /// `builtin` already covers the same tool — passing both would emit
    /// duplicate definitions and most OpenAI-compatible APIs reject
    /// duplicate tool names outright (HTTP 400), dropping the entire
    /// tool list including the plugin tools the caller wants exposed.
    pub fn updateMcpTools(
        self: *Client,
        mcp_tools: []const ai.McpToolSchema,
        registry: ?*tools_mod.ToolRegistry,
        builtin_override: []const tools_common.Tool,
    ) !void {
        const new_json = try tool_schema.buildAllToolsJson(self.gpa, builtin_override, mcp_tools, registry, self.strict, .responses);
        self.gpa.free(self.tools_json);
        self.tools_json = new_json;
    }

    fn clearErrorDetail(self: *Client) void {
        if (self.last_error_detail) |d| self.gpa.free(d);
        self.last_error_detail = null;
    }

    fn recordReadFailure(self: *Client, read_err: anyerror) void {
        const detail = std.fmt.allocPrint(
            self.gpa,
            "Connection to the model provider was lost: {s}",
            .{@errorName(read_err)},
        ) catch return;
        self.clearErrorDetail();
        self.last_error_detail = detail;
    }

    fn headPhaseFailure(self: *Client, err: anyerror) anyerror {
        _ = self;
        return http.headPhaseFailure(err);
    }

    /// Record `HTTP <status>: <message>` from a failed response body for the
    /// UI. Best-effort: a failure to build the string just leaves the detail
    /// unset.
    fn recordErrorDetail(self: *Client, status_code: u16, body: []const u8) void {
        const message = http.extractErrorMessage(self.gpa, body) catch return;
        defer self.gpa.free(message);
        log.warn("responses.recordErrorDetail status={d} body={s}", .{ status_code, message });
        const detail = std.fmt.allocPrint(self.gpa, "HTTP {d}: {s}", .{ status_code, message }) catch return;
        self.clearErrorDetail();
        self.last_error_detail = detail;
    }

    pub fn prompt(self: *Client, messages: []const ai.MessageView, observer: anytype) !ai.Turn {
        self.clearErrorDetail();

        // The payload is serialized ONCE; every retry attempt re-sends the
        // same bytes. Retries happen only on head-phase 429/5xx and on
        // connection drops before any response bytes — the model has not
        // produced anything and no tool has run, so the request is
        // idempotent. Stream-mid errors are never retried (partial deltas may
        // already be visible to the observer).
        var payload: std.Io.Writer.Allocating = .init(self.gpa);
        defer payload.deinit();
        try writeRequestPayload(&payload.writer, self.gpa, self.config, self.responses_config, messages, self.tools_json);
        log.info("responses.request POST {s} profile={s} body={s}", .{ self.url, self.responses_config.log_name, http.logBytesHead(payload.written()) });

        var attempt: u32 = 0;
        while (attempt <= self.config.max_retries) : (attempt += 1) {
            var retry_after_secs: ?u64 = null;
            const turn = self.sendOnce(payload.written(), observer, &retry_after_secs) catch |err| {
                if (attempt >= self.config.max_retries) return err;
                switch (err) {
                    error.HttpServerError, error.HttpRateLimited, error.ConnectionFailed => {},
                    else => return err,
                }
                const delay_ms = http.retryDelayMs(self.config.retry_base_delay_ms, attempt, retry_after_secs);
                log.warn("responses.retry attempt={d} err={s} delay_ms={d}", .{ attempt + 1, @errorName(err), delay_ms });
                self.sleepMs(delay_ms);
                continue;
            };
            return turn;
        }
        unreachable;
    }

    /// Perform one HTTP round-trip with the already-serialized payload.
    /// Transient head-phase statuses (429, 5xx) and pre-response connection
    /// drops surface as `error.HttpRateLimited` / `error.HttpServerError` /
    /// `error.ConnectionFailed` so `prompt` can decide whether to retry;
    /// every other failure propagates unchanged. When a retryable status is
    /// hit, `retry_after_secs` receives the server's `Retry-After` value
    /// (integer seconds) if one was sent.
    fn sendOnce(self: *Client, payload: []const u8, observer: anytype, retry_after_secs: *?u64) !ai.Turn {
        var extra_headers_buffer: [provider_headers.max_outbound_headers]std.http.Header = undefined;
        const extra_headers = self.extraHeaders(&extra_headers_buffer);
        var req = self.http_client.request(.POST, try std.Uri.parse(self.url), .{
            .headers = .{
                .authorization = .{ .override = self.authorization },
                .content_type = .{ .override = http.content_type_json },
                .user_agent = if (self.responses_config.user_agent) |value| .{ .override = value } else .default,
            },
            .extra_headers = extra_headers,
        }) catch |err| return self.headPhaseFailure(err);
        defer req.deinit();

        req.transfer_encoding = .chunked;
        var body_buffer: [body_buffer_bytes]u8 = undefined;
        var body_writer = req.sendBodyUnflushed(&body_buffer) catch |err| return self.headPhaseFailure(err);
        body_writer.writer.writeAll(payload) catch |err| return self.headPhaseFailure(err);
        body_writer.end() catch |err| return self.headPhaseFailure(err);
        req.connection.?.flush() catch |err| return self.headPhaseFailure(err);

        var redirect_buffer: [redirect_buffer_bytes]u8 = undefined;
        var http_response = req.receiveHead(&redirect_buffer) catch |err| {
            // `receiveHead` fails with `error.ReadFailed`/`error.WriteFailed`
            // when the connection drops; capture the underlying socket error
            // so the UI shows what actually went wrong instead of the opaque
            // error name. Read the stream error fields directly —
            // `Connection.getReadError` unwraps `.?` internally and panics
            // when std synthesized the ReadFailed without a socket error.
            if (err == error.ReadFailed or err == error.WriteFailed or err == error.HttpRequestTruncated) {
                if (req.connection) |conn| {
                    const reason: anyerror = if (conn.stream_reader.err) |e| e else if (conn.stream_writer.err) |e| e else err;
                    self.recordReadFailure(reason);
                }
            }
            return self.headPhaseFailure(err);
        };
        const status_code: u16 = @intFromEnum(http_response.head.status);
        log.info("responses.response.head status={d} profile={s}", .{ status_code, self.responses_config.log_name });
        if (status_code >= 400) {
            // Read `Retry-After` before initializing the body reader — the
            // head pointers are invalidated once the body stream starts.
            if (http.isRetryableHeadStatus(status_code)) {
                retry_after_secs.* = http.parseRetryAfterSeconds(http_response.head.bytes);
            }
            // The error body may be gzip/deflate-compressed (the encodings
            // this client advertises) — use the decompressing reader so the
            // toaster logs real text instead of raw compressed bytes.
            var error_buffer: [transfer_buffer_bytes]u8 = undefined;
            var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
            var decompress: std.http.Decompress = undefined;
            const error_reader = http_response.readerDecompressing(&error_buffer, &decompress, &decompress_buffer);
            const error_body = error_reader.allocRemaining(self.gpa, .limited(response_bytes_max)) catch |err| switch (err) {
                error.StreamTooLong => return error.ResponseTooLarge,
                else => |e| return e,
            };
            defer self.gpa.free(error_body);
            log.warn("responses.response.error status={d} body={s}", .{ status_code, http.logBytesHead(error_body) });
            self.recordErrorDetail(status_code, error_body);
            if (status_code == 429) return error.HttpRateLimited;
            if (status_code >= 500) return error.HttpServerError;
            return error.HttpClientError;
        }
        if (!http.isSuccess(status_code)) return error.HttpUnexpectedStatus;

        // Socket-level read timeout: prevents indefinite hangs when the
        // server stops mid-stream. Applied after the head is received so the
        // (fast) head exchange is not affected.
        if (req.connection) |conn| http.setSocketTimeout(conn, self.config.request_timeout_seconds);

        var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
        const reader = http_response.reader(&transfer_buffer);
        return readStream(self.gpa, reader, observer, &self.call_seq) catch |err| {
            if (err == error.ReadFailed) {
                if (req.connection) |conn| {
                    // Prefer the socket error; std also synthesizes
                    // `error.ReadFailed` for a truncated or invalid chunked
                    // body (recorded as `body_err`), and
                    // `Connection.getReadError` would panic on `.?` there —
                    // see the head-phase note above.
                    const reason: anyerror = if (conn.stream_reader.err) |e| e else if (http_response.bodyErr()) |e| e else err;
                    self.recordReadFailure(reason);
                }
            }
            return err;
        };
    }

    /// Block the worker for the backoff delay. Best-effort — a cancel error
    /// just falls through (the turn is being torn down anyway).
    fn sleepMs(self: *const Client, ms: u64) void {
        if (ms == 0) return;
        const clamped: i64 = @intCast(@min(ms, std.math.maxInt(i64)));
        self.io.sleep(std.Io.Duration.fromMilliseconds(clamped), .awake) catch {};
    }

    fn extraHeaders(self: *const Client, buffer: []std.http.Header) []const std.http.Header {
        var set = provider_headers.HeaderSet.init(buffer);
        // Transport-protocol profile headers (codex handshake set) first,
        // then the provider header set (user + auto, precedence resolved at
        // attach). Profile headers win on name collision: `accept` and
        // `OpenAI-Beta` are functional for the SSE transport, not styling.
        const context = provider_headers.ValueContext{
            .session_id = self.config.session_id,
            .account_id = self.config.account_id,
        };
        set.append(self.responses_config.headers, context);
        set.append(self.provider_headers_owned, context);
        return set.slice();
    }
};

fn responsesUrl(gpa: std.mem.Allocator, base_url: []const u8, responses_config: ResponsesConfig) ![]u8 {
    const base = std.mem.trimEnd(u8, base_url, "/");
    const root = switch (responses_config.base_url_mode) {
        .raw => try gpa.dupe(u8, base),
        .openai_v1 => try openai_endpoint.v1Root(gpa, base),
    };
    defer gpa.free(root);
    return try std.fmt.allocPrint(gpa, "{s}{s}", .{ root, responses_config.endpoint_path });
}

fn readStream(gpa: std.mem.Allocator, reader: *std.Io.Reader, observer: anytype, call_seq: *u64) !ai.Turn {
    var state: StreamState = .{};
    defer state.deinit(gpa);
    errdefer state.deinitBlocks(gpa);
    var source: stream_part.Source = .{ .reader = reader };
    while (try source.next(gpa)) |data| {
        defer gpa.free(data);
        log.info("responses.response.sse data={s}", .{http.logBytesHead(data)});
        try state.processJson(gpa, data, observer, call_seq);
    }
    return try state.finish(gpa, call_seq);
}

test "headPhaseFailure maps transient connection drops to a retryable error" {
    var client: Client = undefined;
    try Client.init(&client, std.testing.allocator, std.testing.io, .{
        .base_url = "http://127.0.0.1:1",
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
        .session_id = "test",
        .system_prompt = "",
    }, .{});
    defer client.deinit();

    try std.testing.expectEqual(error.ConnectionFailed, client.headPhaseFailure(error.ReadFailed));
    try std.testing.expectEqual(error.ConnectionFailed, client.headPhaseFailure(error.WriteFailed));
    try std.testing.expectEqual(error.ConnectionFailed, client.headPhaseFailure(error.EndOfStream));
    try std.testing.expectEqual(error.ConnectionFailed, client.headPhaseFailure(error.ConnectionRefused));
    try std.testing.expectEqual(error.ConnectionFailed, client.headPhaseFailure(error.ConnectionResetByPeer));
    try std.testing.expectEqual(error.ConnectionFailed, client.headPhaseFailure(error.ConnectionTimedOut));
    try std.testing.expectEqual(error.ConnectionFailed, client.headPhaseFailure(error.BrokenPipe));
    try std.testing.expectEqual(error.ConnectionFailed, client.headPhaseFailure(error.HttpConnectionClosing));
    try std.testing.expectEqual(error.ConnectionFailed, client.headPhaseFailure(error.Unexpected));
    // Permanent failures are returned unchanged.
    try std.testing.expectEqual(error.HttpClientError, client.headPhaseFailure(error.HttpClientError));
    try std.testing.expectEqual(error.HttpHeadersInvalid, client.headPhaseFailure(error.HttpHeadersInvalid));
}

/// Drain a full chunked HTTP request (headers + body through the terminal
/// `0\r\n\r\n`) from a mock connection without ever blocking past it: the
/// client sends nothing after the terminator — it blocks reading the
/// response — so a blind extra read would hang the server thread and, with
/// it, the whole test. A complete drain also proves the client finished
/// sending before the mock aborts the connection.
fn drainChunkedRequest(reader: *std.Io.Reader) void {
    var req_buf: [4096]u8 = undefined;
    var req_len: usize = 0;
    while (req_len < req_buf.len) {
        // `readSliceShort` blocks until its destination is FULL — and this
        // request is smaller than any fixed buffer we could pick — so it
        // must never be handed a larger destination here. `fillMore`
        // performs exactly one blocking read, then an exactly-sized
        // `readSliceShort` copies the buffered bytes out without waiting
        // for more.
        reader.fillMore() catch break;
        const take = @min(reader.bufferedLen(), req_buf.len - req_len);
        req_len += reader.readSliceShort(req_buf[req_len..][0..take]) catch break;
        if (std.mem.indexOf(u8, req_buf[0..req_len], "\r\n\r\n") != null and
            std.mem.endsWith(u8, req_buf[0..req_len], "0\r\n\r\n")) break;
    }
}

test "prompt records last_error_detail on head-phase ReadFailed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // A mock server that accepts a connection but closes immediately
    // without sending any HTTP response. receiveHead will see ReadFailed.
    const MockCloseServer = struct {
        srv_io: std.Io,
        server: std.Io.net.Server,

        fn init(srv_io: std.Io) !@This() {
            const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
            const srv = try addr.listen(srv_io, .{ .reuse_address = true });
            return .{ .srv_io = srv_io, .server = srv };
        }

        fn deinit(self: *@This()) void {
            self.server.deinit(self.srv_io);
        }

        fn port(self: *const @This()) u16 {
            return self.server.socket.address.ip4.port;
        }

        fn serve(self: *@This()) void {
            var read_buf: [4096]u8 = undefined;
            var write_buf: [8192]u8 = undefined;
            var stream = self.server.accept(self.srv_io) catch return;
            var reader = stream.reader(self.srv_io, &read_buf);
            // Drain the request so the client can finish sending before the
            // connection closes. This makes the failure occur in
            // `receiveHead`, rather than nondeterministically during upload.
            drainChunkedRequest(&reader.interface);
            // Send an incomplete status line after the upload. This makes the
            // client fail while receiving the response head, rather than
            // racing the request upload against a closed socket.
            var writer = stream.writer(self.srv_io, &write_buf);
            writer.interface.writeAll("HTTP/1.1 200") catch return;
            writer.interface.flush() catch return;
            stream.close(self.srv_io);
        }
    };

    var server = try MockCloseServer.init(io);
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockCloseServer.serve, .{&server});
    defer thread.join();

    // `Client.init` copies what it keeps and clears `base_url` in its owned
    // config — the temporary string stays ours to free.
    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});
    defer gpa.free(base_url);
    var client: Client = undefined;
    // `max_retries = 0`: this test verifies error-detail recording on a head
    // phase drop, not the retry loop. The mock accepts a single connection, so
    // leaving the default budget (2) would make attempt 2 block on a connection
    // the server never accepts.
    try Client.init(&client, gpa, io, .{
        .base_url = base_url,
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
        .session_id = "test",
        .system_prompt = "",
        .max_retries = 0,
    }, .{});
    defer client.deinit();

    try std.testing.expectError(error.ConnectionFailed, client.prompt(&.{}, ai.streamNoop()));
    const detail = client.last_error_detail orelse @panic("expected a recorded error detail on head-phase ReadFailed");
    try std.testing.expect(std.mem.startsWith(u8, detail, "Connection to the model provider was lost:"));
}

test "prompt records last_error_detail on stream-phase ReadFailed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // A mock server that sends a valid HTTP 200 head with SSE content-type,
    // sends partial SSE data, then closes abruptly.
    const MockAbortServer = struct {
        srv_io: std.Io,
        server: std.Io.net.Server,

        fn init(srv_io: std.Io) !@This() {
            const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
            const srv = try addr.listen(srv_io, .{ .reuse_address = true });
            return .{ .srv_io = srv_io, .server = srv };
        }

        fn deinit(self: *@This()) void {
            self.server.deinit(self.srv_io);
        }

        fn port(self: *const @This()) u16 {
            return self.server.socket.address.ip4.port;
        }

        fn serve(self: *@This()) void {
            var read_buf: [4096]u8 = undefined;
            var write_buf: [8192]u8 = undefined;
            var stream = self.server.accept(self.srv_io) catch return;
            defer stream.close(self.srv_io);
            var reader = stream.reader(self.srv_io, &read_buf);
            var writer = stream.writer(self.srv_io, &write_buf);
            // Drain the FULL request (headers + chunked body through the
            // terminal `0\r\n\r\n`); see drainChunkedRequest for why a blind
            // extra read past it would hang the test.
            drainChunkedRequest(&reader.interface);
            // Send a 200 OK response with SSE content-type.
            writer.interface.writeAll("HTTP/1.1 200 OK\r\n" ++
                "Content-Type: text/event-stream\r\n" ++
                "Transfer-Encoding: chunked\r\n" ++
                "\r\n") catch return;
            // Send one chunk of SSE data (Responses API format).
            const chunk = "event: response.output_text.delta\ndata: {\"delta\":\"hi\"}\n\n";
            var hex_buf: [16]u8 = undefined;
            const hex = std.fmt.bufPrint(&hex_buf, "{x}\r\n", .{chunk.len}) catch return;
            writer.interface.writeAll(hex) catch return;
            writer.interface.writeAll(chunk) catch return;
            writer.interface.writeAll("\r\n") catch return;
            // A malformed chunk header breaks the client's chunked decoder
            // mid-body — std maps that to a stream-phase `error.ReadFailed`
            // with `body_err` set. An abortive RST would mimic a real-world
            // drop more closely, but `Io.Threaded` hands out AFD handles on
            // Windows, which `setsockopt`(SO_LINGER) rejects — a
            // protocol-level abort is the portable way to exercise the same
            // client capture path.
            writer.interface.writeAll("ZZ\r\n") catch return;
            writer.interface.flush() catch return;
        }
    };

    var server = try MockAbortServer.init(io);
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockAbortServer.serve, .{&server});
    defer thread.join();

    // `Client.init` copies what it keeps and clears `base_url` in its owned
    // config — the temporary string stays ours to free.
    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});
    defer gpa.free(base_url);
    var client: Client = undefined;
    try Client.init(&client, gpa, io, .{
        .base_url = base_url,
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
        .session_id = "test",
        .system_prompt = "",
    }, .{});
    defer client.deinit();

    try std.testing.expectError(error.ReadFailed, client.prompt(&.{}, ai.streamNoop()));
    const detail = client.last_error_detail orelse @panic("expected a recorded error detail on stream-phase ReadFailed");
    try std.testing.expect(std.mem.startsWith(u8, detail, "Connection to the model provider was lost:"));
}

// A valid, completed Responses-API stream (empty output) the mock serves on
// the final attempt. `response.completed` flips the completed flag so `finish`
// succeeds; no output items are needed for a valid Turn.
const ok_responses_sse_body =
    "event: response.completed\n" ++
    "data: {\"type\":\"response.completed\"}\n\n";

/// Mock that serves one canned response per accepted connection (like the
/// chat-completions client's retry tests). Each connection is `close`d after
/// the response so the client reconnects for the next attempt.
const MockResponsesRetryServer = struct {
    const Response = struct {
        status: std.http.Status,
        retry_after: ?[]const u8 = null,
        body: []const u8 = "",
    };

    io: std.Io,
    server: std.Io.net.Server,
    responses: []const Response,
    connection_count: std.atomic.Value(u32) = .init(0),

    fn init(io: std.Io, responses: []const Response) !@This() {
        const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        const server = try addr.listen(io, .{ .reuse_address = true });
        return .{ .io = io, .server = server, .responses = responses };
    }

    fn deinit(self: *@This()) void {
        self.server.deinit(self.io);
    }

    fn port(self: *const @This()) u16 {
        return self.server.socket.address.ip4.port;
    }

    fn serve(self: *@This()) void {
        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        for (self.responses) |resp| {
            var stream = self.server.accept(self.io) catch return;
            defer stream.close(self.io);
            _ = self.connection_count.fetchAdd(1, .monotonic);
            var reader = stream.reader(self.io, &read_buf);
            var writer = stream.writer(self.io, &write_buf);
            var http_server = std.http.Server.init(&reader.interface, &writer.interface);
            // `request.respond` drains the (chunked) request body internally —
            // the client blocks reading the response after sending, so nothing
            // follows the terminal `0\r\n\r\n`.
            var request = http_server.receiveHead() catch return;
            var extra: [2]std.http.Header = undefined;
            var extra_count: usize = 0;
            if (resp.retry_after) |ra| {
                extra[extra_count] = .{ .name = "Retry-After", .value = ra };
                extra_count += 1;
            }
            request.respond(resp.body, .{
                .status = resp.status,
                .keep_alive = false,
                .extra_headers = extra[0..extra_count],
            }) catch return;
        }
    }
};

test "prompt retries a transient 503 and succeeds (Responses API)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var server = try MockResponsesRetryServer.init(io, &.{
        .{ .status = .service_unavailable },
        .{ .status = .ok, .body = ok_responses_sse_body },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockResponsesRetryServer.serve, .{&server});
    defer thread.join();

    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});
    defer gpa.free(base_url);
    var client: Client = undefined;
    try Client.init(&client, gpa, io, .{
        .base_url = base_url,
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
        .session_id = "test",
        .system_prompt = "",
        // No sleeping between retries in tests.
        .retry_base_delay_ms = 0,
    }, .{});
    defer client.deinit();

    var turn = try client.prompt(&.{}, ai.streamNoop());
    defer turn.deinit(gpa);
    // Two connections: the failed 503 attempt plus the successful retry.
    try std.testing.expectEqual(@as(u32, 2), server.connection_count.load(.monotonic));
}

test "prompt does not retry a permanent 4xx (Responses API)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var server = try MockResponsesRetryServer.init(io, &.{
        .{ .status = .bad_request },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockResponsesRetryServer.serve, .{&server});
    defer thread.join();

    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});
    defer gpa.free(base_url);
    var client: Client = undefined;
    try Client.init(&client, gpa, io, .{
        .base_url = base_url,
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
        .session_id = "test",
        .system_prompt = "",
        .retry_base_delay_ms = 0,
    }, .{});
    defer client.deinit();

    try std.testing.expectError(error.HttpClientError, client.prompt(&.{}, ai.streamNoop()));
    // Exactly one attempt — 4xx is permanent.
    try std.testing.expectEqual(@as(u32, 1), server.connection_count.load(.monotonic));
}

test "prompt records last_error_detail on an HTTP error (Responses API)" {
    // Regression: the Responses client previously dropped the error body and
    // never populated `last_error_detail`, so the UI saw no provider message.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var server = try MockResponsesRetryServer.init(io, &.{
        .{ .status = .forbidden, .body = "{\"error\":{\"message\":\"invalid api key\"}}" },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockResponsesRetryServer.serve, .{&server});
    defer thread.join();

    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});
    defer gpa.free(base_url);
    var client: Client = undefined;
    try Client.init(&client, gpa, io, .{
        .base_url = base_url,
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
        .session_id = "test",
        .system_prompt = "",
        .retry_base_delay_ms = 0,
    }, .{});
    defer client.deinit();

    try std.testing.expectError(error.HttpClientError, client.prompt(&.{}, ai.streamNoop()));
    const detail = client.last_error_detail orelse @panic("expected a recorded error detail");
    try std.testing.expectEqualStrings("HTTP 403: invalid api key", detail);
}

test "extraHeaders materializes provider headers with zen routing and user precedence" {
    const gpa = std.testing.allocator;
    // The merged spec list the runtime would hand the client: zen auto
    // headers with the user's client-attribution override applied.
    const specs = try provider_headers.build(gpa, "https://opencode.ai/zen/v1", .minimal, &.{
        .{ .name = "x-opencode-client", .value = .{ .literal = "custom-client" } },
    });
    defer provider_headers.freeHeaders(gpa, specs);
    try std.testing.expectEqual(@as(usize, 2), specs.len);

    var client: Client = undefined;
    try client.init(gpa, std.testing.io, .{
        .base_url = "https://opencode.ai/zen/v1",
        .api_key = "test-key",
        .model = "test-model",
        .session_id = "sess-32",
        .headers = specs,
        .system_prompt = "",
    }, .{ .log_name = "test" });
    defer client.deinit();

    var buffer: [provider_headers.max_outbound_headers]std.http.Header = undefined;
    const headers = client.extraHeaders(&buffer);

    try std.testing.expectEqual(@as(usize, 2), headers.len);
    try std.testing.expectEqualStrings(provider_headers.zen_session_header, headers[0].name);
    try std.testing.expectEqualStrings("sess-32", headers[0].value);
    try std.testing.expectEqualStrings(provider_headers.zen_client_header, headers[1].name);
    try std.testing.expectEqualStrings("custom-client", headers[1].value);
}
