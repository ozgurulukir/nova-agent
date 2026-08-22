const std = @import("std");

const ai = @import("ai.zig");
const compaction = @import("context/compaction.zig");
const db = @import("db.zig");

const assert = std.debug.assert;

const session_type = @import("session/types.zig");
const session_migration = @import("session/migration.zig");
const serialize = @import("session/serialize.zig");
const session_writer = @import("session/writer.zig");

pub const SessionWriter = session_writer.SessionWriter;

pub const entry_id_len = session_type.entry_id_len;
const session_id_len = session_type.session_id_len;
pub const path_entries_max = session_type.path_entries_max;
pub const EntryId = session_type.EntryId;
pub const SessionId = session_type.SessionId;
pub const Error = session_type.Error;
const EntryQueue = session_type.EntryQueue;
pub const QueuedEntry = session_type.QueuedEntry;
pub const CreateOptions = session_type.CreateOptions;
pub const SessionSummary = session_type.SessionSummary;
pub const EntryRecord = session_type.EntryRecord;
pub const UserEntryRef = session_type.UserEntryRef;
pub const CompactionBoundary = session_type.CompactionBoundary;
pub const CompactionCut = session_type.CompactionCut;
pub const EntryKind = session_type.EntryKind;
pub const EntrySummary = session_type.EntrySummary;

const schema_version = session_migration.schema_version;
const default_db_relative_path = session_migration.default_db_relative_path;
fn defaultPath(gpa: std.mem.Allocator, home_dir: []const u8) session_migration.Error![]u8 {
    return session_migration.defaultPath(gpa, home_dir);
}
fn migrate(connection: *db.Connection, io: std.Io) !void {
    try session_migration.migrate(connection, io);
}

