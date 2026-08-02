//! Local bash command safety classifier client.
//!
//! When the remote classifier is unavailable, a simple local pattern matcher
//! provides defense-in-depth against obviously destructive commands.

const std = @import("std");

const assert = std.debug.assert;

const response_bytes_max: u32 = 4096;
const redirect_buffer_bytes: u32 = 8192;

pub const Verdict = enum {
    safe,
    unsafe,
    unavailable,
};

pub fn commandFromArguments(gpa: std.mem.Allocator, arguments: []const u8) ![]u8 {
    const JsonArgs = struct {
        command: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(JsonArgs, gpa, arguments, .{ .ignore_unknown_fields = true }) catch return error.InvalidToolArguments;
    defer parsed.deinit();
    const command = parsed.value.command orelse return error.InvalidToolArguments;
    if (command.len == 0) return error.InvalidToolArguments;
    return try gpa.dupe(u8, command);
}

pub fn classify(
    gpa: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    cwd: []const u8,
    command: []const u8,
) Verdict {
    assert(url.len > 0);
    assert(cwd.len > 0);
    assert(command.len > 0);

    const remote = classifyFallible(gpa, io, url, cwd, command) catch {
        // Remote classifier unavailable — fall back to local pattern matching.
        return localClassify(command);
    };
    return remote;
}

/// Local pattern-based safety check, used when the remote classifier is
/// unavailable. This is defense-in-depth, not a replacement for the model.
/// Returns `.unsafe` for obviously destructive commands, `.safe` otherwise.
fn localClassify(command: []const u8) Verdict {
    const trimmed = std.mem.trim(u8, command, &std.ascii.whitespace);
    if (trimmed.len == 0) return .safe;

    // Fork bombs and infinite-recursion shell constructs.
    if (std.mem.indexOf(u8, trimmed, ":(){") != null) return .unsafe;
    if (std.mem.indexOf(u8, trimmed, ":()") != null) return .unsafe;

    // Destructive disk operations on system paths.
    if (isDangerousRm(trimmed)) return .unsafe;
    if (isDangerousDd(trimmed)) return .unsafe;
    if (isDangerousMkfs(trimmed)) return .unsafe;

    // Overwriting critical system files.
    if (isDangerousRedirect(trimmed)) return .unsafe;

    return .safe;
}

/// Check for `rm -rf /`, `rm -rf /*`, `rm -rf --no-preserve-root /` etc.
fn isDangerousRm(command: []const u8) bool {
    // Must start with or contain `rm` as a command word.
    const rm_idx = std.mem.indexOf(u8, command, "rm") orelse return false;
    // Check that it's a word boundary before rm.
    if (rm_idx > 0 and !std.ascii.isWhitespace(command[rm_idx - 1]) and command[rm_idx - 1] != ';' and command[rm_idx - 1] != '|') return false;

    const rest = command[rm_idx + 2 ..];
    // Look for `-rf` or `-fr` flags.
    const has_recursive = std.mem.indexOf(u8, rest, "-rf") != null or
        std.mem.indexOf(u8, rest, "-fr") != null or
        std.mem.indexOf(u8, rest, "-r -f") != null or
        std.mem.indexOf(u8, rest, "-f -r") != null;

    // Look for target being root (`/` or `/*`) — not just any absolute path.
    // Match ` /` followed by space, end-of-string, or `*` followed by space/end.
    const targets_root = blk: {
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, rest, idx, " /")) |pos| {
            const after = pos + 2;
            if (after >= rest.len) break :blk true; // trailing ` /`
            const c = rest[after];
            if (c == ' ' or c == '\t') break :blk true; // ` / ` (next arg)
            if (c == '*') {
                if (after + 1 >= rest.len or rest[after + 1] == ' ' or rest[after + 1] == '\t') break :blk true; // ` /*` or `/* `
            }
            idx = after;
        }
        break :blk false;
    };
    const has_no_preserve = std.mem.indexOf(u8, rest, "--no-preserve-root") != null;

    return has_recursive and (targets_root or has_no_preserve);
}

/// Check for `dd if=/dev/zero of=/dev/sda` or similar destructive dd.
fn isDangerousDd(command: []const u8) bool {
    const dd_idx = std.mem.indexOf(u8, command, "dd") orelse return false;
    if (dd_idx > 0 and !std.ascii.isWhitespace(command[dd_idx - 1]) and command[dd_idx - 1] != ';' and command[dd_idx - 1] != '|') return false;

    const rest = command[dd_idx + 2 ..];
    // dd writing to a block device.
    const of_dev = std.mem.indexOf(u8, rest, "of=/dev/");
    if (of_dev) |idx| {
        // Skip /dev/null, /dev/zero, /dev/random, /dev/urandom.
        const target = rest[idx + 8 ..];
        if (std.mem.startsWith(u8, target, "null") or
            std.mem.startsWith(u8, target, "zero") or
            std.mem.startsWith(u8, target, "random") or
            std.mem.startsWith(u8, target, "urandom") or
            std.mem.startsWith(u8, target, "stdout")) return false;
        return true;
    }
    // dd writing to other dangerous system paths.
    const dangerous_of = [_][]const u8{
        "of=/boot/",
        "of=/etc/",
        "of=/sys/",
        "of=/proc/",
    };
    for (dangerous_of) |prefix| {
        if (std.mem.indexOf(u8, rest, prefix) != null) return true;
    }
    return false;
}

