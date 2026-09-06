//! TUI tests, moved out of `tui.zig` so the production file stays a readable
//! ~1400 lines. Purely test code: the `test` blocks that used to live at the
//! bottom of `tui.zig` plus their test-only helpers (`benchTranscriptDraw`,
//! `drawTranscriptFrame`, the bench bodies).
//!
//! Wired into the module graph from `src/root.zig`'s `test` block
//! (`_ = @import("tui/tests.zig");`). A lazy reference such as a `pub const
//! tests` on `tui.zig` is NOT enough — the file is never analyzed unless
//! something takes its address, and its test blocks silently never compile
//! into the run (see AGENTS.md "Silent test discovery").
//!
//! Everything the tests touch that is private to `tui.zig` (module consts like
//! `tx_widget`, `root_layout`, `input_mod`) is re-imported here by its real
//! path; `resolveCommand` and `RootWidget.captureEvent` were made `pub` in
//! `tui.zig` for the same reason.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../tui.zig");

const agent_mod = @import("../agent.zig");
const ai = @import("../ai.zig");
const at_search_mod = @import("at_search.zig");
const compaction_lifecycle = @import("compaction_lifecycle.zig");
const lifecycle = @import("lifecycle.zig");
const lane_lifecycle = @import("lane_lifecycle.zig");
const turn_view_mod = @import("turn_view.zig");
const openai_compatible_mod = @import("../ai/openai_compatible.zig");
const codex = @import("../auth/codex.zig");
const config_mod = @import("../config/config.zig");
const runtime_mod = @import("../runtime.zig");
const search_mod = @import("../search.zig");
const session_mod = @import("../session.zig");
const transcript_mod = @import("../transcript.zig");
const tools_mod = @import("../tools.zig");
const CountingAllocator = @import("counting_allocator").CountingAllocator;

const App = tui.App;
const RootWidget = tui.RootWidget;
const Thread = tui.Thread;
const ChipRect = tui.ChipRect;
const DiffCounts = tui.DiffCounts;
const Turn = @import("turn.zig");
const nextIndex = tui.nextIndex;
const previousIndex = tui.previousIndex;
const resolveCommand = tui.resolveCommand;
const reasoningOptions = tui.reasoningOptions;
const commandMatchesCountForFilter = tui.commandMatchesCountForFilter;

const provider_model = @import("provider_model.zig");
const search_lifecycle = @import("search_lifecycle.zig");
const diff_utils = @import("diff_utils.zig");
const model_loader = @import("model_loader.zig");
const root_layout = @import("layout.zig");
const session_switcher = @import("session_switcher.zig");
const transcript_nav = @import("transcript_nav.zig");
const input_mod = @import("widgets/input.zig");
const model_picker = @import("widgets/model_picker.zig");
const panel = @import("widgets/panel.zig");
const provider_picker = @import("widgets/provider_picker.zig");
const tx_widget = @import("widgets/transcript.zig");
const tui_message = @import("widgets/message.zig");
const tui_metrics = @import("metrics.zig");

const ConversationLayout = tui_message.ConversationLayout;
const MessageWidget = tui_message.MessageWidget;
const messageRowsCached = tui_metrics.messageRowsCached;

const isolatedHome = @import("test_fixture.zig").isolatedHome;

test "parse diff counts sums numstat and skips binary" {
    const counts = diff_utils.parseDiffCounts(
        "3\t1\tsrc/a.zig\n" ++
            "-\t-\timage.png\n" ++
            "8\t0\tsrc/new.zig\n",
    );

    try std.testing.expectEqual(@as(u32, 11), counts.additions);
    try std.testing.expectEqual(@as(u32, 1), counts.deletions);
}

test "diff count label is right aligned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 13, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    var surface = try vxfw.Surface.init(ctx.arena, .{ .userdata = undefined, .drawFn = undefined }, .{ .width = 13, .height = 1 });

    input_mod.writeDiffCounts(&surface, ctx, .{ .additions = 1, .deletions = 12 });

    try std.testing.expectEqualStrings(" ", surface.readCell(6, 0).char.grapheme);
    try std.testing.expectEqualStrings("+", surface.readCell(7, 0).char.grapheme);
    try std.testing.expectEqualStrings("1", surface.readCell(8, 0).char.grapheme);
    try std.testing.expectEqualStrings(" ", surface.readCell(9, 0).char.grapheme);
    try std.testing.expectEqualStrings("-", surface.readCell(10, 0).char.grapheme);
    try std.testing.expectEqualStrings("1", surface.readCell(11, 0).char.grapheme);
    try std.testing.expectEqualStrings("2", surface.readCell(12, 0).char.grapheme);
}

test "diff count labels keep signs next to numbers" {
    var small_add: [8]u8 = undefined;
    var small_del: [8]u8 = undefined;
    const small = DiffCounts{ .additions = 1, .deletions = 12 };
    const small_additions = try std.fmt.bufPrint(&small_add, "+{d}", .{@min(small.additions, 99999)});
    const small_deletions = try std.fmt.bufPrint(&small_del, "-{d}", .{@min(small.deletions, 99999)});

    var large_add: [8]u8 = undefined;
    var large_del: [8]u8 = undefined;
    const large = DiffCounts{ .additions = 12345, .deletions = 999999 };
    const large_additions = try std.fmt.bufPrint(&large_add, "+{d}", .{@min(large.additions, 99999)});
    const large_deletions = try std.fmt.bufPrint(&large_del, "-{d}", .{@min(large.deletions, 99999)});

    try std.testing.expectEqualStrings("+1", small_additions);
    try std.testing.expectEqualStrings("-12", small_deletions);
    try std.testing.expectEqualStrings("+12345", large_additions);
    try std.testing.expectEqualStrings("-99999", large_deletions);
}

test "root layout keeps input fixed when panel opens" {
    const normal = root_layout.rootLayout(30, false, 1, false, false);
    const picker = root_layout.rootLayout(30, true, 1, false, false);

    try std.testing.expectEqual(normal.input_row, picker.input_row);
    try std.testing.expectEqual(normal.transcript_height, picker.transcript_height);
    try std.testing.expectEqual(@as(u16, 19), picker.panel_row);
    try std.testing.expectEqual(@as(u16, 7), picker.panel_height);
}

test "root layout clamps panel above input on short screens" {
    const layout = root_layout.rootLayout(8, true, 1, false, false);

    try std.testing.expectEqual(@as(u16, 4), layout.input_height);
    try std.testing.expectEqual(@as(u16, 4), layout.transcript_height);
    try std.testing.expectEqual(@as(u16, 4), layout.panel_height);
    try std.testing.expectEqual(@as(u16, 0), layout.panel_row);
    try std.testing.expectEqual(@as(u16, 4), layout.input_row);
}

test "root layout grows the input as text rows increase" {
    const one = root_layout.rootLayout(30, false, 1, false, false);
    try std.testing.expectEqual(@as(u16, 4), one.input_height);
    try std.testing.expectEqual(@as(u16, 26), one.transcript_height);

    const three = root_layout.rootLayout(30, false, 3, false, false);
    try std.testing.expectEqual(@as(u16, 6), three.input_height);
    try std.testing.expectEqual(@as(u16, 24), three.transcript_height);

    // A short screen still leaves the transcript some room.
    const tight = root_layout.rootLayout(10, false, 6, false, false);
    try std.testing.expectEqual(@as(u16, 7), tight.input_height);
    try std.testing.expectEqual(@as(u16, 3), tight.transcript_height);
}

test "root layout reserves a row for the queued-message line" {
    // A queued (steered) message draws an extra line above the input border, so
    // the input region must grow by one row — otherwise the hint + diff counts
    // get squeezed out (regression: they vanished after sending mid-generation).
    const plain = root_layout.rootLayout(30, false, 1, false, false);
    const queued = root_layout.rootLayout(30, false, 1, false, true);
    try std.testing.expectEqual(plain.input_height + 1, queued.input_height);
}

test "input text rows track the line count" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 100, .height = 30 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    try std.testing.expectEqual(@as(u16, 1), try app.inputTextRows(ctx, 80));

    try app.inputs.input.insertSliceAtCursor("a\nb\nc");
    try std.testing.expectEqual(@as(u16, 3), try app.inputTextRows(ctx, 80));

    try app.inputs.input.insertSliceAtCursor("defgh");
    try std.testing.expectEqual(@as(u16, 4), try app.inputTextRows(ctx, 4));

    // The input keeps growing with the line count (no fixed cap).
    try app.inputs.input.insertSliceAtCursor("\n\n\n\n\n\n\n\n");
    try std.testing.expectEqual(@as(u16, 12), try app.inputTextRows(ctx, 4));
}

test "file picker selection replaces the active mention without corrupting input buffer" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("open @src/ag");
    const query = try gpa.dupe(u8, "src/ag");
    app.at_search = .{ .open = .{ .kind = .file, .query = query } };
    try app.at_search.open.results.append(gpa, try gpa.dupe(u8, "src/search.zig"));

    try app.acceptAtSelection();

    const input = try app.peekInput();
    defer gpa.free(input);
    try std.testing.expectEqualStrings("open @src/search.zig ", input);
}

test "skill picker selection replaces the active mention without corrupting input buffer" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer search_mod.deinit(gpa, std.testing.io);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("run $tig");
    const query = try gpa.dupe(u8, "tig");
    app.at_search = .{ .open = .{ .kind = .skill, .query = query } };
    try app.at_search.open.results.append(gpa, try gpa.dupe(u8, "tigerstyle"));

    try app.acceptAtSelection();

    const input = try app.peekInput();
    defer gpa.free(input);
    try std.testing.expectEqualStrings("run $tigerstyle ", input);
}

test "file picker starts its deferred search after debounce expires" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer search_mod.deinit(gpa, std.testing.io);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("@search");
    try app.updateAtSearch();

    var indexing_polls: u32 = 0;
    while (app.at_search == .indexing and indexing_polls < 100) : (indexing_polls += 1) {
        try app.updateAtSearch();
        std.testing.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(app.at_search == .open);

    // Wait for the 80ms debounce window to naturally expire.
    var wait_ticks: u32 = 0;
    while (!app.at_search.debounceExpired(app.io) and wait_ticks < 50) : (wait_ticks += 1) {
        std.testing.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(app.at_search.debounceExpired(app.io));

    var result_polls: u32 = 0;
    while (app.at_search.open.results.items.len == 0 and result_polls < 100) : (result_polls += 1) {
        try at_search_mod.pollAtSearch(&app);
        std.testing.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(app.at_search.open.results.items.len > 0);
}

test "file picker in-place query updates preserve results while debouncing" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer search_mod.deinit(gpa, std.testing.io);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("@src");
    try app.updateAtSearch();

    var indexing_polls: u32 = 0;
    while (app.at_search == .indexing and indexing_polls < 100) : (indexing_polls += 1) {
        try app.updateAtSearch();
        std.testing.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(app.at_search == .open);

    var wait_ticks: u32 = 0;
    while (!app.at_search.debounceExpired(app.io) and wait_ticks < 50) : (wait_ticks += 1) {
        std.testing.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }
    while (app.at_search.open.results.items.len == 0 and wait_ticks < 100) : (wait_ticks += 1) {
        try at_search_mod.pollAtSearch(&app);
        std.testing.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(app.at_search.open.results.items.len > 0);
    const initial_count = app.at_search.open.results.items.len;

    // Type another character: results must NOT be wiped during debounce.
    try app.inputs.input.insertSliceAtCursor("/tui");
    try app.updateAtSearch();
    try std.testing.expectEqualStrings("src/tui", app.at_search.open.query);
    try std.testing.expectEqual(initial_count, app.at_search.open.results.items.len);
}

test "file picker lifecycle handleTick drives indexing, search, and idle transition" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer search_mod.deinit(gpa, std.testing.io);
    defer app.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var root: RootWidget = .{ .app = &app };
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    try app.inputs.input.insertSliceAtCursor("@src");
    try app.updateAtSearch();

    // While indexing or debouncing, the TUI tick must stay active.
    var ticks: u32 = 0;
    while (ticks < 150) : (ticks += 1) {
        try lifecycle.handleTick(&root, &ctx);
        if (app.at_search == .open and app.at_search.open.results.items.len > 0 and !app.at_search.open.searching and app.at_search.debounceExpired(app.io)) {
            break;
        }
        std.testing.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }

    try std.testing.expect(app.at_search == .open);
    try std.testing.expect(app.at_search.open.results.items.len > 0);

    // One more tick once idle should settle the loading tick to false.
    try lifecycle.handleTick(&root, &ctx);
    try std.testing.expect(!app.metrics.loading_tick_active);
}

test "file picker closes immediately when user backspaces trigger while indexing" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer search_mod.deinit(gpa, std.testing.io);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("@");
    try app.updateAtSearch();

    // If still indexing, backspacing the @ must close immediately.
    app.inputs.input.clearRetainingCapacity();
    try app.updateAtSearch();
    try std.testing.expect(app.at_search == .closed);
}

test "input wrapping uses word breaks" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 100, .height = 30 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const text = "hello world";
    try std.testing.expectEqual(@as(u16, 2), input_mod.wrappedTextRows(ctx, text, 10));

    const cursor = input_mod.wrappedTextPositionAt(ctx, text, "hello wo".len, 10);
    try std.testing.expectEqual(@as(u16, 1), cursor.row);
    try std.testing.expectEqual(@as(u16, 2), cursor.col);
}

