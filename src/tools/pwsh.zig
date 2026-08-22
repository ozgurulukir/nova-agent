const std = @import("std");
const background = @import("../background.zig");
const common = @import("common.zig");
const os = @import("../os.zig");
const platform = @import("platform");
const pws = @import("pwsh_exec.zig");
const paths = @import("../paths.zig");

pub const tool: common.Tool = .{
    .name = "pwsh",
    .description = @embedFile("../prompts/tools/pwsh.md"),
    .schema = .{
        .properties = &.{ .{
            .name = "command",
            .kind = .string,
            .description = "Shell command to run.",
            .required = true,
            .nullable = false,
        }, .{
            .name = "description",
            .kind = .string,
            .description = "Human-readable single-sentence explanation of what this command does — shown as the tool's title.",
            .required = false,
            .nullable = true,
        }, .{
            .name = "cwd",
            .kind = .string,
            .description = "Working directory. Relative to the project unless absolute.",
            .required = false,
            .nullable = true,
        }, .{
            .name = "env",
            .kind = .object,
            .description = "Extra environment variables, merged over the inherited env. String values only.",
            .required = false,
            .nullable = true,
        }, .{ .name = "timeout", .kind = .integer, .description = "Timeout in seconds (default 30).", .required = false, .nullable = true }, .{
            .name = "run_in_background",
            .kind = .boolean,
            .description = "Run the command in the background and return immediately. Use for long-running commands (builds, dev servers, watchers) so you are not blocked. The command's exit will be delivered to you as a message; meanwhile use the `background` tool to inspect status/logs or cancel it. The `timeout` field is ignored for background commands.",
            .required = false,
            .nullable = true,
        } },
    },
    .run = runTool,
    .display = display,
};

/// Background launch context threaded into `runContained` for lane workers
/// whose pwsh call requests `run_in_background`. Mirrors the executor's
/// `BackgroundStart`; null means background is unavailable for this call.
pub const BackgroundCtx = struct {
    manager: *background.BackgroundManager,
    owner: *anyopaque,
};

/// Per-call execution options for the internal run path.
const RunOpts = struct {
    /// When set, prepend the `cd` containment guard so the shell cannot leave
    /// `cwd` (the lane worktree). The guard anchors on the PROJECT root (the
    /// `cwd` param), not the resolved cwd, so a `cwd` subdir argument doesn't
    /// tighten containment to that subdir.
    contained: bool = false,
    /// When set and the call requests `run_in_background`, launch the guarded
    /// command through the manager instead of capturing it synchronously.
    background: ?BackgroundCtx = null,
};

pub fn runTool(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
    userdata: *anyopaque,
) common.Error!common.Output {
    _ = userdata;
    return runToolImpl(gpa, io, cwd, arguments, .{});
}

/// Test convenience wrapper — forwards to `runTool` with a null
/// `userdata` pointer. Production code uses the 5-argument form so
/// `Tool.run` callbacks can route through per-tool context.
pub fn runToolForTest(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
) common.Error!common.Output {
    return runToolImpl(gpa, io, cwd, arguments, .{});
}

/// Root-contained pwsh run for lane workers (see `Agent.contained`). Parses
/// the call like `runTool`, then prepends the cd guard so the command cannot
/// leave `cwd` into the main tree. Background launches (when `background`
/// is non-null and the call asks for one) are guarded too.
pub fn runContained(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
    background_ctx: ?BackgroundCtx,
) common.Error!common.Output {
    return runToolImpl(gpa, io, cwd, arguments, .{ .contained = true, .background = background_ctx });
}

fn runToolImpl(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
    opts: RunOpts,
) common.Error!common.Output {
    var args = parseArgs(gpa, arguments) catch |err| return parseError(gpa, err);
    defer args.deinit();
    var command_cwd: ?[]u8 = null;
    defer if (command_cwd) |path| gpa.free(path);
    const resolved_cwd = if (args.cwd) |path| value: {
        if (std.fs.path.isAbsolute(path)) break :value path;
        command_cwd = std.fs.path.join(gpa, &.{ cwd, path }) catch return error.OutOfMemory;
        break :value command_cwd.?;
    } else cwd;

    if (!validateCwd(gpa, io, cwd, resolved_cwd)) {
        return common.failFmt(gpa, 1, "pwsh: cwd '{s}' escapes the project root\n", .{resolved_cwd});
    }

    var env_map = try currentEnvMap(gpa, io);
    defer env_map.deinit();
    if (args.env) |env| try applyEnv(&env_map, env);

    // A contained run replaces the model's command with the guard-prefixed
    // form; the guard definition is silent, so the observation still reads as
    // the original command (`finishPwshOutput` echoes `command`, not the guard).
    var owned_command: ?[]u8 = null;
    defer if (owned_command) |command| gpa.free(command);
    const command = if (opts.contained) blk: {
        owned_command = prependCdGuard(gpa, cwd, args.command) catch return error.OutOfMemory;
        break :blk owned_command.?;
    } else args.command;

    if (opts.background) |bg| {
        if (wantsBackground(gpa, arguments)) {
            return runBackgroundImpl(gpa, io, resolved_cwd, command, bg.manager, bg.owner, &env_map);
        }
    }

    return runCaptured(gpa, io, resolved_cwd, command, &env_map, args.timeout_seconds);
}

