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
pub const local_models = @import("models/local.zig");
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
pub const pytools = @import("pytools.zig");
pub const search = @import("search.zig");
pub const session = @import("session.zig");
pub const skill = @import("skill.zig");
pub const symbols = @import("symbols.zig");
pub const terminal_markdown = @import("terminal_markdown");
pub const mcp = @import("mcp/manager.zig");
pub const mcp_client = @import("mcp/client.zig");
pub const mcp_transport = @import("mcp/transport.zig");
pub const runtime = @import("runtime.zig");
pub const vcs = @import("vcs.zig");
pub const transcript = @import("transcript.zig");
pub const tools = @import("tools.zig");
pub const lua = @import("lua/root.zig");
pub const lua_test_runner = @import("lua/test_runner.zig");
pub const tui = @import("tui.zig");
pub const thread = @import("tui/thread.zig");
pub const toast = @import("tui/toast.zig");

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

    const home_dir = try resolveHomeDir(gpa, init.environ_map);
    defer gpa.free(home_dir);

    var load_result = try config.load(gpa, init.io, cwd, home_dir, init.environ_map);
    var local_models_handle: ?local_models.Server = null;
    {
        const classifier_set = if (load_result.config.model_selection) |*ms|
            (ms.bashClassifierUrl() != null)
        else
            true;
        if (!classifier_set) {
            local_models_handle = try local_models.ensure(gpa, init.io, cwd);
            errdefer if (local_models_handle) |*server| server.deinit(gpa, init.io);
            if (local_models_handle) |server| {
                if (load_result.config.model_selection) |*ms| {
                    switch (ms.*) {
                        .builtin => |*b| b.bash_classifier_url = try gpa.dupe(u8, server.url),
                        .custom => |*c| c.bash_classifier_url = try gpa.dupe(u8, server.url),
                    }
                }
            }
        }
    }
    defer if (local_models_handle) |*server| server.deinit(gpa, init.io);

    // The TUI is long-running and streams unbounded content. `SmpAllocator`
    // (Zig 0.16) has a known multi-threaded free-list corruption bug that
    // panics with "incorrect alignment"; `PageAllocator` is the safe fallback:
    // thread-safe, actually frees memory, but each allocation maps a whole page.
    const tui_gpa = gpa;
    const tui_config = try load_result.config.cloneForTui(tui_gpa);
    const runtime_gpa = gpa;

    defer search.deinit(runtime_gpa, init.io);

    const system_prompt = if (load_result.config.model_selection) |ms|
        (ms.systemPrompt() orelse @embedFile("prompts/system.md"))
    else
        @embedFile("prompts/system.md");
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
    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse return error.HomeNotSet;
    return std.fs.path.join(gpa, &.{ home, ".config", "nova", "nova.log" });
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
/// 10 MB cap. Bad input falls back to the default rather than disabling
/// rotation silently.
fn resolveMaxBytes(env: anytype) u64 {
    if (env.get("NOVA_LOG_MAX_BYTES")) |raw| {
        if (std.fmt.parseInt(u64, raw, 10)) |n| {
            if (n > 0) return n;
        } else |_| {}
    }
    return 10 * 1024 * 1024;
}

fn resolveHomeDir(gpa: std.mem.Allocator, env: anytype) std.mem.Allocator.Error![]u8 {
    if (env.get("HOME")) |home| return gpa.dupe(u8, home);
    if (env.get("USERPROFILE")) |home| return gpa.dupe(u8, home);
    return gpa.dupe(u8, "");
}

test {
    std.testing.refAllDecls(@This());
    // The TUI tests moved out of `tui.zig` into `src/tui/tests.zig`; reference
    // the file here so its test blocks are compiled into the test run (a file
    // only referenced lazily — e.g. `pub const tests` on `tui.zig` — is never
    // analyzed, and its tests silently never run).
    _ = @import("tui/tests.zig");
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
}
