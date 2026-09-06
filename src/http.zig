//! Shared HTTP-client plumbing: buffer sizes, wire media types, and status
//! predicates common to every outbound HTTP path (AI wire clients, the
//! models.dev registry fetcher, MCP, the bash-safety classifier, Codex OAuth).
//! Leaf — imports nothing outside this repo except `os.zig` (comptime OS tag)
//! and std — so any src/ module can consume it;
//! lib/ modules keep their own consts (INV-LEAF-1 forbids lib → src imports).

const std = @import("std");
const os = @import("os.zig");

/// std.http.Client head-phase buffers, sized for provider/matcher traffic.
pub const redirect_buffer_bytes: u32 = 8192;
pub const transfer_buffer_bytes: u32 = 4096;
pub const body_buffer_bytes: u32 = 4096;

/// Wire media types. RFC-fixed values — they can never change.
pub const content_type_json = "application/json";
pub const media_type_event_stream = "text/event-stream";

/// RFC 6750 authorization scheme prefix for `Authorization` header values.
pub const bearer_prefix = "Bearer ";

/// Log truncation budgets shared by the AI wire clients: request/response
/// bodies are logged head-first at `log_head_bytes_max`, with up to
/// `log_tail_bytes_max` recovered past the cut when a tools array is found.
pub const log_head_bytes_max: usize = 12 * 1024;
pub const log_tail_bytes_max: usize = 4096;

/// True for the 2xx success band.
pub fn isSuccess(status: u16) bool {
    return status >= 200 and status < 300;
}

/// Pure head-cut for log lines: bodies at or under `log_head_bytes_max` pass
/// through verbatim (no allocation, no marker); longer bodies are cut at the
/// limit. The tail-aware variant in `openai_compatible.logBytes` handles the
/// richer tools-recovery case and shares the same budgets.
pub fn logBytesHead(bytes: []const u8) []const u8 {
    if (bytes.len <= log_head_bytes_max) return bytes;
    return bytes[0..log_head_bytes_max];
}

test "isSuccess accepts exactly the 2xx band" {
    try std.testing.expect(!isSuccess(199));
    try std.testing.expect(isSuccess(200));
    try std.testing.expect(isSuccess(299));
    try std.testing.expect(!isSuccess(300));
}

test "logBytesHead passes short bodies and cuts at the shared limit" {
    const short = "hello";
    try std.testing.expectEqualStrings(short, logBytesHead(short));
    var long: [log_head_bytes_max + 1]u8 = undefined;
    @memset(&long, 'x');
    const cut = logBytesHead(&long);
    try std.testing.expectEqual(log_head_bytes_max, cut.len);
    try std.testing.expect(cut.ptr == long[0..].ptr);
}

// ── Retry / transient-failure helpers ────────────────────────────────────
//
// Shared by the chat-completions client (`ai/openai_compatible.zig`) and the
// Responses client (`ai/responses_core.zig`) so both wire dialects retry
// transient head-phase failures with identical delays.

/// Upper bound on ALL retry delays (exponential backoff and server-sent
/// `Retry-After`), in milliseconds. An untrusted `Retry-After` header must
/// not be able to stall the worker for an effectively unbounded duration.
pub const retry_max_delay_ms: u64 = 8000;

/// Head-phase statuses worth retrying: 429 (rate limit) and 5xx (server).
pub fn isRetryableHeadStatus(status: u16) bool {
    return status == 429 or status >= 500;
}