/// Run `command` under PowerShell with the tool's standard capture limits and
/// shape the result into a tool `Output` (merged-output observation, exit-code
/// framing, spill-to-disk on overflow). `cwd` must already be resolved to an
/// absolute path.
pub fn runCaptured(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    command: []const u8,
    env_map: *const std.process.Environ.Map,
    timeout_seconds: u32,
) common.Error!common.Output {
    var captured = pws.capture(gpa, io, .{
        .cwd = cwd,
        .command = command,
        .env_map = env_map,
        .timeout = pws.timeoutFromSeconds(timeout_seconds),
        .limits = capture_limits,
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Canceled) return error.Canceled;
        return common.failFmt(gpa, 1, "pwsh: command failed to run: {s}\n", .{describePwshError(err)});
    };
    defer captured.deinit(gpa);

    const status: FinishStatus = if (captured.timed_out) .{ .timeout_seconds = timeout_seconds } else .{};
    return finishPwshOutput(gpa, &captured, status, command);
}

/// Whether the pwsh arguments request a background launch. Cheap parse used by
/// the executor to decide whether to route the call to the `BackgroundManager`
/// before falling back to a normal blocking run. False on any parse failure.
pub fn wantsBackground(gpa: std.mem.Allocator, arguments: []const u8) bool {
    const Probe = struct { run_in_background: ?bool = null };
    const parsed = std.json.parseFromSlice(Probe, gpa, arguments, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();
    return parsed.value.run_in_background orelse false;
}

/// Launch the command in the background via `manager` and return immediately
/// with an observation telling the model the job id, pid, and log path. The
/// job's eventual exit is delivered to the agent as a message by the manager.
pub fn runBackground(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
    manager: *background.BackgroundManager,
    owner: *anyopaque,
) common.Error!common.Output {
    var args = parseArgs(gpa, arguments) catch |err| return parseError(gpa, err);
    defer args.deinit();
    var command_cwd: ?[]u8 = null;
    defer if (command_cwd) |path| gpa.free(path);
    const resolved_cwd = if (args.cwd) |path| value: {
        if (std.fs.path.isAbsolute(path)) break :value path;
        command_cwd = std.fs.path.join(gpa, &.{ cwd, path }) catch return error.OutOfMemory;
        break :value command_cwd.?;
    } else cwd;

    if (!validateCwd(gpa, io, cwd, resolved_cwd)) {
        return common.failFmt(gpa, 1, "pwsh: cwd '{s}' escapes the project root\n", .{resolved_cwd});
    }

    var env_map = try currentEnvMap(gpa, io);
    defer env_map.deinit();
    if (args.env) |env| try applyEnv(&env_map, env);

    return runBackgroundImpl(gpa, io, resolved_cwd, args.command, manager, owner, &env_map);
}

/// The shared background launch tail: start `command` (already cwd-resolved,
/// possibly guard-prefixed) through `manager` and return the observation. The
/// job's eventual exit is delivered to the agent as a message by the manager.
fn runBackgroundImpl(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    command: []const u8,
    manager: *background.BackgroundManager,
    owner: *anyopaque,
    env_map: *const std.process.Environ.Map,
) common.Error!common.Output {
    var started = manager.start(.{
        .command = command,
        .cwd = cwd,
        .env_map = env_map,
        .owner = owner,
        .shell_path = pws.shellPath(io),
        .command_mode = .stdin_dash_command,
        .stderr_merge_prefix = "",
        .stderr_merge_suffix = "\nif (-not $?) { exit 1 } else { exit $LASTEXITCODE }",
    }) catch |err| return mapBackgroundError(gpa, err);
    defer started.deinit(gpa);

    const text = try std.fmt.allocPrint(
        gpa,
        "Started in the background as {s} (id {d}, pid {d}).\n" ++
            "Output is streaming to {s}.\n" ++
            "To inspect status/logs or cancel, use the `background` tool (`command`: \"status\"/\"tail\"/\"cancel\", `id`: {d}).\n" ++
            "Do not wait on it: its exit will be delivered to you as a message when it finishes.",
        .{ started.label, started.id, started.pid, started.log_path, started.id },
    );
    return common.ok(gpa, text);
}

/// PowerShell function overrides prepended to a contained command. `Set-Location`
/// shadows the built-in for every alias (`cd`, `sl`, `chdir`, `l`), computes the
/// absolute target via `GetFullPath`, and refuses anything outside
/// `_nova_root` (set to the project root by `prependCdGuard`). `Push-Location`/
/// `Pop-Location` are rejected outright (they'd bypass the guard's state). This is
/// defense-in-depth, not a sandbox — it neutralizes location-based escapes, not
/// absolute-path writes. The `cd:` message writes to stderr so it is captured but
/// the guard still fails the command.
const cd_guard_functions =
    \\function Set-Location { param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Path)
    \\    $target = if ($Path.Count -eq 0) { (Get-Location).Path } else { $Path[0] }
    \\    $abs = if ([System.IO.Path]::IsPathRooted($target)) { $target } else { Join-Path (Get-Location) $target }
    \\    $abs = [System.IO.Path]::GetFullPath($abs)
    \\    $root = $_nova_root.TrimEnd('\', '/')
    \\    if ($abs -ne $_nova_root -and $abs -ne $root -and $abs -notlike "$root\*") { throw "cd: $abs escapes the workspace root" }
    \\    Microsoft.PowerShell.Core\Set-Location @Path }
    \\function Push-Location { throw "pushd: not allowed in this workspace" }
    \\function Pop-Location  { throw "popd: not allowed in this workspace" }
    \\
;

/// Prefix `command` with `_nova_root` (the canonicalized project root via
/// `[System.IO.Path]::GetFullPath`, single-quoted and quote-doubled for PowerShell)
/// and the `Set-Location`/`Push-Location`/`Pop-Location` guard functions.
/// `_nova_root` anchors on the project root — not the shell's start cwd — so
/// a `cwd` subdir argument does not tighten containment to that subdir.
fn prependCdGuard(gpa: std.mem.Allocator, project_root: []const u8, command: []const u8) std.mem.Allocator.Error![]u8 {
    const normalized_root = std.fs.path.resolve(gpa, &.{project_root}) catch return error.OutOfMemory;
    defer gpa.free(normalized_root);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "$_nova_root = [System.IO.Path]::GetFullPath('");
    for (normalized_root) |c| {
        if (c == '\'') {
            try out.appendSlice(gpa, "''");
        } else {
            try out.append(gpa, c);
        }
    }
    try out.appendSlice(gpa, "');\n");
    try out.appendSlice(gpa, cd_guard_functions);
    try out.appendSlice(gpa, command);
    return out.toOwnedSlice(gpa);
}

