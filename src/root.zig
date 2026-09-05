const std = @import("std");
const builtin = @import("builtin");
const logger = @import("logger");
const log = std.log.scoped(.root);

pub const agent = @import("agent.zig");
pub const ai = @import("ai.zig");
pub const at_mention = @import("at_mention.zig");
pub const auth = @import("auth/store.zig");
pub const background = @import("background.zig");
pub const bash = @import("tools/bash_exec.zig");
pub const bash_safety = @import("tools/bash_safety.zig");
pub const clipboard = @import("clipboard.zig");
pub const codex = @import("auth/codex.zig");
pub const compaction = @import("context/compaction.zig");
pub const config = @import("config/config.zig");
pub const context = @import("context/manager.zig");
pub const context_assembly = @import("context/assembly.zig");
pub const db = @import("db.zig");
pub const executor = @import("executor.zig");
pub const os = @import("os.zig");
pub const paths = @import("paths.zig");
pub const search = @import("search.zig");
pub const session = @import("session.zig");
pub const skill = @import("skill.zig");
pub const symbols = @import("symbols.zig");
pub const terminal_markdown = @import("terminal_markdown");
pub const mcp = @import("mcp/manager.zig");
pub const mcp_client = @import("mcp/client.zig");
pub const mcp_transport = @import("mcp/transport.zig");
pub const runtime = @import("runtime.zig");
pub const parts = @import("tools/parts.zig");
pub const vcs = @import("vcs.zig");
pub const transcript = @import("transcript.zig");
pub const tools = @import("tools.zig");
pub const lua = @import("lua/root.zig");
pub const lua_test_runner = @import("lua/test_runner.zig");
pub const tui = @import("tui.zig");
pub const thread = @import("tui/thread.zig");
pub const toast = @import("tui/toast.zig");

/// Build-time version, embedded from the git tag via `-Dversion` in build.zig
/// (fallback: `git describe` / `dev`). Convenience alias for the `--version`
/// handler; the settings panel reads `@import("build").version` directly. Both
/// resolve to the same single build option, so they can never diverge.
pub const build_version = @import("build").version;

/// Logger → toast-bus adapter. Installed as the logger's `toast_sink` so warn+
/// messages surface as TUI toasts instead of tearing the frame on stderr. The
/// bus's `initialized` guard makes this a no-op before `tui.run` inits it.
fn toastSink(level: std.log.Level, msg: []const u8) void {
    const toast_level: toast.Level = switch (level) {
        .err => .err,
        .warn => .warn,
        else => .info,
    };
    toast.global.push(toast_level, msg);
}

