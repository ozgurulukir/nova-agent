const std = @import("std");
const os = @import("../os.zig");
const capture_sink = @import("capture_sink.zig");
const temp_files = @import("temp_files.zig");

const assert = std.debug.assert;

/// Shared capture machinery (Result/Capture/CaptureLimits/Sink/drainChild)
/// lives in `capture_sink.zig`; the bash spawn shapes stay here.
pub const Result = capture_sink.Result;
pub const Capture = capture_sink.Capture;
pub const CaptureLimits = capture_sink.CaptureLimits;
const capture_read_reserve = capture_sink.capture_read_reserve;

pub const timeout_seconds_default: u32 = 30;
/// Foreground timeout cap. 1h is 120× the default — generous for any
/// interactive command — while `run_in_background` is the documented escape
/// hatch for longer work (and ignores `timeout`). Requests above the cap are
/// clamped, not rejected, so a model over-shooting by a huge factor degrades
/// gracefully instead of failing the call.
pub const timeout_seconds_max: u32 = 3600;

pub const RunOptions = struct {
    cwd: []const u8,
    command: []const u8,
    env_map: ?*const std.process.Environ.Map = null,
    timeout: std.Io.Timeout = timeoutFromSeconds(timeout_seconds_default),
    /// Bytes piped to the child's stdin before it sees EOF. Null (default)
    /// inherits no stdin. Piping data — rather than embedding it in `command` —
    /// keeps it out of shell interpretation, which is how the git bridge passes
    /// commit messages (`git commit -F -`) without injection risk.
    stdin: ?[]const u8 = null,
};

pub fn timeoutFromSeconds(seconds: u32) std.Io.Timeout {
    assert(seconds > 0);
    return .{ .duration = .{ .raw = .fromSeconds(seconds), .clock = .awake } };
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, command: []const u8) !Result {
    return runWithOptions(gpa, io, .{ .cwd = cwd, .command = command });
}

pub fn runWithOptions(gpa: std.mem.Allocator, io: std.Io, options: RunOptions) !Result {
    assert(options.cwd.len > 0);
    assert(options.command.len > 0);
    // One run path for both the stdin and no-stdin shapes: spawn + drain under a
    // total-runtime deadline (see `runUnderBash`). The old no-stdin
    // `std.process.run` path had idle-timeout semantics internally — the
    // deadline reset whenever bytes arrived — so chatty commands never timed out
    // and quiet ones died on silence. Here `timeout` is the total runtime cap.
    return runUnderBash(gpa, io, options);
}

pub fn runWithStdin(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    command: []const u8,
    stdin: []const u8,
) !Result {
    assert(cwd.len > 0);
    assert(command.len > 0);
    return runUnderBash(gpa, io, .{
        .cwd = cwd,
        .command = command,
        .stdin = stdin,
    });
}