/// Validate that `resolved_cwd` stays within the project root. Tolerant of
/// mixed slash conventions and Windows case-insensitivity.
fn validateCwd(gpa: std.mem.Allocator, io: std.Io, project_root: []const u8, resolved_cwd: []const u8) bool {
    const normalized = std.fs.path.resolve(gpa, &.{ project_root, resolved_cwd }) catch return false;
    defer gpa.free(normalized);
    const normalized_root = std.fs.path.resolve(gpa, &.{project_root}) catch return false;
    defer gpa.free(normalized_root);

    if (!paths.pathsEqual(normalized[0..@min(normalized.len, normalized_root.len)], normalized_root)) return false;
    const root_has_sep = normalized_root.len > 0 and (normalized_root[normalized_root.len - 1] == '/' or normalized_root[normalized_root.len - 1] == '\\');
    if (normalized.len > normalized_root.len and !root_has_sep and normalized[normalized_root.len] != std.fs.path.sep and normalized[normalized_root.len] != '/') return false;

    // Best-effort symlink resolution (TD-4): canonicalize the resolved cwd and
    // the root and re-check containment. `realPathFileAbsoluteAlloc` asserts the
    // path is absolute on the host OS, so a cross-OS path (a Windows drive path
    // resolved on POSIX, or vice versa) — which `std.fs.path.resolve` leaves
    // non-absolute on the foreign OS — would trip that assert and crash. When
    // the normalized path is not absolute on this host the realpath re-check
    // cannot run; fall back to the lexical verdict already computed above,
    // mirroring the `catch return true` degradation for realpath failures.
    if (!std.fs.path.isAbsolute(normalized) or !std.fs.path.isAbsolute(normalized_root)) return true;
    const real_cwd = std.Io.Dir.realPathFileAbsoluteAlloc(io, normalized, gpa) catch return true;
    defer gpa.free(real_cwd);
    const real_root = std.Io.Dir.realPathFileAbsoluteAlloc(io, normalized_root, gpa) catch return true;
    defer gpa.free(real_root);

    if (!paths.pathsEqual(real_cwd[0..@min(real_cwd.len, real_root.len)], real_root)) return false;
    const real_root_has_sep = real_root.len > 0 and (real_root[real_root.len - 1] == '/' or real_root[real_root.len - 1] == '\\');
    if (real_cwd.len > real_root.len and !real_root_has_sep and real_cwd[real_root.len] != std.fs.path.sep and real_cwd[real_root.len] != '/') return false;

    return true;
}

fn mapBackgroundError(gpa: std.mem.Allocator, err: anyerror) common.Error!common.Output {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => common.failFmt(gpa, 1, "pwsh: failed to launch background command: {s}\n", .{@errorName(err)}),
    };
}