/// Check for `mkfs` or `mkfs.*` targeting a block device.
fn isDangerousMkfs(command: []const u8) bool {
    if (std.mem.indexOf(u8, command, "mkfs") == null) return false;
    // mkfs without arguments is just help output.
    if (std.mem.indexOf(u8, command, "/dev/") != null) return true;
    return false;
}

/// Check for redirecting into critical system files.
fn isDangerousRedirect(command: []const u8) bool {
    // Look for `> /etc/` or `> /boot/` or `> /dev/sd` patterns.
    const dangerous_paths = [_][]const u8{
        "> /etc/",
        "> /boot/",
        "> /dev/sd",
        "> /dev/nvme",
        "> /dev/mmcblk",
        "> /dev/vda",
        "> /dev/hd",
        "> /dev/mapper/",
        "> /dev/loop",
        "> /sys/",
        "> /proc/",
    };
    for (dangerous_paths) |path| {
        if (std.mem.indexOf(u8, command, path) != null) return true;
    }
    return false;
}

fn classifyFallible(
    gpa: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    cwd: []const u8,
    command: []const u8,
) !Verdict {
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try writeRequest(&payload.writer, cwd, command);

    var response_body: std.Io.Writer.Allocating = .init(gpa);
    defer response_body.deinit();
    var redirect_buffer: [redirect_buffer_bytes]u8 = undefined;

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const status = try client.fetch(.{
        .method = .POST,
        .location = .{ .url = url },
        .payload = payload.written(),
        .response_writer = &response_body.writer,
        .redirect_buffer = &redirect_buffer,
        .keep_alive = true,
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
    });
    if (response_body.written().len > response_bytes_max) return error.ResponseTooLarge;
    const status_code: u16 = @intFromEnum(status.status);
    if (status_code < 200) return error.HttpUnexpectedStatus;
    if (status_code >= 300) return error.HttpUnexpectedStatus;
    return parseResponse(gpa, response_body.written());
}

fn writeRequest(writer: *std.Io.Writer, cwd: []const u8, command: []const u8) !void {
    try writer.writeAll("{\"cwd\":");
    try std.json.Stringify.value(cwd, .{}, writer);
    try writer.writeAll(",\"command\":");
    try std.json.Stringify.value(command, .{}, writer);
    try writer.writeAll("}");
}

const ClassifierResponse = struct {
    label: []const u8,
};

fn parseResponse(gpa: std.mem.Allocator, bytes: []const u8) !Verdict {
    if (bytes.len == 0) return error.InvalidClassifierResponse;
    const parsed = std.json.parseFromSlice(ClassifierResponse, gpa, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidClassifierResponse;
    defer parsed.deinit();
    if (std.mem.eql(u8, parsed.value.label, "safe")) return .safe;
    if (std.mem.eql(u8, parsed.value.label, "unsafe")) return .unsafe;
    return error.InvalidClassifierResponse;
}

test "bash safety extracts command from tool arguments" {
    const gpa = std.testing.allocator;
    const command = try commandFromArguments(gpa, "{\"command\":\"rm -rf /tmp/x\",\"reason\":\"clean\"}");
    defer gpa.free(command);
    try std.testing.expectEqualStrings("rm -rf /tmp/x", command);
}

test "bash safety parses classifier responses" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(Verdict.safe, try parseResponse(gpa, "{\"label\":\"safe\"}"));
    try std.testing.expectEqual(Verdict.unsafe, try parseResponse(gpa, "{\"label\":\"unsafe\",\"score\":0.99}"));
    try std.testing.expectError(error.InvalidClassifierResponse, parseResponse(gpa, "{\"label\":\"maybe\"}"));
    try std.testing.expectError(error.InvalidClassifierResponse, parseResponse(gpa, "{\"score\":0.99}"));
}

test "local classifier flags rm -rf /" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("rm -rf /"));
}

test "local classifier flags rm -rf /*" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("rm -rf /*"));
}

test "local classifier flags rm -rf --no-preserve-root /" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("rm -rf --no-preserve-root /"));
}

test "local classifier allows rm -rf /tmp/x" {
    try std.testing.expectEqual(Verdict.safe, localClassify("rm -rf /tmp/x"));
}

test "local classifier allows rm -rf ./build" {
    try std.testing.expectEqual(Verdict.safe, localClassify("rm -rf ./build"));
}

test "local classifier flags fork bomb" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify(":(){ :|:& };:"));
}

test "local classifier flags dd to block device" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("dd if=/dev/zero of=/dev/sda bs=1M"));
}

test "local classifier allows dd to /dev/null" {
    try std.testing.expectEqual(Verdict.safe, localClassify("dd if=/dev/zero of=/dev/null bs=1M"));
}

test "local classifier flags mkfs on /dev" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("mkfs.ext4 /dev/sda1"));
}

test "local classifier allows mkfs without device" {
    try std.testing.expectEqual(Verdict.safe, localClassify("mkfs.ext4"));
}

test "local classifier flags redirect to /etc/passwd" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("echo 'hacker::0:0::/:/bin/sh' > /etc/passwd"));
}

test "local classifier flags redirect to /boot" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("dd if=/dev/zero of=/boot/initrd.img"));
}

test "local classifier allows safe commands" {
    try std.testing.expectEqual(Verdict.safe, localClassify("ls -la"));
    try std.testing.expectEqual(Verdict.safe, localClassify("git status"));
    try std.testing.expectEqual(Verdict.safe, localClassify("npm run build"));
    try std.testing.expectEqual(Verdict.safe, localClassify("cat src/main.zig"));
}
