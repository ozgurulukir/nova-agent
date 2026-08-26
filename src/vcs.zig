//! Typed seam over git for Nova's "shadow history" — the automation layer that
//! lets a developer branch and rewind an agent's work without polluting the
//! repo. Unlike the old jj-colocated approach, git HEAD stays *attached* to the
//! user's branch and no automation commit ever lands on it:
//!
//!   - A snapshot stages the whole working tree into a **dedicated index**
//!     (never the user's `.git/index`), writes a tree, and wraps it in a
//!     **parentless commit**. `git log`, `git status`, and `git branch` are
//!     untouched — the snapshot is reachable only through `refs/nova/*`.
//!   - Restoring a snapshot rewrites the working tree to that tree (adds,
//!     modifies, AND deletes tracked files), again without moving HEAD.
//!   - `git add -A` honors `.gitignore`, so build artifacts stay out of
//!     snapshots and are never clobbered on restore.
//!
//! The anchor between a conversation node and its code is a git **commit SHA**
//! (an `ObjectId`), stored on the session entry. Snapshots are immutable and
//! never rewritten, so the SHA always resolves — there is no need for jj's
//! rewrite-stable change-ids.

const std = @import("std");
const platform = @import("platform");
const os = @import("os.zig");
const paths = @import("paths.zig");

const assert = std.debug.assert;

const log = std.log.scoped(.vcs);

pub const Error = error{BadObjectId};

/// A git object id (commit or tree), validated as lowercase hex of a git hash
/// length (40 for SHA-1, 64 for SHA-256). `parse` is the only constructor, so a
/// value of this type is a syntactically valid object id by construction.
pub const ObjectId = struct {
    bytes: [max_len]u8,
    len: u8,

    pub const max_len: u8 = 64;

    pub fn parse(raw: []const u8) Error!ObjectId {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len != 40 and trimmed.len != 64) return error.BadObjectId;
        for (trimmed) |byte| {
            const ok = (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f');
            if (!ok) return error.BadObjectId;
        }
        var id: ObjectId = .{ .bytes = undefined, .len = @intCast(trimmed.len) };
        @memcpy(id.bytes[0..trimmed.len], trimmed);
        return id;
    }

    pub fn slice(self: *const ObjectId) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: ObjectId, other: ObjectId) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};

/// A lane's relationship to the working tree. `.primary` is the repo's own
/// working copy (the branch Nova launched on); `.working` is a parallel lane in
/// its own `git worktree` on a dedicated branch. Lanes run in isolation, but a
/// `.working` lane can be folded back into another lane with `merge` (`/merge`
/// and `/lanes`): the source's branch is merged into the destination's worktree
/// and the source worktree is then removed.
pub const Lane = union(enum) {
    primary,
    working: Working,

    pub const Working = struct {
        /// The lane's branch, e.g. `nova/<id>`. Owned.
        branch: []u8,
        /// Absolute path to the worktree directory. Owned.
        path: []u8,
    };

    pub fn deinit(self: *Lane, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .working => |w| {
                gpa.free(w.branch);
                gpa.free(w.path);
            },
            .primary => {},
        }
        self.* = undefined;
    }

    /// The directory an agent for this lane runs tools in, or null for
    /// `.primary` (the caller uses the repo root).
    pub fn workingPath(self: *const Lane) ?[]const u8 {
        return switch (self.*) {
            .working => |w| w.path,
            .primary => null,
        };
    }
};

// ===========================================================================
// git CLI boundary
//
// Everything below shells out to `git`, funnelling stdout through `ObjectId`.
// Stateless — callers pass the working-copy directory on each call. A missing
// binary surfaces as `GitNotFound` so callers can degrade.
// ===========================================================================

pub const CmdError = error{
    GitNotFound,
    GitSpawnFailed,
    GitCommandFailed,
    GitBadOutput,
    OutOfMemory,
} || Error;

const cmd_stdout_limit: usize = 256 * 1024;
const cmd_stderr_limit: usize = 64 * 1024;
const cmd_timeout_seconds: u32 = 30;

fn cmdTimeout() std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromSeconds(cmd_timeout_seconds), .clock = .awake } };
}

const Captured = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,

    fn deinit(self: *Captured, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
        self.* = undefined;
    }
};

/// Run one git subcommand in `cwd`. `args` must NOT include the binary — it is
/// prepended here. `env` overrides the child environment (used to point
/// `GIT_INDEX_FILE` at the dedicated snapshot index); null inherits this
/// process's environment.
fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    args: []const []const u8,
    env: ?*const std.process.Environ.Map,
) CmdError!Captured {
    assert(cwd.len > 0);
    assert(args.len > 0);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    try argv.appendSlice(gpa, args);

    const result = std.process.run(gpa, io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .environ_map = env,
        .stdout_limit = .limited(cmd_stdout_limit),
        .stderr_limit = .limited(cmd_stderr_limit),
        .timeout = cmdTimeout(),
    }) catch |err| return switch (err) {
        error.FileNotFound => error.GitNotFound,
        error.OutOfMemory => error.OutOfMemory,
        else => error.GitSpawnFailed,
    };
    return .{ .stdout = result.stdout, .stderr = result.stderr, .code = os.termCode(result.term) };
}