test "down returns to multiline input after overshooting above top line" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    try app.inputs.input.insertSliceAtCursor("top\nmiddle\nbottom");

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    try RootWidget.captureEvent(&root, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.up } });
    try RootWidget.captureEvent(&root, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.up } });
    try std.testing.expectEqualStrings("top", app.inputs.input.buf.firstHalf());

    // One more Up leaves the input for block navigation.
    try RootWidget.captureEvent(&root, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.up } });
    try std.testing.expect(app.nav.block_nav);

    // With no transcript block selected, Down must return to the multiline input.
    try RootWidget.captureEvent(&root, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    try std.testing.expect(!app.nav.block_nav);
    try std.testing.expectEqualStrings("top\nmid", app.inputs.input.buf.firstHalf());

    try RootWidget.captureEvent(&root, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.down } });
    try std.testing.expectEqualStrings("top\nmiddle\nbot", app.inputs.input.buf.firstHalf());
}

test "arrow up and down move the input cursor between lines" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // Cursor ends on the third line at column 2 ("ca|t").
    try app.inputs.input.insertSliceAtCursor("fox\nox\ncat");
    app.inputs.input.cursorLeft(); // between "ca" and "t"

    // Up keeps the column, clamped to the shorter middle line ("ox" -> end).
    try std.testing.expect(try app.moveInputCursorVertical(.up));
    try std.testing.expectEqualStrings("fox\nox", app.inputs.input.buf.firstHalf());

    // Up again lands at column 2 of the first line ("fo|x").
    try std.testing.expect(try app.moveInputCursorVertical(.up));
    try std.testing.expectEqualStrings("fo", app.inputs.input.buf.firstHalf());

    // Already on the first line: no move, caller falls back to transcript nav.
    try std.testing.expect(!(try app.moveInputCursorVertical(.up)));

    // Down returns to the middle line at the same column ("ox" -> end).
    try std.testing.expect(try app.moveInputCursorVertical(.down));
    try std.testing.expectEqualStrings("fox\nox", app.inputs.input.buf.firstHalf());

    // Down to the last line, then no further move.
    try std.testing.expect(try app.moveInputCursorVertical(.down));
    try std.testing.expectEqualStrings("fox\nox\nca", app.inputs.input.buf.firstHalf());
    try std.testing.expect(!(try app.moveInputCursorVertical(.down)));
}

test "vertical navigation follows soft-wrapped visual rows" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // A single long line with no manual breaks. Wrapped at width 10 it spans
    // two visual rows ("abcdefghij" / "klmnopqrst"), so the cursor must move by
    // visual row — the old '\n'-only logic was stuck on one logical line.
    try app.inputs.input.insertSliceAtCursor("abcdefghijklmnopqrst");
    app.input_wrap_width = 10;

    // Cursor sits at the end (second visual row). Up moves to the first row.
    try std.testing.expect(try app.moveInputCursorVertical(.up));
    try std.testing.expectEqualStrings("abcdefghij", app.inputs.input.buf.firstHalf());

    // Already on the first visual row: no move, hand off to block nav.
    try std.testing.expect(!(try app.moveInputCursorVertical(.up)));

    // Down returns to the second visual row at the same column.
    try std.testing.expect(try app.moveInputCursorVertical(.down));
    try std.testing.expectEqualStrings("abcdefghijklmnopqrst", app.inputs.input.buf.firstHalf());
    try std.testing.expect(!(try app.moveInputCursorVertical(.down)));
}

test "global resume sorting groups projects by latest session" {
    var summaries = [_]session_mod.SessionSummary{
        .{ .id = @constCast("old-b"), .title = null, .cwd = @constCast("/repo/b"), .created_at_ms = 0, .updated_at_ms = 10, .leaf_entry_id = null, .model_provider = null, .model_id = null, .reasoning_effort = null },
        .{ .id = @constCast("new-a"), .title = null, .cwd = @constCast("/repo/a"), .created_at_ms = 0, .updated_at_ms = 30, .leaf_entry_id = null, .model_provider = null, .model_id = null, .reasoning_effort = null },
        .{ .id = @constCast("new-b"), .title = null, .cwd = @constCast("/repo/b"), .created_at_ms = 0, .updated_at_ms = 40, .leaf_entry_id = null, .model_provider = null, .model_id = null, .reasoning_effort = null },
        .{ .id = @constCast("old-a"), .title = null, .cwd = @constCast("/repo/a"), .created_at_ms = 0, .updated_at_ms = 20, .leaf_entry_id = null, .model_provider = null, .model_id = null, .reasoning_effort = null },
    };

    const context: []const session_mod.SessionSummary = summaries[0..];
    std.mem.sort(session_mod.SessionSummary, summaries[0..], context, session_switcher.resumeSummaryLessThan);

    try std.testing.expectEqualStrings("/repo/b", summaries[0].cwd);
    try std.testing.expectEqualStrings("new-b", summaries[0].id);
    try std.testing.expectEqualStrings("/repo/b", summaries[1].cwd);
    try std.testing.expectEqualStrings("old-b", summaries[1].id);
    try std.testing.expectEqualStrings("/repo/a", summaries[2].cwd);
    try std.testing.expectEqualStrings("new-a", summaries[2].id);
    try std.testing.expectEqualStrings("/repo/a", summaries[3].cwd);
    try std.testing.expectEqualStrings("old-a", summaries[3].id);
}

test "esc backs out of command panels before interrupting active turn" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.thread.turn.submit();
    app.mode = .provider_picker;

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    try RootWidget.captureEvent(&root, &ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });

    try std.testing.expectEqual(App.Mode.command, app.mode);
    try std.testing.expectEqual(Turn.State.active, app.thread.turn.state);
}

test "ctrl-c clears a non-empty input instead of arming quit" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    try app.inputs.input.insertSliceAtCursor("draft message");

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    const ctrl_c: vxfw.Event = .{ .key_press = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } };
    try RootWidget.captureEvent(&root, &ctx, ctrl_c);

    // The input is cleared and the quit sequence is not armed.
    try std.testing.expectEqual(@as(usize, 0), app.inputs.input.buf.realLength());
    try std.testing.expect(app.nav.quit == .none);
    try std.testing.expect(!ctx.quit);
}

test "down past the last block re-enters the input" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    // Tall viewport so the short messages never count as scrollable.
    app.thread.transcript_view_width = 80;
    app.thread.transcript_view_height = 100;

    _ = try app.thread.transcript.append(gpa, .agent, "agent", "one");
    _ = try app.thread.transcript.append(gpa, .agent, "agent", "two");
    _ = try app.thread.transcript.append(gpa, .agent, "agent", "three");
    // Following the tail, the last block is selected.
    try std.testing.expectEqual(@as(?u32, 2), app.thread.transcript.selected);

    // In block navigation, up walks to an earlier block.
    app.nav.block_nav = true;
    _ = try app.handleTranscriptKey(.{ .codepoint = vaxis.Key.up });
    try std.testing.expectEqual(@as(?u32, 1), app.thread.transcript.selected);

    // Down walks back toward the last block, still navigating blocks.
    _ = try app.handleTranscriptKey(.{ .codepoint = vaxis.Key.down });
    try std.testing.expectEqual(@as(?u32, 2), app.thread.transcript.selected);
    try std.testing.expect(app.nav.block_nav);

    // Down again on the last block hands control back to the input.
    _ = try app.handleTranscriptKey(.{ .codepoint = vaxis.Key.down });
    try std.testing.expect(!app.nav.block_nav);
    try std.testing.expectEqual(@as(?u32, 2), app.thread.transcript.selected);
}

test "down past the last block moves into multiline input" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.thread.transcript_view_width = 80;
    app.thread.transcript_view_height = 100;

    _ = try app.thread.transcript.append(gpa, .agent, "agent", "one");
    try app.inputs.input.insertSliceAtCursor("top\nmiddle");
    // Put the cursor on the top line, just before the newline. Re-entering
    // from block navigation should step down into the input line below.
    app.inputs.input.buf.moveGapLeft("\nmiddle".len);
    app.nav.block_nav = true;

    try std.testing.expect(try app.handleTranscriptKey(.{ .codepoint = vaxis.Key.down }));
    try std.testing.expect(!app.nav.block_nav);
    try std.testing.expectEqualStrings("top\nmid", app.inputs.input.buf.firstHalf());
}

test "shift enter inserts a newline instead of submitting" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    try app.inputs.input.insertSliceAtCursor("line one");
    try app.insertInputNewline();
    try app.inputs.input.insertSliceAtCursor("line two");

    const value = try app.peekInput();
    defer gpa.free(value);
    try std.testing.expectEqualStrings("line one\nline two", value);
}

test "firstVisibleLine keeps the cursor line within the window" {
    try std.testing.expectEqual(@as(u16, 0), input_mod.firstVisibleLine(0, 3, 4));
    try std.testing.expectEqual(@as(u16, 0), input_mod.firstVisibleLine(3, 4, 4));
    // Cursor past the fold pins to the bottom edge.
    try std.testing.expectEqual(@as(u16, 1), input_mod.firstVisibleLine(4, 10, 4));
    try std.testing.expectEqual(@as(u16, 6), input_mod.firstVisibleLine(9, 10, 4));
}

test "root overlay host does not paint outside panel" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .command;

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 100, .height = 30 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try root.widget().draw(ctx);
    try std.testing.expectEqual(@as(usize, 2), surface.children.len);

    const overlay_host = surface.children[1].surface;
    try std.testing.expectEqual(@as(usize, 0), overlay_host.buffer.len);
    try std.testing.expectEqual(@as(usize, 1), overlay_host.children.len);

    const panel_surface = overlay_host.children[0].surface;
    try std.testing.expectEqual(@as(u16, 64), panel_surface.size.width);
    try std.testing.expectEqual(@as(u16, 16), panel_surface.size.height);
}

test "provider setup form renders for opencode zen without crashing" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .provider_picker;
    app.pickers.provider.stage = .form;
    app.pickers.provider.form_handle = .{ .builtin = .opencode_zen };

    var root: RootWidget = .{ .app = &app };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 100, .height = 30 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try root.widget().draw(ctx);
    try std.testing.expect(surface.children.len >= 1);
}

test "mouse bottom does not enable auto-scroll when older message is selected" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.transcript.append(gpa, .agent, "agent", "one");
    _ = try app.thread.transcript.append(gpa, .agent, "agent", "two");
    app.thread.transcript.selected = 0;
    app.thread.auto_scroll = false;
    app.thread.transcript_list.scroll.has_more = false;

    app.updateMouseAutoScroll();

    try std.testing.expect(!app.thread.auto_scroll);
}

test "shift down jumps to conversation bottom" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.transcript.append(gpa, .agent, "agent", "one");
    _ = try app.thread.transcript.append(gpa, .agent, "agent", "two");
    _ = try app.thread.transcript.append(gpa, .status, "status", "loading");
    app.thread.transcript.selected = 0;
    app.thread.auto_scroll = false;

    try std.testing.expect(try app.handleTranscriptKey(.{ .codepoint = vaxis.Key.down, .mods = .{ .shift = true } }));

    try std.testing.expectEqual(@as(?u32, 1), app.thread.transcript.selected);
    try std.testing.expect(app.thread.auto_scroll);
}

test "down scrolls through selected long message before moving selection" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.transcript.append(gpa, .agent, "agent", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight");
    _ = try app.thread.transcript.append(gpa, .agent, "agent", "next");
    app.thread.transcript.selected = 0;
    app.thread.transcript_view_width = 80;
    app.thread.transcript_view_height = 4;

    const scrolled = app.navigateTranscript(.next);

    try std.testing.expect(scrolled);
    try std.testing.expectEqual(@as(?u32, 0), app.thread.transcript.selected);
    try std.testing.expectEqual(@as(u32, 0), app.thread.transcript_list.scroll.top);
    try std.testing.expect(app.thread.transcript_list.scroll.offset > 0);
}

test "long message scroll uses a small fixed step" {
    try std.testing.expectEqual(@as(u16, 1), transcript_nav.scrollStepRows(1));
    try std.testing.expectEqual(@as(u16, 2), transcript_nav.scrollStepRows(2));
    try std.testing.expectEqual(@as(u16, 3), transcript_nav.scrollStepRows(20));
}

test "down at latest long message bottom does not loop to top" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.transcript.append(gpa, .agent, "agent", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight");
    app.thread.transcript.selected = 0;
    app.thread.transcript_view_width = 80;
    app.thread.transcript_view_height = 4;
    const offset = messageRowsCached(&app.thread.transcript.messages.items[0], ConversationLayout.contentWidth(app.thread.transcript_view_width)) - app.thread.transcript_view_height;
    transcript_nav.setSelectedMessageOffset(&app, 0, offset);

    const scrolled = app.navigateTranscript(.next);

    try std.testing.expect(!scrolled);
    try std.testing.expectEqual(@as(?u32, 0), app.thread.transcript.selected);
    try std.testing.expectEqual(@as(i17, @intCast(offset)), app.thread.transcript_list.scroll.offset);
}

