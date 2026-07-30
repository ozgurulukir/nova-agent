//! State + parsing for the full-screen `/diff` viewer. This module owns the
//! parsed diff model, cursor/selection/scroll navigation, and the batch of
//! review comments. It deliberately knows nothing about drawing or key events —
//! `tui.zig` renders from this state and feeds key presses back into it.

const std = @import("std");
const bash_mod = @import("../tools/bash_exec.zig");

const assert = std.debug.assert;

/// Working tree vs HEAD, plus untracked files rendered as all-additions. Mirrors
/// the status-bar counter's scope. The `--no-index` per-file pass exits non-zero
/// when a file differs, which is expected; we only read stdout.
pub const diff_command =
    \\git diff --no-color HEAD
    \\git ls-files --others --exclude-standard -z 2>/dev/null | while IFS= read -r -d '' f; do
    \\  git diff --no-color --no-index -- /dev/null "$f"
    \\done
;

pub const LineKind = enum { file_header, hunk_header, context, added, removed, modified, meta };

/// One rendered row of the diff. `text` slices into `State.raw` (no copy). For
/// content rows `new_no`/`old_no` carry the file line numbers for the gutter and
/// for building comment labels.
pub const Line = struct {
    kind: LineKind,
    /// Display text for context/added/removed/headers/meta. For `.modified` this
    /// holds the new text; `old_text`/`new_text` carry both sides for the inline
    /// (intra-line) highlight computed lazily at draw time.
    text: []const u8,
    old_text: []const u8 = "",
    new_text: []const u8 = "",
    new_no: ?u32 = null,
    old_no: ?u32 = null,
    file: u32 = 0,
};

pub const FileEntry = struct {
    path: []const u8,
    header_row: usize,
    adds: u32 = 0,
    dels: u32 = 0,
};

pub const Comment = struct {
    file: u32,
    row_start: usize,
    row_end: usize,
    label: []u8,
    snippet: []u8,
    text: []u8,

    fn deinit(self: *Comment, gpa: std.mem.Allocator) void {
        gpa.free(self.label);
        gpa.free(self.snippet);
        gpa.free(self.text);
        self.* = undefined;
    }
};

pub const Sub = enum { browse, file_search, commenting };

pub const Range = struct { start: usize, end: usize };

