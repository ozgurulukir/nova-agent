const std = @import("std");
const log = std.log.scoped(.ai);

const ai = @import("../ai.zig");
const os = @import("../os.zig");
const http = @import("../http.zig");
const model_catalog = @import("openai_compatible_models.zig");
const openai_endpoint = @import("openai_endpoint.zig");
const stream_parser = @import("stream_parser.zig");
const tool_schema = @import("tool_schema.zig");
const tools_common = @import("../tools/common.zig");
const tools_mod = @import("../tools.zig");

const redirect_buffer_bytes = http.redirect_buffer_bytes;
const transfer_buffer_bytes = http.transfer_buffer_bytes;
const body_buffer_bytes = http.body_buffer_bytes;
/// Upper bound on exponential retry backoff, in milliseconds. A server-sent
/// `Retry-After` header is honored verbatim (not capped here).
const retry_max_delay_ms: u64 = 8000;
/// Raw-body fallback cap for `extractErrorMessage` when the error body is not
/// JSON or carries none of the known message shapes.
const error_detail_cap_bytes: usize = 600;

pub const ModelEntry = model_catalog.ModelEntry;
pub const listModels = model_catalog.listModels;
pub const openaiV1Root = openai_endpoint.v1Root;
pub const sanitizeToolArguments = stream_parser.sanitizeToolArguments;

// Model- and dialect-compat quirks (two-layer effort clipping, Qwen
// system-message normalization) live in the sibling leaf `model_compat.zig`,
// re-exported so existing `openai_compatible.*` callers resolve unchanged.
pub const model_compat = @import("model_compat.zig");
pub const wireEffortLabel = model_compat.wireEffortLabel;
pub const isQwenModel = model_compat.isQwenModel;
pub const clipEffortForModel = model_compat.clipEffortForModel;

// Chat-completions request-body serialization lives in the sibling module
// `openai_request.zig` (INV-RESP-1 symmetry with the Responses client); the
// alias keeps the `Client.prompt` call sites and the payload-band tests that
// exercise `tools_json` end-to-end compiling unchanged.
pub const openai_request = @import("openai_request.zig");
const writeRequestPayload = openai_request.writeRequestPayload;

