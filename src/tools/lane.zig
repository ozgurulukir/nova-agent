//! The `lane` builtin tool — the model's handle on Nova's parallel-lane
//! machinery. Runs on the worker thread, so it cannot touch App-owned state
//! (threads, split, parked lanes) directly; every action is posted across the
//! `LaneBridge` and resolved by the UI on its tick (see `lane_bridge.zig`).
//!
//! Internal workspace scoping remains covered below for lifecycle compatibility
//! and tests, but the model-facing parser admits worker orchestration commands
//! only. The primary model cannot re-root its own tools into another lane.

const std = @import("std");

const agent_mod = @import("../agent.zig");
const common = @import("common.zig");
const lane_bridge = @import("lane_bridge.zig");

const model_commands = [_][]const u8{ "list", "spawn", "read", "await", "steer", "cancel", "merge", "delete" };
const internal_commands = [_][]const u8{ "list", "create", "enter", "leave", "merge", "spawn", "read", "cancel", "await", "steer", "delete" };

comptime {
    for (model_commands) |command| {
        if (opFromString(command) == null) @compileError("model lane command is not a lane_bridge.Op");
    }
}

pub const tool: common.Tool = .{
    .name = "lane",
    .description = @embedFile("../prompts/tools/lane.md"),
    .schema = .{
        .properties = &.{
            // The dispatch key is `command`, not `action` — models pattern-match
            // on the sibling `bash` tool's first parameter and a miss here made
            // the first lane call fail ("Invalid arguments ... `action` is
            // required") on every model. Each command's required arguments are
            // named in the per-property descriptions below (the flat schema
            // can't express per-command requirements, so the prose must).
            .{
                .name = "command",
                .kind = .string,
                .description = "The worker-lane operation to perform. Always required — one of: list, spawn, read, await, steer, cancel, merge, delete.",
                .required = true,
                .enum_values = &model_commands,
            },
            .{
                .name = "purpose",
                .kind = .string,
                .description = "Optional naming context for `spawn`.",
                .required = false,
                .nullable = true,
            },
            .{
                .name = "task",
                .kind = .string,
                .description = "The worker agent's first prompt. Required for `spawn`; unused otherwise. Make it self-contained — the worker starts with fresh context.",
                .required = false,
                .nullable = true,
            },
            .{
                .name = "lane",
                .kind = .string,
                .description = "Lane id (the hex id shown by `lane list`). Required for `merge`, `read`, `cancel`, `await`, `steer`, and `delete`; optional for `spawn` (targets an existing idle lane to reuse its worktree — omit to create a fresh one). Unused for `list`.",
                .required = false,
                .nullable = true,
            },
            .{
                .name = "steer",
                .kind = .string,
                .description = "Short steering message to inject into a running worker. Required for `steer` only; unused otherwise.",
                .required = false,
                .nullable = true,
            },
        },
    },
    .run = runTool,
    .display = display,
};

/// Internal lifecycle tool used by executor tests for workspace re-rooting.
/// It is deliberately not included in the builtin registry or model schema.
pub const internal_tool: common.Tool = .{
    .name = "lane",
    .description = "Internal lane lifecycle bridge.",
    .schema = .{
        .properties = &.{
            .{ .name = "command", .kind = .string, .description = "Internal lane operation.", .required = true, .enum_values = &internal_commands },
            .{ .name = "purpose", .kind = .string, .description = "Lane purpose.", .required = false, .nullable = true },
            .{ .name = "task", .kind = .string, .description = "Worker task.", .required = false, .nullable = true },
            .{ .name = "lane", .kind = .string, .description = "Lane id.", .required = false, .nullable = true },
            .{ .name = "steer", .kind = .string, .description = "Steering message.", .required = false, .nullable = true },
        },
    },
    .run = runInternalTool,
    .display = display,
};

