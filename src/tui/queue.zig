//! Queue management: enqueue, flush, and navigate queued user messages.
//! Free functions taking `*App` — extracted from `tui.zig`.

const std = @import("std");

const tui = @import("../tui.zig");
const skill_mod = @import("../skill.zig");

const App = tui.App;
const Thread = tui.Thread;

fn appendMessageQueueFullNotice(app: *App) !void {
    _ = try app.thread.transcript.append(app.gpa, .notice, "notice", "MessageQueueFull");
}

pub fn appendSkillInvocationsToTranscript(app: *App, prompt: []const u8) !void {
    const runtime = app.liveRuntime() orelse return;
    const names = try skill_mod.collectInvocations(app.gpa, runtime.skills, prompt);
    defer app.gpa.free(names);
    var title_buf: [128]u8 = undefined;
    for (names) |name| {
        const title = try std.fmt.bufPrint(&title_buf, "[SKILL] {s}", .{name});
        _ = try app.thread.transcript.append(app.gpa, .skill, title, "");
    }
}

pub fn enqueueSubmit(app: *App) !bool {
    const prompt = try app.inputs.input.buf.dupe();
    errdefer app.gpa.free(prompt);
    if (prompt.len == 0) {
        app.gpa.free(prompt);
        return false;
    }
    app.thread.agent.?.enqueueUser(prompt) catch |err| switch (err) {
        error.QueueFull => {
            app.gpa.free(prompt);
            try appendMessageQueueFullNotice(app);
            return false;
        },
        else => return err,
    };
    try app.thread.queued.append(app.gpa, .{ .text = prompt });
    app.nav.queued_selection = app.thread.queued.items.len - 1;
    app.clearInput();
    return false;
}

pub fn selectPrevQueued(app: *App) void {
    if (app.thread.queued.items.len == 0) return;
    if (app.nav.queued_selection > 0) app.nav.queued_selection -= 1;
}

pub fn selectNextQueued(app: *App) void {
    const len = app.thread.queued.items.len;
    if (len == 0) return;
    if (app.nav.queued_selection + 1 < len) app.nav.queued_selection += 1;
}

pub fn steerSelectedQueued(app: *App) void {
    const items = app.thread.queued.items;
    if (items.len == 0) return;
    const index = @min(app.nav.queued_selection, items.len - 1);
    items[index].steer = true;
    app.thread.agent.?.setQueuedSteer(@intCast(index));
}

/// Mirror a machine-generated (raw) message into `lane`'s UI queue so the
/// mirror stays 1:1 with the agent queue. The entry is never rendered as a
/// user row — `flushQueuedUserMessagesToTranscript` drops raw entries — but
/// its presence keeps `steerSelectedQueued`'s mirror index aligned with the
/// agent-queue index. Call after a successful `enqueueRaw` on the same lane.
pub fn mirrorRawEnqueue(app: *App, lane: *Thread, message: []const u8) void {
    const mirror_copy = app.gpa.dupe(u8, message) catch return;
    lane.queued.append(app.gpa, .{ .text = mirror_copy, .raw = true }) catch app.gpa.free(mirror_copy);
}

/// `enqueueRaw` + its mirror entry as one atomic step: the mirror entry is
/// appended only AFTER a successful enqueue, so a QueueFull drop never
/// diverges the mirror from the agent queue (a mirror ahead by one shifts
/// every `steerSelectedQueued` index). Returns false when nothing was
/// written on either side (QueueFull, or the lane has no agent).
pub fn enqueueRawMirrored(app: *App, lane: *Thread, message: []const u8) bool {
    const agent = lane.agent orelse return false;
    agent.enqueueRaw(message) catch return false;
    mirrorRawEnqueue(app, lane, message);
    return true;
}

pub fn flushQueuedUserMessagesToTranscript(app: *App, count: u32) !void {
    const flush_count: usize = @min(count, app.thread.queued.items.len);
    for (app.thread.queued.items[0..flush_count]) |message| {
        if (message.raw) {
            // A raw entry is a mirror of a machine-generated message whose
            // notice the delivery path already wrote — never render it as a
            // user row. Free and drop it to keep the mirror in lockstep.
            app.gpa.free(message.text);
            continue;
        }
        _ = try app.thread.transcript.append(app.gpa, .user, "you", message.text);
        try appendSkillInvocationsToTranscript(app, message.text);
        app.gpa.free(message.text);
    }
    std.mem.copyForwards(Thread.QueuedMessage, app.thread.queued.items[0 .. app.thread.queued.items.len - flush_count], app.thread.queued.items[flush_count..]);
    app.thread.queued.shrinkRetainingCapacity(app.thread.queued.items.len - flush_count);
    app.nav.queued_selection -|= flush_count;
}

pub fn clearQueuedUserMessages(app: *App) void {
    for (app.thread.queued.items) |message| app.gpa.free(message.text);
    app.thread.queued.clearRetainingCapacity();
    app.nav.queued_selection = 0;
}

// ── Tests ──

const agent_mod = @import("../agent.zig");

test "M2: raw delivery keeps the UI mirror 1:1 with the agent queue" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var agent = agent_mod.Agent.init(gpa, io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(io, gpa, &agent);
    defer app.deinit();

    // A raw message enqueued on the agent queue, mirrored into the UI queue.
    try agent.enqueueRaw("lane finished");
    mirrorRawEnqueue(&app, app.thread, "lane finished");

    // Mirror and agent queue are the same length; the entry is marked raw.
    try std.testing.expectEqual(@as(usize, 1), app.thread.queued.items.len);
    try std.testing.expectEqual(@as(u32, 1), agent.message_queue.len());
    try std.testing.expect(app.thread.queued.items[0].raw);
    try std.testing.expectEqualStrings("lane finished", app.thread.queued.items[0].text);
}