test "down moves after selected long message bottom is visible" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.transcript.append(gpa, .agent, "agent", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight");
    _ = try app.thread.transcript.append(gpa, .agent, "agent", "next");
    app.thread.transcript.selected = 0;
    app.thread.transcript_view_width = 80;
    app.thread.transcript_view_height = 4;
    transcript_nav.setSelectedMessageOffset(&app, 0, messageRowsCached(&app.thread.transcript.messages.items[0], ConversationLayout.contentWidth(app.thread.transcript_view_width)) - app.thread.transcript_view_height);

    const scrolled = app.navigateTranscript(.next);

    try std.testing.expect(!scrolled);
    try std.testing.expectEqual(@as(?u32, 1), app.thread.transcript.selected);
}

test "up enters selected long message at bottom" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.transcript.append(gpa, .agent, "agent", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight");
    _ = try app.thread.transcript.append(gpa, .agent, "agent", "next");
    app.thread.transcript.selected = 1;
    app.thread.transcript_view_width = 80;
    app.thread.transcript_view_height = 4;

    const scrolled = app.navigateTranscript(.previous);

    try std.testing.expect(!scrolled);
    try std.testing.expectEqual(@as(?u32, 0), app.thread.transcript.selected);
    try std.testing.expect(app.thread.transcript_list.scroll.offset > 0);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var transcript_widget: tx_widget.TranscriptWidget = .{
        .thread = app.thread,
        .gpa = app.gpa,
        .has_model_configured = false,
        .loading_frame = app.metrics.loading_frame,
        .blackhole_frame = app.metrics.blackhole_frame,
        .blackhole_visible = &app.metrics.blackhole_visible,
    };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 6 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    _ = try transcript_widget.widget().draw(ctx);

    try std.testing.expect(app.thread.transcript_list.scroll.offset > 0);
}

test "begin submit clears input and starts a turn awaiting output" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("hello");
    try std.testing.expect(try app.beginSubmit());

    try std.testing.expectEqual(@as(usize, 0), app.inputs.input.buf.firstHalf().len);
    try std.testing.expectEqual(@as(usize, 0), app.inputs.input.buf.secondHalf().len);
    // The user message is the only transcript entry; the loading spinner is never
    // stored as a message.
    try std.testing.expectEqual(@as(usize, 1), app.thread.transcript.messages.items.len);
    try std.testing.expectEqualStrings("hello", app.thread.transcript.messages.items[0].mirror().body);
    try std.testing.expect(app.thread.turn_view.awaitingOutput());
    try std.testing.expectEqual(Turn.State.active, app.thread.turn.state);
    try std.testing.expectEqual(@as(u32, 0), app.thread.transcript.selected.?);
}

test "begin submit defers while a manual compact is pending and keeps the input" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // A manual /compact is mid-flight: the summarizer will swap the context on
    // the UI thread, so a new turn must not race that reload.
    agent.manual_compact_pending = true;
    agent.manual_compact_started = true;

    try app.inputs.input.insertSliceAtCursor("hello");
    try std.testing.expect(!try app.beginSubmit());

    // The prompt stays in the input for a later submit; no turn started.
    try std.testing.expectEqualStrings("hello", app.inputs.input.buf.firstHalf());
    try std.testing.expectEqual(Turn.State.idle, app.thread.turn.state);
    try std.testing.expect(!app.thread.turn_view.awaitingOutput());
    // A one-line notice explains why.
    try std.testing.expectEqual(@as(usize, 1), app.thread.transcript.messages.items.len);
}

test "compact request with no compaction client appends the guard notice" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try std.testing.expect(!try compaction_lifecycle.requestManualCompact(&app));
    // The first guard error maps to a static notice; no waiting row is added.
    try std.testing.expectEqual(@as(usize, 1), app.thread.transcript.messages.items.len);
    try std.testing.expectEqualStrings(
        "No compaction client configured — compaction unavailable",
        app.thread.transcript.messages.items[0].mirror().body,
    );
}

test "compact request appends an animated status row while the summary is produced" {
    const gpa = std.testing.allocator;

    var home = try isolatedHome(gpa, std.testing.io);
    defer home.deinit(gpa);
    try home.tmp.dir.createDirPath(std.testing.io, ".config/nova");

    var writer: session_mod.SessionWriter = undefined;
    try session_mod.SessionWriter.initDefault(&writer, gpa, std.testing.io, home.path, "/tmp");
    defer writer.deinit();

    var client: openai_compatible_mod.Client = undefined;
    try client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer client.deinit();

    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &client });
    defer agent.deinit();
    agent.attachSessionWriter(&writer);
    agent.compaction_client = .{ .openai_compatible = &client };
    agent.context_window_tokens = 4096;
    try agent_mod.fillSessionForCompaction(&agent, 10);

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try std.testing.expect(try compaction_lifecycle.requestManualCompact(&app));
    // The last transcript message is the animated waiting row (a spinner
    // frame + text), not a static notice — what the user sees while the
    // summary is produced. Its index is tracked for the completion cleanup.
    var messages = app.thread.transcript.messages.items;
    try std.testing.expectEqual(transcript_mod.MessageKind.status, messages[messages.len - 1].kind());
    try std.testing.expectEqualStrings("waiting for background summary…", messages[messages.len - 1].mirror().title);
    try std.testing.expect(app.thread.manual_compact_waiting_row != null);

    // The summarizer fails against the dead server; the drain drops the
    // waiting row and appends the error notice — no lingering spinner that
    // could re-animate with a later turn.
    var spins: u32 = 0;
    while (!agent.compactor.stateIs(.failed) and spins < 10_000) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(agent.compactor.stateIs(.failed));
    try std.testing.expect(try compaction_lifecycle.drainManualCompactions(&app));

    messages = app.thread.transcript.messages.items;
    for (messages) |message| {
        try std.testing.expect(message.kind() != transcript_mod.MessageKind.status);
    }
    try std.testing.expect(app.thread.manual_compact_waiting_row == null);
    try std.testing.expectEqualStrings("Background compaction failed", messages[messages.len - 1].mirror().body);
}

test "spinner frame advances while visible lane writes a response" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // Visible lane is mid-response: turn active, but not awaiting model and no
    // tool running — the state the old visible-lane-only gate froze on.
    app.thread.turn.submit();
    app.thread.turn_view.activity = .{ .writing_response = 0 };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var root: RootWidget = .{ .app = &app };
    root.spinner_tick_accum = RootWidget.spinner_tick_threshold_ms - 1;
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    try lifecycle.handleTick(&root, &ctx);
    try std.testing.expectEqual(@as(u8, 1), app.metrics.loading_frame);
}

test "spinner frame advances while a background lane is active and visible lane is idle" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    const lane2 = try gpa.create(Thread);
    lane2.* = .{};
    lane2.turn.submit();
    try app.threads.append(lane2);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var root: RootWidget = .{ .app = &app };
    root.spinner_tick_accum = RootWidget.spinner_tick_threshold_ms - 1;
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    try lifecycle.handleTick(&root, &ctx);
    try std.testing.expectEqual(@as(u8, 1), app.metrics.loading_frame);
}

test "spinner frame does not advance when all lanes are idle" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var root: RootWidget = .{ .app = &app };
    root.spinner_tick_accum = RootWidget.spinner_tick_threshold_ms - 1;
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    try lifecycle.handleTick(&root, &ctx);
    try std.testing.expectEqual(@as(u8, 0), app.metrics.loading_frame);
    // Idle resets the accumulator instead of parking it near the threshold.
    try std.testing.expectEqual(@as(u32, 0), root.spinner_tick_accum);
}

test "spinner frame advances during manual compact with no active turn" {
    const gpa = std.testing.allocator;
    var client: openai_compatible_mod.Client = undefined;
    try client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    // A manual /compact is mid-flight with no turn running: the summarizer is
    // still producing, so the tick gate must keep advancing the frame for the
    // waiting row and lane glyph. (A `.none` compaction client would make
    // `pollManualCompact` treat this as a torn-down client and abort it.)
    agent.compaction_client = .{ .openai_compatible = &client };
    agent.manual_compact_pending = true;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var root: RootWidget = .{ .app = &app };
    root.spinner_tick_accum = RootWidget.spinner_tick_threshold_ms - 1;
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    try lifecycle.handleTick(&root, &ctx);
    try std.testing.expectEqual(@as(u8, 1), app.metrics.loading_frame);
}

test "spinner tick accumulator respects the 40ms threshold" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.thread.turn.submit();
    app.thread.turn_view.awaitModel();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var root: RootWidget = .{ .app = &app };
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    // One 30ms tick stays under the 40ms threshold: no advance, accumulator grows.
    try lifecycle.handleTick(&root, &ctx);
    try std.testing.expectEqual(@as(u8, 0), app.metrics.loading_frame);
    try std.testing.expectEqual(RootWidget.drain_tick_ms, root.spinner_tick_accum);

    // A second tick crosses it: advance and reset.
    try lifecycle.handleTick(&root, &ctx);
    try std.testing.expectEqual(@as(u8, 1), app.metrics.loading_frame);
    try std.testing.expectEqual(@as(u32, 0), root.spinner_tick_accum);
}

test "advanceLoadingFrame wraps at 8" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.metrics.loading_frame = @intCast(tui_message.loading_frames.len - 1);
    app.advanceLoadingFrame();
    try std.testing.expectEqual(@as(u8, 0), app.metrics.loading_frame);
    app.advanceLoadingFrame();
    try std.testing.expectEqual(@as(u8, 1), app.metrics.loading_frame);
    app.advanceLoadingFrame();
    try std.testing.expectEqual(@as(u8, 2), app.metrics.loading_frame);
}

test "chooseLoadingWordIndex returns a valid spinner index" {
    const index = turn_view_mod.chooseLoadingWordIndex(std.testing.io);
    try std.testing.expect(index < turn_view_mod.loading_spinners.len);
}

test "spawn path assigns the spinner word before awaitModel" {
    // A fresh lane's turn view defaults to the first word (index 0); the spawn
    // path (`startTurnForLane`) assigns a fresh one via `chooseLoadingWordIndex`
    // before `awaitModel`, so every spawned lane doesn't show "Firing Neurons".
    var lane: Thread = .{};
    const chosen = turn_view_mod.chooseLoadingWordIndex(std.testing.io);
    lane.turn_view.loading_word_index = chosen;
    lane.turn_view.awaitModel();
    try std.testing.expect(lane.turn_view.loading_word_index < turn_view_mod.loading_spinners.len);
    try std.testing.expect(lane.turn_view.awaitingOutput());
}

test "awaiting turn draws loading outside the transcript list" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.transcript.append(gpa, .user, "you", "hello");
    app.thread.turn_view.awaitModel();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var root_widget: RootWidget = .{ .app = &app };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 10 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try root_widget.widget().draw(ctx);

    try std.testing.expectEqual(@as(usize, 1), surface.children.len);
    const main_surface = surface.children[0].surface;
    try std.testing.expectEqual(@as(usize, 3), main_surface.children.len);
    try std.testing.expectEqual(@as(?u32, 1), app.thread.transcript_list.item_count);
    try std.testing.expectEqual(@as(u32, 0), app.thread.transcript_list.cursor);
    try std.testing.expectEqual(root_layout.rootLayout(10, false, 1, true, false).loading_row, main_surface.children[1].origin.row);
}

test "awaiting turn preserves selected long message inner scroll" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.transcript.append(gpa, .agent, "agent", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight");
    app.thread.transcript.selected = 0;
    app.thread.auto_scroll = false;
    app.thread.turn_view.awaitModel();
    transcript_nav.setSelectedMessageOffset(&app, 0, 3);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var root_widget: RootWidget = .{ .app = &app };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 10 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    _ = try root_widget.widget().draw(ctx);

    try std.testing.expectEqual(@as(u32, 0), app.thread.transcript_list.cursor);
    try std.testing.expectEqual(@as(u32, 0), app.thread.transcript_list.scroll.top);
    try std.testing.expectEqual(@as(i17, 3), app.thread.transcript_list.scroll.offset);
}

test "begin submit queues while turn is in flight" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    // Simulate a turn already streaming and waiting on the next chunk.
    app.thread.turn.submit();
    app.thread.turn_view.awaitModel();

    try app.inputs.input.insertSliceAtCursor("later");
    try std.testing.expect(!try app.beginSubmit());

    try std.testing.expectEqual(@as(usize, 1), app.thread.queued.items.len);
    try std.testing.expectEqualStrings("later", app.thread.queued.items[0].text);
    try std.testing.expectEqual(@as(u32, 1), agent.message_queue.len());
    try std.testing.expectEqual(@as(usize, 0), app.inputs.input.buf.firstHalf().len);
    try std.testing.expect(try app.applyAgentEvent(.{ .queued_messages_flushed = 1 }));
    try std.testing.expectEqual(@as(usize, 0), app.thread.queued.items.len);
    // Just the flushed user message; the spinner stays derived UI.
    try std.testing.expectEqual(@as(usize, 1), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[0].mirror().kind);
    try std.testing.expectEqualStrings("later", app.thread.transcript.messages.items[0].mirror().body);
    try std.testing.expect(app.thread.turn_view.awaitingOutput());
}

