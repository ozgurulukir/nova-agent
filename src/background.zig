//! BackgroundManager — runs long-lived bash commands (`run_in_background`) off
//! the turn loop so the agent is not blocked. Each job streams its merged
//! stdout/stderr to a stable log file (so the model can `tail` it), keeps a
//! bounded in-memory tail for the completion notice, and runs its own reader
//! thread that waits for exit.
//!
//! Threading: the manager is reachable from the UI thread (poll/cancel/shutdown)
//! and owns one reader `std.Thread` per job. The reader only touches its own
//! `Job` (via atomics for the bits the UI reads) and the log file — never the
//! agent or the session — so the only shared state is the job list, guarded by a
//! plain mutex. Delivery back to the agent is pull-based: the UI drains finished
//! jobs each tick (see `takeFinished`) and enqueues the notice itself, keeping
//! all agent/history mutation on the UI/worker threads.
//!
//! Lifecycle: a clean exit (and the modal's cancel) calls `terminateTree`, which
//! kills the whole process tree — `taskkill /T` on Windows, `kill` on POSIX.
//! TODO: Address orphaned processes when an unexpected exit happens.

const std = @import("std");

const bash = @import("tools/bash_exec.zig");
const pws = @import("tools/pwsh_exec.zig");
const temp_files = @import("tools/temp_files.zig");
const os = @import("os.zig");
const platform = @import("platform");
const paths = @import("paths.zig");

const assert = std.debug.assert;

/// Bounded in-memory tail kept per job for the completion notice. The full
/// output always lives in the log file; this is only what the model sees inline.
const tail_bytes_max: usize = 8 * 1024;
const read_reserve: usize = 64 * 1024;

/// Output cap for the synchronous `taskkill.exe` drain — the output is
/// discarded, so this only bounds memory.
const taskkill_output_limit: usize = 64 * 1024;
/// Test-only bound for the "poll until the background job lands" loops.
const test_poll_attempts_max: u32 = 100;

/// Maximum log file size per background job before truncation kicks in (50 MB).
pub const max_job_log_bytes: u64 = 50 * 1024 * 1024;

