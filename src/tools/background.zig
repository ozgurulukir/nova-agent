//! The `background` builtin tool — enables the agent to query and manage
//! long-running background jobs started with `run_in_background: true`.
//! Reaches `BackgroundManager` through a scoped thread-local slot (`background_slot`)
//! bound in `ExecutorService.produceOutput`.

const std = @import("std");

const background = @import("../background.zig");
const common = @import("common.zig");

pub const BackgroundSlot = struct {
    manager: ?*background.BackgroundManager = null,
    owner_generation: u64 = 1,
};

pub threadlocal var background_slot: BackgroundSlot = .{};

pub const tool: common.Tool = .{
    .name = "background",
    .description = @embedFile("../prompts/tools/background.md"),
    .schema = .{
        .properties = &.{
            .{
                .name = "command",
                .kind = .string,
                .description = "The background job operation to perform. Always required — one of: list, status, cancel, tail.",
                .required = true,
                .enum_values = &.{ "list", "status", "cancel", "tail" },
            },
            .{
                .name = "id",
                .kind = .integer,
                .description = "Job id (e.g. 1 for bg_1). Required for status, cancel, and tail; unused for list.",
                .required = false,
                .nullable = true,
            },
            .{
                .name = "lines",
                .kind = .integer,
                .description = "Number of tail lines to inspect (default 50, max 200). Used for tail; unused otherwise.",
                .required = false,
                .nullable = true,
            },
        },
    },
    .run = runTool,
    .display = display,
};

pub const Op = enum {
    list,
    status,
    cancel,
    tail,
};

pub const Args = struct {
    command: Op,
    id: ?u32 = null,
    lines: ?u32 = null,
};

const JsonArgs = struct {
    command: ?[]const u8 = null,
    id: ?i64 = null,
    lines: ?i64 = null,
};

pub const ParseError = error{ InvalidAction, MissingJobId, OutOfMemory };

pub fn parseArgs(gpa: std.mem.Allocator, arguments: []const u8) ParseError!Args {
    const parsed = std.json.parseFromSlice(JsonArgs, gpa, arguments, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAction,
    };
    defer parsed.deinit();
    const command_str = parsed.value.command orelse return error.InvalidAction;
    const command = opFromString(command_str) orelse return error.InvalidAction;

    var id_val: ?u32 = null;
    if (parsed.value.id) |raw_id| {
        if (raw_id <= 0 or raw_id > std.math.maxInt(u32)) return error.InvalidAction;
        id_val = @intCast(raw_id);
    }

    if (command != .list and id_val == null) {
        return error.MissingJobId;
    }

    var lines_val: ?u32 = null;
    if (parsed.value.lines) |raw_lines| {
        if (raw_lines <= 0) return error.InvalidAction;
        lines_val = @intCast(@min(raw_lines, 200));
    }

    return .{
        .command = command,
        .id = id_val,
        .lines = lines_val,
    };
}

fn opFromString(s: []const u8) ?Op {
    const ops = std.meta.tags(Op);
    inline for (ops) |op| {
        if (std.mem.eql(u8, s, @tagName(op))) return op;
    }
    return null;
}

fn formatElapsed(buf: []u8, total_seconds: u64) []const u8 {
    if (total_seconds < 60) return std.fmt.bufPrint(buf, "{d}s", .{total_seconds}) catch "?";
    const minutes = total_seconds / 60;
    const seconds = total_seconds % 60;
    if (minutes < 60) return std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ minutes, seconds }) catch "?";
    const hours = minutes / 60;
    const rem_minutes = minutes % 60;
    return std.fmt.bufPrint(buf, "{d}h {d:0>2}m", .{ hours, rem_minutes }) catch "?";
}