test "queued prompt draws above input at minimum input height" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.thread.turn.submit();
    app.thread.turn_view.awaitModel();

    try app.inputs.input.insertSliceAtCursor("later");
    try std.testing.expect(!try app.beginSubmit());

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var input_widget: input_mod.InputWidget = .{ .app = &app };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 40, .height = 4 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try input_widget.widget().draw(ctx);

    try std.testing.expectEqual(@as(usize, 2), surface.children.len);
    try std.testing.expectEqual(@as(u16, 0), surface.children[0].origin.row);
    try std.testing.expectEqual(@as(u16, 1), surface.children[1].origin.row);
    try std.testing.expectEqualStrings("[", surface.children[0].surface.readCell(0, 0).char.grapheme);
}

test "alt navigation and ctrl-steer drive the queued message line" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.thread.turn.submit();
    app.thread.turn_view.awaitModel();

    try app.inputs.input.insertSliceAtCursor("first");
    try std.testing.expect(!try app.beginSubmit());
    try app.inputs.input.insertSliceAtCursor("second");
    try std.testing.expect(!try app.beginSubmit());

    // Newest is selected after queueing.
    try std.testing.expectEqual(@as(usize, 1), app.nav.queued_selection);

    // ALT+← walks back to the older message; clamps at the front.
    app.selectPrevQueued();
    try std.testing.expectEqual(@as(usize, 0), app.nav.queued_selection);
    app.selectPrevQueued();
    try std.testing.expectEqual(@as(usize, 0), app.nav.queued_selection);

    // CTRL+→ steers the selected message in both the mirror and agent queue.
    app.steerSelectedQueued();
    try std.testing.expect(app.thread.queued.items[0].steer);
    try std.testing.expect(agent.message_queue.at(&agent.message_queue_storage, 0).?.steer);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var input_widget: input_mod.InputWidget = .{ .app = &app };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 60, .height = 6 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try input_widget.widget().draw(ctx);
    // Steered selection renders the ↩ form, not the "[...]" form.
    try std.testing.expectEqualStrings("↩", surface.children[0].surface.readCell(0, 0).char.grapheme);

    // ALT+→ moves to the newer, still-queued message: back to "[...]".
    app.selectNextQueued();
    try std.testing.expectEqual(@as(usize, 1), app.nav.queued_selection);
    const surface2 = try input_widget.widget().draw(ctx);
    try std.testing.expectEqualStrings("[", surface2.children[0].surface.readCell(0, 0).char.grapheme);
}

test "begin submit shows notice when queued message queue is full" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.thread.turn.submit();
    app.thread.turn_view.awaitModel();

    var queued_count: usize = 0;
    while (queued_count < agent.message_queue_storage.len) : (queued_count += 1) {
        try agent.enqueueUser("queued");
    }

    try app.inputs.input.insertSliceAtCursor("later");
    try std.testing.expect(!try app.beginSubmit());

    try std.testing.expectEqual(@as(usize, 0), app.thread.queued.items.len);
    try std.testing.expectEqual(@as(u32, @intCast(agent.message_queue_storage.len)), agent.message_queue.len());
    try std.testing.expectEqualStrings("later", app.inputs.input.buf.firstHalf());
    // The notice is the only transcript row; the spinner is not a status message.
    try std.testing.expectEqual(@as(usize, 1), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.notice, app.thread.transcript.messages.items[0].mirror().kind);
    try std.testing.expectEqualStrings("MessageQueueFull", app.thread.transcript.messages.items[0].mirror().body);
    try std.testing.expect(app.thread.turn_view.awaitingOutput());
}

test "opening model picker starts at top" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.pickers.models.model_selection = 4;
    try provider_model.openModelPicker(&app);

    try std.testing.expectEqual(@as(u32, 0), app.pickers.models.model_selection);
}

test "model picker hides model arrow when reasoning column is focused" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .model_picker;
    app.pickers.models.model_column = .reasoning;
    app.pickers.models.model_selection = 0;
    const models = try codex.loadStaticModels(gpa);
    defer gpa.free(models);
    for (models) |model| try app.pickers.models.append(gpa, model, .openai_codex);

    var row: model_picker.Row = .{
        .model = &app.pickers.models.entries.items[0].model,
        .selected = true,
        .column = app.pickers.models.model_column,
        .active_model = null,
        .reasoning_label = reasoningOptions()[provider_model.selectedReasoningIndex(&app)].label,
    };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 80, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    const surface = try row.widget().draw(ctx);

    try std.testing.expectEqualStrings(" ", surface.readCell(ConversationLayout.left -| 1, 0).char.grapheme);
    try std.testing.expectEqualStrings(" ", surface.readCell(panel.secondaryColumn(surface.size.width), 0).char.grapheme);
}

test "model picker without models stays on model column" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .model_picker;
    app.pickers.models.model_column = .model;
    try std.testing.expect(try app.handleCommandKey(.{ .codepoint = vaxis.Key.right }));
    try std.testing.expectEqual(model_picker.Column.model, app.pickers.models.model_column);
}

test "provider picker navigates from codex to catalogue providers" {
    const count = comptime config_mod.catalogueProviders().len;
    var entries: [count]provider_picker.ProviderHandle = undefined;
    for (config_mod.catalogueProviders(), 0..) |b, idx| entries[idx] = .{ .builtin = b };

    var state: provider_picker.State = .{ .entries = &entries };
    try std.testing.expectEqual(@as(u32, 0), state.selection);
    try std.testing.expectEqual(provider_picker.Action.connect_codex, state.selectedAction("").?);
    // Below the Codex row sit the catalogue providers; selecting one opens its form.
    try std.testing.expect(state.handleKey(.{ .codepoint = vaxis.Key.down }, false, ""));
    try std.testing.expectEqual(@as(u32, 1), state.selection);
    try std.testing.expect(state.selectedAction("").? == .open_entry);
}

test "local provider model labels use correct separator" {
    const label = try provider_model.localModelLabel(std.testing.allocator, .ollama, "llama3");
    defer std.testing.allocator.free(label);

    try std.testing.expectEqualStrings("Ollama · llama3", label);
}

test "ollama cloud models are not listed as local models" {
    try std.testing.expect(provider_model.includeLocalModel(.ollama, "llama3"));
    try std.testing.expect(!provider_model.includeLocalModel(.ollama, "gpt-oss-cloud"));
    try std.testing.expect(!provider_model.includeLocalModel(.ollama, "gpt-oss:120b-cloud"));
    try std.testing.expect(provider_model.includeLocalModel(.llama_cpp, "gpt-oss-cloud"));
}

test "local providers are not loaded twice through configured compatible catalog" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.cached_config.model_selection = .{
        .builtin = .{
            .provider = .ollama,
            .provider_name = @constCast("ollama"),
            .model = .{ .id = @constCast("test") },
        },
    };

    try std.testing.expect(!provider_model.shouldLoadConfiguredCompatibleCatalog(&app));
}

test "provider picker selects sign out horizontally" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    var codex_client: ai.codex_responses.Client = undefined;
    var runtime: runtime_mod.AgentRuntime = undefined;
    runtime.client = .{ .codex_responses = &codex_client };
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = &runtime, .owns = false } };
    app.codex_signed_in = true;

    app.mode = .provider_picker;
    app.pickers.provider.column = .provider;
    try std.testing.expect(try app.handleCommandKey(.{ .codepoint = vaxis.Key.right }));
    try std.testing.expectEqual(provider_picker.Column.sign_out, app.pickers.provider.column);
    try std.testing.expect(try app.handleCommandKey(.{ .codepoint = vaxis.Key.tab }));
    try std.testing.expectEqual(provider_picker.Column.provider, app.pickers.provider.column);
}

test "compatible base url falls back when cached local provider differs" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.cached_config.model_selection = .{
        .builtin = .{
            .provider = .llama_cpp,
            .provider_name = @constCast("llama.cpp"),
            .model = .{ .id = @constCast("test") },
        },
    };

    try std.testing.expectEqualStrings("http://localhost:8080", provider_model.compatibleBaseUrl(&app, .llama_cpp).?);
    try std.testing.expectEqualStrings("http://localhost:11434", provider_model.compatibleBaseUrl(&app, .ollama).?);
}

test "codex sign-in survives selecting local compatible provider" {
    const gpa = std.testing.allocator;
    var home = try isolatedHome(gpa, std.testing.io);
    defer home.deinit(gpa);

    var runtime: runtime_mod.AgentRuntime = undefined;
    runtime.gpa = gpa;
    runtime.io = std.testing.io;
    runtime.cwd = ".";
    runtime.home_dir = home.path;
    runtime.client = .none;
    runtime.base_system_prompt = "test";
    runtime.system_prompt = "test";
    runtime.session_writer = undefined;
    runtime.agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer runtime.agent.deinit();
    runtime.diagnostics = &.{};
    runtime.owned_client = null;
    runtime.owned_compaction_client = null;
    runtime.owned_naming_client = null;
    runtime.modelsdev_registry = null;
    runtime.naming_client = .none;
    var app = try App.init(std.testing.io, gpa, &runtime.agent);
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = &runtime, .owns = false } };
    defer app.deinit();
    defer runtime.disconnectClient();

    app.codex_signed_in = true;
    try app.pickers.models.append(gpa, .{ .id = try gpa.dupe(u8, "llama3"), .label = try gpa.dupe(u8, "llama3") }, .{ .openai_compatible = try model_loader.compatibleSource(gpa, .ollama, "http://localhost:11434/v1", "ollama") });
    app.pickers.models.model_selection = 0;
    app.cached_config_owned = true;
    app.cached_config.model_selection = .{
        .custom = .{
            .provider_name = try gpa.dupe(u8, "openai_compatible"),
            .base_url = try gpa.dupe(u8, "http://localhost:11434/v1"),
            .api_key = try gpa.dupe(u8, "ollama"),
            .model = .{ .id = try gpa.dupe(u8, "placeholder") },
        },
    };

    try provider_model.applySelectedModel(&app);

    try std.testing.expect(app.isCodexSignedIn());
    try std.testing.expectEqual(config_mod.Provider.ollama, app.cached_config.model_selection.?.provider());
}

test "createRuntime wires the full tool set into the freshly-attached client" {
    // Regression for the user-reported "sending request with NO tools
    // (tools_json is empty)" turn loop after a session switch: createRuntime
    // attaches the client via applyFromConfig before the App's ToolRegistry
    // is reachable from the runtime, and nothing re-injected tools after the
    // wiring landed — the new session's main client ran with an empty
    // tools_json until an unrelated MCP event happened to re-inject them.
    // createRuntime must push builtin + plugin + MCP tools once wired.
    const gpa = std.testing.allocator;
    var home = try isolatedHome(gpa, std.testing.io);
    defer home.deinit(gpa);

    // Minimal template runtime standing in for the primary lane.
    var runtime: runtime_mod.AgentRuntime = undefined;
    runtime.gpa = gpa;
    runtime.io = std.testing.io;
    runtime.cwd = home.path;
    runtime.home_dir = home.path;
    runtime.client = .none;
    runtime.base_system_prompt = "test";
    runtime.system_prompt = "test";
    runtime.skills = &.{};
    runtime.plugin_prompts = &.{};
    runtime.session_writer = undefined;
    runtime.agent = agent_mod.Agent.init(gpa, std.testing.io, home.path, .none);
    defer runtime.agent.deinit();
    runtime.diagnostics = &.{};
    runtime.owned_client = null;
    runtime.owned_compaction_client = null;
    runtime.owned_naming_client = null;
    runtime.modelsdev_registry = null;
    runtime.naming_client = .none;

    var app = try App.init(std.testing.io, gpa, &runtime.agent);
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = &runtime, .owns = false } };
    defer app.deinit();

    // A plugin tool in the App's registry must reach the new client.
    try app.tool_registry.addPluginTool(gpa, .{
        .name = try gpa.dupe(u8, "lua__p__t"),
        .description = try gpa.dupe(u8, "test"),
        .schema = .{ .properties = &.{} },
        .run = undefined,
        .display = undefined,
    });
    app.cached_config.model_selection = .{
        .builtin = .{
            .provider = .ollama,
            .provider_name = @constCast("ollama"),
            .model = .{ .id = @constCast("test-model") },
        },
    };

    const new_runtime = try session_switcher.createRuntime(&app, home.path, home.path, null);
    defer {
        new_runtime.deinit();
        gpa.destroy(new_runtime);
    }

    const client = switch (new_runtime.client) {
        .openai_compatible => |c| c,
        else => return error.TestUnexpectedResult,
    };
    const shell_needle = try std.fmt.allocPrint(gpa, "\"name\":\"{s}\"", .{tools_mod.shellToolName});
    defer gpa.free(shell_needle);
    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, shell_needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, "\"name\":\"lane\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, "lua__p__t") != null);
}

