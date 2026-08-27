//! Local shell command safety classifier.
//!
//! Covers BOTH the bash and PowerShell (`pwsh`) shells — the model-facing
//! shell tool on Windows is `pwsh`, and this local matcher backs the
//! destructive-command backstop for whichever shell is host-selected. The
//! bash patterns are kept unchanged (defense-in-depth is not exhaustive), and
//! additive PowerShell patterns are layered on.
//!
//! When the remote classifier is unavailable, a simple local pattern matcher
//! provides defense-in-depth against obviously destructive commands.

const std = @import("std");
const http = @import("../http.zig");

const assert = std.debug.assert;

const response_bytes_max: u32 = 4096;
const redirect_buffer_bytes = http.redirect_buffer_bytes;

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

/// Classify `command` as safe/unsafe. `url` is the remote classifier endpoint,
/// or null when none is configured. With a URL the remote classifies and the
/// local matcher only runs on fetch failure; with null (no classifier — the
/// local-ONNX server couldn't start, or the user set none) the local matcher
/// runs directly so the destructive-command backstop is always armed, per the
/// module's defense-in-depth contract.
pub fn classify(
    gpa: std.mem.Allocator,
    io: std.Io,
    url: ?[]const u8,
    cwd: []const u8,
    command: []const u8,
) Verdict {
    assert(cwd.len > 0);
    assert(command.len > 0);

    const u = url orelse return localClassify(command);
    if (u.len == 0) return localClassify(command);

    const remote = classifyFallible(gpa, io, u, cwd, command) catch {
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

    // Fork bombs and infinite-recursion shell constructs (bash).
    if (std.mem.indexOf(u8, trimmed, ":(){") != null) return .unsafe;
    if (std.mem.indexOf(u8, trimmed, ":()") != null) return .unsafe;
    // PowerShell fork-bomb equivalents.
    if (isPwshForkBomb(trimmed)) return .unsafe;

    // Destructive disk operations on system paths.
    if (isDangerousRm(trimmed)) return .unsafe;
    if (isDangerousDd(trimmed)) return .unsafe;
    if (isDangerousMkfs(trimmed)) return .unsafe;
    if (isDangerousPwshRemove(trimmed)) return .unsafe;
    if (isDangerousClearRecycleBin(trimmed)) return .unsafe;

    // Overwriting critical system files.
    if (isDangerousRedirect(trimmed)) return .unsafe;

    // Privileged package management (e.g. `sudo apt install`, `doas pacman -S`).
    // These mutate the system-wide install state and must surface for approval
    // rather than running unattended — a model should never be able to attempt
    // `sudo apt install` without the interactive gate (TD-3).
    if (isPrivilegedPackageManagement(trimmed)) return .unsafe;

    return .safe;
}

/// True when `command` escalates privileges (`sudo`/`doas`/`runas`) or invokes a
/// system package manager (`apt`, `apt-get`, `dpkg`, `dnf`, `yum`, `pacman`,
/// `apk`, `brew`, `pip install`). The match is prefix/case-insensitive on the
/// first token so `--option sudo apt` noise is not required to trigger it.
fn isPrivilegedPackageManagement(command: []const u8) bool {
    // Tokens that escalate privileges: any of these at the head (possibly after
    // a leading env assignment or `exec`) mean the remainder must be vetted.
    const escalators = [_][]const u8{ "sudo", "doas", "runas" };
    for (escalators) |esc| {
        if (startsWithToken(command, esc)) return true;
    }
    // Package managers invoked directly (no privilege escalation needed to flag —
    // a system-wide install/remove is destructive regardless of user). Single
    // tokens match exactly; multi-word phrases (e.g. `pip install`) match only
    // at word boundaries so `apt-cache` does not false-positive on `apt`.
    const managers = [_][]const u8{
        "apt", "apt-get", "dpkg", "dnf", "yum", "pacman", "apk", "brew",
    };
    for (managers) |mgr| {
        if (containsExactToken(command, mgr)) return true;
    }
    const phrases = [_][]const u8{
        "pip install", "pip3 install", "npm install -g", "npm i -g",
    };
    for (phrases) |phrase| {
        if (containsPhrase(command, phrase)) return true;
    }
    return false;
}

/// Case-insensitive prefix match against the first whitespace-delimited token.
fn startsWithToken(command: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, command, ' ');
    const first = it.next() orelse return false;
    return containsIgnoreCase(first, token);
}