pub const SessionManager = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    connection: db.Connection,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, path: []const u8) Error!SessionManager {
        assert(path.len > 0);
        // :memory: is a special SQLite path — no filesystem directory needed.
        if (!std.mem.eql(u8, path, ":memory:")) {
            const dirname = std.fs.path.dirname(path) orelse return error.InvalidPath;
            std.Io.Dir.createDirPath(.cwd(), io, dirname) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                error.FileNotFound,
                error.NotDir,
                error.BadPathName,
                => return error.InvalidPath,
                error.Canceled => return error.Canceled,
                else => return error.SystemResources,
            };
        }
        var connection = try db.Connection.open(path, .{});
        errdefer connection.close();
        try migrate(&connection, io);
        return .{ .gpa = gpa, .io = io, .connection = connection };
    }

    pub fn initDefault(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) Error!SessionManager {
        assert(home_dir.len > 0);
        const db_path = try defaultPath(gpa, home_dir);
        defer gpa.free(db_path);
        return init(gpa, io, db_path);
    }

    pub fn deinit(self: *SessionManager) void {
        self.connection.close();
        self.* = undefined;
    }

    pub fn create(self: *SessionManager, cwd: []const u8, options: CreateOptions) Error!Session {
        assert(cwd.len > 0);
        var id_buffer: [session_id_len]u8 = undefined;
        const session_id = if (options.id) |id| blk: {
            if (id.len != session_id_len) return error.BadSessionId;
            @memcpy(id_buffer[0..], id);
            break :blk id_buffer[0..];
        } else blk: {
            fillHex(self.io, &id_buffer);
            break :blk id_buffer[0..];
        };

        const timestamp_ms = nowMs(self.io);
        var statement = try self.connection.prepare("insert into sessions(id, title, cwd, created_at_ms, updated_at_ms, leaf_entry_id, model_provider, model_id) values (?, ?, ?, ?, ?, null, ?, ?)");
        defer statement.finalize();
        try statement.bindText(1, session_id);
        if (options.title) |title| {
            try statement.bindText(2, title);
        } else {
            try statement.bindNull(2);
        }
        try statement.bindText(3, cwd);
        try statement.bindInt(4, timestamp_ms);
        try statement.bindInt(5, timestamp_ms);
        if (options.model_provider) |mp| {
            try statement.bindText(6, mp);
        } else {
            try statement.bindNull(6);
        }
        if (options.model_id) |mid| {
            try statement.bindText(7, mid);
        } else {
            try statement.bindNull(7);
        }
        try expectDone(&statement);

        const session = Session{
            .manager = self,
            .id = .{ .bytes = id_buffer },
            .leaf_entry_id = null,
        };
        // Two-way assertion: created session round-trips through resume.
        assert(session.id.bytes.len == session_id_len);
        return session;
    }

    pub fn @"resume"(self: *SessionManager, session_id: []const u8) Error!Session {
        assert(session_id.len > 0);
        if (session_id.len != session_id_len) return error.BadSessionId;

        var statement = try self.connection.prepare("select leaf_entry_id from sessions where id = ?");
        defer statement.finalize();
        try statement.bindText(1, session_id);
        const row = (try statement.step()) orelse return error.MissingSession;

        const id = try SessionId.fromSlice(session_id);
        var leaf_buffer: [entry_id_len]u8 = undefined;
        const leaf = switch (row.columnType(0)) {
            .null => null,
            .text => blk: {
                const value = row.text(0);
                if (value.len != entry_id_len) return error.BadEntryId;
                @memcpy(leaf_buffer[0..], value);
                break :blk EntryId{ .bytes = leaf_buffer };
            },
            else => return error.BadEntryId,
        };
        return .{ .manager = self, .id = id, .leaf_entry_id = leaf };
    }

    pub fn list(self: *SessionManager, gpa: std.mem.Allocator, cwd: ?[]const u8) Error![]SessionSummary {
        const sql = if (cwd == null)
            "select id, title, cwd, created_at_ms, updated_at_ms, leaf_entry_id, model_provider, model_id, reasoning_effort from sessions where leaf_entry_id is not null order by updated_at_ms desc"
        else
            "select id, title, cwd, created_at_ms, updated_at_ms, leaf_entry_id, model_provider, model_id, reasoning_effort from sessions where cwd = ? and leaf_entry_id is not null order by updated_at_ms desc";
        var statement = try self.connection.prepare(sql);
        defer statement.finalize();
        if (cwd) |path| try statement.bindText(1, path);

        var summaries: std.ArrayList(SessionSummary) = .empty;
        errdefer {
            for (summaries.items) |*summary| summary.deinit(gpa);
            summaries.deinit(gpa);
        }
        while (try statement.step()) |row| {
            try summaries.append(gpa, try readSummary(gpa, &row));
        }
        return summaries.toOwnedSlice(gpa);
    }

    /// Find the most recently updated session for the given cwd. Returns null
    /// when no session exists for this directory. Caller owns the returned id.
    pub fn findLatest(self: *SessionManager, gpa: std.mem.Allocator, cwd: []const u8) Error!?[]u8 {
        var statement = try self.connection.prepare("select id from sessions where cwd = ? and leaf_entry_id is not null order by updated_at_ms desc limit 1");
        defer statement.finalize();
        try statement.bindText(1, cwd);
        const row = (try statement.step()) orelse return null;
        return try gpa.dupe(u8, row.text(0));
    }

    /// Delete a session and its entries (cascade delete handles entries via
    /// the `on delete cascade` foreign key). Safe to call on a non-existent
    /// id — the statement simply matches no rows.
    pub fn deleteSession(self: *SessionManager, session_id: []const u8) Error!void {
        var statement = try self.connection.prepare("delete from sessions where id = ?");
        defer statement.finalize();
        try statement.bindText(1, session_id);
        try expectDone(&statement);
    }

    /// Rename a session by id. The title is overwritten (or set if null).
    /// `new_title` must be non-empty — the caller validates.
    pub fn renameSession(self: *SessionManager, session_id: []const u8, new_title: []const u8) Error!void {
        assert(new_title.len > 0);
        var statement = try self.connection.prepare("update sessions set title = ?, updated_at_ms = ? where id = ?");
        defer statement.finalize();
        try statement.bindText(1, new_title);
        try statement.bindInt(2, nowMs(self.io));
        try statement.bindText(3, session_id);
        try expectDone(&statement);
    }
};
pub const Session = struct {
    manager: *SessionManager,
    id: SessionId,
    leaf_entry_id: ?EntryId,

    pub fn append(self: *Session, message: ai.ChatMessage, id_out: *[entry_id_len]u8) Error!void {
        fillHex(self.manager.io, id_out);
        const payload = try serialize.messageToJson(self.manager.gpa, message);
        defer self.manager.gpa.free(payload);
        try self.insertEntry(id_out, "message", message.role().label(), payload);
    }

    pub fn appendPayload(self: *Session, kind: []const u8, role: ?[]const u8, payload_json: []const u8, id_out: *[entry_id_len]u8) Error!void {
        assert(kind.len > 0);
        assert(payload_json.len > 0);
        fillHex(self.manager.io, id_out);
        try self.insertEntry(id_out, kind, role, payload_json);
    }

    pub fn info(self: *Session, title: []const u8, id_out: *[entry_id_len]u8) Error!void {
        assert(title.len > 0);
        fillHex(self.manager.io, id_out);
        const payload = try serialize.titleToJson(self.manager.gpa, title);
        defer self.manager.gpa.free(payload);
        try self.insertEntry(id_out, "session_info", null, payload);

        var statement = try self.manager.connection.prepare("update sessions set title = ?, updated_at_ms = ? where id = ?");
        defer statement.finalize();
        try statement.bindText(1, title);
        try statement.bindInt(2, nowMs(self.manager.io));
        try statement.bindText(3, self.id.slice());
        try expectDone(&statement);
    }

    pub fn branch(self: *Session, entry_id: []const u8, branch_summary: ?[]const u8, id_out: ?*[entry_id_len]u8) Error!void {
        assert(entry_id.len > 0);
        if (entry_id.len != entry_id_len) return error.BadEntryId;
        try self.requireEntry(entry_id);
        if (branch_summary) |text| {
            const out = id_out orelse return error.BadEntryId;
            fillHex(self.manager.io, out);
            const payload = try serialize.branchSummaryToJson(self.manager.gpa, entry_id, text);
            defer self.manager.gpa.free(payload);
            try self.insertEntryWithParent(out, entry_id, "branch_summary", null, payload);
        } else {
            var buffer: [entry_id_len]u8 = undefined;
            @memcpy(buffer[0..], entry_id);
            self.leaf_entry_id = .{ .bytes = buffer };
            try self.updateLeaf(entry_id);
        }
    }

    /// Append a compaction boundary as a child of the current leaf. `summary`
    /// (with any handover framing already applied by the caller) stands in for
    /// every entry before `first_kept_id` in the projected context. Validates
    /// that `first_kept_id` exists in this session before writing — the
    /// write-time half of the branch-safety guarantee whose read-time half is
    /// `findCompactionBoundary`.
    pub fn appendCompaction(self: *Session, first_kept_id: []const u8, compaction_summary: []const u8, id_out: *[entry_id_len]u8) Error!void {
        assert(first_kept_id.len == entry_id_len);
        assert(compaction_summary.len > 0);
        try self.requireEntry(first_kept_id);
        fillHex(self.manager.io, id_out);
        const payload = try serialize.compactionToJson(self.manager.gpa, first_kept_id, compaction_summary);
        defer self.manager.gpa.free(payload);
        try self.insertEntry(id_out, "compaction", null, payload);
    }

    // === git-shadow snapshots ==============================================
    //
    // Each entry can carry a git commit id (`snapshot`) binding it to the code
    // state *at* that conversation node. Unlike the old `checkpoint` child
    // entries, the id lives ON the entry, so navigating to a node reads its own
    // (or its nearest ancestor's) snapshot directly — no descendant scan, no
    // off-by-one. Written by the harness after a file-changing step.

    /// Record `sha` (a git commit id) as the code state at `entry_id`.
    pub fn setSnapshot(self: *Session, entry_id: []const u8, sha: []const u8) Error!void {
        assert(entry_id.len == entry_id_len);
        assert(sha.len > 0);
        var statement = try self.manager.connection.prepare("update session_entries set snapshot = ? where session_id = ? and id = ?");
        defer statement.finalize();
        try statement.bindText(1, sha);
        try statement.bindText(2, self.id.slice());
        try statement.bindText(3, entry_id);
        try expectDone(&statement);
    }

    /// Save a prompt to the session's prompt history. A plain append: the table
    /// is a per-session log of prompts as typed (no dedup — consecutive
    /// identical prompts each get their own row; only the UI ring dedups).
    pub fn savePromptHistory(self: *Session, prompt: []const u8) Error!void {
        assert(prompt.len > 0);
        const timestamp_ms = nowMs(self.manager.io);
        var statement = try self.manager.connection.prepare("insert into prompt_history(session_id, prompt_text, created_at_ms) values (?, ?, ?)");
        defer statement.finalize();
        try statement.bindText(1, self.id.slice());
        try statement.bindText(2, prompt);
        try statement.bindInt(3, timestamp_ms);
        try expectDone(&statement);
    }

    /// Load the prompt history for this session, newest first. Ordered by the
    /// monotonic autoincrement `id`, not `created_at_ms`: millisecond ties and
    /// clock skew would leave the order unspecified, and `/undo` relies on
    /// `[0]` agreeing with `deleteNewestPromptHistory`'s victim. Caller owns
    /// the slice and each string.
    pub fn loadPromptHistory(self: *Session, gpa: std.mem.Allocator) Error![][]u8 {
        var statement = try self.manager.connection.prepare("select prompt_text from prompt_history where session_id = ? order by id desc");
        defer statement.finalize();
        try statement.bindText(1, self.id.slice());

        var prompts: std.ArrayList([]u8) = .empty;
        errdefer {
            for (prompts.items) |p| gpa.free(p);
            prompts.deinit(gpa);
        }
        while (try statement.step()) |row| {
            try prompts.append(gpa, try gpa.dupe(u8, row.text(0)));
        }
        return prompts.toOwnedSlice(gpa);
    }

    /// Drop the newest prompt-history row. `/undo` calls this after a
    /// successful rewind so the table's `[0]` tracks the newest prompt *on the
    /// active branch* — without it, a chained undo would restore the prompt of
    /// the turn it already discarded. Idempotent by construction: deleting
    /// from an empty table is a no-op.
    pub fn deleteNewestPromptHistory(self: *Session) Error!void {
        var statement = try self.manager.connection.prepare(
            "delete from prompt_history where session_id = ?1 and id = (select id from prompt_history where session_id = ?1 order by id desc limit 1)",
        );
        defer statement.finalize();
        try statement.bindText(1, self.id.slice());
        try expectDone(&statement);
    }

    /// Update the model provider, ID, and reasoning effort for this session.
    /// `effort_label` is null to clear a stored override (use config/default).
    pub fn updateModel(self: *Session, provider: []const u8, model_id: []const u8, effort_label: ?[]const u8) Error!void {
        assert(self.id.slice().len > 0);
        var statement = try self.manager.connection.prepare("update sessions set model_provider = ?, model_id = ?, reasoning_effort = ?, updated_at_ms = ? where id = ?");
        defer statement.finalize();
        try statement.bindText(1, provider);
        try statement.bindText(2, model_id);
        if (effort_label) |label| {
            try statement.bindText(3, label);
        } else {
            try statement.bindNull(3);
        }
        const timestamp_ms = nowMs(self.manager.io);
        try statement.bindInt(4, timestamp_ms);
        try statement.bindText(5, self.id.slice());
        try expectDone(&statement);
    }

    /// Load the summary for this session. Caller owns the memory.
    pub fn summary(self: *Session, gpa: std.mem.Allocator) Error!SessionSummary {
        var statement = try self.manager.connection.prepare("select id, title, cwd, created_at_ms, updated_at_ms, leaf_entry_id, model_provider, model_id, reasoning_effort from sessions where id = ?");
        defer statement.finalize();
        try statement.bindText(1, self.id.slice());
        const row = (try statement.step()) orelse return error.MissingSession;
        return try readSummary(gpa, &row);
    }

    /// The git commit id of the nearest entry at or above the current leaf that
    /// carries a snapshot (walking leaf→root) — the code state bound to the
    /// active conversation position. Null when no ancestor has one (a brand-new
    /// session before any file change). Caller owns the returned string.
    pub fn snapshotAt(self: *Session, gpa: std.mem.Allocator) Error!?[]u8 {
        const leaf_id = self.leaf_entry_id orelse return null;
        var statement = try self.manager.connection.prepare(
            \\with recursive anc(id, parent_id, snapshot, depth) as (
            \\  select id, parent_id, snapshot, 0 from session_entries
            \\    where session_id = ?1 and id = ?2
            \\  union all
            \\  select e.id, e.parent_id, e.snapshot, anc.depth + 1
            \\    from session_entries e join anc on e.id = anc.parent_id
            \\    where e.session_id = ?1
            \\)
            \\select snapshot from anc where snapshot is not null order by depth limit 1
        );
        defer statement.finalize();
        try statement.bindText(1, self.id.slice());
        try statement.bindText(2, leaf_id.slice());
        const row = (try statement.step()) orelse return null;
        if (row.columnType(0) == .null) return null;
        return try gpa.dupe(u8, row.text(0));
    }

    /// The newest user message entry on the active root→leaf path (walking
    /// leaf→root), or null when the path holds none (a fresh session). `/undo`'s
    /// target selection: everything after this entry is the last turn, so the
    /// undo target is its `parent_id`. The role filter is pure SQL — compaction
    /// boundaries (role null) and legacy non-message kinds are skipped by the
    /// database itself. Allocation-free: ids are fixed-size.
    pub fn lastUserEntry(self: *Session) Error!?UserEntryRef {
        const leaf_id = self.leaf_entry_id orelse return null;
        var statement = try self.manager.connection.prepare(
            \\with recursive anc(id, parent_id, kind, role, depth) as (
            \\  select id, parent_id, kind, role, 0 from session_entries
            \\    where session_id = ?1 and id = ?2
            \\  union all
            \\  select e.id, e.parent_id, e.kind, e.role, anc.depth + 1
            \\    from session_entries e join anc on e.id = anc.parent_id
            \\    where e.session_id = ?1
            \\)
            \\select id, parent_id from anc
            \\  where kind = 'message' and role = 'user' order by depth limit 1
        );
        defer statement.finalize();
        try statement.bindText(1, self.id.slice());
        try statement.bindText(2, leaf_id.slice());
        const row = (try statement.step()) orelse return null;
        const id = try EntryId.fromSlice(row.text(0));
        const parent_id: ?EntryId = if (row.columnType(1) == .null)
            null
        else
            try EntryId.fromSlice(row.text(1));
        return .{ .id = id, .parent_id = parent_id };
    }

    /// Project the active branch into the message list the model sees. The
    /// durable tree is the source of truth; this is the derived view. When the
    /// branch carries a compaction boundary, the summarized prefix is replaced
    /// by the summary message and everything from the first kept entry onward
    /// is emitted verbatim (see `findCompactionBoundary`). Without a boundary
    /// the whole branch is emitted, preserving the pre-compaction behavior.
    pub fn messages(self: *Session, gpa: std.mem.Allocator) Error![]ai.ChatMessage {
        const path = try self.loadBranch(gpa);
        defer {
            for (path) |*entry| entry.deinit(gpa);
            gpa.free(path);
        }
        assert(path.len <= path_entries_max);

        const boundary = try findCompactionBoundary(gpa, path);
        const emit_start: u32 = if (boundary) |b| b.first_kept_index else 0;

        var messages_list: std.ArrayList(ai.ChatMessage) = .empty;
        errdefer {
            for (messages_list.items) |*message| deinitMessage(gpa, message);
            messages_list.deinit(gpa);
        }
        if (boundary) |b| {
            try messages_list.append(gpa, try serialize.compactionSummaryToMessage(gpa, path[b.summary_index].payload_json));
        }
        for (path[emit_start..]) |entry| {
            try appendProjectedEntry(gpa, &messages_list, entry);
        }
        return messages_list.toOwnedSlice(gpa);
    }

    /// Compute where to cut the active branch for compaction: the entry that
    /// becomes the first kept message, plus the rendered text of everything
    /// before it (including any prior summary, folded in). Works in tree-space
    /// so the boundary references a real entry id — the cache never needs to
    /// track ids. Returns null when the kept-recent budget already covers the
    /// branch (nothing worth summarizing). Caller owns `prefix_text`.
    pub fn compactionCut(self: *Session, gpa: std.mem.Allocator, keep_recent_tokens: u32) Error!?CompactionCut {
        const path = try self.loadBranch(gpa);
        defer {
            for (path) |*entry| entry.deinit(gpa);
            gpa.free(path);
        }
        assert(path.len <= path_entries_max);

        const boundary = try findCompactionBoundary(gpa, path);
        const emit_start: u32 = if (boundary) |b| b.first_kept_index else 0;

        var msgs: std.ArrayList(ai.ChatMessage) = .empty;
        defer {
            for (msgs.items) |*message| deinitMessage(gpa, message);
            msgs.deinit(gpa);
        }
        var ids: std.ArrayList(EntryId) = .empty;
        defer ids.deinit(gpa);
        for (path[emit_start..]) |entry| {
            if (std.mem.eql(u8, entry.kind, "message")) {
                try msgs.append(gpa, try serialize.jsonToMessage(gpa, entry.payload_json));
                try ids.append(gpa, .{ .bytes = entry.id });
            } else if (std.mem.eql(u8, entry.kind, "branch_summary")) {
                try msgs.append(gpa, try serialize.branchSummaryToMessage(gpa, entry.payload_json));
                try ids.append(gpa, .{ .bytes = entry.id });
            }
        }
        if (msgs.items.len == 0) return null;

        const cut = compaction.findCutIndex(msgs.items, keep_recent_tokens);
        if (cut == 0) return null;
        assert(cut < msgs.items.len);

        const prefix_text = try renderCompactionPrefix(gpa, path, boundary, msgs.items[0..cut]);
        return .{ .first_kept_id = ids.items[cut], .prefix_text = prefix_text };
    }

    pub fn leaf(self: *const Session) ?[]const u8 {
        if (self.leaf_entry_id) |*id| return id.slice();
        return null;
    }

    fn insertEntry(self: *Session, id: *const [entry_id_len]u8, kind: []const u8, role: ?[]const u8, payload_json: []const u8) Error!void {
        const parent: ?[]const u8 = if (self.leaf_entry_id) |*leaf_id| leaf_id.slice() else null;
        try self.insertEntryWithParent(id, parent, kind, role, payload_json);
    }

    fn insertEntryWithParent(self: *Session, id: *const [entry_id_len]u8, parent_id: ?[]const u8, kind: []const u8, role: ?[]const u8, payload_json: []const u8) Error!void {
        assert(kind.len > 0);
        assert(payload_json.len > 0);
        const timestamp_ms = nowMs(self.manager.io);
        var statement = try self.manager.connection.prepare("insert into session_entries(id, session_id, parent_id, kind, role, payload_json, created_at_ms) values (?, ?, ?, ?, ?, ?, ?)");
        defer statement.finalize();
        try statement.bindText(1, id[0..]);
        try statement.bindText(2, self.id.slice());
        if (parent_id) |parent| {
            try statement.bindText(3, parent);
        } else {
            try statement.bindNull(3);
        }
        try statement.bindText(4, kind);
        if (role) |value| {
            try statement.bindText(5, value);
        } else {
            try statement.bindNull(5);
        }
        try statement.bindText(6, payload_json);
        try statement.bindInt(7, timestamp_ms);
        try expectDone(&statement);
        self.leaf_entry_id = .{ .bytes = id.* };
        try self.updateLeaf(id[0..]);
    }

    pub fn setTitle(self: *Session, title: []const u8) Error!void {
        assert(title.len > 0);
        var statement = try self.manager.connection.prepare("update sessions set title = ?, updated_at_ms = ? where id = ?");
        defer statement.finalize();
        try statement.bindText(1, title);
        try statement.bindInt(2, nowMs(self.manager.io));
        try statement.bindText(3, self.id.slice());
        try expectDone(&statement);
    }

    pub fn hasTitle(self: *Session) Error!bool {
        var statement = try self.manager.connection.prepare("select title from sessions where id = ?");
        defer statement.finalize();
        try statement.bindText(1, self.id.slice());
        const row = (try statement.step()) orelse return error.MissingSession;
        return row.columnType(0) != .null and row.text(0).len > 0;
    }

    fn updateLeaf(self: *Session, leaf_id: []const u8) Error!void {
        assert(leaf_id.len == entry_id_len);
        var statement = try self.manager.connection.prepare("update sessions set leaf_entry_id = ?, updated_at_ms = ? where id = ?");
        defer statement.finalize();
        try statement.bindText(1, leaf_id);
        try statement.bindInt(2, nowMs(self.manager.io));
        try statement.bindText(3, self.id.slice());
        try expectDone(&statement);
    }

    fn requireEntry(self: *Session, entry_id: []const u8) Error!void {
        var statement = try self.manager.connection.prepare("select 1 from session_entries where session_id = ? and id = ?");
        defer statement.finalize();
        try statement.bindText(1, self.id.slice());
        try statement.bindText(2, entry_id);
        if (try statement.step()) |_| return;
        return error.MissingEntry;
    }

    /// Load every entry in the session (the whole tree, not just the active
    /// path). Callers build the parent→children structure themselves. Entries
    /// are returned oldest-first by creation time so siblings keep a stable
    /// order. Caller owns the slice and each record.
    pub fn entries(self: *Session, gpa: std.mem.Allocator) Error![]EntryRecord {
        // `rowid` breaks created_at_ms ties so "oldest-first" is strictly
        // insertion order — entries written in the same millisecond (tests, fast
        // turns) keep a deterministic sequence, which the tree pre-order relies on.
        var statement = try self.manager.connection.prepare("select id, parent_id, kind, role, payload_json, created_at_ms, snapshot from session_entries where session_id = ? order by created_at_ms, rowid");
        defer statement.finalize();
        try statement.bindText(1, self.id.slice());

        var records: std.ArrayList(EntryRecord) = .empty;
        errdefer {
            for (records.items) |*record| record.deinit(gpa);
            records.deinit(gpa);
        }
        while (try statement.step()) |row| {
            try records.append(gpa, try readEntry(gpa, &row));
        }
        return records.toOwnedSlice(gpa);
    }

    fn loadBranch(self: *Session, gpa: std.mem.Allocator) Error![]EntryRecord {
        const leaf_id = self.leaf_entry_id orelse return try gpa.alloc(EntryRecord, 0);

        var statement = try self.manager.connection.prepare(
            \\with recursive branch(id, parent_id, kind, role, payload_json, created_at_ms, snapshot, rowid) as (
            \\  select id, parent_id, kind, role, payload_json, created_at_ms, snapshot, rowid
            \\    from session_entries where session_id = ? and id = ?
            \\  union all
            \\  select e.id, e.parent_id, e.kind, e.role, e.payload_json, e.created_at_ms, e.snapshot, e.rowid
            \\    from session_entries e join branch on e.id = branch.parent_id
            \\    where branch.parent_id is not null
            \\)
            \\select id, parent_id, kind, role, payload_json, created_at_ms, snapshot from branch order by created_at_ms, rowid
        );
        defer statement.finalize();
        try statement.bindText(1, self.id.slice());
        try statement.bindText(2, leaf_id.slice());

        var records: std.ArrayList(EntryRecord) = .empty;
        errdefer {
            for (records.items) |*record| record.deinit(gpa);
            records.deinit(gpa);
        }

        var found = false;
        while (try statement.step()) |row| {
            found = true;
            try records.append(gpa, try readEntry(gpa, &row));
        }
        if (!found) return error.MissingEntry;
        return records.toOwnedSlice(gpa);
    }
};