pub const BackgroundManager = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Guards the job list and the per-job display fields. Blocking mutex;
    /// critical sections are short and take no I/O, and the reader threads
    /// never acquire it, so a `join` under the lock can't deadlock.
    mutex: std.Io.Mutex = .init,
    next_id: u32 = 1,
    jobs: std.ArrayList(*Job) = .empty,

    pub const StartOptions = struct {
        command: []const u8,
        cwd: []const u8,
        env_map: *const std.process.Environ.Map,
        /// Opaque token (the owning `*Agent`) handed back at completion so the UI
        /// routes the delivery to the right lane. The manager never derefs it.
        owner: *anyopaque,
        /// The resolved shell executable (bash path on POSIX, pwsh.exe/powershell.exe
        /// on Windows). Spawned with the argv shape implied by `command_mode`.
        shell_path: []const u8,
        /// How to pass `command` to the shell: `bash -c <merged>` vs
        /// `pwsh -NoLogo -NonInteractive -Command -` (script fed on stdin).
        command_mode: CommandMode,
        /// Prefix/suffix wrapped around `command` to merge stderr into stdout and
        /// normalize the exit code, so the reader can stay a `Buffer(1)` (stderr is
        /// part of the command text, not a separate pipe) in every mode.
        ///
        /// - bash: prefix `"exec 2>&1\n"`, suffix `""`.
        /// - pwsh: prefix `"& {\n"`, suffix `"\n} 2>&1\nif (-not $?) { exit 1 } else { exit $LASTEXITCODE }"`.
        stderr_merge_prefix: []const u8,
        stderr_merge_suffix: []const u8,
    };

    /// How a background job passes its `command` to the shell.
    pub const CommandMode = enum {
        /// `bash -c <merged>` (single argv string; the classic bash shape).
        argv_dash_c,
        /// `pwsh -NoLogo -NonInteractive -Command -` with `merged` fed on stdin.
        stdin_dash_command,
    };

    /// What the bash tool needs to tell the model after a launch. Owned by the
    /// caller; free with `deinit`.
    pub const StartResult = struct {
        id: u32,
        label: []u8,
        pid: i64,
        log_path: []u8,

        pub fn deinit(self: *StartResult, gpa: std.mem.Allocator) void {
            gpa.free(self.label);
            gpa.free(self.log_path);
            self.* = undefined;
        }
    };

    /// A read-only snapshot of one running job for the TUI modal. Owned by the
    /// caller; free the slice with `freeViews`.
    pub const JobView = struct {
        id: u32,
        label: []u8,
        command: []u8,
        log_path: []u8,
        elapsed_seconds: u64,
    };

    /// A finished job handed to the UI. `completion_message` is the model-facing
    /// notice (null when the job was killed by the user/shutdown — those are
    /// surfaced in the transcript but not delivered to the model). Owned by the
    /// caller; free with `deinit`.
    pub const Finished = struct {
        id: u32,
        label: []u8,
        command: []u8,
        exit_code: u8,
        killed: bool,
        completion_message: ?[]u8,
        owner: *anyopaque,

        pub fn deinit(self: *Finished, gpa: std.mem.Allocator) void {
            gpa.free(self.label);
            gpa.free(self.command);
            if (self.completion_message) |m| gpa.free(m);
            self.* = undefined;
        }
    };

    const State = enum(u8) { running, finished };

    const Job = struct {
        manager: *BackgroundManager,
        id: u32,
        label: []u8,
        command: []u8,
        cwd: []u8,
        log_path: []u8,
        pid: i64,
        owner: *anyopaque,
        started: std.Io.Timestamp,
        child: std.process.Child,
        log_file: std.Io.File,
        /// Temp `.ps1` script file for a pwsh background job (null for bash
        /// `-c` jobs). Owned by the job; deleted in `destroyJob`.
        script_path: ?[]u8 = null,
        tail: std.ArrayList(u8) = .empty,
        thread: ?std.Thread = null,
        state: std.atomic.Value(State) = .init(.running),
        killed: std.atomic.Value(bool) = .init(false),
        exit_code: u8 = 0,
        completion_message: ?[]u8 = null,
        reported: bool = false,
        bytes_written: u64 = 0,
        truncated: bool = false,
    };

    pub fn init(io: std.Io, gpa: std.mem.Allocator) BackgroundManager {
        return .{ .io = io, .gpa = gpa };
    }

    /// Spawn `opts.command` under bash with stderr merged into stdout, streaming
    /// to a fresh log file, and start its reader thread. Returns immediately.
    pub fn start(self: *BackgroundManager, opts: StartOptions) !StartResult {
        const gpa = self.gpa;
        const io = self.io;

        // The mutex guards only `next_id` and the job list; the allocation and
        // spawn work below touches locals only, so drop the lock right after the
        // increment.
        try self.mutex.lock(io);
        const id = self.next_id;
        self.next_id += 1;
        self.mutex.unlock(io);

        var label: ?[]u8 = null;
        defer if (label) |p| gpa.free(p);
        label = try std.fmt.allocPrint(gpa, "bg_{d}", .{id});

        // Composed from `bg_log_prefix` so the log name and the startup pruner
        // share one prefix source; `label` stays the job's display name.
        const log_name = try std.fmt.allocPrint(gpa, temp_files.bg_log_prefix ++ "{d}.log", .{id});
        defer gpa.free(log_name);

        var log_path: ?[]u8 = null;
        defer if (log_path) |p| gpa.free(p);
        log_path = try bash.namedTempPath(gpa, log_name);

        var log_file: ?std.Io.File = null;
        defer if (log_file) |*f| f.close(io);
        log_file = try std.Io.Dir.createFileAbsolute(io, log_path.?, .{});

        // Merge stderr into stdout so the log preserves chronological order, like
        // the foreground capture path. The prefix/suffix come from the shell tool
        // (bash: `exec 2>&1\n`, which merges stderr; pwsh: `""` + the trailing
        // `$?`/`$LASTEXITCODE` exit-check — stderr stays on its own stream and
        // the reader merges it, so `Buffer(2)` below). The shell is non-login.
        const merged = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ opts.stderr_merge_prefix, opts.command, opts.stderr_merge_suffix });
        defer gpa.free(merged);

        // The `.stdin_dash_command` mode writes the merged script to a temp
        // `.ps1` file and runs `pwsh -File` — stdin `-Command -` drops multi-line
        // PowerShell constructs (blocks, function definitions), and argv
        // `-Command "<script>"` rounds the quotes away and hits the 32K cap. The
        // Job owns and deletes the file once its reader is done.
        var script_path: ?[]u8 = null;
        // Owns the script file + path until it is transferred into the Job
        // (below). After transfer the local is nulled, so this runs only on the
        // pre-transfer error path (e.g. a failed spawn) — not on success.
        defer if (script_path) |p| {
            std.Io.Dir.deleteFile(.cwd(), io, p) catch {};
            gpa.free(p);
        };

        var child: ?std.process.Child = null;
        defer if (child) |*c| {
            c.kill(io);
            _ = c.wait(io) catch {};
        };

        child = switch (opts.command_mode) {
            .argv_dash_c => try std.process.spawn(io, .{
                .argv = &.{ opts.shell_path, "-c", merged },
                .cwd = .{ .path = opts.cwd },
                .environ_map = opts.env_map,
                .stdin = .ignore,
                .stdout = .pipe,
                .stderr = .pipe,
            }),
            .stdin_dash_command => blk: {
                const path = try writeBackgroundScript(gpa, io, merged);
                script_path = path;
                break :blk try std.process.spawn(io, .{
                    .argv = &.{ opts.shell_path, "-NoLogo", "-NoProfile", "-NonInteractive", "-File", path },
                    .cwd = .{ .path = opts.cwd },
                    .environ_map = opts.env_map,
                    .stdin = .ignore,
                    .stdout = .pipe,
                    .stderr = .pipe,
                });
            },
        };

        const pid = processId(child.?);

        var command_owned: ?[]u8 = null;
        defer if (command_owned) |p| gpa.free(p);
        command_owned = try gpa.dupe(u8, opts.command);

        var cwd_owned: ?[]u8 = null;
        defer if (cwd_owned) |p| gpa.free(p);
        cwd_owned = try gpa.dupe(u8, opts.cwd);

        var result_label: ?[]u8 = null;
        defer if (result_label) |p| gpa.free(p);
        result_label = try gpa.dupe(u8, label.?);

        var result_log_path: ?[]u8 = null;
        defer if (result_log_path) |p| gpa.free(p);
        result_log_path = try gpa.dupe(u8, log_path.?);

        const job = try gpa.create(Job);
        errdefer gpa.destroy(job);

        job.* = .{
            .manager = self,
            .id = id,
            .label = label.?,
            .command = command_owned.?,
            .cwd = cwd_owned.?,
            .log_path = log_path.?,
            .pid = pid,
            .owner = opts.owner,
            .started = std.Io.Timestamp.now(io, .awake),
            .child = child.?,
            .log_file = log_file.?,
            .script_path = script_path,
        };

        // Ownership of fields transferred to Job; disarm individual defers.
        label = null;
        command_owned = null;
        cwd_owned = null;
        log_path = null;
        child = null;
        log_file = null;
        script_path = null;

        // 1. Spawn reader thread first. On failure, cleanup child, files, and job.
        const thread = std.Thread.spawn(.{}, runReader, .{job}) catch |err| {
            cleanupFailedJob(gpa, io, job);
            return err;
        };
        job.thread = thread;

        // 2. Lock mutex and publish atomically to self.jobs.
        self.mutex.lock(io) catch |err| {
            job.killed.store(true, .release);
            terminateTree(io, gpa, pid);
            thread.join();
            destroyJob(gpa, io, job);
            return err;
        };
        self.jobs.append(gpa, job) catch |err| {
            self.mutex.unlock(io);
            job.killed.store(true, .release);
            terminateTree(io, gpa, pid);
            thread.join();
            destroyJob(gpa, io, job);
            return err;
        };
        self.mutex.unlock(io);

        const result: StartResult = .{
            .id = id,
            .label = result_label.?,
            .pid = pid,
            .log_path = result_log_path.?,
        };
        result_label = null;
        result_log_path = null;
        return result;
    }

    /// Body of a job's reader thread: stream output to the log + tail until EOF,
    /// reap the child, build the completion notice, and flip the job to finished.
    fn runReader(job: *Job) void {
        const io = job.manager.io;
        const gpa = job.manager.gpa;

        var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var multi_reader: std.Io.File.MultiReader = undefined;
        multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{ job.child.stdout.?, job.child.stderr.? });
        defer multi_reader.deinit();
        const reader = multi_reader.reader(0);
        const stderr_reader = multi_reader.reader(1);

        while (multi_reader.fill(read_reserve, .none)) |_| {
            drainBufferedChunks(job, io, gpa, reader, stderr_reader);
        } else |_| {}

        // Trailing drain for any unread bytes buffered before EOF/error.
        drainBufferedChunks(job, io, gpa, reader, stderr_reader);

        const term = job.child.wait(io) catch std.process.Child.Term{ .unknown = 0 };
        job.log_file.close(io);
        job.exit_code = os.termCode(term);

        // A user/shutdown kill is surfaced in the UI only — don't wake the model
        // with output it didn't ask to wait for.
        if (!job.killed.load(.acquire)) {
            job.completion_message = buildCompletionMessage(job, gpa) catch null;
        }
        job.state.store(.finished, .release);
    }

    /// Append a chunk to the job's log file respecting the 50 MB quota.
    pub fn writeLogChunk(job: *Job, io: std.Io, chunk: []const u8) void {
        if (job.truncated) return;
        const remaining = max_job_log_bytes -| job.bytes_written;
        if (remaining == 0) {
            job.truncated = true;
            const notice = "\n\n[... output truncated: exceeded 50MB limit ...]\n";
            job.log_file.writeStreamingAll(io, notice) catch {};
            return;
        }
        if (chunk.len <= remaining) {
            job.log_file.writeStreamingAll(io, chunk) catch {};
            job.bytes_written +|= chunk.len;
        } else {
            const fit = chunk[0..@intCast(remaining)];
            job.log_file.writeStreamingAll(io, fit) catch {};
            job.bytes_written +|= fit.len;
            job.truncated = true;
            const notice = "\n\n[... output truncated: exceeded 50MB limit ...]\n";
            job.log_file.writeStreamingAll(io, notice) catch {};
        }
    }

    /// Drain unconsumed buffered chunks from both streams to the log file and tail buffer.
    fn drainBufferedChunks(
        job: *Job,
        io: std.Io,
        gpa: std.mem.Allocator,
        reader: anytype,
        stderr_reader: anytype,
    ) void {
        // Both stdout and stderr are piped; append each stream's buffered
        // bytes to the log + tail, in the order the MultiReader surfaces
        // them, so a PowerShell background job's error text (which stays on
        // its own stream — pwsh has no `exec 2>&1`) still lands in the log.
        if (reader.buffered().len > 0) {
            const chunk = reader.buffered();
            writeLogChunk(job, io, chunk);
            appendTail(job, gpa, chunk);
            reader.tossBuffered();
        }
        if (stderr_reader.buffered().len > 0) {
            const chunk = stderr_reader.buffered();
            writeLogChunk(job, io, chunk);
            appendTail(job, gpa, chunk);
            stderr_reader.tossBuffered();
        }
    }

    /// Keep `job.tail` to the last `tail_bytes_max` bytes, trimming on a UTF-8
    /// boundary so the inline notice never splits a codepoint.
    fn appendTail(job: *Job, gpa: std.mem.Allocator, chunk: []const u8) void {
        job.tail.appendSlice(gpa, chunk) catch return;
        if (job.tail.items.len <= tail_bytes_max * 2) return;
        var trim_start = job.tail.items.len - tail_bytes_max;
        while (trim_start < job.tail.items.len and (job.tail.items[trim_start] & 0xC0) == 0x80) trim_start += 1;
        const kept = job.tail.items.len - trim_start;
        std.mem.copyForwards(u8, job.tail.items[0..kept], job.tail.items[trim_start..]);
        job.tail.shrinkRetainingCapacity(kept);
    }

    fn buildCompletionMessage(job: *Job, gpa: std.mem.Allocator) ![]u8 {
        const now = std.Io.Timestamp.now(job.manager.io, .awake);
        const elapsed_ns: i128 = job.started.durationTo(now).nanoseconds;
        const secs: u64 = @intCast(@max(elapsed_ns, 0) / std.time.ns_per_s);
        var elapsed_buf: [32]u8 = undefined;
        const elapsed = formatElapsed(&elapsed_buf, secs);

        const tail = std.mem.trimEnd(u8, job.tail.items, "\n");
        const body = if (tail.len == 0) "(no output)" else tail;
        return std.fmt.allocPrint(
            gpa,
            "Background command {s} (`{s}`) finished after {s} with exit code {d}.\n\n" ++
                "{s}\n\n[Full log: {s}]",
            .{ job.label, job.command, elapsed, job.exit_code, body, job.log_path },
        );
    }

    /// Snapshot the running jobs for the TUI modal (oldest first). Free with
    /// `freeViews`.
    pub fn snapshot(self: *BackgroundManager, gpa: std.mem.Allocator) ![]JobView {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const now = std.Io.Timestamp.now(self.io, .awake);
        var out: std.ArrayList(JobView) = .empty;
        errdefer freeViewsList(&out, gpa);
        for (self.jobs.items) |job| {
            if (job.state.load(.acquire) != .running) continue;
            const elapsed_ns: i128 = job.started.durationTo(now).nanoseconds;
            try out.append(gpa, .{
                .id = job.id,
                .label = try gpa.dupe(u8, job.label),
                .command = try gpa.dupe(u8, job.command),
                .log_path = try gpa.dupe(u8, job.log_path),
                .elapsed_seconds = @intCast(@max(elapsed_ns, 0) / std.time.ns_per_s),
            });
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn freeViews(gpa: std.mem.Allocator, views: []JobView) void {
        for (views) |*view| {
            gpa.free(view.label);
            gpa.free(view.command);
            gpa.free(view.log_path);
        }
        gpa.free(views);
    }

    fn freeViewsList(list: *std.ArrayList(JobView), gpa: std.mem.Allocator) void {
        for (list.items) |*view| {
            gpa.free(view.label);
            gpa.free(view.command);
            gpa.free(view.log_path);
        }
        list.deinit(gpa);
    }

    /// How many jobs the manager is tracking (running plus finished-but-not-yet-
    /// reported). The UI keeps its drain tick alive while this is non-zero.
    pub fn activeCount(self: *BackgroundManager) usize {
        if (self.mutex.lock(self.io)) |_| {
            defer self.mutex.unlock(self.io);
            return self.jobs.items.len;
        } else |_| {
            return 0;
        }
    }

    /// How many jobs are still running — the count shown in the footer.
    pub fn runningCount(self: *BackgroundManager) usize {
        if (self.mutex.lock(self.io)) |_| {
            defer self.mutex.unlock(self.io);
            var count: usize = 0;
            for (self.jobs.items) |job| {
                if (job.state.load(.acquire) == .running) count += 1;
            }
            return count;
        } else |_| {
            return 0;
        }
    }

    /// Request termination of job `id`, killing the whole process tree. The
    /// reader then reaps it and marks it finished+killed. Returns true if a
    /// running job matched. The actual kill runs outside the lock so it never stalls the UI's draw/poll path.
    pub fn cancel(self: *BackgroundManager, id: u32) bool {
        var pid: ?i64 = null;
        if (self.mutex.lock(self.io)) |_| {
            for (self.jobs.items) |job| {
                if (job.id != id) continue;
                if (job.state.load(.acquire) == .running) {
                    job.killed.store(true, .release);
                    pid = job.pid;
                }
                break;
            }
            self.mutex.unlock(self.io);
        } else |_| {
            return false;
        }

        if (pid) |p| {
            terminateTree(self.io, self.gpa, p);
            return true;
        }
        return false;
    }

    /// Terminate all running background jobs whose CWD is within `target_cwd`.
    /// Synchronously kills child processes to release file locks before directory deletion.
    pub fn terminateJobsInCwd(self: *BackgroundManager, target_cwd: []const u8) void {
        var pids_to_kill: std.ArrayList(i64) = .empty;
        defer pids_to_kill.deinit(self.gpa);

        if (self.mutex.lock(self.io)) |_| {
            for (self.jobs.items) |job| {
                if (job.state.load(.acquire) == .running) {
                    if (isSubpathOrEqual(job.cwd, target_cwd)) {
                        job.killed.store(true, .release);
                        pids_to_kill.append(self.gpa, job.pid) catch {};
                    }
                }
            }
            self.mutex.unlock(self.io);
        } else |_| return;

        for (pids_to_kill.items) |pid| {
            terminateTreeSync(self.io, self.gpa, pid);
        }
    }

    /// Take every finished-but-unreported job, transferring ownership to the
    /// caller (the UI), which shows the notice and — for non-killed jobs —
    /// delivers `completion_message` to the owning agent. Free each with `deinit`.
    pub fn takeFinished(self: *BackgroundManager, gpa: std.mem.Allocator) ![]Finished {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        var out: std.ArrayList(Finished) = .empty;
        errdefer {
            for (out.items) |*f| f.deinit(gpa);
            out.deinit(gpa);
        }
        try out.ensureTotalCapacity(gpa, self.jobs.items.len);

        var write_idx: usize = 0;
        for (self.jobs.items) |job| {
            if (!job.reported and job.state.load(.acquire) == .finished) {
                if (job.thread) |t| {
                    t.join();
                    job.thread = null;
                }
                if (buildFinished(job, gpa)) |finished| {
                    out.appendAssumeCapacity(finished);
                    destroyJob(self.gpa, self.io, job);
                    continue;
                } else |_| {
                    // Leave the job in place to retry on next tick.
                    job.reported = false;
                }
            }
            self.jobs.items[write_idx] = job;
            write_idx += 1;
        }
        self.jobs.shrinkRetainingCapacity(write_idx);
        return out.toOwnedSlice(gpa);
    }

    fn buildFinished(job: *Job, gpa: std.mem.Allocator) !Finished {
        const label = try gpa.dupe(u8, job.label);
        errdefer gpa.free(label);
        const command = try gpa.dupe(u8, job.command);
        errdefer gpa.free(command);
        const message: ?[]u8 = if (job.completion_message) |m| try gpa.dupe(u8, m) else null;
        return .{
            .id = job.id,
            .label = label,
            .command = command,
            .exit_code = job.exit_code,
            .killed = job.killed.load(.acquire),
            .completion_message = message,
            .owner = job.owner,
        };
    }

    /// Terminate and reap every job, then free everything. Called at clean exit.
    pub fn shutdownAll(self: *BackgroundManager) void {
        self.mutex.lock(self.io) catch return;
        var list = self.jobs;
        self.jobs = .empty;
        self.mutex.unlock(self.io);
        for (list.items) |job| {
            if (job.state.load(.acquire) == .running) {
                job.killed.store(true, .release);
                terminateTree(self.io, self.gpa, job.pid);
            }
            if (job.thread) |thread| {
                thread.join();
                job.thread = null;
            }
            destroyJob(self.gpa, self.io, job);
        }
        list.deinit(self.gpa);
    }

    pub fn deinit(self: *BackgroundManager) void {
        self.shutdownAll();
        self.* = undefined;
    }

    fn cleanupFailedJob(gpa: std.mem.Allocator, io: std.Io, job: *Job) void {
        job.child.kill(io);
        _ = job.child.wait(io) catch {};
        job.log_file.close(io);
        destroyJob(gpa, io, job);
    }

    fn destroyJob(gpa: std.mem.Allocator, io: std.Io, job: *Job) void {
        gpa.free(job.label);
        gpa.free(job.command);
        gpa.free(job.cwd);
        gpa.free(job.log_path);
        if (job.script_path) |path| {
            std.Io.Dir.deleteFile(.cwd(), io, path) catch {};
            gpa.free(path);
        }
        job.tail.deinit(gpa);
        if (job.completion_message) |m| gpa.free(m);
        gpa.destroy(job);
    }
};

/// Render an elapsed duration compactly: `45s`, `12m 03s`, `2h 05m`.
fn formatElapsed(buf: []u8, total_seconds: u64) []const u8 {
    if (total_seconds < 60) return std.fmt.bufPrint(buf, "{d}s", .{total_seconds}) catch "?";
    const minutes = total_seconds / 60;
    const seconds = total_seconds % 60;
    if (minutes < 60) return std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ minutes, seconds }) catch "?";
    const hours = minutes / 60;
    const rem_minutes = minutes % 60;
    return std.fmt.bufPrint(buf, "{d}h {d:0>2}m", .{ hours, rem_minutes }) catch "?";
}

