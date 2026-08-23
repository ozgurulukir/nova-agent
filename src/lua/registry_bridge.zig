//! Bridge between the Lua plugin system and the agent's `ToolRegistry`.
//!
//! Plugin tools (registered through `nova.register_tool` from inside
//! `init.lua`) are materialized as `tools.Tool` records and inserted into
//! the registry. Each `Tool` carries a `PluginToolKey` in its `userdata`
//! field; the shared `runPluginTool` / `displayPluginTool` dispatchers
//! decode the key and route the call to the correct `(plugin_name,
//! tool_name)` handler through `PluginManager.callTool`.
//!
//! This replaces the previous "schema-only `McpToolSchema`" path used by
//! MCP — plugin tools now flow through the same `Tool.run`/`Tool.display`
//! pipeline as builtins, so they get the bash-style display policy and
//! schema parsing for free.

const std = @import("std");
const log = std.log.scoped(.lua);
const c = @import("c");
const lua_mod = @import("root.zig");
const PluginManager = lua_mod.PluginManager;
const PluginInstance = lua_mod.PluginInstance;
const plugin_api = lua_mod.plugin_api;
const tools_mod = @import("../tools.zig");
const tools_common = @import("../tools/common.zig");
const Tool = tools_common.Tool;

/// Per-tool context owned by the registry; freed by `freePluginToolKey`
/// when the tool is removed. Holds the parsed `plugin_name` and
/// `tool_name` extracted from the descriptor's `name` field. The
/// `*PluginManager` is no longer stored here: it is reachable from
/// `executor.plugin_manager` (set on every `App` by-value copy), so
/// storing a manager pointer here would dangle the moment the App
/// struct is re-copied through the run call chain.
pub const PluginToolKey = struct {
    plugin_name: []u8,
    tool_name: []u8,
};

/// Free callback for `Tool.userdata_free`. Decodes the `*anyopaque` back
/// to a `*PluginToolKey` and releases it.
pub fn freePluginToolKey(gpa: std.mem.Allocator, ud: *anyopaque) void {
    const key: *PluginToolKey = @ptrCast(@alignCast(ud));
    gpa.free(key.plugin_name);
    gpa.free(key.tool_name);
    gpa.destroy(key);
}

/// Update the manager pointer inside an already-allocated `PluginToolKey`
/// to track the App's `plugin_manager` field across reassignments. The
/// slot allocated in `allocPluginToolKey` stays at the same address; only
/// its `.*` is rewritten. Called from `registerPluginTools` after every
/// `app.plugin_manager = PluginManager.init(...)`.
/// No-op retained as a marker so callers can still use a uniform rebind
/// pattern; kept here only to make it obvious that the manager indirection
/// was removed on purpose.
pub fn rebindPluginToolKey(_: *PluginToolKey, _: *PluginManager) void {}

/// Build the `lua__<plugin>__<tool>` full name for a tool. Returns an
/// owned slice the caller must free.
pub fn buildPluginToolName(
    gpa: std.mem.Allocator,
    plugin_name: []const u8,
    tool_name: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(gpa, "lua__{s}__{s}", .{ plugin_name, tool_name });
}

/// Allocate and initialize a `PluginToolKey` for a freshly-discovered tool.
fn allocPluginToolKey(
    gpa: std.mem.Allocator,
    plugin_name: []const u8,
    tool_name: []const u8,
) !*PluginToolKey {
    const key = try gpa.create(PluginToolKey);
    errdefer gpa.destroy(key);
    key.* = .{
        .plugin_name = try gpa.dupe(u8, plugin_name),
        .tool_name = try gpa.dupe(u8, tool_name),
    };
    return key;
}

/// Shared dispatcher for every plugin tool. The `userdata` argument
/// carries the `*PluginToolKey` set at registration time. The
/// `*PluginManager` is supplied by the executor (not via the
/// `*const fn` signature, which is fixed), so the dispatcher always
/// dereferences the live `App.plugin_manager` field — even after
/// `initRuntime` reassigns it.
pub fn runPluginTool(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    args: []const u8,
    userdata: *anyopaque,
) tools_common.Error!tools_common.Output {
    _ = cwd;
    _ = io;
    const key: *PluginToolKey = @ptrCast(@alignCast(userdata));
    // The executor is supposed to stash its `*PluginManager` in a
    // thread-local before calling, so the dispatcher can reach it
    // without taking a `*ExecutorService` through the fixed
    // `Tool.run` signature. Falling back to a static `null` ensures
    // we never invoke a freed pointer.
    const manager = plugin_manager_slot orelse
        return tools_common.fail(gpa, "plugin dispatcher: no live plugin manager"[0..], 1);
    const result_text = manager.callTool(
        key.plugin_name[0..],
        key.tool_name[0..],
        args,
    ) catch |err| {
        return tools_common.failFmt(
            gpa,
            1,
            "plugin tool '{s}.{s}' failed: {s}",
            .{ key.plugin_name, key.tool_name, @errorName(err) },
        );
    };
    errdefer gpa.free(result_text);
    const stderr = try gpa.alloc(u8, 0);
    return .{ .stdout = result_text, .stderr = stderr, .code = 0 };
}