/// Run a git subcommand, returning its trimmed stdout on success (code 0) or a
/// typed error. The caller owns the returned slice.
pub fn runOut(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    args: []const []const u8,
    env: ?*const std.process.Environ.Map,
) CmdError![]u8 {
    var out = try run(gpa, io, cwd, args, env);
    errdefer out.deinit(gpa);
    if (out.code != 0) {
        out.deinit(gpa);
        return error.GitCommandFailed;
    }
    gpa.free(out.stderr);
    return out.stdout;
}

/// True when `git` can be invoked at all.
pub fn isAvailable(gpa: std.mem.Allocator, io: std.Io) bool {
    var out = run(gpa, io, ".", &.{"--version"}, null) catch return false;
    defer out.deinit(gpa);
    return out.code == 0;
}

/// True when `dir` is inside a git working tree. Gates the snapshot feature.
pub fn isRepo(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) bool {
    var out = run(gpa, io, dir, &.{ "rev-parse", "--is-inside-work-tree" }, null) catch return false;
    defer out.deinit(gpa);
    if (out.code != 0) return false;
    return std.mem.eql(u8, std.mem.trim(u8, out.stdout, " \t\r\n"), "true");
}

/// Get the current git branch name of `dir`, or null if detached / not a repo.
/// Caller owns the returned slice.
pub fn currentBranch(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) ?[]u8 {
    const out = runOut(gpa, io, dir, &.{ "rev-parse", "--abbrev-ref", "HEAD" }, null) catch return null;
    defer gpa.free(out);
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "HEAD")) return null;
    return gpa.dupe(u8, trimmed) catch null;
}

/// Whether the working tree of `dir` has any change versus HEAD (tracked edits
/// or new non-ignored files). Backs `/save`'s "nothing to save" guard.
pub fn workingTreeDirty(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) CmdError!bool {
    const out = try runOut(gpa, io, dir, &.{ "status", "--porcelain" }, null);
    defer gpa.free(out);
    return std.mem.trim(u8, out, " \t\r\n").len != 0;
}

/// Stage every non-ignored path and commit it onto the current branch with the
/// user's own git identity (this is a real commit they own, unlike snapshots).
/// Fails if git has no identity configured. This is all `/save` is now: HEAD is
/// attached, so committing the working tree advances the branch.
pub fn commitAll(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, message: []const u8) CmdError!void {
    assert(message.len > 0);
    {
        var out = try run(gpa, io, dir, &.{ "add", "-A" }, null);
        defer out.deinit(gpa);
        if (out.code != 0) return error.GitCommandFailed;
    }
    var out = try run(gpa, io, dir, &.{ "commit", "-m", message }, null);
    defer out.deinit(gpa);
    if (out.code != 0) return error.GitCommandFailed;
}

/// Build a child environment that inherits this process's variables and adds
/// `GIT_INDEX_FILE = index_path`, so the snapshot operations stage into the
/// dedicated index instead of the user's `.git/index`. Caller owns the map.
fn indexEnv(gpa: std.mem.Allocator, io: std.Io, index_path: []const u8) CmdError!std.process.Environ.Map {
    var map = try currentEnv(gpa, io);
    errdefer map.deinit();
    try map.put("GIT_INDEX_FILE", index_path);
    return map;
}

fn currentEnv(gpa: std.mem.Allocator, io: std.Io) CmdError!std.process.Environ.Map {
    _ = io;
    return platform.getEnvMap(gpa) catch error.OutOfMemory;
}

/// Resolve the path of Nova's dedicated snapshot index for `dir`. Uses
/// `git rev-parse --git-path` so the location is correct for both the main
/// working copy and linked worktrees (each gets its own). Caller owns the slice.
pub fn indexPath(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) CmdError![]u8 {
    const raw = try runOut(gpa, io, dir, &.{ "rev-parse", "--git-path", "nova-index" }, null);
    defer gpa.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.GitBadOutput;
    return gpa.dupe(u8, trimmed);
}

/// Snapshot the working tree of `dir` into an off-branch commit and return its
/// id. Stages every non-ignored path into the dedicated index (`git add -A`
/// honors `.gitignore`), writes the tree, and wraps it in a parentless commit.
/// HEAD, the user's index, and branch refs are untouched. Identical working
/// trees produce identical *tree* objects (content-addressed dedup); only the
/// tiny commit object is new. `index_path` comes from `indexPath`.
pub fn snapshot(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, index_path: []const u8) CmdError!ObjectId {
    const tree = try workingTreeId(gpa, io, dir, index_path);
    return commitTree(gpa, io, dir, tree);
}