/// OpenAI-compatible AI client using the Completions API.
pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    config: ai.Config,
    url: []u8,
    authorization: ?[]u8,
    tools_json: []u8,
    /// Whether tool definitions carry OpenAI strict structured-outputs mode.
    /// Captured at `init` so `updateMcpTools` can rebuild `tools_json`
    /// consistently without the caller re-passing it. Default `false` —
    /// strict mode is OpenAI-only and silently breaks function-calling on
    /// gateways (OpenRouter/Ollama/vLLM).
    strict: bool = false,
    http_client: std.http.Client,
    /// Optional OpenRouter app-attribution headers. Sent verbatim as
    /// `X-Title` / `HTTP-Referer` when non-null — both are OpenRouter
    /// conventions (ranking/discoverability + rate-limit priority). Owned;
    /// freed in `deinit`. Null for non-OpenRouter dialects.
    app_title: ?[]u8 = null,
    app_referer: ?[]u8 = null,
    /// Monotonic counter for synthesised tool_call ids when the inference
    /// server omits them. OpenAI's protocol requires stable ids linking
    /// assistant tool_calls to their `tool` result messages, so we mint
    /// one here rather than letting the agent see an empty id.
    tool_call_seq: u64 = 0,
    last_error_detail: ?[]u8 = null,

    pub fn init(
        target: *Client,
        gpa: std.mem.Allocator,
        io: std.Io,
        config: ai.Config,
    ) !void {
        std.debug.assert(config.base_url.len > 0);
        std.debug.assert(config.model.len > 0);

        const v1_root = try openaiV1Root(gpa, config.base_url);
        defer gpa.free(v1_root);
        const url = try std.fmt.allocPrint(gpa, "{s}/chat/completions", .{v1_root});
        errdefer gpa.free(url);

        // Empty key => anonymous request. Keep `authorization` null so `prompt`
        // omits the header entirely.
        const authorization: ?[]u8 = if (config.api_key.len > 0)
            try std.fmt.allocPrint(gpa, "{s}{s}", .{ http.bearer_prefix, config.api_key })
        else
            null;
        errdefer if (authorization) |a| gpa.free(a);

        var owned_config = config;
        owned_config.base_url = "";
        owned_config.api_key = "";
        owned_config.model = try gpa.dupe(u8, config.model);
        errdefer gpa.free(owned_config.model);
        owned_config.session_id = try gpa.dupe(u8, config.session_id);
        errdefer gpa.free(owned_config.session_id);

        const tools_json = try tool_schema.buildAllToolsJson(gpa, config.tools, config.mcp_tools, null, config.strict, .completions);
        errdefer gpa.free(tools_json);

        target.* = .{
            .gpa = gpa,
            .io = io,
            .config = owned_config,
            .url = url,
            .authorization = authorization,
            .tools_json = tools_json,
            .strict = config.strict,
            .http_client = .{ .allocator = gpa, .io = io },
            .app_title = null,
            .app_referer = null,
        };
    }

    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
        self.gpa.free(self.config.model);
        self.gpa.free(self.config.session_id);
        self.gpa.free(self.tools_json);
        if (self.authorization) |a| self.gpa.free(a);
        self.gpa.free(self.url);
        if (self.app_title) |t| self.gpa.free(t);
        if (self.app_referer) |r| self.gpa.free(r);
        if (self.last_error_detail) |d| self.gpa.free(d);
        self.* = undefined;
    }

    /// Rebuild the serialized tool definitions after the MCP tool set changes.
    /// `mcp_tools` is borrowed only for the duration of the call; the result is
    /// the owned `tools_json`. Call between turns, never mid-turn.
    /// `registry`, when non-null, contributes its builtin + plugin tools so
    /// the model sees them as first-class definitions. `builtin_override`
    /// lets the caller pick what `config.tools` contributes at call time —
    /// typically `&.{}` because the registry's builtin already covers
    /// bash, and emitting both creates a duplicate name that most APIs
    /// reject outright.
    pub fn updateMcpTools(
        self: *Client,
        mcp_tools: []const ai.McpToolSchema,
        registry: ?*tools_mod.ToolRegistry,
        builtin_override: []const tools_common.Tool,
    ) !void {
        const new_json = try tool_schema.buildAllToolsJson(self.gpa, builtin_override, mcp_tools, registry, self.strict, .completions);
        self.gpa.free(self.tools_json);
        self.tools_json = new_json;
    }

    fn clearErrorDetail(self: *Client) void {
        if (self.last_error_detail) |d| self.gpa.free(d);
        self.last_error_detail = null;
    }

    /// Conservative check: does the last recorded error detail mention "cache"?
    /// Used (C2) to decide whether a 400 might be a `cache_control` /
    /// `prompt_cache_key` rejection worth a single cache-stripped retry.
    /// Case-insensitive. False positives (a 400 mentioning "cache" for an
    /// unrelated reason) cost one extra request and then fail normally — the
    /// retry is bounded and idempotent (a 400 means the model produced nothing).
    fn errorDetailMentionsCache(self: *Client) bool {
        const detail = self.last_error_detail orelse return false;
        return std.ascii.indexOfIgnoreCase(detail, "cache") != null;
    }

    /// Record `HTTP <status>: <message>` from a failed response body for the UI.
    /// Best-effort: a failure to build the string just leaves the detail unset.
    fn recordErrorDetail(self: *Client, status_code: u16, body: []const u8) void {
        const message = extractErrorMessage(self.gpa, body) catch return;
        defer self.gpa.free(message);
        log.warn("openai_compatible.recordErrorDetail status={d} body={s}", .{ status_code, message });
        const detail = std.fmt.allocPrint(self.gpa, "HTTP {d}: {s}", .{ status_code, message }) catch return;
        self.clearErrorDetail();
        self.last_error_detail = detail;
    }

    pub fn prompt(
        self: *Client,
        messages: []const ai.MessageView,
        observer: anytype,
    ) !ai.Turn {
        std.debug.assert(self.url.len > 0);
        self.clearErrorDetail();

        // The payload is serialized ONCE per cache mode; every retry attempt
        // re-sends the same bytes. This is safe because retries only happen on
        // head-phase 429/5xx — the model has not produced anything and no tool
        // has run, so the request is idempotent. Stream-mid errors are never
        // retried (partial deltas may already be visible to the observer).
        var payload: std.Io.Writer.Allocating = .init(self.gpa);
        defer payload.deinit();
        // C1/C2: `disable_cache` starts from the user's config flag. C2 may
        // flip it to `true` after a cache-related 400 and re-send the same
        // payload with cache fields stripped — exactly once, independently of
        // the 429/5xx retry budget (different failure mode).
        var disable_cache = self.config.disable_prompt_cache;
        try writeRequestPayload(
            self.gpa,
            &payload.writer,
            self.config.model,
            self.config.session_id,
            messages,
            self.tools_json,
            self.config.reasoning,
            self.config.max_output_tokens,
            self.config.wire_dialect,
            disable_cache,
            self.config.is_reasoning_model,
        );
        const req_body_log = try logBytes(self.gpa, payload.written());
        defer if (req_body_log.ptr != payload.written().ptr) self.gpa.free(req_body_log);
        log.info("openai_compatible.request POST {s} body={s}", .{ self.url, req_body_log });
        // L2: when this client carries no tools, say so next to the request log
        // with the client identity. `writeRequestPayload` is a free function
        // (no `self.url`), so the URL disambiguation lives here — it tells the
        // main agent apart from the summarizer/naming clients (which are
        // correctly tool-less) when several clients are alive.
        if (std.mem.eql(u8, self.tools_json, "[]")) {
            log.info("openai_compatible.no_tools client model={s} url={s}", .{ self.config.model, self.url });
        }

        // C2: a cache-related 400 earns exactly ONE cache-stripped re-send,
        // independent of the 429/5xx retry budget (different failure mode).
        // `downgrade_done` gates it to a single rebuild; the outer loop runs at
        // most twice (original payload, then stripped). Note Zig's
        // `while … : (step) { continue }` runs the step expr, so a downgrade
        // cannot ride the `attempt` counter — it is a separate state bit.
        var downgrade_done = false;
        while (true) {
            var attempt: u32 = 0;
            while (attempt <= self.config.max_retries) : (attempt += 1) {
                var retry_after_secs: ?u64 = null;
                const turn = self.sendOnce(payload.written(), observer, &retry_after_secs) catch |err| {
                    // Only head-phase transient failures are retried: 429/5xx
                    // statuses and connection drops before any response bytes.
                    // The model has produced nothing and no tool has run, so the
                    // request is idempotent. Every other 4xx is permanent — a
                    // schema/auth/model error won't fix itself — and stream-mid
                    // errors never surface as these codes, so they propagate
                    // immediately too.
                    if (attempt >= self.config.max_retries) {
                        // C2: before giving up on a 400, try the cache-stripped
                        // variant once — some OpenRouter `:free` / gateway-
                        // fronted models reject `cache_control` /
                        // `prompt_cache_key` with 400. Conservative: only when
                        // the error body mentions "cache" AND we haven't
                        // downgraded yet AND the user didn't already disable
                        // caching (no fields to strip).
                        if (err == error.HttpClientError and !downgrade_done and !disable_cache and self.errorDetailMentionsCache()) {
                            downgrade_done = true;
                            disable_cache = true;
                            payload.deinit();
                            payload = .init(self.gpa);
                            try writeRequestPayload(
                                self.gpa,
                                &payload.writer,
                                self.config.model,
                                self.config.session_id,
                                messages,
                                self.tools_json,
                                self.config.reasoning,
                                self.config.max_output_tokens,
                                self.config.wire_dialect,
                                disable_cache,
                                self.config.is_reasoning_model,
                            );
                            log.warn("openai_compatible.cache_downgrade retrying without cache_control/prompt_cache_key after HTTP 400", .{});
                            break; // break inner loop → outer loop re-runs the full retry budget on the stripped payload
                        }
                        return err;
                    }
                    switch (err) {
                        error.HttpServerError, error.HttpRateLimited, error.ConnectionFailed => {},
                        else => return err,
                    }
                    const delay_ms = self.retryDelayMs(attempt, retry_after_secs);
                    log.warn("openai_compatible.retry attempt={d} err={s} delay_ms={d}", .{ attempt + 1, @errorName(err), delay_ms });
                    self.sleepMs(delay_ms);
                    continue;
                };
                return turn;
            }
            // Inner loop exhausted its retry budget without returning a turn.
            // This only happens after a downgrade (the break above) — the
            // original-payload path always returns err or a turn. Surface the
            // persistent 400 rather than looping forever.
            if (downgrade_done) return error.HttpClientError;
            unreachable; // guarded by the return paths above
        }
    }

    /// Perform one HTTP round-trip with the already-serialized payload.
    /// Transient head-phase statuses (429, 5xx) surface as
    /// `error.HttpRateLimited` / `error.HttpServerError` so `prompt` can
    /// decide whether to retry; every other failure propagates unchanged.
    /// When a retryable status is hit, `retry_after_secs` receives the
    /// server's `Retry-After` value (integer seconds) if one was sent.
    fn sendOnce(self: *Client, payload: []const u8, observer: anytype, retry_after_secs: *?u64) !ai.Turn {
        // Everything up to and including the response head is "head phase":
        // the model has produced nothing and no tool has run, so `prompt`
        // may retry the same payload verbatim. Connection/read drops here
        // are mapped to `error.ConnectionFailed` (retryable); protocol-level
        // rejects pass through unchanged (permanent).
        // OpenRouter app-attribution headers (X-Title / HTTP-Referer). These
        // live on this frame's stack and must outlive the request — `req` is
        // fully consumed (`receiveHead` + stream) before this function returns.
        var extra_headers: [2]std.http.Header = undefined;
        var extra_count: usize = 0;
        if (self.app_title) |title| {
            extra_headers[extra_count] = .{ .name = "X-Title", .value = title };
            extra_count += 1;
        }
        if (self.app_referer) |referer| {
            extra_headers[extra_count] = .{ .name = "HTTP-Referer", .value = referer };
            extra_count += 1;
        }
        var req = self.http_client.request(.POST, try std.Uri.parse(self.url), .{
            .headers = .{
                .authorization = if (self.authorization) |a| .{ .override = a } else .omit,
                .content_type = .{ .override = http.content_type_json },
            },
            .extra_headers = extra_headers[0..extra_count],
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
            // `receiveHead` fails with `error.ReadFailed` when the connection
            // drops; capture the underlying socket error so the UI shows what
            // actually went wrong instead of the opaque `ReadFailed`.
            if (err == error.ReadFailed) {
                if (req.connection) |conn| {
                    if (conn.getReadError()) |read_err| self.recordReadFailure(read_err);
                }
            }
            return self.headPhaseFailure(err);
        };
        const status_code: u16 = @intFromEnum(http_response.head.status);
        log.info("openai_compatible.response.head status={d}", .{status_code});
        if (status_code >= 400) {
            // Read `Retry-After` before initializing the body reader — the
            // head pointers are invalidated once the body stream starts.
            if (isRetryableHeadStatus(status_code)) {
                retry_after_secs.* = parseRetryAfterSeconds(http_response.head.bytes);
            }
            var error_buffer: [transfer_buffer_bytes]u8 = undefined;
            const error_reader = http_response.reader(&error_buffer);
            var error_body: std.Io.Writer.Allocating = .init(self.gpa);
            defer error_body.deinit();
            _ = error_reader.streamRemaining(&error_body.writer) catch 0;
            const err_body_log = try logBytes(self.gpa, error_body.written());
            defer if (err_body_log.ptr != error_body.written().ptr) self.gpa.free(err_body_log);
            log.warn("openai_compatible.response.error status={d} body={s}", .{ status_code, err_body_log });
            self.recordErrorDetail(status_code, error_body.written());
            if (status_code == 429) return error.HttpRateLimited;
            if (status_code >= 500) return error.HttpServerError;
            return error.HttpClientError;
        }
        if (!http.isSuccess(status_code)) return error.HttpUnexpectedStatus;

        // Socket-level read timeout: prevents indefinite hangs when the
        // server stops mid-stream. Applied after the head is received so
        // the (fast) head exchange is not affected.
        if (req.connection) |conn| {
            if (!os.is_windows) {
                const tv: std.posix.timeval = .{
                    .sec = @intCast(self.config.request_timeout_seconds),
                    .usec = 0,
                };
                std.posix.setsockopt(
                    conn.stream_reader.stream.socket.handle,
                    std.posix.SOL.SOCKET,
                    std.posix.SO.RCVTIMEO,
                    std.mem.asBytes(&tv),
                ) catch |err| {
                    log.warn("openai_compatible.setsockopt.RCVTIMEO failed: {}", .{err});
                };
            }
        }

        var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
        const reader = http_response.reader(&transfer_buffer);
        return try stream_parser.readStream(self.gpa, reader, observer, &self.tool_call_seq, self.config.max_parallel_tool_calls, self.config.model);
    }

    /// Map a failure that occurred before any response bytes (connect, body
    /// send, or head read) to `error.ConnectionFailed` when it is a transient
    /// connection/read drop. `prompt` retries those verbatim — the model has
    /// produced nothing and no tool has run, so the request is idempotent,
    /// exactly like a head-phase 429/5xx. Protocol-level rejects are returned
    /// unchanged; a retry will not fix them.
    ///
    /// `error.Unexpected` is deliberately included: in the head phase (before
    /// any response bytes) it is almost always a connect/read drop, and Windows
    /// surfaces connection-refused as NTSTATUS 0xc0000236 (`error.Unexpected`)
    /// rather than `error.ConnectionRefused`. The breadth is accepted because no
    /// other `error.Unexpected` source is expected before any response bytes.
    ///
    /// `error.HttpConnectionClosing` is std.http's report for reusing an idle
    /// keep-alive connection the server already closed (0-byte head read): the
    /// retry loop reconnects and re-sends, so the user sees nothing.
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
            error.Unexpected,
            => error.ConnectionFailed,
            else => err,
        };
    }

    /// Record the underlying socket error from a dropped response read for
    /// the UI, so a connection failure shows something actionable instead of
    /// the opaque `ReadFailed`. Best-effort: a failure to build the string
    /// just leaves the detail unset.
    fn recordReadFailure(self: *Client, read_err: anyerror) void {
        const detail = std.fmt.allocPrint(
            self.gpa,
            "Connection to the model provider was lost: {s}",
            .{@errorName(read_err)},
        ) catch return;
        self.clearErrorDetail();
        self.last_error_detail = detail;
    }

    /// Delay before a retry: the server's `Retry-After` (integer seconds)
    /// when present, otherwise exponential backoff `base * 2^attempt` capped
    /// at `retry_max_delay_ms`. Pure — tested directly.
    fn retryDelayMs(self: *const Client, attempt: u32, retry_after_secs: ?u64) u64 {
        if (retry_after_secs) |secs| {
            // Saturating: an absurd header value must not wrap and stall or
            // skip the wait.
            return secs *| std.time.ms_per_s;
        }
        // Exponential backoff `base * 2^attempt`, saturating so an absurd
        // base can't wrap, then capped.
        var backoff = self.config.retry_base_delay_ms;
        var i: u32 = 0;
        while (i < attempt) : (i += 1) backoff *|= 2;
        return @min(backoff, retry_max_delay_ms);
    }

    /// Block the worker for the backoff delay. Best-effort — a cancel error
    /// just falls through (the turn is being torn down anyway).
    fn sleepMs(self: *const Client, ms: u64) void {
        if (ms == 0) return;
        const clamped: i64 = @intCast(@min(ms, std.math.maxInt(i64)));
        self.io.sleep(std.Io.Duration.fromMilliseconds(clamped), .awake) catch {};
    }
};