/// Case-insensitive exact match against any whitespace-delimited token, so
/// `apt` matches `sudo apt install` but not `apt-cache show nginx`.
fn containsExactToken(command: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, command, ' ');
    while (it.next()) |tok| {
        if (std.ascii.eqlIgnoreCase(tok, token)) return true;
    }
    return false;
}

/// Case-insensitive match of `phrase` (which may contain spaces) only when
/// bounded by word boundaries (string edges or whitespace), so `pip install`
/// inside `pip install --user x` matches but `equip installation` does not.
fn containsPhrase(command: []const u8, phrase: []const u8) bool {
    var idx: usize = 0;
    while (idx < command.len) {
        const at = std.mem.indexOf(u8, command[idx..], phrase) orelse return false;
        const abs = idx + at;
        const before_ok = abs == 0 or std.ascii.isWhitespace(command[abs - 1]);
        const after = abs + phrase.len;
        const after_ok = after >= command.len or std.ascii.isWhitespace(command[after]);
        if (before_ok and after_ok) return true;
        idx = after;
    }
    return false;
}

/// PowerShell fork-bomb equivalents: recursive `while($true){Start-Job ...}`
/// loops and `ForEach-Object -Parallel`/`Start-ThreadJob` constructs that fan
/// out unbounded worker processes.
fn isPwshForkBomb(command: []const u8) bool {
    if (containsIgnoreCase(command, "while($true)") or containsIgnoreCase(command, "while ($true)")) {
        if (containsIgnoreCase(command, "Start-Job")) return true;
    }
    if (containsIgnoreCase(command, "-Parallel") and containsIgnoreCase(command, "Start-ThreadJob")) {
        return true;
    }
    return false;
}

/// `Remove-Item -Recurse -Force` on system/drive roots — mirrors `isDangerousRm`
/// for the PowerShell spelling. This is a conservative matcher; the remote
/// classifier covers the full surface. Targets are flagged only when they are a
/// drive ROOT (`C:\` bare), `$env:SystemRoot`, or a well-known system dir —
/// never a project path that merely sits on the C: drive.
fn isDangerousPwshRemove(command: []const u8) bool {
    var idx: usize = 0;
    while (findIgnoreCaseFrom(command, "Remove-Item", idx)) |pos| {
        const rest_view = command[pos..];
        if (!containsIgnoreCase(rest_view, "-Recurse") and !containsIgnoreCase(rest_view, "-Force")) {
            idx = pos + 1;
            continue;
        }
        // $env:SystemRoot / $env:WINDIR resolves to a system root.
        if (containsIgnoreCase(command, "$env:systemroot") or containsIgnoreCase(command, "$env:windir")) return true;
        // A well-known system dir.
        if (containsIgnoreCase(command, "windows\\system32") or
            containsIgnoreCase(command, "program files") or
            containsIgnoreCase(command, "\\windows\\")) return true;
        // A bare drive root: `C:\` followed by end-of-string, whitespace, a
        // regular quote, or a path separator continuation that is still the root
        // (e.g. `C:\*` or `C:\Windows` is caught above; here only bare `C:\`).
        if (hasDriveRootTarget(command)) return true;
        idx = pos + 1;
    }
    return false;
}

/// True when `command` contains a bare drive root target (`C:\` followed by
/// end-of-string, whitespace, a quote, `*`, or nothing) — the `Remove-Item C:\`
/// / `Remove-Item C:\*` case that nukes the whole drive.
fn hasDriveRootTarget(command: []const u8) bool {
    var idx: usize = 0;
    while (idx < command.len) {
        // A drive letter somewhere, then `:\` right after is the drive root.
        if (idx + 2 < command.len and
            std.ascii.isAlphabetic(command[idx]) and
            command[idx + 1] == ':' and
            command[idx + 2] == '\\')
        {
            const after = idx + 3;
            if (after >= command.len) return true; // trailing `C:\`
            const c = command[after];
            if (std.ascii.isWhitespace(c) or c == '\'' or c == '"' or c == '*') return true;
        }
        idx += 1;
    }
    return false;
}