fn expectDone(statement: *db.Statement) Error!void {
    if (try statement.step()) |_| return error.Sqlite;
}

/// Emit one branch entry into the projected message list, dispatching on its
/// kind. Compaction entries are skipped: they are represented by the summary
/// message emitted in `messages`, not by a message of their own.
fn appendProjectedEntry(gpa: std.mem.Allocator, list: *std.ArrayList(ai.ChatMessage), entry: EntryRecord) Error!void {
    assert(entry.kind.len > 0);
    assert(entry.payload_json.len > 0);
    if (std.mem.eql(u8, entry.kind, "message")) {
        try list.append(gpa, try serialize.jsonToMessage(gpa, entry.payload_json));
        return;
    }
    if (std.mem.eql(u8, entry.kind, "branch_summary")) {
        try list.append(gpa, try serialize.branchSummaryToMessage(gpa, entry.payload_json));
        return;
    }
}

/// Locate the active compaction boundary in a root→leaf `path`: the newest
/// `compaction` entry whose `first_kept_id` still resolves to an entry on the
/// path. Returns null when there is no compaction entry, or when the named
/// boundary is not on this branch (a stale boundary left by a branch switch —
/// ignored so the full history projects instead).
fn findCompactionBoundary(gpa: std.mem.Allocator, path: []const EntryRecord) Error!?CompactionBoundary {
    assert(path.len <= path_entries_max);
    var summary_index: u32 = 0;
    var found = false;
    var scan: u32 = @intCast(path.len);
    while (scan > 0) {
        scan -= 1;
        if (std.mem.eql(u8, path[scan].kind, "compaction")) {
            summary_index = scan;
            found = true;
            break;
        }
    }
    if (!found) return null;

    const first_kept_id = try serialize.compactionFirstKeptId(gpa, path[summary_index].payload_json);
    const first_kept_index = indexOfEntry(path, first_kept_id[0..]) orelse return null;
    if (first_kept_index > summary_index) return null;
    assert(first_kept_index <= summary_index);
    return .{ .summary_index = summary_index, .first_kept_index = first_kept_index };
}