pub const State = struct {
    raw: []u8 = &.{},
    lines: std.ArrayList(Line) = .empty,
    files: std.ArrayList(FileEntry) = .empty,
    cursor: usize = 0,
    sel_anchor: ?usize = null,
    scroll: usize = 0,
    sub: Sub = .browse,
    comment_anchor: Range = .{ .start = 0, .end = 0 },
    /// Index of the comment being edited (null = composing a new one). Set by
    /// `editActiveComment` / `beginNewComment`, consumed by `saveComment`.
    comment_edit: ?usize = null,
    comments: std.ArrayList(Comment) = .empty,
    search_matches: std.ArrayList(u32) = .empty,
    search_sel: u32 = 0,
    /// Body height in rows, refreshed each draw so page navigation can step a
    /// screenful. Pure view state, parked here next to `cursor`/`scroll`.
    viewport_rows: u16 = 0,

    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        for (self.comments.items) |*comment| comment.deinit(gpa);
        self.comments.deinit(gpa);
        self.search_matches.deinit(gpa);
        self.lines.deinit(gpa);
        self.files.deinit(gpa);
        if (self.raw.len > 0) gpa.free(self.raw);
        self.* = .{};
    }

    pub fn isEmpty(self: *const State) bool {
        return self.lines.items.len == 0;
    }

    /// Ordered [start, end] of the current selection (single line when no anchor).
    pub fn selection(self: *const State) Range {
        const anchor = self.sel_anchor orelse return .{ .start = self.cursor, .end = self.cursor };
        if (anchor <= self.cursor) return .{ .start = anchor, .end = self.cursor };
        return .{ .start = self.cursor, .end = anchor };
    }

    fn lastIndex(self: *const State) usize {
        return if (self.lines.items.len == 0) 0 else self.lines.items.len - 1;
    }

    /// Move the cursor by `delta` rows. A plain move drops any selection anchor.
    pub fn moveCursor(self: *State, delta: i32) void {
        self.sel_anchor = null;
        self.applyDelta(delta);
    }

    /// Shift+arrow: keep an anchor and extend the highlighted range.
    pub fn extendSelection(self: *State, delta: i32) void {
        if (self.sel_anchor == null) self.sel_anchor = self.cursor;
        self.applyDelta(delta);
    }

    fn applyDelta(self: *State, delta: i32) void {
        const last = self.lastIndex();
        if (delta < 0) {
            const step: usize = @intCast(-delta);
            self.cursor = if (step >= self.cursor) 0 else self.cursor - step;
        } else {
            const step: usize = @intCast(delta);
            self.cursor = @min(self.cursor + step, last);
        }
    }

    /// Jump the cursor to the previous/next file header. `dir` is -1 or +1.
    pub fn jumpFile(self: *State, dir: i32) void {
        self.sel_anchor = null;
        if (self.files.items.len == 0) return;
        if (dir > 0) {
            for (self.files.items) |file| {
                if (file.header_row > self.cursor) {
                    self.cursor = file.header_row;
                    return;
                }
            }
            self.cursor = self.files.items[self.files.items.len - 1].header_row;
        } else {
            var target: usize = self.files.items[0].header_row;
            var i: usize = self.files.items.len;
            while (i > 0) {
                i -= 1;
                if (self.files.items[i].header_row < self.cursor) {
                    target = self.files.items[i].header_row;
                    break;
                }
            }
            self.cursor = target;
        }
    }

    pub fn jumpToFile(self: *State, file_index: usize) void {
        self.sel_anchor = null;
        if (file_index >= self.files.items.len) return;
        self.cursor = self.files.items[file_index].header_row;
    }

    /// Rebuild the file-search match list from `query` (case-insensitive
    /// substring). An empty query matches every file. The query itself lives in
    /// the popup's text field (`palette_input`); this just consumes its value.
    pub fn filterFiles(self: *State, gpa: std.mem.Allocator, query: []const u8) !void {
        self.search_matches.clearRetainingCapacity();
        for (self.files.items, 0..) |file, index| {
            if (query.len == 0 or std.ascii.indexOfIgnoreCase(file.path, query) != null) {
                try self.search_matches.append(gpa, @intCast(index));
            }
        }
        if (self.search_sel >= self.search_matches.items.len) self.search_sel = 0;
    }

    /// The comment implicitly selected by the cursor: the most specific one
    /// covering the cursor line (smallest range, most recent on ties). This is
    /// what Ctrl+E / Ctrl+D act on and what renders with the yellow gutter.
    pub fn activeComment(self: *const State) ?usize {
        var best: ?usize = null;
        var best_span: usize = std.math.maxInt(usize);
        for (self.comments.items, 0..) |comment, index| {
            if (self.cursor >= comment.row_start and self.cursor <= comment.row_end) {
                const span = comment.row_end - comment.row_start;
                if (best == null or span <= best_span) {
                    best = index;
                    best_span = span;
                }
            }
        }
        return best;
    }

    /// Open the comment editor for the current selection. If a comment already
    /// spans exactly that range, edit it (returns its text to prefill) rather
    /// than stacking a duplicate; otherwise compose a new one (returns "").
    pub fn beginComment(self: *State) []const u8 {
        const range = self.selection();
        self.sub = .commenting;
        self.comment_anchor = range;
        for (self.comments.items, 0..) |comment, index| {
            if (comment.row_start == range.start and comment.row_end == range.end) {
                self.comment_edit = index;
                return comment.text;
            }
        }
        self.comment_edit = null;
        return "";
    }

    /// Begin editing the active comment, returning its current text to prefill
    /// the editor. Null when no comment covers the cursor.
    pub fn editActiveComment(self: *State) ?[]const u8 {
        const index = self.activeComment() orelse return null;
        const comment = self.comments.items[index];
        self.comment_edit = index;
        self.comment_anchor = .{ .start = comment.row_start, .end = comment.row_end };
        self.sub = .commenting;
        return comment.text;
    }

    /// Delete the active comment. Returns true when one was removed.
    pub fn deleteActiveComment(self: *State, gpa: std.mem.Allocator) bool {
        const index = self.activeComment() orelse return false;
        var removed = self.comments.orderedRemove(index);
        removed.deinit(gpa);
        return true;
    }

    /// Commit the draft. When editing, an empty draft deletes the comment and a
    /// non-empty one replaces its text. When composing, an empty draft is
    /// discarded. Returns true when a comment exists afterwards (i.e. not
    /// discarded/deleted).
    pub fn saveComment(self: *State, gpa: std.mem.Allocator, draft: []const u8) !bool {
        const trimmed = std.mem.trim(u8, draft, " \t\r\n");
        self.sub = .browse;
        self.sel_anchor = null;
        const edit_index = self.comment_edit;
        self.comment_edit = null;

        if (edit_index) |index| {
            if (trimmed.len == 0) {
                var removed = self.comments.orderedRemove(index);
                removed.deinit(gpa);
                return false;
            }
            const text = try gpa.dupe(u8, trimmed);
            gpa.free(self.comments.items[index].text);
            self.comments.items[index].text = text;
            return true;
        }

        if (trimmed.len == 0) return false;
        const range = self.comment_anchor;
        const file = self.lines.items[range.start].file;
        const label = try self.rangeLabel(gpa, range);
        errdefer gpa.free(label);
        const snippet = try self.buildSnippet(gpa, range);
        errdefer gpa.free(snippet);
        const text = try gpa.dupe(u8, trimmed);
        errdefer gpa.free(text);
        try self.comments.append(gpa, .{
            .file = file,
            .row_start = range.start,
            .row_end = range.end,
            .label = label,
            .snippet = snippet,
            .text = text,
        });
        return true;
    }

    /// Gutter bracket glyph for a code row covered by a comment: `┌` at the top
    /// of a range, `│` below it, null when the row has no comment.
    pub fn bracketChar(self: *const State, row: usize) ?[]const u8 {
        var covered = false;
        var top = false;
        for (self.comments.items) |comment| {
            if (row >= comment.row_start and row <= comment.row_end) {
                covered = true;
                if (row == comment.row_start) top = true;
            }
        }
        if (!covered) return null;
        return if (top) "┌" else "│";
    }

    fn rowNumber(self: *const State, row: usize) ?u32 {
        const line = self.lines.items[row];
        return line.new_no orelse line.old_no;
    }

    /// `path:line` or `path:start-end` for a row range. Caller owns the result.
    pub fn rangeLabel(self: *State, gpa: std.mem.Allocator, range: Range) ![]u8 {
        const path = self.files.items[self.lines.items[range.start].file].path;
        const start_no = self.rowNumber(range.start);
        const end_no = self.rowNumber(range.end);
        if (start_no) |s| {
            if (end_no) |e| {
                if (e > s) return std.fmt.allocPrint(gpa, "{s}:{d}-{d}", .{ path, s, e });
                return std.fmt.allocPrint(gpa, "{s}:{d}", .{ path, s });
            }
            return std.fmt.allocPrint(gpa, "{s}:{d}", .{ path, s });
        }
        return std.fmt.allocPrint(gpa, "{s}", .{path});
    }

    fn buildSnippet(self: *State, gpa: std.mem.Allocator, range: Range) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);
        var row = range.start;
        while (row <= range.end and row < self.lines.items.len) : (row += 1) {
            const line = self.lines.items[row];
            // A merged modification expands back to its `-old` / `+new` pair so
            // the agent sees both sides.
            if (line.kind == .modified) {
                try buf.append(gpa, '-');
                try buf.appendSlice(gpa, line.old_text);
                try buf.append(gpa, '\n');
                try buf.append(gpa, '+');
                try buf.appendSlice(gpa, line.new_text);
                try buf.append(gpa, '\n');
                continue;
            }
            const sign: u8 = switch (line.kind) {
                .added => '+',
                .removed => '-',
                else => ' ',
            };
            try buf.append(gpa, sign);
            try buf.appendSlice(gpa, line.text);
            try buf.append(gpa, '\n');
        }
        return buf.toOwnedSlice(gpa);
    }

    /// Compose the batched review comments into a single user message, or null
    /// when there are no comments. Caller owns the returned slice.
    pub fn composeMessage(self: *State, gpa: std.mem.Allocator) !?[]u8 {
        if (self.comments.items.len == 0) return null;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);
        try buf.appendSlice(gpa, "Review comments on the current diff:\n");
        for (self.comments.items) |comment| {
            try buf.append(gpa, '\n');
            try buf.appendSlice(gpa, comment.label);
            try buf.append(gpa, '\n');
            // Lazy and zero-allocating: splitScalar yields slices straight into
            // the snippet string (no per-iteration copy), and composeMessage
            // only runs on explicit user actions (close viewer / copy), never
            // per-frame — so there is nothing to pre-split or cache here.
            var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, comment.snippet, "\n"), '\n');
            while (lines.next()) |snippet_line| {
                try buf.appendSlice(gpa, "> ");
                try buf.appendSlice(gpa, snippet_line);
                try buf.append(gpa, '\n');
            }
            try buf.appendSlice(gpa, comment.text);
            try buf.append(gpa, '\n');
        }
        return try buf.toOwnedSlice(gpa);
    }
};

