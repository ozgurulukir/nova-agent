//! File search backend for the `@` at-search autocomplete: fuzzy filepath
//! search over a background-walked index of the project tree. Matching is
//! done by the vendored fzy C library (`vendor/fzy`), which scores
//! candidates with a subsequence matcher.
//!
//! The index is built asynchronously with `io.concurrent` so the TUI render
//! loop never stutters: `runIfReady` returns `null` while the walk is still
//! in progress, and the caller (the `@` at-search popup) shows an
//! "indexing…" state instead of blocking.

const std = @import("std");
const c = @import("c");

const assert = std.debug.assert;

const page_size: u32 = 50;

/// Directory basenames that are always skipped while indexing. These are the
/// usual build output / dependency cache / version-control directories across
/// ecosystems, and they are ignored even when a project has no .gitignore.
const always_ignored_dirs: []const []const u8 = &.{
    ".git",
    ".zig-cache",
    "zig-out",
    "node_modules",
    "vendor", // vendored deps are typically not user-edited source
    "dist",
    "build",
    "out",
    "target", // Rust
    ".cargo",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".venv",
    "venv",
    ".tox",
    "*.egg-info", // actual dirs end without the star; literal match below
    ".gradle",
    ".idea",
    ".vscode",
    ".vs",
    "obj", // C/C# build dirs
    "bin",
    "Debug",
    "Release",
    "x64",
    "x86",
    "CMakeFiles",
    "CMakeCache.txt",
    ".stack-work", // Haskell
    ".cabal-sandbox",
    "_build", // Elixir / Erlang
    "deps", // Elixir deps
    "priv",
    ".elixir-tools",
    "Pods", // CocoaPods
    ".bundle",
    "DerivedData",
    ".next", // Next.js
    ".nuxt",
    ".output",
    ".svelte-kit",
    "storybook-static",
    ".parcel-cache",
    ".cache",
    ".turbo",
    ".vercel",
    "coverage",
    "site-packages",
    "dist-packages",
    "target-assert",
    "target-release",
    ".gitkeep",
};

fn makeIgnoredDirsMapKV(comptime dirs: []const []const u8) [dirs.len]struct { []const u8, void } {
    var kvs: [dirs.len]struct { []const u8, void } = undefined;
    for (dirs, 0..) |dir, i| {
        kvs[i] = .{ dir, {} };
    }
    return kvs;
}

const always_ignored_dirs_map = std.StaticStringMap(void).initComptime(makeIgnoredDirsMapKV(always_ignored_dirs));

/// True when `name` is one of the directory basenames we never recurse into.
fn isIgnoredDir(name: []const u8) bool {
    return always_ignored_dirs_map.has(name);
}

pub const Op = enum {
    find,

    pub fn name(self: Op) []const u8 {
        return ops_names[@intFromEnum(self)];
    }
};

const ops_names = [_][]const u8{"find"};

pub const ops_by_name = std.StaticStringMap(Op).initComptime(.{
    .{ "find", .find },
});

pub const Request = struct {
    op: Op,
    query: []const u8,
    cursor: ?[]const u8 = null,
};

pub const ResultStatus = enum { ok, err };

pub const Result = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,
    status: ResultStatus = .ok,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
        self.* = undefined;
    }
};

const Cursor = struct {
    op: Op,
    offset: u32,
    query_hash: u64,
};

/// A single indexed filepath. `path` points into the backend's slab
/// (`Backend.ready.files`), so it is only valid while the backend is ready.
const FileEntry = struct {
    path: []const u8,
    is_dir: bool,
};

const InitOutcome = union(enum) {
    ready: struct {
        /// Slab of null-terminated filepaths, one per `count` entry.
        files: []u8,
        count: usize,
    },
    failed: []u8, // gpa-owned

    fn deinit(self: *InitOutcome, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .ready => |r| gpa.free(r.files),
            .failed => |msg| if (msg.len > 0) gpa.free(msg),
        }
        self.* = undefined;
    }
};

