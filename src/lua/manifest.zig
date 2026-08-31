//! Plugin manifest parsing and validation.
//!
//! A plugin manifest is a `plugin.lua` file at the root of a plugin directory.
//! It returns a Lua table with metadata about the plugin, including
//! permissions and resource limits.

const std = @import("std");
const c = @import("c");
const log = std.log.scoped(.lua);
const State = @import("state.zig").State;
const bridge = @import("bridge.zig");
const sandbox = @import("sandbox.zig");

/// Parsed plugin manifest.
pub const Manifest = struct {
    /// Plugin name (unique identifier, e.g. "syntax_highlighter")
    name: []const u8,
    /// Semantic version string (e.g. "1.2.0")
    version: []const u8,
    /// Author name or handle
    author: []const u8 = "",
    /// License identifier (e.g. "MIT", "Apache-2.0")
    license: []const u8 = "",
    /// Human-readable description
    description: []const u8 = "",
    /// Plugin dependencies (e.g. "lpeg >= 1.0")
    dependencies: []const []const u8 = &.{},
    /// Whether this is an embedded plugin (shipped with Nova)
    is_embedded: bool = false,
    /// Permissions requested by the plugin
    permissions: sandbox.Permissions = .{},

    const Self = @This();

    /// Parse a manifest from a Lua file loaded in the given state.
    /// The manifest table must be on top of the stack.
    /// Caller owns the returned strings (allocated with `allocator`).
    pub fn parse(allocator: std.mem.Allocator, L: *State) !Manifest {
        if (!L.isTable(-1)) return error.InvalidManifest;

        const raw_name = bridge.getTableString(L, -1, "name") orelse return error.MissingPluginName;
        const name = try allocator.dupe(u8, raw_name);
        errdefer allocator.free(name);

        const raw_version = bridge.getTableString(L, -1, "version") orelse return error.MissingPluginVersion;
        const version = try allocator.dupe(u8, raw_version);
        errdefer allocator.free(version);

        const author = if (bridge.getTableString(L, -1, "author")) |s| try allocator.dupe(u8, s) else "";
        errdefer if (author.len > 0) allocator.free(author);

        const license = if (bridge.getTableString(L, -1, "license")) |s| try allocator.dupe(u8, s) else "";
        errdefer if (license.len > 0) allocator.free(license);

        const description = if (bridge.getTableString(L, -1, "description")) |s| try allocator.dupe(u8, s) else "";
        errdefer if (description.len > 0) allocator.free(description);

        // Parse permissions sub-table
        const permissions = parsePermissions(L) catch sandbox.Permissions{};

        return Manifest{
            .name = name,
            .version = version,
            .author = author,
            .license = license,
            .description = description,
            .dependencies = &.{},
            .is_embedded = false,
            .permissions = permissions,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        if (self.author.len > 0) allocator.free(self.author);
        if (self.license.len > 0) allocator.free(self.license);
        if (self.description.len > 0) allocator.free(self.description);
    }
};

/// Parse the permissions sub-table from the manifest table on the stack.
/// The manifest table must be at the top of the stack.
fn parsePermissions(L: *State) !sandbox.Permissions {
    const t = c.lua_getfield(L.handle, -1, "permissions");
    defer L.pop(1);

    if (t != c.LUA_TTABLE) return sandbox.Permissions{};

    validatePermissionKeys(L);

    var perms = sandbox.Permissions{};

    if (bridge.getTableBoolean(L, -1, "file_access")) |v| perms.file_access = v;
    if (bridge.getTableBoolean(L, -1, "network_access")) |v| perms.network_access = v;
    if (bridge.getTableBoolean(L, -1, "require_others")) |v| perms.require_others = v;
    if (bridge.getTableBoolean(L, -1, "allow_os_execute")) |v| perms.allow_os_execute = v;
    if (bridge.getTableBoolean(L, -1, "allow_os_exit")) |v| perms.allow_os_exit = v;
    if (bridge.getTableBoolean(L, -1, "allow_os_remove")) |v| perms.allow_os_remove = v;

    // Clamp on the i64 before the u32 cast so a negative value (a manifest typo
    // or a hand-edited plugin.lua) cannot wrap to ~4e9. 0 keeps its "unlimited"
    // semantics, so clamp only the lower bound at 0.
    if (bridge.getTableInteger(L, -1, "instruction_limit")) |v| perms.instruction_limit = @intCast(@max(v, 0));
    if (bridge.getTableInteger(L, -1, "memory_limit_mb")) |v| perms.memory_limit_mb = @intCast(@max(v, 0));
    if (bridge.getTableInteger(L, -1, "timeout_ms")) |v| perms.timeout_ms = @intCast(@max(v, 0));

    return perms;
}

/// Whether `key` is a recognized permission key. Pure — testable without a
/// Lua state or log capture.
fn isRecognizedPermissionKey(key: []const u8) bool {
    const recognized = [_][]const u8{
        "file_access",
        "network_access",
        "require_others",
        "allow_os_execute",
        "allow_os_exit",
        "allow_os_remove",
        "instruction_limit",
        "memory_limit_mb",
        "timeout_ms",
    };
    for (recognized) |r| {
        if (std.mem.eql(u8, key, r)) return true;
    }
    return false;
}

/// Warn on any key in the permissions table that isn't a recognized
/// permission. Catches typos like `reqiure_others`, which today are silently
/// swallowed. Pure iteration over the table — no stack mutation.
fn validatePermissionKeys(L: *State) void {
    // Push a nil key to start the iteration (lua_next).
    c.lua_pushnil(L.handle);
    while (c.lua_next(L.handle, -2) != 0) {
        // Key is at -2, value at -1.
        if (c.lua_type(L.handle, -2) == c.LUA_TSTRING) {
            var key_len: usize = 0;
            const key = std.mem.span(c.lua_tolstring(L.handle, -2, &key_len));
            if (!isRecognizedPermissionKey(key)) {
                log.warn("manifest.permissions.unknown_key key={s}", .{key});
            }
        }
        // Pop the value, keep the key for the next lua_next.
        c.lua_pop(L.handle, 1);
    }
}

test "manifest: parse valid table" {
    const testing = std.testing;
    var L = try State.init();
    defer L.deinit();

    try testing.expect(L.doString(
        \\return { name = "test_plugin", version = "1.0.0", author = "dev" }
    ));

    var manifest = try Manifest.parse(testing.allocator, &L);
    defer manifest.deinit(testing.allocator);

    try testing.expectEqualStrings("test_plugin", manifest.name);
    try testing.expectEqualStrings("1.0.0", manifest.version);
    try testing.expectEqualStrings("dev", manifest.author);
}

test "manifest: missing name returns error" {
    var L = try State.init();
    defer L.deinit();

    try std.testing.expect(L.doString("return { version = '1.0.0' }"));
    try std.testing.expectError(error.MissingPluginName, Manifest.parse(std.testing.allocator, &L));
}

test "manifest: missing version returns error" {
    var L = try State.init();
    defer L.deinit();

    try std.testing.expect(L.doString("return { name = 'test' }"));
    try std.testing.expectError(error.MissingPluginVersion, Manifest.parse(std.testing.allocator, &L));
}

test "manifest: parse permissions" {
    const testing = std.testing;
    var L = try State.init();
    defer L.deinit();

    try testing.expect(L.doString(
        \\return {
        \\  name = "test_plugin",
        \\  version = "1.0.0",
        \\  permissions = {
        \\    file_access = true,
        \\    network_access = true,
        \\    allow_os_execute = true,
        \\    instruction_limit = 50000,
        \\    memory_limit_mb = 32,
        \\  }
        \\}
    ));

    var manifest = try Manifest.parse(testing.allocator, &L);
    defer manifest.deinit(testing.allocator);

    try testing.expect(manifest.permissions.file_access);
    try testing.expect(manifest.permissions.network_access);
    try testing.expect(manifest.permissions.allow_os_execute);
    try testing.expectEqual(@as(u32, 50000), manifest.permissions.instruction_limit);
    try testing.expectEqual(@as(u32, 32), manifest.permissions.memory_limit_mb);
}

test "manifest: default permissions when not specified" {
    const testing = std.testing;
    var L = try State.init();
    defer L.deinit();

    try testing.expect(L.doString(
        \\return { name = "test", version = "1.0.0" }
    ));

    var manifest = try Manifest.parse(testing.allocator, &L);
    defer manifest.deinit(testing.allocator);

    try testing.expect(!manifest.permissions.file_access);
    try testing.expect(!manifest.permissions.network_access);
    try testing.expect(manifest.permissions.require_others);
}

test "manifest: isRecognizedPermissionKey accepts all valid keys (T3)" {
    const testing = std.testing;
    for ([_][]const u8{
        "file_access",
        "network_access",
        "require_others",
        "allow_os_execute",
        "allow_os_exit",
        "allow_os_remove",
        "instruction_limit",
        "memory_limit_mb",
        "timeout_ms",
    }) |key| {
        try testing.expect(isRecognizedPermissionKey(key));
    }
}

test "manifest: isRecognizedPermissionKey rejects a typo (T3)" {
    const testing = std.testing;
    // A typo'd key must be flagged so it isn't silently swallowed.
    try testing.expect(!isRecognizedPermissionKey("reqiure_others"));
    try testing.expect(!isRecognizedPermissionKey("file_acces"));
    try testing.expect(!isRecognizedPermissionKey(""));
}