/// Reconcile the dedicated index with the working tree (adds new, updates
/// modified, drops deleted — honoring `.gitignore`) and write it out as a tree
/// object, returning its id. Content-addressed, so an unchanged working tree
/// yields the *same* id — callers dedup on this to skip a no-op snapshot (the
/// "did this tool actually change anything?" check that doesn't trust output).
pub fn workingTreeId(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, index_path: []const u8) CmdError!ObjectId {
    var env = try indexEnv(gpa, io, index_path);
    defer env.deinit();
    {
        var out = try run(gpa, io, dir, &.{ "add", "-A" }, &env);
        defer out.deinit(gpa);
        if (out.code != 0) return error.GitCommandFailed;
    }
    const tree_raw = try runOut(gpa, io, dir, &.{"write-tree"}, &env);
    defer gpa.free(tree_raw);
    return ObjectId.parse(tree_raw);
}

/// Wrap `tree` in a parentless commit and return its id. `-c user.*` avoids
/// depending on the user having a git identity configured (snapshots are
/// Nova's, not the user's — unlike `/save`'s real commit).
pub fn commitTree(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, tree: ObjectId) CmdError!ObjectId {
    const commit_raw = try runOut(gpa, io, dir, &.{
        "-c",          "user.name=nova",
        "-c",          "user.email=nova@local",
        "commit-tree", tree.slice(),
        "-m",          "nova snapshot",
    }, null);
    defer gpa.free(commit_raw);
    return ObjectId.parse(commit_raw);
}

/// Rewrite the working tree of `dir` to match `rev`'s tree — adding, modifying,
/// and **deleting** tracked files as needed — without moving HEAD. Ignored
/// files are left alone. Used by timeline navigation to restore the code state
/// bound to a conversation node. `index_path` comes from `indexPath`.
pub fn restore(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, index_path: []const u8, rev: ObjectId) CmdError!void {
    var env = try indexEnv(gpa, io, index_path);
    defer env.deinit();

    // Sync the dedicated index to the current working tree first, so the
    // subsequent reset knows which files to remove (those present now but absent
    // in the target tree).
    {
        var out = try run(gpa, io, dir, &.{ "add", "-A" }, &env);
        defer out.deinit(gpa);
        if (out.code != 0) return error.GitCommandFailed;
    }
    const tree_spec = std.fmt.allocPrint(gpa, "{s}^{{tree}}", .{rev.slice()}) catch return error.OutOfMemory;
    defer gpa.free(tree_spec);
    var out = try run(gpa, io, dir, &.{ "read-tree", "-u", "--reset", tree_spec }, &env);
    defer out.deinit(gpa);
    if (out.code != 0) {
        // B4: a restore failure leaves the working tree on the wrong node —
        // surface it in the operator log so it is not silent. The caller
        // (session_switcher.restoreCheckpointForBranch) swallows the error and
        // leaves the tree as-is; this log is the only visibility. Use `warn`
        // not `err` — `log.err` trips the test-runner success gate (AGENTS.md
        // §Logging). The `warn` sink is active in all builds incl. ReleaseFast.
        log.warn("vcs.restore failed dir={s} rev={s} code={d} stderr={s}", .{
            dir, rev.slice(), out.code, std.mem.trim(u8, out.stderr, " \t\r\n"),
        });
        return error.GitCommandFailed;
    }
}

/// Read the contents of `path` as it exists at `rev` (a branch name, commit, or
/// snapshot id), without touching the working tree. Backs the agent's
/// cross-branch reads. Caller owns the returned slice.
pub fn showFile(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, rev: []const u8, path: []const u8) CmdError![]u8 {
    const spec = std.fmt.allocPrint(gpa, "{s}:{s}", .{ rev, path }) catch return error.OutOfMemory;
    defer gpa.free(spec);
    return runOut(gpa, io, dir, &.{ "show", spec }, null);
}

/// Create a parallel-lane worktree at `path` on a fresh `branch` forked from
/// the current HEAD of `repo_dir`. The new worktree has its own working copy,
/// branch, and (via `git rev-parse --git-path`) its own snapshot index — fully
/// isolated from the source lane.
pub fn worktreeAdd(gpa: std.mem.Allocator, io: std.Io, repo_dir: []const u8, path: []const u8, branch: []const u8) CmdError!void {
    var out = try run(gpa, io, repo_dir, &.{ "worktree", "add", "-b", branch, path }, null);
    defer out.deinit(gpa);
    if (out.code != 0) return error.GitCommandFailed;
}

