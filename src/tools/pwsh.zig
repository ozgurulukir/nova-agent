//! The `pwsh` (PowerShell) tool: the per-shell backend over the shared
//! implementation in `shell.zig`. Everything that is real PowerShell
//! divergence lives here — the exec module, the
//! `Set-Location`/`Push-Location`/`Pop-Location` containment guard, the
//! slash/case-tolerant `pathsEqual` cwd containment, and the `-File`+
//! exit-check background spawn shape — and `shell.Impl(Backend)` supplies the
//! shared orchestration (arg parsing, capture→observation shaping, display
//! extraction, background launch, display labeling) plus the pub tool
//! surface, re-exported below unchanged.
//!
//! Like `pwsh_exec.zig`, this module MUST compile on POSIX even though its
//! runtime paths are Windows-only.

const std = @import("std");
const background = @import("../background.zig");
const common = @import("common.zig");
const os = @import("../os.zig");
const pws = @import("pwsh_exec.zig");
const paths = @import("../paths.zig");
const shell = @import("shell.zig");

/// The pwsh-specific half of the `shell.Impl` Backend contract (see
/// `shell.zig`'s module doc). Containment is defense-in-depth, not a sandbox —
/// it neutralizes location-based escapes, not absolute-path writes.
pub const Backend = struct {
    pub const name: []const u8 = "pwsh";
    pub const description: []const u8 = @embedFile("../prompts/tools/pwsh.md");
    pub const prompt_prefix: []const u8 = "> ";
    pub const exec = pws;
    pub const command_mode: background.BackgroundManager.CommandMode = .stdin_dash_command;
    pub const stderr_merge_prefix: []const u8 = "";
    pub const stderr_merge_suffix: []const u8 = "\nif (-not $?) { exit 1 } else { exit $LASTEXITCODE }";

    /// PowerShell function overrides prepended to a contained command. `Set-Location`
    /// shadows the built-in for every alias (`cd`, `sl`, `chdir`, `l`), computes the
    /// absolute target via `GetFullPath`, and refuses anything outside
    /// `_nova_root` (set to the project root by `prependCdGuard`). `Push-Location`/
    /// `Pop-Location` are rejected outright (they'd bypass the guard's state).
    /// The `cd:` message writes to stderr so it is captured but the guard still
    /// fails the command.
    pub const cd_guard_functions =
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
    pub fn prependCdGuard(gpa: std.mem.Allocator, project_root: []const u8, command: []const u8) std.mem.Allocator.Error![]u8 {
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
    pub fn validateCwd(gpa: std.mem.Allocator, io: std.Io, project_root: []const u8, resolved_cwd: []const u8) bool {
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

test "pwsh backend pins the prompt prefix and tool name" {
    // The echo e2e tests below are Windows-gated; pin the observation prefix
    // and the model-facing name here so a change fails on every platform.
    try std.testing.expectEqualStrings("> ", Backend.prompt_prefix);
    try std.testing.expectEqualStrings("pwsh", Backend.name);
}

test "validateCwd accepts a trailing-slash project root" {
    try std.testing.expect(Backend.validateCwd(std.testing.allocator, std.testing.io, "/tmp/x/", "/tmp/x"));
    try std.testing.expect(Backend.validateCwd(std.testing.allocator, std.testing.io, "/tmp/x/", "."));
}

test "validateCwd rejects an absolute cwd outside the root" {
    try std.testing.expect(!Backend.validateCwd(std.testing.allocator, std.testing.io, "/tmp/x", "/etc"));
}

test "prependCdGuard anchors on the project root and defines the guard" {
    const gpa = std.testing.allocator;
    const guarded = try Backend.prependCdGuard(gpa, "C:\\Users\\u\\repo", "Write-Output hi");
    defer gpa.free(guarded);

    try std.testing.expect(std.mem.startsWith(u8, guarded, "$_nova_root = [System.IO.Path]::GetFullPath('C:\\Users\\u\\repo');\n"));
    try std.testing.expect(std.mem.indexOf(u8, guarded, "function Set-Location") != null);
    try std.testing.expect(std.mem.indexOf(u8, guarded, "function Push-Location") != null);
    try std.testing.expect(std.mem.endsWith(u8, guarded, "Write-Output hi"));
}

test "prependCdGuard doubles single quotes in the root path" {
    const gpa = std.testing.allocator;
    const guarded = try Backend.prependCdGuard(gpa, "C:\\Repo O'Brien", "true");
    defer gpa.free(guarded);

    try std.testing.expect(std.mem.indexOf(u8, guarded, "$_nova_root = [System.IO.Path]::GetFullPath('C:\\Repo O''Brien');") != null);
}

test "prependCdGuard canonicalizes forward slashes in project root" {
    const gpa = std.testing.allocator;
    const guarded = try Backend.prependCdGuard(gpa, "C:/Users/u/repo", "Write-Output hi");
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

    try std.testing.expect(Backend.validateCwd(gpa, io, "C:\\repo", "C:/repo/sub"));
    try std.testing.expect(Backend.validateCwd(gpa, io, "C:/repo", "sub"));
    try std.testing.expect(!Backend.validateCwd(gpa, io, "C:\\repo", "C:\\repo-other"));
    try std.testing.expect(!Backend.validateCwd(gpa, io, "C:\\repo", "C:\\other"));
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
