//! The `bash` tool: the per-shell backend over the shared implementation in
//! `shell.zig`. Everything that is real bash divergence lives here — the exec
//! module, the `cd`/`pushd`/`popd` containment guard, the cwd-containment
//! semantics, and the background spawn shape — and `shell.Impl(Backend)`
//! supplies the shared orchestration (arg parsing, capture→observation
//! shaping, display extraction, background launch, display labeling) plus the
//! pub tool surface, re-exported below unchanged.

const std = @import("std");
const background = @import("../background.zig");
const bash = @import("bash_exec.zig");
const common = @import("common.zig");
const os = @import("../os.zig");
const shell = @import("shell.zig");

/// The bash-specific half of the `shell.Impl` Backend contract (see
/// `shell.zig`'s module doc). Containment is defense-in-depth, not a sandbox —
/// it neutralizes `cd`-based escapes, not absolute-path writes.
pub const Backend = struct {
    pub const name: []const u8 = "bash";
    pub const description: []const u8 = @embedFile("../prompts/tools/bash.md");
    pub const prompt_prefix: []const u8 = "$ ";
    pub const exec = bash;
    pub const command_mode: background.BackgroundManager.CommandMode = .argv_dash_c;
    pub const stderr_merge_prefix: []const u8 = "exec 2>&1\n";
    pub const stderr_merge_suffix: []const u8 = "";

    /// Shell function definitions prepended to a contained command. The `cd`
    /// override runs `builtin cd`, then compares the shell's PHYSICAL cwd (`pwd -P`)
    /// against `_nova_root` (set to the project root by `prependCdGuard`): a target
    /// that resolves outside the root is refused and the shell restored, so a model
    /// that `cd`s to the main tree's absolute path stays put. `pushd`/`popd` are
    /// rejected outright (they'd bypass the guard).
    pub const cd_guard_functions =
        \\cd() { while [ $# -gt 0 ] && { [ "$1" = -P ] || [ "$1" = -L ] || [ "$1" = -- ]; }; do shift; done; local _prev="$PWD"; builtin cd "$@" || return 1; local _phys="$(pwd -P)"; if [ "$_phys" != "$_nova_root" ] && [ "${_phys#$_nova_root}" = "$_phys" ]; then printf 'cd: %s escapes the workspace root\n' "$_phys" >&2; builtin cd "$_prev" 2>/dev/null || builtin cd "$_nova_root"; return 1; fi; return 0; };
        \\pushd() { printf 'pushd: not allowed in this workspace\n' >&2; return 1; };
        \\popd() { printf 'popd: not allowed in this workspace\n' >&2; return 1; };
        \\
    ;

    /// Prefix `command` with `_nova_root` (the literal, shell-escaped project root)
    /// and the `cd`/`pushd`/`popd` guard functions. `_nova_root` anchors on the
    /// project root — not the shell's start cwd — so a `cwd` subdir argument does
    /// not tighten containment to that subdir.
    pub fn prependCdGuard(gpa: std.mem.Allocator, project_root: []const u8, command: []const u8) std.mem.Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, "_nova_root=\"");
        for (project_root) |c| switch (c) {
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '"' => try out.appendSlice(gpa, "\\\""),
            '$' => try out.appendSlice(gpa, "\\$"),
            '`' => try out.appendSlice(gpa, "\\`"),
            else => try out.append(gpa, c),
        };
        try out.appendSlice(gpa, "\";\n");
        try out.appendSlice(gpa, cd_guard_functions);
        try out.appendSlice(gpa, command);
        return out.toOwnedSlice(gpa);
    }

    /// Validate that `resolved_cwd` stays within the project root. `project_root`
    /// must be absolute; `resolved_cwd` may be absolute or relative. Returns
    /// `false` when the resolved path escapes the project root.
    ///
    /// Two containment checks, both against a normalized root: a lexical one (after
    /// collapsing `..`/`.`/double-slashes) and a best-effort symlink one (realpath on
    /// both sides, so `link -> /etc` inside the root is caught). The symlink check
    /// is an optimization over the lexical one: realpath has limited platform
    /// support and is racy, so any realpath failure falls back to the lexical
    /// verdict instead of rejecting the command — a missing path is still rejected
    /// by the spawn with a clear error.
    pub fn validateCwd(gpa: std.mem.Allocator, io: std.Io, project_root: []const u8, resolved_cwd: []const u8) bool {
        const normalized = std.fs.path.resolve(gpa, &.{ project_root, resolved_cwd }) catch return false;
        defer gpa.free(normalized);
        // Normalize the root too so a trailing slash (or `.`/`..`/double-slash) in
        // `project_root` can't defeat the prefix compare (resolve() already
        // collapsed `resolved_cwd`).
        const normalized_root = std.fs.path.resolve(gpa, &.{project_root}) catch return false;
        defer gpa.free(normalized_root);

        if (!std.mem.startsWith(u8, normalized, normalized_root)) return false;
        // Also check that the next byte after the project root is a separator or end-of-string,
        // so `/home/project-evil` is not considered inside `/home/project`.
        if (normalized.len > normalized_root.len and normalized[normalized_root.len] != std.fs.path.sep) return false;

        // Best-effort symlink resolution (TD-4): canonicalize the resolved cwd and
        // the root and re-check containment. Any error skips this check — never a
        // hard failure. `realPathFileAbsoluteAlloc` asserts the path is absolute on
        // the host OS; a cross-OS path (a Windows drive path resolved on POSIX, or
        // vice versa) that `std.fs.path.resolve` leaves non-absolute on the foreign
        // OS would trip that assert and crash. When the normalized path is not
        // absolute on this host the realpath re-check cannot run; fall back to the
        // lexical verdict already computed above, mirroring the `catch return true`
        // degradation for realpath failures.
        if (!std.fs.path.isAbsolute(normalized) or !std.fs.path.isAbsolute(normalized_root)) return true;
        const real_cwd = std.Io.Dir.realPathFileAbsoluteAlloc(io, normalized, gpa) catch return true;
        defer gpa.free(real_cwd);
        const real_root = std.Io.Dir.realPathFileAbsoluteAlloc(io, normalized_root, gpa) catch return true;
        defer gpa.free(real_root);
        if (!std.mem.startsWith(u8, real_cwd, real_root)) return false;
        if (real_cwd.len > real_root.len and real_cwd[real_root.len] != std.fs.path.sep and real_cwd[real_root.len] != '/') return false;
        return true;
    }
};