const Backend = struct {
    mutex: std.Io.Mutex = .init,
    /// Background init state machine. The previous flat fields
    /// (future/done/api/handle/failed/failure_message) allowed illegal
    /// combinations like future=null with api set, or failed=true with
    /// future still pending. The union makes those unrepresentable.
    state: State = .idle,
    /// Current interactive search (if any). Separate from `state` so an
    /// in-progress search can run while the index is ready, and so a new
    /// keystroke can cancel/replace a previous search without waiting for it.
    search: SearchState = .idle,
    /// Monotonic counter incremented every time the index is rebuilt
    /// (`start` / `restart`). Search results carry the generation they were
    /// computed against; stale results are discarded after a `restart`.
    index_generation: u64 = 0,

    pub const State = union(enum) {
        idle,
        loading: struct {
            future: std.Io.Future(InitOutcome),
            /// Set by the init task immediately before it returns, so
            /// callers can non-blockingly check whether await is instant.
            done: std.atomic.Value(bool),
        },
        ready: struct {
            /// Slab of null-terminated filepaths, one per `count` entry.
            files: []u8,
            count: usize,
        },
        failed: struct {
            message: []u8,
        },
    };

    pub const SearchState = union(enum) {
        idle,
        running: struct {
            future: std.Io.Future(?Result),
            done: *std.atomic.Value(bool),
            query_hash: u64,
            /// The index generation this search was started against.
            generation: u64,
            /// A copy of the ready index slab at the moment the search was
            /// started. The task borrows this copy so that deinit/restart can
            /// free the Backend's slab without racing the background worker.
            files_copy: []u8,
            count: usize,
        },
    };

    /// Caller-owned copy of the current failure message, or null when the
    /// backend is not in the failed state. The caller must free with `gpa`.
    pub fn lastFailure(self: *const Backend, gpa: std.mem.Allocator) ?[]u8 {
        return switch (self.state) {
            .failed => |f| gpa.dupe(u8, f.message) catch null,
            else => null,
        };
    }
};

pub var backend: Backend = .{};

fn initBackend(gpa: std.mem.Allocator, io: std.Io, cwd: []u8, done: *std.atomic.Value(bool)) InitOutcome {
    defer {
        gpa.free(cwd);
        done.store(true, .release);
    }

    var files: std.ArrayListUnmanaged(u8) = .empty;
    errdefer files.deinit(gpa);
    var count: usize = 0;

    var dir = std.Io.Dir.openDir(.cwd(), io, cwd, .{ .iterate = true }) catch |err| {
        return .{ .failed = gpa.dupe(u8, @errorName(err)) catch &.{} };
    };
    defer dir.close(io);

    var walker = dir.walkSelectively(gpa) catch |err| {
        return .{ .failed = gpa.dupe(u8, @errorName(err)) catch &.{} };
    };
    defer walker.deinit();

    while (walker.next(io) catch |err| {
        return .{ .failed = gpa.dupe(u8, @errorName(err)) catch &.{} };
    }) |entry| {
        // Skip directories that are typically build output / caches / version
        // control internals across ecosystems. We only check the basename
        // (not the full path) for O(1) lookup; this covers the common cases
        // like .git, node_modules, .zig-cache, target, etc.
        if (entry.kind == .directory) {
            if (isIgnoredDir(entry.basename)) continue;
            walker.enter(io, entry) catch |err| {
                return .{ .failed = gpa.dupe(u8, @errorName(err)) catch &.{} };
            };
        }
        // Index regular files only. Directories are skipped — the `@`
        // at-search popup filters them out anyway, and the find operation
        // targets files.
        if (entry.kind != .file) continue;
        const path = entry.path;
        const path_len = path.len;
        const old_len = files.items.len;
        files.ensureUnusedCapacity(gpa, path_len + 1) catch |err| {
            return .{ .failed = gpa.dupe(u8, @errorName(err)) catch &.{} };
        };
        const slice = files.items.ptr[old_len..];
        @memcpy(slice[0..path_len], path);
        slice[path_len] = 0;
        files.items.len = old_len + path_len + 1;
        count += 1;
    }

    return .{ .ready = .{ .files = files.toOwnedSlice(gpa) catch |err| {
        return .{ .failed = gpa.dupe(u8, @errorName(err)) catch &.{} };
    }, .count = count } };
}