/// Run git and parse the combined diff into a fresh `State`. An empty diff
/// yields a `State` whose `isEmpty()` is true.
pub fn load(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) !State {
    assert(cwd.len > 0);
    var result = bash_mod.runWithOptions(gpa, io, .{
        .cwd = cwd,
        .command = diff_command,
        .timeout = bash_mod.timeoutFromSeconds(10),
    }) catch return .{};
    defer result.deinit(gpa);

    return fromRaw(gpa, result.stdout);
}

/// Parse an already-captured combined diff (e.g. the cached one) into a fresh
/// `State`. Dupes `raw`, so the caller keeps ownership of its copy.
pub fn fromRaw(gpa: std.mem.Allocator, raw: []const u8) !State {
    var state: State = .{ .raw = try gpa.dupe(u8, raw) };
    errdefer state.deinit(gpa);
    try parse(&state, gpa);
    return state;
}

/// Buffers the removed/added lines of one contiguous change region so they can
/// be merged into `.modified` rows (deletion paired with the addition that
/// replaced it) when the region ends.
const ChangeBlock = struct {
    dels: std.ArrayList([]const u8) = .empty,
    adds: std.ArrayList([]const u8) = .empty,
    old_base: u32 = 0,
    new_base: u32 = 0,

    fn deinit(self: *ChangeBlock, gpa: std.mem.Allocator) void {
        self.dels.deinit(gpa);
        self.adds.deinit(gpa);
    }

    fn empty(self: *const ChangeBlock) bool {
        return self.dels.items.len == 0 and self.adds.items.len == 0;
    }

    /// Capture the starting line numbers the first time a row joins the block.
    fn ensureBase(self: *ChangeBlock, old_no: u32, new_no: u32) void {
        if (self.empty()) {
            self.old_base = old_no;
            self.new_base = new_no;
        }
    }

    /// Emit the buffered rows: pair deletions with additions index-wise as
    /// `.modified`, then any leftover deletions / additions on their own. Advances
    /// the running line numbers past the block and resets the buffers.
    fn flush(self: *ChangeBlock, state: *State, gpa: std.mem.Allocator, file_index: u32, old_no: *u32, new_no: *u32) !void {
        if (self.empty()) return;
        const pairs = @min(self.dels.items.len, self.adds.items.len);
        var i: usize = 0;
        while (i < pairs) : (i += 1) {
            try state.lines.append(gpa, .{
                .kind = .modified,
                .text = self.adds.items[i],
                .old_text = self.dels.items[i],
                .new_text = self.adds.items[i],
                .old_no = self.old_base + @as(u32, @intCast(i)),
                .new_no = self.new_base + @as(u32, @intCast(i)),
                .file = file_index,
            });
        }
        var di = pairs;
        while (di < self.dels.items.len) : (di += 1) {
            try state.lines.append(gpa, .{ .kind = .removed, .text = self.dels.items[di], .old_no = self.old_base + @as(u32, @intCast(di)), .file = file_index });
        }
        var ai = pairs;
        while (ai < self.adds.items.len) : (ai += 1) {
            try state.lines.append(gpa, .{ .kind = .added, .text = self.adds.items[ai], .new_no = self.new_base + @as(u32, @intCast(ai)), .file = file_index });
        }
        state.files.items[file_index].dels += @intCast(self.dels.items.len);
        state.files.items[file_index].adds += @intCast(self.adds.items.len);
        old_no.* = self.old_base + @as(u32, @intCast(self.dels.items.len));
        new_no.* = self.new_base + @as(u32, @intCast(self.adds.items.len));
        self.dels.clearRetainingCapacity();
        self.adds.clearRetainingCapacity();
    }
};

