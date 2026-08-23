//! Background summarizer state for the Agent.
//!
//! At most one summary is ever in flight, so a single result slot plus an
//! atomic state is all the synchronization needed between the worker thread
//! (start/apply) and the summarizer thread (produce). The summarizer never
//! touches live history or the session — only the dedicated client and its
//! own allocations — so the boundary is clean.

const std = @import("std");
const log = std.log.scoped(.agent);

const ai = @import("../ai.zig");
const compaction = @import("../context/compaction.zig");
const session_mod = @import("../session.zig");
const request_limiter_mod = @import("../request_limiter.zig");

const assert = std.debug.assert;

pub const Compactor = @This();

state: std.atomic.Value(State) = .init(.idle),
thread: ?std.Thread = null,
job: ?Job = null,
result: ?Result = null,

const State = enum(u8) { idle, running, ready, failed };

/// Self-contained input handed to the summarizer thread: the rendered
/// prefix to summarize and the entry the kept history resumes from.
const Job = struct {
    gpa: std.mem.Allocator,
    /// The shared `std.Io` — needed for the limiter's I/O-condition wait on
    /// the summarizer thread (the client owns no exposed io handle).
    io: std.Io,
    client: ai.LanguageModel,
    /// The app-wide concurrency limiter, borrowed (null = no gate). Keeps the
    /// summarizer request inside the same at-most-`permits` provider budget as
    /// turn and naming requests.
    limiter: ?*request_limiter_mod.RequestLimiter,
    first_kept_id: session_mod.EntryId,
    prefix_text: []u8,
};

const Result = struct {
    first_kept_id: session_mod.EntryId,
    stored_summary: []u8,
};

pub fn stateIs(self: *const Compactor, expected: State) bool {
    assert(@intFromEnum(expected) <= @intFromEnum(State.failed));
    return self.state.load(.acquire) == expected;
}

/// Body of the summarizer thread: produce the stored summary from the job's
/// frozen prefix, publish it, and flip the state. Acquire/release on `state`
/// makes the result visible to the worker once it observes `.ready`.
pub fn runThread(compactor: *Compactor) void {
    assert(compactor.stateIs(.running));
    const job = compactor.job.?;
    defer job.gpa.free(job.prefix_text);
    const stored = produceStoredSummary(job) catch |err| {
        log.warn("compaction summarize failed: {s}", .{@errorName(err)});
        compactor.state.store(.failed, .release);
        return;
    };
    compactor.result = .{ .first_kept_id = job.first_kept_id, .stored_summary = stored };
    compactor.state.store(.ready, .release);
}

fn produceStoredSummary(job: Job) ![]u8 {
    // Validate input before summarization.
    assert(job.prefix_text.len > 0);
    const summary = if (job.limiter) |limiter| blk: {
        try limiter.acquire(job.io);
        defer limiter.release(job.io);
        break :blk try compaction.summarize(job.gpa, job.client, job.prefix_text);
    } else try compaction.summarize(job.gpa, job.client, job.prefix_text);
    defer job.gpa.free(summary);
    if (summary.len == 0) return error.EmptySummary;
    return compaction.buildStoredSummary(job.gpa, summary);
}

test "returnsTrue_whenStateMatchesExpected" {
    // Arrange
    const compactor: Compactor = .{};

    // Act
    const is_idle = compactor.stateIs(.idle);

    // Assert
    try std.testing.expect(is_idle);
}

test "returnsFalse_whenStateDiffersFromExpected" {
    // Arrange
    const compactor: Compactor = .{};

    // Act & Assert
    try std.testing.expect(!compactor.stateIs(.running));
    try std.testing.expect(!compactor.stateIs(.ready));
    try std.testing.expect(!compactor.stateIs(.failed));
}

test "returnsTrue_afterAtomicStateTransitions" {
    // Arrange
    var compactor: Compactor = .{};

    // Act & Assert: transition to running
    compactor.state.store(.running, .release);
    try std.testing.expect(compactor.stateIs(.running));
    try std.testing.expect(!compactor.stateIs(.idle));

    // Act & Assert: transition to ready
    compactor.state.store(.ready, .release);
    try std.testing.expect(compactor.stateIs(.ready));
    try std.testing.expect(!compactor.stateIs(.running));

    // Act & Assert: transition to failed
    compactor.state.store(.failed, .release);
    try std.testing.expect(compactor.stateIs(.failed));
    try std.testing.expect(!compactor.stateIs(.ready));
}