pub fn start(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) void {
    assert(cwd.len > 0);

    backend.mutex.lock(io) catch return;
    defer backend.mutex.unlock(io);

    // Already loading, ready, or failed — nothing to do.
    if (backend.state != .idle) return;

    backend.index_generation += 1;

    const cwd_owned = gpa.dupe(u8, cwd) catch {
        backend.state = .{ .failed = .{ .message = gpa.dupe(u8, "out of memory") catch &.{} } };
        return;
    };

    backend.state = .{
        .loading = .{
            .future = undefined, // set below
            .done = .init(false),
        },
    };
    const done_ptr = &backend.state.loading.done;
    backend.state.loading.future = io.concurrent(initBackend, .{ gpa, io, cwd_owned, done_ptr }) catch |err| {
        gpa.free(cwd_owned);
        backend.state = .{ .failed = .{ .message = gpa.dupe(u8, @errorName(err)) catch &.{} } };
        return;
    };
}

pub fn deinit(gpa: std.mem.Allocator, io: std.Io) void {
    backend.mutex.lock(io) catch return;
    defer backend.mutex.unlock(io);

    if (backend.state == .loading) {
        var future = backend.state.loading.future;
        var outcome = future.cancel(io);
        outcome.deinit(gpa);
    }
    if (backend.state == .ready) {
        gpa.free(backend.state.ready.files);
    }
    if (backend.state == .failed and backend.state.failed.message.len > 0) {
        gpa.free(backend.state.failed.message);
    }
    if (backend.search == .running) {
        const old = backend.search.running;
        var future = old.future;
        var result = future.cancel(io);
        if (result) |*r| r.deinit(gpa);
        gpa.destroy(old.done);
    }
    backend.state = .idle;
    backend.search = .idle;
    backend.index_generation = 0;
}

/// Release the current index (if any) and start indexing `cwd`.
/// Called on session switch / cross-project resume so the old directory's
/// index is torn down before the new one starts. No-op when the backend is
/// already indexing the same cwd.
pub fn restart(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) void {
    assert(cwd.len > 0);
    deinit(gpa, io);
    start(gpa, io, cwd);
}

fn searchTask(gpa: std.mem.Allocator, files: []u8, count: usize, query: []u8, done: *std.atomic.Value(bool)) ?Result {
    // `files` is task-owned: a copy of the ready slab made in queryAsync.
    // This lets deinit/restart free the Backend's slab without racing the
    // background worker.
    // `done` is owned by the caller (queryAsync/poll/cancel); the task only
    // writes to it and never frees it. `query` is task-owned.
    defer {
        gpa.free(files);
        gpa.free(query);
    }
    const query_c = gpa.dupeZ(u8, query) catch return null;
    defer gpa.free(query_c);

    const request: Request = .{ .op = .find, .query = query };
    const result = runFind(gpa, request, files, count) catch |err| {
        done.store(true, .release);
        return failResult(gpa, @errorName(err)) catch null;
    };
    done.store(true, .release);
    return result;
}

fn failResult(gpa: std.mem.Allocator, message: []const u8) !Result {
    assert(message.len > 0);
    return .{
        .stdout = try gpa.dupe(u8, message),
        .stderr = try gpa.alloc(u8, 0),
        .code = 2,
        .status = .err,
    };
}

/// Advance the backend out of `.loading` if the index walk has finished.
/// Caller must hold `backend.mutex`. No-op unless the worker signalled done.
fn drainIndexingLocked(io: std.Io) void {
    if (backend.state == .loading and backend.state.loading.done.load(.acquire)) {
        const outcome = backend.state.loading.future.await(io);
        switch (outcome) {
            .ready => |r| backend.state = .{ .ready = .{ .files = r.files, .count = r.count } },
            .failed => |msg| backend.state = .{ .failed = .{ .message = msg } },
        }
    }
}

/// Non-blocking: if the background index walk has finished, move the backend
/// from `.loading` to `.ready`/`.failed`. Returns `true` once the backend is
/// ready (or failed) and no longer indexing. Safe to call every frame while
/// the at-search popup shows the indexing spinner.
pub fn drainIndexing(io: std.Io) bool {
    backend.mutex.lock(io) catch return false;
    defer backend.mutex.unlock(io);
    drainIndexingLocked(io);
    return backend.state != .loading;
}