/// Index of the entry whose id equals `id` in `path`, or null if absent.
fn indexOfEntry(path: []const EntryRecord, id: []const u8) ?u32 {
    assert(id.len == entry_id_len);
    assert(path.len <= path_entries_max);
    for (path, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.id[0..], id)) return @intCast(index);
    }
    return null;
}

/// Render the text handed to the summarizer: any prior summary (folded in so
/// repeated compactions stay cumulative) followed by the rendered prefix
/// messages. Caller owns the result.
fn renderCompactionPrefix(gpa: std.mem.Allocator, path: []const EntryRecord, boundary: ?CompactionBoundary, prefix_msgs: []const ai.ChatMessage) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    if (boundary) |b| {
        const prev_summary = try serialize.compactionSummaryText(gpa, path[b.summary_index].payload_json);
        defer gpa.free(prev_summary);
        // Fold in only the inner summary, not the handover template's framing,
        // so repeated compactions don't re-ingest the boilerplate (M7).
        const inner = compaction.stripSummaryFraming(prev_summary);
        try out.writer.print("{s}\n", .{inner});
    }
    const rendered = try compaction.serializePrefix(gpa, prefix_msgs);
    defer gpa.free(rendered);
    try out.writer.writeAll(rendered);
    return out.toOwnedSlice();
}