/// Remove a lane's worktree (and its working directory). `--force` because the
/// lane's uncommitted snapshots live off-branch, so a "dirty" worktree is normal
/// and shouldn't block teardown. Retries up to 4 times on Windows with backoff
/// (50ms, 150ms, 300ms) to accommodate transient file locks.
pub fn worktreeRemove(gpa: std.mem.Allocator, io: std.Io, repo_dir: []const u8, path: []const u8) CmdError!void {
    const max_attempts: u32 = if (os.is_windows) 4 else 1;
    var attempt: u32 = 1;

    while (attempt <= max_attempts) : (attempt += 1) {
        var out = try run(gpa, io, repo_dir, &.{ "worktree", "remove", "--force", path }, null);
        defer out.deinit(gpa);
        if (out.code == 0) return;

        if (attempt < max_attempts and os.is_windows) {
            const delay_ms: i64 = switch (attempt) {
                1 => 50,
                2 => 150,
                else => 300,
            };
            io.sleep(.fromMilliseconds(delay_ms), .awake) catch {};
            continue;
        }

        log.warn("vcs.worktreeRemove failed repo={s} path={s} code={d} stderr={s}", .{
            repo_dir, path, out.code, std.mem.trim(u8, out.stderr, " \t\r\n"),
        });
        return error.GitCommandFailed;
    }
}

pub const worktree_retention_days: u64 = 7;
pub const worktree_retention_ns: u64 = worktree_retention_days * 24 * 60 * 60 * std.time.ns_per_s;

/// Resolve the global worktree directory path.
/// Platform-correct base: Windows -> %APPDATA%\nova/worktrees, POSIX -> ~/.config/nova/worktrees.
pub fn globalWorktreesDir(gpa: std.mem.Allocator, home_dir: []const u8) ![]u8 {
    const base = try paths.platformConfigDir(gpa, home_dir);
    errdefer gpa.free(base);
    const dir = try std.fs.path.join(gpa, &.{ base, "worktrees" });
    gpa.free(base);
    return dir;
}

test "globalWorktreesDir: resolves under the platform config dir" {
    const gpa = std.testing.allocator;
    const dir = try globalWorktreesDir(gpa, "PREFIX");
    defer gpa.free(dir);
    try std.testing.expect(std.mem.endsWith(u8, dir, "worktrees"));
    const base = try paths.platformConfigDir(gpa, "PREFIX");
    defer gpa.free(base);
    const expected = try std.fs.path.join(gpa, &.{ base, "worktrees" });
    defer gpa.free(expected);
    try std.testing.expect(paths.pathsEqual(dir, expected));
}

/// Scans the global worktrees directory and deletes abandoned worktree checkouts
/// older than `max_age_ns`. Runs during startup hygiene before the TUI initializes.
pub fn gcOrphanedWorktrees(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, max_age_ns: u64) void {
    if (home_dir.len == 0) return;
    const parent = globalWorktreesDir(gpa, home_dir) catch return;
    defer gpa.free(parent);
    gcWorktreesDir(io, parent, max_age_ns);
}

/// Directory-parameterized core of `gcOrphanedWorktrees` so unit tests can
/// target a scratch directory.
pub fn gcWorktreesDir(io: std.Io, dir_path: []const u8, max_age_ns: u64) void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    const now = std.Io.Timestamp.now(io, .real);
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const st = dir.statFile(io, entry.name, .{}) catch continue;
        const age_ns = st.mtime.durationTo(now).nanoseconds;
        if (age_ns > 0 and @as(u128, @intCast(age_ns)) > max_age_ns) {
            dir.deleteTree(io, entry.name) catch continue;
            log.info("vcs.gc: pruned orphaned worktree {s}", .{entry.name});
        }
    }
}

/// Prune working tree metadata in `.git/worktrees`. Uses `--expire now` so
/// newly-orphaned worktree metadata is cleaned up immediately.
pub fn worktreePrune(gpa: std.mem.Allocator, io: std.Io, repo_dir: []const u8) CmdError!void {
    var out = try run(gpa, io, repo_dir, &.{ "worktree", "prune", "--expire", "now" }, null);
    defer out.deinit(gpa);
    if (out.code != 0) return error.GitCommandFailed;
}

/// Delete a lane's branch (best-effort; `-D` force-deletes even if unmerged).
pub fn deleteBranch(gpa: std.mem.Allocator, io: std.Io, repo_dir: []const u8, branch: []const u8) CmdError!void {
    var out = try run(gpa, io, repo_dir, &.{ "branch", "-D", branch }, null);
    defer out.deinit(gpa);
    // A missing branch is fine — this is cleanup.
}

/// Rename `old` to `new` (e.g. when the model names a lane's hex branch).
/// Fails if `new` already exists; worktree HEADs checked out on `old` follow
/// the rename, so this is safe while an agent works in the lane's worktree.
pub fn renameBranch(gpa: std.mem.Allocator, io: std.Io, repo_dir: []const u8, old: []const u8, new: []const u8) CmdError!void {
    var out = try run(gpa, io, repo_dir, &.{ "branch", "-m", old, new }, null);
    defer out.deinit(gpa);
    if (out.code != 0) return error.GitCommandFailed;
}