const Args = struct {
    command: lane_bridge.Op,
    purpose: ?[]const u8 = null,
    task: ?[]const u8 = null,
    lane: ?[]const u8 = null,
    steer: ?[]const u8 = null,

    fn deinit(self: *Args, gpa: std.mem.Allocator) void {
        if (self.purpose) |s| gpa.free(s);
        if (self.task) |s| gpa.free(s);
        if (self.lane) |s| gpa.free(s);
        if (self.steer) |s| gpa.free(s);
        self.* = undefined;
    }
};

const JsonArgs = struct {
    command: ?[]const u8 = null,
    purpose: ?[]const u8 = null,
    task: ?[]const u8 = null,
    lane: ?[]const u8 = null,
    steer: ?[]const u8 = null,
    // Detector only — never read. `ignore_unknown_fields` would silently drop
    // an `id` the model sent instead of the canonical `lane`, leaving it stuck
    // repeating the same miss. Surfaced as a WrongField error below instead.
    id: ?[]const u8 = null,
};

const ParseError = error{ InvalidAction, DriverOnlyAction, WrongField, OutOfMemory };

fn parseArgs(gpa: std.mem.Allocator, arguments: []const u8) ParseError!Args {
    return parseArgsWithMode(gpa, arguments, false);
}

fn parseInternalArgs(gpa: std.mem.Allocator, arguments: []const u8) ParseError!Args {
    return parseArgsWithMode(gpa, arguments, true);
}

fn parseArgsWithMode(gpa: std.mem.Allocator, arguments: []const u8, allow_workspace_ops: bool) ParseError!Args {
    const parsed = std.json.parseFromSlice(JsonArgs, gpa, arguments, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAction,
    };
    defer parsed.deinit();
    const command_str = parsed.value.command orelse return error.InvalidAction;
    const command = opFromString(command_str) orelse return error.InvalidAction;
    if (!allow_workspace_ops and !isModelCommand(command_str)) return error.DriverOnlyAction;

    // The canonical field is `lane`. `id` is a common model guess (the bare
    // value surfaces unlabelled in `lane list`), so reject it explicitly instead
    // of letting `ignore_unknown_fields` drop it — otherwise the model loops on
    // "needs a lane id" while believing it already sent one. When both are
    // present, the canonical `lane` wins.
    if (parsed.value.id != null and parsed.value.lane == null) return error.WrongField;

    var out = Args{ .command = command };
    errdefer out.deinit(gpa);
    if (parsed.value.purpose) |s| out.purpose = try gpa.dupe(u8, s);
    if (parsed.value.task) |s| out.task = try gpa.dupe(u8, s);
    if (parsed.value.lane) |s| out.lane = try gpa.dupe(u8, s);
    if (parsed.value.steer) |s| out.steer = try gpa.dupe(u8, s);
    return out;
}

fn opFromString(s: []const u8) ?lane_bridge.Op {
    const ops = std.meta.tags(lane_bridge.Op);
    inline for (ops) |op| {
        if (std.mem.eql(u8, s, @tagName(op))) return op;
    }
    return null;
}

fn isModelCommand(s: []const u8) bool {
    for (model_commands) |command| {
        if (std.mem.eql(u8, s, command)) return true;
    }
    return false;
}

fn parseError(gpa: std.mem.Allocator, err: ParseError) common.Error!common.Output {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DriverOnlyAction => common.failFmt(
            gpa,
            1,
            "lane: driver workspace commands (`create`, `enter`, `leave`) are unavailable to the model; use `spawn` for worker work\n",
            .{},
        ),
        error.InvalidAction => common.failFmt(
            gpa,
            1,
            "lane: invalid arguments — `command` must be one of: list, spawn, read, await, steer, cancel, merge, delete; driver workspace commands are unavailable to the model\n",
            .{},
        ),
        // Models learn the field name from output + schema; a misspelled `id`
        // must surface as a named-field hint, not a silent drop. Points at the
        // canonical `lane` field for id-bearing worker operations.
        error.WrongField => common.failFmt(
            gpa,
            1,
            "lane: this tool has no `id` parameter — pass a lane id as the `lane` field (e.g. {{\"command\":\"read\",\"lane\":\"e1e94861c257\"}}); for `create`, the title is the `purpose` field\n",
            .{},
        ),
    };
}