/// Write the merged pwsh background script to a fresh `nova-pwsh-bg-<hex>.ps1`
/// temp file under the shared temp dir, so the `.stdin_dash_command` mode can
/// run it with `pwsh -File`. The `nova-pwsh-` prefix is deliberate: the startup
/// temp-prune (`bash_exec.pruneTempDir`, matching `nova-pwsh-*`) reaps any file
/// stranded by a crash, so a failed spawn can never leak one permanently. On a
/// write failure the (already-created) file is deleted here; the caller owns the
/// path string and the file on success (the Job stores it, `destroyJob` removes
/// it), so no cleanup is needed on the error path beyond what's here.
fn writeBackgroundScript(gpa: std.mem.Allocator, io: std.Io, script: []const u8) ![]u8 {
    var random: [16]u8 = undefined;
    io.random(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const name = try std.fmt.allocPrint(gpa, temp_files.pwsh_prefix ++ "bg-{s}.ps1", .{hex[0..]});
    defer gpa.free(name);
    const path = try bash.namedTempPath(gpa, name);
    errdefer gpa.free(path);
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    // On a write failure, remove the now-created (possibly partial) file so a
    // stranding doesn't accumulate on every failed background launch. Register
    // the delete BEFORE the close so, on the error path, LIFO runs close first —
    // Windows cannot delete a file that is still open and would otherwise fail
    // this cleanup silently.
    errdefer std.Io.Dir.deleteFile(.cwd(), io, path) catch {};
    defer file.close(io);
    try file.writeStreamingAll(io, script);
    return path;
}

/// Worker function to execute taskkill.exe synchronously.
fn runTaskkillWorker(io: std.Io, pid: i64) void {
    const alloc = std.heap.page_allocator;
    var pid_buf: [32]u8 = undefined;
    const pid_arg = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch return;

    const result = std.process.run(alloc, io, .{
        .argv = &.{ "taskkill.exe", "/F", "/T", "/PID", pid_arg },
        .stdout_limit = .limited(taskkill_output_limit),
        .stderr_limit = .limited(taskkill_output_limit),
        .timeout = bash.timeoutFromSeconds(5),
    }) catch return;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
}

/// Synchronously kill a job's whole process tree by pid.
pub fn terminateTreeSync(io: std.Io, gpa: std.mem.Allocator, pid: i64) void {
    _ = gpa;
    if (os.is_windows) {
        runTaskkillWorker(io, pid);
        return;
    }
    if (!os.is_windows) {
        if (pid <= 1) return;
        const p: std.posix.pid_t = @intCast(pid);
        if (std.posix.kill(-p, std.posix.SIG.KILL)) |_| {} else |_| {
            std.posix.kill(p, std.posix.SIG.KILL) catch {};
        }
    }
}

/// Kill a job's whole process tree by pid. On Windows, offloads taskkill to a
/// background worker thread so the TUI render loop is never blocked.
/// Best-effort and side-effect free on the caller's data — runs outside the manager lock.
fn terminateTree(io: std.Io, gpa: std.mem.Allocator, pid: i64) void {
    if (os.is_windows) {
        if (std.Thread.spawn(.{}, runTaskkillWorker, .{ io, pid })) |thread| {
            thread.detach();
        } else |_| {
            runTaskkillWorker(io, pid);
        }
        return;
    }
    terminateTreeSync(io, gpa, pid);
}

fn processId(child: std.process.Child) i64 {
    if (os.is_windows) return @intCast(windows.GetProcessId(child.id.?));
    return @intCast(child.id.?);
}

/// Minimal Win32 surface — just the pid query, so the displayed/taskkill pid
/// matches the real OS process. No Job Object or handle duplication: those
/// disturb cygwin (see `terminateTree`).
const windows = struct {
    const HANDLE = std.os.windows.HANDLE;
    const DWORD = std.os.windows.DWORD;
    extern "kernel32" fn GetProcessId(Process: HANDLE) callconv(.winapi) DWORD;
};

pub fn isSubpathOrEqual(child: []const u8, parent: []const u8) bool {
    if (paths.pathsEqual(child, parent)) return true;
    if (child.len <= parent.len) return false;
    const prefix = child[0..parent.len];
    if (paths.pathsEqual(prefix, parent)) {
        const sep = child[parent.len];
        return sep == '/' or sep == '\\';
    }
    return false;
}

test "isSubpathOrEqual handles exact match, subpaths, and rejects prefix collisions" {
    try std.testing.expect(isSubpathOrEqual("C:\\Users\\nova\\worktrees\\1", "C:/Users/nova/worktrees/1"));
    try std.testing.expect(isSubpathOrEqual("C:\\Users\\nova\\worktrees\\1\\sub", "C:/Users/nova/worktrees/1"));
    try std.testing.expect(!isSubpathOrEqual("C:\\Users\\nova\\worktrees\\1-other", "C:/Users/nova/worktrees/1"));
    try std.testing.expect(!isSubpathOrEqual("C:\\Users\\nova\\worktrees", "C:/Users/nova/worktrees/1"));
}

test "BackgroundManager init/deinit cycle is clean" {
    // A manager with no jobs must deinit without leaks or hangs.
    var manager = BackgroundManager.init(std.testing.io, std.testing.allocator);
    defer manager.deinit();
    try std.testing.expectEqual(@as(usize, 0), manager.activeCount());
    try std.testing.expectEqual(@as(usize, 0), manager.runningCount());

    // takeFinished on an empty manager returns an empty slice.
    const finished = try manager.takeFinished(std.testing.allocator);
    std.testing.allocator.free(finished);
    try std.testing.expectEqual(@as(usize, 0), finished.len);
}

test "BackgroundManager tracks active and running counts" {
    // Without spawning a real subprocess (which would race with the reader
    // thread joining under std.testing.io), verify the counts a manager
    // reports on init, after takeFinished, and after shutdown.
    var manager = BackgroundManager.init(std.testing.io, std.testing.allocator);
    defer manager.deinit();
    try std.testing.expectEqual(@as(usize, 0), manager.activeCount());
    try std.testing.expectEqual(@as(usize, 0), manager.runningCount());

    // snapshot on an empty manager returns an empty slice.
    const views = try manager.snapshot(std.testing.allocator);
    defer BackgroundManager.freeViews(std.testing.allocator, views);
    try std.testing.expectEqual(@as(usize, 0), views.len);

    // takeFinished is idempotent on an empty manager.
    const finished1 = try manager.takeFinished(std.testing.allocator);
    std.testing.allocator.free(finished1);
    const finished2 = try manager.takeFinished(std.testing.allocator);
    std.testing.allocator.free(finished2);
    try std.testing.expectEqual(@as(usize, 0), finished1.len);
    try std.testing.expectEqual(@as(usize, 0), finished2.len);
}

test "BackgroundManager.start returns and the job completes" {
    // Regression for the self-deadlock: `start` took the manager mutex via a
    // function-scoped `defer` and re-locked the non-recursive mutex mid-function,
    // so every launch hung in futexWait. With the bug present this test times
    // out (CI) — `start` never returns; on a healthy manager the `true` job
    // finishes within a few hundred ms and takeFinished hands it back.
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);

    var env_map = try platform.getEnvMap(gpa);
    defer env_map.deinit();

    var manager = BackgroundManager.init(std.testing.io, gpa);
    defer manager.shutdownAll();

    var started = try manager.start(.{
        .command = "true",
        .cwd = cwd,
        .env_map = &env_map,
        .owner = @as(*anyopaque, @ptrFromInt(1)),
        // Explicit bash options regardless of host, so this stays a pure
        // BackgroundManager test (shell-agnostic spawn plumbing is exercised
        // separately by the pwsh path guarded to Windows).
        .shell_path = bash.shellPath(std.testing.io),
        .command_mode = .argv_dash_c,
        .stderr_merge_prefix = "exec 2>&1\n",
        .stderr_merge_suffix = "",
    });
    defer started.deinit(gpa);
    defer std.Io.Dir.deleteFile(.cwd(), std.testing.io, started.log_path) catch {};
    try std.testing.expect(started.pid > 0);

    var finished: []BackgroundManager.Finished = &.{};
    var attempts: u32 = 0;
    while (attempts < test_poll_attempts_max) : (attempts += 1) {
        const pending = try manager.takeFinished(gpa);
        if (pending.len > 0) {
            finished = pending;
            break;
        }
        gpa.free(pending);
        std.testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    defer {
        for (finished) |*f| f.deinit(gpa);
        gpa.free(finished);
    }
    try std.testing.expectEqual(@as(usize, 1), finished.len);
    try std.testing.expectEqual(@as(u8, 0), finished[0].exit_code);
    try std.testing.expect(!finished[0].killed);
    try std.testing.expectEqual(@as(u32, 1), finished[0].id);
}

test "BackgroundManager.start executes pwsh on Windows" {
    if (!os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);

    var env_map = try platform.getEnvMap(gpa);
    defer env_map.deinit();

    var manager = BackgroundManager.init(io, gpa);
    defer manager.shutdownAll();

    var started = try manager.start(.{
        .command = "Write-Output 'pwsh-bg-ok'",
        .cwd = cwd,
        .env_map = &env_map,
        .owner = @as(*anyopaque, @ptrFromInt(1)),
        .shell_path = pws.shellPath(io),
        .command_mode = .stdin_dash_command,
        .stderr_merge_prefix = "",
        .stderr_merge_suffix = "\nif (-not $?) { exit 1 } else { exit $LASTEXITCODE }",
    });
    defer started.deinit(gpa);
    defer std.Io.Dir.deleteFile(.cwd(), io, started.log_path) catch {};
    try std.testing.expect(started.pid > 0);

    var finished: []BackgroundManager.Finished = &.{};
    var attempts: u32 = 0;
    while (attempts < test_poll_attempts_max) : (attempts += 1) {
        const pending = try manager.takeFinished(gpa);
        if (pending.len > 0) {
            finished = pending;
            break;
        }
        gpa.free(pending);
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    defer {
        for (finished) |*f| f.deinit(gpa);
        gpa.free(finished);
    }
    try std.testing.expectEqual(@as(usize, 1), finished.len);
    try std.testing.expectEqual(@as(u8, 0), finished[0].exit_code);
    try std.testing.expect(!finished[0].killed);
    try std.testing.expectEqual(@as(u32, 1), finished[0].id);

    // Verify log file output contains pwsh-bg-ok
    var log_file = try std.Io.Dir.openFileAbsolute(io, started.log_path, .{});
    defer log_file.close(io);
    var buf: [256]u8 = undefined;
    var reader_buf: [256]u8 = undefined;
    var file_reader = log_file.reader(io, &reader_buf);
    const read_len = file_reader.interface.readSliceShort(&buf) catch 0;
    try std.testing.expect(std.mem.indexOf(u8, buf[0..read_len], "pwsh-bg-ok") != null);
}

test "BackgroundManager.cancel terminates long-running job" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);

    var env_map = try platform.getEnvMap(gpa);
    defer env_map.deinit();

    var manager = BackgroundManager.init(io, gpa);
    defer manager.shutdownAll();

    const is_win = os.is_windows;
    var started = try manager.start(.{
        .command = if (is_win) "Start-Sleep -Seconds 60" else "sleep 60",
        .cwd = cwd,
        .env_map = &env_map,
        .owner = @as(*anyopaque, @ptrFromInt(1)),
        .shell_path = if (is_win) pws.shellPath(io) else bash.shellPath(io),
        .command_mode = if (is_win) .stdin_dash_command else .argv_dash_c,
        .stderr_merge_prefix = if (is_win) "" else "exec 2>&1\n",
        .stderr_merge_suffix = if (is_win) "\nif (-not $?) { exit 1 } else { exit $LASTEXITCODE }" else "",
    });
    defer started.deinit(gpa);
    defer std.Io.Dir.deleteFile(.cwd(), io, started.log_path) catch {};
    try std.testing.expect(started.pid > 0);

    // Cancel the running job
    const cancelled = manager.cancel(started.id);
    try std.testing.expect(cancelled);

    var finished: []BackgroundManager.Finished = &.{};
    var attempts: u32 = 0;
    while (attempts < test_poll_attempts_max) : (attempts += 1) {
        const pending = try manager.takeFinished(gpa);
        if (pending.len > 0) {
            finished = pending;
            break;
        }
        gpa.free(pending);
        io.sleep(.fromMilliseconds(20), .awake) catch {};
    }
    defer {
        for (finished) |*f| f.deinit(gpa);
        gpa.free(finished);
    }
    try std.testing.expectEqual(@as(usize, 1), finished.len);
    try std.testing.expect(finished[0].killed);
}