pub fn queryAsync(gpa: std.mem.Allocator, io: std.Io, request: Request) !void {
    try backend.mutex.lock(io);
    defer backend.mutex.unlock(io);

    // Drain any ready index future first (same as runReadyBackend).
    drainIndexingLocked(io);

    if (backend.state == .failed) return;
    if (backend.state != .ready) return;

    // Cancel an in-progress search for a different query. The task owns
    // and frees its own slab copy, so we only clean up the done flag.
    if (backend.search == .running) {
        if (backend.search.running.query_hash == hashQuery(request.query)) return;
        const old = backend.search.running;
        var future = old.future;
        var result = future.cancel(io);
        if (result) |*r| r.deinit(gpa);
        gpa.destroy(old.done);
    }

    const query_hash = hashQuery(request.query);
    const owned_query = try gpa.dupe(u8, request.query);
    errdefer gpa.free(owned_query);
    const done_ptr = try gpa.create(std.atomic.Value(bool));
    errdefer gpa.destroy(done_ptr);
    done_ptr.* = .init(false);

    // Copy the ready slab so the task owns its data. This lets deinit/restart
    // free the Backend's slab while the task is still running.
    const files = backend.state.ready.files;
    const count = backend.state.ready.count;
    const files_copy = try gpa.dupe(u8, files);
    errdefer gpa.free(files_copy);

    const future = try io.concurrent(searchTask, .{ gpa, files_copy, count, owned_query, done_ptr });
    backend.search = .{ .running = .{
        .future = future,
        .done = done_ptr,
        .query_hash = query_hash,
        .generation = backend.index_generation,
        .files_copy = files_copy,
        .count = count,
    } };
}

/// Non-blocking poll for an async search result. Returns `null` while the
/// search is still running; returns the completed `Result` (caller owns)
/// once it finishes. Returns `null` and clears state if the backend is not
/// ready or has failed, or if the result belongs to an index generation that
/// has been superseded by a restart.
pub fn pollSearchResult(gpa: std.mem.Allocator, io: std.Io) !?Result {
    try backend.mutex.lock(io);
    defer backend.mutex.unlock(io);

    if (backend.search != .running) return null;
    if (!backend.search.running.done.load(.acquire)) return null;

    const running = backend.search.running;
    var future = running.future;
    const result = future.await(io);
    const done_ptr = running.done;
    const search_generation = running.generation;
    backend.search = .idle;
    gpa.destroy(done_ptr);

    // If the index was restarted while this search was in flight, the
    // result belongs to a stale slab. Discard it silently; the UI will
    // re-issue the current query once the new index is ready.
    if (search_generation != backend.index_generation) {
        var stale = result;
        if (stale) |*r| r.deinit(gpa);
        return null;
    }

    // Result is task-owned; caller takes ownership.
    return result;
}

pub fn cancelSearch(gpa: std.mem.Allocator, io: std.Io) void {
    if (backend.search == .running) {
        const old = backend.search.running;
        var future = old.future;
        var result = future.cancel(io);
        if (result) |*r| r.deinit(gpa);
        gpa.destroy(old.done);
        backend.search = .idle;
    }
}

pub fn isIndexing() bool {
    return backend.state == .loading;
}

pub fn runIfReady(gpa: std.mem.Allocator, io: std.Io, request: Request) !?Result {
    return runReadyBackend(gpa, io, request);
}

fn runReadyBackend(gpa: std.mem.Allocator, io: std.Io, request: Request) !?Result {
    try backend.mutex.lock(io);
    defer backend.mutex.unlock(io);

    // Drain the loading future if the worker has signalled done.
    drainIndexingLocked(io);

    if (backend.state == .failed) return null;
    if (backend.state != .ready) return null;
    const files = backend.state.ready.files;
    const count = backend.state.ready.count;

    return try runFind(gpa, request, files, count);
}