/// Outcome of a lane merge. `.conflict` covers both content conflicts and a
/// dirty destination that git refuses to overwrite — in either case the merge
/// was rolled back (`git merge --abort`) so the destination is left untouched.
pub const MergeOutcome = enum { ok, conflict };

/// Merge `branch` into the working tree of `dir` (the destination lane's
/// worktree, on its own branch). A clean merge returns `.ok`; anything git
/// refuses — content conflicts or a dirty tree it would clobber — is rolled
/// back with `git merge --abort` and returns `.conflict`, so a denied merge
/// never leaves the destination half-merged.
pub fn merge(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, branch: []const u8) CmdError!MergeOutcome {
    var out = try run(gpa, io, dir, &.{ "merge", "--no-edit", branch }, null);
    defer out.deinit(gpa);
    if (out.code == 0) return .ok;
    // Roll back so the destination worktree is exactly as it was pre-merge.
    var abort = try run(gpa, io, dir, &.{ "merge", "--abort" }, null);
    abort.deinit(gpa);
    return .conflict;
}

/// One entry from `git worktree list` — an absolute worktree `path` and the
/// `branch` checked out there (short name, e.g. `nova/<id>`). Both owned.
pub const WorktreeEntry = struct {
    path: []u8,
    branch: []u8,

    pub fn deinit(self: *WorktreeEntry, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.branch);
        self.* = undefined;
    }
};

/// List every linked worktree of `repo_dir` and the branch each has checked out.
/// Parses `git worktree list --porcelain` (records separated by blank lines,
/// `worktree <path>` + `branch refs/heads/<name>` lines). Detached or
/// branchless worktrees are skipped. Backs `/lanes`, which filters to parked
/// `nova/*` lanes. Caller owns the slice — free with `freeWorktreeList`.
pub fn worktreeList(gpa: std.mem.Allocator, io: std.Io, repo_dir: []const u8) CmdError![]WorktreeEntry {
    const raw = try runOut(gpa, io, repo_dir, &.{ "worktree", "list", "--porcelain" }, null);
    defer gpa.free(raw);

    var entries: std.ArrayList(WorktreeEntry) = .empty;
    errdefer {
        for (entries.items) |*entry| entry.deinit(gpa);
        entries.deinit(gpa);
    }

    var path: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "worktree ")) {
            path = std.mem.trim(u8, trimmed["worktree ".len..], " \t\r");
        } else if (std.mem.startsWith(u8, trimmed, "branch ")) {
            const ref = std.mem.trim(u8, trimmed["branch ".len..], " \t\r");
            const name = if (std.mem.startsWith(u8, ref, "refs/heads/")) ref["refs/heads/".len..] else ref;
            const p = path orelse continue;
            const path_dup = try gpa.dupe(u8, p);
            errdefer gpa.free(path_dup);
            const branch_dup = try gpa.dupe(u8, name);
            errdefer gpa.free(branch_dup);
            try entries.append(gpa, .{ .path = path_dup, .branch = branch_dup });
        }
    }
    return entries.toOwnedSlice(gpa);
}

/// Free a slice returned by `worktreeList`.
pub fn freeWorktreeList(gpa: std.mem.Allocator, entries: []WorktreeEntry) void {
    for (entries) |*entry| entry.deinit(gpa);
    gpa.free(entries);
}

/// Point a `refs/nova/<name>` ref at `sha` so the snapshot survives `git gc`.
/// `name` must be a ref-safe path segment (the caller passes a session/entry id).
pub fn keepRef(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8, sha: ObjectId) CmdError!void {
    const ref = std.fmt.allocPrint(gpa, "refs/nova/{s}", .{name}) catch return error.OutOfMemory;
    defer gpa.free(ref);
    var out = try run(gpa, io, dir, &.{ "update-ref", ref, sha.slice() }, null);
    defer out.deinit(gpa);
    if (out.code != 0) return error.GitCommandFailed;
}

/// Drop a `refs/nova/<name>` ref (e.g. when pruning an abandoned timeline
/// branch). The underlying objects become unreachable and are collected by a
/// later `git gc`. Missing ref is not an error.
pub fn dropRef(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8) CmdError!void {
    const ref = std.fmt.allocPrint(gpa, "refs/nova/{s}", .{name}) catch return error.OutOfMemory;
    defer gpa.free(ref);
    var out = try run(gpa, io, dir, &.{ "update-ref", "-d", ref }, null);
    defer out.deinit(gpa);
    // `update-ref -d` on a missing ref exits non-zero; treat that as success.
}

