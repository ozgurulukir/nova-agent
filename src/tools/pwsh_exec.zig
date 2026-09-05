//! Low-level execution for the `pwsh` (PowerShell) tool, mirroring
//! `bash_exec.zig` with PowerShell specifics.
//!
//! The module MUST compile on POSIX even though it is never used there (it is
//! pulled into the test graph via `registry.zig`'s `shell_tool` selection and
//! `tools.zig`'s test wiring), so every runtime-only path is guarded by
//! `os.is_windows` or left as a POSIX no-op stub.
//!
//! Key deltas from `bash_exec.zig`:
//! - Spawn mode is `pwsh -NoLogo -NoProfile -NonInteractive -File <temp .ps1>`
//!   in BOTH the sync run path and `capture()`. The exit-checked script is
//!   written to a temp `.ps1` under the shared temp dir, then run via `-File`.
//!   This was chosen after `-Command -` (stdin) empirically DROPS the output of
//!   multi-line PowerShell constructs (blocks, function definitions) and mangled
//!   the `& { ... } 2>&1` exit wrapper; an argv `-Command "<script>"` round-trip
//!   strips quotes and re-introduces the 32K CreateProcess command-line limit
//!   that the temp file sidesteps. `runWithStdin` still pipes caller stdin to the
//!   child separately (`-File` doesn't consume stdin), so a command can read it
//!   via `$input`.
//! - Exit code is normalized by appending a trailing `$?`/`$LASTEXITCODE` check
//!   directly after the user command (NO `& { ... }` block — that block is the
//!   stdin-mode casualty above), because PowerShell's process exit code is 0 for
//!   pure-cmdlet runs even when a statement failed.
//! - `capture()` pipes BOTH stdout and stderr and merges them in the reader
//!   (`MultiReader.Buffer(2)`), since PowerShell lacks a session-wide
//!   `exec 2>&1` redirect.
//! - The capture machinery (`Sink`, spill files, `drainChild`, result types)
//!   is SHARED with `bash_exec.zig` via `capture_sink.zig` — the spill-file
//!   prefix is the only per-shell bit (`nova-pwsh-`).
//! - `tempDir()`/`namedTempPath()` are REUSED from `bash_exec` (no second
//!   temp-walk; `pruneTempDir` matches both prefixes). Script temp files use the
//!   `nova-pwsh-script-<hex>.ps1` prefix so a crash-stranded file is also pruned.
//! - POSIX-only no-op stubs: `loginEnvBlock()` returns null, and
//!   `disablePseudoConsole()` does nothing (no MSYS2/Cygwin in PowerShell).

const std = @import("std");
const os = @import("../os.zig");

const assert = std.debug.assert;

const bash_exec = @import("bash_exec.zig");
const capture_sink = @import("capture_sink.zig");
const temp_files = @import("temp_files.zig");

/// Shared capture machinery — see `capture_sink.zig`.
pub const Result = capture_sink.Result;
pub const Capture = capture_sink.Capture;

// Timeout constants/helpers reused from `bash_exec` so both shells honor the
// same default/cap and deadline semantics.
pub const timeout_seconds_default = bash_exec.timeout_seconds_default;
pub const timeout_seconds_max = bash_exec.timeout_seconds_max;
pub const timeoutFromSeconds = bash_exec.timeoutFromSeconds;

pub const RunOptions = struct {
    cwd: []const u8,
    command: []const u8,
    env_map: ?*const std.process.Environ.Map = null,
    timeout: std.Io.Timeout = bash_exec.timeoutFromSeconds(bash_exec.timeout_seconds_default),
    /// Bytes piped to the child's stdin before it sees EOF. Null (default)
    /// inherits no stdin.
    stdin: ?[]const u8 = null,
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, command: []const u8) !Result {
    return runWithOptions(gpa, io, .{ .cwd = cwd, .command = command });
}

pub fn runWithOptions(gpa: std.mem.Allocator, io: std.Io, options: RunOptions) !Result {
    assert(options.cwd.len > 0);
    assert(options.command.len > 0);
    return runUnderPwsh(gpa, io, options);
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
    return runUnderPwsh(gpa, io, .{
        .cwd = cwd,
        .command = command,
        .stdin = stdin,
    });
}