const impl = shell.Impl(Backend);

pub const tool = impl.tool;
pub const BackgroundCtx = impl.BackgroundCtx;
pub const runTool = impl.runTool;
pub const runToolForTest = impl.runToolForTest;
pub const runContained = impl.runContained;
pub const runBackground = impl.runBackground;
pub const runCaptured = impl.runCaptured;
pub const wantsBackground = impl.wantsBackground;
pub const currentEnvMap = impl.currentEnvMap;
pub const display_diff_begin = impl.display_diff_begin;
pub const display_diff_end = impl.display_diff_end;

test "bash tool applies env object" {
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);

    var output = try runToolForTest(gpa, std.testing.io, cwd, "{\"command\":\"printf \\\"$BASH_TOOL_TEST\\\"\",\"description\":\"read\",\"env\":{\"BASH_TOOL_TEST\":\"hello-env\"}}");
    defer output.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), output.code);
    // stdout is the rendered observation — it now echoes the command first.
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "hello-env") != null);
}

test "bash tool applies relative cwd" {
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);

    try std.Io.Dir.cwd().createDirPath(std.testing.io, ".zig-cache/bash-tool-test");

    var output = try runToolForTest(gpa, std.testing.io, cwd, "{\"command\":\"printf \\\"$PWD\\\"\",\"description\":\"read\",\"cwd\":\".zig-cache/bash-tool-test\"}");
    defer output.deinit(gpa);

    // `$PWD` is reported in the shell's native notation (MSYS forward-slash form
    // under git bash), so assert the relative segment was applied rather than
    // exact-matching a host-style absolute path.
    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expect(std.mem.endsWith(u8, output.stdout, ".zig-cache/bash-tool-test"));
}

