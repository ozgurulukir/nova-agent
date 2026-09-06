//! At-search (`@` file / `$` skill mention popup). Free functions taking
//! `*App` — extracted from `tui.zig`.

const std = @import("std");

const tui = @import("../tui.zig");
const at_mention = @import("../at_mention.zig");
const search_mod = @import("../search.zig");
const skill_mod = @import("../skill.zig");

const App = tui.App;

pub const MentionSearchKind = enum { file, skill };

fn isSearchFooter(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "+") or
        std.mem.eql(u8, line, "0 results.");
}

pub fn updateAtSearch(app: *App) !void {
    const before = app.inputs.input.buf.firstHalf();
    const active_file = at_mention.activeQuery(before);
    const active_skill = if (active_file == null) skill_mod.activeQuery(before) else null;

    // If neither mention nor skill trigger is active in the input, close immediately.
    if (active_file == null and active_skill == null) {
        closeAtSearch(app);
        return;
    }

    // While indexing, only proceed to open once the background walk completes.
    if (app.at_search == .indexing) {
        if (search_mod.drainIndexing(app.io)) {
            try onSearchBackendReady(app);
        } else {
            return;
        }
    }

    if (active_file) |active| {
        try setMentionSearch(app, .file, active.query);
        return;
    }
    if (active_skill) |active| {
        try setMentionSearch(app, .skill, active.query);
        return;
    }
    closeAtSearch(app);
}

fn setMentionSearch(app: *App, kind: MentionSearchKind, query: []const u8) !void {
    if (kind == .file) startAtSearchBackend(app);

    if (app.at_search == .open and app.at_search.open.kind == kind) {
        if (std.mem.eql(u8, query, app.at_search.open.query)) return;

        const owned = if (query.len > 0) try app.gpa.dupe(u8, query) else "";
        const o = &app.at_search.open;
        if (o.query.len > 0) app.gpa.free(o.query);
        o.query = owned;
        o.selection = 0;
        app.at_search.refreshDebounce(app.io, 80);
        if (kind == .skill) {
            try refreshSkillResults(app);
        }
        return;
    }

    const owned: []u8 = if (query.len > 0) try app.gpa.dupe(u8, query) else "";
    errdefer if (owned.len > 0) app.gpa.free(owned);

    if (app.at_search == .open and app.at_search.open.kind == .file and kind != .file) {
        search_mod.cancelSearch(app.gpa, app.io);
    }
    app.at_search.close(app.gpa);
    app.at_search = .{ .open = .{ .kind = kind, .query = owned } };

    // Coalesce rapid input changes. The render loop and lifecycle tick call
    // `drainAtSearch`, which starts the latest query once this deadline expires.
    app.at_search.refreshDebounce(app.io, 80);
    try refreshAtResults(app);
}

fn startAtSearchBackend(app: *App) void {
    const cwd = if (app.liveRuntime()) |runtime| runtime.cwd else ".";
    search_mod.start(app.gpa, app.io, cwd);
}

fn refreshAtResults(app: *App) !void {
    // Caller ensures we're in .open (or transitioning to .indexing).
    if (app.at_search != .open) return;
    switch (app.at_search.open.kind) {
        .file => try refreshFileResults(app),
        .skill => try refreshSkillResults(app),
    }
}

/// Drains pending at-search events on the UI tick. Returns true if results or
/// presentation changed and a redraw is needed.
pub fn drainAtSearch(app: *App) !bool {
    if (app.at_search == .closed) return false;

    if (app.at_search == .indexing) {
        if (search_mod.drainIndexing(app.io)) {
            try onSearchBackendReady(app);
            return true;
        }
        return false;
    }

    if (app.at_search == .open and app.at_search.open.kind == .file) {
        var changed = false;
        if (try pollFileResults(app)) {
            changed = true;
        }
        if (try startDeferredFileSearch(app)) {
            // New async search in-flight
        }
        return changed;
    }

    return false;
}

/// Poll the async search backend and update the popup's results when a
/// search completes. Safe to call every frame; no-op when no search is running.
pub fn pollAtSearch(app: *App) !void {
    _ = try drainAtSearch(app);
}

fn pollFileResults(app: *App) !bool {
    if (app.at_search != .open) return false;
    const o = &app.at_search.open;
    if (o.kind != .file) return false;

    // If a search completed, parse its stdout into the result list.
    if (try search_mod.pollSearchResult(app.gpa, app.io)) |result| {
        var res = result;
        defer res.deinit(app.gpa);
        o.searching = false;

        // If the completed search was for an older query, ignore it so stale
        // results do not replace the user's active query.
        const current_hash = search_mod.hashQuery(o.query);
        if (res.query_hash != 0 and res.query_hash != current_hash) {
            return false;
        }

        clearAtResults(app);
        if (res.status == .err) {
            setSearchNotice(app, res.stdout);
            return true;
        }
        setSearchNotice(app, "");
        try parseAtResults(app, res.stdout);
        return true;
    } else if (o.searching and !search_mod.isSearching(app.io)) {
        o.searching = false;
    }
    return false;
}