fn parse(state: *State, gpa: std.mem.Allocator) !void {
    var current_file: i64 = -1;
    var new_no: u32 = 0;
    var old_no: u32 = 0;
    var block: ChangeBlock = .{};
    defer block.deinit(gpa);

    var it = std.mem.splitScalar(u8, state.raw, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");

        if (std.mem.startsWith(u8, line, "diff --git")) {
            if (current_file >= 0) try block.flush(state, gpa, @intCast(current_file), &old_no, &new_no);
            const header_row = state.lines.items.len;
            try state.lines.append(gpa, .{ .kind = .file_header, .text = "", .file = @intCast(state.files.items.len) });
            try state.files.append(gpa, .{ .path = "", .header_row = header_row });
            current_file = @intCast(state.files.items.len - 1);
            new_no = 0;
            old_no = 0;
            continue;
        }
        if (current_file < 0) continue;
        const file_index: u32 = @intCast(current_file);

        if (std.mem.startsWith(u8, line, "+++ ")) {
            const path = stripPathPrefix(line[4..]);
            if (path.len > 0) setFilePath(state, file_index, path);
            continue;
        }
        if (std.mem.startsWith(u8, line, "--- ")) {
            // Keep the old path as a fallback (deletions where +++ is /dev/null).
            const path = stripPathPrefix(line[4..]);
            if (path.len > 0 and state.files.items[file_index].path.len == 0) {
                setFilePath(state, file_index, path);
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "@@")) {
            try block.flush(state, gpa, file_index, &old_no, &new_no);
            const span = parseHunk(line);
            old_no = span.old_start;
            new_no = span.new_start;
            // Git appends the enclosing context (function signature) after the
            // closing `@@`. Show just the `@@ … @@` marker, then drop the
            // heading onto its own dim line rather than crowding the marker.
            const cut = hunkHeaderEnd(line);
            try state.lines.append(gpa, .{ .kind = .hunk_header, .text = line[0..cut], .file = file_index });
            const heading = std.mem.trim(u8, line[cut..], " \t");
            if (heading.len > 0) {
                try state.lines.append(gpa, .{ .kind = .meta, .text = heading, .file = file_index });
            }
            continue;
        }
        if (line.len == 0) {
            try block.flush(state, gpa, file_index, &old_no, &new_no);
            continue;
        }
        switch (line[0]) {
            '+' => {
                block.ensureBase(old_no, new_no);
                try block.adds.append(gpa, line[1..]);
            },
            '-' => {
                // A deletion after additions begins a fresh change region.
                if (block.adds.items.len > 0) try block.flush(state, gpa, file_index, &old_no, &new_no);
                block.ensureBase(old_no, new_no);
                try block.dels.append(gpa, line[1..]);
            },
            ' ' => {
                try block.flush(state, gpa, file_index, &old_no, &new_no);
                try state.lines.append(gpa, .{ .kind = .context, .text = line[1..], .new_no = new_no, .old_no = old_no, .file = file_index });
                new_no += 1;
                old_no += 1;
            },
            else => {
                try block.flush(state, gpa, file_index, &old_no, &new_no);
                // index/mode/similarity lines are noise; surface binary notices.
                if (std.mem.startsWith(u8, line, "Binary files")) {
                    try state.lines.append(gpa, .{ .kind = .meta, .text = line, .file = file_index });
                }
            },
        }
    }
    if (current_file >= 0) try block.flush(state, gpa, @intCast(current_file), &old_no, &new_no);
}