test "M2: steer marks the selected entry despite interleaved raw messages" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var agent = agent_mod.Agent.init(gpa, io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(io, gpa, &agent);
    defer app.deinit();

    // Mirror [user, raw, user] — the raw entry is a machine-generated message
    // interleaved between two user messages.
    try agent.enqueueUser("first");
    try app.thread.queued.append(gpa, .{ .text = try gpa.dupe(u8, "first") });
    try agent.enqueueRaw("lane finished");
    mirrorRawEnqueue(&app, app.thread, "lane finished");
    try agent.enqueueUser("third");
    try app.thread.queued.append(gpa, .{ .text = try gpa.dupe(u8, "third") });

    // Steer the third entry (mirror index 2) — the agent queue's third entry
    // must be flagged, not the raw one at index 1.
    app.nav.queued_selection = 2;
    steerSelectedQueued(&app);
    try std.testing.expectEqual(@as(u32, 3), agent.message_queue.len());
    try std.testing.expect(!agent.message_queue.at(&agent.message_queue_storage, 0).?.steer);
    try std.testing.expect(!agent.message_queue.at(&agent.message_queue_storage, 1).?.steer);
    try std.testing.expect(agent.message_queue.at(&agent.message_queue_storage, 2).?.steer);
}

test "M2: flush renders user entries only, dropping raw mirrors" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var agent = agent_mod.Agent.init(gpa, io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(io, gpa, &agent);
    defer app.deinit();

    // Mirror [user, raw] — the raw entry's notice was already written by the
    // delivery path, so flushing must render only the user row.
    try app.thread.queued.append(gpa, .{ .text = try gpa.dupe(u8, "user prompt") });
    try app.thread.queued.append(gpa, .{ .text = try gpa.dupe(u8, "lane finished"), .raw = true });
    const before = app.thread.transcript.messages.items.len;

    try flushQueuedUserMessagesToTranscript(&app, 2);
    try std.testing.expectEqual(before + 1, app.thread.transcript.messages.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.thread.queued.items.len);
    try std.testing.expect(transcriptHasUser(&app, "user prompt"));
    try std.testing.expect(!transcriptHasUser(&app, "lane finished"));
}

test "M2: enqueueRawMirrored writes nothing on either side when the agent queue is full" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var agent = agent_mod.Agent.init(gpa, io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(io, gpa, &agent);
    defer app.deinit();

    // Fill the agent queue to capacity.
    for (0..agent.message_queue_storage.len) |_| try agent.enqueueRaw("filler");

    // The mirrored enqueue must fail atomically: no agent entry, no mirror
    // entry — a mirror ahead of the agent queue shifts every steer index.
    try std.testing.expect(!enqueueRawMirrored(&app, app.thread, "one more"));
    try std.testing.expectEqual(@as(usize, 0), app.thread.queued.items.len);
    try std.testing.expectEqual(@as(u32, agent.message_queue_storage.len), agent.message_queue.len());

    // Success path: both sides gain exactly one entry, in lockstep.
    agent.clearQueue();
    try std.testing.expect(enqueueRawMirrored(&app, app.thread, "delivered"));
    try std.testing.expectEqual(@as(usize, 1), app.thread.queued.items.len);
    try std.testing.expectEqual(@as(u32, 1), agent.message_queue.len());
    try std.testing.expect(app.thread.queued.items[0].raw);
}

fn transcriptHasUser(app: *App, needle: []const u8) bool {
    for (app.thread.transcript.messages.items) |m| {
        const body: []const u8 = switch (m) {
            .user => |x| x.body,
            else => continue,
        };
        if (std.mem.indexOf(u8, body, needle) != null) return true;
    }
    return false;
}

const runtime_mod = @import("../runtime.zig");

test "appendSkillInvocationsToTranscript appends formatted skill title to transcript" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_abs = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_abs);
    const home_dir = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_dir);
    var agent = agent_mod.Agent.init(gpa, io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(io, gpa, &agent);
    defer app.deinit();

    var runtime: runtime_mod.AgentRuntime = undefined;
    try runtime.initNew(gpa, io, ".", home_dir, home_dir, "test system prompt", .{}, &.{}, null);
    defer runtime.deinit();
    app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = &runtime, .owns = false } };

    const skills = try gpa.alloc(skill_mod.Skill, 2);
    skills[0] = .{ .name = try gpa.dupe(u8, "skill1"), .description = try gpa.dupe(u8, "desc1"), .path = try gpa.dupe(u8, "path1"), .base_dir = try gpa.dupe(u8, "."), .body = try gpa.dupe(u8, "body1") };
    skills[1] = .{ .name = try gpa.dupe(u8, "skill2"), .description = try gpa.dupe(u8, "desc2"), .path = try gpa.dupe(u8, "path2"), .base_dir = try gpa.dupe(u8, "."), .body = try gpa.dupe(u8, "body2") };
    skill_mod.deinitAll(gpa, runtime.skills);
    runtime.skills = skills;

    try appendSkillInvocationsToTranscript(&app, "Run $skill1 and $skill2 now");

    try std.testing.expectEqual(@as(usize, 2), app.thread.transcript.messages.items.len);
    try std.testing.expectEqualStrings("[SKILL] skill1", app.thread.transcript.messages.items[0].skill.title);
    try std.testing.expectEqualStrings("[SKILL] skill2", app.thread.transcript.messages.items[1].skill.title);
}