pub fn readLogTailBounded(
    io: std.Io,
    gpa: std.mem.Allocator,
    log_path: []const u8,
    max_lines: u32,
) ![]u8 {
    var file = if (std.fs.path.isAbsolute(log_path))
        std.Io.Dir.openFileAbsolute(io, log_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return try gpa.dupe(u8, "(log file not found)\n");
            }
            return err;
        }
    else
        std.Io.Dir.openFile(.cwd(), io, log_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return try gpa.dupe(u8, "(log file not found)\n");
            }
            return err;
        };
    defer file.close(io);

    const stat = file.stat(io) catch |err| return err;
    const file_size: usize = @intCast(stat.size);
    if (file_size == 0) {
        return try gpa.dupe(u8, "(no output yet)\n");
    }

    const max_bytes_to_scan: usize = 64 * 1024;
    const read_len: usize = @min(file_size, max_bytes_to_scan);
    const read_offset: u64 = @intCast(file_size - read_len);

    const buf = try gpa.alloc(u8, read_len);
    defer gpa.free(buf);

    const actual_read = try file.readPositionalAll(io, buf, read_offset);
    const slice = buf[0..actual_read];
    if (slice.len == 0) {
        return try gpa.dupe(u8, "(no output yet)\n");
    }

    var lines_found: u32 = 0;
    var start_idx: usize = slice.len;
    var i: usize = slice.len;
    if (i > 0 and slice[i - 1] == '\n') {
        i -= 1;
    }
    while (i > 0) {
        i -= 1;
        if (slice[i] == '\n') {
            lines_found += 1;
            if (lines_found >= max_lines) {
                start_idx = i + 1;
                break;
            }
        }
    }
    if (lines_found < max_lines) {
        start_idx = 0;
    }

    while (start_idx < slice.len and (slice[start_idx] & 0xC0) == 0x80) start_idx += 1;

    const tail_slice = slice[start_idx..];
    return try gpa.dupe(u8, tail_slice);
}

pub fn handleList(
    gpa: std.mem.Allocator,
    manager: *background.BackgroundManager,
) common.Error!common.Output {
    const views = manager.snapshot(gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return common.failFmt(gpa, 1, "background: failed to snapshot jobs: {s}\n", .{@errorName(err)}),
    };
    defer background.BackgroundManager.freeViews(gpa, views);

    if (views.len == 0) {
        return common.ok(gpa, try gpa.dupe(u8, "No active background jobs running.\n"));
    }

    var writer: std.Io.Writer.Allocating = .init(gpa);
    defer writer.deinit();

    writer.writer.print("Active background jobs ({d}):\n", .{views.len}) catch return error.OutOfMemory;
    for (views) |v| {
        writer.writer.print("- Job {d} ({s}): running for {d}s | command: `{s}` | log: {s}\n", .{
            v.id,
            v.label,
            v.elapsed_seconds,
            v.command,
            v.log_path,
        }) catch return error.OutOfMemory;
    }

    const output = writer.toOwnedSlice() catch return error.OutOfMemory;
    return common.ok(gpa, output);
}

pub fn handleStatus(
    io: std.Io,
    gpa: std.mem.Allocator,
    manager: *background.BackgroundManager,
    id: u32,
) common.Error!common.Output {
    const views = manager.snapshot(gpa) catch return error.OutOfMemory;
    defer background.BackgroundManager.freeViews(gpa, views);

    for (views) |v| {
        if (v.id == id) {
            const tail_content = readLogTailBounded(io, gpa, v.log_path, 20) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => try std.fmt.allocPrint(gpa, "(unable to read log tail: {s})\n", .{@errorName(err)}),
            };
            defer gpa.free(tail_content);

            const text = try std.fmt.allocPrint(
                gpa,
                "Job {d} ({s}): {s}\nCommand: `{s}`\nElapsed: {d} seconds\nLog file: {s}\n\nRecent output:\n{s}",
                .{ v.id, v.label, if (v.terminating) "TERMINATING" else "RUNNING", v.command, v.elapsed_seconds, v.log_path, tail_content },
            );
            return common.ok(gpa, text);
        }
    }

    return common.failFmt(gpa, 1, "background: no running job found with id {d}\n", .{id});
}

pub fn handleCancel(
    gpa: std.mem.Allocator,
    manager: *background.BackgroundManager,
    id: u32,
) common.Error!common.Output {
    const cancelled = manager.cancel(id);
    if (cancelled) {
        return common.ok(gpa, try std.fmt.allocPrint(gpa, "Termination requested for background job {d}.\n", .{id}));
    }
    return common.failFmt(gpa, 1, "background: no running job found with id {d} to cancel\n", .{id});
}