test "bash observation echoes the invoked command" {
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);

    var output = try runToolForTest(gpa, std.testing.io, cwd, "{\"command\":\"printf hello\",\"description\":\"Print hello\"}");
    defer output.deinit(gpa);
    const observation = try testObservationText(gpa, output);
    defer gpa.free(observation);

    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expectEqualStrings("$ printf hello\nhello", observation);
}

test "bash timeout observation echoes the command and retry guidance" {
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);

    var output = try runToolForTest(gpa, std.testing.io, cwd, "{\"command\":\"sleep 5\",\"timeout\":1}");
    defer output.deinit(gpa);
    const observation = try testObservationText(gpa, output);
    defer gpa.free(observation);

    try std.testing.expect(std.mem.indexOf(u8, observation, "$ sleep 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "timed out after 1 seconds") != null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "run_in_background") != null);
}

fn testObservationText(gpa: std.mem.Allocator, output: common.Output) ![]u8 {
    const observation = output.observation orelse return error.MissingObservation;
    return observation.render(gpa);
}

test "bash observation strips ANSI codes" {
    // `\x1b[31;1m` (red error) + `\x1b[0m` (reset) wraps a genuine payload to
    // prove the downstream strip cleans the observation. Mirror of the pwsh
    // ANSI-strip test; the whole point of the shared `stripAnsi` SSOT is that
    // both shells run the identical strip path. Skipped on Windows, where the
    // bash tool's runtime is broken (see issues #27; all bash *spawn* tests
    // fail there) — on POSIX, where bash runs, the test is mandatory.
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);

    var output = try runToolForTest(gpa, std.testing.io, cwd, "{\"command\":\"printf '\\\\x1b[31;1mboom\\\\x1b[0m'\",\"description\":\"ANSI error\"}");
    defer output.deinit(gpa);
    const observation = try testObservationText(gpa, output);
    defer gpa.free(observation);

    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expect(std.mem.indexOfScalar(u8, observation, 0x1b) == null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "boom") != null);
}

test "bash tool reports exit code in observation" {
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);

    var output = try runToolForTest(gpa, std.testing.io, cwd, "{\"command\":\"printf nope; exit 7\",\"description\":\"read\"}");
    defer output.deinit(gpa);
    const observation = try testObservationText(gpa, output);
    defer gpa.free(observation);

    try std.testing.expectEqual(@as(u8, 7), output.code);
    try std.testing.expect(std.mem.indexOf(u8, observation, "nope") != null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "Command exited with code 7") != null);
}

test "bash tool surfaces a display block as a diff-kind display" {
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);

    // The JSON-escaped RS byte (backslash-u-001e) is the sentinel; the shell
    // receives it literally and printf echoes it back out.
    const args = "{\"command\":\"printf 'edited ok\\n\\u001enova:diff\\n-old\\n+new\\n\\u001enova:end\\n'\",\"description\":\"edit\"}";
    var output = try runToolForTest(gpa, std.testing.io, cwd, args);
    defer output.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expectEqualStrings("-old\n+new", output.display.diff);
    try std.testing.expect(output.display == .diff);
    const observation = try testObservationText(gpa, output);
    defer gpa.free(observation);
    try std.testing.expect(std.mem.indexOf(u8, observation, "edited ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "\x1e") == null);
}

test "bash tool truncates observation tail and keeps full output path" {
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);

    var output = try runToolForTest(gpa, std.testing.io, cwd, "{\"command\":\"i=0; while [ $i -lt 2105 ]; do echo line-$i; i=$((i+1)); done\",\"description\":\"read\"}");
    defer {
        if (output.observation) |observation| switch (observation) {
            .complete => {},
            .truncated_tail => |tail| std.Io.Dir.deleteFile(.cwd(), std.testing.io, tail.full_output_path) catch {},
        };
        output.deinit(gpa);
    }
    const observation = try testObservationText(gpa, output);
    defer gpa.free(observation);

    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expect(std.mem.indexOf(u8, observation, "line-2104") != null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "line-0\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "Full output:") != null);
}

test "bash tool accepts null for optional fields under strict schema" {
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);

    // Null for optional string, object, integer, and boolean fields.
    var output = try runToolForTest(gpa, std.testing.io, cwd,
        \\{"command":"printf ok","description":null,"cwd":null,"env":null,"timeout":null,"run_in_background":null}
    );
    defer output.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), output.code);
    // stdout is the rendered observation — it echoes the command first.
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "ok") != null);
}