/// Strip a leading `a/` or `b/` and a surrounding `"..."` quote from a diff path.
fn stripPathPrefix(path: []const u8) []const u8 {
    var p = path;
    if (p.len >= 2 and (p[0] == 'a' or p[0] == 'b') and p[1] == '/') p = p[2..];
    if (std.mem.eql(u8, p, "/dev/null")) return "";
    if (p.len >= 2 and p[0] == '"' and p[p.len - 1] == '"') p = p[1 .. p.len - 1];
    return p;
}

fn setFilePath(state: *State, file_index: u32, path: []const u8) void {
    state.files.items[file_index].path = path;
    state.lines.items[state.files.items[file_index].header_row].text = path;
}

/// Byte offset just past the closing `@@` of a hunk header, so the trailing
/// section heading can be split off. Falls back to the whole line.
fn hunkHeaderEnd(line: []const u8) usize {
    if (line.len < 2) return line.len;
    if (std.mem.indexOf(u8, line[2..], "@@")) |rel| return 2 + rel + 2;
    return line.len;
}

const HunkSpan = struct { old_start: u32, new_start: u32 };

/// Parse `@@ -old,len +new,len @@` for the starting line numbers.
fn parseHunk(line: []const u8) HunkSpan {
    var span: HunkSpan = .{ .old_start = 0, .new_start = 0 };
    if (std.mem.indexOfScalar(u8, line, '-')) |minus| {
        span.old_start = parseLeadingInt(line[minus + 1 ..]);
    }
    if (std.mem.indexOfScalar(u8, line, '+')) |plus| {
        span.new_start = parseLeadingInt(line[plus + 1 ..]);
    }
    return span;
}

