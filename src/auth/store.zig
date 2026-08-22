//! Generic provider credential storage service.
//!
//! Owns the `auth.json` file format (`~/.config/nova/auth.json`) and the
//! OS keychain fallback. All providers — builtin, models.dev dynamic, and
//! user-defined config — use this module for API key storage.
//!
//! OpenAI Codex OAuth lives in `codex.zig` and imports this module for
//! persistence. The `openaiCodex` section of auth.json is owned here as
//! the `Credentials` type because it is part of the file format, not
//! OAuth business logic.

const std = @import("std");
const log = std.log.scoped(.auth);

const keyring = @import("keyring.zig");

const keyring_service = "Nova";

// ---------------------------------------------------------------------------
// Credentials (openaiCodex section of auth.json)
// ---------------------------------------------------------------------------

pub const Credentials = struct {
    access: []u8,
    refresh: []u8,
    account_id: []u8,
    expires: i64,

    pub fn deinit(self: *Credentials, gpa: std.mem.Allocator) void {
        gpa.free(self.access);
        gpa.free(self.refresh);
        gpa.free(self.account_id);
        self.* = undefined;
    }
};

const CredentialsJson = struct {
    access: []const u8,
    refresh: []const u8,
    accountId: []const u8,
    expires: i64,
};

// ---------------------------------------------------------------------------
// API Key Map
// ---------------------------------------------------------------------------

pub const ApiKeyMap = std.StringArrayHashMapUnmanaged([]u8);

pub fn freeApiKeyMap(gpa: std.mem.Allocator, map: *ApiKeyMap) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        gpa.free(entry.key_ptr.*);
        gpa.free(entry.value_ptr.*);
    }
    map.deinit(gpa);
}

// ---------------------------------------------------------------------------
// Public API — Credentials
// ---------------------------------------------------------------------------

/// Read stored Codex credentials, or null when absent.
pub fn loadCredentials(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) !?Credentials {
    const bytes = (try readBlob(gpa, io, home_dir)) orelse return null;
    defer gpa.free(bytes);
    return parseCredentials(gpa, bytes);
}

/// Persist Codex credentials, preserving any stored provider API keys.
pub fn saveCredentials(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, credentials: Credentials) !void {
    var keys = try loadAllProviderApiKeys(gpa, io, home_dir);
    defer freeApiKeyMap(gpa, &keys);
    try writeAuthFile(gpa, io, home_dir, credentials, &keys);
}

/// Remove Codex credentials, preserving any stored provider API keys.
/// If no API keys remain, deletes the entire auth blob.
pub fn removeCredentials(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) !void {
    var keys = try loadAllProviderApiKeys(gpa, io, home_dir);
    defer freeApiKeyMap(gpa, &keys);
    if (apiKeysCount(&keys) > 0) {
        try writeAuthFile(gpa, io, home_dir, null, &keys);
        return;
    }
    try deleteBlob(gpa, io, home_dir);
}

// ---------------------------------------------------------------------------
// Public API — Provider API Keys
// ---------------------------------------------------------------------------

/// Read every stored provider API key. Returns an empty map when the auth
/// file is absent or carries no `apiKeys` section.
pub fn loadAllProviderApiKeys(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) !ApiKeyMap {
    const bytes = (try readBlob(gpa, io, home_dir)) orelse return .empty;
    defer gpa.free(bytes);
    return parseApiKeys(gpa, bytes);
}

/// Read a single provider's stored API key, or null if none is stored.
pub fn loadProviderApiKey(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, label: []const u8) !?[]u8 {
    var map = try loadAllProviderApiKeys(gpa, io, home_dir);
    defer freeApiKeyMap(gpa, &map);
    const value = map.get(label) orelse return null;
    return try gpa.dupe(u8, value);
}

/// Upsert a provider API key, preserving Codex credentials and other keys.
pub fn saveProviderApiKey(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, label: []const u8, key: []const u8) !void {
    var keys = try loadAllProviderApiKeys(gpa, io, home_dir);
    defer freeApiKeyMap(gpa, &keys);
    if (keys.fetchOrderedRemove(label)) |old| {
        gpa.free(old.key);
        gpa.free(old.value);
    }
    const owned_label = try gpa.dupe(u8, label);
    errdefer gpa.free(owned_label);
    const owned_key = try gpa.dupe(u8, key);
    errdefer gpa.free(owned_key);
    try keys.put(gpa, owned_label, owned_key);

    var creds = try loadCredentials(gpa, io, home_dir);
    defer if (creds) |*c| c.deinit(gpa);
    try writeAuthFile(gpa, io, home_dir, creds, &keys);
}