const Args = struct {
    command: []const u8,
    summary: []const u8,
    cwd: ?[]const u8 = null,
    env: ?std.json.Value = null,
    parsed: std.json.Parsed(JsonArgs),
    timeout_seconds: u32 = pws.timeout_seconds_default,

    fn deinit(self: *Args) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

const JsonArgs = struct {
    command: ?[]const u8 = null,
    description: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    env: ?std.json.Value = null,
    timeout: ?u32 = null,
};

const ParseError = error{
    InvalidJson,
    MissingCommand,
    BadCommand,
    BadCwd,
    BadEnv,
    BadEnvKey,
    BadEnvValue,
    BadTimeout,
};

fn parseArgs(gpa: std.mem.Allocator, arguments: []const u8) ParseError!Args {
    const parsed = std.json.parseFromSlice(JsonArgs, gpa, arguments, .{ .ignore_unknown_fields = true }) catch return error.InvalidJson;
    errdefer parsed.deinit();

    const command = parsed.value.command orelse return error.MissingCommand;
    if (command.len == 0) return error.MissingCommand;

    const summary = if (parsed.value.description) |d|
        (if (d.len > 0) d else "Executing command.")
    else
        "Executing command.";

    if (parsed.value.cwd) |cwd| {
        if (cwd.len == 0) return error.BadCwd;
    }

    if (parsed.value.env) |env| {
        if (env != .object) return error.BadEnv;
        try validateEnv(env);
    }

    const timeout_seconds = @min(parsed.value.timeout orelse pws.timeout_seconds_default, pws.timeout_seconds_max);
    if (timeout_seconds == 0) return error.BadTimeout;

    return .{
        .command = command,
        .summary = summary,
        .cwd = parsed.value.cwd,
        .env = parsed.value.env,
        .parsed = parsed,
        .timeout_seconds = timeout_seconds,
    };
}

fn validateEnv(env: std.json.Value) ParseError!void {
    var iterator = env.object.iterator();
    while (iterator.next()) |entry| {
        if (!std.process.Environ.Map.validateKeyForPut(entry.key_ptr.*)) return error.BadEnvKey;
        if (entry.value_ptr.* != .string) return error.BadEnvValue;
    }
}

fn parseError(gpa: std.mem.Allocator, err: ParseError) common.Error!common.Output {
    return switch (err) {
        error.InvalidJson => common.fail(gpa, "pwsh: invalid JSON arguments\n", 2),
        error.MissingCommand => common.fail(gpa, "pwsh: missing command\n", 2),
        error.BadCommand => common.fail(gpa, "pwsh: command must be a string\n", 2),
        error.BadCwd => common.fail(gpa, "pwsh: cwd must be a non-empty string\n", 2),
        error.BadEnv => common.fail(gpa, "pwsh: env must be an object\n", 2),
        error.BadEnvKey => common.fail(gpa, "pwsh: env keys must be valid environment variable names\n", 2),
        error.BadEnvValue => common.fail(gpa, "pwsh: env values must be strings\n", 2),
        error.BadTimeout => common.fail(gpa, "pwsh: timeout must be a positive integer number of seconds\n", 2),
    };
}

pub fn currentEnvMap(gpa: std.mem.Allocator, io: std.Io) (std.mem.Allocator.Error || std.Io.UnexpectedError)!std.process.Environ.Map {
    var map = try platform.getEnvMap(gpa);
    errdefer map.deinit();

    // PowerShell needs no login-shell env snapshot (`pwsh_exec.loginEnvBlock`
    // always returns null); keep the call for parity with the bash tool. The
    // per-command `env` arg is applied after this base and still wins.
    _ = pws.loginEnvBlock(io);
    return map;
}

fn applyEnv(map: *std.process.Environ.Map, env: std.json.Value) std.mem.Allocator.Error!void {
    var iterator = env.object.iterator();
    while (iterator.next()) |entry| {
        try map.put(entry.key_ptr.*, entry.value_ptr.string);
    }
}

const observation_lines_max: u32 = 2000;
const observation_bytes_max: usize = 50 * 1024;
const rolling_bytes_max: usize = observation_bytes_max * 2;

/// Capture thresholds for `pws.capture`.
const capture_limits: pws.CaptureLimits = .{
    .bytes_max = observation_bytes_max,
    .lines_max = observation_lines_max,
    .tail_bytes_max = rolling_bytes_max,
    .spill_bytes_max = 10 * 1024 * 1024,
};

const FinishStatus = struct {
    timeout_seconds: ?u32 = null,
};

const TailSnapshot = struct {
    text: []u8,
    total_lines: u32,
    shown_lines: u32,
    total_bytes: u64,
    shown_bytes: u32,
    truncated: bool,
    last_line_partial: bool,
};

/// Sentinel lines that tools and scripts wrap visual diff output in. Anything
/// between a begin/end pair is routed to the human display channel (`Output.display`,
/// rendered as a visual diff widget in the TUI) and stripped from the model-facing
/// observation. Shared with the bash tool.
pub const display_diff_begin = "\x1enova:diff";
pub const display_diff_end = "\x1enova:end";

/// Turn a `pws.Capture` into the tool's observation (see `finishBashOutput` for
/// the bash twin — this version echoes with the `>` prompt).
fn finishPwshOutput(
    gpa: std.mem.Allocator,
    captured: *const pws.Capture,
    status: FinishStatus,
    command: []const u8,
) common.Error!common.Output {
    // Strip ANSI before shaping the observation: PowerShell's error/table
    // formatting can emit raw VT codes into the capture even with PSStyle
    // PlainText set (a child program can print its own ANSI regardless). The
    // model reads the escape noise as corruption, so clean it here. `total_lines`/
    // `total_bytes` still reflect the original capture (accurate truncation footer).
    const stripped = common.stripAnsi(gpa, captured.tail) catch return error.OutOfMemory;
    defer gpa.free(stripped);

    var extraction = extractDisplayBlocks(gpa, stripped) catch return error.OutOfMemory;
    defer extraction.deinit(gpa);

    var snapshot = truncateTailBuffer(gpa, extraction.remainder, captured.total_lines, captured.total_bytes) catch return error.OutOfMemory;
    defer snapshotDeinit(gpa, &snapshot);

    const observation_text = formatPwshText(gpa, snapshot.text, captured.code, status, command) catch return error.OutOfMemory;
    var observation_text_moved = false;
    errdefer if (!observation_text_moved) gpa.free(observation_text);

    var observation: common.Observation = if (captured.spill_path) |spill_path| truncated: {
        const path = try gpa.dupe(u8, spill_path);
        errdefer gpa.free(path);
        break :truncated .{ .truncated_tail = .{
            .text = observation_text,
            .total_lines = snapshot.total_lines,
            .shown_lines = snapshot.shown_lines,
            .total_bytes = snapshot.total_bytes,
            .shown_bytes = snapshot.shown_bytes,
            .full_output_path = path,
        } };
    } else .{ .complete = observation_text };
    observation_text_moved = true;
    errdefer observation.deinit(gpa);
    const display_text = observation.render(gpa) catch return error.OutOfMemory;
    errdefer gpa.free(display_text);

    const stderr = try gpa.alloc(u8, 0);
    errdefer gpa.free(stderr);
    const display_block = extraction.takeDisplay();
    const display_value: common.Display = if (display_block) |block| blk: {
        if (block.len == 0) {
            gpa.free(block);
            break :blk .none;
        }
        break :blk .{ .diff = block };
    } else .none;
    return .{
        .stdout = display_text,
        .stderr = stderr,
        .code = captured.code,
        .display = display_value,
        .observation = observation,
    };
}

const DisplayExtraction = struct {
    /// The captured tail with every display block (markers included) removed.
    remainder: []u8,
    /// Concatenated inner text of all blocks, or null when none were found.
    display: ?[]u8,

    /// Move the display text out; the caller owns it. See `take*` convention.
    fn takeDisplay(self: *DisplayExtraction) ?[]u8 {
        const text = self.display;
        self.display = null;
        return text;
    }

    fn deinit(self: *DisplayExtraction, gpa: std.mem.Allocator) void {
        gpa.free(self.remainder);
        if (self.display) |text| gpa.free(text);
        self.* = undefined;
    }
};

fn extractDisplayBlocks(gpa: std.mem.Allocator, tail: []const u8) std.mem.Allocator.Error!DisplayExtraction {
    if (std.mem.indexOf(u8, tail, display_diff_begin) == null and
        std.mem.indexOf(u8, tail, display_diff_end) == null)
    {
        return .{ .remainder = try gpa.dupe(u8, tail), .display = null };
    }

    var remainder: std.ArrayList(u8) = .empty;
    errdefer remainder.deinit(gpa);
    var blocks: std.ArrayList(u8) = .empty;
    errdefer blocks.deinit(gpa);
    var found_block = false;

    var cursor: usize = 0;
    while (cursor < tail.len) {
        const line_end = std.mem.findScalarPos(u8, tail, cursor, '\n') orelse tail.len;
        const line_span_end = @min(line_end + 1, tail.len);
        const line = std.mem.trimEnd(u8, tail[cursor..line_end], "\r");
        if (std.mem.eql(u8, line, display_diff_begin)) {
            if (findBlockEnd(tail, line_span_end)) |block| {
                if (found_block) try blocks.append(gpa, '\n');
                try blocks.appendSlice(gpa, tail[line_span_end..block.text_end]);
                found_block = true;
                cursor = block.next;
                continue;
            }
            try remainder.appendSlice(gpa, tail[cursor..]);
            break;
        }
        if (!std.mem.eql(u8, line, display_diff_end)) {
            try remainder.appendSlice(gpa, tail[cursor..line_span_end]);
        }
        cursor = line_span_end;
    }

    return .{
        .remainder = try remainder.toOwnedSlice(gpa),
        .display = if (found_block) try blocks.toOwnedSlice(gpa) else blk: {
            blocks.deinit(gpa);
            break :blk null;
        },
    };
}

const BlockEnd = struct {
    text_end: usize,
    next: usize,
};

fn findBlockEnd(tail: []const u8, from: usize) ?BlockEnd {
    var cursor = from;
    while (cursor < tail.len) {
        const line_end = std.mem.findScalarPos(u8, tail, cursor, '\n') orelse tail.len;
        const line = std.mem.trimEnd(u8, tail[cursor..line_end], "\r");
        if (std.mem.eql(u8, line, display_diff_end)) {
            const text_end = if (cursor > from) cursor - 1 else from;
            return .{ .text_end = text_end, .next = @min(line_end + 1, tail.len) };
        }
        cursor = @min(line_end + 1, tail.len);
        if (line_end == tail.len) break;
    }
    return null;
}

fn snapshotDeinit(gpa: std.mem.Allocator, snapshot: *TailSnapshot) void {
    gpa.free(snapshot.text);
    snapshot.* = undefined;
}

fn formatPwshText(
    gpa: std.mem.Allocator,
    text: []const u8,
    code: u8,
    status: FinishStatus,
    command: []const u8,
) std.mem.Allocator.Error![]u8 {
    const prefix = try echoCommand(gpa, command);
    defer gpa.free(prefix);
    if (status.timeout_seconds) |seconds| {
        if (text.len == 0) {
            return std.fmt.allocPrint(
                gpa,
                "{s}Command timed out after {d} seconds — retry with a larger `timeout` or use `run_in_background`",
                .{ prefix, seconds },
            );
        }
        return std.fmt.allocPrint(
            gpa,
            "{s}{s}\n\nCommand timed out after {d} seconds — retry with a larger `timeout` or use `run_in_background`",
            .{ prefix, text, seconds },
        );
    }
    if (code != 0) {
        if (text.len == 0) return std.fmt.allocPrint(gpa, "{s}Command exited with code {d}", .{ prefix, code });
        return std.fmt.allocPrint(gpa, "{s}{s}\n\nCommand exited with code {d}", .{ prefix, text, code });
    }
    if (text.len == 0) return std.fmt.allocPrint(gpa, "{s}(no output)", .{prefix});
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, text });
}

