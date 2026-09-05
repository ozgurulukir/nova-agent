//! Shared cursor-token scanner for the two prompt sigils: `@` file mentions
//! (`at_mention.zig`) and `$` skill invocations (`skill.zig`).
//!
//! The backward-scan rules are identical for both surfaces — the token starts
//! at a sigil that sits at the start of the text or right after whitespace and
//! runs to the cursor with no intervening whitespace. Extracted so the
//! boundary rules can never drift between autocomplete and prompt parsing
//! (same lockstep discipline as skill `find`/`contains` case-insensitivity).
//!
//! paths.zig-style leaf: pure std-only helpers, no imports from `src/`.
//! `bash_safety.zig`'s `isBoundary` is a different predicate (shell
//! metacharacters) and deliberately NOT shared with this one.

const std = @import("std");

/// One sigil token ending at the cursor.
pub const Token = struct {
    /// Byte offset of the sigil within the scanned text.
    start: usize,
    /// The fragment after the sigil (may be empty when the cursor sits right
    /// after the sigil).
    query: []const u8,
};

/// The active sigil token ending at the cursor, given the text *before* the
/// cursor. The token starts right after a `trigger` byte that sits at the
/// start of the text or just after whitespace, and runs to the cursor with no
/// intervening whitespace. Returns null when there is no such token (e.g. the
/// cursor is mid-word, after a space, or the sigil is embedded like in an
/// email address).
pub fn activeQuery(before_cursor: []const u8, trigger: u8) ?Token {
    var i: usize = before_cursor.len;
    while (i > 0) : (i -= 1) {
        const c = before_cursor[i - 1];
        if (isBoundary(c)) return null;
        if (c == trigger) {
            const at = i - 1;
            if (at == 0 or isBoundary(before_cursor[at - 1])) {
                return .{ .start = at, .query = before_cursor[at + 1 ..] };
            }
            return null;
        }
    }
    return null;
}

/// Whitespace-only token boundary (space, tab, newline, carriage return).
pub fn isBoundary(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Drops trailing sentence punctuation so `@src/x.zig.` references `src/x.zig`
/// and `$tiger!` references `tiger`.
pub fn trimTrailingPunctuation(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0) : (end -= 1) {
        switch (value[end - 1]) {
            '.', ',', ';', ':', '!', '?' => {},
            else => break,
        }
    }
    return value[0..end];
}

test "activeQuery detects a token at the cursor (both sigils)" {
    var buf: [16]u8 = undefined;
    inline for (.{ '@', '$' }) |sigil| {
        const text = try std.fmt.bufPrint(&buf, "explain {c}src/ag", .{sigil});
        const active = activeQuery(text, sigil).?;
        try std.testing.expectEqual(@as(usize, 8), active.start);
        try std.testing.expectEqualStrings("src/ag", active.query);
    }
}

test "activeQuery handles a bare sigil at the start (both sigils)" {
    var buf: [2]u8 = undefined;
    inline for (.{ '@', '$' }) |sigil| {
        buf[0] = sigil;
        const active = activeQuery(buf[0..1], sigil).?;
        try std.testing.expectEqual(@as(usize, 0), active.start);
        try std.testing.expectEqualStrings("", active.query);
    }
}

test "activeQuery rejects whitespace after the token (both sigils)" {
    var buf: [16]u8 = undefined;
    inline for (.{ '@', '$' }) |sigil| {
        const trailing = try std.fmt.bufPrint(&buf, "explain {c}foo ", .{sigil});
        try std.testing.expect(activeQuery(trailing, sigil) == null);
        try std.testing.expect(activeQuery("hello world", sigil) == null);
    }
}

test "activeQuery rejects an embedded sigil (email-like)" {
    try std.testing.expect(activeQuery("mail user@host", '@') == null);
}

test "activeQuery only honors its own trigger" {
    try std.testing.expect(activeQuery("see @src", '@') != null);
    try std.testing.expect(activeQuery("see @src", '$') == null);
    try std.testing.expect(activeQuery("use $tiger", '$') != null);
    try std.testing.expect(activeQuery("use $tiger", '@') == null);
}

test "trimTrailingPunctuation strips sentence punctuation only" {
    try std.testing.expectEqualStrings("src/a.zig", trimTrailingPunctuation("src/a.zig."));
    try std.testing.expectEqualStrings("tiger", trimTrailingPunctuation("tiger!?"));
    try std.testing.expectEqualStrings("a,b", trimTrailingPunctuation("a,b"));
    try std.testing.expectEqualStrings("", trimTrailingPunctuation(""));
    try std.testing.expectEqualStrings("", trimTrailingPunctuation("..."));
}