/// Remove a provider API key, preserving Codex credentials and other keys.
pub fn removeProviderApiKey(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, label: []const u8) !void {
    var keys = try loadAllProviderApiKeys(gpa, io, home_dir);
    defer freeApiKeyMap(gpa, &keys);
    if (keys.fetchOrderedRemove(label)) |old| {
        gpa.free(old.key);
        gpa.free(old.value);
    }
    var creds = try loadCredentials(gpa, io, home_dir);
    defer if (creds) |*c| c.deinit(gpa);
    try writeAuthFile(gpa, io, home_dir, creds, &keys);
}

/// Remove auth.json keys that don't correspond to any known provider.
/// Keys matching `valid_names` (builtin labels + config provider names)
/// are kept; everything else is an orphan and gets removed.
/// Idempotent: running again after a prune removes nothing.
/// Returns the number of keys removed.
pub fn pruneOrphanKeys(
    gpa: std.mem.Allocator,
    io: std.Io,
    home_dir: []const u8,
    valid_names: []const []const u8,
) !u32 {
    var keys = try loadAllProviderApiKeys(gpa, io, home_dir);
    defer freeApiKeyMap(gpa, &keys);

    var orphans: std.ArrayList([]const u8) = .empty;
    defer orphans.deinit(gpa);

    var it = keys.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        var found = false;
        for (valid_names) |valid| {
            if (std.mem.eql(u8, name, valid)) {
                found = true;
                break;
            }
        }
        if (!found) try orphans.append(gpa, name);
    }

    if (orphans.items.len == 0) return 0;

    for (orphans.items) |name| {
        if (keys.fetchOrderedRemove(name)) |old| {
            gpa.free(old.key);
            gpa.free(old.value);
        }
    }

    var creds = try loadCredentials(gpa, io, home_dir);
    defer if (creds) |*c| c.deinit(gpa);
    try writeAuthFile(gpa, io, home_dir, creds, &keys);

    return @intCast(orphans.items.len);
}

// ---------------------------------------------------------------------------
// Public API — Blob I/O (used by codex.zig for signOut)
// ---------------------------------------------------------------------------

pub fn authPath(gpa: std.mem.Allocator, home_dir: []const u8) ![]u8 {
    if (home_dir.len == 0) return error.HomeNotSet;
    return std.fs.path.join(gpa, &.{ home_dir, ".config", "nova", "auth.json" });
}

/// Read the serialized auth blob, preferring the keychain and falling back
/// to `auth.json`. Returns gpa-owned bytes, or null when neither has an entry.
pub fn readBlob(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) !?[]u8 {
    var account_buf: [20]u8 = undefined;
    const account = keyringAccount(home_dir, &account_buf);
    if (keyring.load(gpa, keyring_service, account)) |maybe| {
        if (maybe) |bytes| return bytes;
    } else |err| {
        if (err != error.Unsupported) log.warn("keyring load failed ({s}); using auth.json", .{@errorName(err)});
    }
    return readBlobFile(gpa, io, home_dir);
}

/// Persist the blob: try the keychain, and on success drop the plaintext
/// file so the secret isn't left on disk. Falls back to auth.json when the
/// keychain is unavailable or rejects the blob.
pub fn writeBlob(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, bytes: []const u8) !void {
    var account_buf: [20]u8 = undefined;
    const account = keyringAccount(home_dir, &account_buf);
    keyring.save(gpa, keyring_service, account, bytes) catch |err| {
        if (err != error.Unsupported) log.warn("keyring save failed ({s}); writing auth.json", .{@errorName(err)});
        return writeBlobFile(gpa, io, home_dir, bytes);
    };
    deleteBlobFile(gpa, io, home_dir) catch {};
}

/// Remove the blob from both the keychain and the plaintext file.
pub fn deleteBlob(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) !void {
    var account_buf: [20]u8 = undefined;
    const account = keyringAccount(home_dir, &account_buf);
    _ = keyring.delete(gpa, keyring_service, account) catch |err| {
        if (err != error.Unsupported) log.warn("keyring delete failed ({s})", .{@errorName(err)});
    };
    try deleteBlobFile(gpa, io, home_dir);
}

// ---------------------------------------------------------------------------
// auth.json serialization
// ---------------------------------------------------------------------------