test "BackgroundManager handles instant command exit cleanly" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);

    var env_map = try platform.getEnvMap(gpa);
    defer env_map.deinit();

    var manager = BackgroundManager.init(io, gpa);
    defer manager.shutdownAll();

    const is_win = os.is_windows;
    var started = try manager.start(.{
        .command = if (is_win) "exit 0" else "true",
        .cwd = cwd,
        .env_map = &env_map,
        .owner = @as(*anyopaque, @ptrFromInt(1)),
        .shell_path = if (is_win) pws.shellPath(io) else bash.shellPath(io),
        .command_mode = if (is_win) .stdin_dash_command else .argv_dash_c,
        .stderr_merge_prefix = if (is_win) "" else "exec 2>&1\n",
        .stderr_merge_suffix = if (is_win) "\nif (-not $?) { exit 1 } else { exit $LASTEXITCODE }" else "",
    });
    defer started.deinit(gpa);
    defer std.Io.Dir.deleteFile(.cwd(), io, started.log_path) catch {};
    try std.testing.expect(started.pid > 0);

    var finished: []BackgroundManager.Finished = &.{};
    var attempts: u32 = 0;
    while (attempts < test_poll_attempts_max) : (attempts += 1) {
        const pending = try manager.takeFinished(gpa);
        if (pending.len > 0) {
            finished = pending;
            break;
        }
        gpa.free(pending);
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    defer {
        for (finished) |*f| f.deinit(gpa);
        gpa.free(finished);
    }
    try std.testing.expectEqual(@as(usize, 1), finished.len);
    try std.testing.expectEqual(@as(u8, 0), finished[0].exit_code);
    try std.testing.expect(!finished[0].killed);
}

