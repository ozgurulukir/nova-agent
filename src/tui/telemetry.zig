//! Token velocity EMA + context capacity meter formatting. Pure and zero-alloc.
//!
//! Extracted to its own file (not `metrics.zig`, which is dedicated to render
//! metrics: row counting, cache sizing) so the telemetry engine has a distinct
//! home. `TelemetryTracker` is a pure value type — it holds EMA state and
//! formats strings into caller-provided fixed buffers; it has no byte counter
//! (the caller accumulates `streamed_bytes` and feeds `streamed_bytes / 4`).
//!
//! Wired into `src/root.zig`'s test block (`_ = @import("tui/telemetry.zig")`)
//! so its inline tests run (AGENTS.md test-runner quirk).

const std = @import("std");

/// Samples closer together than this are skipped so a burst of per-frame
/// calls doesn't over-smooth the velocity gauge.
const velocity_min_sample_interval_ns: i128 = 200 * std.time.ns_per_ms;
/// Context-meter bar block count; █/░ are 3-byte UTF-8, hence the ×3 scratch
/// buffer in `formatContextBar`.
const bar_blocks: usize = 10;

/// Context-meter severity. The caller resolves this to a palette color; the
/// meter itself stays pure data (color knowledge lives in `style.zig`).
pub const MeterLevel = enum { normal, warn, alert };

pub const TelemetryTracker = struct {
    last_sample_ns: i128 = 0,
    last_token_count: usize = 0,
    current_tokens_per_sec: f64 = 0.0,

    /// Update the exponential-moving-average token rate from the total token
    /// count seen so far. Samples closer than 200 ms apart are skipped (the
    /// last sample time/count is not advanced), so a burst of per-frame
    /// `streamed_bytes / 4` calls doesn't over-smooth the gauge. The `-|`
    /// underflow guard makes a total reset (e.g. `streamed_bytes = 0` on a
    /// turn end) safe.
    pub fn updateVelocity(self: *TelemetryTracker, now_ns: i128, total_tokens: usize, alpha: f64) void {
        const delta_ns = now_ns - self.last_sample_ns;
        if (delta_ns < velocity_min_sample_interval_ns) return;
        const delta_tokens = total_tokens -| self.last_token_count;
        const delta_sec = @as(f64, @floatFromInt(delta_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        const instant_rate = @as(f64, @floatFromInt(delta_tokens)) / delta_sec;
        if (self.current_tokens_per_sec == 0.0) {
            self.current_tokens_per_sec = instant_rate;
        } else {
            self.current_tokens_per_sec = (alpha * instant_rate) + ((1.0 - alpha) * self.current_tokens_per_sec);
        }
        self.last_sample_ns = now_ns;
        self.last_token_count = total_tokens;
    }

    /// Format the 10-block context capacity bar plus `(used/max)` and the
    /// percentage, resolving the severity against the warn/alert thresholds.
    /// Returns an empty text with `.normal` level when `max_tokens == 0` or the
    /// buffer is too small.
    pub fn formatContextBar(used_tokens: usize, max_tokens: usize, warn: f64, alert: f64, buf: *[64]u8) struct { text: []const u8, level: MeterLevel } {
        if (max_tokens == 0) return .{ .text = "", .level = .normal };
        const fraction = @as(f64, @floatFromInt(used_tokens)) / @as(f64, @floatFromInt(max_tokens));
        const clamped = @min(@max(fraction, 0.0), 1.0);
        const filled_blocks: usize = @intFromFloat(clamped * @as(f64, @floatFromInt(bar_blocks)));
        const used_k = @as(f64, @floatFromInt(used_tokens)) / 1000.0;
        const max_k = @as(f64, @floatFromInt(max_tokens)) / 1000.0;
        const percent: usize = @intFromFloat(clamped * 100.0);
        const level: MeterLevel = if (clamped >= alert) .alert else if (clamped >= warn) .warn else .normal;

        // Build the bar into a scratch buffer (█/░ are 3-byte UTF-8).
        var blocks: [bar_blocks * 3]u8 = undefined;
        var bn: usize = 0;
        for (0..bar_blocks) |i| {
            const block: []const u8 = if (i < filled_blocks) "█" else "░";
            @memcpy(blocks[bn..][0..3], block);
            bn += 3;
        }
        const text = std.fmt.bufPrint(buf, "[{s}] {d}% ({d:.1}k/{d:.0}k)", .{ blocks[0..bn], percent, used_k, max_k }) catch return .{ .text = "", .level = .normal };
        return .{ .text = text, .level = level };
    }

    /// Format the streaming velocity gauge. Returns an empty string when not
    /// streaming or the rate is below the display floor (0.1 tok/s).
    pub fn formatVelocity(rate: f64, is_streaming: bool, buf: *[32]u8) []const u8 {
        if (!is_streaming or rate <= 0.1) return "";
        return std.fmt.bufPrint(buf, "⚡ {d:.1} tok/s", .{rate}) catch "";
    }
};

test "telemetry EMA seeds on the first sample" {
    var t: TelemetryTracker = .{};
    // 1 s elapsed, 100 tokens → instant rate 100 tok/s, seeded directly.
    t.updateVelocity(1_000_000_000, 100, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), t.current_tokens_per_sec, 0.001);
    try std.testing.expectEqual(@as(i128, 1_000_000_000), t.last_sample_ns);
    try std.testing.expectEqual(@as(usize, 100), t.last_token_count);
}

test "telemetry EMA smooths subsequent samples" {
    var t: TelemetryTracker = .{};
    t.updateVelocity(1_000_000_000, 100, 0.5); // rate 100
    // 1 s later another 200 tokens → instant 200; EMA = 0.5*200 + 0.5*100 = 150.
    t.updateVelocity(2_000_000_000, 300, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 150.0), t.current_tokens_per_sec, 0.001);
}