/// Head-phase statuses worth retrying: 429 (rate limit) and 5xx (server). The
/// error returns keep 429 → HttpRateLimited and 5xx → HttpServerError as
/// distinct errors; this predicate only gates the shared `Retry-After` read.
fn isRetryableHeadStatus(status: u16) bool {
    return status == 429 or status >= 500;
}

/// Extract an integer-seconds `Retry-After` value from a raw HTTP head.
/// HTTP-date formatted values are out of scope and yield null (gateways
/// practically send integer seconds). Pure — tested directly.
fn parseRetryAfterSeconds(head_bytes: []const u8) ?u64 {
    var it = std.mem.splitSequence(u8, head_bytes, "\r\n");
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "retry-after")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseInt(u64, value, 10) catch null;
    }
    return null;
}

/// Truncate a request/response body for logging. When the body exceeds
/// `limit`, keep the head AND append a tail slice so the `tools` array
/// (which serializes after `messages` and is usually past the head) is
/// still visible. The tail is found by locating `"tools":` in the full
/// body; if absent (or already inside the head), a plain
/// `[...{n} more bytes]` ellipsis is used.
///
/// Returns either `bytes` verbatim (short body, or long body without a
/// tools array past the head — caller frees nothing) or a freshly
/// allocated slice (caller frees via `gpa` when `result.ptr != bytes.ptr`).
fn logBytes(gpa: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const limit = http.log_head_bytes_max;
    if (bytes.len <= limit) return bytes;
    // Look for the tools array past the head — the common debug target when
    // triaging "the model can't call tools" reports. The tools array is
    // serialised after messages, so a realistic system prompt + a few turns
    // already pushes it past the head.
    if (std.mem.indexOf(u8, bytes, "\"tools\":")) |pos| {
        if (pos >= limit) {
            const tail_max: usize = http.log_tail_bytes_max;
            const tail_end = @min(bytes.len, pos + tail_max);
            return std.fmt.allocPrint(gpa, "{s}\n   [...{d} bytes truncated...]\n   {s}", .{
                bytes[0..limit],
                bytes.len - limit,
                bytes[pos..tail_end],
            });
        }
    }
    return std.fmt.allocPrint(gpa, "{s}\n   [...{d} more bytes]", .{ bytes[0..limit], bytes.len - limit });
}

/// Pull a human-readable message out of an error response body. Handles the
/// common OpenAI-ish shapes — `{"error":{"message":...}}`, `{"error":"..."}`,
/// `{"message":...}` — and falls back to the raw body (capped) when the body
/// isn't JSON or has none of those. Returned slice is owned by `gpa`.
fn extractErrorMessage(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    const fallback = trimmed[0..@min(trimmed.len, error_detail_cap_bytes)];

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{}) catch
        return gpa.dupe(u8, if (fallback.len > 0) fallback else "(empty response body)");
    defer parsed.deinit();

    if (parsed.value == .object) {
        const obj = parsed.value.object;
        if (obj.get("error")) |err_val| switch (err_val) {
            .string => |s| return gpa.dupe(u8, s),
            .object => |eo| if (eo.get("message")) |m| {
                if (m == .string) return gpa.dupe(u8, m.string);
            },
            else => {},
        };
        if (obj.get("message")) |m| {
            if (m == .string) return gpa.dupe(u8, m.string);
        }
    }
    return gpa.dupe(u8, if (fallback.len > 0) fallback else "(empty response body)");
}

test "extractErrorMessage pulls the nested message, plain error, or raw fallback" {
    const gpa = std.testing.allocator;

    // OpenCode Zen's shape: {"type":"error","error":{"type":...,"message":...}}
    const zen = try extractErrorMessage(gpa,
        \\{"type":"error","error":{"type":"ModelError","message":"Free promotion has ended."}}
    );
    defer gpa.free(zen);
    try std.testing.expectEqualStrings("Free promotion has ended.", zen);

    // `error` as a bare string.
    const plain = try extractErrorMessage(gpa,
        \\{"error":"invalid api key"}
    );
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("invalid api key", plain);

    // Non-JSON body falls back to the raw text.
    const raw = try extractErrorMessage(gpa, "  upstream timeout  ");
    defer gpa.free(raw);
    try std.testing.expectEqualStrings("upstream timeout", raw);
}

test "logBytes passes short bodies through untouched (no allocation)" {
    const gpa = std.testing.allocator;
    const short = "hello world";
    const out = try logBytes(gpa, short);
    // Pointer equality proves no allocation happened — the slice is aliased.
    try std.testing.expect(out.ptr == short.ptr);
    try std.testing.expectEqualStrings(short, out);
}

test "logBytes truncation surfaces the tools array past the head" {
    const gpa = std.testing.allocator;

    // Build a ~20KB body: ~13KB of message filler, then the `tools` array the
    // old head-only truncation would have hidden. JSON key order is
    // model → messages → … → tools, so this mirrors a real payload.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, "{\"model\":\"m\",\"messages\":[{\"role\":\"system\",\"content\":\"");
    var filler: usize = 0;
    while (filler < 13 * 1024) : (filler += 1) try body.append(gpa, 'x');
    try body.appendSlice(gpa, "\"}],\"stream\":true,\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"bash\"}}]}");

    const out = try logBytes(gpa, body.items);
    defer if (out.ptr != body.items.ptr) gpa.free(out);

    // The tools array is now visible despite living past the 12KB head.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"tools\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"bash\"") != null);
    // The truncation marker is present.
    try std.testing.expect(std.mem.indexOf(u8, out, "bytes truncated") != null);
    // And it was allocated (not aliased).
    try std.testing.expect(out.ptr != body.items.ptr);
}

test "logBytes truncation falls back to an ellipsis when there is no tools array" {
    const gpa = std.testing.allocator;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, "{\"model\":\"m\",\"content\":\"");
    var filler: usize = 0;
    while (filler < 13 * 1024) : (filler += 1) try body.append(gpa, 'x');
    try body.appendSlice(gpa, "\"}");

    const out = try logBytes(gpa, body.items);
    defer gpa.free(out);
    try std.testing.expect(out.ptr != body.items.ptr);
    try std.testing.expect(std.mem.indexOf(u8, out, "more bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"tools\":") == null);
}

test "errorDetailMentionsCache is case-insensitive and handles null" {
    // C2: the downgrade decision is driven by this predicate. Verify the
    // conservative "cache" substring match in both cases and the null path.
    const gpa = std.testing.allocator;
    const tools = [_]tools_common.Tool{
        .{ .name = "bash", .description = "x", .schema = .{ .properties = &.{} }, .run = undefined, .display = undefined },
    };
    var client: Client = undefined;
    try client.init(gpa, std.testing.io, .{
        .base_url = "http://localhost:8080/v1",
        .api_key = "test-key",
        .model = "test-model",
        .tools = &tools,
        .mcp_tools = &.{},
    });
    defer client.deinit();

    // No detail recorded yet → no mention.
    try std.testing.expect(!client.errorDetailMentionsCache());

    // Lowercase "cache".
    client.last_error_detail = try gpa.dupe(u8, "HTTP 400: unknown field cache_control");
    try std.testing.expect(client.errorDetailMentionsCache());
    gpa.free(client.last_error_detail.?);

    // Mixed-case "Cache".
    client.last_error_detail = try gpa.dupe(u8, "Cache-Control header rejected");
    try std.testing.expect(client.errorDetailMentionsCache());
    gpa.free(client.last_error_detail.?);

    // Unrelated error → no mention (downgrade must not fire).
    client.last_error_detail = try gpa.dupe(u8, "HTTP 400: invalid model id");
    try std.testing.expect(!client.errorDetailMentionsCache());
    gpa.free(client.last_error_detail.?);
    client.last_error_detail = null;
}

test "buildToolsJson produces a valid JSON array for the registry" {
    const tools = @import("../tools.zig");
    const gpa = std.testing.allocator;
    const json = try tool_schema.buildAllToolsJson(gpa, tools.builtinRegistry(), &.{}, null, true, .completions);
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    // The builtin shell tool is `pwsh` on Windows and `bash` elsewhere; build the
    // expected "name" dynamically from the canonical `shellToolName` so the
    // assertion holds on both hosts.
    const shell_name = try std.fmt.allocPrint(gpa, "\"name\":\"{s}\"", .{tools.shellToolName});
    defer gpa.free(shell_name);
    try std.testing.expect(std.mem.indexOf(u8, json, shell_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"strict\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"additionalProperties\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Shell command to run.") != null);
}

test "buildToolsJson substitutes {{hsep}} placeholders with ~" {
    const gpa = std.testing.allocator;
    const tools = [_]tools_common.Tool{
        .{
            .name = "demo",
            .description = "uses {{hsep}} marker",
            .schema = .{ .properties = &.{} },
            .run = undefined,
            .display = undefined,
        },
    };
    const json = try tool_schema.buildAllToolsJson(gpa, &tools, &.{}, null, false, .completions);
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "uses ~ marker") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "{{hsep}}") == null);
}

test "buildAllToolsJson includes MCP tools alongside builtin tools" {
    const gpa = std.testing.allocator;
    const tools = [_]tools_common.Tool{
        .{
            .name = "bash",
            .description = "Run shell commands",
            .schema = .{ .properties = &.{} },
            .run = undefined,
            .display = undefined,
        },
    };
    const mcp_tools = [_]ai.McpToolSchema{
        .{
            .name = "mcp__server__greet",
            .description = "Say hello",
            .schema = .{ .properties = &.{} },
        },
    };
    const json = try tool_schema.buildAllToolsJson(gpa, &tools, &mcp_tools, null, false, .completions);
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"bash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"mcp__server__greet\"") != null);
}