/// Classify an entry and produce its one-line `/timeline` summary in a single
/// parse. Whitespace is collapsed and the text truncated to one row. Caller
/// owns `text`.
pub fn entrySummary(gpa: std.mem.Allocator, record: EntryRecord) Error!EntrySummary {
    const display_max: u32 = 120;
    if (std.mem.eql(u8, record.kind, "branch_summary")) {
        return .{ .branch_summary = .{ .text = try gpa.dupe(u8, "branch summary") } };
    }
    if (std.mem.eql(u8, record.kind, "session_info")) {
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, record.payload_json, .{}) catch
            return .{ .session_info = .{ .text = try gpa.dupe(u8, "title") } };
        defer parsed.deinit();
        if (parsed.value == .object) {
            if (parsed.value.object.get("title")) |title| {
                if (title == .string) {
                    const collapsed = try collapseWhitespace(gpa, title.string, display_max);
                    defer gpa.free(collapsed);
                    return .{ .session_info = .{ .text = try std.fmt.allocPrint(gpa, "title: {s}", .{collapsed}) } };
                }
            }
        }
        return .{ .session_info = .{ .text = try gpa.dupe(u8, "title") } };
    }
    if (std.mem.eql(u8, record.kind, "checkpoint")) {
        return .{ .checkpoint = .{ .text = try gpa.dupe(u8, "checkpoint") } };
    }
    if (!std.mem.eql(u8, record.kind, "message")) {
        return .{ .other = .{ .text = try gpa.dupe(u8, record.kind) } };
    }

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, record.payload_json, .{}) catch
        return .{ .other = .{ .text = try gpa.dupe(u8, "message") } };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .other = .{ .text = try gpa.dupe(u8, "message") } };
    const object = parsed.value.object;

    const role = if (object.get("role")) |value| (if (value == .string) value.string else "") else "";
    if (std.mem.eql(u8, role, "tool")) {
        const tool_failed = if (object.get("tool_failed")) |field| field == .bool and field.bool else false;
        if (object.get("tool_display_label")) |label| {
            if (label == .string and label.string.len > 0) {
                return .{ .tool = .{ .text = try collapseWhitespace(gpa, label.string, display_max), .failed = tool_failed } };
            }
        }
        return .{ .tool = .{ .text = try gpa.dupe(u8, "tool result"), .failed = tool_failed } };
    }

    const is_user = std.mem.eql(u8, role, "user");
    const prefix = if (is_user) "you: " else "agent: ";
    const text = firstTextBlock(object);
    if (text.len == 0) {
        if (is_user) {
            return .{ .user = .{ .text = try gpa.dupe(u8, std.mem.trimEnd(u8, prefix, " :")) } };
        } else {
            return .{ .assistant_empty = .{ .text = try gpa.dupe(u8, std.mem.trimEnd(u8, prefix, " :")) } };
        }
    }
    const collapsed = try collapseWhitespace(gpa, text, display_max);
    defer gpa.free(collapsed);
    const allocated_text = try std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, collapsed });
    if (is_user) {
        return .{ .user = .{ .text = allocated_text } };
    } else {
        return .{ .assistant = .{ .text = allocated_text } };
    }
}

/// First `text` block of a message's content array, or "" if none.
fn firstTextBlock(object: std.json.ObjectMap) []const u8 {
    const content = object.get("content") orelse return "";
    if (content == .string) return content.string;
    if (content != .array) return "";
    for (content.array.items) |block| {
        if (block != .object) continue;
        const kind = block.object.get("type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "text")) continue;
        const value = block.object.get("text") orelse continue;
        if (value == .string and value.string.len > 0) return value.string;
    }
    return "";
}

/// Collapse runs of whitespace to single spaces and truncate to `max` columns.
/// Trailing "..." is added when cut and counts toward the `max` budget. Caller
/// owns the result.
fn collapseWhitespace(gpa: std.mem.Allocator, text: []const u8, max: u32) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var pending_space = false;
    var started = false;
    // Reserve 3 bytes for the "..." suffix so the total output never exceeds
    // `max`. Without this, a byte that pushes past max is appended first, then
    // "..." adds 3 more bytes — producing max + 3 (or max + 4 with a pending
    // space).
    const cap = max -| 3;
    for (text) |byte| {
        const is_space = byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
        if (is_space) {
            pending_space = started;
            continue;
        }
        if (pending_space) {
            if (out.items.len >= cap) {
                try out.appendSlice(gpa, "...");
                break;
            }
            try out.append(gpa, ' ');
            pending_space = false;
        }
        if (out.items.len >= cap) {
            try out.appendSlice(gpa, "...");
            break;
        }
        try out.append(gpa, byte);
        started = true;
    }
    return out.toOwnedSlice(gpa);
}

fn readSummary(gpa: std.mem.Allocator, row: *const db.Row) Error!SessionSummary {
    var leaf_buffer: [entry_id_len]u8 = undefined;
    return .{
        .id = try gpa.dupe(u8, row.text(0)),
        .title = if (row.columnType(1) == .null) null else try gpa.dupe(u8, row.text(1)),
        .cwd = try gpa.dupe(u8, row.text(2)),
        .created_at_ms = row.int(3),
        .updated_at_ms = row.int(4),
        .leaf_entry_id = if (row.columnType(5) == .null) null else blk: {
            const value = row.text(5);
            // A wrong-length leaf_entry_id is corrupt data (e.g. a test row or a
            // leftover from an older schema). Treat it as null so one bad row
            // doesn't crash the entire resume picker; the session still shows up
            // and a resume attempt fails gracefully via manager.@"resume".
            if (value.len != entry_id_len) break :blk null;
            @memcpy(leaf_buffer[0..], value);
            break :blk EntryId{ .bytes = leaf_buffer };
        },
        .model_provider = if (row.columnType(6) == .null) null else try gpa.dupe(u8, row.text(6)),
        .model_id = if (row.columnType(7) == .null) null else try gpa.dupe(u8, row.text(7)),
        .reasoning_effort = if (row.columnType(8) == .null) null else try gpa.dupe(u8, row.text(8)),
    };
}