test "telemetry -| underflow guard survives a total reset" {
    var t: TelemetryTracker = .{};
    t.updateVelocity(1_000_000_000, 100, 0.5); // rate 100
    // streamed_bytes reset to 0 on turn end → total drops below last count.
    // delta_tokens = 0 -| 100 = 0, so EMA = 0.5*0 + 0.5*100 = 50, no crash.
    t.updateVelocity(2_000_000_000, 0, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), t.current_tokens_per_sec, 0.001);
}

test "telemetry 200ms debounce skips close samples without advancing" {
    var t: TelemetryTracker = .{};
    t.updateVelocity(1_000_000_000, 100, 0.5); // seeds to 100
    // Only 100 ms later → debounced; rate and last-count stay unchanged.
    t.updateVelocity(1_000_100_000, 200, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), t.current_tokens_per_sec, 0.001);
    try std.testing.expectEqual(@as(usize, 100), t.last_token_count);
}

test "formatContextBar renders 0% at normal level" {
    var buf: [64]u8 = undefined;
    const meter = TelemetryTracker.formatContextBar(0, 128000, 0.70, 0.85, &buf);
    try std.testing.expectEqualStrings("[░░░░░░░░░░] 0% (0.0k/128k)", meter.text);
    try std.testing.expectEqual(MeterLevel.normal, meter.level);
}

test "formatContextBar renders 75% at warn level" {
    var buf: [64]u8 = undefined;
    // 0.75 * 128000 = 96000 — above the 0.70 warn threshold, below 0.85.
    const meter = TelemetryTracker.formatContextBar(96000, 128000, 0.70, 0.85, &buf);
    try std.testing.expectEqual(MeterLevel.warn, meter.level);
    // 7 filled blocks, 96.0k / 128k, 75%.
    try std.testing.expectEqualStrings("[███████░░░] 75% (96.0k/128k)", meter.text);
}

test "formatContextBar renders 100% at alert level" {
    var buf: [64]u8 = undefined;
    const meter = TelemetryTracker.formatContextBar(128000, 128000, 0.70, 0.85, &buf);
    try std.testing.expectEqual(MeterLevel.alert, meter.level);
    try std.testing.expectEqualStrings("[██████████] 100% (128.0k/128k)", meter.text);
}

test "formatContextBar returns empty when max_tokens is zero" {
    var buf: [64]u8 = undefined;
    const meter = TelemetryTracker.formatContextBar(100, 0, 0.70, 0.85, &buf);
    try std.testing.expectEqualStrings("", meter.text);
    try std.testing.expectEqual(MeterLevel.normal, meter.level);
}

test "formatVelocity hides when not streaming or rate is below the floor" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("", TelemetryTracker.formatVelocity(50.0, false, &buf));
    try std.testing.expectEqualStrings("", TelemetryTracker.formatVelocity(0.05, true, &buf));
    try std.testing.expectEqualStrings("⚡ 58.4 tok/s", TelemetryTracker.formatVelocity(58.4, true, &buf));
}
