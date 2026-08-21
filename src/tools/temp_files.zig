//! Temp-file name prefixes shared by the writers (bash_exec, pwsh_exec,
//! background) and the startup pruner (bash_exec.pruneTempDir). The pruner
//! matches on these prefixes, so every writer file name MUST start with one of
//! `prunable_prefixes` — otherwise a crash-stranded file is never reaped by the
//! 24h startup cleanup. The values are load-bearing history: files written by
//! older binaries carry these exact prefixes, so changing one silently stops
//! pruning every pre-existing temp file.

const std = @import("std");

/// Spill files from the bash tool's disk-backed capture: `nova-bash-<hex>.log`.
pub const bash_spill_prefix = "nova-bash-";

/// PowerShell temp files: spill logs (`nova-pwsh-<hex>.log`), exit-checked
/// scripts (`nova-pwsh-script-<hex>.ps1`), and background scripts
/// (`nova-pwsh-bg-<hex>.ps1`).
pub const pwsh_prefix = "nova-pwsh-";

/// Background job logs, composed from the job id: `nova-bg_<id>.log`.
pub const bg_log_prefix = "nova-bg_";

/// Everything the startup pruner may delete. Bare `nova-` is deliberately
/// absent so unrelated temp files that merely start with `nova-` are never
/// touched.
pub const prunable_prefixes = [_][]const u8{ bash_spill_prefix, pwsh_prefix, bg_log_prefix };

/// True when `name` starts with one of `prunable_prefixes`.
pub fn isPrunable(name: []const u8) bool {
    for (prunable_prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return true;
    }
    return false;
}

test "prunable prefixes cover every writer name shape" {
    // Pin the exact prefix values: files from older binaries carry them, so an
    // accidental value change would strand every pre-existing temp file past
    // the startup prune.
    try std.testing.expectEqualStrings("nova-bash-", bash_spill_prefix);
    try std.testing.expectEqualStrings("nova-pwsh-", pwsh_prefix);
    try std.testing.expectEqualStrings("nova-bg_", bg_log_prefix);

    // Every name shape the writers produce, composed the way the writers do.
    try std.testing.expect(isPrunable(bash_spill_prefix ++ "a1b2c3.log"));
    try std.testing.expect(isPrunable(pwsh_prefix ++ "a1b2c3.log"));
    try std.testing.expect(isPrunable(pwsh_prefix ++ "script-a1b2c3.ps1"));
    try std.testing.expect(isPrunable(pwsh_prefix ++ "bg-a1b2c3.ps1"));
    try std.testing.expect(isPrunable(bg_log_prefix ++ "7.log"));

    // Bare `nova-` must stay unprunable, and unrelated files untouched.
    try std.testing.expect(!isPrunable("nova-other.txt"));
    try std.testing.expect(!isPrunable("keep.txt"));
    try std.testing.expect(!isPrunable(""));
}