fn readEntry(gpa: std.mem.Allocator, row: *const db.Row) Error!EntryRecord {
    var id: [entry_id_len]u8 = undefined;
    const id_text = row.text(0);
    if (id_text.len != entry_id_len) return error.BadEntryId;
    @memcpy(id[0..], id_text);

    var parent_id: ?[entry_id_len]u8 = null;
    if (row.columnType(1) != .null) {
        const parent_text = row.text(1);
        if (parent_text.len != entry_id_len) return error.BadEntryId;
        var parent_buffer: [entry_id_len]u8 = undefined;
        @memcpy(parent_buffer[0..], parent_text);
        parent_id = parent_buffer;
    }

    return .{
        .id = id,
        .parent_id = parent_id,
        .kind = try gpa.dupe(u8, row.text(2)),
        .role = if (row.columnType(3) == .null) null else try gpa.dupe(u8, row.text(3)),
        .payload_json = try gpa.dupe(u8, row.text(4)),
        .created_at_ms = row.int(5),
        .snapshot = if (row.columnType(6) == .null) null else try gpa.dupe(u8, row.text(6)),
    };
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.now(.real, io).toMilliseconds();
}

fn fillHex(io: std.Io, buffer: []u8) void {
    assert(buffer.len > 0);
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    const alphabet = "0123456789abcdef";
    for (buffer, 0..) |*byte, index| {
        const value = bytes[index / 2];
        const nibble = if (index % 2 == 0) value >> 4 else value & 0x0f;
        byte.* = alphabet[nibble];
    }
}

fn deinitMessage(gpa: std.mem.Allocator, message: *ai.ChatMessage) void {
    message.deinit(gpa);
}

fn freeToolCalls(gpa: std.mem.Allocator, calls: []const ai.ToolCall) void {
    if (calls.len == 0) return;
    for (calls) |call| {
        var owned = call;
        owned.deinit(gpa);
    }
    gpa.free(calls);
}

test "session persists and loads messages" {
    var manager = try SessionManager.init(std.testing.allocator, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/nova", .{ .id = "0123456789abcdef0123456789abcdef", .title = "Test" });

    var id: [entry_id_len]u8 = undefined;
    const blocks = try std.testing.allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, "hello") } };
    try session.append(.{ .user = .{ .content = blocks } }, &id);
    for (blocks) |*block| block.deinit(std.testing.allocator);
    std.testing.allocator.free(blocks);
    const messages = try session.messages(std.testing.allocator);
    defer {
        for (messages) |*message| deinitMessage(std.testing.allocator, message);
        std.testing.allocator.free(messages);
    }
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(.user, messages[0].role());
    try std.testing.expectEqualStrings("hello", messages[0].text());
}

test "session persists tool display labels and failures" {
    var manager = try SessionManager.init(std.testing.allocator, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/nova", .{ .id = "11111111111111111111111111111111", .title = "Tools" });

    var id: [entry_id_len]u8 = undefined;
    const blocks = try std.testing.allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, "contents") } };
    const call_id = try std.testing.allocator.dupe(u8, "call_1");
    const label = try std.testing.allocator.dupe(u8, "read AGENTS.md");
    try session.append(.{ .tool = .{ .content = blocks, .call_id = .{ .value = call_id }, .display_label = label, .failed = true } }, &id);
    for (blocks) |*block| block.deinit(std.testing.allocator);
    std.testing.allocator.free(blocks);
    std.testing.allocator.free(call_id);
    std.testing.allocator.free(label);

    const messages = try session.messages(std.testing.allocator);
    defer {
        for (messages) |*message| deinitMessage(std.testing.allocator, message);
        std.testing.allocator.free(messages);
    }
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(.tool, messages[0].role());
    try std.testing.expectEqualStrings("call_1", messages[0].tool.call_id.slice());
    try std.testing.expectEqualStrings("read AGENTS.md", messages[0].tool.display_label.?);
    try std.testing.expect(messages[0].tool.failed);
}

test "session branch with summary changes context" {
    var manager = try SessionManager.init(std.testing.allocator, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/nova", .{ .id = "fedcba9876543210fedcba9876543210" });

    var first: [entry_id_len]u8 = undefined;
    var second: [entry_id_len]u8 = undefined;
    var summary: [entry_id_len]u8 = undefined;
    const root_blocks = try std.testing.allocator.alloc(ai.ContentBlock, 1);
    root_blocks[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, "root") } };
    try session.append(.{ .user = .{ .content = root_blocks } }, &first);
    for (root_blocks) |*block| block.deinit(std.testing.allocator);
    std.testing.allocator.free(root_blocks);
    const old_blocks = try std.testing.allocator.alloc(ai.ContentBlock, 1);
    old_blocks[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, "old branch") } };
    try session.append(.{ .assistant = .{ .content = old_blocks } }, &second);
    for (old_blocks) |*block| block.deinit(std.testing.allocator);
    std.testing.allocator.free(old_blocks);
    try session.branch(first[0..], "old branch was abandoned", &summary);

    const messages = try session.messages(std.testing.allocator);
    defer {
        for (messages) |*message| deinitMessage(std.testing.allocator, message);
        std.testing.allocator.free(messages);
    }
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("root", messages[0].text());
    try std.testing.expectEqualStrings("Branch summary: old branch was abandoned", messages[1].text());
}

fn appendTextEntry(session: *Session, gpa: std.mem.Allocator, role: ai.Role, text: []const u8, id_out: *[entry_id_len]u8) !void {
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    defer {
        for (blocks) |*block| block.deinit(gpa);
        gpa.free(blocks);
    }
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, text) } };
    const message: ai.ChatMessage = switch (role) {
        .system => .{ .system = .{ .content = blocks } },
        .user => .{ .user = .{ .content = blocks } },
        .assistant => .{ .assistant = .{ .content = blocks } },
        .tool => return error.InvalidRole,
    };
    try session.append(message, id_out);
}

test "session compaction boundary replaces summarized prefix" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/nova", .{ .id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" });

    var id_old_user: [entry_id_len]u8 = undefined;
    var id_old_agent: [entry_id_len]u8 = undefined;
    var id_kept: [entry_id_len]u8 = undefined;
    var id_compaction: [entry_id_len]u8 = undefined;
    try appendTextEntry(&session, gpa, .user, "old one", &id_old_user);
    try appendTextEntry(&session, gpa, .assistant, "old two", &id_old_agent);
    try appendTextEntry(&session, gpa, .user, "keep me", &id_kept);
    try session.appendCompaction(id_kept[0..], "SUMMARY TEXT", &id_compaction);

    const messages = try session.messages(gpa);
    defer {
        for (messages) |*message| deinitMessage(gpa, message);
        gpa.free(messages);
    }
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqual(.user, messages[0].role());
    try std.testing.expectEqualStrings("SUMMARY TEXT", messages[0].text());
    try std.testing.expectEqualStrings("keep me", messages[1].text());
}

test "session compaction boundary keeps entries appended after it" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/nova", .{ .id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" });

    var id_old: [entry_id_len]u8 = undefined;
    var id_kept: [entry_id_len]u8 = undefined;
    var id_compaction: [entry_id_len]u8 = undefined;
    var id_after: [entry_id_len]u8 = undefined;
    try appendTextEntry(&session, gpa, .user, "old one", &id_old);
    try appendTextEntry(&session, gpa, .user, "keep me", &id_kept);
    try session.appendCompaction(id_kept[0..], "SUMMARY", &id_compaction);
    try appendTextEntry(&session, gpa, .assistant, "after compaction", &id_after);

    const messages = try session.messages(gpa);
    defer {
        for (messages) |*message| deinitMessage(gpa, message);
        gpa.free(messages);
    }
    try std.testing.expectEqual(@as(usize, 3), messages.len);
    try std.testing.expectEqualStrings("SUMMARY", messages[0].text());
    try std.testing.expectEqualStrings("keep me", messages[1].text());
    try std.testing.expectEqualStrings("after compaction", messages[2].text());
}