test "buildAllToolsJson via updateMcpTools: registry builtin suppresses duplicate shell" {
    // Regression: the tick-driven `injectAllTools` path used to call
    // `updateMcpTools(mcp_tools, registry)` without an override, so
    // `buildAllToolsJson` would emit the shell tool twice — once from
    // `self.config.tools` and again from `r.all.builtin`. Most
    // OpenAI-compatible APIs reject duplicate tool names with HTTP 400,
    // dropping the entire tool list including the plugin tools.
    const gpa = std.testing.allocator;

    // The builtin shell name is `pwsh` on Windows and `bash` elsewhere — build
    // the occurrence scan off the canonical `shellToolName` so the "exactly one,
    // no duplicate" invariant holds on both hosts.
    const shell_name = try std.fmt.allocPrint(gpa, "\"name\":\"{s}\"", .{tools_mod.shellToolName});
    defer gpa.free(shell_name);

    // Build a minimal Client with just a shell builtin in `config.tools`.
    var client: Client = undefined;
    try client.init(gpa, std.testing.io, .{
        .base_url = "https://example.invalid",
        .api_key = "test-key",
        .model = "test-model",
        .tools = tools_mod.builtinRegistry(),
        .mcp_tools = &.{},
        .session_id = "test",
        .system_prompt = "",
    });
    defer client.deinit();

    // Build a registry with a plugin tool; its builtin is the shell tool too.
    const reg = try gpa.create(tools_mod.ToolRegistry);
    defer {
        reg.deinit(gpa);
        gpa.destroy(reg);
    }
    reg.* = tools_mod.ToolRegistry.init(tools_mod.builtinRegistry());
    // Ownership of `plugin_name` and `plugin_desc` transfers to the
    // registry via addPluginTool; registry.deinit frees them.
    const plugin_name = try gpa.dupe(u8, "lua__p__t");
    const plugin_desc = try gpa.dupe(u8, "plugin tool");
    try reg.addPluginTool(gpa, .{
        .name = plugin_name,
        .description = plugin_desc,
        .schema = .{ .properties = &.{} },
        .run = undefined,
        .display = undefined,
    });

    // The fix: pass &.{} as builtin_override so config.tools isn't
    // emitted alongside the registry's builtin (which already has it).
    try client.updateMcpTools(&.{}, reg, &.{});

    const json = client.tools_json;
    var first: ?usize = null;
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, json, idx, shell_name)) |pos| {
        if (first == null) first = pos;
        count += 1;
        idx = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"lua__p__t\"") != null);
}

test "updateMcpTools propagates plugin tools into tools_json end-to-end" {
    // End-to-end regression for the user-reported "plugin tools not
    // visible to AI" bug. We simulate the exact call site:
    //   attachOpenAiCompatibleClient → injectPluginTools → injectAllTools →
    //   runtime.client.updateMcpTools(mcp_schemas, registry, &.{}).
    // After the call, `client.tools_json` must contain every plugin
    // tool's name so the next prompt includes them.
    const gpa = std.testing.allocator;

    var client: Client = undefined;
    try client.init(gpa, std.testing.io, .{
        .base_url = "https://example.invalid",
        .api_key = "test-key",
        .model = "test-model",
        .tools = tools_mod.builtinRegistry(),
        .mcp_tools = &.{},
        .session_id = "test",
        .system_prompt = "",
    });
    defer client.deinit();

    // Build a registry carrying two plugin tools, exactly the way
    // registerPluginTools would after initRuntime runs.
    const reg = try gpa.create(tools_mod.ToolRegistry);
    defer {
        reg.deinit(gpa);
        gpa.destroy(reg);
    }
    reg.* = tools_mod.ToolRegistry.init(tools_mod.builtinRegistry());

    for ([_][]const u8{ "lua__hello-world__greet", "lua__hello-world__current_time" }) |tool_name| {
        const owned_name = try gpa.dupe(u8, tool_name);
        const owned_desc = try gpa.dupe(u8, "test");
        try reg.addPluginTool(gpa, .{
            .name = owned_name,
            .description = owned_desc,
            .schema = .{ .properties = &.{} },
            .run = undefined,
            .display = undefined,
        });
    }

    // The exact call shape from injectAllTools.
    try client.updateMcpTools(&.{}, reg, &.{});

    const json = client.tools_json;
    const shell_name = try std.fmt.allocPrint(gpa, "\"name\":\"{s}\"", .{tools_mod.shellToolName});
    defer gpa.free(shell_name);
    try std.testing.expect(std.mem.indexOf(u8, json, shell_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"lane\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"background\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"skill\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"lua__hello-world__greet\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"lua__hello-world__current_time\"") != null);

    // And the count of name occurrences must be exactly 6 (4 builtins + 2 plugin tools).
    var name_count: usize = 0;
    var scan_idx: usize = 0;
    while (std.mem.indexOfPos(u8, json, scan_idx, "\"name\":\"")) |pos| {
        name_count += 1;
        scan_idx = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 6), name_count);
}

test "buildToolsJson emits strict schema with nullable union types for optional fields" {
    const gpa = std.testing.allocator;
    const tools = [_]tools_common.Tool{
        .{
            .name = "demo",
            .description = "Demo tool with mixed required/optional fields",
            .schema = .{
                .properties = &.{
                    .{ .name = "required_str", .kind = .string, .description = "Required string", .required = true, .nullable = false },
                    .{ .name = "optional_str", .kind = .string, .description = "Optional string", .required = false, .nullable = true },
                    .{ .name = "optional_int", .kind = .integer, .description = "Optional int", .required = false, .nullable = true },
                    .{ .name = "optional_bool", .kind = .boolean, .description = "Optional bool", .required = false, .nullable = true },
                    .{ .name = "optional_obj", .kind = .object, .description = "Optional object", .required = false, .nullable = true },
                    .{ .name = "optional_arr", .kind = .array, .description = "Optional array", .required = false, .nullable = true },
                    .{ .name = "non_nullable_str", .kind = .string, .description = "Non-nullable string", .required = true, .nullable = false },
                },
            },
            .run = undefined,
            .display = undefined,
        },
    };
    const json = try tool_schema.buildAllToolsJson(gpa, &tools, &.{}, null, true, .completions);
    defer gpa.free(json);

    // Top-level strict marker and top-level additionalProperties:false
    try std.testing.expect(std.mem.indexOf(u8, json, "\"strict\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"additionalProperties\":false") != null);

    // Non-nullable required field stays as a single type string
    try std.testing.expect(std.mem.indexOf(u8, json, "\"required_str\":{\"type\":\"string\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"non_nullable_str\":{\"type\":\"string\"") != null);

    // Nullable optional fields become union type arrays
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_str\":{\"type\":[\"string\",\"null\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_int\":{\"type\":[\"integer\",\"null\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_bool\":{\"type\":[\"boolean\",\"null\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_obj\":{\"type\":[\"object\",\"null\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_arr\":{\"type\":[\"array\",\"null\"]") != null);

    // Nested object keeps additionalProperties:true for free-form keys
    try std.testing.expect(std.mem.indexOf(u8, json, "\"additionalProperties\":true") != null);

    // Required array includes ALL properties for strict mode compliance.
    // Optional fields are marked nullable so the model knows they can be absent.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"required\":[\"required_str\",\"optional_str\",\"optional_int\",\"optional_bool\",\"optional_obj\",\"optional_arr\",\"non_nullable_str\"]") != null);
    // Optional fields appear in properties.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_str\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_int\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_bool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_obj\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_arr\"") != null);
}

test "buildToolsJson omits strict mode and filters required when strict is false (gateway compatibility)" {
    // Regression for the "model emits tool calls as plain text" bug:
    // gateways (OpenRouter/Ollama/vLLM) reject or silently break OpenAI
    // strict structured-outputs mode, which disables function-calling.
    // With strict=false the schema must (a) NOT carry "strict":true and
    // (b) list only genuinely-required properties in `required`.
    const gpa = std.testing.allocator;
    const tools = [_]tools_common.Tool{
        .{
            .name = "demo",
            .description = "Demo",
            .schema = .{
                .properties = &.{
                    .{ .name = "required_str", .kind = .string, .description = "Required", .required = true, .nullable = false },
                    .{ .name = "optional_str", .kind = .string, .description = "Optional", .required = false, .nullable = true },
                    .{ .name = "optional_int", .kind = .integer, .description = "Optional", .required = false, .nullable = true },
                },
            },
            .run = undefined,
            .display = undefined,
        },
    };
    const json = try tool_schema.buildAllToolsJson(gpa, &tools, &.{}, null, false, .completions);
    defer gpa.free(json);

    // No strict marker.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"strict\"") == null);
    // Only the required property is required — optionals stay optional.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"required\":[\"required_str\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "optional_str") != null);
    // Optionals still listed in properties (nullable unions preserved).
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_str\":{\"type\":[\"string\",\"null\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"optional_int\":{\"type\":[\"integer\",\"null\"]") != null);
    // Empty `required` (no required props) is still valid JSON.
    const no_required_tools = [_]tools_common.Tool{
        .{
            .name = "noargs",
            .description = "No args",
            .schema = .{ .properties = &.{} },
            .run = undefined,
            .display = undefined,
        },
    };
    const json2 = try tool_schema.buildAllToolsJson(gpa, &no_required_tools, &.{}, null, false, .completions);
    defer gpa.free(json2);
    try std.testing.expect(std.mem.indexOf(u8, json2, "\"required\":[]") != null);
}