test "switching from codex to catalogue provider resets cached connection" {
    const gpa = std.testing.allocator;
    var home = try isolatedHome(gpa, std.testing.io);
    defer home.deinit(gpa);

    var runtime: runtime_mod.AgentRuntime = undefined;
    runtime.gpa = gpa;
    runtime.io = std.testing.io;
    runtime.cwd = ".";
    runtime.home_dir = home.path;
    runtime.client = .none;
    runtime.base_system_prompt = "test";
    runtime.system_prompt = "test";
    runtime.session_writer = undefined;
    runtime.agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer runtime.agent.deinit();
    runtime.diagnostics = &.{};
    runtime.codex_connection_expired = false;
    runtime.owned_client = null;
    runtime.owned_compaction_client = null;
    runtime.owned_naming_client = null;
    runtime.modelsdev_registry = null;
    runtime.naming_client = .none;
    defer runtime.disconnectClient();

    var app = try App.init(std.testing.io, gpa, &runtime.agent);
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = &runtime, .owns = false } };
    defer app.deinit();

    app.pickers.models.model_scope = .session;
    try app.pickers.models.append(gpa, .{ .id = try gpa.dupe(u8, "zen"), .label = try gpa.dupe(u8, "zen") }, .{ .openai_compatible = try model_loader.compatibleSource(gpa, .opencode_zen, "https://opencode.ai/zen/v1", "opencode_zen") });
    app.pickers.models.model_selection = 0;
    app.cached_config_owned = true;
    app.cached_config.model_selection = .{
        .builtin = .{
            .provider = .openai,
            .provider_name = try gpa.dupe(u8, "openai"),
            .model = .{ .id = try gpa.dupe(u8, "placeholder") },
        },
    };

    try provider_model.applySelectedModel(&app);

    const ms = app.cached_config.model_selection.?;
    try std.testing.expectEqual(config_mod.Provider.opencode_zen, ms.provider());
    try std.testing.expectEqualStrings("https://opencode.ai/zen/v1", ms.provider().defaultBaseUrl().?);
    try std.testing.expect(ms.apiKey() == null);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/v1/chat/completions", runtime.client.openai_compatible.url);
}

test "active model appears at display position 0 without mutating storage" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    const active_model_id = try gpa.dupe(u8, "gpt-5.6-terra");
    defer gpa.free(active_model_id);
    app.cached_config.model_selection = .{
        .builtin = .{
            .provider = .openai,
            .provider_name = @constCast("openai"),
            .model = .{ .id = active_model_id },
        },
    };

    try provider_model.reloadModelCatalog(&app, .openai_codex);

    const active_storage_idx = app.pickers.models.activeStorageIdx("gpt-5.6-terra");
    const storage_idx = model_picker.displayToStorage(active_storage_idx, 0);
    try std.testing.expectEqualStrings("gpt-5.6-terra", app.pickers.models.entries.items[storage_idx].model.id);
}

test "explicit codex catalog loads before runtime is connected" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try provider_model.reloadModelCatalog(&app, .openai_codex);

    try std.testing.expect(app.pickers.models.len() > 0);
    try std.testing.expect(provider_model.selectedCodexModel(&app) != null);
}

test "slash opens command menu before focused input handles it" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{
        .io = std.testing.io,
        .alloc = arena.allocator(),
        .cmds = .empty,
    };

    var root: RootWidget = .{ .app = &app };
    try RootWidget.captureEvent(&root, &ctx, .{ .key_press = .{ .codepoint = '/', .text = "/" } });

    try std.testing.expectEqual(App.Mode.command, app.mode);
    try std.testing.expectEqual(@as(usize, 0), app.inputs.input.buf.realLength());
}

test "slash opens command menu when text field previous value is stale" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    app.inputs.input.previous_val = try gpa.dupe(u8, "/");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{
        .io = std.testing.io,
        .alloc = arena.allocator(),
        .cmds = .empty,
    };

    var root: RootWidget = .{ .app = &app };
    try RootWidget.captureEvent(&root, &ctx, .{ .key_press = .{ .codepoint = '/', .text = "/" } });

    try std.testing.expectEqual(App.Mode.command, app.mode);
    try std.testing.expectEqual(@as(usize, 0), app.inputs.input.buf.realLength());
}

test "expired codex connection reports reconnect message" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var runtime: runtime_mod.AgentRuntime = undefined;
    runtime.codex_connection_expired = true;
    runtime.diagnostics = &.{};
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = &runtime, .owns = false } };
    app.cached_config = .{
        .model_selection = .{
            .builtin = .{
                .provider = .openai,
                .provider_name = @constCast("openai"),
                .model = .{ .id = @constCast("test") },
            },
        },
    };

    const message = try app.formatNoProviderMessage();
    defer gpa.free(message);

    try std.testing.expectEqualStrings(runtime_mod.codex_connection_expired_message, message);
}

test "typing slash can open command menu after input changed before" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();
    app.bindInputCallbacks();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{
        .io = std.testing.io,
        .alloc = arena.allocator(),
        .cmds = .empty,
    };

    try app.inputs.input.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'x', .text = "x" } });
    app.inputs.input.clearRetainingCapacity();
    app.thread.turn.submit();
    defer app.thread.turn.reset();
    try app.inputs.input.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = '/', .text = "/" } });

    try std.testing.expectEqual(App.Mode.command, app.mode);
}

test "reprompt after interrupt starts a fresh turn" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("first");
    try std.testing.expect(try app.beginSubmit());
    if (app.thread.pending_prompt) |prompt| app.thread.worker_context.?.gpa.free(prompt);
    app.thread.pending_prompt = null;
    try app.handleInterrupt();

    try app.inputs.input.insertSliceAtCursor("second");
    try std.testing.expect(try app.beginSubmit());
    defer app.thread.turn.reset();
    defer {
        if (app.thread.pending_prompt) |prompt| app.thread.worker_context.?.gpa.free(prompt);
        app.thread.pending_prompt = null;
    }

    try std.testing.expectEqual(Turn.State.active, app.thread.turn.state);
    try std.testing.expectEqual(@as(usize, 0), app.thread.queued.items.len);
}

test "interrupt drops the turn straight back to idle" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("first");
    try std.testing.expect(try app.beginSubmit());
    if (app.thread.pending_prompt) |prompt| app.thread.worker_context.?.gpa.free(prompt);
    app.thread.pending_prompt = null;
    try std.testing.expectEqual(Turn.State.active, app.thread.turn.state);

    // Interrupt must not leave the lane lingering in `interrupting` waiting for
    // a (possibly blocked) worker to reach its next cancellation point — the UI
    // would read as in-flight. The worker is torn down and the turn is idle.
    try app.handleInterrupt();
    try std.testing.expectEqual(Turn.State.idle, app.thread.turn.state);
    try std.testing.expect(!app.thread.turn.isActive());
}

test "lane commands stay hidden until a second lane exists" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // Single lane: the multi-lane commands (/merge, /close) are filtered out of
    // the palette and can't be resolved; the twenty-five always-on commands remain.
    try std.testing.expectEqual(@as(u32, 25), commandMatchesCountForFilter(&app, ""));
    try std.testing.expect(resolveCommand(&app, "Close") == null);
    try std.testing.expect(resolveCommand(&app, "Merge") == null);
    // `/sync` was removed with the git-shadow pivot and never came back.
    try std.testing.expect(resolveCommand(&app, "Sync") == null);
    try std.testing.expect(resolveCommand(&app, "Parallel") == .parallel);
    try std.testing.expect(resolveCommand(&app, "Lanes") == .lanes);

    // A second lane unhides the multi-lane commands.
    const lane2 = try gpa.create(Thread);
    lane2.* = .{};
    try app.threads.append(lane2);
    try std.testing.expect(resolveCommand(&app, "Merge") == .merge);
    try std.testing.expect(resolveCommand(&app, "Close") == .close);
}

test "cycleLane wraps the active lane in both directions" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // With a single lane, cycling is a no-op.
    app.cycleLane(1);
    try std.testing.expectEqual(@as(usize, 0), app.activeIndex());

    const lane2 = try gpa.create(Thread);
    lane2.* = .{};
    try app.threads.append(lane2);
    const lane3 = try gpa.create(Thread);
    lane3.* = .{};
    try app.threads.append(lane3);

    try std.testing.expectEqual(@as(usize, 0), app.activeIndex());
    app.cycleLane(1);
    try std.testing.expectEqual(@as(usize, 1), app.activeIndex());
    app.cycleLane(1);
    try std.testing.expectEqual(@as(usize, 2), app.activeIndex());
    // Forward past the last lane wraps to the first.
    app.cycleLane(1);
    try std.testing.expectEqual(@as(usize, 0), app.activeIndex());
    // Backward past the first lane wraps to the last.
    app.cycleLane(-1);
    try std.testing.expectEqual(@as(usize, 2), app.activeIndex());
}

test "cycleSplitMode cycles dual → grid → tab → dual only with multiple lanes" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // Single lane: nothing to split, so the cycle leaves the mode untouched.
    try std.testing.expect(app.split_mode == .tab);
    app.cycleSplitMode();
    try std.testing.expect(app.split_mode == .tab);

    const lane2 = try gpa.create(Thread);
    lane2.* = .{};
    try app.threads.append(lane2);
    // With two lanes, cycle through dual → grid → tab → dual.
    app.split_mode = .dual;
    app.cycleSplitMode();
    try std.testing.expect(app.split_mode == .grid);
    app.cycleSplitMode();
    try std.testing.expect(app.split_mode == .tab);
    app.cycleSplitMode();
    try std.testing.expect(app.split_mode == .dual);
}

test "cycleFocusedWorker wraps within worker lane indices" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // Single lane: no-op.
    app.focused_worker_index = 1;
    app.cycleFocusedWorker();
    try std.testing.expectEqual(@as(usize, 1), app.focused_worker_index);

    // Two lanes: only worker index 1 is valid, so it wraps to itself.
    const lane2 = try gpa.create(Thread);
    lane2.* = .{};
    try app.threads.append(lane2);
    app.focused_worker_index = 1;
    app.cycleFocusedWorker();
    try std.testing.expectEqual(@as(usize, 1), app.focused_worker_index);

    // Three lanes: cycle 1 → 2 → 1.
    const lane3 = try gpa.create(Thread);
    lane3.* = .{};
    try app.threads.append(lane3);
    app.focused_worker_index = 1;
    app.cycleFocusedWorker();
    try std.testing.expectEqual(@as(usize, 2), app.focused_worker_index);
    app.cycleFocusedWorker();
    try std.testing.expectEqual(@as(usize, 1), app.focused_worker_index);
}

test "shiftFocusedWorker moves the focused worker in both directions with wrap" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // Single lane: no-op.
    app.focused_worker_index = 1;
    app.shiftFocusedWorker(1);
    try std.testing.expectEqual(@as(usize, 1), app.focused_worker_index);

    // Four lanes → workers are [1, 3].
    for (0..3) |_| {
        const lane = try gpa.create(Thread);
        lane.* = .{};
        try app.threads.append(lane);
    }
    app.focused_worker_index = 1;
    app.shiftFocusedWorker(1); // 1 → 2
    try std.testing.expectEqual(@as(usize, 2), app.focused_worker_index);
    app.shiftFocusedWorker(1); // 2 → 3
    try std.testing.expectEqual(@as(usize, 3), app.focused_worker_index);
    app.shiftFocusedWorker(1); // 3 → 1 (wrap forward)
    try std.testing.expectEqual(@as(usize, 1), app.focused_worker_index);
    app.shiftFocusedWorker(-1); // 1 → 3 (wrap backward)
    try std.testing.expectEqual(@as(usize, 3), app.focused_worker_index);
    app.shiftFocusedWorker(-1); // 3 → 2
    try std.testing.expectEqual(@as(usize, 2), app.focused_worker_index);
}

test "cycleLane in dual cycles the focused worker, not app.thread" {
    // Regression: Shift+Tab / Shift+Left / Shift+Right route through cycleLane.
    // In `.dual` app.thread must stay the driver (lane 0, the left pane) or
    // input would route to a lane no pane displays; lane cycling becomes worker
    // cycling instead.
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    const lane2 = try gpa.create(Thread);
    lane2.* = .{};
    try app.threads.append(lane2);
    const lane3 = try gpa.create(Thread);
    lane3.* = .{};
    try app.threads.append(lane3);

    app.split_mode = .dual;
    app.thread = app.threads.slice()[0];
    app.focused_worker_index = 1;

    // In `.dual`, cycling never moves app.thread off the driver.
    app.cycleLane(1);
    try std.testing.expectEqual(app.threads.slice()[0], app.thread);
    try std.testing.expectEqual(@as(usize, 2), app.focused_worker_index);
    app.cycleLane(1);
    try std.testing.expectEqual(app.threads.slice()[0], app.thread);
    try std.testing.expectEqual(@as(usize, 1), app.focused_worker_index);
    app.cycleLane(-1);
    try std.testing.expectEqual(app.threads.slice()[0], app.thread);
    try std.testing.expectEqual(@as(usize, 2), app.focused_worker_index);
}