test "bash subprocess executes and returns captured output" {
    // Direct coverage of the bash + merged-stderr pipeline the manager uses,
    // via the high-level `std.process.run` API that works reliably under
    // `std.testing.io`. This pins the contract that `manager.start` relies on:
    // bash exists, can run `exec 2>&1` + a command, and exits 0 on success.
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const result = std.process.run(gpa, std.testing.io, .{
        .argv = &.{ bash.shellPath(std.testing.io), "-c", "exec 2>&1\nprintf 'hello-bg\\n'" },
    }) catch return error.SkipZigTest;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    try std.testing.expectEqual(@as(u8, 0), switch (result.term) {
        .exited => |code| code,
        else => 255,
    });
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hello-bg") != null);
}

test "formatElapsed renders compact durations" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("45s", formatElapsed(&buf, 45));
    try std.testing.expectEqualStrings("12m 03s", formatElapsed(&buf, 12 * 60 + 3));
    try std.testing.expectEqualStrings("2h 05m", formatElapsed(&buf, 2 * 3600 + 5 * 60 + 9));
}

test "takeFinished compacts jobs list in-place and preserves unready jobs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var manager = BackgroundManager.init(io, gpa);
    defer manager.deinit();

    const job1 = try gpa.create(BackgroundManager.Job);
    job1.* = .{
        .manager = &manager,
        .id = 1,
        .label = try gpa.dupe(u8, "bg_1"),
        .command = try gpa.dupe(u8, "cmd1"),
        .cwd = try gpa.dupe(u8, "."),
        .log_path = try gpa.dupe(u8, "log1"),
        .pid = 101,
        .owner = @as(*anyopaque, @ptrFromInt(1)),
        .started = std.Io.Timestamp.now(io, .awake),
        .child = undefined,
        .log_file = undefined,
        .script_path = null,
        .state = .init(.finished),
    };

    const job2 = try gpa.create(BackgroundManager.Job);
    job2.* = .{
        .manager = &manager,
        .id = 2,
        .label = try gpa.dupe(u8, "bg_2"),
        .command = try gpa.dupe(u8, "cmd2"),
        .cwd = try gpa.dupe(u8, "."),
        .log_path = try gpa.dupe(u8, "log2"),
        .pid = 102,
        .owner = @as(*anyopaque, @ptrFromInt(1)),
        .started = std.Io.Timestamp.now(io, .awake),
        .child = undefined,
        .log_file = undefined,
        .script_path = null,
        .state = .init(.running),
    };

    const job3 = try gpa.create(BackgroundManager.Job);
    job3.* = .{
        .manager = &manager,
        .id = 3,
        .label = try gpa.dupe(u8, "bg_3"),
        .command = try gpa.dupe(u8, "cmd3"),
        .cwd = try gpa.dupe(u8, "."),
        .log_path = try gpa.dupe(u8, "log3"),
        .pid = 103,
        .owner = @as(*anyopaque, @ptrFromInt(1)),
        .started = std.Io.Timestamp.now(io, .awake),
        .child = undefined,
        .log_file = undefined,
        .script_path = null,
        .state = .init(.finished),
    };

    try manager.jobs.append(gpa, job1);
    try manager.jobs.append(gpa, job2);
    try manager.jobs.append(gpa, job3);

    const finished = try manager.takeFinished(gpa);
    defer {
        for (finished) |*f| f.deinit(gpa);
        gpa.free(finished);
    }

    try std.testing.expectEqual(@as(usize, 2), finished.len);
    try std.testing.expectEqual(@as(u32, 1), finished[0].id);
    try std.testing.expectEqual(@as(u32, 3), finished[1].id);
    try std.testing.expectEqual(@as(usize, 1), manager.jobs.items.len);
    try std.testing.expectEqual(@as(u32, 2), manager.jobs.items[0].id);
}