test "bash tool accepts partial nulls alongside populated optional fields" {
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);

    // Mix of null and real values: null description, populated cwd, null env, populated timeout, null run_in_background.
    var output = try runToolForTest(gpa, std.testing.io, cwd,
        \\{"command":"printf ok","description":null,"cwd":".","env":null,"timeout":30,"run_in_background":null}
    );
    defer output.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "ok") != null);
}

test "bash tool parses null timeout as default" {
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);

    var output = try runToolForTest(gpa, std.testing.io, cwd,
        \\{"command":"printf ok","timeout":null}
    );
    defer output.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "ok") != null);
}

test "bash tool rejects invalid type for nullable field when model sends wrong type" {
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);

    // Strict schema allows string|null for `description`, but not integer. The
    // JSON parser rejects the type mismatch, so parseArgs returns InvalidJson
    // and the tool exits non-zero instead of silently misinterpreting it.
    var output = try runToolForTest(gpa, std.testing.io, cwd,
        \\{"command":"printf ok","description":42}
    );
    defer output.deinit(gpa);

    try std.testing.expect(output.code != 0);
}

test "validateCwd accepts a trailing-slash project root" {
    // Regression for H2: the containment compare used the RAW project root, so
    // a trailing slash (resolve() strips it) made every relative cwd escape.
    try std.testing.expect(Backend.validateCwd(std.testing.allocator, std.testing.io, "/tmp/x/", "/tmp/x"));
    try std.testing.expect(Backend.validateCwd(std.testing.allocator, std.testing.io, "/tmp/x/", "."));
}

test "validateCwd rejects an absolute cwd outside the root" {
    // Existing behavior, kept green: an absolute cwd outside the root is refused.
    try std.testing.expect(!Backend.validateCwd(std.testing.allocator, std.testing.io, "/tmp/x", "/etc"));
}

test "validateCwd blocks a symlink that escapes the root" {
    // Regression for H3: the lexical check alone let `link -> /etc` inside the
    // project pass; the best-effort realpath re-check must catch it. Windows
    // resolves symlinks differently (`REPARSE_POINT_NOT_RESOLVED`), so this
    // semantics is exercised only on POSIX hosts.
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd_abs = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd_abs);
    const root_abs = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(root_abs);

    // Create `<tmp>/link -> /etc`; skip the test if the sandbox forbids symlinks.
    tmp.dir.symLink(std.testing.io, "/etc", "link", .{}) catch return error.SkipZigTest;

    const link_abs = try std.fs.path.join(gpa, &.{ root_abs, "link" });
    defer gpa.free(link_abs);

    try std.testing.expect(!Backend.validateCwd(gpa, std.testing.io, root_abs, link_abs));
}

test "empty sentinel block yields no display" {
    // Regression for L1: a begin/end sentinel pair with nothing between must not
    // produce a zero-length `.diff` display (the `common.Display` invariant).
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    const args = "{\"command\":\"printf '\\u001enova:diff\\n\\u001enova:end\\n'\",\"description\":\"edit\"}";
    var output = try runToolForTest(gpa, std.testing.io, cwd, args);
    defer output.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expect(output.display == .none);
}