/// Score every indexed path against the query with fzy and return the top
/// `page_size` matches, honoring the cursor for pagination.
fn runFind(gpa: std.mem.Allocator, request: Request, files: []const u8, count: usize) !Result {
    const cursor = try parseCursorForRequest(request);
    const query_c = if (request.query.len > 0) try gpa.dupeZ(u8, request.query) else "";
    defer if (request.query.len > 0) gpa.free(query_c);

    // Collect (score, index) pairs for every matching path.
    const Scored = struct { score: c.score_t, index: usize };
    var scored: std.ArrayListUnmanaged(Scored) = .empty;
    defer scored.deinit(gpa);

    var offset: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const null_pos = std.mem.indexOfScalarPos(u8, files, offset, 0) orelse break;
        const path_len = null_pos - offset;
        const path_ptr = files[offset..].ptr;
        offset = null_pos + 1;
        if (path_len == 0) continue;
        if (request.query.len == 0) {
            // Empty query: include every file with a neutral score so results
            // stay in walk order (the sort below is stable for equal scores).
            try scored.append(gpa, .{ .score = 0, .index = i });
        } else if (c.has_match(query_c.ptr, path_ptr) != 0) {
            try scored.append(gpa, .{ .score = c.match(query_c.ptr, path_ptr), .index = i });
        }
    }

    // Sort descending by score (stable — ties keep walk order).
    std.mem.sort(Scored, scored.items, {}, struct {
        fn lessThan(_: void, a: Scored, b: Scored) bool {
            return a.score > b.score;
        }
    }.lessThan);

    const total = scored.items.len;
    const start_idx = @min(cursor.offset, @as(u32, @intCast(total)));
    const end = @min(start_idx + page_size, @as(u32, @intCast(total)));

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const writer = &out.writer;

    if (total == 0) {
        try writer.writeAll("0 results.\n");
    } else {
        var k: u32 = start_idx;
        while (k < end) : (k += 1) {
            const entry = scored.items[k];
            const path = entryPath(files, count, entry.index);
            try writer.print("{s}\n", .{path});
        }
    }

    const next_offset = end;
    if (end > start_idx and next_offset < total) {
        const more_count = total - next_offset;
        const next_cursor = try encodeCursor(gpa, .{ .op = .find, .offset = next_offset, .query_hash = hashQuery(request.query) });
        defer gpa.free(next_cursor);
        try writer.print("\n+{} more results. Pass cursor=\"{s}\" to continue.\n", .{ more_count, next_cursor });
    }
    return okOwned(gpa, try out.toOwnedSlice());
}

/// Return the `index`-th path from the slab.
fn entryPath(files: []const u8, count: usize, index: usize) []const u8 {
    assert(index < count);
    var offset: usize = 0;
    var i: usize = 0;
    while (i < index) : (i += 1) {
        const path = std.mem.sliceTo(files[offset..], 0);
        offset += path.len + 1;
    }
    return std.mem.sliceTo(files[offset..], 0);
}

fn parseCursorForRequest(request: Request) !Cursor {
    if (request.cursor) |raw| {
        const cursor = decodeCursor(raw) orelse return error.InvalidCursor;
        if (cursor.op != request.op) return error.InvalidCursor;
        if (cursor.query_hash != hashQuery(request.query)) return error.InvalidCursor;
        return cursor;
    }
    return .{ .op = request.op, .offset = 0, .query_hash = hashQuery(request.query) };
}

fn encodeCursor(gpa: std.mem.Allocator, cursor: Cursor) ![]u8 {
    assert(cursor.offset > 0);
    return std.fmt.allocPrint(gpa, "nova-search-v2:{s}:{}:{x}", .{
        cursor.op.name(),
        cursor.offset,
        cursor.query_hash,
    });
}

fn decodeCursor(raw: []const u8) ?Cursor {
    if (raw.len == 0) return null;
    var iter = std.mem.splitScalar(u8, raw, ':');
    const prefix = iter.next() orelse return null;
    if (!std.mem.eql(u8, prefix, "nova-search-v2")) return null;
    const op = ops_by_name.get(iter.next() orelse return null) orelse return null;
    const offset = std.fmt.parseInt(u32, iter.next() orelse return null, 10) catch return null;
    const query_hash = std.fmt.parseInt(u64, iter.next() orelse return null, 16) catch return null;
    if (iter.next() != null) return null;
    if (offset == 0) return null;
    return .{ .op = op, .offset = offset, .query_hash = query_hash };
}

fn hashQuery(query: []const u8) u64 {
    return std.hash.Wyhash.hash(0x6e6f76615f736561, query);
}

fn okOwned(gpa: std.mem.Allocator, stdout: []u8) !Result {
    return .{ .stdout = stdout, .stderr = try gpa.alloc(u8, 0), .code = 0 };
}

test "cursor validates op and query" {
    const gpa = std.testing.allocator;
    const cursor = try encodeCursor(gpa, .{ .op = .find, .offset = 50, .query_hash = hashQuery("abc") });
    defer gpa.free(cursor);
    const parsed = decodeCursor(cursor) orelse return error.TestFailed;
    try std.testing.expectEqual(Op.find, parsed.op);
    try std.testing.expectEqual(@as(u32, 50), parsed.offset);
    try std.testing.expectEqual(hashQuery("abc"), parsed.query_hash);
}