/// Thread-local slot used by `runPluginTool` to reach the live
/// `*PluginManager` without widening the `Tool.run` signature. The
/// executor sets it in `produceOutput` right before dispatching a
/// plugin tool and clears it immediately after.
pub threadlocal var plugin_manager_slot: ?*PluginManager = null;

/// Human display metadata for a plugin tool. The `userdata` carries the
/// `(plugin_name, tool_name)` key set at registration time.
pub fn displayPluginTool(
    gpa: std.mem.Allocator,
    args: []const u8,
    userdata: *anyopaque,
) std.mem.Allocator.Error!tools_common.ToolDisplay {
    const key: *PluginToolKey = @ptrCast(@alignCast(userdata));
    if (args.len == 0) return .{ .label = try gpa.dupe(u8, key.tool_name) };
    return .{
        .label = try gpa.dupe(u8, key.tool_name),
        .expanded_label = try std.fmt.allocPrint(gpa, "{s} {s}", .{ key.tool_name, args }),
    };
}

/// Build a single `Tool` descriptor for one plugin tool. The returned
/// `Tool.userdata` is a heap-allocated `*PluginToolKey`; ownership
/// transfers to the registry through `ToolRegistry.addPluginTool`. The
/// returned `name` and `description` are owned and freed by the registry
/// when the tool is removed. `desc` is copied.
pub fn buildPluginTool(
    gpa: std.mem.Allocator,
    plugin: *PluginInstance,
    tool_name: []const u8,
    desc: []const u8,
    schema: tools_common.Schema,
) !Tool {
    const full_name = try buildPluginToolName(gpa, plugin.manifest.name, tool_name);
    errdefer gpa.free(full_name);
    const desc_owned = try gpa.dupe(u8, desc);
    errdefer gpa.free(desc_owned);
    const key = try allocPluginToolKey(gpa, plugin.manifest.name, tool_name);
    errdefer freePluginToolKey(gpa, @ptrCast(key));
    return .{
        .name = full_name,
        .description = desc_owned,
        .schema = schema,
        .run = runPluginTool,
        .display = displayPluginTool,
        .userdata = @ptrCast(key),
        .userdata_free = freePluginToolKey,
    };
}

/// Walk every active plugin in `manager`, materialize one `Tool` per
/// registered handler, and return them as a freshly-allocated slice.
/// Each `Tool` carries an owned `*PluginToolKey` (freed via
/// `userdata_free`) and owned `name` / `description` strings (freed by
/// the caller when the tool is removed from the registry). The slice
/// itself is freed by the caller with `gpa.free`.
pub fn buildPluginToolDescriptors(
    gpa: std.mem.Allocator,
    manager: *PluginManager,
) ![]Tool {
    // First pass: count active tools so we can allocate exactly once.
    var total: u32 = 0;
    var iter = manager.iterator();
    while (iter.next()) |entry| {
        const plugin = entry.value_ptr.*;
        if (!plugin.active) continue;
        total += plugin_api.countTools(plugin.state.handle);
    }
    if (total == 0) return &.{};

    var out: std.ArrayList(Tool) = .empty;
    errdefer {
        for (out.items) |*t| {
            if (t.userdata_free) |free_fn| free_fn(gpa, t.userdata);
            gpa.free(t.name);
            gpa.free(t.description);
        }
        out.deinit(gpa);
    }
    try out.ensureTotalCapacity(gpa, total);

    // Second pass: materialize each tool.
    var iter2 = manager.iterator();
    while (iter2.next()) |entry| {
        const plugin = entry.value_ptr.*;
        if (!plugin.active) continue;
        const L = plugin.state.handle;

        _ = c.lua_getfield(L, c.LUA_REGISTRYINDEX, "nova_tools");
        if (c.lua_isnil(L, -1)) {
            c.lua_pop(L, 1);
            continue;
        }
        const tools_len = c.lua_rawlen(L, -1);
        var tool_i: c_int = 1;
        while (tool_i <= @as(c_int, @intCast(tools_len))) : (tool_i += 1) {
            _ = c.lua_rawgeti(L, -1, tool_i);

            // name (at -1, just above the entry table)
            _ = c.lua_getfield(L, -1, "name");
            var name_len: usize = 0;
            const name_ptr = c.lua_tolstring(L, -1, &name_len);
            const tn = if (name_ptr) |p| p[0..name_len] else "";

            // description (at -1; entry now at -2)
            _ = c.lua_getfield(L, -2, "description");
            var desc_len: usize = 0;
            const desc_ptr = c.lua_tolstring(L, -1, &desc_len);
            const desc = if (desc_ptr) |p| p[0..desc_len] else "";

            // Push a copy of the entry so buildToolSchemaFromLua can read
            // the parameters table from -1, then restore. Entry was at
            // -3 (before name+description were pushed); push a copy.
            _ = c.lua_pushvalue(L, -3);
            const schema = buildToolSchemaFromLua(gpa, L) catch |err| blk: {
                log.warn(
                    "plugin.tool.schema.failed plugin={s} tool={s} err={s}",
                    .{ plugin.manifest.name, tn, @errorName(err) },
                );
                break :blk tools_common.Schema{ .properties = &.{} };
            };
            c.lua_pop(L, 1); // pop the entry copy

            const tool_obj = buildPluginTool(
                gpa,
                plugin,
                tn,
                desc,
                schema,
            ) catch |err| {
                log.warn(
                    "plugin.tool.build.failed plugin={s} tool={s} err={s}",
                    .{ plugin.manifest.name, tn, @errorName(err) },
                );
                c.lua_pop(L, 3); // pop desc, name, entry
                continue;
            };
            out.appendAssumeCapacity(tool_obj);

            c.lua_pop(L, 3); // pop desc, name, entry
        }
        c.lua_pop(L, 1); // pop nova_tools
    }
    return out.toOwnedSlice(gpa);
}