pub fn runTool(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
    userdata: *anyopaque,
) common.Error!common.Output {
    return runToolWithMode(gpa, io, cwd, arguments, userdata, false);
}

pub fn runInternalTool(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
    userdata: *anyopaque,
) common.Error!common.Output {
    return runToolWithMode(gpa, io, cwd, arguments, userdata, true);
}

fn runToolWithMode(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
    userdata: *anyopaque,
    allow_workspace_ops: bool,
) common.Error!common.Output {
    _ = cwd;
    _ = userdata;
    // Null slot is defined behavior: headless/tests have no bridge.
    const slot = lane_bridge.lane_bridge_slot;
    const bridge = slot.bridge orelse return common.failFmt(gpa, 1, "lane: lanes are unavailable in this context\n", .{});
    const requester = slot.requester orelse return common.failFmt(gpa, 1, "lane: no lane requester attached\n", .{});

    var parsed = parseArgsWithMode(gpa, arguments, allow_workspace_ops) catch |err| return parseError(gpa, err);
    defer parsed.deinit(gpa);

    var req = lane_bridge.Request{
        .op = parsed.command,
        .purpose = parsed.purpose,
        .task = parsed.task,
        .lane = parsed.lane,
        .steer = parsed.steer,
        .requester = requester,
    };
    defer req.deinit(gpa);
    // Ownership of the string fields moved into `req` — `parsed` must not free
    // them too or the slices are double-freed (PageAllocator unmaps on the
    // first free, so the second `@memset` in free() segfaults). Only `req`
    // frees them now.
    parsed.purpose = null;
    parsed.task = null;
    parsed.lane = null;
    parsed.steer = null;

    const resp = bridge.request(io, &req) catch |err| switch (err) {
        // `request` only yields `error.Canceled` (the owning future was
        // cancelled); the tool degrades to a terse observation.
        error.Canceled => return common.failFmt(gpa, 1, "lane: interrupted\n", .{}),
    };
    // `text` is owned by the UI; everything else in the response is borrowed.
    defer gpa.free(resp.text);

    // Workspace scoping is a worker-thread write, read by the next tool call
    // (H4). `enter` borrows the lane's path; `leave` drops the borrow. The
    // lane Thread owns the path and is guaranteed alive (S17). The write goes
    // through `setWorkspace` so the UI thread's reads (`driverWorkspace`,
    // `clearWorkspaceBorrowForPath`) are mutex-guarded against the tear.
    // Only enter/leave touch the agent — list/read/etc. skip the cast.
    if (parsed.command == .enter or parsed.command == .leave) {
        const agent: *agent_mod.Agent = @ptrCast(@alignCast(requester));
        switch (parsed.command) {
            .enter => {
                if (resp.path) |path| agent.setWorkspace(path);
            },
            .leave => agent.setWorkspace(null),
            else => {},
        }
    }

    const stdout = try gpa.dupe(u8, resp.text);
    const stderr = try gpa.alloc(u8, 0);
    return .{ .stdout = stdout, .stderr = stderr, .code = resp.code };
}

fn display(gpa: std.mem.Allocator, args: []const u8, userdata: *anyopaque) std.mem.Allocator.Error!common.ToolDisplay {
    _ = userdata;
    const Probe = struct { command: ?[]const u8 = null, lane: ?[]const u8 = null };
    const parsed = std.json.parseFromSlice(Probe, gpa, args, .{ .ignore_unknown_fields = true }) catch {
        return .{ .label = try gpa.dupe(u8, "lane") };
    };
    defer parsed.deinit();
    const command = parsed.value.command orelse return .{ .label = try gpa.dupe(u8, "lane") };
    if (parsed.value.lane) |lane_id| {
        return .{ .label = try std.fmt.allocPrint(gpa, "lane {s} {s}", .{ command, lane_id }) };
    }
    return .{ .label = try std.fmt.allocPrint(gpa, "lane {s}", .{command}) };
}