test "fzy match scores a subsequence" {
    const gpa = std.testing.allocator;
    const needle = try gpa.dupeZ(u8, "main");
    defer gpa.free(needle);
    const hay = try gpa.dupeZ(u8, "src/main.zig");
    defer gpa.free(hay);
    try std.testing.expect(c.has_match(needle.ptr, hay.ptr) != 0);
    try std.testing.expect(c.match(needle.ptr, hay.ptr) > 0);
}

test "async query returns results" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    start(gpa, io, ".");
    defer deinit(gpa, io);

    // Wait for index.
    var tries: usize = 0;
    while (tries < 50) : (tries += 1) {
        if (try runIfReady(gpa, io, .{ .op = .find, .query = "main" })) |result| {
            var res = result;
            defer res.deinit(gpa);
            break;
        }
        io.sleep(std.Io.Duration.fromNanoseconds(10 * 1000 * 1000), .awake) catch {};
    } else return error.SearchStuckInIndexing;

    // Start async search and poll until it completes.
    try queryAsync(gpa, io, .{ .op = .find, .query = "main" });
    var polls: usize = 0;
    while (polls < 50) : (polls += 1) {
        if (try pollSearchResult(gpa, io)) |result| {
            var res = result;
            defer res.deinit(gpa);
            try std.testing.expect(res.stdout.len > 0);
            return;
        }
        io.sleep(std.Io.Duration.fromNanoseconds(10 * 1000 * 1000), .awake) catch {};
    }
    return error.AsyncSearchStuck;
}

test "empty query returns all indexed files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Walk synchronously — test IO does not reliably run io.concurrent.
    var dir = std.Io.Dir.openDir(.cwd(), io, ".", .{ .iterate = true }) catch unreachable;
    defer dir.close(io);

    var walker = dir.walkSelectively(gpa) catch unreachable;
    defer walker.deinit();

    var files: std.ArrayListUnmanaged(u8) = .empty;
    defer files.deinit(gpa);
    var count: usize = 0;

    while (walker.next(io) catch null) |entry| {
        if (entry.kind == .directory) {
            if (!isIgnoredDir(entry.basename)) walker.enter(io, entry) catch {};
            continue;
        }
        if (entry.kind != .file) continue;
        const path = entry.path;
        try files.ensureUnusedCapacity(gpa, path.len + 1);
        const slice = files.items.ptr[files.items.len..];
        @memcpy(slice[0..path.len], path);
        slice[path.len] = 0;
        files.items.len += path.len + 1;
        count += 1;
    }

    try std.testing.expect(count >= 100);

    var result = try runFind(gpa, .{ .op = .find, .query = "" }, files.items, count);
    defer result.deinit(gpa);

    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expect(result.status == .ok);
    // Output should have at least page_size (50) entries + the "+N more" footer.
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "+") != null);
}

test "start with nonexistent cwd transitions to failed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    start(gpa, io, "/does-not-exist-nova-test");
    defer deinit(gpa, io);

    var tries: usize = 0;
    while (tries < 50) : (tries += 1) {
        _ = try runIfReady(gpa, io, .{ .op = .find, .query = "main" });
        if (backend.lastFailure(gpa)) |msg| {
            defer gpa.free(msg);
            try std.testing.expect(msg.len > 0);
            return;
        }
        io.sleep(std.Io.Duration.fromNanoseconds(10 * 1000 * 1000), .awake) catch {};
    } else return error.SearchStuckInIndexing;
}

test "rapid queryAsync with different queries cancels cleanly" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    start(gpa, io, ".");
    defer deinit(gpa, io);

    var tries: usize = 0;
    while (tries < 50) : (tries += 1) {
        if (try runIfReady(gpa, io, .{ .op = .find, .query = "a" })) |result| {
            var res = result;
            defer res.deinit(gpa);
            break;
        }
        io.sleep(std.Io.Duration.fromNanoseconds(10 * 1000 * 1000), .awake) catch {};
    } else return error.SearchStuckInIndexing;

    // Fire a sequence of different queries; only one should win. Each
    // different query implicitly cancels the previous one via queryAsync.
    for ([_][]const u8{ "a", "ab", "abc", "abcd", "main" }) |q| {
        try queryAsync(gpa, io, .{ .op = .find, .query = q });
    }

    var polls: usize = 0;
    while (polls < 50) : (polls += 1) {
        if (try pollSearchResult(gpa, io)) |result| {
            var res = result;
            defer res.deinit(gpa);
            try std.testing.expect(res.status == .ok);
            try std.testing.expect(res.stdout.len > 0);
            return;
        }
        io.sleep(std.Io.Duration.fromNanoseconds(10 * 1000 * 1000), .awake) catch {};
    }
    return error.AsyncSearchStuck;
}