fn parseLeadingInt(text: []const u8) u32 {
    var value: u32 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') break;
        value = value * 10 + (c - '0');
    }
    return value;
}

/// A line split into the unchanged head/tail shared by old and new, plus the
/// differing middles. Slices borrow from the inputs.
pub const InlineDiff = struct {
    prefix: []const u8,
    old_mid: []const u8,
    new_mid: []const u8,
    suffix: []const u8,
};

/// Cheap intra-line diff for a modification: the common prefix and suffix stay
/// shared; the differing middle is the deletion (old) vs insertion (new). O(len)
/// and allocation-free — good enough for the typical single-line edit and fast
/// enough to recompute per visible row each frame. Backed off to UTF-8
/// boundaries so multibyte scalars never split.
pub fn inlineDiff(old: []const u8, new: []const u8) InlineDiff {
    const limit = @min(old.len, new.len);
    var p: usize = 0;
    while (p < limit and old[p] == new[p]) p += 1;
    while (p > 0 and p < old.len and isContinuation(old[p])) p -= 1;

    var s: usize = 0;
    const tail_limit = limit - p;
    while (s < tail_limit and old[old.len - 1 - s] == new[new.len - 1 - s]) s += 1;
    while (s > 0 and isContinuation(old[old.len - s])) s -= 1;

    return .{
        .prefix = old[0..p],
        .old_mid = old[p .. old.len - s],
        .new_mid = new[p .. new.len - s],
        .suffix = old[old.len - s ..],
    };
}

fn isContinuation(byte: u8) bool {
    return (byte & 0xC0) == 0x80;
}

const sample_diff =
    \\diff --git a/foo.zig b/foo.zig
    \\index 1111111..2222222 100644
    \\--- a/foo.zig
    \\+++ b/foo.zig
    \\@@ -1,3 +1,4 @@
    \\ const a = 1;
    \\-const b = 2;
    \\+const b = 3;
    \\+const c = 4;
    \\ const d = 5;
    \\diff --git a/bar.txt b/bar.txt
    \\new file mode 100644
    \\index 0000000..3333333
    \\--- /dev/null
    \\+++ b/bar.txt
    \\@@ -0,0 +1,2 @@
    \\+hello
    \\+world
;

fn parseSample(gpa: std.mem.Allocator) !State {
    var state: State = .{ .raw = try gpa.dupe(u8, sample_diff) };
    errdefer state.deinit(gpa);
    try parse(&state, gpa);
    return state;
}

test "parse splits files and counts additions/deletions" {
    const gpa = std.testing.allocator;
    var state = try parseSample(gpa);
    defer state.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), state.files.items.len);
    try std.testing.expectEqualStrings("foo.zig", state.files.items[0].path);
    try std.testing.expectEqual(@as(u32, 2), state.files.items[0].adds);
    try std.testing.expectEqual(@as(u32, 1), state.files.items[0].dels);
    try std.testing.expectEqualStrings("bar.txt", state.files.items[1].path);
    try std.testing.expectEqual(@as(u32, 2), state.files.items[1].adds);
    try std.testing.expectEqual(@as(u32, 0), state.files.items[1].dels);
}

fn firstOfKind(state: *const State, kind: LineKind) usize {
    for (state.lines.items, 0..) |line, index| {
        if (line.kind == kind) return index;
    }
    return 0;
}

test "parse merges a -/+ pair into one modified row" {
    const gpa = std.testing.allocator;
    var state = try parseSample(gpa);
    defer state.deinit(gpa);

    const modified = state.lines.items[firstOfKind(&state, .modified)];
    try std.testing.expectEqualStrings("const b = 2;", modified.old_text);
    try std.testing.expectEqualStrings("const b = 3;", modified.new_text);
    try std.testing.expectEqual(@as(?u32, 2), modified.new_no);
    try std.testing.expectEqual(@as(?u32, 2), modified.old_no);

    // The unpaired extra addition stays its own row, numbered after it.
    const added = state.lines.items[firstOfKind(&state, .added)];
    try std.testing.expectEqualStrings("const c = 4;", added.text);
    try std.testing.expectEqual(@as(?u32, 3), added.new_no);
}