fn startDeferredFileSearch(app: *App) !bool {
    if (app.at_search != .open) return false;
    const o = &app.at_search.open;
    if (o.kind != .file) return false;

    // If the backend is still indexing, transition open -> indexing so the
    // UI shows the indexing spinner.
    if (search_mod.isIndexing()) {
        const kind = o.kind;
        const query = o.query;
        const results_list = o.results;
        const selection = o.selection;
        app.at_search = .{ .indexing = .{ .kind = kind, .results = results_list } };
        app.gpa.free(query);
        _ = selection;
        return true;
    }

    // Don't start a new search while the debounce window is open.
    if (!app.at_search.debounceExpired(app.io)) return false;

    const current_hash = search_mod.hashQuery(o.query);
    if (o.last_query_hash != null and o.last_query_hash.? == current_hash) {
        return false;
    }

    try search_mod.queryAsync(app.gpa, app.io, .{ .op = .find, .query = o.query });
    o.searching = true;
    o.last_query_hash = current_hash;
    return true;
}

fn refreshFileResults(app: *App) !void {
    _ = try pollFileResults(app);
    _ = try startDeferredFileSearch(app);
}

fn refreshSkillResults(app: *App) !void {
    if (app.at_search != .open) return;
    const o = &app.at_search.open;
    const runtime = app.liveRuntime() orelse return;
    clearAtResults(app);
    const names = try skill_mod.filterNames(app.gpa, runtime.skills, o.query);
    for (names, 0..) |name, idx| {
        o.results.append(app.gpa, name) catch |err| {
            for (names[idx..]) |unconsumed| app.gpa.free(unconsumed);
            app.gpa.free(names);
            return err;
        };
    }
    app.gpa.free(names);
    if (o.selection >= o.results.items.len) o.selection = 0;
}

fn parseAtResults(app: *App, stdout: []const u8) !void {
    if (app.at_search != .open) return;
    const o = &app.at_search.open;
    const max_results = 50;
    var iter = std.mem.splitScalar(u8, stdout, '\n');
    while (iter.next()) |line| {
        if (o.results.items.len >= max_results) break;
        if (line.len == 0) continue;
        if (isSearchFooter(line)) continue;
        if (line[line.len - 1] == '/') continue;
        const owned = try app.gpa.dupe(u8, line);
        errdefer app.gpa.free(owned);
        try o.results.append(app.gpa, owned);
    }
    if (o.selection >= o.results.items.len) o.selection = 0;
}

pub fn acceptAtSelection(app: *App) !void {
    if (app.at_search != .open) return;
    const o = &app.at_search.open;
    if (o.selection >= o.results.items.len) return;
    const before = app.inputs.input.buf.firstHalf();
    const active_start = switch (o.kind) {
        .file => if (at_mention.activeQuery(before)) |active| active.start else return,
        .skill => if (skill_mod.activeQuery(before)) |active| active.start else return,
    };
    const value = o.results.items[o.selection];
    const sigil: u8 = if (o.kind == .file) '@' else '$';
    const insert = try std.fmt.allocPrint(app.gpa, "{c}{s} ", .{ sigil, value });
    defer app.gpa.free(insert);
    // `active_start` points at the sigil itself. Remove the sigil and typed
    // query before inserting the selected value with its replacement sigil.
    app.inputs.input.buf.growGapLeft(before.len - active_start);
    try app.inputs.input.insertSliceAtCursor(insert);
    closeAtSearch(app);
}

fn clearAtResults(app: *App) void {
    switch (app.at_search) {
        .open => |*o| {
            for (o.results.items) |path| app.gpa.free(path);
            o.results.clearRetainingCapacity();
        },
        .indexing => |*i| {
            for (i.results.items) |path| app.gpa.free(path);
            i.results.clearRetainingCapacity();
        },
        .closed => {},
    }
}

pub fn closeAtSearch(app: *App) void {
    if (app.at_search == .open and app.at_search.open.kind == .file) {
        search_mod.cancelSearch(app.gpa, app.io);
    }
    app.at_search.close(app.gpa);
}

/// Set a transient inline notice on the open at-search popup. The notice
/// is freed when the popup closes or a new notice replaces it.
pub fn setSearchNotice(app: *App, text: []const u8) void {
    if (app.at_search != .open) return;
    const o = &app.at_search.open;
    if (o.notice) |n| app.gpa.free(n);
    o.notice = null;
    if (text.len == 0) return;
    o.notice = app.gpa.dupe(u8, text) catch null;
}

/// Promote an indexing state back to open when the backend completes.
/// Re-runs refreshAtResults against the current input-buffer query.
pub fn onSearchBackendReady(app: *App) !void {
    if (app.at_search != .indexing) return;
    // Recover the query from the input buffer — the indexing variant
    // doesn't carry it.
    const before = app.inputs.input.buf.firstHalf();
    // The two branches below return distinct anonymous struct types; pin
    // `active` to an explicit type so both break values coerce to it.
    const Active = struct { kind: MentionSearchKind, query: []const u8 };
    const active: Active = blk: {
        if (at_mention.activeQuery(before)) |q| break :blk .{ .kind = .file, .query = q.query };
        if (skill_mod.activeQuery(before)) |q| break :blk .{ .kind = .skill, .query = q.query };
        closeAtSearch(app);
        return;
    };
    // Drop the indexing results — refreshAtResults repopulates from
    // the now-ready backend.
    clearAtResults(app);
    const kind_mention: MentionSearchKind = active.kind;
    const owned: []u8 = if (active.query.len > 0) try app.gpa.dupe(u8, active.query) else "";
    app.at_search.close(app.gpa);
    app.at_search = .{ .open = .{ .kind = kind_mention, .query = owned } };
    // The backend just became ready: refresh results immediately, but still
    // debounce a fresh query if the user is still typing.
    app.at_search.refreshDebounce(app.io, 40);
    try refreshAtResults(app);
}
