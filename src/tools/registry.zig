const std = @import("std");

const background_tool = @import("background.zig");
const bash_tool = @import("bash.zig");
const common = @import("common.zig");
const lane_tool = @import("lane.zig");
const os = @import("../os.zig");
const pwsh_tool = @import("pwsh.zig");
const skill_tool = @import("skill.zig");
const Tool = common.Tool;

/// Runtime-mutable tool registry. The App owns one; builtin tools live in
/// its immutable `builtin` slice, plugin tools are appended at runtime
/// through `addPluginTool`. This is the single source of truth for tools
/// in the agent — `tools.runWith` (dispatch) and each `LanguageModel`
/// adapter (schema serialization) read from `all`.
///
/// `all()` returns a borrowed slice that aliases the registry's internal
/// storage. It is invalidated by any `addPluginTool` / `removePluginToolsOf`
/// call — callers must consume the slice before mutating.
pub const ToolRegistry = struct {
    /// Immutable builtin tools (bash or pwsh, per `shell_tool`). Same backing as
    /// `builtinRegistry()`.
    builtin: []const Tool,
    /// Plugin tools appended at runtime. Each owns its `userdata` allocation
    /// through `Tool.userdata_free`; `deinit` calls them.
    plugin: std.ArrayList(Tool) = .empty,
    /// Backing storage for the borrowed slice returned by `all`. The capacity
    /// is reused across calls so the `all()` pointer is stable between calls
    /// that don't add or remove tools.
    scratch: std.ArrayList(Tool) = .empty,

    pub fn init(builtin_slice: []const Tool) ToolRegistry {
        return .{ .builtin = builtin_slice };
    }

    pub fn deinit(self: *ToolRegistry, gpa: std.mem.Allocator) void {
        for (self.plugin.items) |*t| {
            // Plugin tool's `name` and `description` are always owned and
            // heap-allocated (see `buildPluginTool` in the registry
            // bridge). Free them here so the registry is the single
            // source of truth for plugin tool lifetimes.
            gpa.free(t.name);
            gpa.free(t.description);
            if (t.userdata_free) |free_fn| free_fn(gpa, t.userdata);
        }
        self.plugin.deinit(gpa);
        self.scratch.deinit(gpa);
    }

    /// Borrowed flat slice of every registered tool (builtin + plugin). The
    /// slice aliases `scratch` storage; it is invalidated by any mutation
    /// that adds or removes a tool. Callers should consume the slice
    /// synchronously — do not stash it across `addPluginTool` calls.
    pub fn all(self: *ToolRegistry, gpa: std.mem.Allocator) ![]const Tool {
        self.scratch.clearRetainingCapacity();
        try self.scratch.appendSlice(gpa, self.builtin);
        try self.scratch.appendSlice(gpa, self.plugin.items);
        return self.scratch.items;
    }

    /// Look up a tool by name. Searches builtin first (so builtins always
    /// win name collisions), then plugin tools. Returns null when absent.
    pub fn lookup(self: *ToolRegistry, gpa: std.mem.Allocator, name: []const u8) !?Tool {
        for (self.builtin) |tool| {
            if (std.mem.eql(u8, tool.name, name)) return tool;
        }
        for (self.plugin.items) |tool| {
            if (std.mem.eql(u8, tool.name, name)) return tool;
        }
        _ = gpa;
        return null;
    }

    /// Append a plugin tool. The registry takes ownership of `tool.userdata`
    /// and will free it via `tool.userdata_free` on `deinit` or when
    /// `removePluginToolsWithPrefix` strips the tool.
    pub fn addPluginTool(self: *ToolRegistry, gpa: std.mem.Allocator, tool: Tool) !void {
        try self.plugin.append(gpa, tool);
    }

    /// Remove every plugin tool whose name starts with the
    /// `<prefix>__` namespace (e.g. `lua__<plugin_name>__`). Frees each
    /// matching tool's `userdata` before splicing it out. Idempotent: a
    /// no-op when no tools match.
    pub fn removePluginToolsWithPrefix(
        self: *ToolRegistry,
        gpa: std.mem.Allocator,
        prefix: []const u8,
    ) void {
        var i: usize = 0;
        while (i < self.plugin.items.len) {
            const t = self.plugin.items[i];
            if (std.mem.startsWith(u8, t.name, prefix)) {
                gpa.free(t.name);
                gpa.free(t.description);
                if (t.userdata_free) |free_fn| free_fn(gpa, t.userdata);
                _ = self.plugin.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

/// The model-facing shell tool selected at comptime: `pwsh` on Windows,
/// `bash` elsewhere. THE single source of truth for the bash↔pwsh switch —
/// every consumer (the builtin list below, the executor's dispatch, the TUI
/// display policy) reads the selected name from here.
pub const shell_tool: Tool = if (os.is_windows) pwsh_tool.tool else bash_tool.tool;

/// Canonical builtin tool list. Consumed by `ToolRegistry.init` and by
/// `src/tools.zig`'s re-export (all single-registry call sites).
pub fn builtin() []const Tool {
    return &.{ shell_tool, lane_tool.tool, background_tool.tool, skill_tool.tool };
}

const tools_common = @import("common.zig");

// Sentinel tool for testing — has a valid name/description/schema so the
// test doesn't trip on dereferencing dangling slices.
const dummy_free: *const fn (gpa: std.mem.Allocator, ud: *anyopaque) void = struct {
    fn free(gpa: std.mem.Allocator, ud: *anyopaque) void {
        _ = gpa;
        _ = ud;
    }
}.free;

const dummy_run: *const fn (
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    args: []const u8,
    userdata: *anyopaque,
) tools_common.Error!tools_common.Output = struct {
    fn run(
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        args: []const u8,
        userdata: *anyopaque,
    ) tools_common.Error!tools_common.Output {
        _ = io;
        _ = cwd;
        _ = args;
        _ = userdata;
        const stdout = try gpa.dupe(u8, "ok");
        const stderr = try gpa.alloc(u8, 0);
        return .{ .stdout = stdout, .stderr = stderr, .code = 0 };
    }
}.run;

const dummy_display: *const fn (
    gpa: std.mem.Allocator,
    args: []const u8,
    userdata: *anyopaque,
) std.mem.Allocator.Error!tools_common.ToolDisplay = struct {
    fn display(
        gpa: std.mem.Allocator,
        args: []const u8,
        userdata: *anyopaque,
    ) std.mem.Allocator.Error!tools_common.ToolDisplay {
        _ = args;
        _ = userdata;
        return .{ .label = try gpa.dupe(u8, "dummy") };
    }
}.display;

test "ToolRegistry: lookup finds builtin tools" {
    const gpa = std.testing.allocator;
    var reg: ToolRegistry = .init(@import("../tools.zig").builtinRegistry());
    defer reg.deinit(gpa);

    const maybe_tool = try reg.lookup(gpa, shell_tool.name);
    try std.testing.expect(maybe_tool != null);
    const tool = maybe_tool.?;
    try std.testing.expectEqualStrings(shell_tool.name, tool.name);
}

test "ToolRegistry: lookup returns null for unknown tool" {
    const gpa = std.testing.allocator;
    var reg: ToolRegistry = .init(@import("../tools.zig").builtinRegistry());
    defer reg.deinit(gpa);

    try std.testing.expect((try reg.lookup(gpa, "nope")) == null);
}

test "ToolRegistry: addPluginTool makes plugin tool discoverable" {
    const gpa = std.testing.allocator;
    var reg: ToolRegistry = .init(@import("../tools.zig").builtinRegistry());
    defer reg.deinit(gpa);

    const name = try gpa.dupe(u8, "lua__p__t");
    errdefer gpa.free(name);
    const desc = try gpa.dupe(u8, "plugin tool");
    errdefer gpa.free(desc);

    try reg.addPluginTool(gpa, .{
        .name = name,
        .description = desc,
        .schema = .{ .properties = &.{} },
        .run = dummy_run,
        .display = dummy_display,
        .userdata = undefined,
        .userdata_free = dummy_free,
    });

    const maybe_tool = try reg.lookup(gpa, "lua__p__t");
    try std.testing.expect(maybe_tool != null);
    const tool = maybe_tool.?;
    try std.testing.expectEqualStrings("lua__p__t", tool.name);
    try std.testing.expectEqualStrings("plugin tool", tool.description);

    const all = try reg.all(gpa);
    try std.testing.expectEqual(@as(usize, 5), all.len); // shell + lane + background + skill + plugin
    try std.testing.expectEqualStrings(shell_tool.name, all[0].name);
    try std.testing.expectEqualStrings("lane", all[1].name);
    try std.testing.expectEqualStrings("background", all[2].name);
    try std.testing.expectEqualStrings("skill", all[3].name);
    try std.testing.expectEqualStrings("lua__p__t", all[4].name);
}

test "ToolRegistry: removePluginToolsWithPrefix strips matching tools" {
    const gpa = std.testing.allocator;
    var reg: ToolRegistry = .init(@import("../tools.zig").builtinRegistry());
    defer reg.deinit(gpa);

    const mk = struct {
        fn make(gpa_: std.mem.Allocator, reg_: *ToolRegistry, n: []const u8) !void {
            const name = try gpa_.dupe(u8, n);
            errdefer gpa_.free(name);
            const desc = try gpa_.dupe(u8, "d");
            errdefer gpa_.free(desc);
            try reg_.addPluginTool(gpa_, .{
                .name = name,
                .description = desc,
                .schema = .{ .properties = &.{} },
                .run = dummy_run,
                .display = dummy_display,
                .userdata = undefined,
                .userdata_free = dummy_free,
            });
        }
    }.make;
    try mk(gpa, &reg, "lua__p__a");
    try mk(gpa, &reg, "lua__p__b");
    try mk(gpa, &reg, "mcp__x__c"); // should not be removed

    reg.removePluginToolsWithPrefix(gpa, "lua__p__");
    try std.testing.expect((try reg.lookup(gpa, "lua__p__a")) == null);
    try std.testing.expect((try reg.lookup(gpa, "lua__p__b")) == null);
    try std.testing.expect((try reg.lookup(gpa, "mcp__x__c")) != null);
    try std.testing.expect((try reg.lookup(gpa, shell_tool.name)) != null);
    try std.testing.expect((try reg.lookup(gpa, "skill")) != null);
}

test "ToolRegistry: strip-and-rebuild keeps plugin tools unique across re-registration" {
    // Pins registerPluginTools' re-sync semantics (P8): strip all `lua__`
    // tools, then append fresh — duplicate names can never reach
    // buildAllToolsJson (strict providers 400 on duplicate tool names).
    // registerPluginTools runs at initRuntime today; this pins the
    // idempotency contract for any future re-registration site.
    const gpa = std.testing.allocator;
    var reg: ToolRegistry = .init(@import("../tools.zig").builtinRegistry());
    defer reg.deinit(gpa);

    const mk = struct {
        fn make(gpa_: std.mem.Allocator, reg_: *ToolRegistry, n: []const u8) !void {
            const name = try gpa_.dupe(u8, n);
            errdefer gpa_.free(name);
            const desc = try gpa_.dupe(u8, "d");
            errdefer gpa_.free(desc);
            try reg_.addPluginTool(gpa_, .{
                .name = name,
                .description = desc,
                .schema = .{ .properties = &.{} },
                .run = dummy_run,
                .display = dummy_display,
                .userdata = undefined,
                .userdata_free = dummy_free,
            });
        }
    }.make;

    // Non-lua plugin tools (the MCP path injects those; registerPluginTools
    // never touches them) are added once, before the re-registration cycles.
    try mk(gpa, &reg, "mcp__x__c");

    // The registerPluginTools sequence, twice (initial sync + any future
    // re-sync).
    for (0..2) |_| {
        reg.removePluginToolsWithPrefix(gpa, "lua__");
        try mk(gpa, &reg, "lua__p__a");
        try mk(gpa, &reg, "lua__p__b");
    }

    // Each lua__ name appears exactly once; non-lua plugin tools survive.
    const all = try reg.all(gpa);
    var lua_a: usize = 0;
    var lua_b: usize = 0;
    var mcp_c: usize = 0;
    for (all) |t| {
        if (std.mem.eql(u8, t.name, "lua__p__a")) lua_a += 1;
        if (std.mem.eql(u8, t.name, "lua__p__b")) lua_b += 1;
        if (std.mem.eql(u8, t.name, "mcp__x__c")) mcp_c += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), lua_a);
    try std.testing.expectEqual(@as(usize, 1), lua_b);
    try std.testing.expectEqual(@as(usize, 1), mcp_c);
}

test "ToolRegistry: all() returns valid slices after multiple calls" {
    // Regression: a refactor that frees a tool's `name`/`description` after
    // addPluginTool corrupts the registry. all() must always return slices
    // whose tool data is fully owned by the registry.
    const gpa = std.testing.allocator;
    var reg: ToolRegistry = .init(@import("../tools.zig").builtinRegistry());
    defer reg.deinit(gpa);

    const mk = struct {
        fn make(gpa_: std.mem.Allocator, reg_: *ToolRegistry, n: []const u8) !void {
            const name = try gpa_.dupe(u8, n);
            errdefer gpa_.free(name);
            const desc = try gpa_.dupe(u8, "test desc");
            errdefer gpa_.free(desc);
            try reg_.addPluginTool(gpa_, .{
                .name = name,
                .description = desc,
                .schema = .{ .properties = &.{} },
                .run = dummy_run,
                .display = dummy_display,
                .userdata = undefined,
                .userdata_free = dummy_free,
            });
        }
    }.make;
    try mk(gpa, &reg, "lua__p__a");
    try mk(gpa, &reg, "lua__p__b");

    // First all(): tools are still allocated.
    {
        const all = try reg.all(gpa);
        try std.testing.expect(all.len == 6); // shell + lane + background + skill + 2 plugin
        for (all) |t| {
            try std.testing.expect(t.name.len > 0);
            try std.testing.expect(t.description.len > 0);
        }
    }

    // Reuse the same registry; backing storage must still be intact.
    {
        const all = try reg.all(gpa);
        try std.testing.expect(all.len == 6);
        for (all) |t| {
            try std.testing.expect(t.name.len > 0);
            try std.testing.expect(t.description.len > 0);
        }
    }
}

test "registry builtin carries exactly one shell tool" {
    // SSOT vector (Phase 3): the builtin list must expose exactly one shell
    // tool (`pwsh` on Windows, `bash` elsewhere) plus `lane`, `background`, and `skill`.
    const tools = builtin();
    try std.testing.expectEqual(@as(usize, 4), tools.len);
    try std.testing.expect(std.mem.eql(u8, tools[0].name, shell_tool.name));
    try std.testing.expectEqualStrings("lane", tools[1].name);
    try std.testing.expectEqualStrings("background", tools[2].name);
    try std.testing.expectEqualStrings("skill", tools[3].name);
    try std.testing.expect(shell_tool.name.len == 4 or std.mem.eql(u8, shell_tool.name, "pwsh"));
}
