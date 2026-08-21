//! Shared HTTP-client plumbing: buffer sizes, wire media types, and status
//! predicates common to every outbound HTTP path (AI wire clients, the
//! models.dev registry fetcher, MCP, the bash-safety classifier, Codex OAuth).
//! Pure leaf — imports nothing but std — so any src/ module can consume it;
//! lib/ modules keep their own consts (INV-LEAF-1 forbids lib → src imports).

const std = @import("std");

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
