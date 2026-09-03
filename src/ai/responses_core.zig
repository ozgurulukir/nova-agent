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

pub const ResponsesConfig = struct {
    pub const HeaderValue = union(enum) {
        literal: []const u8,
        account_id,
        session_id,
    };

    pub const Header = struct {
        name: []const u8,
        value: HeaderValue,
    };

    pub const BaseUrlMode = enum { openai_v1, raw };

    base_url_mode: BaseUrlMode = .openai_v1,
    endpoint_path: []const u8 = "/responses",
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
    http_client: std.http.Client,
    call_seq: u64 = 0,
    last_error_detail: ?[]u8 = null,

    pub fn init(target: *Client, gpa: std.mem.Allocator, io: std.Io, config: ai.Config, responses_config: ResponsesConfig) !void {
        std.debug.assert(config.base_url.len > 0);
        std.debug.assert(config.model.len > 0);
        const url = try responsesUrl(gpa, config.base_url, responses_config);
        errdefer gpa.free(url);
        const authorization = try std.fmt.allocPrint(gpa, "{s}{s}", .{ http.bearer_prefix, config.api_key });
        errdefer gpa.free(authorization);
        var owned_config = config;
        owned_config.base_url = "";
        owned_config.api_key = "";
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
        target.* = .{
            .gpa = gpa,
            .io = io,
            .config = owned_config,
            .url = url,
            .authorization = authorization,
            .tools_json = tools_json,
            .strict = config.strict,
            .responses_config = responses_config,
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
        return switch (err) {
            error.ReadFailed,
            error.WriteFailed,
            error.EndOfStream,
            error.ConnectionRefused,
            error.ConnectionResetByPeer,
            error.ConnectionTimedOut,
            error.BrokenPipe,
            error.HttpConnectionClosing,
            error.HttpRequestTruncated,
            error.Unexpected,
            => error.ConnectionFailed,
            else => err,
        };
    }

    pub fn prompt(self: *Client, messages: []const ai.MessageView, observer: anytype) !ai.Turn {
        self.clearErrorDetail();
        var extra_headers_buffer: [8]std.http.Header = undefined;
        const extra_headers = self.extraHeaders(&extra_headers_buffer);
        var req = try self.http_client.request(.POST, try std.Uri.parse(self.url), .{
            .headers = .{
                .authorization = .{ .override = self.authorization },
                .content_type = .{ .override = http.content_type_json },
                .user_agent = if (self.responses_config.user_agent) |value| .{ .override = value } else .default,
            },
            .extra_headers = extra_headers,
        });
        defer req.deinit();

        var payload: std.Io.Writer.Allocating = .init(self.gpa);
        defer payload.deinit();
        try writeRequestPayload(&payload.writer, self.gpa, self.config, self.responses_config, messages, self.tools_json);
        log.info("responses.request POST {s} profile={s} body={s}", .{ self.url, self.responses_config.log_name, http.logBytesHead(payload.written()) });
        req.transfer_encoding = .chunked;
        var body_buffer: [body_buffer_bytes]u8 = undefined;
        var body_writer = try req.sendBodyUnflushed(&body_buffer);
        try body_writer.writer.writeAll(payload.written());
        try body_writer.end();
        try req.connection.?.flush();

        var redirect_buffer: [redirect_buffer_bytes]u8 = undefined;
        var http_response = req.receiveHead(&redirect_buffer) catch |err| {
            // Capture the underlying socket error so the UI shows what
            // actually went wrong instead of the opaque error name. Read the
            // stream error fields directly — `Connection.getReadError`
            // unwraps `.?` internally and panics when std synthesized the
            // ReadFailed without a socket error.
            if (err == error.ReadFailed or err == error.WriteFailed or err == error.HttpRequestTruncated) {
                const reason: anyerror = if (req.connection) |conn|
                    if (conn.stream_reader.err) |e| e else if (conn.stream_writer.err) |e| e else err
                else
                    err;
                self.recordReadFailure(reason);
            }
            return self.headPhaseFailure(err);
        };
        const status_code: u16 = @intFromEnum(http_response.head.status);
        log.info("responses.response.head status={d} profile={s}", .{ status_code, self.responses_config.log_name });
        if (status_code >= 400) {
            var error_buffer: [transfer_buffer_bytes]u8 = undefined;
            const error_reader = http_response.reader(&error_buffer);
            var error_body: std.Io.Writer.Allocating = .init(self.gpa);
            defer error_body.deinit();
            _ = error_reader.streamRemaining(&error_body.writer) catch 0;
            log.warn("responses.response.error status={d} body={s}", .{ status_code, http.logBytesHead(error_body.written()) });
            if (status_code >= 500) return error.HttpServerError;
            return error.HttpClientError;
        }
        if (!http.isSuccess(status_code)) return error.HttpUnexpectedStatus;

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

    fn extraHeaders(self: *const Client, buffer: *[8]std.http.Header) []const std.http.Header {
        std.debug.assert(self.responses_config.headers.len <= buffer.len);
        for (self.responses_config.headers, 0..) |header, index| {
            buffer[index] = .{
                .name = header.name,
                .value = switch (header.value) {
                    .literal => |value| value,
                    .account_id => self.config.account_id,
                    .session_id => self.config.session_id,
                },
            };
        }
        return buffer[0..self.responses_config.headers.len];
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