/// Spawn `pwsh -NoLogo -NoProfile -NonInteractive -File <script>` and drain
/// stdout/stderr to completion under a TOTAL runtime deadline. The exit-checked
/// script is written to a temp `.ps1` file, so multi-line PowerShell constructs
/// (full commands, `& { ... }` blocks, function definitions) are honored — a
/// `-Command -` stdin feed empirically drops multi-line block/function output and
/// mangled the `& { } 2>&1` wrapper, and an argv `-Command "<script>"` round-trip
/// strips quotes and hits the 32K CreateProcess command-line cap. The temp file
/// sidesteps both. When `runWithStdin` supplies stdin bytes they are piped to
/// the child separately (a `-File` script doesn't consume stdin), so the model
/// command can read them via `$input` as usual.
fn runUnderPwsh(gpa: std.mem.Allocator, io: std.Io, options: RunOptions) !Result {
    assert(options.cwd.len > 0);
    assert(options.command.len > 0);
    if (std.mem.indexOfScalar(u8, options.command, 0) != null) return error.InvalidCharacter;
    const script = try exitCheckedScript(gpa, options.command);
    defer gpa.free(script);
    const script_path = try writeScriptTemp(gpa, io, script);
    defer cleanupScriptTemp(gpa, io, script_path);

    var child = try std.process.spawn(io, .{
        .argv = &.{ shellPath(io), "-NoLogo", "-NoProfile", "-NonInteractive", "-File", script_path },
        .cwd = .{ .path = options.cwd },
        .environ_map = options.env_map,
        .stdin = if (options.stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
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

/// Write `script` to a fresh `nova-pwsh-script-<hex>.ps1` temp file under the
/// shared temp dir (reusing `bash_exec.namedTempPath`'s containment checks).
/// Caller owns the returned path and must `cleanupScriptTemp` it.
fn writeScriptTemp(gpa: std.mem.Allocator, io: std.Io, script: []const u8) ![]u8 {
    var random: [16]u8 = undefined;
    io.random(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const name = try std.fmt.allocPrint(gpa, temp_files.pwsh_prefix ++ "script-{s}.ps1", .{hex[0..]});
    defer gpa.free(name);
    const path = try bash_exec.namedTempPath(gpa, name);
    errdefer gpa.free(path);
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    // Prefix UTF-8 BOM (\xEF\xBB\xBF) so Windows PowerShell 5.1 interprets the
    // script as UTF-8 rather than ANSI/Windows-1252, while PowerShell 7+ handles it seamlessly.
    try file.writeStreamingAll(io, "\xEF\xBB\xBF");
    try file.writeStreamingAll(io, script);
    return path;
}

fn cleanupScriptTemp(gpa: std.mem.Allocator, io: std.Io, path: []const u8) void {
    std.Io.Dir.deleteFile(.cwd(), io, path) catch {};
    gpa.free(path);
}

/// Wrap `command` so PowerShell exits nonzero when any statement fails, WITHOUT
/// a `& { ... }` block (a multi-line block's output is dropped under `-Command -`
/// stdin mode). Instead we append a trailing `$?`/`$LASTEXITCODE` check directly
/// after the user command, which runs in `-File` mode as plain statements:
///   - `$?` is false when ANY statement failed (native non-zero exit, Write-
///     Error, thrown exception) → `exit 1`.
///   - otherwise `exit $LASTEXITCODE` (correct code for a failed native command
///     that did run, `exit $null` = 0 on a pure-cmdlet success).
/// A user command that itself calls `exit N` exits the process with N before the
/// trailing check runs, which is the desired behavior.
///
/// Stderr is NOT merged here — it stays on its own stream and is combined with
/// stdout in the reader (see `capture`), matching the plan's Buffer(2) design.
///
/// `color_disable` is prepended to suppress ANSI colorization at the source:
/// PowerShell 7.2+ (`pwsh`) only formats in color when `$PSStyle.OutputRendering`
/// allows it, and native colorizers honor `NO_COLOR`. The `if ($null -ne $PSStyle)`
/// guard keeps it safe on Windows PowerShell 5.1 (`powershell.exe`), where
/// `$PSStyle` is `$null` and assigning a property to it would throw.
const color_disable =
    \\$env:NO_COLOR = '1'
    \\if ($null -ne $PSStyle) { $PSStyle.OutputRendering = 'PlainText' }
    \\
;
fn exitCheckedScript(gpa: std.mem.Allocator, command: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}{s}\nif (-not $?) {{ exit 1 }} else {{ exit $LASTEXITCODE }}", .{ color_disable, command });
}

/// Inline-vs-spill thresholds for `capture`. Shared via `capture_sink` (bash
/// re-exports the same type) so both shells honor identical observation budgets.
pub const CaptureLimits = capture_sink.CaptureLimits;
pub const CaptureOptions = struct {
    cwd: []const u8,
    command: []const u8,
    env_map: ?*const std.process.Environ.Map = null,
    timeout: std.Io.Timeout = bash_exec.timeoutFromSeconds(bash_exec.timeout_seconds_default),
    limits: CaptureLimits,
};

const capture_read_reserve = capture_sink.capture_read_reserve;

/// Run `command` under PowerShell, merging stderr into the captured stream in
/// the reader (stderr stays on its own stream; PowerShell has no session-wide
/// `exec 2>&1` redirect), and stream the result into a bounded tail with lazy
/// spill. The exit-checked script is written to a temp `.ps1` file and run with
/// `-File` (see `runUnderPwsh` for why stdin/argv are both avoided). See
/// `Capture`.
pub fn capture(gpa: std.mem.Allocator, io: std.Io, options: CaptureOptions) !Capture {
    assert(options.cwd.len > 0);
    assert(options.command.len > 0);
    if (std.mem.indexOfScalar(u8, options.command, 0) != null) return error.InvalidCharacter;
    assert(options.limits.tail_bytes_max > options.limits.bytes_max);
    assert(options.limits.spill_bytes_max >= options.limits.tail_bytes_max);

    const script = try exitCheckedScript(gpa, options.command);
    defer gpa.free(script);
    const script_path = try writeScriptTemp(gpa, io, script);
    defer cleanupScriptTemp(gpa, io, script_path);

    var child = try std.process.spawn(io, .{
        .argv = &.{ shellPath(io), "-NoLogo", "-NoProfile", "-NonInteractive", "-File", script_path },
        .cwd = .{ .path = options.cwd },
        .environ_map = options.env_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var sink: Sink = .{ .limits = options.limits };
    errdefer sink.deinit(gpa, io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    // Merge both streams in the reader, appending any buffered bytes from each
    // stream in the order the MultiReader surfaces them, so stderr and stdout
    // stay chronologically interleaved (stderr is NOT merged into the command
    // for PowerShell, unlike bash's `exec 2>&1`).
    const reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    const deadline = options.timeout.toDeadline(io);

    var timed_out = false;
    while (multi_reader.fill(capture_read_reserve, deadline)) |_| {
        if (reader.buffered().len > 0) {
            try sink.ingest(gpa, io, reader.buffered());
            reader.tossBuffered();
        }
        if (stderr_reader.buffered().len > 0) {
            try sink.ingest(gpa, io, stderr_reader.buffered());
            stderr_reader.tossBuffered();
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => timed_out = true,
        else => |e| return e,
    }

    if (!timed_out) try multi_reader.checkAnyError();
    // `os.termCode`: the trailing exit-check normalizes in-shell failures to an
    // explicit `exit 1`/`exit $LASTEXITCODE` (see `exitCheckedScript`), so
    // `.exited` carries the real value; signal/unknown maps to 255.
    const code = if (timed_out) 124 else os.termCode(try child.wait(io));

    return sink.finish(gpa, io, code, timed_out);
}

/// Per-shell `capture_sink.Sink` instantiation: the spill log carries the pwsh
/// prunable prefix (`nova-pwsh-`, pinned by temp_files tests) and spills into
/// the same shared temp dir bash uses (`bash_exec.tempDir`).
const PwshSinkConfig = struct {
    pub const spill_prefix = temp_files.pwsh_prefix;
    pub const spillDir = bash_exec.tempDir;
};
const Sink = capture_sink.Sink(PwshSinkConfig);

/// POSIX-only no-op: PowerShell needs no login-shell env snapshot (Windows
/// command shells inherit the process environment directly). Mirrors
/// `bash_exec.loginEnvBlock`'s null-on-Windows behavior.
pub fn loginEnvBlock(io: std.Io) ?[]const u8 {
    _ = io;
    return null;
}

/// POSIX-only no-op: there is no MSYS2/Cygwin pseudo-console to disable.
pub fn disablePseudoConsole() void {}

var pwsh_mutex: std.Io.Mutex = .init;
var pwsh_path_value: ?[]const u8 = null;

/// The resolved PowerShell executable path (`pwsh.exe` → `powershell.exe` on
/// Windows, `"pwsh"` elsewhere as a harmless never-called fallback). Exposed so
/// the `BackgroundManager` spawns the same shell as foreground runs.
pub fn shellPath(io: std.Io) []const u8 {
    if (pwsh_mutex.lock(io)) |_| {
        defer pwsh_mutex.unlock(io);
        if (pwsh_path_value) |p| return p;
        const resolved = resolvePwshPath(io);
        pwsh_path_value = resolved;
        return resolved;
    } else |_| {
        return if (pwsh_path_value) |p| p else "pwsh.exe";
    }
}

fn resolvePwshPath(io: std.Io) []const u8 {
    if (!os.is_windows) return "pwsh";
    // Prefer PowerShell 7 (`pwsh.exe`); fall back to Windows PowerShell 5.1.
    for ([_][]const u8{ "pwsh.exe", "powershell.exe" }) |exe| {
        if (findOnPath(io, exe)) |path| return path;
    }
    return "pwsh.exe";
}

/// Look `exe` up on PATH and return the first match's absolute path, or null.
fn findOnPath(io: std.Io, exe: []const u8) ?[]const u8 {
    const gpa = std.heap.page_allocator;
    var map = std.process.Environ.createMap(.{ .block = .global }, gpa) catch return null;
    defer map.deinit();
    const path_value = map.get("PATH") orelse return null;
    var it = std.mem.tokenizeScalar(u8, path_value, ';');
    while (it.next()) |dir| {
        const candidate = std.fs.path.join(gpa, &.{ dir, exe }) catch continue;
        defer gpa.free(candidate);
        if (std.Io.Dir.accessAbsolute(io, candidate, .{})) |_| {
            return gpa.dupe(u8, candidate) catch null;
        } else |_| {}
    }
    return null;
}

test "pwsh captures stdout and exit code" {
    if (!os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var result = try run(gpa, std.testing.io, cwd, "Write-Output hello");
    defer result.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hello") != null);
    try std.testing.expectEqual(@as(u8, 0), result.code);
}

test "pwsh forwards stdin from buffer" {
    if (!os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var result = try runWithStdin(gpa, std.testing.io, cwd, "Write-Output foo", "piped-bytes");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), result.code);
}

test "pwsh capture enforces total runtime" {
    if (!os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var captured = try capture(gpa, std.testing.io, .{
        .cwd = cwd,
        .command = "while ($true) { Write-Output t; Start-Sleep -Milliseconds 50 }",
        .timeout = bash_exec.timeoutFromSeconds(1),
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

test "pwsh spill stops growing at cap" {
    // Pure Sink test — runs on all platforms (no spawn).
    const gpa = std.testing.allocator;
    var sink: Sink = .{ .limits = .{
        .bytes_max = 4,
        .lines_max = 100,
        .tail_bytes_max = 64,
        .spill_bytes_max = 16,
    } };
    defer sink.deinit(gpa, std.testing.io);

    try sink.ingest(gpa, std.testing.io, "aaaa");
    try sink.ingest(gpa, std.testing.io, "bbbb");
    try std.testing.expect(sink.spill != null);
    try sink.ingest(gpa, std.testing.io, "cccc");
    try sink.ingest(gpa, std.testing.io, "dddd");
    try sink.ingest(gpa, std.testing.io, "eeee");
    try std.testing.expectEqual(@as(usize, 16), sink.spill_bytes);
}

test "exitCheckedScript wraps command and normalizes exit" {
    // Pure helper test — runs on all platforms. The no-block form is required:
    // a multi-line `& { ... } 2>&1` block is not honored under `-Command -`
    // (stdin) mode, so the trailing `$?`/`$LASTEXITCODE` check is appended
    // directly after the user command.
    const gpa = std.testing.allocator;
    const script = try exitCheckedScript(gpa, "Write-Output hi");
    defer gpa.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "Write-Output hi") != null);
    // The color-disable preamble precedes the user command.
    try std.testing.expect(std.mem.startsWith(u8, script, "$env:NO_COLOR = '1'"));
    try std.testing.expect(std.mem.indexOf(u8, script, "$env:NO_COLOR = '1'") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "$PSStyle.OutputRendering = 'PlainText'") != null);
    // The `$null` guard keeps PSStyle assignment 5.1-safe.
    try std.testing.expect(std.mem.indexOf(u8, script, "if ($null -ne $PSStyle)") != null);
    // The user command and the trailing exit-normalization check still follow.
    try std.testing.expect(std.mem.indexOf(u8, script, "if (-not $?)") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "exit $LASTEXITCODE") != null);
    // The preamble precedes the user command (ordering).
    const command_pos = std.mem.indexOf(u8, script, "Write-Output hi").?;
    const preamble_pos = std.mem.indexOf(u8, script, "$PSStyle.OutputRendering").?;
    try std.testing.expect(preamble_pos < command_pos);
    // No `& {` block wrapper (see comment above).
    try std.testing.expect(std.mem.indexOf(u8, script, "& {") == null);
}

test "runUnderPwsh rejects command with null byte" {
    const gpa = std.testing.allocator;

    const options = RunOptions{
        .cwd = ".",
        .command = "Write-Output hello\x00world",
    };

    try std.testing.expectError(error.InvalidCharacter, runUnderPwsh(gpa, std.testing.io, options));
}

test "pwsh capture rejects command with null byte" {
    const gpa = std.testing.allocator;

    const options = CaptureOptions{
        .cwd = ".",
        .command = "Write-Output hello\x00world",
        .limits = .{
            .bytes_max = 50 * 1024,
            .lines_max = 2000,
            .tail_bytes_max = 100 * 1024,
            .spill_bytes_max = 10 * 1024 * 1024,
        },
    };
    try std.testing.expectError(error.InvalidCharacter, capture(gpa, std.testing.io, options));
}
