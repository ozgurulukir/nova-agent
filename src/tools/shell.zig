//! Shared implementation for the twin shell tools (`bash.zig`, `pwsh.zig`).
//!
//! The two tool modules carried byte-identical copies of the whole tool-side
//! pipeline — argument parsing/validation, cwd resolution, env overlay, the
//! capture→observation shaping, display-block extraction, the background
//! launch, and the TUI display label. That pipeline lives here, generic over
//! a `Backend` namespace (`Impl(comptime B)`); only the shells' real
//! differences stay in the per-shell modules, expressed as Backend decls:
//!
//! - `name: []const u8` — the model-facing tool name ("bash"/"pwsh"); also
//!   the error-message prefix (`"<name>: ..."`).
//! - `description: []const u8` — the `@embedFile`'d prompt markdown.
//! - `prompt_prefix: []const u8` — the observation echo prefix ("$ " / "> ").
//! - `exec: type` — the exec module (`bash_exec`/`pwsh_exec`) providing
//!   `capture`, `shellPath`, `loginEnvBlock`, `timeoutFromSeconds`,
//!   `timeout_seconds_default`, and `timeout_seconds_max`.
//! - `command_mode: background.BackgroundManager.CommandMode` with
//!   `stderr_merge_prefix` / `stderr_merge_suffix` — the background spawn
//!   shape (`bash -c` with an `exec 2>&1` prefix vs pwsh `-File` with a
//!   trailing `$?` exit check).
//! - `prependCdGuard(gpa, project_root, command) ![]u8` — the per-shell
//!   containment-guard script (bash `cd`/`pushd`/`popd` overrides vs
//!   PowerShell `Set-Location`/`Push-Location`/`Pop-Location`).
//! - `validateCwd(gpa, io, project_root, resolved_cwd) bool` — the per-shell
//!   cwd-containment semantics (lexical prefix + best-effort realpath for
//!   bash; slash/case-tolerant `pathsEqual` for pwsh). SEMANTIC divergence —
//!   do not fold into this module.
//!
//! The contract is validated at comptime (`validateBackend`), so a missing or
//! mistyped decl fails the build with a targeted message instead of a deep
//! error inside a generic body. No runtime dispatch, no vtables: each tool
//! module instantiates `Impl` with its own `Backend` and re-exports the pub
//! surface (`tool`, `runTool`, `runContained`, ...) with unchanged signatures.
//!
//! This module imports neither backend: shared capture types come from
//! `capture_sink.zig`, mirroring the exec-layer split.

const std = @import("std");
const background = @import("../background.zig");
const capture_sink = @import("capture_sink.zig");
const common = @import("common.zig");
const platform = @import("platform");

/// Compile-time Backend contract (see the module doc for the per-decl story).
fn validateBackend(comptime B: type) void {
    inline for (.{ "name", "description", "prompt_prefix", "stderr_merge_prefix", "stderr_merge_suffix" }) |decl| {
        if (!@hasDecl(B, decl) or @TypeOf(@field(B, decl)) != []const u8) {
            @compileError("shell.Impl backend must declare `" ++ decl ++ ": []const u8`");
        }
    }
    if (!@hasDecl(B, "exec") or @TypeOf(B.exec) != type) {
        @compileError("shell.Impl backend must declare `exec: type` (the bash_exec/pwsh_exec module)");
    }
    inline for (.{ "capture", "timeoutFromSeconds", "timeout_seconds_default", "timeout_seconds_max", "shellPath", "loginEnvBlock" }) |decl| {
        if (!@hasDecl(B.exec, decl)) {
            @compileError("shell.Impl backend `exec` module must declare `" ++ decl ++ "` (see bash_exec.zig)");
        }
    }
    if (!@hasDecl(B, "command_mode") or @TypeOf(B.command_mode) != background.BackgroundManager.CommandMode) {
        @compileError("shell.Impl backend must declare `command_mode: background.BackgroundManager.CommandMode`");
    }
    inline for (.{ "prependCdGuard", "validateCwd" }) |decl| {
        if (!@hasDecl(B, decl)) {
            @compileError("shell.Impl backend must declare `" ++ decl ++ "` (the containment hook)");
        }
    }
}

