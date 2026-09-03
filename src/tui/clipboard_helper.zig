//! TUI Clipboard Integration Helper.
//!
//! Bridges TUI modes, inputs, and selection state with `clipboard.zig`.

const std = @import("std");
const tui = @import("../tui.zig");
const clipboard_mod = @import("../clipboard.zig");

const App = tui.App;

/// Paste `text` into whichever text input currently has focus for `app.mode`.
pub fn pasteToFocusedInput(app: *App, text: []const u8) !void {
    if (text.len == 0) return;
    // The prompt is a multiline field: keep embedded newlines (that is the
    // whole point of multiline paste), folding CR to LF so Windows CRLF
    // clipboards don't inject raw carriage returns into the buffer. Every
    // other target is single-line — trim line endings so a multiline
    // clipboard can't leak newlines into a filter field.
    var normalized: ?[]u8 = null;
    const clean_text: []const u8 = if (app.getMode() == .normal) blk: {
        const buf = try app.gpa.dupe(u8, text);
        for (buf) |*b| b.* = if (b.* == '\r') '\n' else b.*;
        normalized = buf;
        break :blk buf;
    } else std.mem.trim(u8, text, "\r\n");
    defer if (normalized) |buf| app.gpa.free(buf);
    if (clean_text.len == 0) return;

    switch (app.getMode()) {
        .normal => {
            try app.inputs.input.insertSliceAtCursor(clean_text);
        },
        .command, .model_picker, .tree_picker, .search, .theme_picker => {
            try app.inputs.palette.insertSliceAtCursor(clean_text);
        },
        .session_picker => {
            if (app.nav.session_action == .renaming) {
                try app.input_buffers.session_rename_text.appendSlice(app.gpa, clean_text);
            } else {
                try app.inputs.palette.insertSliceAtCursor(clean_text);
            }
        },
        .provider_picker => {
            if (app.pickers.provider.stage == .form) {
                try app.getProviderKeyInput().appendSlice(app.gpa, clean_text);
                // Paste bypasses ProviderPicker.handle, so mark the key dirty
                // here too — otherwise a pasted key over a pre-filled one stays
                // masked and the user can't verify the paste.
                app.pickers.provider.key_dirty = true;
            }
        },
        .settings => {
            if (app.pickers.settings.edit_target != .none) {
                try app.input_buffers.settings_text.appendSlice(app.gpa, clean_text);
            }
        },
        .diff_viewer => {
            if (app.diff.sub == .commenting) {
                try app.inputs.comment.insertSliceAtCursor(clean_text);
            } else if (app.diff.sub == .file_search) {
                try app.inputs.palette.insertSliceAtCursor(clean_text);
            }
        },
        .save_message => {
            try app.inputs.palette.insertSliceAtCursor(clean_text);
        },
        .mcp => {
            if (app.pickers.mcp.adding) {
                try app.input_buffers.mcp_url.appendSlice(app.gpa, clean_text);
            }
        },
        .lanes, .help, .plugins => {},
    }
}

/// Paste system clipboard content into the focused input field.
pub fn pasteFromSystemClipboard(app: *App) !bool {
    if (clipboard_mod.readFromClipboard(app.gpa, app.getIo())) |text| {
        defer app.gpa.free(text);
        try pasteToFocusedInput(app, text);
        return true;
    }
    return false;
}

/// Copy the text of the selected transcript block (or last agent response) to clipboard.
pub fn copySelectedTranscriptBlock(app: *App) !bool {
    const selected_idx = app.thread.transcript.selected orelse blk: {
        // Fall back to last agent response if no block is selected.
        if (app.thread.transcript.messages.items.len == 0) return false;
        var i = app.thread.transcript.messages.items.len;
        while (i > 0) {
            i -= 1;
            const msg = &app.thread.transcript.messages.items[i];
            if (msg.* == .agent) break :blk @as(u32, @intCast(i));
        }
        break :blk @as(u32, @intCast(app.thread.transcript.messages.items.len - 1));
    };

    if (selected_idx >= app.thread.transcript.messages.items.len) return false;
    const msg = &app.thread.transcript.messages.items[selected_idx];
    const mirror = msg.mirror();
    const text = mirror.body;
    if (text.len == 0) return false;

    clipboard_mod.copyToClipboard(app.gpa, app.getIo(), text);

    var notice_buf: [256]u8 = undefined;
    const kind_name = @tagName(mirror.kind);
    const notice_text = try std.fmt.bufPrint(&notice_buf, "Copied {s} message block to clipboard ({d} bytes).", .{ kind_name, text.len });
    _ = try app.thread.transcript.append(app.gpa, .notice, "clipboard", notice_text);
    return true;
}

/// Copy current diff file patch or review text to clipboard.
pub fn copyDiffToClipboard(app: *App) !bool {
    if (!app.isDiffViewerMode()) return false;
    const composed = try app.diff.composeMessage(app.gpa);
    if (composed) |msg| {
        defer app.gpa.free(msg);
        clipboard_mod.copyToClipboard(app.gpa, app.getIo(), msg);
        _ = try app.thread.transcript.append(app.gpa, .notice, "clipboard", "Copied diff review comments to clipboard.");
        return true;
    }
    return false;
}

const agent_mod = @import("../agent.zig");

test "pasteToFocusedInput inserts text into main prompt in normal mode" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .normal;
    try pasteToFocusedInput(&app, "pasted prompt text");

    const val = try app.peekInput();
    defer gpa.free(val);
    try std.testing.expectEqualStrings("pasted prompt text", val);
}

test "pasteToFocusedInput keeps newlines in the multiline prompt" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .normal;
    try pasteToFocusedInput(&app, "line1\nline2\nline3");

    const val = try app.peekInput();
    defer gpa.free(val);
    try std.testing.expectEqualStrings("line1\nline2\nline3", val);
}

test "pasteToFocusedInput folds CRLF to LF in the prompt" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .normal;
    try pasteToFocusedInput(&app, "line1\r\nline2");

    const val = try app.peekInput();
    defer gpa.free(val);
    try std.testing.expectEqualStrings("line1\nline2", val);
}

test "pasteToFocusedInput trims newlines for single-line palette targets" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .model_picker;
    try pasteToFocusedInput(&app, "filter\r\n");

    const val = try app.peekPaletteInput();
    defer gpa.free(val);
    try std.testing.expectEqualStrings("filter", val);
}

test "pasteToFocusedInput inserts text into provider key input in provider form" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .provider_picker;
    app.pickers.provider.stage = .form;

    try pasteToFocusedInput(&app, "sk-proj-12345");
    try std.testing.expectEqualStrings("sk-proj-12345", app.input_buffers.provider_key.items);
    // Paste bypasses ProviderPicker.handle, so it must mark the key dirty to
    // reveal the pasted value for verification.
    try std.testing.expect(app.pickers.provider.key_dirty);
}