test "buildToolsJson preserves nested object additionalProperties for free-form env" {
    const gpa = std.testing.allocator;
    const tools = [_]tools_common.Tool{
        .{
            .name = "bash",
            .description = "Run shell commands",
            .schema = .{
                .properties = &.{
                    .{ .name = "command", .kind = .string, .description = "Shell command", .required = true, .nullable = false },
                    .{ .name = "env", .kind = .object, .description = "Env vars", .required = false, .nullable = true },
                },
            },
            .run = undefined,
            .display = undefined,
        },
    };
    const json = try tool_schema.buildAllToolsJson(gpa, &tools, &.{}, null, true, .completions);
    defer gpa.free(json);

    // Top-level parameters object is strict
    try std.testing.expect(std.mem.indexOf(u8, json, "\"parameters\":{\"type\":\"object\",\"additionalProperties\":false") != null);
    // Nested env object remains free-form
    try std.testing.expect(std.mem.indexOf(u8, json, "\"env\":{\"type\":[\"object\",\"null\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"additionalProperties\":true") != null);
}

test "updateMcpTools rebuilds the serialized tool list in place" {
    const gpa = std.testing.allocator;
    const tools = [_]tools_common.Tool{
        .{
            .name = "bash",
            .description = "Run shell commands",
            .schema = .{ .properties = &.{} },
            .run = undefined,
            .display = undefined,
        },
    };
    var client: Client = undefined;
    try client.init(gpa, std.testing.io, .{
        .base_url = "http://localhost:8080/v1",
        .api_key = "test-key",
        .model = "test-model",
        .tools = &tools,
        .mcp_tools = &.{},
    });
    defer client.deinit();

    // No MCP tools yet — only the builtin "bash" is serialized.
    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, "mcp__tavily__search") == null);

    // Injecting an MCP tool set must add it alongside the builtin tool.
    const mcp_tools = [_]ai.McpToolSchema{
        .{ .name = "mcp__tavily__search", .description = "Search the web", .schema = .{ .properties = &.{} } },
    };
    try client.updateMcpTools(&mcp_tools, null, tools_mod.builtinRegistry());
    const shell_name = try std.fmt.allocPrint(gpa, "\"name\":\"{s}\"", .{tools_mod.shellToolName});
    defer gpa.free(shell_name);
    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, shell_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, "\"name\":\"mcp__tavily__search\"") != null);

    // Replacing with an empty set removes the MCP tool but keeps the builtin.
    try client.updateMcpTools(&.{}, null, tools_mod.builtinRegistry());
    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, "mcp__tavily__search") == null);
    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, shell_name) != null);
}

test "writeRequestPayload ships the full tools array for OpenRouter byte-for-byte" {
    // Tersine mühendislik yerine servis katmanını uçtan uca çalıştırıp, gerçek
    // wire payload'ı üretir ve OpenRouter'a giden `tools` array'inin log
    // truncation'ına takılmadan tam doğruluğunu (hiçbir tool düşmeden, tam
    // byte-for-byte) kanıtlar. Payload `writeRequestPayload` tarafından tek
    // parça üretilir — `logBytes` yalnızca loglama için kırpar, test ham byte'ı
    // olduğu gibi alır.
    const gpa = std.testing.allocator;

    // Registry: builtin (bash, lane) + plugin tools, aynen üretimdeki gibi.
    var registry: tools_mod.ToolRegistry = .init(tools_mod.builtinRegistry());
    defer registry.deinit(gpa);
    const plugin_names = [_][]const u8{
        "lua__file-tools__read",        "lua__file-tools__write",        "lua__file-tools__edit",
        "lua__search-tools__grep",      "lua__search-tools__glob",       "lua__path-tools__create_directory",
        "lua__path-tools__delete_path", "lua__git-tools__git_status",    "lua__git-tools__git_diff",
        "lua__git-tools__git_commit",   "lua__todo__todo_list",          "lua__todo__todo_add",
        "lua__todo__todo_done",         "lua__file-watcher__file_stats", "lua__hello-world__greet",
    };
    for (plugin_names) |name| {
        try registry.addPluginTool(gpa, .{
            .name = try gpa.dupe(u8, name),
            .description = try std.fmt.allocPrint(gpa, "Plugin tool {{hsep}} for {s}", .{name}),
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
        .{ .name = "mcp__chrome-devtools__click", .description = "Click element", .schema = .{ .properties = &.{} } },
    };

    // Tools array'i servis katmanıyla, OpenRouter'ın gerçekte aldığı biçimde üret.
    const tools_json = try tool_schema.buildAllToolsJson(gpa, &.{}, &mcp_tools, &registry, false, .completions);
    defer gpa.free(tools_json);

    // Full wire payload — writeRequestPayload applies no truncation. Include a
    // system message so OpenRouter's top-level cache_control is emitted.
    const system_blocks = try gpa.alloc(ai.ContentBlock, 1);
    system_blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "You are a helpful agent.") } };
    var system_msg: ai.ChatMessage = .{ .system = .{ .content = system_blocks } };
    defer system_msg.deinit(gpa);
    const views = [_]ai.MessageView{.{ .borrowed = &system_msg }};

    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "inclusionai/ling-3.0-flash:free", "session-abc", &views, tools_json, null, null, .openrouter, false, false);
    const body = payload.written();

    // Payload gerçekten JSON parse edilebilir olmalı (kırpılmamış, geçerli).
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);

    // 1. OpenRouter dialect'i: top-level cache_control + native session_id.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"cache_control\":{\"type\":\"ephemeral\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"session_id\":\"session-abc\"") != null);

    // 2. tools array'i tam ve kırpılmamış — üretilen byte'larla birebir aynı.
    const tools_str = try std.fmt.allocPrint(gpa, "\"tools\":{s}", .{tools_json});
    defer gpa.free(tools_str);
    try std.testing.expect(std.mem.indexOf(u8, body, tools_str) != null);
    try std.testing.expectEqual(@as(usize, tools_mod.builtinRegistry().len + plugin_names.len + mcp_tools.len), countWireTools(tools_json));

    // 3. tool_choice auto (tools varken) + stream true.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"auto\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
}

fn countWireTools(tools_json: []const u8) usize {
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, tools_json, idx, "\"type\":\"function\"")) |pos| {
        count += 1;
        idx = pos + 1;
    }
    return count;
}

test "ollama_cloud(minimal) vs openrouter dialect: identical tools array, only cache fields differ" {
    // Kullanıcının gözlemi: ollama_cloud üzerindeki temel bir model (gemma4:31b)
    // tool çağırabiliyor ama openrouter'daki ling-3.0-flash çağıramıyor. Dialect
    // farkının tools array'ini ETKİLEMEDİĞİNİ kanıtlar — ikisi de aynı `tools`
    // array'ini üretir; tek fark OpenRouter'ın eklediği cache_control /
    // prompt_cache_key alanlarıdır. Yani tool çağıramama sorunu dialect'ten
    // değil, modelin kendisinden gelir.
    const gpa = std.testing.allocator;

    // Aynı tool seti, her iki dialect için.
    var registry: tools_mod.ToolRegistry = .init(tools_mod.builtinRegistry());
    defer registry.deinit(gpa);
    try registry.addPluginTool(gpa, .{
        .name = try gpa.dupe(u8, "lua__file-tools__read"),
        .description = try gpa.dupe(u8, "Read a file"),
        .schema = .{ .properties = &.{.{ .name = "path", .kind = .string, .description = "A path", .required = true, .nullable = false }} },
        .run = undefined,
        .display = undefined,
    });
    const mcp_tools = [_]ai.McpToolSchema{
        .{ .name = "mcp__tavily__search", .description = "Web search", .schema = .{ .properties = &.{} } },
    };
    const tools_json = try tool_schema.buildAllToolsJson(gpa, &.{}, &mcp_tools, &registry, false, .completions);
    defer gpa.free(tools_json);

    const system_blocks = try gpa.alloc(ai.ContentBlock, 1);
    system_blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "You are a helpful agent.") } };
    var system_msg: ai.ChatMessage = .{ .system = .{ .content = system_blocks } };
    defer system_msg.deinit(gpa);
    const views = [_]ai.MessageView{.{ .borrowed = &system_msg }};

    // .minimal = ollama_cloud'ın çözümü; .openrouter = openrouter'ın çözümü.
    var payload_min: std.Io.Writer.Allocating = .init(gpa);
    defer payload_min.deinit();
    try writeRequestPayload(gpa, &payload_min.writer, "gemma4:31b", "", &views, tools_json, null, null, .minimal, false, false);
    const body_min = payload_min.written();

    var payload_or: std.Io.Writer.Allocating = .init(gpa);
    defer payload_or.deinit();
    try writeRequestPayload(gpa, &payload_or.writer, "inclusionai/ling-3.0-flash:free", "sess", &views, tools_json, null, null, .openrouter, false, false);
    const body_or = payload_or.written();

    // 1. tools array'i İKİSİNDE DE aynıdır — byte-for-byte.
    const tools_needle = try std.fmt.allocPrint(gpa, "\"tools\":{s}", .{tools_json});
    defer gpa.free(tools_needle);
    try std.testing.expect(std.mem.indexOf(u8, body_min, tools_needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, body_or, tools_needle) != null);
    try std.testing.expectEqual(countWireTools(tools_json), tools_mod.builtinRegistry().len + 1 + mcp_tools.len);

    // 2. tool_choice auto her ikisinde de var (tools varken).
    try std.testing.expect(std.mem.indexOf(u8, body_min, "\"tool_choice\":\"auto\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_or, "\"tool_choice\":\"auto\"") != null);

    // 3. TEK fark: openrouter, top-level cache_control + native session_id
    //    ekler; minimal bunları hiç üretmez.
    try std.testing.expect(std.mem.indexOf(u8, body_min, "cache_control") == null);
    try std.testing.expect(std.mem.indexOf(u8, body_min, "session_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, body_min, "prompt_cache_key") == null);
    try std.testing.expect(std.mem.indexOf(u8, body_or, "\"cache_control\":{\"type\":\"ephemeral\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_or, "\"session_id\":\"sess\"") != null);
}

// Ollama (or any generic gateway) can serve Qwen models; the provider resolves to
// `.minimal`, not `.dashscope`. The Qwen gate must still normalize the history so
// Qwen does not reject multiple/late system messages. This mirrors running a
// `qwen2.5:7b` model through a local ollama instance.
test "writeRequestPayload normalizes system messages for qwen model on minimal dialect" {
    const gpa = std.testing.allocator;

    const sys1 = ai.ChatMessage{ .system = .{ .content = try gpa.dupe(ai.ContentBlock, &.{ai.ContentBlock{ .text = .{ .text = try gpa.dupe(u8, "SYS_A") } }}) } };
    const user = ai.ChatMessage{ .user = .{ .content = try gpa.dupe(ai.ContentBlock, &.{ai.ContentBlock{ .text = .{ .text = try gpa.dupe(u8, "hi") } }}) } };
    const sys2 = ai.ChatMessage{ .system = .{ .content = try gpa.dupe(ai.ContentBlock, &.{ai.ContentBlock{ .text = .{ .text = try gpa.dupe(u8, "SYS_B") } }}) } };
    var chat_messages = [_]ai.ChatMessage{ sys1, user, sys2 };
    var views: [chat_messages.len]ai.MessageView = undefined;
    for (&chat_messages, 0..) |*m, i| views[i] = ai.MessageView{ .borrowed = @ptrCast(@constCast(m)) };
    const messages = views[0..];
    defer {
        for (&chat_messages) |*m| m.deinit(gpa);
    }

    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    // minimal dialect + a qwen* model id → normalization must fire.
    try writeRequestPayload(gpa, &payload.writer, "qwen2.5:7b", "", messages, "[]", null, null, .minimal, false, false);
    const body = payload.written();

    // Exactly one system message, and it is the merged leading block.
    const sys_count = countSubstring(body, "\"role\":\"system\"");
    try std.testing.expectEqual(@as(usize, 1), sys_count);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "SYS_A") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "SYS_B") != null);
    // system must precede the user message.
    const sys_idx = std.mem.indexOf(u8, body, "\"role\":\"system\"").?;
    const user_idx = std.mem.indexOf(u8, body, "\"role\":\"user\"").?;
    try std.testing.expect(sys_idx < user_idx);
}