/// `> <command>\n`, the observation prefix that ties a result back to what was
/// invoked (the PowerShell analog of bash's `$`). The display-channel sentinel
/// byte (`\x1e`) is escaped to the two characters `\x1e` so the model-facing
/// observation never carries the raw byte.
fn echoCommand(gpa: std.mem.Allocator, command: []const u8) std.mem.Allocator.Error![]u8 {
    if (std.mem.indexOfScalar(u8, command, '\x1e') == null) {
        return std.fmt.allocPrint(gpa, "> {s}\n", .{command});
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "> ");
    for (command) |byte| {
        if (byte == '\x1e') {
            try out.appendSlice(gpa, "\\x1e");
        } else {
            try out.append(gpa, byte);
        }
    }
    try out.append(gpa, '\n');
    return out.toOwnedSlice(gpa);
}

fn truncateTailBuffer(gpa: std.mem.Allocator, tail: []const u8, total_lines: u32, total_bytes: u64) !TailSnapshot {
    const truncated = total_lines > observation_lines_max or total_bytes > observation_bytes_max;
    if (!truncated) {
        return .{
            .text = try gpa.dupe(u8, tail),
            .total_lines = total_lines,
            .shown_lines = total_lines,
            .total_bytes = total_bytes,
            .shown_bytes = @intCast(@min(total_bytes, std.math.maxInt(u32))),
            .truncated = false,
            .last_line_partial = false,
        };
    }

    var start = tail.len;
    var lines_seen: u32 = 0;
    var bytes_seen: usize = 0;
    while (start > 0) {
        const next = previousUtf8Start(tail, start);
        const byte_count = start - next;
        if (bytes_seen + byte_count > observation_bytes_max) break;
        bytes_seen += byte_count;
        start = next;
        if (tail[start] == '\n') {
            if (lines_seen >= observation_lines_max) {
                start += 1;
                break;
            }
            lines_seen += 1;
        }
    }
    while (start < tail.len and (tail[start] & 0xC0) == 0x80) start += 1;
    const out = try gpa.dupe(u8, tail[start..]);
    return .{
        .text = out,
        .total_lines = total_lines,
        .shown_lines = countLines(out),
        .total_bytes = total_bytes,
        .shown_bytes = @intCast(@min(out.len, std.math.maxInt(u32))),
        .truncated = true,
        .last_line_partial = start > 0 and start < tail.len and tail[start - 1] != '\n',
    };
}