test "ObjectId.parse accepts 40/64 lowercase hex, trims, rejects the rest" {
    const sha1 = "0123456789abcdef0123456789abcdef01234567"; // 40
    const ok = try ObjectId.parse("  " ++ sha1 ++ "\n");
    try std.testing.expectEqual(@as(u8, 40), ok.len);
    try std.testing.expectEqualStrings(sha1, ok.slice());

    _ = try ObjectId.parse("a" ** 64); // SHA-256 length
    try std.testing.expectError(error.BadObjectId, ObjectId.parse(""));
    try std.testing.expectError(error.BadObjectId, ObjectId.parse("abc")); // too short
    try std.testing.expectError(error.BadObjectId, ObjectId.parse("g" ** 40)); // non-hex
    try std.testing.expectError(error.BadObjectId, ObjectId.parse("ABCDEF" ** 7 ++ "ab")); // uppercase
}

test "ObjectId.eql compares the live slice" {
    const a = try ObjectId.parse("0" ** 40);
    const b = try ObjectId.parse("0" ** 40);
    const c = try ObjectId.parse("0" ** 39 ++ "1");
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "git shadow: snapshot ignores artifacts, restore adds/deletes, HEAD stays clean" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!isAvailable(gpa, io)) return error.SkipZigTest;

    var rand: [8]u8 = undefined;
    io.random(&rand);
    const hex = std.fmt.bytesToHex(rand, .lower);
    const name = try std.fmt.allocPrint(gpa, "nova-vcstest-{s}", .{hex[0..]});
    defer gpa.free(name);

    try std.Io.Dir.cwd().createDirPath(io, name);
    defer std.Io.Dir.cwd().deleteTree(io, name) catch {};

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo = try std.fs.path.join(gpa, &.{ cwd, name });
    defer gpa.free(repo);

    // init + a baseline commit so HEAD is attached to a branch.
    try expectOk(gpa, io, repo, &.{ "init", "-q" });
    try expectOk(gpa, io, repo, &.{ "config", "core.autocrlf", "false" });
    try expectOk(gpa, io, repo, &.{ "-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "-qm", "baseline" });

    const head_before = try runOut(gpa, io, repo, &.{ "rev-parse", "HEAD" }, null);
    defer gpa.free(head_before);

    const index = try indexPath(gpa, io, repo);
    defer gpa.free(index);

    // `.gitignore` excludes build output; write a tracked file + an ignored one.
    try writeFileRel(io, name, ".gitignore", "build/\n");
    try writeFileRel(io, name, "a.txt", "A\n");
    try writeFileRel(io, name, "build/x", "junk\n");

    const s1 = try snapshot(gpa, io, repo, index);
    // The ignored file must NOT be in the snapshot tree; the tracked one must be.
    {
        const listing = try runOut(gpa, io, repo, &.{ "ls-tree", "-r", "--name-only", s1.slice() }, null);
        defer gpa.free(listing);
        try std.testing.expect(std.mem.indexOf(u8, listing, "a.txt") != null);
        try std.testing.expect(std.mem.indexOf(u8, listing, "build/x") == null);
    }

    // Second snapshot: delete a.txt, add b.txt — a different tree.
    const a_path = try std.fs.path.join(gpa, &.{ name, "a.txt" });
    defer gpa.free(a_path);
    try std.Io.Dir.cwd().deleteFile(io, a_path);
    try writeFileRel(io, name, "b.txt", "B\n");
    const s2 = try snapshot(gpa, io, repo, index);
    try std.testing.expect(!(try treeOf(gpa, io, repo, s1)).eql(try treeOf(gpa, io, repo, s2)));

    // Restore s1, then re-snapshot the worktree: matching trees proves the
    // working copy was rewritten exactly to s1 (a.txt re-added, b.txt deleted).
    try restore(gpa, io, repo, index, s1);
    const after = try snapshot(gpa, io, repo, index);
    try std.testing.expect((try treeOf(gpa, io, repo, after)).eql(try treeOf(gpa, io, repo, s1)));

    // showFile reads a path out of a snapshot without touching the worktree.
    {
        const content = try showFile(gpa, io, repo, s1.slice(), "a.txt");
        defer gpa.free(content);
        try std.testing.expectEqualStrings("A\n", content);
    }

    // keepRef makes a snapshot survive an aggressive gc; dropRef lets it go.
    try keepRef(gpa, io, repo, name, s1);
    try expectOk(gpa, io, repo, &.{ "gc", "--prune=now", "-q" });
    {
        const kept = try runOut(gpa, io, repo, &.{ "cat-file", "-t", s1.slice() }, null);
        defer gpa.free(kept);
        try std.testing.expectEqualStrings("commit", std.mem.trim(u8, kept, " \t\r\n"));
    }

    // HEAD never moved and history stays a single commit (no snapshot pollution).
    const head_after = try runOut(gpa, io, repo, &.{ "rev-parse", "HEAD" }, null);
    defer gpa.free(head_after);
    try std.testing.expectEqualStrings(
        std.mem.trim(u8, head_before, " \t\r\n"),
        std.mem.trim(u8, head_after, " \t\r\n"),
    );
    const count = try runOut(gpa, io, repo, &.{ "rev-list", "--count", "HEAD" }, null);
    defer gpa.free(count);
    try std.testing.expectEqualStrings("1", std.mem.trim(u8, count, " \t\r\n"));
}

test "workingTreeDirty: false on clean tree, true after edits" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!isAvailable(gpa, io)) return error.SkipZigTest;

    var rand: [8]u8 = undefined;
    io.random(&rand);
    const hex = std.fmt.bytesToHex(rand, .lower);
    const name = try std.fmt.allocPrint(gpa, "nova-dirtytest-{s}", .{hex[0..]});
    defer gpa.free(name);

    try std.Io.Dir.cwd().createDirPath(io, name);
    defer std.Io.Dir.cwd().deleteTree(io, name) catch {};

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo = try std.fs.path.join(gpa, &.{ cwd, name });
    defer gpa.free(repo);

    // init + a baseline commit so HEAD is attached to a branch.
    try expectOk(gpa, io, repo, &.{ "init", "-q" });
    try expectOk(gpa, io, repo, &.{ "config", "core.autocrlf", "false" });
    try expectOk(gpa, io, repo, &.{ "config", "user.name", "t" });
    try expectOk(gpa, io, repo, &.{ "config", "user.email", "t@t" });
    try expectOk(gpa, io, repo, &.{ "commit", "--allow-empty", "-qm", "baseline" });

    // clean initially
    try std.testing.expectEqual(false, try workingTreeDirty(gpa, io, repo));

    // adding a file makes it dirty
    try writeFileRel(io, name, "a.txt", "A\n");
    try std.testing.expectEqual(true, try workingTreeDirty(gpa, io, repo));

    // committing makes it clean
    try expectOk(gpa, io, repo, &.{ "add", "-A" });
    try expectOk(gpa, io, repo, &.{ "commit", "-qm", "add a" });
    try std.testing.expectEqual(false, try workingTreeDirty(gpa, io, repo));

    // modifying tracked file makes it dirty
    try writeFileRel(io, name, "a.txt", "B\n");
    try std.testing.expectEqual(true, try workingTreeDirty(gpa, io, repo));
    try expectOk(gpa, io, repo, &.{ "add", "-A" });
    try expectOk(gpa, io, repo, &.{ "commit", "-qm", "mod a" });
    try std.testing.expectEqual(false, try workingTreeDirty(gpa, io, repo));

    // ignoring a file makes it clean (after committing the gitignore)
    try writeFileRel(io, name, ".gitignore", "build/\n");
    try expectOk(gpa, io, repo, &.{ "add", "-A" });
    try expectOk(gpa, io, repo, &.{ "commit", "-qm", "add gitignore" });
    try std.testing.expectEqual(false, try workingTreeDirty(gpa, io, repo));

    try writeFileRel(io, name, "build/ignored.txt", "ignored\n");
    try std.testing.expectEqual(false, try workingTreeDirty(gpa, io, repo));
}