test "inlineDiff splits common prefix and suffix" {
    const d = inlineDiff("const b = 2;", "const b = 3;");
    try std.testing.expectEqualStrings("const b = ", d.prefix);
    try std.testing.expectEqualStrings("2", d.old_mid);
    try std.testing.expectEqualStrings("3", d.new_mid);
    try std.testing.expectEqualStrings(";", d.suffix);
}

test "saveComment + composeMessage expands a modification to both sides" {
    const gpa = std.testing.allocator;
    var state = try parseSample(gpa);
    defer state.deinit(gpa);

    state.cursor = firstOfKind(&state, .modified);
    _ = state.beginComment();
    try std.testing.expect(try state.saveComment(gpa, "use a const"));
    try std.testing.expectEqual(@as(usize, 1), state.comments.items.len);

    const message = (try state.composeMessage(gpa)).?;
    defer gpa.free(message);
    try std.testing.expect(std.mem.indexOf(u8, message, "foo.zig:2") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "> -const b = 2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "> +const b = 3;") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "use a const") != null);
}

test "empty comment draft is discarded" {
    const gpa = std.testing.allocator;
    var state = try parseSample(gpa);
    defer state.deinit(gpa);

    _ = state.beginComment();
    try std.testing.expect(!try state.saveComment(gpa, "   \n"));
    try std.testing.expectEqual(@as(usize, 0), state.comments.items.len);
    try std.testing.expect((try state.composeMessage(gpa)) == null);
}

test "identical-range selection edits; different ranges coexist" {
    const gpa = std.testing.allocator;
    var state = try parseSample(gpa);
    defer state.deinit(gpa);

    const m = firstOfKind(&state, .modified);
    const a = firstOfKind(&state, .added);

    state.cursor = m;
    _ = state.beginComment();
    try std.testing.expect(try state.saveComment(gpa, "first"));

    state.cursor = a;
    _ = state.beginComment();
    try std.testing.expect(try state.saveComment(gpa, "second"));
    try std.testing.expectEqual(@as(usize, 2), state.comments.items.len);

    // Re-selecting the exact same single line edits the existing comment.
    state.cursor = m;
    state.sel_anchor = null;
    const prefill = state.beginComment();
    try std.testing.expectEqualStrings("first", prefill);
    try std.testing.expect(try state.saveComment(gpa, "first-edited"));
    try std.testing.expectEqual(@as(usize, 2), state.comments.items.len);
}

test "editActiveComment edits in place; deleteActiveComment removes it" {
    const gpa = std.testing.allocator;
    var state = try parseSample(gpa);
    defer state.deinit(gpa);

    state.cursor = firstOfKind(&state, .added);
    _ = state.beginComment();
    try std.testing.expect(try state.saveComment(gpa, "first"));

    const prefill = state.editActiveComment().?;
    try std.testing.expectEqualStrings("first", prefill);
    try std.testing.expect(try state.saveComment(gpa, "second"));
    try std.testing.expectEqual(@as(usize, 1), state.comments.items.len);
    try std.testing.expectEqualStrings("second", state.comments.items[0].text);

    try std.testing.expect(state.deleteActiveComment(gpa));
    try std.testing.expectEqual(@as(usize, 0), state.comments.items.len);
    try std.testing.expect(state.editActiveComment() == null);
}

test "bracketChar marks the top and body of a comment range" {
    const gpa = std.testing.allocator;
    var state = try parseSample(gpa);
    defer state.deinit(gpa);

    const s = firstOfKind(&state, .modified); // modified row, followed by an added row
    state.cursor = s;
    state.sel_anchor = s + 1;
    _ = state.beginComment();
    try std.testing.expect(try state.saveComment(gpa, "spans two"));

    try std.testing.expectEqualStrings("┌", state.bracketChar(s).?);
    try std.testing.expectEqualStrings("│", state.bracketChar(s + 1).?);
    try std.testing.expect(state.bracketChar(s + 2) == null);
}

test "jumpFile moves the cursor between file headers" {
    const gpa = std.testing.allocator;
    var state = try parseSample(gpa);
    defer state.deinit(gpa);

    state.cursor = 0;
    state.jumpFile(1);
    try std.testing.expectEqual(state.files.items[1].header_row, state.cursor);
    state.jumpFile(-1);
    try std.testing.expectEqual(state.files.items[0].header_row, state.cursor);
}