test "lane parses a full argument set" {
    const gpa = std.testing.allocator;
    var args = try parseArgs(gpa, "{\"command\":\"spawn\",\"purpose\":\"evaluate PR #82\",\"task\":\"Review the diff\",\"lane\":\"abc123\"}");
    defer args.deinit(gpa);
    try std.testing.expectEqual(lane_bridge.Op.spawn, args.command);
    try std.testing.expectEqualStrings("evaluate PR #82", args.purpose.?);
    try std.testing.expectEqualStrings("Review the diff", args.task.?);
    try std.testing.expectEqualStrings("abc123", args.lane.?);
}

test "lane rejects a missing or unknown command" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidAction, parseArgs(gpa, "{}"));
    try std.testing.expectError(error.InvalidAction, parseArgs(gpa, "{\"command\":\"nope\"}"));
    // The dispatch key is `command` — the old `action`-keyed shape (the
    // model's original miss) is unknown fields only, so it must fail too.
    try std.testing.expectError(error.InvalidAction, parseArgs(gpa, "{\"action\":\"list\"}"));
}

test "lane accepts only model worker commands" {
    const gpa = std.testing.allocator;
    const property = tool.schema.properties[0];
    const enum_values = property.enum_values.?;
    try std.testing.expectEqual(model_commands.len, enum_values.len);
    for (model_commands, enum_values) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
        const arguments = try std.fmt.allocPrint(gpa, "{{\"command\":\"{s}\"}}", .{expected});
        defer gpa.free(arguments);
        var args = try parseArgs(gpa, arguments);
        defer args.deinit(gpa);
        try std.testing.expectEqual(opFromString(expected).?, args.command);
    }
    try std.testing.expectError(error.DriverOnlyAction, parseArgs(gpa, "{\"command\":\"create\"}"));
    try std.testing.expectError(error.DriverOnlyAction, parseArgs(gpa, "{\"command\":\"enter\"}"));
    try std.testing.expectError(error.DriverOnlyAction, parseArgs(gpa, "{\"command\":\"leave\"}"));
}

test "lane reports driver-only commands without posting a bridge request" {
    const gpa = std.testing.allocator;
    var bridge: lane_bridge.LaneBridge = .{};
    const AgentAligned = struct { _: u8 align(@alignOf(agent_mod.Agent)) };
    var dummy: AgentAligned = .{ ._ = 0 };

    const prev = lane_bridge.lane_bridge_slot;
    defer lane_bridge.lane_bridge_slot = prev;
    lane_bridge.lane_bridge_slot = .{ .bridge = &bridge, .requester = &dummy };

    var output = try runTool(gpa, std.testing.io, ".", "{\"command\":\"enter\"}", undefined);
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "unavailable to the model") != null);
    try std.testing.expect(bridge.pending == null);
}

test "lane invalid-action diagnostics advertise only worker commands" {
    const gpa = std.testing.allocator;
    var output = try parseError(gpa, error.InvalidAction);
    defer output.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "list, spawn, read, await, steer, cancel, merge, delete") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "list, create") == null);
}

test "lane rejects an `id` field and points at the canonical `lane` field" {
    // The canonical lane-id field is `lane`. A common model guess is `id`
    // (the bare value surfaces unlabelled in `lane list`, so models infer the
    // wrong key). It must surface as WrongField, not be silently dropped —
    // otherwise the model loops on "needs a lane id" while believing it sent one.
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.WrongField, parseArgs(gpa, "{\"command\":\"read\",\"id\":\"e1e94861c257\"}"));
}

test "lane prefers the canonical `lane` field when both `lane` and `id` are present" {
    const gpa = std.testing.allocator;
    var args = try parseArgs(gpa, "{\"command\":\"read\",\"lane\":\"abc\",\"id\":\"xyz\"}");
    defer args.deinit(gpa);
    // Canonical wins; the stray `id` is ignored because `lane` satisfied it.
    try std.testing.expectEqualStrings("abc", args.lane.?);
}