pub fn run(init: std.process.Init, gpa: std.mem.Allocator) !void {
    if (try handleVersionFlag(init, gpa)) return;
    os.initConsoleUtf8();
    @import("tools/bash_exec.zig").disablePseudoConsole();

    if (resolveLogPath(gpa, init.environ_map)) |log_path| {
        defer gpa.free(log_path);
        const stderr_level = resolveStderrLevel(init.environ_map);
        logger.init(.{
            .io = init.io,
            .log_path = log_path,
            .stderr_level = stderr_level orelse switch (builtin.mode) {
                .Debug => .err,
                else => .warn,
            },
            .stderr_explicit = stderr_level != null,
            .toast_sink = toastSink,
            .max_bytes = resolveMaxBytes(init.environ_map),
        }) catch {};
    } else |_| {}
    defer logger.deinit();

    const cwd = try std.process.currentPathAlloc(init.io, gpa);
    defer gpa.free(cwd);

    const home_dir = try resolveHome(gpa, init.environ_map) orelse {
        // No usable home (none set, or set to a relative path): the global
        // tree (config, sessions DB, worktrees, logs) has nowhere safe to go.
        // Fail with an actionable message instead of letting a stray
        // `AppData/` (or `.config/`) sprout in the launch directory.
        return error.HomeNotSet;
    };
    defer gpa.free(home_dir);

    var load_result = try config.load(gpa, init.io, cwd, home_dir, init.environ_map);

    // The TUI is long-running and streams unbounded content. `SmpAllocator`
    // (Zig 0.16) has a known multi-threaded free-list corruption bug that
    // panics with "incorrect alignment"; `PageAllocator` is the safe fallback:
    // thread-safe, actually frees memory, but each allocation maps a whole page.
    const tui_gpa = gpa;
    const tui_config = try load_result.config.cloneForTui(tui_gpa);
    const runtime_gpa = gpa;

    defer search.deinit(runtime_gpa, init.io);

    const system_prompt = if (load_result.config.model_selection) |ms|
        (ms.systemPrompt() orelse defaultSystemPrompt())
    else
        defaultSystemPrompt();
    const agent_runtime = try tui_gpa.create(runtime.AgentRuntime);
    errdefer tui_gpa.destroy(agent_runtime);

    // Auth integrity: prune orphan keys that no longer correspond to any
    // known provider. Builtin labels are always valid; config provider
    // names and the current dynamic_provider_id are collected as the
    // valid set. Idempotent — running again after a prune removes nothing.
    {
        var valid_names: std.ArrayList([]const u8) = .empty;
        defer valid_names.deinit(runtime_gpa);
        for (config.allBuiltinLabels()) |label| {
            valid_names.append(runtime_gpa, label) catch continue;
        }
        for (load_result.config.providers) |p| {
            valid_names.append(runtime_gpa, p.name) catch continue;
        }
        if (load_result.config.dynamic_provider_id) |id| {
            valid_names.append(runtime_gpa, id) catch {};
        }
        const pruned = auth.pruneOrphanKeys(runtime_gpa, init.io, home_dir, valid_names.items) catch 0;
        if (pruned > 0) {
            log.warn("auth.integrity.pruned count={d}", .{pruned});
        }
    }

    // Temp hygiene: drop stale spill (`nova-bash-*`) and background-log
    // (`nova-bg_*`) files older than the retention window. Startup is the one
    // moment no session can be mid-read of a previous process's output.
    bash.pruneStaleTempFiles(init.io, gpa, bash.temp_retention_ns);

    // Worktree hygiene: drop orphaned worktree checkouts (> 7 days) and
    // sync git metadata in the current workspace.
    vcs.gcOrphanedWorktrees(gpa, init.io, home_dir, vcs.worktree_retention_ns);
    if (vcs.isRepo(gpa, init.io, cwd)) {
        vcs.worktreePrune(gpa, init.io, cwd) catch {};
    }

    // Auto-resume: find the most recently updated session for this cwd.
    const resume_session_id = blk: {
        var manager = session.SessionManager.initDefault(runtime_gpa, init.io, home_dir) catch break :blk null;
        defer manager.deinit();
        const id = manager.findLatest(runtime_gpa, cwd) catch null;
        break :blk id;
    };
    if (resume_session_id) |id| {
        defer runtime_gpa.free(id);
        agent_runtime.initResume(
            runtime_gpa,
            init.io,
            cwd,
            cwd,
            home_dir,
            system_prompt,
            load_result.config,
            load_result.takeDiagnostics(),
            id,
            null,
        ) catch |err| {
            log.warn("session.resume.failed err={s}, starting new session", .{@errorName(err)});
            try agent_runtime.initNew(
                runtime_gpa,
                init.io,
                cwd,
                cwd,
                home_dir,
                system_prompt,
                load_result.config,
                load_result.takeDiagnostics(),
                null,
            );
        };
    } else {
        try agent_runtime.initNew(
            runtime_gpa,
            init.io,
            cwd,
            cwd,
            home_dir,
            system_prompt,
            load_result.config,
            load_result.takeDiagnostics(),
            null,
        );
    }
    load_result.config.deinit(gpa);

    try tui.run(init, agent_runtime, tui_config, tui_gpa);
}

fn resolveLogPath(gpa: std.mem.Allocator, env: anytype) ![]u8 {
    if (env.get("NOVA_LOG_FILE")) |path| return gpa.dupe(u8, path);
    const home = try resolveHome(gpa, env) orelse return error.HomeNotSet;
    // Platform-correct base: Windows -> %APPDATA%\nova, POSIX -> ~/.config/nova.
    const base = try paths.platformConfigDir(gpa, home);
    errdefer gpa.free(base);
    const log_path = try std.fs.path.join(gpa, &.{ base, "nova.log" });
    gpa.free(base);
    return log_path;
}