/// Extract an integer-seconds `Retry-After` value from a raw HTTP head.
/// HTTP-date formatted values are out of scope and yield null (gateways
/// practically send integer seconds). Pure — tested directly.
pub fn parseRetryAfterSeconds(head_bytes: []const u8) ?u64 {
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

/// Delay before a retry: the server's `Retry-After` (integer seconds) when
/// present — capped at `retry_max_delay_ms` — otherwise exponential backoff
/// `base * 2^attempt`, capped. Pure — tested directly.
pub fn retryDelayMs(base_ms: u64, attempt: u32, retry_after_secs: ?u64) u64 {
    if (retry_after_secs) |secs| {
        // Saturating: an absurd header value must not wrap and stall.
        return @min(secs *| std.time.ms_per_s, retry_max_delay_ms);
    }
    // Exponential backoff `base * 2^attempt`, saturating so an absurd
    // base can't wrap, then capped.
    var backoff = base_ms;
    var i: u32 = 0;
    while (i < attempt) : (i += 1) backoff *|= 2;
    return @min(backoff, retry_max_delay_ms);
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
pub fn headPhaseFailure(err: anyerror) anyerror {
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

/// Set socket-level send/recv timeouts on a std.http connection so a server
/// that accepts the connection but then stalls — no response head, or a
/// mid-body stop — fails instead of blocking the worker forever.
/// Best-effort: a failure to setsockopt is not fatal.
///
/// Windows: `Io.Threaded` opens sockets through the AFD driver, so socket
/// handles are not ws2_32 SOCKETs and setsockopt always fails
/// (WSAENOTSOCK) — skip it rather than warn on every request.
pub fn setSocketTimeout(conn: *std.http.Client.Connection, seconds: u32) void {
    if (os.is_windows) return;
    const tv: std.posix.timeval = .{
        .sec = @intCast(seconds),
        .usec = 0,
    };
    std.posix.setsockopt(
        conn.stream_reader.stream.socket.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&tv),
    ) catch {};
    std.posix.setsockopt(
        conn.stream_reader.stream.socket.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDTIMEO,
        std.mem.asBytes(&tv),
    ) catch {};
}

/// Pull a human-readable message out of an error response body. Handles the
/// common OpenAI-ish shapes — `{"error":{"message":...}}`, `{"error":"..."}`,
/// `{"message":...}` — and falls back to the raw body (capped) when the body
/// isn't JSON or has none of those. Returned slice is owned by `gpa`.
pub fn extractErrorMessage(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    const fallback = trimmed[0..@min(trimmed.len, 600)];

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

test "isRetryableHeadStatus accepts 429 and 5xx only" {
    try std.testing.expect(isRetryableHeadStatus(429));
    try std.testing.expect(isRetryableHeadStatus(500));
    try std.testing.expect(isRetryableHeadStatus(503));
    try std.testing.expect(!isRetryableHeadStatus(400));
    try std.testing.expect(!isRetryableHeadStatus(401));
    try std.testing.expect(!isRetryableHeadStatus(200));
}

test "parseRetryAfterSeconds extracts integer seconds from a head" {
    try std.testing.expectEqual(@as(?u64, 5), parseRetryAfterSeconds("HTTP/1.1 429 Too Many Requests\r\nRetry-After: 5\r\nContent-Length: 0\r\n\r\n"));
    // Header name is case-insensitive.
    try std.testing.expectEqual(@as(?u64, 2), parseRetryAfterSeconds("HTTP/1.1 503 Service Unavailable\r\nretry-after: 2\r\n\r\n"));
    // Missing header → null.
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfterSeconds("HTTP/1.1 200 OK\r\n\r\n"));
    // HTTP-date value → null (integer seconds only, per scope).
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfterSeconds("HTTP/1.1 429 Too Many Requests\r\nRetry-After: Wed, 21 Oct 2026 07:28:00 GMT\r\n\r\n"));
    // Negative / non-integer values → null.
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfterSeconds("HTTP/1.1 429 Too Many Requests\r\nRetry-After: -5\r\n\r\n"));
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfterSeconds("HTTP/1.1 429 Too Many Requests\r\nRetry-After: 1.5\r\n\r\n"));
}

