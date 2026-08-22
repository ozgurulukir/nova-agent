//! Core types for the session layer.
//!
//! Pure type definitions with no references to Session, SessionManager,
//! SessionWriter, or the database — the leaves of the dependency graph.

const std = @import("std");
const bounded_queue = @import("bounded_queue");
const db = @import("../db.zig");

const assert = std.debug.assert;

/// Length of an entry id in bytes.
pub const entry_id_len: u32 = 8;
/// Length of a session id in bytes.
pub const session_id_len: u32 = 32;
/// Upper bound on entries in a single branch path. Far above any real
/// session; exists so projection loops are bounded (tigerstyle).
pub const path_entries_max: u32 = 1 << 20;

pub const EntryId = struct {
    bytes: [entry_id_len]u8,

    pub fn fromSlice(value: []const u8) Error!EntryId {
        if (value.len != entry_id_len) return error.BadEntryId;
        var bytes: [entry_id_len]u8 = undefined;
        @memcpy(bytes[0..], value);
        const result = EntryId{ .bytes = bytes };
        // Two-way assertion: round-trip preserves the value.
        assert(std.mem.eql(u8, value, result.slice()));
        return result;
    }

    pub fn slice(self: *const EntryId) []const u8 {
        return self.bytes[0..];
    }
};

pub const SessionId = struct {
    bytes: [session_id_len]u8,

    pub fn fromSlice(value: []const u8) Error!SessionId {
        if (value.len != session_id_len) return error.BadSessionId;
        var bytes: [session_id_len]u8 = undefined;
        @memcpy(bytes[0..], value);
        const result = SessionId{ .bytes = bytes };
        // Two-way assertion: round-trip preserves the value.
        assert(std.mem.eql(u8, value, result.slice()));
        return result;
    }

    pub fn slice(self: *const SessionId) []const u8 {
        return self.bytes[0..];
    }
};

pub const Error = db.Error || error{
    BadSessionId,
    BadEntryId,
    MissingSession,
    MissingEntry,
    UnsupportedEntryKind,
    CorruptPayload,
    OutOfMemory,
    WriteFailed,
    SystemResources,
    Unexpected,
    LockedMemoryLimitExceeded,
    ThreadQuotaExceeded,
    QueueFull,
    Canceled,
    InvalidPath,
};

/// A single entry queued for the background writer thread.
pub const QueuedEntry = struct {
    kind: []const u8,
    role: ?[]u8,
    payload_json: []u8,
    title_candidate: ?[]u8 = null,

    pub fn deinit(self: *QueuedEntry, gpa: std.mem.Allocator) void {
        if (self.role) |role| gpa.free(role);
        gpa.free(self.payload_json);
        if (self.title_candidate) |title| gpa.free(title);
        self.* = undefined;
    }
};

/// Fixed-capacity queue of entries pending write.
pub const EntryQueue = bounded_queue.BoundedQueue(QueuedEntry);

pub const CreateOptions = struct {
    id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    model_provider: ?[]const u8 = null,
    model_id: ?[]const u8 = null,
};

pub const SessionSummary = struct {
    id: []u8,
    title: ?[]u8,
    cwd: []u8,
    created_at_ms: i64,
    updated_at_ms: i64,
    /// Last entry id in the branch's leaf chain. Branded as EntryId
    /// (fixed-size [entry_id_len]u8) instead of a loose []u8 so the
    /// type system enforces the length invariant the DB layer relies
    /// on. null when the branch has no entries yet.
    leaf_entry_id: ?EntryId,
    /// Model provider and ID used in this session. null for sessions
    /// created before schema v4 or when model info is not available.
    model_provider: ?[]u8,
    model_id: ?[]u8,
    /// Session-scoped reasoning effort label ("default", "high", …).
    /// null for sessions created before schema v5 or when the user never
    /// overrode the effort — resume then falls back to config/default.
    reasoning_effort: ?[]u8,

    pub fn deinit(self: *SessionSummary, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        if (self.title) |title| gpa.free(title);
        gpa.free(self.cwd);
        if (self.model_provider) |mp| gpa.free(mp);
        if (self.model_id) |mid| gpa.free(mid);
        if (self.reasoning_effort) |effort| gpa.free(effort);
        self.* = undefined;
    }
};

/// A single entry in the session tree, loaded from the database.
pub const EntryRecord = struct {
    id: [entry_id_len]u8,
    parent_id: ?[entry_id_len]u8,
    kind: []u8,
    role: ?[]u8,
    payload_json: []u8,
    created_at_ms: i64,
    /// The git snapshot commit bound to this entry (null if none). Drives the
    /// timeline ✦ marker and code-state restore.
    snapshot: ?[]u8 = null,

    pub fn deinit(self: *EntryRecord, gpa: std.mem.Allocator) void {
        // Assert pre-free invariant: self-owned fields are non-null.
        assert(self.kind.len > 0);
        gpa.free(self.kind);
        if (self.role) |role| gpa.free(role);
        assert(self.payload_json.len > 0);
        gpa.free(self.payload_json);
        if (self.snapshot) |s| gpa.free(s);
        // Poison after free to catch use-after-free.
        self.* = undefined;
    }
};

/// Fixed-size reference to a user message entry on the active path — the
/// `/undo` walk's result. Carries only the two ids the caller needs, so the
/// lookup stays allocation-free (no payload ownership).
pub const UserEntryRef = struct {
    id: EntryId,
    parent_id: ?EntryId,
};

/// A compaction boundary found while walking a branch.
pub const CompactionBoundary = struct {
    /// Index in the path array of the compaction entry itself.
    summary_index: u32,
    /// Index of the first entry that should be emitted (the "first kept" id).
    first_kept_index: u32,
};

/// Result of computing where to cut the branch for compaction.
pub const CompactionCut = struct {
    first_kept_id: EntryId,
    prefix_text: []u8,
};

pub const EntryKind = enum {
    user,
    assistant,
    assistant_empty,
    tool,
    branch_summary,
    session_info,
    checkpoint,
    other,
};

pub const EntrySummary = union(enum) {
    user: struct { text: []u8 },
    assistant: struct { text: []u8 },
    assistant_empty: struct { text: []u8 },
    tool: struct { text: []u8, failed: bool },
    branch_summary: struct { text: []u8 },
    session_info: struct { text: []u8 },
    checkpoint: struct { text: []u8 },
    other: struct { text: []u8 },

    pub fn deinit(self: *EntrySummary, gpa: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |info| gpa.free(info.text),
        }
        self.* = undefined;
    }

    pub fn text(self: EntrySummary) []u8 {
        return switch (self) {
            inline else => |info| info.text,
        };
    }

    pub fn kind(self: EntrySummary) EntryKind {
        return switch (self) {
            .user => .user,
            .assistant => .assistant,
            .assistant_empty => .assistant_empty,
            .tool => .tool,
            .branch_summary => .branch_summary,
            .session_info => .session_info,
            .checkpoint => .checkpoint,
            .other => .other,
        };
    }

    pub fn toolFailed(self: EntrySummary) bool {
        return switch (self) {
            .tool => |t| t.failed,
            else => false,
        };
    }
};