// The exact scenario from vllm-project/vllm#41114: a vLLM server hosting a
// HuggingFace-style `Qwen/Qwen3-32B` id. The provider is a generic
// OpenAI-compatible URL (resolves to `.minimal`), and the model id starts with
// a capitalized `Qwen/` — so both the history normalization AND the effort clip
// must key off the case-insensitive model-id gate, not the dialect alone.
test "writeRequestPayload normalizes system messages and clips effort for vLLM-style Qwen id" {
    const gpa = std.testing.allocator;

    const sys1 = ai.ChatMessage{ .system = .{ .content = try gpa.dupe(ai.ContentBlock, &.{ai.ContentBlock{ .text = .{ .text = try gpa.dupe(u8, "SYS_A") } }}) } };
    const user = ai.ChatMessage{ .user = .{ .content = try gpa.dupe(ai.ContentBlock, &.{ai.ContentBlock{ .text = .{ .text = try gpa.dupe(u8, "hi") } }}) } };
    const sys2 = ai.ChatMessage{ .system = .{ .content = try gpa.dupe(ai.ContentBlock, &.{ai.ContentBlock{ .text = .{ .text = try gpa.dupe(u8, "SYS_B") } }}) } };
    var chat_messages = [_]ai.ChatMessage{ sys1, user, sys2 };
    var views: [chat_messages.len]ai.MessageView = undefined;
    for (&chat_messages, 0..) |*m, i| views[i] = ai.MessageView{ .borrowed = @ptrCast(@constCast(m)) };
    const messages = views[0..];
    defer {
        for (&chat_messages) |*m| m.deinit(gpa);
    }

    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequestPayload(gpa, &payload.writer, "Qwen/Qwen3-32B", "", messages, "[]", ai.Reasoning{ .effort = .high }, null, .minimal, false, false);
    const body = payload.written();

    // Single leading merged system block. The join newline is JSON-escaped in
    // the payload, so assert the escaped two-character `\n` sequence.
    try std.testing.expectEqual(@as(usize, 1), countSubstring(body, "\"role\":\"system\""));
    try std.testing.expect(std.mem.indexOf(u8, body, "SYS_A\\nSYS_B") != null);
    // `high` is invalid for Qwen — clipped to `medium` even on the `.minimal`
    // dialect (dialect passes it through, the model layer clips it).
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"medium\"") != null);
}

fn countSubstring(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < haystack.len) : (i += 1) {
        if (std.mem.indexOf(u8, haystack[i..], needle)) |idx| {
            count += 1;
            i += idx;
        } else break;
    }
    return count;
}

test "readStream accepts an SSE line larger than the transfer buffer" {
    const gpa = std.testing.allocator;
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);

    try stream.appendSlice(gpa, "data: {\"choices\":[{\"delta\":{\"content\":\"");
    var index: u32 = 0;
    while (index < transfer_buffer_bytes + 512) : (index += 1) try stream.append(gpa, 'a');
    try stream.appendSlice(gpa, "\"}}]}\n");
    try stream.appendSlice(gpa, "data: [DONE]\n");

    var reader: std.Io.Reader = .fixed(stream.items);
    var tool_call_seq: u64 = 0;
    var response = try stream_parser.readStream(gpa, &reader, ai.streamNoop(), &tool_call_seq, 16, "test-model");
    defer response.deinit(gpa);
    try std.testing.expectEqual(@as(usize, transfer_buffer_bytes + 512), response.assistant.assistant.content[0].text.text.len);
}

test "readStream skips empty data lines without crashing" {
    const gpa = std.testing.allocator;
    // An empty `data:` keep-alive used to hit `parseStreamChunk`'s non-empty
    // assertion and panic the TUI mid-turn.
    const stream =
        "data:\n" ++
        "data: \n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n" ++
        "data: [DONE]\n";
    var reader: std.Io.Reader = .fixed(stream);
    var tool_call_seq: u64 = 0;
    var response = try stream_parser.readStream(gpa, &reader, ai.streamNoop(), &tool_call_seq, 16, "test-model");
    defer response.deinit(gpa);
    try std.testing.expectEqualStrings("hi", response.assistant.assistant.content[0].text.text);
}

test "parse streaming content tolerates null prelude" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const change = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"finish_reason":null,"index":0,"delta":{"role":"assistant","content":null}}]}
    , &content, &reasoning, &stream);

    try std.testing.expect(change.empty());
    try std.testing.expectEqual(@as(usize, 0), content.items.len);
    try std.testing.expectEqual(@as(usize, 0), reasoning.items.len);
}

test "parse streaming tool deltas as they arrive" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const Seen = struct {
        name: []const u8 = "",
        arguments: []const u8 = "",
        index: u32 = 0,

        fn onToolDelta(ctx: *@This(), delta: ai.ToolDelta) anyerror!void {
            ctx.index = delta.index;
            ctx.name = delta.name;
            ctx.arguments = delta.arguments;
        }
        fn noopBytes(_: *@This(), _: []const u8) anyerror!void {}
        fn noopVoid(_: *@This()) anyerror!void {}
    };
    var seen: Seen = .{};
    const observer: ai.StreamObserver(Seen) = .{
        .ctx = &seen,
        .on_content = Seen.noopBytes,
        .on_reasoning = Seen.noopBytes,
        .on_tool_delta = Seen.onToolDelta,
        .on_delta_end = Seen.noopVoid,
    };

    try stream_parser.processStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash","arguments":"{\"command\":\"zig"}}]}}]}
    , &content, &reasoning, &stream, observer);
    try stream_parser.processStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":" build\"}"}}]}}]}
    , &content, &reasoning, &stream, observer);

    try std.testing.expectEqualStrings("bash", seen.name);
    try std.testing.expectEqualStrings("{\"command\":\"zig build\"}", seen.arguments);
    try std.testing.expectEqual(@as(u32, 0), seen.index);
}

test "parse streaming tool deltas tolerate key reorder" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    try stream_parser.processStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"function":{"name":"bash","arguments":"{}"},"id":"call_1","index":0}]}}]}
    , &content, &reasoning, &stream, ai.streamNoop());

    try std.testing.expectEqual(@as(usize, 1), stream.builders.items.len);
    try std.testing.expectEqualStrings("call_1", stream.builders.items[0].id.items);
    try std.testing.expectEqualStrings("bash", stream.builders.items[0].name.items);
    try std.testing.expectEqualStrings("{}", stream.builders.items[0].arguments.items);
}

test "parse streaming tool deltas batches render notification per event" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const Seen = struct {
        tool_delta_count: u32 = 0,
        render_count: u32 = 0,

        fn onToolDelta(ctx: *@This(), _: ai.ToolDelta) anyerror!void {
            ctx.tool_delta_count += 1;
        }

        fn onDeltaEnd(ctx: *@This()) anyerror!void {
            ctx.render_count += 1;
        }
        fn noopBytes(_: *@This(), _: []const u8) anyerror!void {}
    };
    var seen: Seen = .{};
    const observer: ai.StreamObserver(Seen) = .{
        .ctx = &seen,
        .on_content = Seen.noopBytes,
        .on_reasoning = Seen.noopBytes,
        .on_tool_delta = Seen.onToolDelta,
        .on_delta_end = Seen.onDeltaEnd,
    };

    try stream_parser.processStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash","arguments":"{\"command\":\"pwd\"}"}},{"index":1,"id":"call_2","function":{"name":"bash","arguments":"{\"command\":\"ls\"}"}}]}}]}
    , &content, &reasoning, &stream, observer);

    try std.testing.expectEqual(@as(u32, 2), seen.tool_delta_count);
    try std.testing.expectEqual(@as(u32, 1), seen.render_count);
}