/// Spawn `bash -c <command>` and drain stdout/stderr to completion under a
/// TOTAL runtime deadline (TD-2). When `stdin` is non-null a writer thread
/// feeds it concurrently (TD-7 / M5) so a child that writes before it reads
/// cannot deadlock the drain.
fn runUnderBash(gpa: std.mem.Allocator, io: std.Io, options: RunOptions) !Result {
    assert(options.cwd.len > 0);
    assert(options.command.len > 0);
    if (std.mem.indexOfScalar(u8, options.command, 0) != null) return error.InvalidCharacter;
    var child = try std.process.spawn(io, .{
        .argv = &.{ bashPath(io), "-c", options.command },
        .cwd = .{ .path = options.cwd },
        .environ_map = options.env_map,
        .stdin = if (options.stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    // Join registered FIRST so it runs LAST (LIFO): the kill must land before we
    // wait on the writer, or a blocked writer deadlocks the join.
    var writer: ?std.Thread = null;
    defer if (writer) |*t| t.join();
    defer child.kill(io);

    if (options.stdin) |stdin_bytes| {
        if (child.stdin) |stdin_file| {
            writer = try std.Thread.spawn(.{}, capture_sink.writeStdinAndClose, .{ io, stdin_file, stdin_bytes });
            child.stdin = null; // ownership moved to the writer
        }
    }
    return capture_sink.drainChild(gpa, io, &child, options.timeout);
}

/// Inline-vs-spill thresholds for `capture`.
/// (`CaptureLimits`, like `Capture`/`Result`, is shared — see `capture_sink.zig`.)
pub const CaptureOptions = struct {
    cwd: []const u8,
    command: []const u8,
    env_map: ?*const std.process.Environ.Map = null,
    timeout: std.Io.Timeout = timeoutFromSeconds(timeout_seconds_default),
    limits: CaptureLimits,
};

/// Combined stdout+stderr capture of one command, streamed rather than
/// buffered — the type lives in `capture_sink.zig` (re-exported above); the
/// bash spawn shape is `capture` below.
/// Run `command` under bash, merging stderr into stdout (`exec 2>&1`) so the
/// captured stream preserves chronological interleaving, and stream the result
/// into a bounded tail with lazy spill. See `Capture`.
pub fn capture(gpa: std.mem.Allocator, io: std.Io, options: CaptureOptions) !Capture {
    assert(options.cwd.len > 0);
    assert(options.command.len > 0);
    if (std.mem.indexOfScalar(u8, options.command, 0) != null) return error.InvalidCharacter;
    assert(options.limits.tail_bytes_max > options.limits.bytes_max);
    // The seed write (the untrimmed tail, <= tail_bytes_max) must always fit, or
    // the spill would be created over its own cap.
    assert(options.limits.spill_bytes_max >= options.limits.tail_bytes_max);

    // `exec 2>&1` merges stderr into stdout so the captured stream preserves
    // chronological interleaving. The shell is non-login (see `bashPath`), so no
    // profile runs and only the command's own output reaches the pipe.
    const merged = try std.fmt.allocPrint(gpa, "exec 2>&1\n{s}", .{options.command});
    defer gpa.free(merged);

    var child = try std.process.spawn(io, .{
        .argv = &.{ bashPath(io), "-c", merged },
        .cwd = .{ .path = options.cwd },
        .environ_map = options.env_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);

    var sink: Sink = .{ .limits = options.limits };
    errdefer sink.deinit(gpa, io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(1) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{child.stdout.?});
    defer multi_reader.deinit();
    const reader = multi_reader.reader(0);

    // Total-runtime deadline, same as the run path (TD-2): the loop must stop at
    // `timeout` even when output keeps flowing.
    const deadline = options.timeout.toDeadline(io);

    var timed_out = false;
    while (multi_reader.fill(capture_read_reserve, deadline)) |_| {
        const chunk = reader.buffered();
        if (chunk.len == 0) continue;
        try sink.ingest(gpa, io, chunk);
        reader.tossBuffered();
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => timed_out = true,
        else => |e| return e,
    }

    if (!timed_out) try multi_reader.checkAnyError();
    const code = if (timed_out) 124 else os.termCode(try child.wait(io));

    return sink.finish(gpa, io, code, timed_out);
}

/// Per-shell `capture_sink.Sink` instantiation: the spill log carries the
/// bash prunable prefix (`nova-bash-`, pinned by temp_files tests) and spills
/// into the one temp dir both bash and Nova agree on.
const BashSinkConfig = struct {
    pub const spill_prefix = temp_files.bash_spill_prefix;
    pub const spillDir = tempDir;
};
const Sink = capture_sink.Sink(BashSinkConfig);

/// Resolve a temp directory that both the shell and Nova agree on.
///
/// On Windows the bash tool runs under git bash, which maps `/tmp` to `%TEMP%`,
/// but Nova reads the spilled output back through the Windows file API — there
/// a literal `/tmp/...` resolves against the current drive root (`C:\tmp\...`),
/// not where the shell actually wrote. Using the real `%TEMP%` keeps the write
/// and the read pointing at the same file. POSIX shares one `/tmp` already.
/// `pub` so `pwsh_exec` (which mirrors the spill-to-disk capture path) reuses
/// the one temp dir both shells and Nova agree on.
pub fn tempDir(gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    if (!os.is_windows) return gpa.dupe(u8, "/tmp");
    for ([_][]const u8{ "TEMP", "TMP" }) |key| {
        const value = std.process.Environ.getAlloc(.{ .block = .global }, gpa, key) catch continue;
        if (value.len == 0) {
            gpa.free(value);
            continue;
        }
        return value;
    }
    return gpa.dupe(u8, ".");
}

// Commands run under a non-login shell (see `bashPath`), but a non-login shell
// skips the profile — so on a GUI-launched POSIX host it would miss PATH/vars
// set only in login dotfiles. Rather than pay the profile cost (and leak its
// startup chatter) on every command, resolve the login environment once: run a
// login shell, dump its exported vars, and reuse them as the base env for every
// command. This mirrors codex's shell-snapshot approach; the captured vars are
// applied via the command's env map, so the per-command shell stays non-login.
//
// The dump is fenced by a NUL-delimited marker so the login profile's own stdout
// chatter (which precedes the marker) is discarded. `compgen -e` lists exported
// names; `${!k}` reads each value; `PWD`/`OLDPWD` are skipped so a stale cwd is
// not carried. Values are emitted NUL-terminated so newlines/`=` survive intact.
const login_env_marker = "\x00__NOVA_LOGIN_ENV__\x00";
const login_env_dump =
    "printf '\\0__NOVA_LOGIN_ENV__\\0'; " ++
    "for k in $(compgen -e); do case \"$k\" in PWD|OLDPWD) continue ;; esac; printf '%s=%s\\0' \"$k\" \"${!k}\"; done";
const login_env_bytes_limit: usize = 1024 * 1024;
const login_env_stderr_limit: usize = 64 * 1024;
const login_env_timeout_seconds: u32 = 10;

var login_env_cache: ?[]const u8 = null;
var login_env_attempted: bool = false;

/// POSIX only: the login shell's exported environment as a NUL-separated
/// `KEY=VALUE` block, captured once and cached for the process lifetime. Returns
/// null on Windows, or if the capture fails (callers then fall back to the
/// inherited process env). See the comment above for the rationale.
pub fn loginEnvBlock(io: std.Io) ?[]const u8 {
    if (os.is_windows) return null;
    if (!login_env_attempted) {
        login_env_attempted = true;
        login_env_cache = captureLoginEnv(io) catch null;
    }
    return login_env_cache;
}

fn captureLoginEnv(io: std.Io) ![]const u8 {
    // Cached for the process lifetime, so it is owned independently of any
    // caller's allocator.
    const gpa = std.heap.page_allocator;
    var result = try std.process.run(gpa, io, .{
        .argv = &.{ bashPath(io), "-lc", login_env_dump },
        .stdout_limit = .limited(login_env_bytes_limit),
        .stderr_limit = .limited(login_env_stderr_limit),
        .timeout = timeoutFromSeconds(login_env_timeout_seconds),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (os.termCode(result.term) != 0) return error.LoginEnvFailed;
    const marker_at = std.mem.indexOf(u8, result.stdout, login_env_marker) orelse return error.LoginEnvFailed;
    return gpa.dupe(u8, result.stdout[marker_at + login_env_marker.len ..]);
}

// On Windows, `bash` on PATH may resolve to the WSL bash bridge in
// system32, which talks to a Windows service that intermittently exhausts
// socket buffers (WSAENOBUFS / Bash/Service/0x80072747). Prefer git bash when
// available.
const windows_bash_candidates = [_][]const u8{
    "C:\\Program Files\\Git\\bin\\bash.exe",
    "C:\\Program Files\\Git\\usr\\bin\\bash.exe",
};

extern "kernel32" fn SetEnvironmentVariableW(
    lpName: [*:0]const u16,
    lpValue: [*:0]const u16,
) callconv(.winapi) std.os.windows.BOOL;

/// Disable MSYS2/Cygwin's pseudo-console (ConPTY) integration for every child
/// shell, by setting `MSYS`/`CYGWIN=disable_pcon` in our own process
/// environment so spawned bash processes inherit it.
pub fn disablePseudoConsole() void {
    if (!os.is_windows) return;
    const value = std.unicode.utf8ToUtf16LeStringLiteral("disable_pcon");
    _ = SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("MSYS"), value);
    _ = SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("CYGWIN"), value);
}

/// The resolved bash executable path (git bash on Windows, `bash` elsewhere).
/// Exposed so the `BackgroundManager` spawns the same shell as foreground runs.
pub fn shellPath(io: std.Io) []const u8 {
    return bashPath(io);
}

/// Join `name` under the temp directory both the shell and Nova agree on (see
/// `tempDir`). Used for background-job log files so the model can `tail` a stable
/// path. Caller owns the result.
/// Asserts that `name` contains no path separators (to prevent path traversal).
pub fn namedTempPath(gpa: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]u8 {
    assert(std.mem.indexOfScalar(u8, name, std.fs.path.sep) == null);
    const dir = try tempDir(gpa);
    defer gpa.free(dir);
    return std.fs.path.join(gpa, &.{ dir, name });
}

pub const temp_retention_ns: u64 = 24 * std.time.ns_per_hour;

/// Best-effort cleanup of stale spill (`nova-bash-*`) and background-log
/// (`nova-bg_*`) files older than `max_age_ns`. Called once at startup, when no
/// session can still be reading a previous process's output (TD-6).
pub fn pruneStaleTempFiles(io: std.Io, gpa: std.mem.Allocator, max_age_ns: u64) void {
    const dir_path = tempDir(gpa) catch return;
    defer gpa.free(dir_path);
    pruneTempDir(io, dir_path, max_age_ns);
}

/// The dir-parameterized core of `pruneStaleTempFiles`, separated so tests can
/// target a scratch dir instead of the shared temp dir. Prefix-scoped via
/// `temp_files.isPrunable` (the writers' prefixes, never bare `nova-`) so
/// unrelated temp files are untouched; mtime is compared against the wall clock
/// (`.real`); every operation is `catch`-tolerant so cleanup can never break
/// startup.
fn pruneTempDir(io: std.Io, dir_path: []const u8, max_age_ns: u64) void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    const now = std.Io.Timestamp.now(io, .real); // Stat.mtime is wall-clock
    var iter = dir.iterate();
    // `catch null` treats an iteration error as end-of-listing — best-effort
    // cleanup never fails startup.
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file and entry.kind != .unknown) continue;
        const name = entry.name;
        if (!temp_files.isPrunable(name)) continue;
        const st = dir.statFile(io, name, .{}) catch continue;
        const age_ns = st.mtime.durationTo(now).nanoseconds;
        if (age_ns > 0 and @as(u128, @intCast(age_ns)) > max_age_ns) {
            dir.deleteFile(io, name) catch {};
        }
    }
}

var bash_path_mutex: std.Io.Mutex = .init;
var bash_path_value: ?[]const u8 = null;

/// Mutex-guarded lazy init (mirrors `pwsh_exec.shellPath`): bash runs on the
/// tool-call path and the background reader, so first resolution can race.
/// On a lock failure fall back to the cached value, then to `"bash"` — the
/// resolution is an optimization over the default PATH lookup anyway.
fn bashPath(io: std.Io) []const u8 {
    if (bash_path_mutex.lock(io)) |_| {
        defer bash_path_mutex.unlock(io);
        if (bash_path_value) |p| return p;
        const resolved = resolveBashPath(io);
        bash_path_value = resolved;
        return resolved;
    } else |_| {
        return bash_path_value orelse "bash";
    }
}

fn resolveBashPath(io: std.Io) []const u8 {
    if (!os.is_windows) return "bash";
    for (windows_bash_candidates) |path| {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch continue;
        return path;
    }
    return "bash";
}

test "bash captures stdout and exit code" {
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var result = try run(gpa, std.testing.io, cwd, "printf hello");
    defer result.deinit(gpa);

    try std.testing.expectEqualStrings("hello", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.code);
}

test "bash forwards stdin from buffer" {
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var result = try runWithStdin(gpa, std.testing.io, cwd, "cat", "piped-bytes");
    defer result.deinit(gpa);

    try std.testing.expectEqualStrings("piped-bytes", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.code);
}

test "capture enforces total runtime even when output keeps flowing" {
    // Regression for H1: the timeout was an idle timeout (reset on every byte),
    // so a chatty command never died. The command prints ~20 lines over 2.5s;
    // under a 1s TOTAL deadline the fill loop must stop and report timed_out.
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var captured = try capture(gpa, std.testing.io, .{
        .cwd = cwd,
        .command = "i=0; while [ $i -lt 50 ]; do echo t$i; sleep 0.05; done",
        .timeout = timeoutFromSeconds(1),
        .limits = .{
            .bytes_max = 50 * 1024,
            .lines_max = 2000,
            .tail_bytes_max = 100 * 1024,
            .spill_bytes_max = 10 * 1024 * 1024,
        },
    });
    defer captured.deinit(gpa);
    try std.testing.expect(captured.timed_out);
    try std.testing.expectEqual(@as(u8, 124), captured.code);
}

test "capture still returns all output for a fast command" {
    // Positive control: the deadline conversion must not change fast commands.
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var captured = try capture(gpa, std.testing.io, .{
        .cwd = cwd,
        .command = "printf hello",
        .timeout = timeoutFromSeconds(2),
        .limits = .{
            .bytes_max = 50 * 1024,
            .lines_max = 2000,
            .tail_bytes_max = 100 * 1024,
            .spill_bytes_max = 10 * 1024 * 1024,
        },
    });
    defer captured.deinit(gpa);
    try std.testing.expect(!captured.timed_out);
    try std.testing.expectEqual(@as(u8, 0), captured.code);
    try std.testing.expectEqualStrings("hello", captured.tail);
}

test "spill stops growing at spill_bytes_max" {
    // Pure Sink test: once the spill cap is hit, further chunks are not written
    // to disk (the in-memory tail still serves the observation).
    const gpa = std.testing.allocator;
    var sink: Sink = .{ .limits = .{
        .bytes_max = 4,
        .lines_max = 100,
        .tail_bytes_max = 64,
        .spill_bytes_max = 16,
    } };
    defer sink.deinit(gpa, std.testing.io);

    try sink.ingest(gpa, std.testing.io, "aaaa"); // 4 bytes — not over budget yet
    try sink.ingest(gpa, std.testing.io, "bbbb"); // 8 > 4 → spill trips, seed+chunk
    try std.testing.expect(sink.spill != null);
    try sink.ingest(gpa, std.testing.io, "cccc");
    try sink.ingest(gpa, std.testing.io, "dddd"); // reaches the 16-byte cap
    try sink.ingest(gpa, std.testing.io, "eeee"); // past the cap — not written
    try std.testing.expectEqual(@as(usize, 16), sink.spill_bytes);

    const st = std.Io.Dir.statFile(.cwd(), std.testing.io, sink.spill.?.path, .{}) catch unreachable;
    try std.testing.expect(st.size <= 16);
}

test "pruneTempDir removes only matching stale files" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd_abs = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd_abs);
    const dir_path = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(dir_path);

    (try tmp.dir.createFile(std.testing.io, "nova-bash-abcdef.log", .{})).close(std.testing.io);
    (try tmp.dir.createFile(std.testing.io, "nova-pwsh-123456.log", .{})).close(std.testing.io);
    (try tmp.dir.createFile(std.testing.io, "nova-bg_1.log", .{})).close(std.testing.io);
    (try tmp.dir.createFile(std.testing.io, "keep.txt", .{})).close(std.testing.io);

    const tmp_has = struct {
        fn has(io: std.Io, dir: std.Io.Dir, name: []const u8) bool {
            return (dir.access(io, name, .{}) catch null) != null;
        }
    }.has;

    // Fresh files are younger than the retention window: nothing is removed.
    pruneTempDir(std.testing.io, dir_path, temp_retention_ns);
    try std.testing.expect(tmp_has(std.testing.io, tmp.dir, "nova-bash-abcdef.log"));
    try std.testing.expect(tmp_has(std.testing.io, tmp.dir, "nova-pwsh-123456.log"));
    try std.testing.expect(tmp_has(std.testing.io, tmp.dir, "nova-bg_1.log"));
    try std.testing.expect(tmp_has(std.testing.io, tmp.dir, "keep.txt"));

    // With a ~1ns window the nova files are stale and removed, while keep.txt
    // (a different prefix) survives — prefix-scoping is the property under test.
    pruneTempDir(std.testing.io, dir_path, 1);
    try std.testing.expect(!tmp_has(std.testing.io, tmp.dir, "nova-bash-abcdef.log"));
    try std.testing.expect(!tmp_has(std.testing.io, tmp.dir, "nova-pwsh-123456.log"));
    try std.testing.expect(!tmp_has(std.testing.io, tmp.dir, "nova-bg_1.log"));
    try std.testing.expect(tmp_has(std.testing.io, tmp.dir, "keep.txt"));
}

test "runUnderBash rejects command with null byte" {
    const gpa = std.testing.allocator;

    const options = RunOptions{
        .cwd = ".",
        .command = "echo hello\x00world",
    };

    try std.testing.expectError(error.InvalidCharacter, runUnderBash(gpa, std.testing.io, options));
}

test "capture rejects command with null byte" {
    const gpa = std.testing.allocator;

    const options = CaptureOptions{
        .cwd = ".",
        .command = "echo hello\x00world",
        .limits = .{
            .bytes_max = 50 * 1024,
            .lines_max = 2000,
            .tail_bytes_max = 100 * 1024,
            .spill_bytes_max = 10 * 1024 * 1024,
        },
    };
    try std.testing.expectError(error.InvalidCharacter, capture(gpa, std.testing.io, options));
}