test "retryDelayMs honors Retry-After and caps exponential growth" {
    // Retry-After wins regardless of the attempt count.
    try std.testing.expectEqual(@as(u64, 3000), retryDelayMs(500, 0, 3));
    try std.testing.expectEqual(@as(u64, 3000), retryDelayMs(500, 5, 3));
    // An absurd Retry-After is capped at retry_max_delay_ms — never unbounded.
    try std.testing.expectEqual(retry_max_delay_ms, retryDelayMs(500, 0, 3600));
    try std.testing.expectEqual(retry_max_delay_ms, retryDelayMs(500, 0, 999_999_999));
    // Without the header: base * 2^attempt, capped.
    try std.testing.expectEqual(@as(u64, 500), retryDelayMs(500, 0, null));
    try std.testing.expectEqual(@as(u64, 1000), retryDelayMs(500, 1, null));
    try std.testing.expectEqual(@as(u64, 2000), retryDelayMs(500, 2, null));
    try std.testing.expectEqual(@as(u64, 4000), retryDelayMs(500, 3, null));
    try std.testing.expectEqual(@as(u64, 8000), retryDelayMs(500, 4, null)); // capped
    try std.testing.expectEqual(@as(u64, 8000), retryDelayMs(500, 10, null)); // stays capped
    // A huge base can't wrap.
    try std.testing.expectEqual(retry_max_delay_ms, retryDelayMs(std.math.maxInt(u64), 10, null));
}

test "headPhaseFailure maps transient connection drops to a retryable error" {
    try std.testing.expectEqual(error.ConnectionFailed, headPhaseFailure(error.ReadFailed));
    try std.testing.expectEqual(error.ConnectionFailed, headPhaseFailure(error.WriteFailed));
    try std.testing.expectEqual(error.ConnectionFailed, headPhaseFailure(error.EndOfStream));
    try std.testing.expectEqual(error.ConnectionFailed, headPhaseFailure(error.ConnectionRefused));
    try std.testing.expectEqual(error.ConnectionFailed, headPhaseFailure(error.ConnectionResetByPeer));
    try std.testing.expectEqual(error.ConnectionFailed, headPhaseFailure(error.ConnectionTimedOut));
    try std.testing.expectEqual(error.ConnectionFailed, headPhaseFailure(error.BrokenPipe));
    try std.testing.expectEqual(error.ConnectionFailed, headPhaseFailure(error.HttpConnectionClosing));
    try std.testing.expectEqual(error.ConnectionFailed, headPhaseFailure(error.HttpRequestTruncated));
    try std.testing.expectEqual(error.ConnectionFailed, headPhaseFailure(error.Unexpected));
    // Permanent failures are returned unchanged.
    try std.testing.expectEqual(error.HttpClientError, headPhaseFailure(error.HttpClientError));
    try std.testing.expectEqual(error.HttpHeadersInvalid, headPhaseFailure(error.HttpHeadersInvalid));
}

test "extractErrorMessage pulls the nested message, plain error, or raw fallback" {
    const gpa = std.testing.allocator;

    // OpenCode Zen's shape: {"type":"error","error":{"type":...,"message":...}}
    const zen = try extractErrorMessage(gpa, "{\"type\":\"error\",\"error\":{\"type\":\"ModelError\",\"message\":\"Free promotion has ended.\"}}");
    defer gpa.free(zen);
    try std.testing.expectEqualStrings("Free promotion has ended.", zen);

    // `error` as a bare string.
    const plain = try extractErrorMessage(gpa, "{\"error\":\"invalid api key\"}");
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("invalid api key", plain);

    // Top-level `message`.
    const top = try extractErrorMessage(gpa, "{\"message\":\"something broke\"}");
    defer gpa.free(top);
    try std.testing.expectEqualStrings("something broke", top);

    // Non-JSON body falls back to the raw text.
    const raw = try extractErrorMessage(gpa, "  upstream timeout  ");
    defer gpa.free(raw);
    try std.testing.expectEqualStrings("upstream timeout", raw);

    // Empty body.
    const empty = try extractErrorMessage(gpa, "  ");
    defer gpa.free(empty);
    try std.testing.expectEqualStrings("(empty response body)", empty);
}