test "terminateTreeSync safely handles invalid and guarded pids" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // Guarded PIDs (0, 1, negative) must be immediate no-ops and never panic or error.
    terminateTreeSync(io, gpa, 0);
    terminateTreeSync(io, gpa, 1);
    terminateTreeSync(io, gpa, -1);
}

test "writeLogChunk caps at quota and writes truncation notice" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const tmp_path = try bash.namedTempPath(gpa, "nova-test-quota.log");
    defer gpa.free(tmp_path);
    defer std.Io.Dir.deleteFile(.cwd(), io, tmp_path) catch {};

    var file = try std.Io.Dir.createFileAbsolute(io, tmp_path, .{});
    defer file.close(io);

    var job: BackgroundManager.Job = .{
        .manager = undefined,
        .id = 1,
        .label = undefined,
        .command = undefined,
        .cwd = undefined,
        .log_path = undefined,
        .pid = 0,
        .owner = undefined,
        .started = undefined,
        .child = undefined,
        .log_file = file,
        .bytes_written = max_job_log_bytes - 10,
        .truncated = false,
    };

    // Write a 20-byte chunk, which exceeds the remaining 10-byte quota
    const chunk = "1234567890ABCDEFGHIJ";
    BackgroundManager.writeLogChunk(&job, io, chunk);

    try std.testing.expect(job.truncated);
    try std.testing.expectEqual(max_job_log_bytes, job.bytes_written);

    // Subsequent writeLogChunk calls must be no-ops
    BackgroundManager.writeLogChunk(&job, io, "more data");
    try std.testing.expectEqual(max_job_log_bytes, job.bytes_written);
}