pub fn handleTail(
    io: std.Io,
    gpa: std.mem.Allocator,
    manager: *background.BackgroundManager,
    id: u32,
    lines: u32,
) common.Error!common.Output {
    const views = manager.snapshot(gpa) catch return error.OutOfMemory;
    defer background.BackgroundManager.freeViews(gpa, views);

    var target_log: ?[]u8 = null;
    defer if (target_log) |p| gpa.free(p);

    for (views) |v| {
        if (v.id == id) {
            target_log = try gpa.dupe(u8, v.log_path);
            break;
        }
    }

    const log_path = target_log orelse return common.failFmt(gpa, 1, "background: no running job found with id {d}\n", .{id});
    const content = readLogTailBounded(io, gpa, log_path, lines) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return common.failFmt(gpa, 1, "background: failed to read log file '{s}': {s}\n", .{ log_path, @errorName(err) }),
    };
    defer gpa.free(content);

    return common.ok(gpa, try std.fmt.allocPrint(gpa, "Log tail for job {d} (last {d} lines):\n{s}", .{ id, lines, content }));
}

pub fn runTool(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    arguments: []const u8,
    userdata: *anyopaque,
) common.Error!common.Output {
    _ = cwd;
    _ = userdata;
    const slot = background_slot;
    const mgr = slot.manager orelse return common.failFmt(gpa, 1, "background: background execution is unavailable in this context\n", .{});

    const parsed = parseArgs(gpa, arguments) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidAction => common.failFmt(
            gpa,
            1,
            "background: invalid arguments — `command` must be one of: list, status, cancel, tail\n",
            .{},
        ),
        error.MissingJobId => common.failFmt(
            gpa,
            1,
            "background: `id` is required for this command\n",
            .{},
        ),
    };

    switch (parsed.command) {
        .list => return handleList(gpa, mgr),
        .status => {
            return handleStatus(io, gpa, mgr, parsed.id.?);
        },
        .cancel => {
            return handleCancel(gpa, mgr, parsed.id.?);
        },
        .tail => {
            return handleTail(io, gpa, mgr, parsed.id.?, parsed.lines orelse 50);
        },
    }
}

pub fn display(
    gpa: std.mem.Allocator,
    args: []const u8,
    userdata: *anyopaque,
) std.mem.Allocator.Error!common.ToolDisplay {
    _ = userdata;
    const Probe = struct { command: ?[]const u8 = null, id: ?u32 = null };
    const parsed = std.json.parseFromSlice(Probe, gpa, args, .{ .ignore_unknown_fields = true }) catch {
        return .{ .label = try gpa.dupe(u8, "bg") };
    };
    defer parsed.deinit();

    const cmd = parsed.value.command orelse return .{ .label = try gpa.dupe(u8, "bg") };
    if (parsed.value.id) |id| {
        return .{ .label = try std.fmt.allocPrint(gpa, "bg {s} {d}", .{ cmd, id }) };
    }
    return .{ .label = try std.fmt.allocPrint(gpa, "bg {s}", .{cmd}) };
}

// ── Unit Tests ──

test "background parseArgs parses valid commands" {
    const gpa = std.testing.allocator;

    {
        const args = try parseArgs(gpa, "{\"command\":\"list\"}");
        try std.testing.expectEqual(Op.list, args.command);
        try std.testing.expectEqual(@as(?u32, null), args.id);
        try std.testing.expectEqual(@as(?u32, null), args.lines);
    }

    {
        const args = try parseArgs(gpa, "{\"command\":\"status\",\"id\":3}");
        try std.testing.expectEqual(Op.status, args.command);
        try std.testing.expectEqual(@as(?u32, 3), args.id);
        try std.testing.expectEqual(@as(?u32, null), args.lines);
    }

    {
        const args = try parseArgs(gpa, "{\"command\":\"cancel\",\"id\":5}");
        try std.testing.expectEqual(Op.cancel, args.command);
        try std.testing.expectEqual(@as(?u32, 5), args.id);
        try std.testing.expectEqual(@as(?u32, null), args.lines);
    }

    {
        const args = try parseArgs(gpa, "{\"command\":\"tail\",\"id\":2,\"lines\":80}");
        try std.testing.expectEqual(Op.tail, args.command);
        try std.testing.expectEqual(@as(?u32, 2), args.id);
        try std.testing.expectEqual(@as(?u32, 80), args.lines);
    }
}