fn previousUtf8Start(text: []const u8, end: usize) usize {
    var index = end - 1;
    while (index > 0 and (text[index] & 0xC0) == 0x80) index -= 1;
    return index;
}

fn countLines(text: []const u8) u32 {
    if (text.len == 0) return 0;
    var count: u32 = 1;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    if (text[text.len - 1] == '\n') count -= 1;
    return count;
}

fn describePwshError(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "command or shell not found (check PATH / the cwd exists)",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.NotDir => "cwd is not a directory",
        error.StreamTooLong => "output exceeded the capture limit",
        error.Timeout => "timed out",
        else => @errorName(err),
    };
}

/// The pwsh display summary is the model-provided `description`; the expanded
/// title is the executable command.
fn display(gpa: std.mem.Allocator, args: []const u8, userdata: *anyopaque) std.mem.Allocator.Error!common.ToolDisplay {
    _ = userdata;
    const parsed = std.json.parseFromSlice(JsonArgs, gpa, args, .{ .ignore_unknown_fields = true }) catch {
        return .{ .label = try gpa.dupe(u8, "pwsh") };
    };
    defer parsed.deinit();

    const summary: ?[]const u8 = blk: {
        if (parsed.value.description) |d| {
            if (d.len > 0) break :blk d;
        }
        break :blk null;
    };
    if (summary) |s| {
        const label = try gpa.dupe(u8, s);
        errdefer gpa.free(label);
        const command = parsed.value.command orelse return .{ .label = label };
        if (command.len == 0) return .{ .label = label };
        const expanded_label = try gpa.dupe(u8, command);
        return .{ .label = label, .expanded_label = expanded_label };
    }

    const command = parsed.value.command orelse return .{ .label = try gpa.dupe(u8, "pwsh") };
    if (command.len == 0) return .{ .label = try gpa.dupe(u8, "pwsh") };
    return .{ .label = try gpa.dupe(u8, command) };
}

test "pwsh display ignores a legacy reason field" {
    const gpa = std.testing.allocator;
    var label = try display(gpa, "{\"command\":\"Get-Location\",\"reason\":\"Inspect the current directory\"}", undefined);
    defer label.deinit(gpa);
    try std.testing.expectEqualStrings("Get-Location", label.label);
    try std.testing.expect(label.expanded_label == null);
}

test "pwsh display falls back on partial JSON" {
    const gpa = std.testing.allocator;
    var label = try display(gpa, "{\"command", undefined);
    defer label.deinit(gpa);
    try std.testing.expectEqualStrings("pwsh", label.label);
    try std.testing.expect(label.expanded_label == null);
}

test "pwsh display uses description with command as expanded label" {
    const gpa = std.testing.allocator;
    var label = try display(gpa, "{\"command\":\"Get-Location\",\"description\":\"Inspect the current directory\"}", undefined);
    defer label.deinit(gpa);
    try std.testing.expectEqualStrings("Inspect the current directory", label.label);
    try std.testing.expectEqualStrings("Get-Location", label.expanded_label.?);
}

test "pwsh display falls back to the command when no summary is present" {
    const gpa = std.testing.allocator;
    var label = try display(gpa, "{\"command\":\"git status\"}", undefined);
    defer label.deinit(gpa);
    try std.testing.expectEqualStrings("git status", label.label);
    try std.testing.expect(label.expanded_label == null);
}