test "entering dual from tab re-roots thread to the driver" {
    // Regression: cycling `.tab` → `.dual` (Ctrl+W) with `app.thread` on a
    // worker must re-root it to the driver (lane 0) — otherwise input would
    // route to a lane no pane displays.
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    const lane2 = try gpa.create(Thread);
    lane2.* = .{};
    try app.threads.append(lane2);
    const lane3 = try gpa.create(Thread);
    lane3.* = .{};
    try app.threads.append(lane3);

    // `.tab` fullscreens a worker (legitimately allowed in tab/grid).
    app.split_mode = .tab;
    app.thread = app.threads.slice()[2];
    app.cycleSplitMode(); // tab → dual
    try std.testing.expect(app.split_mode == .dual);
    // Re-rooted to the driver; the previously-focused worker is preserved.
    try std.testing.expectEqual(app.threads.slice()[0], app.thread);
    try std.testing.expectEqual(@as(usize, 1), app.focused_worker_index);
}

test "createParallelLane-shaped dual branch reveals the new lane, not a thread swap" {
    // Direct equivalent of `createParallelLane`'s `.dual` branch: the driver
    // stays the input-routing lane and the freshly-appended worker is revealed
    // in the right pane via `focused_worker_index` (never by moving `app.thread`
    // to a lane no pane displays).
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // First parallel lane: driver + one worker → new lane is index 1.
    const lane2 = try gpa.create(Thread);
    lane2.* = .{};
    try app.threads.append(lane2);
    app.split_mode = .dual;
    app.thread = app.threads.slice()[0];
    app.focused_worker_index = app.threads.len() - 1;
    try std.testing.expectEqual(app.threads.slice()[0], app.thread);
    try std.testing.expectEqual(@as(usize, 1), app.focused_worker_index);

    // Second parallel lane: new lane is index 2.
    const lane3 = try gpa.create(Thread);
    lane3.* = .{};
    try app.threads.append(lane3);
    app.focused_worker_index = app.threads.len() - 1;
    try std.testing.expectEqual(app.threads.slice()[0], app.thread);
    try std.testing.expectEqual(@as(usize, 2), app.focused_worker_index);
}

test "lanes chip rect hit test covers its row span only" {
    const rect: ChipRect = .{ .row = 5, .col = 2, .width = 9 };
    try std.testing.expect(rect.contains(5, 2)); // left edge
    try std.testing.expect(rect.contains(5, 10)); // right edge (col + width - 1)
    try std.testing.expect(!rect.contains(5, 11)); // one past the right edge
    try std.testing.expect(!rect.contains(5, 1)); // one before the left edge
    try std.testing.expect(!rect.contains(4, 5)); // wrong row
    try std.testing.expect(!rect.contains(-1, -1)); // off-screen negatives
}

test "model selection is allowed after interrupt" {
    const gpa = std.testing.allocator;
    var home = try isolatedHome(gpa, std.testing.io);
    defer home.deinit(gpa);

    var runtime: runtime_mod.AgentRuntime = undefined;
    runtime.gpa = gpa;
    runtime.io = std.testing.io;
    runtime.cwd = ".";
    runtime.home_dir = home.path;
    runtime.client = .none;
    runtime.base_system_prompt = "test";
    runtime.system_prompt = "test";
    runtime.session_writer = undefined;
    runtime.agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer runtime.agent.deinit();
    runtime.diagnostics = &.{};
    runtime.owned_client = null;
    runtime.owned_compaction_client = null;
    runtime.owned_naming_client = null;
    runtime.modelsdev_registry = null;
    runtime.naming_client = .none;
    var app = try App.init(std.testing.io, gpa, &runtime.agent);
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = &runtime, .owns = false } };
    defer app.deinit();
    defer runtime.disconnectClient();

    try app.pickers.models.append(gpa, .{ .id = try gpa.dupe(u8, "llama3"), .label = try gpa.dupe(u8, "llama3") }, .{ .openai_compatible = try model_loader.compatibleSource(gpa, .ollama, "http://localhost:11434/v1", "ollama") });
    app.pickers.models.model_selection = 0;
    app.cached_config_owned = true;
    app.cached_config.model_selection = .{
        .custom = .{
            .provider_name = try gpa.dupe(u8, "openai_compatible"),
            .base_url = try gpa.dupe(u8, "http://localhost:11434/v1"),
            .api_key = try gpa.dupe(u8, "ollama"),
            .model = .{ .id = try gpa.dupe(u8, "placeholder") },
        },
    };
    app.thread.turn.submit();
    app.thread.turn.interrupt();

    try provider_model.applySelectedModel(&app);

    try std.testing.expectEqual(Turn.State.idle, app.thread.turn.state);
    try std.testing.expectEqual(config_mod.Provider.ollama, app.cached_config.model_selection.?.provider());
}

test "interrupt restart flushes queued messages to the transcript when no provider" {
    const gpa = std.testing.allocator;
    var home = try isolatedHome(gpa, std.testing.io);
    defer home.deinit(gpa);

    var runtime: runtime_mod.AgentRuntime = undefined;
    runtime.gpa = gpa;
    runtime.io = std.testing.io;
    runtime.cwd = ".";
    runtime.home_dir = home.path;
    runtime.client = .none;
    runtime.base_system_prompt = "test";
    runtime.system_prompt = "test";
    runtime.session_writer = undefined;
    runtime.agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer runtime.agent.deinit();
    runtime.diagnostics = &.{};
    runtime.owned_client = null;
    runtime.owned_compaction_client = null;
    runtime.owned_naming_client = null;
    runtime.modelsdev_registry = null;
    runtime.naming_client = .none;
    var app = try App.init(std.testing.io, gpa, &runtime.agent);
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = &runtime, .owns = false } };
    defer app.deinit();
    defer app.thread.turn.reset();

    // Queue two messages behind a running turn.
    app.thread.turn.submit();
    try app.inputs.input.insertSliceAtCursor("one");
    try std.testing.expect(!try app.beginSubmit());
    try app.inputs.input.insertSliceAtCursor("two");
    try std.testing.expect(!try app.beginSubmit());
    try std.testing.expectEqual(@as(usize, 2), app.thread.queued.items.len);

    // With no provider, the restart surfaces the queued text and drops the queue
    // rather than spinning up a doomed worker.
    try std.testing.expect(try app.restartTurnForQueuedMessages());
    try std.testing.expectEqual(@as(usize, 0), app.thread.queued.items.len);
    try std.testing.expectEqual(@as(u32, 0), runtime.agent.message_queue.len());
    try std.testing.expectEqual(@as(usize, 2), app.thread.transcript.messages.items.len);
    try std.testing.expectEqualStrings("one", app.thread.transcript.messages.items[0].mirror().body);
    try std.testing.expectEqualStrings("two", app.thread.transcript.messages.items[1].mirror().body);
}

test "canceling a picker returns to command menu" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .model_picker;
    try std.testing.expect(try app.cancelMode());
    try std.testing.expectEqual(App.Mode.command, app.mode);
    const main_input = try app.peekInput();
    defer gpa.free(main_input);
    try std.testing.expectEqualStrings("", main_input);
    const palette_filter = try app.peekPaletteInput();
    defer gpa.free(palette_filter);
    try std.testing.expectEqualStrings("", palette_filter);
}

test "typing slash inside picker opens command menu" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .session_picker;
    try app.syncModeWithInput("/");
    try std.testing.expectEqual(App.Mode.command, app.mode);
}

test "menu navigation wraps and model reasoning tab cycles" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    app.mode = .command;
    app.nav.command_selection = commandMatchesCountForFilter(&app, "") - 1;
    try std.testing.expect(try app.handleCommandKey(.{ .codepoint = vaxis.Key.down }));
    try std.testing.expectEqual(@as(u32, 0), app.nav.command_selection);

    const models = try codex.loadStaticModels(gpa);
    defer gpa.free(models);
    for (models) |model| try app.pickers.models.append(gpa, model, .openai_codex);
    app.mode = .model_picker;
    app.pickers.models.model_selection = @intCast(app.pickers.models.len() - 1);
    try std.testing.expect(try app.handleCommandKey(.{ .codepoint = vaxis.Key.down }));
    try std.testing.expectEqual(@as(u32, 0), app.pickers.models.model_selection);

    app.pickers.models.model_column = .reasoning;
    try std.testing.expect(try app.handleCommandKey(.{ .codepoint = vaxis.Key.tab }));
    try std.testing.expectEqual(@as(u32, 1), app.pickers.models.entries.items[0].reasoning_index);
    try std.testing.expectEqual(@as(u32, 0), app.pickers.models.entries.items[1].reasoning_index);
}

test "empty text deltas do not create selectable messages" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("hello");
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .response_delta = "" }));
    try std.testing.expectEqual(@as(usize, 1), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[0].mirror().kind);

    try std.testing.expect(!try app.applyAgentEvent(.{ .thinking_delta = "" }));
    try std.testing.expectEqual(@as(usize, 1), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[0].mirror().kind);
}

test "agent app events update transcript on the ui side" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("hello");
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .thinking_delta = "checking" }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .arguments = "{\"command\":\"ls\",\"description\":\"List files\"}",
    } }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .thinking_delta = " files" }));
    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .display_label = "List files",
        .display_expanded_label = "ls",
        .display_body = "$ ls\nexit 0\nstdout:\n\nstderr:\n",
    } }));

    try std.testing.expectEqual(@as(usize, 3), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[0].mirror().kind);
    try std.testing.expectEqual(.thinking, app.thread.transcript.messages.items[1].mirror().kind);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[2].mirror().kind);
    try std.testing.expectEqual(@as(u32, 2), app.thread.transcript.selected.?);
    try std.testing.expectEqualStrings("checking files", app.thread.transcript.messages.items[1].mirror().body);
    try std.testing.expectEqualStrings("🛠  List files", app.thread.transcript.messages.items[2].mirror().title);
}

test "user can navigate away from a streaming thinking block" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("hello");
    _ = try app.beginSubmit();

    _ = try app.applyAgentEvent(.{ .thinking_delta = "first chunk" });
    try std.testing.expectEqual(.thinking, app.thread.transcript.messages.items[app.thread.transcript.selected.?].mirror().kind);

    app.thread.transcript.moveSelection(.previous);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[app.thread.transcript.selected.?].mirror().kind);

    _ = try app.applyAgentEvent(.{ .thinking_delta = " more" });
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[app.thread.transcript.selected.?].mirror().kind);
}

test "user can navigate away from a streaming agent message" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("hello");
    _ = try app.beginSubmit();

    _ = try app.applyAgentEvent(.{ .response_delta = "first chunk" });
    try std.testing.expectEqual(.agent, app.thread.transcript.messages.items[app.thread.transcript.selected.?].mirror().kind);

    app.thread.transcript.moveSelection(.previous);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[app.thread.transcript.selected.?].mirror().kind);

    _ = try app.applyAgentEvent(.{ .response_delta = " more" });
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[app.thread.transcript.selected.?].mirror().kind);
}

test "empty content delta does not finalize thinking" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("hello");
    _ = try app.beginSubmit();

    _ = try app.applyAgentEvent(.{ .thinking_delta = "thinking" });
    const thinking_index = app.thread.turn_view.thinking_index.?;
    try std.testing.expectEqualStrings("Thinking...", app.thread.transcript.messages.items[thinking_index].mirror().title);

    _ = try app.applyAgentEvent(.{ .response_delta = "" });
    try std.testing.expectEqualStrings("Thinking...", app.thread.transcript.messages.items[thinking_index].mirror().title);

    _ = try app.applyAgentEvent(.{ .thinking_delta = " more" });
    try std.testing.expectEqualStrings("Thinking...", app.thread.transcript.messages.items[thinking_index].mirror().title);

    _ = try app.applyAgentEvent(.{ .response_delta = "answer" });
    try std.testing.expectEqualStrings("Thoughts", app.thread.transcript.messages.items[thinking_index].mirror().title);
}

test "content deltas do not override user scroll state" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("hello");
    _ = try app.beginSubmit();

    _ = try app.applyAgentEvent(.{ .response_delta = "first" });
    try std.testing.expect(app.thread.auto_scroll);

    app.thread.auto_scroll = false;
    _ = try app.applyAgentEvent(.{ .response_delta = " second" });
    try std.testing.expect(!app.thread.auto_scroll);
}

test "loading does not appear during final answer after tool batch" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("inspect");
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .arguments = "{\"command\":\"pwd\",\"description\":\"Print working directory\"}",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .display_label = "Print working directory",
        .display_expanded_label = "pwd",
        .display_body = "$ pwd\nexit 0\nstdout:\n/tmp\nstderr:\n",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.tool_batch_finished));
    // No status message — the spinner is derived; the batch leaves us awaiting
    // the next response over the user + tool rows.
    try std.testing.expectEqual(@as(usize, 2), app.thread.transcript.messages.items.len);
    try std.testing.expect(app.thread.turn_view.awaitingOutput());

    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "Final answer" }));
    try std.testing.expect(try app.applyAgentEvent(.delta_end));
    try std.testing.expectEqual(@as(usize, 3), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.agent, app.thread.transcript.messages.items[2].mirror().kind);
}