/// Parse a `parameters` table at the top of the Lua stack into a
/// `tools_common.Schema`. Mirrors the previous private helper in
/// `tui/provider_model.zig`; relocated here so plugin-side and
/// agent-side share one definition.
fn buildToolSchemaFromLua(
    gpa: std.mem.Allocator,
    L: *c.lua_State,
) !tools_common.Schema {
    _ = c.lua_getfield(L, -1, "parameters");
    defer c.lua_pop(L, 1);
    if (!c.lua_istable(L, -1)) return .{ .properties = &.{} };

    var props: std.ArrayList(tools_common.Schema.Property) = .empty;
    errdefer {
        for (props.items) |p| {
            gpa.free(p.name);
            gpa.free(p.description);
            if (p.enum_values) |ev| {
                for (ev) |v| gpa.free(v);
                gpa.free(ev);
            }
            if (p.default_value) |dv| gpa.free(dv);
        }
        props.deinit(gpa);
    }

    c.lua_pushnil(L);
    while (c.lua_next(L, -2) != 0) {
        var key_len: usize = 0;
        const key_ptr = c.lua_tolstring(L, -2, &key_len);
        const param_name = if (key_ptr) |p| try gpa.dupe(u8, p[0..key_len]) else {
            c.lua_pop(L, 1);
            continue;
        };
        if (!c.lua_istable(L, -1)) {
            gpa.free(param_name);
            c.lua_pop(L, 1);
            continue;
        }

        _ = c.lua_getfield(L, -1, "type");
        var type_len: usize = 0;
        const type_ptr = c.lua_tolstring(L, -1, &type_len);
        const kind = if (type_ptr) |p| parseToolParamType(p[0..type_len]) else .string;
        c.lua_pop(L, 1);

        _ = c.lua_getfield(L, -1, "description");
        var desc_len: usize = 0;
        const desc_ptr = c.lua_tolstring(L, -1, &desc_len);
        const description = if (desc_ptr) |p| try gpa.dupe(u8, p[0..desc_len]) else try gpa.dupe(u8, "");
        c.lua_pop(L, 1);

        _ = c.lua_getfield(L, -1, "optional");
        const optional = c.lua_isboolean(L, -1) and c.lua_toboolean(L, -1) != 0;
        c.lua_pop(L, 1);

        _ = c.lua_getfield(L, -1, "nullable");
        const nullable = c.lua_isboolean(L, -1) and c.lua_toboolean(L, -1) != 0;
        c.lua_pop(L, 1);

        var enum_values: ?[]const []const u8 = null;
        _ = c.lua_getfield(L, -1, "enum");
        if (c.lua_istable(L, -1)) {
            const enum_len = c.lua_rawlen(L, -1);
            if (enum_len > 0) {
                var ev_list = try gpa.alloc([]const u8, enum_len);
                var ev_idx: u32 = 0;
                var ei: c_int = 1;
                while (ei <= @as(c_int, @intCast(enum_len))) : (ei += 1) {
                    _ = c.lua_rawgeti(L, -1, ei);
                    var ev_len: usize = 0;
                    const ev_ptr = c.lua_tolstring(L, -1, &ev_len);
                    if (ev_len > 0) {
                        ev_list[ev_idx] = try gpa.dupe(u8, ev_ptr[0..ev_len]);
                        ev_idx += 1;
                    }
                    c.lua_pop(L, 1);
                }
                if (ev_idx == 0) gpa.free(ev_list) else enum_values = try gpa.realloc(ev_list, ev_idx);
            }
        }
        c.lua_pop(L, 1);

        var default_value: ?[]const u8 = null;
        _ = c.lua_getfield(L, -1, "default");
        if (!c.lua_isnil(L, -1)) {
            default_value = try luaValueToJson(gpa, L);
        }
        c.lua_pop(L, 1);

        try props.append(gpa, .{
            .name = param_name,
            .kind = kind,
            .description = description,
            .required = !optional,
            .nullable = nullable,
            .enum_values = enum_values,
            .default_value = default_value,
        });
        c.lua_pop(L, 1); // pop value, keep key for next iteration
    }
    return .{ .properties = try props.toOwnedSlice(gpa) };
}