test "compaction cut splits the branch at the keep-recent budget" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/nova", .{ .id = "cccccccccccccccccccccccccccccccc" });

    var id_first: [entry_id_len]u8 = undefined;
    var id_second: [entry_id_len]u8 = undefined;
    var id_third: [entry_id_len]u8 = undefined;
    try appendTextEntry(&session, gpa, .user, "a" ** 40, &id_first);
    try appendTextEntry(&session, gpa, .assistant, "b" ** 40, &id_second);
    try appendTextEntry(&session, gpa, .user, "c" ** 40, &id_third);

    // keep_recent of 15 tokens keeps the last two (~10 tokens each); the cut
    // lands on the second entry and the first is summarized.
    const cut = (try session.compactionCut(gpa, 15)) orelse return error.TestFailed;
    defer gpa.free(cut.prefix_text);
    try std.testing.expectEqualSlices(u8, id_second[0..], cut.first_kept_id.slice());
    try std.testing.expect(std.mem.indexOf(u8, cut.prefix_text, "aaaa") != null);
    try std.testing.expect(std.mem.indexOf(u8, cut.prefix_text, "bbbb") == null);
}

test "compaction cut returns null when the budget covers the branch" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/nova", .{ .id = "dddddddddddddddddddddddddddddddd" });

    var id_only: [entry_id_len]u8 = undefined;
    try appendTextEntry(&session, gpa, .user, "small", &id_only);
    const result = try session.compactionCut(gpa, 100_000);
    try std.testing.expect(result == null);
}

test "snapshotAt reads the nearest ancestor-or-self snapshot, branch-aware" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/nova", .{ .id = "5" ** session_id_len });

    const sha_a = "a" ** 40;
    const sha_b = "b" ** 40;
    var user_id: [entry_id_len]u8 = undefined;
    var asst_id: [entry_id_len]u8 = undefined;
    var scratch: [entry_id_len]u8 = undefined;

    // No entries yet → no snapshot.
    try std.testing.expect((try session.snapshotAt(gpa)) == null);

    try appendTextEntry(&session, gpa, .user, "first", &user_id);
    try session.setSnapshot(user_id[0..], sha_a);
    try appendTextEntry(&session, gpa, .assistant, "second", &asst_id);

    // a1 carries no snapshot → nearest ancestor (u1) wins.
    {
        const got = (try session.snapshotAt(gpa)) orelse return error.TestFailed;
        defer gpa.free(got);
        try std.testing.expectEqualStrings(sha_a, got);
    }
    // Annotate the assistant entry → self wins.
    try session.setSnapshot(asst_id[0..], sha_b);
    {
        const got = (try session.snapshotAt(gpa)) orelse return error.TestFailed;
        defer gpa.free(got);
        try std.testing.expectEqualStrings(sha_b, got);
    }
    // Fork off u1: the new branch's leaf has no snapshot, so it inherits u1's —
    // never a1's (which is on the other branch). This is the binding that the
    // old descendant-checkpoint model got wrong.
    try session.branch(user_id[0..], null, null);
    try appendTextEntry(&session, gpa, .user, "alt", &scratch);
    {
        const got = (try session.snapshotAt(gpa)) orelse return error.TestFailed;
        defer gpa.free(got);
        try std.testing.expectEqualStrings(sha_a, got);
    }
}

test "lastUserEntry walks the active path to the newest user message" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/nova", .{ .id = "e" ** session_id_len });

    var user1: [entry_id_len]u8 = undefined;
    var asst1: [entry_id_len]u8 = undefined;
    var user2: [entry_id_len]u8 = undefined;
    var asst2: [entry_id_len]u8 = undefined;
    var scratch: [entry_id_len]u8 = undefined;

    // Fresh session: no entries → no user entry.
    try std.testing.expect((try session.lastUserEntry()) == null);

    try appendTextEntry(&session, gpa, .user, "one", &user1);
    try appendTextEntry(&session, gpa, .assistant, "two", &asst1);
    try appendTextEntry(&session, gpa, .user, "three", &user2);
    try appendTextEntry(&session, gpa, .assistant, "four", &asst2);

    // Leaf is a2: the newest user entry on the path is u2, its parent asst1 is
    // exactly the /undo target (the last entry of the previous turn).
    {
        const got = (try session.lastUserEntry()) orelse return error.TestFailed;
        try std.testing.expectEqualSlices(u8, user2[0..], got.id.slice());
        try std.testing.expectEqualSlices(u8, asst1[0..], got.parent_id.?.slice());
    }

    // A compaction boundary appended after the leaf must be skipped by the
    // kind/role filters (compaction rows are kind='compaction', role null).
    try session.appendCompaction(asst2[0..], "SUMMARY", &scratch);
    {
        const got = (try session.lastUserEntry()) orelse return error.TestFailed;
        try std.testing.expectEqualSlices(u8, user2[0..], got.id.slice());
    }

    // Rewind to a1 (the /undo navigation): u2 is off-path, u1 is the newest
    // user entry — and its null parent is the "first prompt" discriminator.
    try session.branch(asst1[0..], null, null);
    {
        const got = (try session.lastUserEntry()) orelse return error.TestFailed;
        try std.testing.expectEqualSlices(u8, user1[0..], got.id.slice());
        try std.testing.expect(got.parent_id == null);
    }
}

test "deleteNewestPromptHistory removes exactly the newest row" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/nova", .{ .id = "f" ** session_id_len });

    try session.savePromptHistory("first");
    try session.savePromptHistory("second");
    try session.savePromptHistory("third");

    {
        const prompts = try session.loadPromptHistory(gpa);
        defer {
            for (prompts) |p| gpa.free(p);
            gpa.free(prompts);
        }
        try std.testing.expectEqual(@as(usize, 3), prompts.len);
        try std.testing.expectEqualStrings("third", prompts[0]);
    }
    try session.deleteNewestPromptHistory();
    {
        const prompts = try session.loadPromptHistory(gpa);
        defer {
            for (prompts) |p| gpa.free(p);
            gpa.free(prompts);
        }
        try std.testing.expectEqual(@as(usize, 2), prompts.len);
        try std.testing.expectEqualStrings("second", prompts[0]);
        try std.testing.expectEqualStrings("first", prompts[1]);
    }

    // Drain to empty, then one more delete: a no-op, not an error.
    try session.deleteNewestPromptHistory();
    try session.deleteNewestPromptHistory();
    try session.deleteNewestPromptHistory();
    {
        const prompts = try session.loadPromptHistory(gpa);
        defer {
            for (prompts) |p| gpa.free(p);
            gpa.free(prompts);
        }
        try std.testing.expectEqual(@as(usize, 0), prompts.len);
    }
}

test "prompt history newest-first order is insertion-stable under millisecond ties" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/nova", .{ .id = "6" ** session_id_len });

    // Two rows sharing created_at_ms: the order must fall back to insertion
    // order (autoincrement id) — the agreement point between
    // loadPromptHistory[0] and deleteNewestPromptHistory's victim.
    {
        var stmt = try manager.connection.prepare(
            "insert into prompt_history(session_id, prompt_text, created_at_ms) values (?, ?, 0)",
        );
        defer stmt.finalize();
        try stmt.bindText(1, session.id.slice());
        try stmt.bindText(2, "older insert");
        try expectDone(&stmt);
    }
    {
        var stmt = try manager.connection.prepare(
            "insert into prompt_history(session_id, prompt_text, created_at_ms) values (?, ?, 0)",
        );
        defer stmt.finalize();
        try stmt.bindText(1, session.id.slice());
        try stmt.bindText(2, "newer insert");
        try expectDone(&stmt);
    }
    const prompts = try session.loadPromptHistory(gpa);
    defer {
        for (prompts) |p| gpa.free(p);
        gpa.free(prompts);
    }
    try std.testing.expectEqual(@as(usize, 2), prompts.len);
    try std.testing.expectEqualStrings("newer insert", prompts[0]);
    try std.testing.expectEqualStrings("older insert", prompts[1]);
}