test "restart discards stale in-flight result" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    start(gpa, io, ".");
    defer deinit(gpa, io);

    // Wait for the first index.
    var tries: usize = 0;
    while (tries < 50) : (tries += 1) {
        if (try runIfReady(gpa, io, .{ .op = .find, .query = "main" })) |result| {
            var res = result;
            defer res.deinit(gpa);
            break;
        }
        io.sleep(std.Io.Duration.fromNanoseconds(10 * 1000 * 1000), .awake) catch {};
    } else return error.SearchStuckInIndexing;

    // Start a long-running broad query and restart before it finishes.
    try queryAsync(gpa, io, .{ .op = .find, .query = "a" });
    restart(gpa, io, ".");

    // The old search result must be discarded because the generation changed.
    var polls: usize = 0;
    while (polls < 5) : (polls += 1) {
        if (try pollSearchResult(gpa, io)) |result| {
            var res = result;
            defer res.deinit(gpa);
            return error.StaleResultNotDiscarded;
        }
        io.sleep(std.Io.Duration.fromNanoseconds(10 * 1000 * 1000), .awake) catch {};
    }

    // After the new index is ready, a fresh query must succeed.
    tries = 0;
    while (tries < 50) : (tries += 1) {
        if (try runIfReady(gpa, io, .{ .op = .find, .query = "main" })) |result| {
            var res = result;
            defer res.deinit(gpa);
            break;
        }
        io.sleep(std.Io.Duration.fromNanoseconds(10 * 1000 * 1000), .awake) catch {};
    } else return error.SearchStuckInIndexing;

    try queryAsync(gpa, io, .{ .op = .find, .query = "main" });

    polls = 0;
    while (polls < 50) : (polls += 1) {
        if (try pollSearchResult(gpa, io)) |result| {
            var res = result;
            defer res.deinit(gpa);
            try std.testing.expect(res.status == .ok);
            try std.testing.expect(res.stdout.len > 0);
            return;
        }
        io.sleep(std.Io.Duration.fromNanoseconds(10 * 1000 * 1000), .awake) catch {};
    }
    return error.AsyncSearchStuck;
}

test "async search for same query is debounced" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    start(gpa, io, ".");
    defer deinit(gpa, io);

    // Wait for index.
    var tries: usize = 0;
    while (tries < 50) : (tries += 1) {
        if (try runIfReady(gpa, io, .{ .op = .find, .query = "main" })) |result| {
            var res = result;
            defer res.deinit(gpa);
            break;
        }
        io.sleep(std.Io.Duration.fromNanoseconds(10 * 1000 * 1000), .awake) catch {};
    } else return error.SearchStuckInIndexing;

    try queryAsync(gpa, io, .{ .op = .find, .query = "main" });
    try queryAsync(gpa, io, .{ .op = .find, .query = "main" }); // same query should be a no-op

    var polls: usize = 0;
    var received_results: usize = 0;
    var grace_polls_remaining: ?usize = null;
    while (polls < 50) : (polls += 1) {
        if (try pollSearchResult(gpa, io)) |result| {
            var res = result;
            defer res.deinit(gpa);
            received_results += 1;
            if (grace_polls_remaining == null) grace_polls_remaining = 5;
        }
        io.sleep(std.Io.Duration.fromNanoseconds(10 * 1000 * 1000), .awake) catch {};
        if (grace_polls_remaining) |*rem| {
            if (rem.* == 0) break;
            rem.* -= 1;
        }
    }
    if (received_results == 0) return error.AsyncSearchStuck;
    try std.testing.expectEqual(@as(usize, 1), received_results);
}