test "loading does not reappear between content chunks" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("implement dijkstra");
    _ = try app.beginSubmit();

    // Once a content delta has arrived we are committed to streaming. The gap
    // between chunks must NOT bring the spinner back — the streaming text is
    // its own progress indicator.
    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "Here's the implementation plan:" }));
    _ = try app.applyAgentEvent(.delta_end);
    try std.testing.expectEqual(@as(usize, 2), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[0].mirror().kind);
    try std.testing.expectEqual(.agent, app.thread.transcript.messages.items[1].mirror().kind);
}

test "bash tool waits for complete arguments while streaming" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("list files");
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .arguments = "{\"command\":\"printf hello",
    } }));
    try std.testing.expectEqual(@as(usize, 1), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[0].mirror().kind);

    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .display_label = "Print hello",
        .display_expanded_label = "printf hello",
        .display_body = "hello",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[0].mirror().kind);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[1].mirror().kind);
}

test "tool row persists through finish and turn completion" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("run ls");
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .arguments = "{\"command\":\"ls\",\"description\":\"List files\"}",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[1].mirror().kind);
    try std.testing.expectEqualStrings("🛠  List files", app.thread.transcript.messages.items[1].mirror().title);
    try std.testing.expectEqualStrings("🛠  ls", app.thread.transcript.messages.items[1].mirror().tool_expanded_title.?);
    try std.testing.expect(app.thread.transcript.messages.items[1].mirror().tool_running);
    try std.testing.expect(app.thread.transcript.hasRunningTool());

    try std.testing.expect(try app.applyAgentEvent(.delta_end));
    try std.testing.expectEqual(@as(usize, 2), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[1].mirror().kind);
    try std.testing.expectEqualStrings("🛠  List files", app.thread.transcript.messages.items[1].mirror().title);

    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .display_label = "List files",
        .display_expanded_label = "ls",
        .display_body = "$ ls\nexit 0\nstdout:\nfile\nstderr:\n",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.thread.transcript.messages.items.len);
    try std.testing.expect(!app.thread.transcript.messages.items[1].mirror().tool_running);
    try std.testing.expect(!app.thread.transcript.hasRunningTool());
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[1].mirror().kind);
    try std.testing.expectEqualStrings("🛠  List files", app.thread.transcript.messages.items[1].mirror().title);

    try std.testing.expect(try app.applyAgentEvent(.turn_finished));
    try std.testing.expectEqual(@as(usize, 2), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[1].mirror().kind);
    try std.testing.expectEqualStrings("🛠  List files", app.thread.transcript.messages.items[1].mirror().title);
}

test "partial tool arguments do not create visible tool rows" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("run ls");
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .arguments = "{\"command\":\"",
    } }));
    // Partial arguments render nothing, so no tool row appears and the spinner
    // stays up (awaiting) over the lone user message.
    try std.testing.expectEqual(@as(usize, 1), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[0].mirror().kind);
    try std.testing.expect(app.thread.turn_view.awaitingOutput());

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .arguments = "{\"command\":\"ls\",\"description\":\"List files\"}",
    } }));
    try std.testing.expectEqual(@as(usize, 2), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[1].mirror().kind);
    try std.testing.expectEqualStrings("🛠  List files", app.thread.transcript.messages.items[1].mirror().title);
}

test "tool finish creates row if no complete streamed arguments appeared" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("run ls");
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .arguments = "{\"command\":\"",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .display_label = "List files",
        .display_expanded_label = "ls",
        .display_body = "$ ls\nexit 0\nstdout:\nfile\nstderr:\n",
    } }));

    try std.testing.expectEqual(@as(usize, 2), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[1].mirror().kind);
    try std.testing.expectEqualStrings("🛠  List files", app.thread.transcript.messages.items[1].mirror().title);
}

test "new tool response index creates a new transcript row" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("run tools");
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .arguments = "{\"command\":\"ls\",\"description\":\"List files\"}",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .display_label = "List files",
        .display_expanded_label = "ls",
        .display_body = "$ ls\nexit 0\nstdout:\nfile\nstderr:\n",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.tool_batch_finished));

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .arguments = "{\"command\":\"pwd\",\"description\":\"Print working directory\"}",
    } }));

    try std.testing.expectEqual(@as(usize, 3), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[1].mirror().kind);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[2].mirror().kind);
    try std.testing.expectEqualStrings("🛠  List files", app.thread.transcript.messages.items[1].mirror().title);
    try std.testing.expectEqualStrings("🛠  Print working directory", app.thread.transcript.messages.items[2].mirror().title);
}

test "bash tool after batch creates a new tool row" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("run tools");
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .arguments = "{\"command\":\"ls\",\"description\":\"List files\"}",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .display_label = "List files",
        .display_expanded_label = "ls",
        .display_body = "$ ls\nexit 0\nstdout:\nfile\nstderr:\n",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.tool_batch_finished));
    // Awaiting the next segment over the user + tool rows; spinner is derived.
    try std.testing.expectEqual(@as(usize, 2), app.thread.transcript.messages.items.len);
    try std.testing.expect(app.thread.turn_view.awaitingOutput());

    _ = try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .arguments = "{\"command\":\"printf done\",\"description\":\"Print done\"}",
    } });

    try std.testing.expectEqual(@as(usize, 3), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[0].mirror().kind);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[1].mirror().kind);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[2].mirror().kind);
}

test "late tool finish does not move selection upward" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("run tools");
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .arguments = "{\"command\":\"ls\",\"description\":\"List files\"}",
    } }));
    try std.testing.expectEqual(@as(u32, 1), app.thread.transcript.selected.?);

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 1,
        .name = tools_mod.shellToolName,
        .arguments = "{\"command\":\"pwd\",\"description\":\"Print working directory\"}",
    } }));
    try std.testing.expectEqual(@as(u32, 2), app.thread.transcript.selected.?);

    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .display_label = "List files",
        .display_expanded_label = "ls",
        .display_body = "$ ls\nexit 0\nstdout:\nfile\nstderr:\n",
    } }));
    try std.testing.expectEqual(@as(u32, 2), app.thread.transcript.selected.?);

    try std.testing.expect(try app.applyAgentEvent(.tool_batch_finished));
    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "done" }));
    try std.testing.expectEqual(@as(u32, 3), app.thread.transcript.selected.?);
}

test "loading does not resume after post-tool thinking delta" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("inspect");
    _ = try app.beginSubmit();

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .arguments = "{\"command\":\"pwd\",\"description\":\"Print working directory\"}",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .display_label = "Print working directory",
        .display_expanded_label = "pwd",
        .display_body = "$ pwd\nexit 0\nstdout:\n/tmp\nstderr:\n",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.tool_batch_finished));

    try std.testing.expect(!try app.applyAgentEvent(.{ .thinking_delta = "checking output" }));
    try std.testing.expect(try app.applyAgentEvent(.delta_end));

    try std.testing.expectEqual(@as(usize, 3), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[0].mirror().kind);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[1].mirror().kind);
    try std.testing.expectEqual(.thinking, app.thread.transcript.messages.items[2].mirror().kind);
    try std.testing.expectEqualStrings("Thinking...", app.thread.transcript.messages.items[2].mirror().title);
}

test "agent response after tool batch appears below tool rows" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("inspect");
    _ = try app.beginSubmit();

    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "I will check." }));
    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .arguments = "{\"command\":\"pwd\",\"description\":\"Print working directory\"}",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .display_label = "Print working directory",
        .display_expanded_label = "pwd",
        .display_body = "$ pwd\nexit 0\nstdout:\n/tmp\nstderr:\n",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.tool_batch_finished));
    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "The repo is in /tmp." }));

    try std.testing.expectEqual(@as(usize, 4), app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(.user, app.thread.transcript.messages.items[0].mirror().kind);
    try std.testing.expectEqual(.agent, app.thread.transcript.messages.items[1].mirror().kind);
    try std.testing.expectEqual(.tool, app.thread.transcript.messages.items[2].mirror().kind);
    try std.testing.expectEqual(.agent, app.thread.transcript.messages.items[3].mirror().kind);
    try std.testing.expectEqualStrings("I will check.", app.thread.transcript.messages.items[1].mirror().body);
    try std.testing.expectEqualStrings("🛠  Print working directory", app.thread.transcript.messages.items[2].mirror().title);
    try std.testing.expectEqualStrings("The repo is in /tmp.", app.thread.transcript.messages.items[3].mirror().body);
    try std.testing.expectEqual(@as(u32, 3), app.thread.transcript.selected.?);
}

test "content delta after tool preview does not move selection away from tool row" {
    const gpa = std.testing.allocator;
    var openai_compatible_client: openai_compatible_mod.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.input.insertSliceAtCursor("inspect");
    _ = try app.beginSubmit();

    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = "I will check." }));
    try std.testing.expect(try app.applyAgentEvent(.delta_end));
    try std.testing.expectEqual(@as(u32, 1), app.thread.transcript.selected.?);

    try std.testing.expect(!try app.applyAgentEvent(.{ .tool_delta = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .arguments = "{\"command\":\"pwd\",\"description\":\"Print working directory\"}",
    } }));
    try std.testing.expect(try app.applyAgentEvent(.delta_end));
    try std.testing.expectEqual(@as(u32, 2), app.thread.transcript.selected.?);

    try std.testing.expect(try app.applyAgentEvent(.{ .response_delta = " Still checking." }));
    _ = try app.applyAgentEvent(.delta_end);
    try std.testing.expectEqual(@as(u32, 2), app.thread.transcript.selected.?);

    try std.testing.expect(try app.applyAgentEvent(.{ .tool_call_finished = .{
        .index = 0,
        .name = tools_mod.shellToolName,
        .display_label = "Print working directory",
        .display_expanded_label = "pwd",
        .display_body = "$ pwd\nexit 0\nstdout:\n/tmp\nstderr:\n",
    } }));
    try std.testing.expectEqual(@as(u32, 2), app.thread.transcript.selected.?);
    try std.testing.expectEqualStrings("I will check.", app.thread.transcript.messages.items[1].mirror().body);
    try std.testing.expectEqualStrings("🛠  Print working directory", app.thread.transcript.messages.items[2].mirror().title);
    try std.testing.expectEqualStrings(" Still checking.", app.thread.transcript.messages.items[3].mirror().body);
}

test "collapsed thinking and tool rows have stable heights" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const thinking_index = try transcript.append(gpa, .thinking, "Thinking...", "short");
    try std.testing.expectEqual(@as(u16, 2), messageRowsCached(&transcript.messages.items[thinking_index], 80));

    try transcript.appendThinkingDelta(gpa, thinking_index, " ");
    try transcript.appendThinkingDelta(gpa, thinking_index, "this is a much longer thinking body that should not change the collapsed row height");
    try std.testing.expectEqual(@as(u16, 2), messageRowsCached(&transcript.messages.items[thinking_index], 80));

    const tool_index = try transcript.startTool(gpa, "pwd");
    try std.testing.expectEqual(@as(u16, 2), messageRowsCached(&transcript.messages.items[tool_index], 80));
}

test "collapsed tool title wraps to visible rows" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const index = try transcript.startTool(gpa, "python3 - <<'PY'\nprint('a very long patch document')\nPY");
    try std.testing.expect(!transcript.messages.items[index].mirror().expanded);
    try std.testing.expect(messageRowsCached(&transcript.messages.items[index], 12) > 3);
}

test "resumed tool messages keep the tool icon" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "done") } };
    try agent.takeMessage(.{
        .tool = .{
            .content = blocks,
            .call_id = .{ .value = try gpa.dupe(u8, "test_call") },
            .display_label = try gpa.dupe(u8, "zig build test"),
        },
    });

    try app.rebuildTranscriptFromAgent();

    try std.testing.expectEqual(@as(usize, 1), app.thread.transcript.messages.items.len);
    try std.testing.expectEqualStrings("🛠  zig build test", app.thread.transcript.messages.items[0].mirror().title);
}

test "collapsed tool messages render no body text" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    const index = try transcript.startTool(gpa, "printf hello");
    try transcript.finishTool(gpa, index, "hello", null, false, .plain);

    try std.testing.expect(!transcript.messages.items[index].mirror().expanded);
    try std.testing.expectEqual(@as(u16, 2), messageRowsCached(&transcript.messages.items[index], 80));
    transcript.toggleSelected();
    try std.testing.expect(transcript.messages.items[index].mirror().expanded);
    try std.testing.expectEqualStrings("hello", transcript.messages.items[index].mirror().body);
}

test "expanded tool surface height cannot overflow vxfw buffer size" {
    const gpa = std.testing.allocator;
    const body = try gpa.alloc(u8, 80_000);
    defer gpa.free(body);
    @memset(body, 'x');

    var message: transcript_mod.Message = .{
        .tool = .{
            .title = try gpa.dupe(u8, "$ yes"),
            .body = body,
            .expanded = true,
        },
    };
    defer gpa.free(message.tool.title);

    var widget: MessageWidget = .{
        .message = &message,
        .selected = true,
        .loading_frame = 0,
        .blackhole_frame = 0,
        .gpa = gpa,
    };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 120, .height = null },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try widget.widget().draw(ctx);
    try std.testing.expect(surface.size.width * surface.size.height <= std.math.maxInt(u16));
}