/// G1a: parse `NOVA_LOG_STDERR_LEVEL` (err|warn|info|debug). Defaults to
/// `warn` in release, `err` in debug — stderr is the TUI-adjacent stream, so
/// G1a: parse `NOVA_LOG_STDERR_LEVEL` (err|warn|info|debug). Returns null when
/// the env var is absent — the caller distinguishes "explicitly set" (which
/// restores full stderr output even when a toast sink is installed) from the
/// default. The default level is `warn` in release, `err` in debug — stderr is
/// the TUI-adjacent stream, so `warn` is the highest default that won't
/// routinely tear a frame.
fn resolveStderrLevel(env: anytype) ?std.log.Level {
    if (env.get("NOVA_LOG_STDERR_LEVEL")) |raw| {
        const LevelMap = struct { name: []const u8, level: std.log.Level };
        const map = [_]LevelMap{
            .{ .name = "debug", .level = .debug },
            .{ .name = "info", .level = .info },
            .{ .name = "warn", .level = .warn },
            .{ .name = "err", .level = .err },
        };
        for (map) |m| {
            if (std.ascii.eqlIgnoreCase(raw, m.name)) return m.level;
        }
    }
    return null;
}

/// P2: parse `NOVA_LOG_MAX_BYTES` (decimal). Defaults to the logger's built-in
/// cap (`logger.default_max_bytes`) so the env fallback and the API default can
/// never diverge. Bad input falls back to the default rather than disabling
/// rotation silently.
fn resolveMaxBytes(env: anytype) u64 {
    if (env.get("NOVA_LOG_MAX_BYTES")) |raw| {
        if (std.fmt.parseInt(u64, raw, 10)) |n| {
            if (n > 0) return n;
        } else |_| {}
    }
    return logger.default_max_bytes;
}

/// Resolve the home directory that anchors Nova's global tree (config,
/// sessions DB, worktrees, logs). Returns null when no usable home exists —
/// `run` then fails fast with `error.HomeNotSet` instead of letting a bogus
/// home plant the global tree inside the user's project.
///
/// Env precedence is platform-correct:
///   - Windows: USERPROFILE first (the canonical home; %APPDATA% is derived
///     from it). HOME is a foreign variable — it only appears in git-bash /
///     MSYS2 / CI-style environments, and an override pointing at the project
///     root used to plant `AppData/Roaming/nova/` inside the user's repo.
///   - POSIX: HOME first, as is conventional.
/// A set-but-relative value is rejected: it would resolve against the launch
/// directory and anchor the global tree inside the user's project.
fn resolveHome(
    gpa: std.mem.Allocator,
    env: anytype,
) std.mem.Allocator.Error!?[]u8 {
    const primary: ?[]const u8 = if (os.is_windows)
        env.get("USERPROFILE")
    else
        env.get("HOME");
    const candidate: ?[]const u8 = if (primary != null)
        primary
    else
        (if (os.is_windows) env.get("HOME") else env.get("USERPROFILE"));
    if (candidate) |home| {
        if (std.fs.path.isAbsolute(home)) {
            const dup = try gpa.dupe(u8, home);
            return dup;
        }
    }
    return null;
}

test "resolveHome: platform-canonical var wins, relative rejected" {
    const gpa = std.testing.allocator;
    // resolveHome is platform-branched at compile time (os.is_windows), so
    // only the active host's branch runs; both are still type-checked.
    if (os.is_windows) {
        // USERPROFILE (canonical) beats a foreign, project-root HOME override —
        // the exact scenario that planted AppData/Roaming/nova in a repo.
        var map = std.process.Environ.Map.init(gpa);
        defer map.deinit();
        try map.put("USERPROFILE", "C:/Users/tester");
        try map.put("HOME", "C:/Github/nova-agent");
        const home = try resolveHome(gpa, map);
        defer if (home) |h| gpa.free(h);
        try std.testing.expect(home != null);
        try std.testing.expect(paths.pathsEqual(home.?, "C:/Users/tester"));

        // A set-but-relative USERPROFILE is rejected fail-closed, even when
        // HOME looks valid: a broken canonical var must not be silently
        // second-guessed.
        var map2 = std.process.Environ.Map.init(gpa);
        defer map2.deinit();
        try map2.put("USERPROFILE", "relative/path");
        try map2.put("HOME", "C:/Users/tester");
        try std.testing.expect(try resolveHome(gpa, map2) == null);
    } else {
        // HOME is canonical on POSIX.
        var map = std.process.Environ.Map.init(gpa);
        defer map.deinit();
        try map.put("HOME", "/home/tester");
        const home = try resolveHome(gpa, map);
        defer if (home) |h| gpa.free(h);
        try std.testing.expect(home != null);
        try std.testing.expect(paths.pathsEqual(home.?, "/home/tester"));

        // A set-but-relative HOME is rejected fail-closed.
        var map2 = std.process.Environ.Map.init(gpa);
        defer map2.deinit();
        try map2.put("HOME", "relative/path");
        try map2.put("USERPROFILE", "/home/tester");
        try std.testing.expect(try resolveHome(gpa, map2) == null);
    }

    // Neither variable set: no home at all.
    var empty = std.process.Environ.Map.init(gpa);
    defer empty.deinit();
    try std.testing.expect(try resolveHome(gpa, empty) == null);
}