test "async empty query returns results" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Walk synchronously — test IO does not reliably run io.concurrent.
    var dir = std.Io.Dir.openDir(.cwd(), io, ".", .{ .iterate = true }) catch unreachable;
    defer dir.close(io);

    var walker = dir.walkSelectively(gpa) catch unreachable;
    defer walker.deinit();

    var files: std.ArrayListUnmanaged(u8) = .empty;
    defer files.deinit(gpa);
    var count: usize = 0;

    while (walker.next(io) catch null) |entry| {
        if (entry.kind == .directory) {
            if (!isIgnoredDir(entry.basename)) walker.enter(io, entry) catch {};
            continue;
        }
        if (entry.kind != .file) continue;
        const path = entry.path;
        try files.ensureUnusedCapacity(gpa, path.len + 1);
        const slice = files.items.ptr[files.items.len..];
        @memcpy(slice[0..path.len], path);
        slice[path.len] = 0;
        files.items.len += path.len + 1;
        count += 1;
    }

    try std.testing.expect(count >= 100);

    var result = try runFind(gpa, .{ .op = .find, .query = "" }, files.items, count);
    defer result.deinit(gpa);

    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expect(result.status == .ok);
}

fn failingConcurrent(
    userdata: ?*anyopaque,
    result_len: usize,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start_fn: *const fn (context: *const anyopaque, result: *anyopaque) void,
) std.Io.ConcurrentError!*std.Io.AnyFuture {
    _ = userdata;
    _ = result_len;
    _ = result_alignment;
    _ = context;
    _ = context_alignment;
    _ = start_fn;
    return error.ConcurrencyUnavailable;
}

test "start_whenConcurrentFails_transitionsToFailedState" {
    // Arrange
    const gpa = std.testing.allocator;
    var mock_vtable = std.testing.io.vtable.*;
    mock_vtable.concurrent = failingConcurrent;
    const failing_io: std.Io = .{
        .userdata = std.testing.io.userdata,
        .vtable = &mock_vtable,
    };

    // Act
    start(gpa, failing_io, ".");
    defer deinit(gpa, std.testing.io);

    // Assert
    const msg = backend.lastFailure(gpa) orelse return error.TestExpectedFailureMessage;
    defer gpa.free(msg);
    try std.testing.expectEqualStrings("ConcurrencyUnavailable", msg);
}

test "queryAsync_whenConcurrentFails_returnsError" {
    // Arrange
    const gpa = std.testing.allocator;
    var mock_vtable = std.testing.io.vtable.*;
    mock_vtable.concurrent = failingConcurrent;
    const failing_io: std.Io = .{
        .userdata = std.testing.io.userdata,
        .vtable = &mock_vtable,
    };

    const files_slab = try gpa.dupe(u8, "main.zig\x00lib.zig\x00");
    backend.state = .{ .ready = .{ .files = files_slab, .count = 2 } };
    defer deinit(gpa, std.testing.io);

    // Act & Assert
    try std.testing.expectError(
        error.ConcurrencyUnavailable,
        queryAsync(gpa, failing_io, .{ .op = .find, .query = "main" }),
    );
}

test "initBackend returns failed outcome when walkSelectively allocation fails" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // fail_index = 1: alloc #0 (cwd_duped) succeeds; alloc #1
    // (dir.walkSelectively) fails with OutOfMemory. openDir does not
    // use the user-supplied allocator, so the sequence is deterministic.
    var failing_allocator = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 1 });
    const failing_gpa = failing_allocator.allocator();

    const cwd_duped = try failing_gpa.dupe(u8, ".");
    var done = std.atomic.Value(bool).init(false);

    var outcome = initBackend(failing_gpa, io, cwd_duped, &done);
    defer outcome.deinit(failing_gpa);

    try std.testing.expect(done.load(.monotonic));
    switch (outcome) {
        .failed => |msg| try std.testing.expectEqualStrings("", msg),
        else => return error.TestExpectedFailedOutcome,
    }
}

test "isIgnoredDir_whenNameInIgnoredList_returnsTrueAndFalseOtherwise" {
    // Arrange
    const sample_non_ignored = [_][]const u8{
        "src",
        "lib",
        "components",
        "docs",
        "assets",
        "main.zig",
        "git",
        "",
    };

    // Act & Assert - All ignored directory basenames must return true
    for (always_ignored_dirs) |ignored_dir| {
        try std.testing.expect(isIgnoredDir(ignored_dir));
    }

    // Act & Assert - Normal directory basenames must return false
    for (sample_non_ignored) |non_ignored_dir| {
        try std.testing.expect(!isIgnoredDir(non_ignored_dir));
    }
}
