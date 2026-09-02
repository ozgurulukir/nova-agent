//! The host operating system, resolved once at comptime. A single place for the
//! rest of the program to branch on (`is_windows`, `tag`) or label (`label`) the
//! OS, instead of reaching for `builtin.os.tag` — and re-deriving the human name —
//! in scattered spots.

const std = @import("std");
const builtin = @import("builtin");

/// Host OS tag. Prefer this over `builtin.os.tag` so every OS check shares one source.
pub const tag = builtin.os.tag;

/// Whether the host is Windows — Nova's most common OS branch.
pub const is_windows = tag == .windows;

/// Human-facing OS name, e.g. for the system prompt's `${OS}` placeholder.
pub const label: []const u8 = switch (tag) {
    .windows => "Windows",
    .linux => "Linux",
    .macos => "macOS",
    .freebsd => "FreeBSD",
    .netbsd => "NetBSD",
    .openbsd => "OpenBSD",
    else => @tagName(tag),
};

/// Extract the exit code from a child process termination. Non-exit
/// terminations (signal, stop, unknown) map to 255 so callers always see a
/// u8. Shared by `vcs.zig` and `background.zig` — the single source of truth.
pub fn termCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |value| value,
        .signal, .stopped, .unknown => 255,
    };
}

const windows = if (is_windows) struct {
    const BOOL = i32;
    const UINT = u32;
    extern "kernel32" fn SetConsoleOutputCP(wCodePageID: UINT) callconv(.winapi) BOOL;
    extern "kernel32" fn SetConsoleCP(wCodePageID: UINT) callconv(.winapi) BOOL;
} else struct {};

/// Ensure Windows console input/output codepage is set to UTF-8 (65001)
/// so Unicode characters render cleanly instead of falling back to legacy OEM codepages.
pub fn initConsoleUtf8() void {
    if (comptime is_windows) {
        _ = windows.SetConsoleOutputCP(65001);
        _ = windows.SetConsoleCP(65001);
    }
}