test "pwsh tool parses timeout" {
    var args = try parseArgs(std.testing.allocator, "{\"command\":\"Write-Output ok\",\"description\":\"read\",\"timeout\":42}");
    defer args.deinit();
    try std.testing.expectEqual(@as(u32, 42), args.timeout_seconds);
}

test "pwsh tool ignores a legacy reason field" {
    var args = try parseArgs(std.testing.allocator, "{\"command\":\"Write-Output ok\",\"reason\":\"Print ok\"}");
    defer args.deinit();
    try std.testing.expectEqualStrings("Executing command.", args.summary);
}

test "pwsh tool accepts description as the canonical summary" {
    var args = try parseArgs(std.testing.allocator, "{\"command\":\"Write-Output ok\",\"description\":\"Print ok\"}");
    defer args.deinit();
    try std.testing.expectEqualStrings("Print ok", args.summary);
}

test "parseArgs clamps timeout to the max" {
    var args = try parseArgs(std.testing.allocator, "{\"command\":\"true\",\"timeout\":999999}");
    defer args.deinit();
    try std.testing.expectEqual(pws.timeout_seconds_max, args.timeout_seconds);
    try std.testing.expectError(error.BadTimeout, parseArgs(std.testing.allocator, "{\"command\":\"true\",\"timeout\":0}"));
}