const AuthFile = struct {
    openaiCodex: ?CredentialsJson = null,
    /// Map of provider label/id -> API key. Parsed as a raw object because
    /// the keys are provider identifiers, not known field names.
    apiKeys: ?std.json.Value = null,
};

fn writeAuthFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    home_dir: []const u8,
    credentials: ?Credentials,
    api_keys: *const ApiKeyMap,
) !void {
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try payload.writer.writeByte('{');
    var wrote_any = false;
    if (credentials) |value| {
        try writeAuthKey(&payload.writer, "openaiCodex", &wrote_any);
        try writeCredentialsJson(&payload.writer, &value);
    }
    if (apiKeysCount(api_keys) > 0) {
        try writeAuthKey(&payload.writer, "apiKeys", &wrote_any);
        try writeApiKeys(&payload.writer, api_keys);
    }
    try payload.writer.writeAll("}\n");
    try writeBlob(gpa, io, home_dir, payload.written());
}

fn writeCredentialsJson(writer: *std.Io.Writer, credentials: *const Credentials) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"access\":");
    try std.json.Stringify.value(credentials.access, .{}, writer);
    try writer.writeAll(",\"refresh\":");
    try std.json.Stringify.value(credentials.refresh, .{}, writer);
    try writer.writeAll(",\"expires\":");
    try std.json.Stringify.value(credentials.expires, .{}, writer);
    try writer.writeAll(",\"accountId\":");
    try std.json.Stringify.value(credentials.account_id, .{}, writer);
    try writer.writeByte('}');
}

fn writeApiKeys(writer: *std.Io.Writer, api_keys: *const ApiKeyMap) !void {
    try writer.writeByte('{');
    var wrote_any = false;
    var it = api_keys.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.*.len == 0) continue;
        if (wrote_any) try writer.writeByte(',');
        try std.json.Stringify.value(entry.key_ptr.*, .{}, writer);
        try writer.writeByte(':');
        try std.json.Stringify.value(entry.value_ptr.*, .{}, writer);
        wrote_any = true;
    }
    try writer.writeByte('}');
}

fn writeAuthKey(writer: *std.Io.Writer, name: []const u8, wrote_any: *bool) !void {
    if (wrote_any.*) try writer.writeByte(',');
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeByte(':');
    wrote_any.* = true;
}

fn apiKeysCount(api_keys: *const ApiKeyMap) usize {
    var count: usize = 0;
    var it = api_keys.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.*.len > 0) count += 1;
    }
    return count;
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

fn parseCredentials(gpa: std.mem.Allocator, bytes: []const u8) !?Credentials {
    const parsed = std.json.parseFromSlice(AuthFile, gpa, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidCredentials;
    defer parsed.deinit();
    const provider = parsed.value.openaiCodex orelse return null;
    return .{
        .access = try gpa.dupe(u8, provider.access),
        .refresh = try gpa.dupe(u8, provider.refresh),
        .account_id = try gpa.dupe(u8, provider.accountId),
        .expires = provider.expires,
    };
}

fn parseApiKeys(gpa: std.mem.Allocator, bytes: []const u8) !ApiKeyMap {
    const parsed = std.json.parseFromSlice(AuthFile, gpa, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidCredentials;
    defer parsed.deinit();
    var map: ApiKeyMap = .empty;
    errdefer freeApiKeyMap(gpa, &map);
    const keys_value = parsed.value.apiKeys orelse return map;
    if (keys_value != .object) return map;
    var it = keys_value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        if (entry.value_ptr.*.string.len == 0) continue;
        const owned_label = try gpa.dupe(u8, entry.key_ptr.*);
        errdefer gpa.free(owned_label);
        const owned_key = try gpa.dupe(u8, entry.value_ptr.*.string);
        errdefer gpa.free(owned_key);
        try map.put(gpa, owned_label, owned_key);
    }
    return map;
}

// ---------------------------------------------------------------------------
// Blob file I/O
// ---------------------------------------------------------------------------

fn keyringAccount(home_dir: []const u8, buf: *[20]u8) []const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(home_dir, &digest, .{});
    const hex = "0123456789abcdef";
    @memcpy(buf[0..4], "cli|");
    for (digest[0..8], 0..) |byte, i| {
        buf[4 + i * 2] = hex[byte >> 4];
        buf[4 + i * 2 + 1] = hex[byte & 0x0f];
    }
    return buf[0..20];
}