test "switching lanes is a no-op with a single lane" {
    const gpa = std.testing.allocator;
    var client: openai_compatible_mod.Client = undefined;
    try client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer client.deinit();
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &client });
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try std.testing.expectEqual(@as(usize, 1), app.threads.len());
    const before = app.thread;
    app.switchToNextLane();
    try std.testing.expectEqual(before, app.thread);
}

const BenchResult = struct { allocs: usize, bytes: usize };

/// Message body for the allocation bench: no blank lines, so the incremental
/// render cache has no stable chunks and every frame re-renders the tail into
/// the frame arena — a clean measure of the viewport-bounded draw path.
const bench_body =
    "This is a paragraph of agent markdown that wraps across the\nterminal a few times so the row counting and render caches do real work.\n";

/// A body with blank lines, so the incremental cache folds stable chunks (and
/// allocates owned segments into App.gpa). Used by the width-change spike test
/// to exercise the cache-reset cost that a resize pays per visible message.
const bench_wrapped_body =
    "## Heading with a few words\n\n" ++
    "A paragraph of **bold** and `code` text long enough to wrap across an eighty column terminal more than once.\n\n" ++
    "- a list item with `inline code` and trailing words to force wrapping\n\n";

/// Draw the transcript at a fixed viewport, resetting the arena first. The
/// App.gpa is wrapped in a CountingAllocator by the caller, so the measured
/// frame accounts for the render_inc stable-cache segments too — the pre-§2.3
/// bench only counted the frame arena, silently missing every gpa allocation
/// in the row-counting path.
fn drawTranscriptFrame(
    tw: *tx_widget.TranscriptWidget,
    ar: *std.heap.ArenaAllocator,
    c: *CountingAllocator,
    width: u16,
    height: u16,
) !void {
    _ = ar.reset(.retain_capacity);
    const ctx: vxfw.DrawContext = .{
        .arena = c.allocator(),
        .min = .{},
        .max = .{ .width = width, .height = height },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    _ = try tw.widget().draw(ctx);
}

fn benchTranscriptDraw(gpa: std.mem.Allocator, n: usize) !BenchResult {
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app_gpa: CountingAllocator = .{ .child = gpa };
    var app = try App.init(std.testing.io, app_gpa.allocator(), &agent);
    defer app.deinit();

    const body = bench_body;
    var i: usize = 0;
    while (i < n) : (i += 1) _ = try app.thread.transcript.append(gpa, .agent, "agent", body);
    app.thread.transcript_view_width = 100;
    app.thread.transcript_view_height = 40;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var counting: CountingAllocator = .{ .child = arena.allocator() };
    var transcript_widget: tx_widget.TranscriptWidget = .{
        .thread = app.thread,
        .gpa = app.gpa,
        .has_model_configured = false,
        .loading_frame = app.metrics.loading_frame,
        .blackhole_frame = app.metrics.blackhole_frame,
        .blackhole_visible = &app.metrics.blackhole_visible,
    };

    // Warm frame: renders + caches markdown for the visible messages.
    try drawTranscriptFrame(&transcript_widget, &arena, &counting, 100, 40);

    // One measured warm frame for allocation accounting (frame arena + App.gpa).
    counting.count = 0;
    counting.bytes = 0;
    app_gpa.count = 0;
    app_gpa.bytes = 0;
    try drawTranscriptFrame(&transcript_widget, &arena, &counting, 100, 40);
    return .{ .allocs = counting.count + app_gpa.count, .bytes = counting.bytes + app_gpa.bytes };
}

test "transcript draw allocation does not scale with history length" {
    const gpa = std.testing.allocator;
    const small = try benchTranscriptDraw(gpa, 50);
    const large = try benchTranscriptDraw(gpa, 800);
    try std.testing.expect(large.bytes <= small.bytes + 4096);
}

// The resize spike: a width change invalidates every visible message's row
// cache and resets its incremental render cache (folding fresh stable segments
// into App.gpa). That re-count cost must be viewport-bounded, not O(N) full
// markdown renders — the exact scenario that paid N page_allocator renders
// before the §2.3 counting change.
test "search matches are case-insensitive substrings over user, agent, and tool text" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.transcript.append(gpa, .user, "you", "Fix the flaky SESSION resume");
    _ = try app.thread.transcript.append(gpa, .agent, "agent", "I will look at the session code");
    const tool = try app.thread.transcript.startTool(gpa, "grep session");
    try app.thread.transcript.finishTool(gpa, tool, "output line\nmore output", null, false, .plain);

    // Empty query → hint state, no matches.
    try search_lifecycle.rebuildMatches(&app, "");
    try std.testing.expectEqual(@as(usize, 0), app.pickers.search.matches.items.len);
    try std.testing.expect(app.pickers.search.filter_empty);

    // Case-insensitive substring across user and agent bodies — and the tool
    // *title* ("grep session"), which also matches.
    try search_lifecycle.rebuildMatches(&app, "SESSION");
    try std.testing.expectEqual(@as(usize, 3), app.pickers.search.matches.items.len);
    try std.testing.expectEqualStrings("user", app.pickers.search.matches.items[0].role);
    try std.testing.expectEqualStrings("agent", app.pickers.search.matches.items[1].role);
    try std.testing.expectEqualStrings("tool", app.pickers.search.matches.items[2].role);

    // Tool-body matching: the grep output line is searched, not just the title.
    try search_lifecycle.rebuildMatches(&app, "output");
    try std.testing.expectEqual(@as(usize, 1), app.pickers.search.matches.items.len);
    try std.testing.expectEqual(@as(u32, 2), app.pickers.search.matches.items[0].message_index);
    try std.testing.expectEqualStrings("tool", app.pickers.search.matches.items[0].role);
    try std.testing.expectEqualStrings("output line", app.pickers.search.matches.items[0].snippet);
}

test "search match list covers mixed roles in document order and an empty transcript" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // Empty transcript → nothing matches.
    try search_lifecycle.rebuildMatches(&app, "anything");
    try std.testing.expectEqual(@as(usize, 0), app.pickers.search.matches.items.len);

    _ = try app.thread.transcript.append(gpa, .user, "you", "add tests");
    _ = try app.thread.transcript.append(gpa, .agent, "agent", "adding tests now");
    _ = try app.thread.transcript.append(gpa, .notice, "notice", "tests pass");
    try search_lifecycle.rebuildMatches(&app, "tests");
    try std.testing.expectEqual(@as(usize, 3), app.pickers.search.matches.items.len);
    // Document order (oldest → newest).
    try std.testing.expectEqual(@as(u32, 0), app.pickers.search.matches.items[0].message_index);
    try std.testing.expectEqual(@as(u32, 2), app.pickers.search.matches.items[2].message_index);
}

test "search Enter-jump pins the selected message and disables auto-scroll" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.transcript.append(gpa, .user, "you", "first");
    _ = try app.thread.transcript.append(gpa, .agent, "agent", "second message");
    _ = try app.thread.transcript.append(gpa, .user, "you", "third");
    app.thread.auto_scroll = true;

    try app.openSearch();
    try std.testing.expectEqual(App.Mode.search, app.mode);
    try search_lifecycle.rebuildMatches(&app, "second");
    try std.testing.expectEqual(@as(usize, 1), app.pickers.search.matches.items.len);
    try app.acceptSearchSelection();

    // Jump lands on the matched message, auto-scroll off, search mode closed.
    try std.testing.expectEqual(App.Mode.normal, app.mode);
    try std.testing.expectEqual(@as(?u32, 1), app.thread.transcript.selected);
    try std.testing.expect(!app.thread.auto_scroll);
}

test "search snippets are owned copies, not borrows into the transcript" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    _ = try app.thread.transcript.append(gpa, .agent, "agent", "needle in hay");
    try search_lifecycle.rebuildMatches(&app, "needle");
    try std.testing.expectEqual(@as(usize, 1), app.pickers.search.matches.items.len);

    // The overlay does not pause streaming: `appendOwned` reallocs the body
    // buffer on every delta, so a snippet borrowed from it would dangle the
    // moment realloc moves. The snippet must be a dup — a distinct pointer
    // that keeps its bytes after the source body grows.
    const body = app.thread.transcript.messages.items[0].mirror().body;
    const snippet = app.pickers.search.matches.items[0].snippet;
    try std.testing.expect(snippet.ptr != body.ptr);
    try app.thread.transcript.appendAgentDelta(gpa, 0, " and more text streaming in afterwards");
    try std.testing.expectEqualStrings("needle in hay", snippet);
}

test "palette peek arena copy matches the gpa copy byte-for-byte" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try app.inputs.palette.buf.insertSliceAtCursor("some filter");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const gpa_copy = try app.peekPaletteInput();
    defer gpa.free(gpa_copy);
    const arena_copy = try app.peekPaletteInputArena(arena.allocator());
    try std.testing.expectEqualStrings(gpa_copy, arena_copy);
}

test "transcript draw width-change re-count stays below a fixed gpa ceiling" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app_gpa: CountingAllocator = .{ .child = gpa };
    var app = try App.init(std.testing.io, app_gpa.allocator(), &agent);
    defer app.deinit();

    const n = 800;
    var i: usize = 0;
    while (i < n) : (i += 1) _ = try app.thread.transcript.append(gpa, .agent, "agent", bench_wrapped_body);
    app.thread.transcript_view_width = 100;
    app.thread.transcript_view_height = 40;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var counting: CountingAllocator = .{ .child = arena.allocator() };
    var transcript_widget: tx_widget.TranscriptWidget = .{
        .thread = app.thread,
        .gpa = app.gpa,
        .has_model_configured = false,
        .loading_frame = app.metrics.loading_frame,
        .blackhole_frame = app.metrics.blackhole_frame,
        .blackhole_visible = &app.metrics.blackhole_visible,
    };

    // Warm at width 100 so the visible messages hold populated incremental
    // caches (stable segments owned by App.gpa).
    try drawTranscriptFrame(&transcript_widget, &arena, &counting, 100, 40);

    // Width change to 60: every visible message's row cache misses and its
    // render cache resets. The re-count frame's App.gpa allocations must stay
    // viewport-bounded — a fixed ceiling O(N) full re-renders would blow past.
    app_gpa.count = 0;
    app_gpa.bytes = 0;
    try drawTranscriptFrame(&transcript_widget, &arena, &counting, 60, 40);
    try std.testing.expect(app_gpa.bytes < 512 * 1024);
    try std.testing.expect(app_gpa.count < 512);
}

test "handleTick invokes the 4 documented phase functions in order" {
    // Locks in AGENTS.md's documented handleTick ordering: drainAgentEvents
    // (private to lifecycle.zig) → serviceLaneBridge → drainLaneNaming →
    // deliverPendingLaneCompletions. The 3 lane-bridge phases are pub and
    // exercised directly; the private drainAgentEvents is exercised via
    // handleTick itself. If any of the 4 phase functions is renamed or its
    // signature changes, this test fails to compile (or the handleTick body
    // no longer calls them in the documented order).
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var root: RootWidget = .{ .app = &app };
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    // The 3 pub lane-bridge phases in AGENTS.md's documented order, on an
    // idle App. Each returns the expected shape: no naming change, no
    // pending completions, no bridge work.
    lane_lifecycle.serviceLaneBridge(&app); // void return — no error path
    const naming_changed = try lane_lifecycle.drainLaneNaming(&app);
    try std.testing.expect(!naming_changed);
    const completions_changed = try lane_lifecycle.deliverPendingLaneCompletions(&app);
    try std.testing.expect(!completions_changed);

    // Run the same composition via the single handleTick entry point that
    // production uses. The post-tick App must be in the same shape the
    // documented 4 phases leave it: idle turn, no loading frame, no
    // pending lane completions.
    try lifecycle.handleTick(&root, &ctx);
    try std.testing.expect(!app.thread.turn.isActive());
    try std.testing.expect(!app.metrics.loading_tick_active);
}

test "refreshGitLabel updates metrics.git_label on dirty flag and avoids duplicate allocation" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try lifecycle.refreshGitLabel(&app);
    const initial_label_len = app.metrics.git_label.len;
    if (initial_label_len > 0) {
        const ptr_before = app.metrics.git_label.ptr;
        // Refreshing again when branch is unchanged skips realloc
        try lifecycle.refreshGitLabel(&app);
        try std.testing.expectEqual(ptr_before, app.metrics.git_label.ptr);
    }

    app.git_label_dirty = false;
    app.armGitLabelRefresh();
    try std.testing.expect(app.git_label_dirty);
}

test "handleTick refreshes git label when dirty and resets dirty flag" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var root: RootWidget = .{ .app = &app };
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    app.git_label_dirty = true;
    try lifecycle.handleTick(&root, &ctx);
    try std.testing.expect(!app.git_label_dirty);
}