test "worktree lanes: list finds lane branches, merge folds one in, conflict rolls back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!isAvailable(gpa, io)) return error.SkipZigTest;

    var rand: [8]u8 = undefined;
    io.random(&rand);
    const hex = std.fmt.bytesToHex(rand, .lower);
    const name = try std.fmt.allocPrint(gpa, "nova-mergetest-{s}", .{hex[0..]});
    defer gpa.free(name);

    try std.Io.Dir.cwd().createDirPath(io, name);
    defer std.Io.Dir.cwd().deleteTree(io, name) catch {};

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo = try std.fs.path.join(gpa, &.{ cwd, name });
    defer gpa.free(repo);

    // Baseline commit with a git identity so worktree commits inherit it.
    try expectOk(gpa, io, repo, &.{ "init", "-q" });
    try expectOk(gpa, io, repo, &.{ "config", "core.autocrlf", "false" });
    try expectOk(gpa, io, repo, &.{ "config", "user.name", "t" });
    try expectOk(gpa, io, repo, &.{ "config", "user.email", "t@t" });
    try writeFileRel(io, name, "base.txt", "base\n");
    try expectOk(gpa, io, repo, &.{ "add", "-A" });
    try expectOk(gpa, io, repo, &.{ "commit", "-qm", "baseline" });

    // Two lanes forked from HEAD (nested under the repo; git tracks them as
    // linked worktrees, not files).
    const dest = try std.fs.path.join(gpa, &.{ repo, "wt-dest" });
    defer gpa.free(dest);
    const src = try std.fs.path.join(gpa, &.{ repo, "wt-src" });
    defer gpa.free(src);
    try worktreeAdd(gpa, io, repo, dest, "nova/dest");
    try worktreeAdd(gpa, io, repo, src, "nova/src");

    // worktreeList reports both lane branches.
    {
        const list = try worktreeList(gpa, io, repo);
        defer freeWorktreeList(gpa, list);
        var saw_src = false;
        var saw_dest = false;
        for (list) |entry| {
            if (std.mem.eql(u8, entry.branch, "nova/src")) saw_src = true;
            if (std.mem.eql(u8, entry.branch, "nova/dest")) saw_dest = true;
        }
        try std.testing.expect(saw_src and saw_dest);
    }

    // Non-conflicting work on the source lane; commit it onto nova/src.
    try writeFileRel(io, name, "wt-src/feature.txt", "feature\n");
    try expectOk(gpa, io, src, &.{ "add", "-A" });
    try expectOk(gpa, io, src, &.{ "commit", "-qm", "feat" });

    // Merge folds the source lane's file into the destination worktree.
    try std.testing.expectEqual(MergeOutcome.ok, try merge(gpa, io, dest, "nova/src"));
    {
        const merged = try showFile(gpa, io, dest, "HEAD", "feature.txt");
        defer gpa.free(merged);
        try std.testing.expectEqualStrings("feature\n", merged);
    }

    // Divergent edits to the same file on each lane → conflict, rolled back.
    try writeFileRel(io, name, "wt-src/base.txt", "src-change\n");
    try expectOk(gpa, io, src, &.{ "commit", "-aqm", "src edit" });
    try writeFileRel(io, name, "wt-dest/base.txt", "dest-change\n");
    try expectOk(gpa, io, dest, &.{ "commit", "-aqm", "dest edit" });
    try std.testing.expectEqual(MergeOutcome.conflict, try merge(gpa, io, dest, "nova/src"));

    // The abort left the destination exactly as it was — no half-merge.
    const restored = try showFile(gpa, io, dest, "HEAD", "base.txt");
    defer gpa.free(restored);
    try std.testing.expectEqualStrings("dest-change\n", restored);
}

