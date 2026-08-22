//! Background session writer thread.
//!
//! `SessionWriter` owns a dedicated thread that drains a bounded queue of
//! entries and persists them to sqlite, decoupling the hot agent turn path
//! from disk I/O. Extracted from `session.zig` to keep the parent file
//! focused on `SessionManager` and `Session` (the read/append API).

const std = @import("std");
const log = std.log.scoped(.session);

const ai = @import("../ai.zig");

const session_type = @import("types.zig");
const serialize = @import("serialize.zig");

const entry_id_len = session_type.entry_id_len;
const Error = session_type.Error;
const EntryQueue = session_type.EntryQueue;
const QueuedEntry = session_type.QueuedEntry;
const EntryRecord = session_type.EntryRecord;
const CompactionCut = session_type.CompactionCut;

const assert = std.debug.assert;

const session_mod = @import("../session.zig");
const SessionManager = session_mod.SessionManager;
const Session = session_mod.Session;

pub const SessionWriter = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    manager: SessionManager,
    session: Session,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    queue: []QueuedEntry,
    entry_queue: EntryQueue = .{},
    stopping: bool = false,
    title_written: bool = false,
    thread: ?std.Thread = null,

    pub const queue_capacity_default: u32 = 256;

    pub fn initDefault(target: *SessionWriter, gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, cwd: []const u8) Error!void {
        return initDefaultWithCapacity(target, gpa, io, home_dir, cwd, queue_capacity_default);
    }

    pub fn initResumeDefault(target: *SessionWriter, gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, session_id: []const u8) Error!void {
        return initResumeDefaultWithCapacity(target, gpa, io, home_dir, session_id, queue_capacity_default);
    }

    pub fn initDefaultWithCapacity(target: *SessionWriter, gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, cwd: []const u8, capacity: u32) Error!void {
        assert(home_dir.len > 0);
        assert(cwd.len > 0);
        assert(capacity > 0);
        var manager = try SessionManager.initDefault(gpa, io, home_dir);
        errdefer manager.deinit();
        const session = try manager.create(cwd, .{});
        try target.initWithSession(gpa, io, manager, session, capacity);
    }

    pub fn initResumeDefaultWithCapacity(target: *SessionWriter, gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, session_id: []const u8, capacity: u32) Error!void {
        assert(home_dir.len > 0);
        assert(session_id.len > 0);
        assert(capacity > 0);
        var manager = try SessionManager.initDefault(gpa, io, home_dir);
        errdefer manager.deinit();
        const session = try manager.@"resume"(session_id);
        try target.initWithSession(gpa, io, manager, session, capacity);
    }

    fn initWithSession(target: *SessionWriter, gpa: std.mem.Allocator, io: std.Io, manager: SessionManager, session: Session, capacity: u32) Error!void {
        const queue = try gpa.alloc(QueuedEntry, capacity);
        errdefer gpa.free(queue);
        target.* = .{
            .gpa = gpa,
            .io = io,
            .manager = manager,
            .session = session,
            .queue = queue,
        };
        target.session.manager = &target.manager;
        target.title_written = try target.session.hasTitle();
        target.thread = try std.Thread.spawn(.{}, runWriter, .{target});
    }

    pub fn deinit(self: *SessionWriter) void {
        if (self.mutex.lock(self.io)) |_| {
            self.stopping = true;
            self.condition.signal(self.io);
            self.mutex.unlock(self.io);
        } else |_| {
            // Lock failed (canceled) — signal/cleanup will happen via thread join.
        }
        if (self.thread) |thread| thread.join();
        while (self.entry_queue.pop(self.queue)) |entry| {
            var owned = entry;
            owned.deinit(self.gpa);
        }
        self.gpa.free(self.queue);
        self.manager.deinit();
        self.* = undefined;
    }

    pub fn append(self: *SessionWriter, message: ai.ChatMessage) Error!void {
        if (message.role() == .system) return;
        const payload = try serialize.messageToJson(self.gpa, message);
        errdefer self.gpa.free(payload);
        const role = try self.gpa.dupe(u8, message.role().label());
        errdefer self.gpa.free(role);
        const title_candidate = if (message.role() == .user)
            try serialize.titleFromUserMessage(self.gpa, message.text())
        else
            null;
        errdefer if (title_candidate) |title| self.gpa.free(title);
        try self.enqueue(.{ .kind = "message", .role = role, .payload_json = payload, .title_candidate = title_candidate });
    }

    /// Enqueue a compaction boundary for the background writer. Mirrors
    /// `append`: builds the payload and hands it to the writer thread. The
    /// branch on which it lands is whatever leaf is current when the writer
    /// drains it; a stale boundary is ignored at projection time, so no
    /// quiesce is needed here.
    pub fn appendCompaction(self: *SessionWriter, first_kept_id: []const u8, summary: []const u8) Error!void {
        assert(first_kept_id.len == entry_id_len);
        assert(summary.len > 0);
        const payload = try serialize.compactionToJson(self.gpa, first_kept_id, summary);
        errdefer self.gpa.free(payload);
        try self.enqueue(.{ .kind = "compaction", .role = null, .payload_json = payload });
    }

    /// Bind a git snapshot id to the current leaf entry, race-free. Flushes
    /// queued writes first so the leaf reflects the entries the turn just wrote,
    /// then annotates that entry. No-op if the session has no leaf yet.
    pub fn setLeafSnapshot(self: *SessionWriter, sha: []const u8) Error!void {
        self.quiesce();
        defer self.restart() catch |err| log.warn("session writer restart failed: {s}", .{@errorName(err)});
        const leaf_id = self.session.leaf() orelse return;
        return self.session.setSnapshot(leaf_id, sha);
    }

    /// Race-free `Session.snapshotAt`: the git snapshot bound to the active
    /// conversation position (nearest entry at/above the leaf). Caller owns it.
    pub fn snapshotAt(self: *SessionWriter, gpa: std.mem.Allocator) Error!?[]u8 {
        self.quiesce();
        defer self.restart() catch |err| log.warn("session writer restart failed: {s}", .{@errorName(err)});
        return self.session.snapshotAt(gpa);
    }

    /// Save a prompt to the session's prompt history, race-free. A plain
    /// append — no dedup (the table is a per-session log; only the UI ring
    /// dedups).
    pub fn savePromptHistory(self: *SessionWriter, prompt: []const u8) Error!void {
        self.quiesce();
        defer self.restart() catch |err| log.warn("session writer restart failed: {s}", .{@errorName(err)});
        try self.session.savePromptHistory(prompt);
    }

    /// Load the prompt history for this session, race-free. Caller owns the
    /// slice and each string.
    pub fn loadPromptHistory(self: *SessionWriter, gpa: std.mem.Allocator) Error![][]u8 {
        self.quiesce();
        defer self.restart() catch |err| log.warn("session writer restart failed: {s}", .{@errorName(err)});
        return self.session.loadPromptHistory(gpa);
    }

    /// Drop the newest prompt-history row, race-free. `/undo`'s second half:
    /// keeps `[0]` tracking the active branch across chained undos. Idempotent.
    pub fn deleteNewestPromptHistory(self: *SessionWriter) Error!void {
        self.quiesce();
        defer self.restart() catch |err| log.warn("session writer restart failed: {s}", .{@errorName(err)});
        try self.session.deleteNewestPromptHistory();
    }

    /// Race-free `Session.lastUserEntry`: the newest user message entry on the
    /// active path, or null when the session holds none. Allocation-free.
    pub fn lastUserEntry(self: *SessionWriter) Error!?session_type.UserEntryRef {
        self.quiesce();
        defer self.restart() catch |err| log.warn("session writer restart failed: {s}", .{@errorName(err)});
        return self.session.lastUserEntry();
    }

    /// Load the whole session tree, race-free. Stops the background writer so
    /// the read has exclusive access to the connection, then restarts it.
    pub fn entries(self: *SessionWriter, gpa: std.mem.Allocator) Error![]EntryRecord {
        self.quiesce();
        defer self.restart() catch |err| log.warn("session writer restart failed: {s}", .{@errorName(err)});
        return self.session.entries(gpa);
    }

    /// Reconstruct the active-path messages (leaf→root), race-free. Used after
    /// `navigate` to rehydrate the agent's conversation from the new branch.
    pub fn messages(self: *SessionWriter, gpa: std.mem.Allocator) Error![]ai.ChatMessage {
        self.quiesce();
        defer self.restart() catch |err| log.warn("session writer restart failed: {s}", .{@errorName(err)});
        return self.session.messages(gpa);
    }

    /// Race-free `Session.compactionCut`: flushes queued writes so the cut is
    /// computed against the persisted tree, then restarts the writer.
    pub fn compactionCut(self: *SessionWriter, gpa: std.mem.Allocator, keep_recent_tokens: u32) Error!?CompactionCut {
        self.quiesce();
        defer self.restart() catch |err| log.warn("session writer restart failed: {s}", .{@errorName(err)});
        return self.session.compactionCut(gpa, keep_recent_tokens);
    }

    /// Move the session leaf to `entry_id` (branch switch, no summary),
    /// race-free with the background writer. The next appended message becomes
    /// a child of `entry_id`, forming a new branch.
    pub fn navigate(self: *SessionWriter, entry_id: []const u8) Error!void {
        self.quiesce();
        defer self.restart() catch |err| log.warn("session writer restart failed: {s}", .{@errorName(err)});
        try self.session.branch(entry_id, null, null);
    }

    /// Update the model provider, ID, and reasoning effort for the current
    /// session. Called when the model selection changes during a session.
    pub fn updateModel(self: *SessionWriter, provider: []const u8, model_id: []const u8, effort_label: ?[]const u8) Error!void {
        self.quiesce();
        defer self.restart() catch |err| log.warn("session writer restart failed: {s}", .{@errorName(err)});
        try self.session.updateModel(provider, model_id, effort_label);
    }

    pub fn leaf(self: *const SessionWriter) ?[]const u8 {
        return self.session.leaf();
    }

    /// Stop the writer thread and flush any queued entries synchronously,
    /// leaving the calling thread sole owner of the sqlite connection. Pair
    /// with `restart`. Queued entries are written (not dropped) so an
    /// in-flight assistant turn isn't lost.
    fn quiesce(self: *SessionWriter) void {
        if (self.mutex.lock(self.io)) |_| {
            self.stopping = true;
            self.condition.signal(self.io);
            self.mutex.unlock(self.io);
        } else |_| {
            // Lock failed (canceled) — stop flag will be observed on next poll.
        }
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        while (self.entry_queue.pop(self.queue)) |entry| {
            var owned = entry;
            defer owned.deinit(self.gpa);
            writeQueuedEntry(self, &owned) catch |err| log.warn("session writer flush failed: {s}", .{@errorName(err)});
        }
    }

    fn restart(self: *SessionWriter) Error!void {
        assert(self.thread == null);
        self.stopping = false;
        self.thread = try std.Thread.spawn(.{}, runWriter, .{self});
    }

    fn enqueue(self: *SessionWriter, entry: QueuedEntry) Error!void {
        try self.mutex.lock(self.io);
        if (!self.entry_queue.push(self.queue, entry)) {
            self.mutex.unlock(self.io);
            return error.QueueFull;
        }
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
    }
};