test "lane opFromString still resolves internal operations" {
    try std.testing.expectEqual(lane_bridge.Op.create, opFromString("create").?);
    try std.testing.expectEqual(lane_bridge.Op.enter, opFromString("enter").?);
    try std.testing.expectEqual(lane_bridge.Op.leave, opFromString("leave").?);
    try std.testing.expect(opFromString("bogus") == null);
}

test "lane run without a bridge slot reports lanes unavailable" {
    const gpa = std.testing.allocator;
    const prev = lane_bridge.lane_bridge_slot;
    defer lane_bridge.lane_bridge_slot = prev;
    lane_bridge.lane_bridge_slot = .{};
    var output = try runTool(gpa, std.testing.io, ".", "{\"command\":\"list\"}", undefined);
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "lanes are unavailable") != null);
}

test "lane run against a stub bridge resolves a request end-to-end" {
    const gpa = std.testing.allocator;
    var bridge: lane_bridge.LaneBridge = .{};
    // A requester aligned like `*Agent` (the tool never dereferences it for
    // `list`, but the @alignCast in the enter/leave path must be satisfiable).
    const AgentAligned = struct { _: u8 align(@alignOf(agent_mod.Agent)) };
    var dummy: AgentAligned = .{ ._ = 0 };

    const Handler = struct {
        fn handle(_: *anyopaque, req: *const lane_bridge.Request) ?lane_bridge.Response {
            std.debug.assert(req.op == .list);
            return lane_bridge.response(std.testing.allocator, "one lane\n", .{}, null, null) catch unreachable;
        }
    };

    const prev = lane_bridge.lane_bridge_slot;
    defer lane_bridge.lane_bridge_slot = prev;
    lane_bridge.lane_bridge_slot = .{ .bridge = &bridge, .requester = &dummy };

    const Worker = struct {
        fn run(b: *lane_bridge.LaneBridge, allocator: std.mem.Allocator, out: *common.Output) void {
            _ = b;
            out.* = runTool(allocator, std.testing.io, ".", "{\"command\":\"list\"}", undefined) catch |err| {
                std.debug.print("runTool failed: {s}\n", .{@errorName(err)});
                return;
            };
        }
    };
    var result: common.Output = undefined;
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ &bridge, gpa, &result });
    var spins: u32 = 0;
    while (spins < 10_000) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(2), .awake) catch {};
        bridge.mutex.lock(std.testing.io) catch continue;
        const posted = bridge.pending != null;
        bridge.mutex.unlock(std.testing.io);
        if (posted) break;
    }
    try std.testing.expect(bridge.pending != null);
    bridge.service(std.testing.io, undefined, &Handler.handle);
    thread.join();
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expectEqualStrings("one lane\n", result.stdout);
}