test "describePwshError names common failures" {
    try std.testing.expect(std.mem.indexOf(u8, describePwshError(error.FileNotFound), "not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, describePwshError(error.NotDir), "not a directory") != null);
    try std.testing.expect(std.mem.eql(u8, "BadPipe", describePwshError(error.BadPipe)));
}

test "validateCwd accepts a trailing-slash project root" {
    try std.testing.expect(validateCwd(std.testing.allocator, std.testing.io, "/tmp/x/", "/tmp/x"));
    try std.testing.expect(validateCwd(std.testing.allocator, std.testing.io, "/tmp/x/", "."));
}

test "validateCwd rejects an absolute cwd outside the root" {
    try std.testing.expect(!validateCwd(std.testing.allocator, std.testing.io, "/tmp/x", "/etc"));
}

test "extractDisplayBlocks routes sentinel content to the display channel" {
    const gpa = std.testing.allocator;
    const tail = "before\n" ++ display_diff_begin ++ "\n-old\n+new\n" ++ display_diff_end ++ "\nafter\n";
    var extraction = try extractDisplayBlocks(gpa, tail);
    defer extraction.deinit(gpa);
    try std.testing.expectEqualStrings("before\nafter\n", extraction.remainder);
    try std.testing.expectEqualStrings("-old\n+new", extraction.display.?);
}

test "extractDisplayBlocks concatenates multiple blocks" {
    const gpa = std.testing.allocator;
    const tail = display_diff_begin ++ "\n+a\n" ++ display_diff_end ++ "\nmid\n" ++
        display_diff_begin ++ "\n+b\n" ++ display_diff_end ++ "\n";
    var extraction = try extractDisplayBlocks(gpa, tail);
    defer extraction.deinit(gpa);
    try std.testing.expectEqualStrings("mid\n", extraction.remainder);
    try std.testing.expectEqualStrings("+a\n+b", extraction.display.?);
}

test "extractDisplayBlocks passes through text without markers" {
    const gpa = std.testing.allocator;
    var extraction = try extractDisplayBlocks(gpa, "plain output\n");
    defer extraction.deinit(gpa);
    try std.testing.expectEqualStrings("plain output\n", extraction.remainder);
    try std.testing.expect(extraction.display == null);
}

test "extractDisplayBlocks leaves an unterminated block in place" {
    const gpa = std.testing.allocator;
    const tail = "before\n" ++ display_diff_begin ++ "\n+clipped\n";
    var extraction = try extractDisplayBlocks(gpa, tail);
    defer extraction.deinit(gpa);
    try std.testing.expectEqualStrings(tail, extraction.remainder);
    try std.testing.expect(extraction.display == null);
}

test "extractDisplayBlocks drops a dangling end marker line" {
    const gpa = std.testing.allocator;
    const tail = "+half a diff clipped by the rolling tail\n" ++ display_diff_end ++ "\nafter\n";
    var extraction = try extractDisplayBlocks(gpa, tail);
    defer extraction.deinit(gpa);
    try std.testing.expectEqualStrings("+half a diff clipped by the rolling tail\nafter\n", extraction.remainder);
    try std.testing.expect(extraction.display == null);
}

test "prependCdGuard anchors on the project root and defines the guard" {
    const gpa = std.testing.allocator;
    const guarded = try prependCdGuard(gpa, "C:\\Users\\u\\repo", "Write-Output hi");
    defer gpa.free(guarded);

    try std.testing.expect(std.mem.startsWith(u8, guarded, "$_nova_root = [System.IO.Path]::GetFullPath('C:\\Users\\u\\repo');\n"));
    try std.testing.expect(std.mem.indexOf(u8, guarded, "function Set-Location") != null);
    try std.testing.expect(std.mem.indexOf(u8, guarded, "function Push-Location") != null);
    try std.testing.expect(std.mem.endsWith(u8, guarded, "Write-Output hi"));
}

test "prependCdGuard doubles single quotes in the root path" {
    const gpa = std.testing.allocator;
    const guarded = try prependCdGuard(gpa, "C:\\Repo O'Brien", "true");
    defer gpa.free(guarded);

    try std.testing.expect(std.mem.indexOf(u8, guarded, "$_nova_root = [System.IO.Path]::GetFullPath('C:\\Repo O''Brien');") != null);
}

test "prependCdGuard canonicalizes forward slashes in project root" {
    const gpa = std.testing.allocator;
    const guarded = try prependCdGuard(gpa, "C:/Users/u/repo", "Write-Output hi");
    defer gpa.free(guarded);

    try std.testing.expect(std.mem.indexOf(u8, guarded, "$_nova_root = [System.IO.Path]::GetFullPath('") != null);
}

test "validateCwd handles case-folding, slash differences, and rejects prefix collisions" {
    // Exercises Windows path-containment semantics (drive-letter roots, mixed
    // slashes, prefix-collision rejection) that `std.fs.path.resolve` only
    // honours on Windows — on POSIX it joins the Windows paths as relative
    // components, so the assertions below can't hold. Like every other pwsh
    // runtime/containment test in this file, run it only on Windows.
    if (!os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    try std.testing.expect(validateCwd(gpa, io, "C:\\repo", "C:/repo/sub"));
    try std.testing.expect(validateCwd(gpa, io, "C:/repo", "sub"));
    try std.testing.expect(!validateCwd(gpa, io, "C:\\repo", "C:\\repo-other"));
    try std.testing.expect(!validateCwd(gpa, io, "C:\\repo", "C:\\other"));
}

test "contained pwsh refuses Set-Location to a directory outside the workspace root" {
    if (!os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const test_cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(test_cwd);
    const root_abs = try std.fs.path.join(gpa, &.{ test_cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(root_abs);

    var output = try runContained(gpa, std.testing.io, root_abs, "{\"command\":\"Set-Location C:\\\\Windows; Write-Output escaped\",\"description\":\"escape\"}", null);
    defer output.deinit(gpa);

    try std.testing.expect(output.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "escapes the workspace root") != null);
}

test "contained pwsh allows Set-Location within the workspace root" {
    if (!os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const test_cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(test_cwd);
    const root_abs = try std.fs.path.join(gpa, &.{ test_cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(root_abs);
    // A workspace-relative subdir inside the root is allowed.
    var output = try runContained(gpa, std.testing.io, root_abs, "{\"command\":\"Set-Location .; Write-Output ok\",\"description\":\"read\"}", null);
    defer output.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), output.code);
}

test "pwsh observation echoes the invoked command" {
    if (!os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);

    var output = try runToolForTest(gpa, std.testing.io, cwd, "{\"command\":\"Write-Output hello\",\"description\":\"Print hello\"}");
    defer output.deinit(gpa);
    const observation = try testObservationText(gpa, output);
    defer gpa.free(observation);

    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expect(std.mem.indexOf(u8, observation, "> Write-Output hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "hello") != null);
}

test "pwsh timeout observation echoes the command and retry guidance" {
    if (!os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);

    var output = try runToolForTest(gpa, std.testing.io, cwd, "{\"command\":\"Start-Sleep -Seconds 5\",\"timeout\":1}");
    defer output.deinit(gpa);
    const observation = try testObservationText(gpa, output);
    defer gpa.free(observation);

    try std.testing.expect(std.mem.indexOf(u8, observation, "timed out after 1 seconds") != null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "run_in_background") != null);
}

test "pwsh tool reports exit code in observation" {
    if (!os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);

    var output = try runToolForTest(gpa, std.testing.io, cwd, "{\"command\":\"Write-Output nope; exit 7\",\"description\":\"read\"}");
    defer output.deinit(gpa);
    const observation = try testObservationText(gpa, output);
    defer gpa.free(observation);

    try std.testing.expectEqual(@as(u8, 7), output.code);
    try std.testing.expect(std.mem.indexOf(u8, observation, "nope") != null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "Command exited with code 7") != null);
}

test "pwsh tool applies env object" {
    if (!os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);

    var output = try runToolForTest(gpa, std.testing.io, cwd, "{\"command\":\"Write-Output $env:PWSH_TOOL_TEST\",\"description\":\"read\",\"env\":{\"PWSH_TOOL_TEST\":\"hello-env\"}}");
    defer output.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "hello-env") != null);
}

fn testObservationText(gpa: std.mem.Allocator, output: common.Output) ![]u8 {
    const observation = output.observation orelse return error.MissingObservation;
    return observation.render(gpa);
}

test "pwsh observation strips ANSI codes" {
    if (!os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);

    // Override the spawn-time PlainText back to Ansi, then emit a colored error,
    // so we are exercising the downstream strip, not the upstream PSStyle fix.
    var output = try runToolForTest(gpa, std.testing.io, cwd, "{\"command\":\"$PSStyle.OutputRendering='Ansi'; Write-Error \\\"boom\\\"\",\"description\":\"err\"}");
    defer output.deinit(gpa);
    const observation = try testObservationText(gpa, output);
    defer gpa.free(observation);

    // Whatever the capture actually contains, the final observation the model
    // sees must be ANSI-free while still carrying the payload.
    try std.testing.expect(std.mem.indexOfScalar(u8, observation, 0x1b) == null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "boom") != null);
}

test "pwsh tool accepts null for optional fields under strict schema" {
    if (!os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);

    var output = try runToolForTest(gpa, std.testing.io, cwd,
        \\{"command":"Write-Output ok","description":null,"cwd":null,"env":null,"timeout":null,"run_in_background":null}
    );
    defer output.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "ok") != null);
}