fn readBlobFile(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) !?[]u8 {
    const path = try authPath(gpa, home_dir);
    defer gpa.free(path);
    const file = std.Io.Dir.openFile(.cwd(), io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > 32 * 1024) return error.FileTooBig;
    const bytes = try gpa.alloc(u8, @intCast(stat.size));
    errdefer gpa.free(bytes);
    var reader = file.reader(io, &.{});
    try reader.interface.readSliceAll(bytes);
    return bytes;
}

fn writeBlobFile(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, bytes: []const u8) !void {
    const path = try authPath(gpa, home_dir);
    defer gpa.free(path);
    const dirname = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.Io.Dir.createDirPath(.cwd(), io, dirname);
    var file = try std.Io.Dir.createFile(.cwd(), io, path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn deleteBlobFile(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) !void {
    const path = try authPath(gpa, home_dir);
    defer gpa.free(path);
    std.Io.Dir.deleteFile(.cwd(), io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "auth file parser loads openai codex credentials" {
    const gpa = std.testing.allocator;
    const loaded = try parseCredentials(gpa, "{\"openaiCodex\":{\"access\":\"a\",\"refresh\":\"r\",\"expires\":12,\"accountId\":\"acct\"}}");
    var credentials = loaded.?;
    defer credentials.deinit(gpa);
    try std.testing.expectEqualStrings("a", credentials.access);
    try std.testing.expectEqualStrings("r", credentials.refresh);
    try std.testing.expectEqualStrings("acct", credentials.account_id);
    try std.testing.expectEqual(@as(i64, 12), credentials.expires);
}

test "auth file parser still reads codex creds alongside apiKeys" {
    const gpa = std.testing.allocator;
    const loaded = try parseCredentials(gpa, "{\"openaiCodex\":{\"access\":\"a\",\"refresh\":\"r\",\"expires\":12,\"accountId\":\"acct\"},\"apiKeys\":{\"cerebras\":\"csk\"}}");
    var credentials = loaded.?;
    defer credentials.deinit(gpa);
    try std.testing.expectEqualStrings("a", credentials.access);
}

test "parseApiKeys reads keys and skips empty/non-string entries" {
    const gpa = std.testing.allocator;
    var map = try parseApiKeys(gpa, "{\"apiKeys\":{\"cerebras\":\"csk\",\"openrouter\":\"\",\"nvidia_nim\":42,\"huggingface\":\"hf\"}}");
    defer freeApiKeyMap(gpa, &map);
    try std.testing.expectEqual(@as(usize, 2), map.count());
    try std.testing.expectEqualStrings("csk", map.get("cerebras").?);
    try std.testing.expectEqualStrings("hf", map.get("huggingface").?);
    try std.testing.expectEqual(@as(?[]u8, null), map.get("openrouter"));
}

test "parseApiKeys returns empty map when section absent" {
    const gpa = std.testing.allocator;
    var map = try parseApiKeys(gpa, "{\"openaiCodex\":{\"access\":\"a\",\"refresh\":\"r\",\"expires\":1,\"accountId\":\"x\"}}");
    defer freeApiKeyMap(gpa, &map);
    try std.testing.expectEqual(@as(usize, 0), map.count());
}

test "parseCredentials returns InvalidCredentials on malformed json" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidCredentials, parseCredentials(gpa, "{invalid json"));
}

test "parseApiKeys returns InvalidCredentials on malformed json" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidCredentials, parseApiKeys(gpa, "{invalid json"));
}

test "writeApiKeys serializes non-empty entries as a json object" {
    const gpa = std.testing.allocator;
    var map: ApiKeyMap = .empty;
    defer freeApiKeyMap(gpa, &map);
    try map.put(gpa, try gpa.dupe(u8, "cerebras"), try gpa.dupe(u8, "csk"));
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeApiKeys(&out.writer, &map);
    try std.testing.expectEqualStrings("{\"cerebras\":\"csk\"}", out.written());
}

test "saveProviderApiKey and removeProviderApiKey round-trip" {
    const gpa = std.testing.allocator;
    const home_dir = "/tmp/nova-auth-test";
    defer deleteBlob(gpa, std.testing.io, home_dir) catch {};

    try saveProviderApiKey(gpa, std.testing.io, home_dir, "cerebras", "csk-123");
    const loaded = try loadProviderApiKey(gpa, std.testing.io, home_dir, "cerebras");
    try std.testing.expectEqualStrings("csk-123", loaded.?);
    gpa.free(loaded.?);

    try removeProviderApiKey(gpa, std.testing.io, home_dir, "cerebras");
    const after = try loadProviderApiKey(gpa, std.testing.io, home_dir, "cerebras");
    try std.testing.expect(after == null);
}