test "lane run with string fields (spawn-style) does not double-free the args" {
    // The tool moved the parsed Args' string fields into the bridge Request
    // but then deinit'd BOTH — a double free that PageAllocator turns into a
    // segfault at the free() `@memset`. The earlier stub tests only used
    // `list`/`enter` (no string fields), so this path was uncovered.
    const gpa = std.testing.allocator;
    var bridge: lane_bridge.LaneBridge = .{};
    const AgentAligned = struct { _: u8 align(@alignOf(agent_mod.Agent)) };
    var dummy: AgentAligned = .{ ._ = 0 };

    const Handler = struct {
        fn handle(_: *anyopaque, req: *const lane_bridge.Request) ?lane_bridge.Response {
            std.debug.assert(req.op == .spawn);
            std.debug.assert(req.task != null); // the moved field must arrive intact
            return lane_bridge.response(std.testing.allocator, "spawned\n", .{}, "abc", null) catch unreachable;
        }
    };

    const prev = lane_bridge.lane_bridge_slot;
    defer lane_bridge.lane_bridge_slot = prev;
    lane_bridge.lane_bridge_slot = .{ .bridge = &bridge, .requester = &dummy };

    const Worker = struct {
        fn run(b: *lane_bridge.LaneBridge, allocator: std.mem.Allocator, out: *common.Output) void {
            _ = b;
            const args = "{\"command\":\"spawn\",\"task\":\"do work\",\"purpose\":\"eval\",\"lane\":\"abc\",\"steer\":\"x\"}";
            out.* = runTool(allocator, std.testing.io, ".", args, undefined) catch |err| {
                std.debug.print("runTool failed: {s}\n", .{@errorName(err)});
                return;
            };
        }
    };
    var result: common.Output = undefined;
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ &bridge, gpa, &result });
    var spins: u32 = 0;
    while (spins < 10_000) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(2), .awake) catch {};
        bridge.mutex.lock(std.testing.io) catch continue;
        const posted = bridge.pending != null;
        bridge.mutex.unlock(std.testing.io);
        if (posted) break;
    }
    try std.testing.expect(bridge.pending != null);
    bridge.service(std.testing.io, undefined, &Handler.handle);
    thread.join();
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expectEqualStrings("spawned\n", result.stdout);
}

test "lane enter/leave write the agent workspace via the bridge" {
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var bridge: lane_bridge.LaneBridge = .{};

    const Handler = struct {
        const path = "THE_LANE_PATH";
        fn handle(_: *anyopaque, req: *const lane_bridge.Request) ?lane_bridge.Response {
            _ = req;
            return lane_bridge.response(std.testing.allocator, "ok\n", .{}, null, path) catch unreachable;
        }
    };

    const Worker = struct {
        fn run(b: *lane_bridge.LaneBridge, a: *agent_mod.Agent, action: []const u8) void {
            const args = std.fmt.allocPrint(std.testing.allocator, "{{\"command\":\"{s}\"}}", .{action}) catch unreachable;
            defer std.testing.allocator.free(args);
            var output = runInternalTool(std.testing.allocator, std.testing.io, ".", args, undefined) catch |err| {
                std.debug.print("runTool failed: {s}\n", .{@errorName(err)});
                return;
            };
            output.deinit(std.testing.allocator);
            _ = b;
            _ = a;
        }
    };

    const prev = lane_bridge.lane_bridge_slot;
    defer lane_bridge.lane_bridge_slot = prev;
    lane_bridge.lane_bridge_slot = .{ .bridge = &bridge, .requester = &agent };

    // ── enter: the tool borrows the returned path as the workspace.
    const thread1 = try std.Thread.spawn(.{}, Worker.run, .{ &bridge, &agent, "enter" });
    var spins: u32 = 0;
    while (spins < 10_000) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(2), .awake) catch {};
        bridge.mutex.lock(std.testing.io) catch continue;
        const posted = bridge.pending != null;
        bridge.mutex.unlock(std.testing.io);
        if (posted) break;
    }
    try std.testing.expect(bridge.pending != null);
    bridge.service(std.testing.io, undefined, &Handler.handle);
    thread1.join();
    try std.testing.expectEqualStrings(Handler.path, agent.workspaceBorrow().?);
    try std.testing.expectEqualStrings(Handler.path, agent.effectiveCwd());

    // ── leave: the tool clears the borrow.
    const thread2 = try std.Thread.spawn(.{}, Worker.run, .{ &bridge, &agent, "leave" });
    spins = 0;
    while (spins < 10_000) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(2), .awake) catch {};
        bridge.mutex.lock(std.testing.io) catch continue;
        const posted = bridge.pending != null;
        bridge.mutex.unlock(std.testing.io);
        if (posted) break;
    }
    try std.testing.expect(bridge.pending != null);
    bridge.service(std.testing.io, undefined, &Handler.handle);
    thread2.join();
    try std.testing.expect(agent.workspaceBorrow() == null);
    try std.testing.expectEqualStrings(".", agent.effectiveCwd());
}