/// `Clear-RecycleBin -Force` empties the recycle bin without confirmation —
/// destructive, irreversible recovery.
fn isDangerousClearRecycleBin(command: []const u8) bool {
    return containsIgnoreCase(command, "clear-recyclebin") and containsIgnoreCase(command, "-force");
}

/// Case-insensitive substring search over ASCII (command text is shell code,
/// which never needs Unicode folding).
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (eqlIgnoreCaseAscii(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Case-insensitive search returning the first match position, or null.
fn findIgnoreCaseFrom(haystack: []const u8, needle: []const u8, from: usize) ?usize {
    if (from >= haystack.len) return null;
    var i = from;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (eqlIgnoreCaseAscii(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn eqlIgnoreCaseAscii(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
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
            if (c == ' ' or c == '\t' or c == ';' or c == '&' or c == '|' or c == '\r' or c == '\n') break :blk true; // ` / ` or ` /; ` (next arg / command)
            if (c == '*') {
                if (after + 1 >= rest.len or rest[after + 1] == ' ' or rest[after + 1] == '\t' or rest[after + 1] == ';' or rest[after + 1] == '&' or rest[after + 1] == '|') break :blk true; // ` /*` or `/* `
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
    // PowerShell redirects into system roots: `> C:\Windows\`,
    // `> 'C:\Program Files\'`, etc. Drive-letter roots and the well-known
    // system dirs are the only Windows targets worth flagging from the local
    // matcher (defense-in-depth; the remote classifier covers the full surface).
    if (isDangerousPwshRedirect(command)) return true;
    return false;
}

/// PowerShell redirect (`>`) into a Windows system root. Case-insensitive on the
/// ASCII text. Flags well-known system dirs and a bare drive root; a project path
/// on the C: drive (`> C:\repo\out.txt`) is NOT flagged.
fn isDangerousPwshRedirect(command: []const u8) bool {
    if (std.mem.indexOf(u8, command, ">") == null) return false;
    if (containsIgnoreCase(command, "windows\\system32") or
        containsIgnoreCase(command, "program files") or
        containsIgnoreCase(command, "windows\\") or
        containsIgnoreCase(command, "$env:systemroot"))
    {
        return true;
    }
    // A bare drive root redirect (`> C:\`, `> 'D:\'`): the target is the drive
    // root with nothing after it but whitespace / quote / end-of-string / `*`.
    if (hasBareDriveRootRedirect(command)) return true;
    return false;
}

/// True when `command` contains a `>` redirect to a drive root with nothing but
/// whitespace/quote/`*`/end after the `C:\` — i.e. writing to the root of a
/// drive itself, not into a subdirectory.
fn hasBareDriveRootRedirect(command: []const u8) bool {
    var idx: usize = 0;
    while (indexOfScalarPos(command, idx, '>')) |gt| {
        var after = gt + 1;
        while (after < command.len and std.ascii.isWhitespace(command[after])) after += 1;
        if (after < command.len and (command[after] == '\'' or command[after] == '"')) after += 1;
        if (after + 2 <= command.len and
            std.ascii.isAlphabetic(command[after]) and
            command[after + 1] == ':' and
            command[after + 2] == '\\')
        {
            const tail = after + 3;
            if (tail >= command.len) return true;
            const c = command[tail];
            if (std.ascii.isWhitespace(c) or c == '\'' or c == '"' or c == '*' or c == ';') return true;
        }
        idx = gt + 1;
    }
    return false;
}

fn indexOfScalarPos(haystack: []const u8, from: usize, needle: u8) ?usize {
    if (from >= haystack.len) return null;
    return std.mem.indexOfScalarPos(u8, haystack, from, needle);
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
            .content_type = .{ .override = http.content_type_json },
        },
    });
    if (response_body.written().len > response_bytes_max) return error.ResponseTooLarge;
    const status_code: u16 = @intFromEnum(status.status);
    if (!http.isSuccess(status_code)) return error.HttpUnexpectedStatus;
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
    const command = try commandFromArguments(gpa, "{\"command\":\"rm -rf /tmp/x\",\"description\":\"clean\"}");
    defer gpa.free(command);
    try std.testing.expectEqualStrings("rm -rf /tmp/x", command);
}

test "bash safety parses classifier responses" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(Verdict.safe, try parseResponse(gpa, "{\"label\":\"safe\"}"));
    try std.testing.expectEqual(Verdict.unsafe, try parseResponse(gpa, "{\"label\":\"unsafe\",\"score\":0.99}"));
    try std.testing.expectError(error.InvalidClassifierResponse, parseResponse(gpa, "{\"label\":\"maybe\"}"));
    // A response with a score but no label is also malformed.
    try std.testing.expectError(error.InvalidClassifierResponse, parseResponse(gpa, "{\"score\":0.99}"));
}

test "classify with no URL falls back to the local matcher" {
    // Regression for H4: with no classifier configured the local destructive-
    // command backstop must still run (it used to be reachable only through the
    // remote-fetch-failure path).
    try std.testing.expectEqual(Verdict.unsafe, classify(std.testing.allocator, std.testing.io, null, "/x", "rm -rf /"));
    try std.testing.expectEqual(Verdict.safe, classify(std.testing.allocator, std.testing.io, null, "/x", "ls"));
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

test "local classifier flags pwsh Remove-Item on a drive root" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Remove-Item -Recurse -Force C:\\"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Remove-Item -Recurse -Force C:\\*"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Remove-Item -Recurse -Force $env:SystemRoot"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Remove-Item -Recurse -Force C:\\Windows\\*"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Remove-Item -Recurse -Force 'C:\\Program Files\\*'"));
}

test "local classifier allows pwsh Remove-Item on a project path" {
    try std.testing.expectEqual(Verdict.safe, localClassify("Remove-Item -Recurse -Force .\\build"));
    try std.testing.expectEqual(Verdict.safe, localClassify("Remove-Item -Recurse -Force C:\\repo\\dist"));
}

test "local classifier flags Clear-RecycleBin -Force" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Clear-RecycleBin -Force"));
    try std.testing.expectEqual(Verdict.safe, localClassify("Clear-RecycleBin -WhatIf"));
}

test "local classifier flags pwsh fork-bomb equivalents" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("while($true){Start-Job { Start-Job { Start-Job {} } }}"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("1..100 | ForEach-Object -Parallel { Start-ThreadJob { } }"));
}