test "background parseArgs caps lines at 200" {
    const gpa = std.testing.allocator;
    const args = try parseArgs(gpa, "{\"command\":\"tail\",\"id\":1,\"lines\":500}");
    try std.testing.expectEqual(@as(?u32, 200), args.lines);
}

test "background parseArgs rejects invalid commands or negative values" {
    const gpa = std.testing.allocator;

    try std.testing.expectError(error.InvalidAction, parseArgs(gpa, "{\"command\":\"unknown\"}"));
    try std.testing.expectError(error.MissingJobId, parseArgs(gpa, "{\"command\":\"status\"}"));
    try std.testing.expectError(error.MissingJobId, parseArgs(gpa, "{\"command\":\"cancel\"}"));
    try std.testing.expectError(error.MissingJobId, parseArgs(gpa, "{\"command\":\"tail\"}"));
}

test "background display formats labels correctly" {
    const gpa = std.testing.allocator;

    {
        var d = try display(gpa, "{\"command\":\"list\"}", undefined);
        defer d.deinit(gpa);
        try std.testing.expectEqualStrings("bg list", d.label);
    }

    {
        var d = try display(gpa, "{\"command\":\"cancel\",\"id\":1}", undefined);
        defer d.deinit(gpa);
        try std.testing.expectEqualStrings("bg cancel 1", d.label);
    }

    {
        var d = try display(gpa, "{}", undefined);
        defer d.deinit(gpa);
        try std.testing.expectEqualStrings("bg", d.label);
    }
}

test "readLogTailBounded reads trailing lines accurately" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const log_path = try @import("bash_exec.zig").namedTempPath(gpa, "nova-test-tail.log");
    defer gpa.free(log_path);
    defer std.Io.Dir.deleteFile(.cwd(), io, log_path) catch {};

    var file = try std.Io.Dir.createFileAbsolute(io, log_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "line 1\nline 2\nline 3\nline 4\nline 5\n");

    const tail_2 = try readLogTailBounded(io, gpa, log_path, 2);
    defer gpa.free(tail_2);
    try std.testing.expectEqualStrings("line 4\nline 5\n", tail_2);

    const tail_10 = try readLogTailBounded(io, gpa, log_path, 10);
    defer gpa.free(tail_10);
    try std.testing.expectEqualStrings("line 1\nline 2\nline 3\nline 4\nline 5\n", tail_10);
}

test "background tool reports unavailable when slot is null" {
    const gpa = std.testing.allocator;
    const prev = background_slot;
    defer background_slot = prev;
    background_slot = .{};

    var output = try runTool(gpa, std.testing.io, ".", "{\"command\":\"list\"}", undefined);
    defer output.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "background execution is unavailable") != null);
}

test "background tool executes list, status, cancel, and tail with active manager" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var manager = background.BackgroundManager.init(io, gpa);
    defer manager.deinit();

    const prev = background_slot;
    defer background_slot = prev;
    background_slot = .{ .manager = &manager, .owner_generation = 1 };

    // 1. List with no jobs
    {
        var output = try runTool(gpa, io, ".", "{\"command\":\"list\"}", undefined);
        defer output.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 0), output.code);
        try std.testing.expectEqualStrings("No active background jobs running.\n", output.stdout);
    }

    // 2. Status for non-existent job
    {
        var output = try runTool(gpa, io, ".", "{\"command\":\"status\",\"id\":99}", undefined);
        defer output.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 1), output.code);
        try std.testing.expect(std.mem.indexOf(u8, output.stderr, "no running job found with id 99") != null);
    }

    // 3. Status missing id
    {
        var output = try runTool(gpa, io, ".", "{\"command\":\"status\"}", undefined);
        defer output.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 1), output.code);
        try std.testing.expect(std.mem.indexOf(u8, output.stderr, "`id` is required") != null);
    }

    // 4. Cancel non-existent job
    {
        var output = try runTool(gpa, io, ".", "{\"command\":\"cancel\",\"id\":99}", undefined);
        defer output.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 1), output.code);
        try std.testing.expect(std.mem.indexOf(u8, output.stderr, "no running job found with id 99") != null);
    }

    // 5. Tail non-existent job
    {
        var output = try runTool(gpa, io, ".", "{\"command\":\"tail\",\"id\":99}", undefined);
        defer output.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 1), output.code);
        try std.testing.expect(std.mem.indexOf(u8, output.stderr, "no running job found with id 99") != null);
    }
}