test "parse streaming reasoning deltas as they arrive" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const Seen = struct {
        gpa: std.mem.Allocator,
        reasoning: std.ArrayList(u8) = .empty,

        fn deinit(self: *@This()) void {
            self.reasoning.deinit(self.gpa);
        }

        fn onReasoning(ctx: *@This(), delta: []const u8) anyerror!void {
            try ctx.reasoning.appendSlice(ctx.gpa, delta);
        }
        fn noopBytes(_: *@This(), _: []const u8) anyerror!void {}
        fn noopToolDelta(_: *@This(), _: ai.ToolDelta) anyerror!void {}
        fn noopVoid(_: *@This()) anyerror!void {}
    };
    var seen: Seen = .{ .gpa = gpa };
    defer seen.deinit();
    const observer: ai.StreamObserver(Seen) = .{
        .ctx = &seen,
        .on_content = Seen.noopBytes,
        .on_reasoning = Seen.onReasoning,
        .on_tool_delta = Seen.noopToolDelta,
        .on_delta_end = Seen.noopVoid,
    };

    try stream_parser.processStreamChunk(gpa,
        \\{"choices":[{"delta":{"reasoning_content":"checking output"}}]}
    , &content, &reasoning, &stream, observer);

    try std.testing.expectEqualStrings("checking output", seen.reasoning.items);
    try std.testing.expectEqualStrings("checking output", reasoning.items);
}

test "parse streaming content deltas as they arrive" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const Seen = struct {
        gpa: std.mem.Allocator,
        content: std.ArrayList(u8) = .empty,

        fn deinit(self: *@This()) void {
            self.content.deinit(self.gpa);
        }

        fn onContent(ctx: *@This(), delta: []const u8) anyerror!void {
            try ctx.content.appendSlice(ctx.gpa, delta);
        }
        fn noopBytes(_: *@This(), _: []const u8) anyerror!void {}
        fn noopToolDelta(_: *@This(), _: ai.ToolDelta) anyerror!void {}
        fn noopVoid(_: *@This()) anyerror!void {}
    };
    var seen: Seen = .{ .gpa = gpa };
    defer seen.deinit();
    const observer: ai.StreamObserver(Seen) = .{
        .ctx = &seen,
        .on_content = Seen.onContent,
        .on_reasoning = Seen.noopBytes,
        .on_tool_delta = Seen.noopToolDelta,
        .on_delta_end = Seen.noopVoid,
    };

    try stream_parser.processStreamChunk(gpa,
        \\{"choices":[{"delta":{"content":"hel"}}]}
    , &content, &reasoning, &stream, observer);
    try stream_parser.processStreamChunk(gpa,
        \\{"choices":[{"delta":{"content":"lo"}}]}
    , &content, &reasoning, &stream, observer);

    try std.testing.expectEqualStrings("hello", seen.content.items);
    try std.testing.expectEqualStrings("hello", content.items);
}

test "parse streaming usage chunk" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const change = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[],"usage":{"prompt_tokens":1200,"completion_tokens":340,"total_tokens":1540}}
    , &content, &reasoning, &stream);

    try std.testing.expect(change.usage != null);
    try std.testing.expectEqual(@as(u32, 1200), change.usage.?.input_tokens);
    try std.testing.expectEqual(@as(u32, 340), change.usage.?.output_tokens);
    try std.testing.expectEqual(@as(u32, 1540), change.usage.?.total_tokens);
}

test "parse streaming usage chunk captures cached and reasoning token details" {
    // The chat-completions parser must populate the same cached/reasoning
    // breakdown the Responses API parser does, so both wire dialects report
    // `ai.Usage` consistently (mirrors the openai-compatible provider's
    // `prompt_tokens_details.cached_tokens` / `completion_tokens_details.reasoning_tokens`).
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const change = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[],"usage":{"prompt_tokens":2000,"prompt_tokens_details":{"cached_tokens":1500},"completion_tokens":420,"completion_tokens_details":{"reasoning_tokens":256},"total_tokens":2420}}
    , &content, &reasoning, &stream);

    try std.testing.expect(change.usage != null);
    try std.testing.expectEqual(@as(u32, 2000), change.usage.?.input_tokens);
    try std.testing.expectEqual(@as(u32, 1500), change.usage.?.cached_input_tokens);
    try std.testing.expectEqual(@as(u32, 420), change.usage.?.output_tokens);
    try std.testing.expectEqual(@as(u32, 256), change.usage.?.reasoning_tokens);
    try std.testing.expectEqual(@as(u32, 2420), change.usage.?.total_tokens);
}

test "content chunk carries null usage" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const change = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"content":"hi"}}],"usage":null}
    , &content, &reasoning, &stream);

    try std.testing.expect(change.usage == null);
}

test "parse streaming usage tolerates null token details sub-objects" {
    // Some providers send `prompt_tokens_details: null` / `completion_tokens_details: null`
    // (the openai-compatible schema marks them nullish). The parser must not
    // fail the whole stream on a null nested object.
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    const change = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[],"usage":{"prompt_tokens":100,"prompt_tokens_details":null,"completion_tokens":50,"completion_tokens_details":null,"total_tokens":150}}
    , &content, &reasoning, &stream);

    try std.testing.expect(change.usage != null);
    try std.testing.expectEqual(@as(u32, 100), change.usage.?.input_tokens);
    try std.testing.expectEqual(@as(u32, 0), change.usage.?.cached_input_tokens);
    try std.testing.expectEqual(@as(u32, 0), change.usage.?.reasoning_tokens);
    try std.testing.expectEqual(@as(u32, 150), change.usage.?.total_tokens);
}

test "parse streaming tool calls deduplicates repeated tool names (bashbash fix)" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    _ = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash","arguments":"{\"command\":"}}]}}]}
    , &content, &reasoning, &stream);

    // Second chunk repeats function.name: "bash" while sending argument continuation
    _ = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash","arguments":"\"ls\"}"}}]}}]}
    , &content, &reasoning, &stream);

    try std.testing.expectEqual(@as(usize, 1), stream.builders.items.len);
    try std.testing.expectEqualStrings("bash", stream.builders.items[0].name.items);
    try std.testing.expectEqualStrings("call_1", stream.builders.items[0].id.items);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", stream.builders.items[0].arguments.items);
}

test "sanitizeToolArguments strips markdown backticks and falls back to empty object" {
    try std.testing.expectEqualStrings("{}", stream_parser.sanitizeToolArguments(""));
    try std.testing.expectEqualStrings("{}", stream_parser.sanitizeToolArguments("   "));
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", stream_parser.sanitizeToolArguments("{\"command\":\"ls\"}"));
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", stream_parser.sanitizeToolArguments("```json\n{\"command\":\"ls\"}\n```"));
    try std.testing.expectEqualStrings("{}", stream_parser.sanitizeToolArguments("not a json string"));
}

test "parse streaming parallel tool calls with reused index does not concatenate names" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    // Provider emits two parallel tool calls in separate SSE events, both
    // with index 0 (a known misbehaviour from some OpenAI-compatible providers).
    _ = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"mcp__server__get_architecture","arguments":"{}"}}]}}]}
    , &content, &reasoning, &stream);

    _ = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_2","function":{"name":"mcp__server__search_graph","arguments":"{}"}}]}}]}
    , &content, &reasoning, &stream);

    // Queue mechanism forks the second tool call into a new physical slot.
    // Both tool calls are preserved — names must NOT be concatenated.
    try std.testing.expectEqual(@as(usize, 2), stream.builders.items.len);
    try std.testing.expectEqualStrings("mcp__server__get_architecture", stream.builders.items[0].name.items);
    try std.testing.expectEqualStrings("call_1", stream.builders.items[0].id.items);
    try std.testing.expectEqualStrings("mcp__server__search_graph", stream.builders.items[1].name.items);
    try std.testing.expectEqualStrings("call_2", stream.builders.items[1].id.items);
}

test "parse streaming duplicate ID across indices merges into one builder" {
    const gpa = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var reasoning: std.ArrayList(u8) = .empty;
    defer reasoning.deinit(gpa);
    var stream: stream_parser.ToolCallStream = .{};
    defer stream.deinit(gpa);

    // Qwen/DashScope echoes the same tool-call ID across multiple indices.
    // The first chunk carries the name at index 0; a duplicate arrives at
    // index 1 with the same ID. Arguments follow on index 0.
    _ = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash","arguments":""}}]}}]}
    , &content, &reasoning, &stream);

    _ = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_1","function":{"name":"bash","arguments":""}}]}}]}
    , &content, &reasoning, &stream);

    _ = try stream_parser.parseStreamChunk(gpa,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"command\":\"ls\"}"}}]}}]}
    , &content, &reasoning, &stream);

    // Index 1 is remapped to the same physical slot as index 0.
    // Only one builder should carry the name + arguments.
    var with_args: usize = 0;
    for (stream.builders.items) |b| {
        if (b.name.items.len > 0 and b.arguments.items.len > 0) with_args += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), with_args);
    try std.testing.expectEqualStrings("bash", stream.builders.items[0].name.items);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", stream.builders.items[0].arguments.items);
}

// ── Retry / backoff ───────────────────────────────────────────────────────