test "prependCdGuard anchors on the project root and defines the guard" {
    const gpa = std.testing.allocator;
    const guarded = try Backend.prependCdGuard(gpa, "/home/u/repo", "printf hi");
    defer gpa.free(guarded);

    try std.testing.expect(std.mem.startsWith(u8, guarded, "_nova_root=\"/home/u/repo\";\n"));
    try std.testing.expect(std.mem.indexOf(u8, guarded, "cd() {") != null);
    try std.testing.expect(std.mem.indexOf(u8, guarded, "pushd()") != null);
    try std.testing.expect(std.mem.endsWith(u8, guarded, "printf hi"));
}

test "prependCdGuard escapes shell metacharacters in the root path" {
    const gpa = std.testing.allocator;
    const guarded = try Backend.prependCdGuard(gpa, "/tmp/a b\"c$d`e", "true");
    defer gpa.free(guarded);

    try std.testing.expect(std.mem.indexOf(u8, guarded, "_nova_root=\"/tmp/a b\\\"c\\$d\\`e\";") != null);
}

test "contained bash refuses cd to a directory outside the workspace root" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const test_cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(test_cwd);
    const root_abs = try std.fs.path.join(gpa, &.{ test_cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(root_abs);

    // The main-tree escape that broke lane isolation: `cd` to an absolute path
    // outside the worktree, then run. The guard must refuse the cd so the
    // command never executes in the escaped directory.
    var output = try runContained(gpa, std.testing.io, root_abs, "{\"command\":\"cd /etc && pwd\",\"description\":\"escape\"}", null);
    defer output.deinit(gpa);

    try std.testing.expect(output.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "escapes the workspace root") != null);
}

test "contained bash refuses cd via a symlink that leaves the root" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const test_cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(test_cwd);
    const root_abs = try std.fs.path.join(gpa, &.{ test_cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(root_abs);

    // `link -> /etc` inside the root: `cd link` resolves physically to /etc, so
    // the guard's `pwd -P` check must catch it (not just the lexical check).
    tmp.dir.symLink(std.testing.io, "/etc", "link", .{}) catch return error.SkipZigTest;

    var output = try runContained(gpa, std.testing.io, root_abs, "{\"command\":\"cd link && pwd\",\"description\":\"escape\"}", null);
    defer output.deinit(gpa);

    try std.testing.expect(output.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "escapes the workspace root") != null);
}

test "contained bash allows cd within the workspace root" {
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const test_cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(test_cwd);
    const root_abs = try std.fs.path.join(gpa, &.{ test_cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(root_abs);
    const sub_abs = try std.fs.path.join(gpa, &.{ root_abs, "sub" });
    defer gpa.free(sub_abs);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, sub_abs);

    // `cd sub` stays inside the worktree and must be allowed; `$PWD` reports the
    // native path form, so assert the relative segment landed.
    var output = try runContained(gpa, std.testing.io, root_abs, "{\"command\":\"cd sub && printf \\\"$PWD\\\"\",\"description\":\"read\"}", null);
    defer output.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expect(std.mem.endsWith(u8, output.stdout, "/sub"));
}

test "contained bash refuses pushd outright" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const test_cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(test_cwd);
    const root_abs = try std.fs.path.join(gpa, &.{ test_cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(root_abs);

    var output = try runContained(gpa, std.testing.io, root_abs, "{\"command\":\"pushd /etc\",\"description\":\"escape\"}", null);
    defer output.deinit(gpa);

    try std.testing.expect(output.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "pushd: not allowed") != null);
}

test "contained bash still validates a cwd argument escaping the root" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const test_cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(test_cwd);
    const root_abs = try std.fs.path.join(gpa, &.{ test_cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(root_abs);

    // The existing `cwd`-argument containment still applies under `runContained`.
    // The refusal is a tool-level failure (no shell spawned), so the message
    // lands in `stderr`, not the captured stdout.
    var output = try runContained(gpa, std.testing.io, root_abs, "{\"command\":\"pwd\",\"cwd\":\"/etc\",\"description\":\"read\"}", null);
    defer output.deinit(gpa);

    try std.testing.expect(output.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "escapes the project root") != null);
}
