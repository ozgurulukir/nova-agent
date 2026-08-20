//! Shared fixtures for TUI tests. Referenced ONLY from `test` blocks —
//! never from production code — so lazy analysis keeps this module out of
//! release builds entirely. When `Thread` or `AgentRuntime` gain a required
//! field, these are the single places to update instead of one copy per
//! test file.

const std = @import("std");
const tui = @import("../tui.zig");

const App = tui.App;

/// Append a fresh idle lane and focus it — the fixture for every idle-lane
/// guard test. The primary keeps its runtime so App teardown stays clean,
/// while `app.thread` (the focused lane) has none: `liveRuntime()` returns
/// null without leaving the App in an unrepresentable state.
pub fn addIdleFocusedLane(gpa: std.mem.Allocator, app: *App, id: []const u8) !void {
    const lane = try gpa.create(tui.Thread);
    errdefer gpa.destroy(lane);
    const branch = try std.fmt.allocPrint(gpa, "nova/{s}", .{id});
    errdefer gpa.free(branch);
    const path = try std.fmt.allocPrint(gpa, "/tmp/nova-lanes/{s}", .{id});
    errdefer gpa.free(path);
    lane.* = .{ .engine = .{ .idle = .{ .working = .{ .branch = branch, .path = path } } } };
    try app.threads.append(lane);
    app.thread = lane; // focus the idle lane
}

/// Minimal heap runtime whose surface survives a real `AgentRuntime.deinit`
/// (mirrors the tests.zig createRuntime fixture, plus a real session writer).
/// For park/close tests that tear a runtime down on the App's behalf.
pub fn makeParkTestRuntime(gpa: std.mem.Allocator, home_abs: []const u8) !*@import("../runtime.zig").AgentRuntime {
    const runtime_mod = @import("../runtime.zig");
    const session_mod = @import("../session.zig");
    const runtime = try gpa.create(runtime_mod.AgentRuntime);
    errdefer gpa.destroy(runtime);
    runtime.* = undefined;
    runtime.gpa = gpa;
    runtime.io = std.testing.io;
    runtime.cwd = try gpa.dupe(u8, ".");
    errdefer gpa.free(runtime.cwd);
    runtime.home_dir = home_abs; // borrowed; not freed by deinit
    runtime.client = .none;
    runtime.base_system_prompt = try gpa.dupe(u8, "");
    errdefer gpa.free(runtime.base_system_prompt);
    runtime.system_prompt = try gpa.dupe(u8, "");
    errdefer gpa.free(runtime.system_prompt);
    runtime.skills = &.{};
    runtime.plugin_prompts = &.{};
    runtime.diagnostics = &.{};
    runtime.owned_client = null;
    runtime.owned_compaction_client = null;
    runtime.owned_naming_client = null;
    runtime.modelsdev_registry = null;
    runtime.naming_client = .none;
    runtime.agent = @import("../agent.zig").Agent.init(gpa, std.testing.io, ".", .none);
    try session_mod.SessionWriter.initDefault(&runtime.session_writer, gpa, std.testing.io, home_abs, ".");
    return runtime;
}