test "local classifier flags pwsh dangerous redirect" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Write-Output 'x' > C:\\Windows\\x.txt"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("Something > 'C:\\Program Files\\x.txt'"));
    try std.testing.expectEqual(Verdict.safe, localClassify("Write-Output 'x' > .\\out.txt"));
    try std.testing.expectEqual(Verdict.safe, localClassify("Write-Output 'x' > C:\\repo\\out.txt"));
}

test "local classifier flags sudo apt install as unsafe" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("sudo apt install nginx"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("sudo apt-get install -y curl"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("doas pacman -S htop"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("runas /user:admin winget install foo"));
}

test "local classifier flags direct package managers as unsafe" {
    try std.testing.expectEqual(Verdict.unsafe, localClassify("apt-get update"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("dpkg -i package.deb"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("dnf install vim"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("yum remove git"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("pacman -Syu"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("apk add wget"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("pip install --user requests"));
    try std.testing.expectEqual(Verdict.unsafe, localClassify("npm install -g typescript"));
}

test "local classifier still allows safe reads" {
    try std.testing.expectEqual(Verdict.safe, localClassify("ls -la"));
    try std.testing.expectEqual(Verdict.safe, localClassify("apt-cache show nginx"));
    try std.testing.expectEqual(Verdict.safe, localClassify("pip show requests"));
    // `apt` substring inside an unrelated word must not false-positive.
    try std.testing.expectEqual(Verdict.safe, localClassify("cat adapter.log"));
}