test "initDefault creates directory and initializes database" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_dir);

    var manager = try SessionManager.initDefault(gpa, std.testing.io, home_dir);
    defer manager.deinit();

    // Verify the file was actually created in the right spot
    const expected_path = ".config/nova/sessions.sqlite";
    try tmp.dir.access(std.testing.io, expected_path, .{});
}

test "create rejects session id with wrong length" {
    var manager = try SessionManager.init(std.testing.allocator, std.testing.io, ":memory:");
    defer manager.deinit();
    try std.testing.expectError(error.BadSessionId, manager.create("/tmp/nova", .{ .id = "short" }));
}

test "list treats corrupt leaf_entry_id as null instead of crashing" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();

    // Valid session: create + append an entry so it has a proper 8-char leaf.
    var session = try manager.create("/tmp/nova", .{ .id = "a" ** session_id_len });
    var id: [entry_id_len]u8 = undefined;
    try appendTextEntry(&session, gpa, .user, "hello", &id);

    // Corrupt session: mimic the production write order (insert session with
    // null leaf, insert entry, then update leaf) but end with a wrong-length
    // leaf_entry_id, simulating stale test data or an older-schema leftover.
    // The composite FK on sessions(id, leaf_entry_id) → session_entries(session_id, id)
    // requires the entry row to exist before the update.
    var sess_stmt = try manager.connection.prepare(
        "insert into sessions(id, title, cwd, created_at_ms, updated_at_ms, leaf_entry_id) values (?, null, ?, 0, 0, null)",
    );
    defer sess_stmt.finalize();
    try sess_stmt.bindText(1, "b" ** session_id_len);
    try sess_stmt.bindText(2, "/tmp/nova");
    try expectDone(&sess_stmt);

    var entry_stmt = try manager.connection.prepare(
        "insert into session_entries(id, session_id, parent_id, kind, role, payload_json, created_at_ms) values (?, ?, null, 'message', 'user', '{}', 0)",
    );
    defer entry_stmt.finalize();
    try entry_stmt.bindText(1, "entry-123"); // 9 chars, not 8
    try entry_stmt.bindText(2, "b" ** session_id_len);
    try expectDone(&entry_stmt);

    var upd_stmt = try manager.connection.prepare("update sessions set leaf_entry_id = ? where id = ?");
    defer upd_stmt.finalize();
    try upd_stmt.bindText(1, "entry-123");
    try upd_stmt.bindText(2, "b" ** session_id_len);
    try expectDone(&upd_stmt);

    const summaries = try manager.list(gpa, null);
    defer {
        for (summaries) |*s| s.deinit(gpa);
        gpa.free(summaries);
    }
    // Both sessions are returned — the corrupt one must not crash the list.
    try std.testing.expectEqual(@as(usize, 2), summaries.len);
    for (summaries) |s| {
        if (std.mem.eql(u8, s.id, "b" ** session_id_len)) {
            try std.testing.expect(s.leaf_entry_id == null);
        }
    }
}

test "deleteSession removes a session and its entries" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();

    var session = try manager.create("/tmp/nova", .{ .id = "a" ** session_id_len });
    var id: [entry_id_len]u8 = undefined;
    try appendTextEntry(&session, gpa, .user, "hello", &id);

    // The session shows up in list.
    {
        const summaries = try manager.list(gpa, null);
        defer {
            for (summaries) |*s| s.deinit(gpa);
            gpa.free(summaries);
        }
        try std.testing.expectEqual(@as(usize, 1), summaries.len);
    }

    // Delete it.
    try manager.deleteSession("a" ** session_id_len);

    // The list is now empty.
    {
        const summaries = try manager.list(gpa, null);
        defer {
            for (summaries) |*s| s.deinit(gpa);
            gpa.free(summaries);
        }
        try std.testing.expectEqual(@as(usize, 0), summaries.len);
    }
}

test "updateModel persists reasoning effort and summary reads it back" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();
    var session = try manager.create("/tmp/nova", .{ .id = "e" ** session_id_len });

    // Direct session-row update (no writer thread in this harness).
    try session.updateModel("ollama", "llama3.1:8b", "high");

    var summary = try session.summary(gpa);
    defer summary.deinit(gpa);
    try std.testing.expectEqualStrings("ollama", summary.model_provider.?);
    try std.testing.expectEqualStrings("llama3.1:8b", summary.model_id.?);
    try std.testing.expectEqualStrings("high", summary.reasoning_effort.?);

    // Clearing the override (null) round-trips back to NULL — resume then
    // falls back to config/default.
    try session.updateModel("ollama", "llama3.1:8b", null);
    var summary2 = try session.summary(gpa);
    defer summary2.deinit(gpa);
    try std.testing.expect(summary2.reasoning_effort == null);
    try std.testing.expectEqualStrings("ollama", summary2.model_provider.?);
}

test "renameSession updates the title" {
    const gpa = std.testing.allocator;
    var manager = try SessionManager.init(gpa, std.testing.io, ":memory:");
    defer manager.deinit();

    _ = try manager.create("/tmp/nova", .{ .id = "b" ** session_id_len });

    // No title initially.
    {
        const summaries = try manager.list(gpa, null);
        defer {
            for (summaries) |*s| s.deinit(gpa);
            gpa.free(summaries);
        }
        try std.testing.expectEqual(@as(usize, 0), summaries.len);
    }

    // Rename (set a title). But list filters by leaf_entry_id is not null,
    // so we need an entry. Use a direct insert + update like the corrupt test.
    var sess_stmt = try manager.connection.prepare(
        "insert into sessions(id, title, cwd, created_at_ms, updated_at_ms, leaf_entry_id) values (?, null, ?, 0, 0, null)",
    );
    defer sess_stmt.finalize();
    try sess_stmt.bindText(1, "c" ** session_id_len);
    try sess_stmt.bindText(2, "/tmp/nova");
    try expectDone(&sess_stmt);

    var entry_stmt = try manager.connection.prepare(
        "insert into session_entries(id, session_id, parent_id, kind, role, payload_json, created_at_ms) values (?, ?, null, 'message', 'user', '{}', 0)",
    );
    defer entry_stmt.finalize();
    try entry_stmt.bindText(1, "12345678");
    try entry_stmt.bindText(2, "c" ** session_id_len);
    try expectDone(&entry_stmt);

    var upd_stmt = try manager.connection.prepare("update sessions set leaf_entry_id = ? where id = ?");
    defer upd_stmt.finalize();
    try upd_stmt.bindText(1, "12345678");
    try upd_stmt.bindText(2, "c" ** session_id_len);
    try expectDone(&upd_stmt);

    // Rename the session.
    try manager.renameSession("c" ** session_id_len, "My Renamed Session");

    // The list now shows the new title.
    {
        const summaries = try manager.list(gpa, null);
        defer {
            for (summaries) |*s| s.deinit(gpa);
            gpa.free(summaries);
        }
        try std.testing.expectEqual(@as(usize, 1), summaries.len);
        try std.testing.expect(summaries[0].title != null);
        try std.testing.expectEqualStrings("My Renamed Session", summaries[0].title.?);
    }
}