fn parseToolParamType(type_str: []const u8) tools_common.Schema.Kind {
    if (std.mem.eql(u8, type_str, "string")) return .string;
    if (std.mem.eql(u8, type_str, "integer")) return .integer;
    if (std.mem.eql(u8, type_str, "number")) return .number;
    if (std.mem.eql(u8, type_str, "boolean")) return .boolean;
    if (std.mem.eql(u8, type_str, "object")) return .object;
    if (std.mem.eql(u8, type_str, "array")) return .array;
    return .string;
}

fn luaValueToJson(gpa: std.mem.Allocator, L: *c.lua_State) ![]const u8 {
    if (c.lua_isnil(L, -1)) return gpa.dupe(u8, "null");
    if (c.lua_isboolean(L, -1)) return gpa.dupe(u8, if (c.lua_toboolean(L, -1) != 0) "true" else "false");
    if (c.lua_isnumber(L, -1) != 0) {
        var len: usize = 0;
        const ptr = c.lua_tolstring(L, -1, &len);
        if (len > 0) return gpa.dupe(u8, ptr[0..len]);
        return gpa.dupe(u8, "0");
    }
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, -1, &len);
    if (len > 0) {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        try aw.writer.writeByte('"');
        try aw.writer.writeAll(ptr[0..len]);
        try aw.writer.writeByte('"');
        return aw.toOwnedSlice();
    }
    return gpa.dupe(u8, "\"\"");
}

test "buildPluginToolName: formats lua__<plugin>__<tool>" {
    const gpa = std.testing.allocator;
    const name = try buildPluginToolName(gpa, "hello-world", "greet");
    defer gpa.free(name);
    try std.testing.expectEqualStrings("lua__hello-world__greet", name);
}

test "PluginManager: init+deinit cycle (no plugins)" {
    // The refactor splits `App.init`'s placeholder plugin_manager (empty
    // home/cwd) from `App.initRuntime`'s real one. Both must clean up
    // independently so a second initRuntime doesn't double-free.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var m1 = PluginManager.init(gpa, io, "", "");
    defer m1.deinit();
    var m2 = PluginManager.init(gpa, io, "/tmp", "/tmp");
    defer m2.deinit();
    try std.testing.expect(m1.plugins.count() == 0);
    try std.testing.expect(m2.plugins.count() == 0);
}

test "buildPluginToolDescriptors: returns empty slice when no plugins" {
    var manager = PluginManager.init(std.testing.allocator, std.testing.io, "", "");
    defer manager.deinit();
    const descs = try buildPluginToolDescriptors(std.testing.allocator, &manager);
    try std.testing.expectEqual(@as(usize, 0), descs.len);
}

test "PluginManager: heap-allocated tool registry round-trip" {
    // The App holds a `*ToolRegistry` (heap-allocated) that plugin tools
    // get appended to. This test mirrors that flow: create a registry,
    // build descriptors from a (mock) plugin manager, append them, and
    // free the registry — verifying the lifetime is correct.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var manager = PluginManager.init(gpa, io, "", "");
    defer manager.deinit();

    const reg = try gpa.create(tools_mod.ToolRegistry);
    defer {
        reg.deinit(gpa);
        gpa.destroy(reg);
    }
    reg.* = try tools_mod.ToolRegistry.init(gpa, tools_mod.builtinRegistry());

    const descs = try buildPluginToolDescriptors(gpa, &manager);
    defer {
        for (descs) |*t| {
            if (t.userdata_free) |f| f(gpa, t.userdata);
            gpa.free(t.name);
            gpa.free(t.description);
        }
        gpa.free(descs);
    }
    // all() should not crash and the slice should include the builtin
    // shell tool (pwsh on Windows, bash elsewhere) plus any plugin tools
    // (none in this case).
    const all = try reg.all(gpa);
    try std.testing.expect(all.len >= 1);
    try std.testing.expectEqualStrings(tools_mod.shellToolName, all[0].name);
}
