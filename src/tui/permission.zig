//! Permission overlay: approval/rejection of tool calls. Free functions taking
//! `*App`.

const std = @import("std");
const vaxis = @import("vaxis");

const tui = @import("../tui.zig");
const agent_worker = @import("agent_worker.zig");

const App = tui.App;
const Thread = tui.Thread;

/// The lane whose worker is blocked on a tool approval, if any. The visible
/// lane is checked first so its overlay wins when several gates pend at once;
/// the rest are scanned in `threads` order. A background worker that hits a
/// destructive-bash gate is invisible without this — the overlay binds to the
/// returned lane, not blindly to `app.thread`.
pub fn approvalLane(app: *App) ?*Thread {
    if (pendingOn(app.thread)) return app.thread;
    for (app.threads.slice()) |lane| {
        if (lane == app.thread) continue;
        if (pendingOn(lane)) return lane;
    }
    return null;
}

fn pendingOn(lane: *Thread) bool {
    const worker = if (lane.worker_context) |*context| context else return false;
    return worker.approval.pending(worker.io);
}

pub fn permissionPending(app: *App) bool {
    return approvalLane(app) != null;
}

pub fn handlePermissionKey(app: *App, key: vaxis.Key) !bool {
    if (key.matches(vaxis.Key.left, .{}) or key.matches('h', .{})) {
        app.thread.permission_selection = .approve;
        return true;
    }
    if (key.matches(vaxis.Key.right, .{}) or key.matches('l', .{})) {
        app.thread.permission_selection = .reject;
        return true;
    }
    if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
        if (app.thread.permission_scroll > 0) app.thread.permission_scroll -= 1;
        return true;
    }
    if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
        app.thread.permission_scroll += 1;
        return true;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        try resolvePermission(app, app.thread.permission_selection);
        return true;
    }
    if (key.matches('y', .{}) or key.matches('a', .{})) {
        try resolvePermission(app, .approve);
        return true;
    }
    if (key.matches('n', .{}) or key.matches('r', .{})) {
        try resolvePermission(app, .reject);
        return true;
    }
    return false;
}

pub fn resolvePermission(app: *App, decision: agent_worker.ApprovalDecision) !void {
    const lane = approvalLane(app) orelse return;
    const worker = if (lane.worker_context) |*context| context else return;
    try worker.approval.resolve(worker.io, decision);
    // View state (scroll/selection) stays on the visible lane — it drives the
    // overlay's rendering, whichever lane owns the resolved gate.
    app.thread.permission_scroll = 0;
    app.thread.permission_selection = .approve;
}

// ── Tests ──

const agent_mod = @import("../agent.zig");

/// Append a fake working lane carrying a worker context, so its approval gate
/// is live. `app.deinit` frees it with the real lanes.
fn addLaneWithWorker(gpa: std.mem.Allocator, app: *App, io: std.Io, id: []const u8) !*Thread {
    const lane = try gpa.create(Thread);
    errdefer gpa.destroy(lane);
    const branch = try std.fmt.allocPrint(gpa, "nova/{s}", .{id});
    errdefer gpa.free(branch);
    const path = try std.fmt.allocPrint(gpa, "/tmp/nova-lanes/{s}", .{id});
    errdefer gpa.free(path);
    lane.* = .{
        .engine = .{ .idle = .{ .working = .{ .branch = branch, .path = path } } },
        .worker_context = .{ .io = io, .gpa = gpa },
    };
    try app.threads.append(lane);
    return lane;
}

const GateOutcome = struct { approved: ?bool = null };

fn gateRequestWorker(worker: *agent_worker.Context, out: *GateOutcome) void {
    out.approved = worker.approval.request(worker.io, worker.gpa, "rm -rf /scratch") catch unreachable;
}

test "approvalLane finds a pending gate on a background lane" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var agent = agent_mod.Agent.init(gpa, io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(io, gpa, &agent);
    defer app.deinit();

    const lane = try addLaneWithWorker(gpa, &app, io, "abc123");
    // The visible lane's own gate is empty — only the background lane pends.
    try std.testing.expect(!pendingOn(app.thread));
    try std.testing.expect(approvalLane(&app) == null);

    // Block a worker on the background lane's gate.
    var outcome = GateOutcome{};
    const worker = &lane.worker_context.?;
    const thread = try std.Thread.spawn(.{}, gateRequestWorker, .{ worker, &outcome });
    var spins: u32 = 0;
    while (!pendingOn(lane) and spins < 10_000) : (spins += 1) {
        io.sleep(.fromMilliseconds(2), .awake) catch {};
    }
    try std.testing.expect(pendingOn(lane));

    // The scan surfaces the background lane, and permissionPending follows.
    try std.testing.expect(approvalLane(&app) == lane);
    try std.testing.expect(permissionPending(&app));

    // Resolving through the App unblocks the worker with the decision.
    try resolvePermission(&app, .approve);
    thread.join();
    try std.testing.expectEqual(true, outcome.approved.?);
    try std.testing.expect(approvalLane(&app) == null);
}

test "approvalLane prefers the visible lane when several gates pend" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var agent = agent_mod.Agent.init(gpa, io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(io, gpa, &agent);
    defer app.deinit();

    const background = try addLaneWithWorker(gpa, &app, io, "abc123");
    // Seed both gates directly (no blocking thread needed for a scan-order
    // assertion): visible lane first, background second. deinitApp frees both
    // commands via each gate's `deinit`.
    app.thread.worker_context.?.approval.command = try gpa.dupe(u8, "visible cmd");
    background.worker_context.?.approval.command = try gpa.dupe(u8, "background cmd");
    try std.testing.expect(approvalLane(&app) == app.thread);
}