test "worktreePrune executes cleanly on empty or populated repo" {
    if (!isAvailable(std.testing.allocator, std.testing.io)) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var rand: [8]u8 = undefined;
    io.random(&rand);
    const hex = std.fmt.bytesToHex(rand, .lower);
    const name = try std.fmt.allocPrint(gpa, "nova-vcsprune-{s}", .{hex[0..]});
    defer gpa.free(name);

    try std.Io.Dir.cwd().createDirPath(io, name);
    defer std.Io.Dir.cwd().deleteTree(io, name) catch {};

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo = try std.fs.path.join(gpa, &.{ cwd, name });
    defer gpa.free(repo);

    try expectOk(gpa, io, repo, &.{ "init", "-q" });
    try worktreePrune(gpa, io, repo);
}

test "gcWorktreesDir prunes old directories and leaves recent directories untouched" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var rand: [8]u8 = undefined;
    io.random(&rand);
    const hex = std.fmt.bytesToHex(rand, .lower);
    const name = try std.fmt.allocPrint(gpa, "nova-vcsgc-{s}", .{hex[0..]});
    defer gpa.free(name);

    try std.Io.Dir.cwd().createDirPath(io, name);
    defer std.Io.Dir.cwd().deleteTree(io, name) catch {};

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const parent_dir = try std.fs.path.join(gpa, &.{ cwd, name });
    defer gpa.free(parent_dir);

    // Create two mock worktrees
    const recent = try std.fs.path.join(gpa, &.{ parent_dir, "recent-wt" });
    defer gpa.free(recent);
    try std.Io.Dir.cwd().createDirPath(io, recent);

    const stale = try std.fs.path.join(gpa, &.{ parent_dir, "stale-wt" });
    defer gpa.free(stale);
    try std.Io.Dir.cwd().createDirPath(io, stale);

    // Running GC with a huge retention window (7 days) leaves both untouched
    gcWorktreesDir(io, parent_dir, worktree_retention_ns);
    try std.Io.Dir.accessAbsolute(io, recent, .{});
    try std.Io.Dir.accessAbsolute(io, stale, .{});

    // Running GC with 0 max_age prunes both
    gcWorktreesDir(io, parent_dir, 0);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, recent, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, stale, .{}));
}

fn expectOk(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, args: []const []const u8) !void {
    var out = try run(gpa, io, dir, args, null);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), out.code);
}

fn treeOf(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, rev: ObjectId) !ObjectId {
    const spec = try std.fmt.allocPrint(gpa, "{s}^{{tree}}", .{rev.slice()});
    defer gpa.free(spec);
    const raw = try runOut(gpa, io, dir, &.{ "rev-parse", spec }, null);
    defer gpa.free(raw);
    return ObjectId.parse(raw);
}

fn writeFileRel(io: std.Io, repo_name: []const u8, rel: []const u8, content: []const u8) !void {
    const gpa = std.testing.allocator;
    const full = try std.fs.path.join(gpa, &.{ repo_name, rel });
    defer gpa.free(full);
    if (std.fs.path.dirname(rel)) |sub| {
        const dir = try std.fs.path.join(gpa, &.{ repo_name, sub });
        defer gpa.free(dir);
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    var f = try std.Io.Dir.createFile(.cwd(), io, full, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, content);
}