fn runWriter(writer: *SessionWriter) void {
    while (true) {
        if (takeQueuedEntry(writer)) |entry| {
            var owned = entry;
            defer owned.deinit(writer.gpa);
            writeQueuedEntry(writer, &owned) catch continue;
        } else {
            // Queue is empty: wait for a signal rather than busy-yielding.
            // We hold the lock around the check+wait so we can't miss a
            // signal that lands between the check and the wait.
            writer.mutex.lock(writer.io) catch return;
            while (writer.entry_queue.empty() and !writer.stopping) {
                writer.condition.waitUncancelable(writer.io, &writer.mutex);
            }
            const done = writer.stopping and writer.entry_queue.empty();
            writer.mutex.unlock(writer.io);
            if (done) return;
        }
    }
}

fn writeQueuedEntry(writer: *SessionWriter, entry: *const QueuedEntry) Error!void {
    assert(entry.kind.len > 0);
    assert(entry.payload_json.len > 0);

    const previous_leaf = writer.session.leaf_entry_id;
    try writer.manager.connection.exec("begin immediate");
    errdefer {
        writer.manager.connection.exec("rollback") catch {};
        writer.session.leaf_entry_id = previous_leaf;
    }

    var id: [entry_id_len]u8 = undefined;
    try writer.session.appendPayload(entry.kind, entry.role, entry.payload_json, &id);
    const should_write_title = !writer.title_written and entry.title_candidate != null;
    if (should_write_title) try writer.session.setTitle(entry.title_candidate.?);

    try writer.manager.connection.exec("commit");
    if (should_write_title) writer.title_written = true;
}

fn takeQueuedEntry(writer: *SessionWriter) ?QueuedEntry {
    writer.mutex.lock(writer.io) catch return null;
    defer writer.mutex.unlock(writer.io);
    return writer.entry_queue.pop(writer.queue);
}