test "parseRetryAfterSeconds extracts integer seconds from a head" {
    try std.testing.expectEqual(@as(?u64, 5), parseRetryAfterSeconds("HTTP/1.1 429 Too Many Requests\r\nRetry-After: 5\r\nContent-Length: 0\r\n\r\n"));
    // Header name is case-insensitive.
    try std.testing.expectEqual(@as(?u64, 2), parseRetryAfterSeconds("HTTP/1.1 503 Service Unavailable\r\nretry-after: 2\r\n\r\n"));
    // Missing header → null.
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfterSeconds("HTTP/1.1 200 OK\r\n\r\n"));
    // HTTP-date value → null (integer seconds only, per scope).
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfterSeconds("HTTP/1.1 429 Too Many Requests\r\nRetry-After: Wed, 21 Oct 2026 07:28:00 GMT\r\n\r\n"));
}

test "retryDelayMs honors Retry-After over backoff and caps exponential growth" {
    const gpa = std.testing.allocator;
    var client: Client = undefined;
    try client.init(gpa, std.testing.io, .{
        .base_url = "http://127.0.0.1:1/v1",
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
    });
    defer client.deinit();

    // Retry-After wins regardless of the attempt count.
    try std.testing.expectEqual(@as(u64, 3000), client.retryDelayMs(0, 3));
    try std.testing.expectEqual(@as(u64, 3000), client.retryDelayMs(5, 3));
    // Without the header: base * 2^attempt, capped at 8000ms.
    try std.testing.expectEqual(@as(u64, 500), client.retryDelayMs(0, null));
    try std.testing.expectEqual(@as(u64, 1000), client.retryDelayMs(1, null));
    try std.testing.expectEqual(@as(u64, 2000), client.retryDelayMs(2, null));
    try std.testing.expectEqual(@as(u64, 4000), client.retryDelayMs(3, null));
    try std.testing.expectEqual(@as(u64, 8000), client.retryDelayMs(4, null)); // capped
    try std.testing.expectEqual(@as(u64, 8000), client.retryDelayMs(10, null)); // stays capped
}

/// Minimal blocking HTTP server for retry tests. Serves exactly one canned
/// response per accepted connection (each `Connection: close`), on a
/// dedicated thread. The ephemeral port comes from `server.socket.address`.
const MockRetryServer = struct {
    const Response = struct {
        status: std.http.Status,
        retry_after: ?[]const u8 = null,
        body: []const u8 = "",
    };

    io: std.Io,
    server: std.Io.net.Server,
    responses: []const Response,
    connection_count: std.atomic.Value(u32) = .init(0),

    fn init(io: std.Io, responses: []const Response) !MockRetryServer {
        const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        const server = try addr.listen(io, .{ .reuse_address = true });
        return .{ .io = io, .server = server, .responses = responses };
    }

    fn deinit(self: *MockRetryServer) void {
        self.server.deinit(self.io);
    }

    fn port(self: *const MockRetryServer) u16 {
        return self.server.socket.address.ip4.port;
    }

    fn serve(self: *MockRetryServer) void {
        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        for (self.responses) |resp| {
            var stream = self.server.accept(self.io) catch return;
            defer stream.close(self.io);
            _ = self.connection_count.fetchAdd(1, .monotonic);
            var reader = stream.reader(self.io, &read_buf);
            var writer = stream.writer(self.io, &write_buf);
            var http_server = std.http.Server.init(&reader.interface, &writer.interface);
            var request = http_server.receiveHead() catch return;
            var extra: [1]std.http.Header = undefined;
            const headers: []const std.http.Header = if (resp.retry_after) |ra| blk: {
                extra[0] = .{ .name = "Retry-After", .value = ra };
                break :blk &extra;
            } else &.{};
            request.respond(resp.body, .{
                .status = resp.status,
                .keep_alive = false,
                .extra_headers = headers,
            }) catch return;
        }
    }
};

const ok_sse_body =
    "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n" ++
    "data: [DONE]\n";

fn retryTestClient(gpa: std.mem.Allocator, io: std.Io, port: u16) !Client {
    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v1", .{port});
    errdefer gpa.free(base_url);
    var client: Client = undefined;
    try client.init(gpa, io, .{
        .base_url = base_url,
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
        // No sleeping between retries in tests.
        .retry_base_delay_ms = 0,
    });
    // `init` deep-copies the config (including the request URL) — the
    // temporary base_url is not retained, so free it.
    gpa.free(base_url);
    return client;
}

test "prompt retries a transient 503 and succeeds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var server = try MockRetryServer.init(io, &.{
        .{ .status = .service_unavailable },
        .{ .status = .ok, .body = ok_sse_body },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockRetryServer.serve, .{&server});
    defer thread.join();

    var client = try retryTestClient(gpa, io, server.port());
    defer client.deinit();

    var turn = try client.prompt(&.{}, ai.streamNoop());
    defer turn.deinit(gpa);
    // Two connections: the failed 503 attempt plus the successful retry.
    try std.testing.expectEqual(@as(u32, 2), server.connection_count.load(.monotonic));
    try std.testing.expectEqualStrings("hi", turn.assistant.assistant.content[0].text.text);
}

test "prompt retries a 429 and honors Retry-After" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var server = try MockRetryServer.init(io, &.{
        .{ .status = .too_many_requests, .retry_after = "0" },
        .{ .status = .ok, .body = ok_sse_body },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockRetryServer.serve, .{&server});
    defer thread.join();

    var client = try retryTestClient(gpa, io, server.port());
    defer client.deinit();

    var turn = try client.prompt(&.{}, ai.streamNoop());
    defer turn.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), server.connection_count.load(.monotonic));
    try std.testing.expectEqualStrings("hi", turn.assistant.assistant.content[0].text.text);
}

test "headPhaseFailure maps transient connection drops to a retryable error" {
    // The head phase is idempotent — the model has produced nothing and no
    // tool has run — so connection/read drops must surface as the retryable
    // `error.ConnectionFailed`, while protocol-level rejects pass through as
    // permanent. (A TCP-level drop can't be simulated over `std.testing.io`,
    // whose event loop never wakes a blocked head read on peer-close, so the
    // mapping is tested directly.)
    const gpa = std.testing.allocator;
    var client: Client = undefined;
    try client.init(gpa, std.testing.io, .{
        .base_url = "http://127.0.0.1:1/v1",
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
    });
    defer client.deinit();

    try std.testing.expectEqual(error.ConnectionFailed, client.headPhaseFailure(error.ReadFailed));
    try std.testing.expectEqual(error.ConnectionFailed, client.headPhaseFailure(error.WriteFailed));
    try std.testing.expectEqual(error.ConnectionFailed, client.headPhaseFailure(error.EndOfStream));
    try std.testing.expectEqual(error.ConnectionFailed, client.headPhaseFailure(error.ConnectionRefused));
    try std.testing.expectEqual(error.ConnectionFailed, client.headPhaseFailure(error.ConnectionResetByPeer));
    try std.testing.expectEqual(error.ConnectionFailed, client.headPhaseFailure(error.ConnectionTimedOut));
    try std.testing.expectEqual(error.ConnectionFailed, client.headPhaseFailure(error.BrokenPipe));
    // Stale keep-alive: the server closed an idle connection and the 0-byte
    // head read surfaces as error.HttpConnectionClosing (std.http), not one of
    // the socket errors above — still a transient head-phase drop.
    try std.testing.expectEqual(error.ConnectionFailed, client.headPhaseFailure(error.HttpConnectionClosing));
    // Windows surfaces connection-refused as NTSTATUS 0xc0000236 (error.Unexpected),
    // which is treated as a transient connect/read drop in the head phase.
    try std.testing.expectEqual(error.ConnectionFailed, client.headPhaseFailure(error.Unexpected));
    // Permanent failures are returned unchanged.
    try std.testing.expectEqual(error.HttpClientError, client.headPhaseFailure(error.HttpClientError));
    try std.testing.expectEqual(error.HttpHeadersInvalid, client.headPhaseFailure(error.HttpHeadersInvalid));
}

test "prompt does not retry a permanent 4xx" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var server = try MockRetryServer.init(io, &.{
        .{ .status = .bad_request },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockRetryServer.serve, .{&server});
    defer thread.join();

    var client = try retryTestClient(gpa, io, server.port());
    defer client.deinit();

    try std.testing.expectError(error.HttpClientError, client.prompt(&.{}, ai.streamNoop()));
    // Exactly one attempt — 4xx is permanent.
    try std.testing.expectEqual(@as(u32, 1), server.connection_count.load(.monotonic));
}

test "prompt with max_retries 0 makes a single attempt on a transient 5xx" {
    // Kill-switch regression: max_retries = 0 must reproduce the legacy
    // single-attempt behavior even for otherwise-retryable 5xx errors.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var server = try MockRetryServer.init(io, &.{
        .{ .status = .internal_server_error },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockRetryServer.serve, .{&server});
    defer thread.join();

    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v1", .{server.port()});
    defer gpa.free(base_url);
    var client: Client = undefined;
    try client.init(gpa, io, .{
        .base_url = base_url,
        .api_key = "test-key",
        .model = "test-model",
        .tools = &.{},
        .mcp_tools = &.{},
        .max_retries = 0,
    });
    defer client.deinit();

    try std.testing.expectError(error.HttpServerError, client.prompt(&.{}, ai.streamNoop()));
    try std.testing.expectEqual(@as(u32, 1), server.connection_count.load(.monotonic));
}

test "prompt exhausts retries on a persistent 5xx" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Default max_retries = 2 → three attempts total.
    var server = try MockRetryServer.init(io, &.{
        .{ .status = .internal_server_error },
        .{ .status = .internal_server_error },
        .{ .status = .internal_server_error },
    });
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, MockRetryServer.serve, .{&server});
    defer thread.join();

    var client = try retryTestClient(gpa, io, server.port());
    defer client.deinit();

    try std.testing.expectError(error.HttpServerError, client.prompt(&.{}, ai.streamNoop()));
    try std.testing.expectEqual(@as(u32, 3), server.connection_count.load(.monotonic));
}