/// The default system prompt, composed at comptime from the shared
/// system-common.md template and the platform shell fragment (system-pwsh.md
/// on Windows, system-bash.md elsewhere).
pub fn defaultSystemPrompt() []const u8 {
    return comptime @embedFile("prompts/system-common.md") ++ "\n\n" ++
        (if (os.is_windows)
            @embedFile("prompts/system-pwsh.md")
        else
            @embedFile("prompts/system-bash.md"));
}

/// Handle `nova --version`. Returns true when the flag was present and the
/// version was printed (the caller returns immediately). Iterates args via the
/// cross-platform `iterateAllocator` wrapper on `Args` (WTF-8 on Windows,
/// UTF-8 elsewhere). `--version` is matched on ANY arg, so `nova some-cmd
/// --version` also prints the version — a deliberate deviation from
/// first-arg-only conventions (see plan note).
fn handleVersionFlag(init: std.process.Init, gpa: std.mem.Allocator) !bool {
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            var buf: [256]u8 = undefined;
            var writer = std.Io.File.stdout().writer(init.io, &buf);
            defer writer.interface.flush() catch {};
            try writer.interface.print("nova {s}\n", .{build_version});
            return true;
        }
    }
    return false;
}

test {
    _ = @import("tui/widgets/plugins_status.zig");
    std.testing.refAllDecls(@This());
    // The TUI tests moved out of `tui.zig` into `src/tui/tests.zig`; reference
    // the file here so its test blocks are compiled into the test run (a file
    // only referenced lazily — e.g. `pub const tests` on `tui.zig` — is never
    // analyzed, and its tests silently never run).
    _ = @import("tui/tests.zig");
    _ = @import("tui/bounded_list.zig");
    _ = @import("tui/style.zig");
    _ = @import("tui/widgets/status_bar.zig");
    _ = @import("tui/widgets/message.zig");
    _ = @import("tui/widgets/transcript.zig");
    // The telemetry engine (token velocity EMA + context meter) is a new
    // module; reference it here so its inline tests compile into the run
    // (AGENTS.md test-runner quirk: a file only referenced lazily is never
    // analyzed and its tests silently never run).
    _ = @import("tui/telemetry.zig");
    _ = @import("lua/root.zig");
    _ = @import("lua/state.zig");
    _ = @import("lua/bridge.zig");
    _ = @import("lua/sandbox.zig");
    _ = @import("lua/plugin.zig");
    _ = @import("lua/manifest.zig");
    _ = @import("lua/manager.zig");
    _ = @import("lua/events.zig");
    // The text-tool-call recovery module (T1). Pure module, only consumed by
    // the agent at call sites — reference it explicitly so its exhaustive
    // unit tests run (silent-drop guard per AGENTS.md §Test runner quirks).
    _ = @import("ai/text_tool_call.zig");
    _ = @import("ai/model_compat.zig");
    _ = @import("ai/openai_request.zig");
    _ = @import("ai/responses_request.zig");
    _ = @import("ai/responses_events.zig");
    _ = @import("ai/stream_part.zig");
    _ = @import("tools/executor_safety.zig");
    _ = @import("tools/executor_validation.zig");
    // Temp-file prefix SSOT between the spill/script writers and the startup
    // pruner; referenced explicitly so its lockstep test runs.
    _ = @import("tools/temp_files.zig");
    // Shared HTTP plumbing (buffers, media types, status predicates);
    // referenced explicitly so its inline tests run.
    _ = @import("http.zig");
    // Idle-lane notice SSOT shared by mode/turn lifecycle; referenced
    // explicitly so its byte-pinning test runs.
    _ = @import("tui/lanes.zig");
    // Platform-tolerant path comparison root leaf (extracted from
    // tui/lanes.zig); referenced explicitly so its inline tests run.
    _ = @import("paths.zig");
    _ = @import("agent/compactor.zig");
    _ = @import("auth/keyring.zig");
    _ = @import("config/provider.zig");
}