pub fn Impl(comptime B: type) type {
    comptime validateBackend(B);
    return struct {
        pub const tool: common.Tool = .{
            .name = B.name,
            .description = B.description,
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
        /// whose shell call requests `run_in_background`. Mirrors the executor's
        /// `BackgroundStart`; null means background is unavailable for this call.
        pub const BackgroundCtx = struct {
            manager: *background.BackgroundManager,
            owner_generation: u64 = 1,
        };

        /// Per-call execution options for the internal run path.
        const RunOpts = struct {
            /// When set, prepend the backend's containment guard so the shell
            /// cannot leave `cwd` (the lane worktree). The guard anchors on the
            /// PROJECT root (the `cwd` param), not the resolved cwd, so a `cwd`
            /// subdir argument doesn't tighten containment to that subdir.
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

        /// Root-contained shell run for lane workers (see `Agent.contained`).
        /// Parses the call like `runTool`, then prepends the backend's
        /// containment guard so the command cannot leave `cwd` into the main
        /// tree. Background launches (when `background` is non-null and the call
        /// asks for one) are guarded too.
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

            if (!B.validateCwd(gpa, io, cwd, resolved_cwd)) {
                return common.failFmt(gpa, 1, B.name ++ ": cwd '{s}' escapes the project root\n", .{resolved_cwd});
            }

            var env_map = try currentEnvMap(gpa, io);
            defer env_map.deinit();
            if (args.env) |env| try applyEnv(&env_map, env);

            // A contained run replaces the model's command with the guard-prefixed
            // form; the guard definition is silent, so the observation still reads
            // as the original command (`finishOutput` echoes `command`, not the
            // guard).
            var owned_command: ?[]u8 = null;
            defer if (owned_command) |p| gpa.free(p);
            const command = if (opts.contained) blk: {
                owned_command = B.prependCdGuard(gpa, cwd, args.command) catch return error.OutOfMemory;
                break :blk owned_command.?;
            } else args.command;

            if (opts.background) |bg| {
                if (wantsBackground(gpa, arguments)) {
                    return runBackgroundImpl(gpa, io, resolved_cwd, command, bg.manager, bg.owner_generation, &env_map);
                }
            }

            return runCaptured(gpa, io, resolved_cwd, command, &env_map, args.timeout_seconds);
        }

        /// Run `command` under the backend's shell with the tool's standard
        /// capture limits and shape the result into a tool `Output`
        /// (merged-output observation, exit-code framing, spill-to-disk on
        /// overflow). `cwd` must already be resolved to an absolute path.
        pub fn runCaptured(
            gpa: std.mem.Allocator,
            io: std.Io,
            cwd: []const u8,
            command: []const u8,
            env_map: *const std.process.Environ.Map,
            timeout_seconds: u32,
        ) common.Error!common.Output {
            var captured = B.exec.capture(gpa, io, .{
                .cwd = cwd,
                .command = command,
                .env_map = env_map,
                .timeout = B.exec.timeoutFromSeconds(timeout_seconds),
                .limits = capture_limits,
            }) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                if (err == error.Canceled) return error.Canceled;
                return common.failFmt(gpa, 1, B.name ++ ": command failed to run: {s}\n", .{describeError(err)});
            };
            defer captured.deinit(gpa);

            const status: FinishStatus = if (captured.timed_out) .{ .timeout_seconds = timeout_seconds } else .{};
            return finishOutput(gpa, &captured, status, command);
        }

        /// Whether the arguments request a background launch. Cheap parse used by
        /// the executor to decide whether to route the call to the
        /// `BackgroundManager` before falling back to a normal blocking run.
        /// False on any parse failure.
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
            owner_generation: u64,
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

            if (!B.validateCwd(gpa, io, cwd, resolved_cwd)) {
                return common.failFmt(gpa, 1, B.name ++ ": cwd '{s}' escapes the project root\n", .{resolved_cwd});
            }

            var env_map = try currentEnvMap(gpa, io);
            defer env_map.deinit();
            if (args.env) |env| try applyEnv(&env_map, env);

            return runBackgroundImpl(gpa, io, resolved_cwd, args.command, manager, owner_generation, &env_map);
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
            owner_generation: u64,
            env_map: *const std.process.Environ.Map,
        ) common.Error!common.Output {
            var started = manager.start(.{
                .command = command,
                .cwd = cwd,
                .env_map = env_map,
                .owner_generation = owner_generation,
                .shell_path = B.exec.shellPath(io),
                .command_mode = B.command_mode,
                .stderr_merge_prefix = B.stderr_merge_prefix,
                .stderr_merge_suffix = B.stderr_merge_suffix,
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

        fn mapBackgroundError(gpa: std.mem.Allocator, err: anyerror) common.Error!common.Output {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Canceled => error.Canceled,
                else => common.failFmt(gpa, 1, B.name ++ ": failed to launch background command: {s}\n", .{@errorName(err)}),
            };
        }

        const Args = struct {
            command: []const u8,
            summary: []const u8,
            cwd: ?[]const u8 = null,
            env: ?std.json.Value = null,
            parsed: std.json.Parsed(JsonArgs),
            timeout_seconds: u32 = B.exec.timeout_seconds_default,

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

            // `description` is the summary field; null/empty → the generic fallback
            // keeps the display honest. (`reason` was removed — the schema is the
            // contract, and unknown fields are ignored like any other.)
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

            // Clamp before the `0` check so a clamped-to-0 input is impossible
            // (max >= 1). The cap keeps a model from passing a ~136-year timeout that
            // effectively disables the deadline; long work belongs in background.
            const timeout_seconds = @min(parsed.value.timeout orelse B.exec.timeout_seconds_default, B.exec.timeout_seconds_max);
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
                error.InvalidJson => common.fail(gpa, B.name ++ ": invalid JSON arguments\n", 2),
                error.MissingCommand => common.fail(gpa, B.name ++ ": missing command\n", 2),
                error.BadCommand => common.fail(gpa, B.name ++ ": command must be a string\n", 2),
                error.BadCwd => common.fail(gpa, B.name ++ ": cwd must be a non-empty string\n", 2),
                error.BadEnv => common.fail(gpa, B.name ++ ": env must be an object\n", 2),
                error.BadEnvKey => common.fail(gpa, B.name ++ ": env keys must be valid environment variable names\n", 2),
                error.BadEnvValue => common.fail(gpa, B.name ++ ": env values must be strings\n", 2),
                error.BadTimeout => common.fail(gpa, B.name ++ ": timeout must be a positive integer number of seconds\n", 2),
            };
        }

        pub fn currentEnvMap(gpa: std.mem.Allocator, io: std.Io) (std.mem.Allocator.Error || std.Io.UnexpectedError)!std.process.Environ.Map {
            var map = try platform.getEnvMap(gpa);
            errdefer map.deinit();

            // Overlay the login shell's environment (PATH etc.) over the inherited
            // process env, so non-login command shells see what a login shell would —
            // captured once, not re-sourced per command. The per-command `env` arg is
            // applied after this and still wins. Null (pwsh always; bash on Windows
            // or capture failure) leaves the process env untouched.
            if (B.exec.loginEnvBlock(io)) |block| {
                var entries = std.mem.splitScalar(u8, block, 0);
                while (entries.next()) |entry| {
                    if (entry.len == 0) continue;
                    const separator = std.mem.findScalar(u8, entry, '=') orelse continue;
                    if (separator == 0) continue;
                    try map.put(entry[0..separator], entry[separator + 1 ..]);
                }
            }
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

        /// Capture thresholds for `B.exec.capture`. The spill-to-disk trigger is
        /// the same budget the observation truncates at, so a spill file exists
        /// exactly when the tail is shown truncated.
        const capture_limits: capture_sink.CaptureLimits = .{
            .bytes_max = observation_bytes_max,
            .lines_max = observation_lines_max,
            .tail_bytes_max = rolling_bytes_max,
            // 10MB ≫ any realistic "read the rest" need; bounds disk growth for a
            // command that emits endless output (the observation only ever shows the
            // last 50KB regardless).
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
        /// observation. `\x1e` (ASCII record separator) makes an accidental collision with
        /// real command output practically impossible. Shared by both shell tools.
        pub const display_diff_begin = "\x1enova:diff";
        pub const display_diff_end = "\x1enova:end";

        /// Turn a `Capture` into the tool's observation: strip ANSI (git-bash and
        /// PowerShell both leak VT codes into the capture), split out any
        /// display-block sentinel content, trim the rolling tail to the display
        /// budget, and — when the output was spilled to disk — surface the spill
        /// path so the model can read the full output. The observation is
        /// prefixed with `<prompt_prefix><command>` so a truncated, timed-out, or
        /// empty result still shows what was invoked.
        fn finishOutput(
            gpa: std.mem.Allocator,
            captured: *const capture_sink.Capture,
            status: FinishStatus,
            command: []const u8,
        ) common.Error!common.Output {
            const stripped = common.stripAnsi(gpa, captured.tail) catch return error.OutOfMemory;
            defer gpa.free(stripped);

            var extraction = extractDisplayBlocks(gpa, stripped) catch return error.OutOfMemory;
            defer extraction.deinit(gpa);

            var snapshot = truncateTailBuffer(gpa, extraction.remainder, captured.total_lines, captured.total_bytes) catch return error.OutOfMemory;
            defer snapshotDeinit(gpa, &snapshot);

            const observation_text = formatText(gpa, snapshot.text, captured.code, status, command) catch return error.OutOfMemory;
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
                // Uphold `common.Display`'s invariant that a `.diff` body is non-empty:
                // a begin/end sentinel pair with nothing between would otherwise hand
                // the model a zero-length diff next to the "(no output)" observation.
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

        /// Split sentinel-delimited display blocks out of a captured tail. Markers
        /// must each sit on their own line. A begin marker with no matching end
        /// (crash mid-print, or the rolling tail clipped the pair apart) is left in
        /// place untouched — plain rendering is the safe failure mode. A begin whose
        /// leading bytes were clipped leaves a dangling end marker; that line alone is
        /// dropped so half a diff never leaks into the observation as gibberish.
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
                    // Unterminated block: keep everything as-is from here on.
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
            /// End of the block's inner text (trailing newline before the end marker excluded).
            text_end: usize,
            /// First byte after the end-marker line.
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

        fn formatText(
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

        /// `<prompt_prefix><command>\n`, the observation prefix that ties a result
        /// back to what was invoked. The display-channel sentinel byte (`\x1e`) is
        /// escaped to the two characters `\x1e` when a command embeds it (the model
        /// routing content to the human display), so the model-facing observation
        /// never carries the raw byte — the display channel is its only legitimate
        /// carrier.
        fn echoCommand(gpa: std.mem.Allocator, command: []const u8) std.mem.Allocator.Error![]u8 {
            if (std.mem.indexOfScalar(u8, command, '\x1e') == null) {
                return std.fmt.allocPrint(gpa, B.prompt_prefix ++ "{s}\n", .{command});
            }
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            try out.appendSlice(gpa, B.prompt_prefix);
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

        /// Shell observation line count: empty text is 0 lines and a trailing
        /// newline does not start a new one. This is deliberately NOT the Lua
        /// `read_file` display counter (`lua/plugin_api.zig::countLines`), which
        /// counts empty text as 1 line without the trailing-newline compensation.
        fn countLines(text: []const u8) u32 {
            if (text.len == 0) return 0;
            var count: u32 = 1;
            for (text) |byte| {
                if (byte == '\n') count += 1;
            }
            if (text[text.len - 1] == '\n') count -= 1;
            return count;
        }

        /// Map a `capture`/spawn failure to a model-readable reason. OOM and Canceled
        /// propagate on the caller's error surface; everything else becomes a tool
        /// output carrying the real cause — a missing shell, a bad cwd, fd exhaustion —
        /// instead of the opaque "Unexpected".
        fn describeError(err: anyerror) []const u8 {
            return switch (err) {
                error.FileNotFound => "command or shell not found (check PATH / the cwd exists)",
                error.AccessDenied, error.PermissionDenied => "permission denied",
                error.NotDir => "cwd is not a directory",
                error.StreamTooLong => "output exceeded the capture limit",
                error.Timeout => "timed out",
                else => @errorName(err),
            };
        }

        /// The display summary is the model-provided `description`; the expanded
        /// title is the executable command, so users can inspect exactly what ran.
        /// When no summary is present the command itself becomes the collapsed title,
        /// so the invoked command is never invisible.
        fn display(gpa: std.mem.Allocator, args: []const u8, userdata: *anyopaque) std.mem.Allocator.Error!common.ToolDisplay {
            _ = userdata;
            const parsed = std.json.parseFromSlice(JsonArgs, gpa, args, .{ .ignore_unknown_fields = true }) catch {
                return .{ .label = try gpa.dupe(u8, B.name) };
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

            const command = parsed.value.command orelse return .{ .label = try gpa.dupe(u8, B.name) };
            if (command.len == 0) return .{ .label = try gpa.dupe(u8, B.name) };
            return .{ .label = try gpa.dupe(u8, command) };
        }
    };
}

// ---------------------------------------------------------------------------
// Pure-helper tests. The per-shell modules keep their spawn/containment/
// validateCwd/prependCdGuard tests; these families were byte-identical twins
// there and now run once against a minimal TestBackend. `exec.capture` is
// never called here (lazy analysis), so the stub only needs to satisfy the
// comptime contract.
// ---------------------------------------------------------------------------

const TestExec = struct {
    pub const timeout_seconds_default: u32 = 30;
    pub const timeout_seconds_max: u32 = 3600;

    pub fn timeoutFromSeconds(seconds: u32) std.Io.Timeout {
        return .{ .duration = .{ .raw = .fromSeconds(seconds), .clock = .awake } };
    }

    pub fn shellPath(_: std.Io) []const u8 {
        return "test-shell";
    }

    pub fn loginEnvBlock(_: std.Io) ?[]const u8 {
        return null;
    }

    pub const Capture = capture_sink.Capture;
    pub const CaptureLimits = capture_sink.CaptureLimits;

    pub fn capture(_: std.mem.Allocator, _: std.Io, options: anytype) !Capture {
        _ = options;
        return error.NotImplemented;
    }
};

const TestBackend = struct {
    pub const name: []const u8 = "test-shell";
    pub const description: []const u8 = "test shell tool";
    pub const prompt_prefix: []const u8 = "% ";
    pub const exec = TestExec;
    pub const command_mode: background.BackgroundManager.CommandMode = .argv_dash_c;
    pub const stderr_merge_prefix: []const u8 = "";
    pub const stderr_merge_suffix: []const u8 = "";

    pub fn prependCdGuard(gpa: std.mem.Allocator, project_root: []const u8, command: []const u8) std.mem.Allocator.Error![]u8 {
        return std.fmt.allocPrint(gpa, "{s}\n{s}", .{ project_root, command });
    }

    pub fn validateCwd(_: std.mem.Allocator, _: std.Io, _: []const u8, _: []const u8) bool {
        return true;
    }
};

const impl = Impl(TestBackend);

test "shell display ignores a legacy reason field" {
    // `reason` was removed from the contract; a model that still sends it gets
    // the command-as-title fallback, not a bogus summary.
    const gpa = std.testing.allocator;
    var label = try impl.display(gpa, "{\"command\":\"pwd\",\"reason\":\"Inspect the current directory\"}", undefined);
    defer label.deinit(gpa);
    try std.testing.expectEqualStrings("pwd", label.label);
    try std.testing.expect(label.expanded_label == null);
}

test "shell display falls back on partial JSON" {
    const gpa = std.testing.allocator;
    var label = try impl.display(gpa, "{\"command", undefined);
    defer label.deinit(gpa);
    try std.testing.expectEqualStrings(TestBackend.name, label.label);
    try std.testing.expect(label.expanded_label == null);
}

test "shell display uses description with command as expanded label" {
    // The canonical field: what current models emit for the summary.
    const gpa = std.testing.allocator;
    var label = try impl.display(gpa, "{\"command\":\"pwd\",\"description\":\"Inspect the current directory\"}", undefined);
    defer label.deinit(gpa);
    try std.testing.expectEqualStrings("Inspect the current directory", label.label);
    try std.testing.expectEqualStrings("pwd", label.expanded_label.?);
}

test "shell display falls back to the command when no summary is present" {
    // A model that omits the description must not produce a bare tool-name row —
    // the invoked command becomes the title.
    const gpa = std.testing.allocator;
    var label = try impl.display(gpa, "{\"command\":\"git status\"}", undefined);
    defer label.deinit(gpa);
    try std.testing.expectEqualStrings("git status", label.label);
    try std.testing.expect(label.expanded_label == null);
}

test "shell tool parses timeout" {
    var args = try impl.parseArgs(std.testing.allocator, "{\"command\":\"printf ok\",\"description\":\"read\",\"timeout\":42}");
    defer args.deinit();

    try std.testing.expectEqual(@as(u32, 42), args.timeout_seconds);
}

test "shell tool ignores a legacy reason field" {
    var args = try impl.parseArgs(std.testing.allocator, "{\"command\":\"printf ok\",\"reason\":\"Print ok\"}");
    defer args.deinit();

    try std.testing.expectEqualStrings("Executing command.", args.summary);
}

test "shell tool accepts description as the canonical summary" {
    var args = try impl.parseArgs(std.testing.allocator, "{\"command\":\"printf ok\",\"description\":\"Print ok\"}");
    defer args.deinit();

    try std.testing.expectEqualStrings("Print ok", args.summary);
}

test "parseArgs clamps timeout to the max" {
    var args = try impl.parseArgs(std.testing.allocator, "{\"command\":\"true\",\"timeout\":999999}");
    defer args.deinit();
    try std.testing.expectEqual(TestExec.timeout_seconds_max, args.timeout_seconds);
    try std.testing.expectError(error.BadTimeout, impl.parseArgs(std.testing.allocator, "{\"command\":\"true\",\"timeout\":0}"));
}

test "describeError names common failures" {
    try std.testing.expect(std.mem.indexOf(u8, impl.describeError(error.FileNotFound), "not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, impl.describeError(error.NotDir), "not a directory") != null);
    try std.testing.expect(std.mem.eql(u8, "BadPipe", impl.describeError(error.BadPipe)));
}

test "extractDisplayBlocks routes sentinel content to the display channel" {
    const gpa = std.testing.allocator;
    const tail = "before\n" ++ impl.display_diff_begin ++ "\n-old\n+new\n" ++ impl.display_diff_end ++ "\nafter\n";
    var extraction = try impl.extractDisplayBlocks(gpa, tail);
    defer extraction.deinit(gpa);
    try std.testing.expectEqualStrings("before\nafter\n", extraction.remainder);
    try std.testing.expectEqualStrings("-old\n+new", extraction.display.?);
}

test "extractDisplayBlocks concatenates multiple blocks" {
    const gpa = std.testing.allocator;
    const tail = impl.display_diff_begin ++ "\n+a\n" ++ impl.display_diff_end ++ "\nmid\n" ++
        impl.display_diff_begin ++ "\n+b\n" ++ impl.display_diff_end ++ "\n";
    var extraction = try impl.extractDisplayBlocks(gpa, tail);
    defer extraction.deinit(gpa);
    try std.testing.expectEqualStrings("mid\n", extraction.remainder);
    try std.testing.expectEqualStrings("+a\n+b", extraction.display.?);
}

test "extractDisplayBlocks passes through text without markers" {
    const gpa = std.testing.allocator;
    var extraction = try impl.extractDisplayBlocks(gpa, "plain output\n");
    defer extraction.deinit(gpa);
    try std.testing.expectEqualStrings("plain output\n", extraction.remainder);
    try std.testing.expect(extraction.display == null);
}

test "extractDisplayBlocks leaves an unterminated block in place" {
    const gpa = std.testing.allocator;
    const tail = "before\n" ++ impl.display_diff_begin ++ "\n+clipped\n";
    var extraction = try impl.extractDisplayBlocks(gpa, tail);
    defer extraction.deinit(gpa);
    try std.testing.expectEqualStrings(tail, extraction.remainder);
    try std.testing.expect(extraction.display == null);
}

test "extractDisplayBlocks drops a dangling end marker line" {
    const gpa = std.testing.allocator;
    const tail = "+half a diff clipped by the rolling tail\n" ++ impl.display_diff_end ++ "\nafter\n";
    var extraction = try impl.extractDisplayBlocks(gpa, tail);
    defer extraction.deinit(gpa);
    try std.testing.expectEqualStrings("+half a diff clipped by the rolling tail\nafter\n", extraction.remainder);
    try std.testing.expect(extraction.display == null);
}
