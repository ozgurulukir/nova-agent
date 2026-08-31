//! Restricted Lua environment builder.
//!
//! Creates a sandboxed Lua state by replacing the global table (_G) with a
//! controlled environment containing only safe functions and libraries.
//! Resource limits (instruction count, memory) are enforced via a Lua hook.

const std = @import("std");
const c = @import("c");
const State = @import("state.zig").State;
const plugin_api = @import("plugin_api.zig");
const platform = @import("platform");

/// Permissions granted to a plugin.
pub const Permissions = struct {
    /// Advisory: the `nova.*` bridge is always sandboxed and `io.*`/`socket.*`
    /// are never exposed, so this field gates nothing today. Kept for forward
    /// compatibility; do not rely on it to grant or deny access.
    file_access: bool = false,
    /// Advisory: `socket.*` is never exposed, so this gates nothing today.
    network_access: bool = false,
    /// Advisory: the `package` library is never exposed, so this gates nothing
    /// today. Kept for forward compatibility.
    require_others: bool = true,
    /// Full access to all Lua standard libraries (embedded plugins only)
    full_access: bool = false,
    /// Allow os.execute
    allow_os_execute: bool = false,
    /// Allow os.remove/os.rename
    allow_os_remove: bool = false,
    /// Maximum Lua instructions before abort (0 = unlimited). This is a
    /// **per-dispatch** budget — reset before each tool call / event callback
    /// by `resetInstructionBudget`, so a busy plugin can't exhaust it for the
    /// rest of the session.
    instruction_limit: u32 = 100_000,
    /// Maximum memory in MB (0 = unlimited)
    memory_limit_mb: u32 = 16,
    /// Timeout in ms (approximate, based on instruction count — the hook
    /// checks the deadline every 1000 instructions, so a short timeout may
    /// overshoot by up to ~1000 instructions of work).
    timeout_ms: u32 = 5000,
};

/// Data stored in lua_getextraspace for the instruction hook.
const HookData = struct {
    instruction_limit: u32,
    instruction_count: u32,
    memory_limit: usize,
    /// Timeout in ms for the current dispatch (0 = no timeout).
    timeout_ms: u32,
    /// Absolute deadline (ns since epoch) for the current dispatch, or 0 when
    /// no timeout is set. Reset per-dispatch by `resetInstructionBudget`.
    deadline_ns: i128 = 0,
};

/// Monotonic clock reading in nanoseconds, used for the per-dispatch timeout.
/// The instruction hook has no `Io` handle, so it reads the OS clock directly.
/// Falls back to 0 (no timeout) if the clock is unavailable.
fn monotonicNowNs() i128 {
    return platform.monotonicNowNs();
}

/// Instruction count hook function.
/// Fires every 1000 instructions and checks resource limits.
fn instructionHook(L: ?*c.lua_State, ar: [*c]c.lua_Debug) callconv(.c) void {
    _ = ar;
    const L_ptr = L orelse return;
    const slot = @as(*?*HookData, @ptrCast(@alignCast(c.lua_getextraspace(L_ptr))));
    const data = slot.* orelse return;
    data.instruction_count += 1;
    if (data.instruction_count >= data.instruction_limit) {
        _ = c.luaL_error(L_ptr, "instruction limit exceeded");
    }
    // Approximate timeout check (1000-instruction granularity, by design).
    if (data.deadline_ns != 0 and monotonicNowNs() >= data.deadline_ns) {
        _ = c.luaL_error(L_ptr, "timeout exceeded");
    }
    // Check memory every 1000 instructions
    const mem_kb = c.lua_gc(L_ptr, c.LUA_GCCOUNT, @as(c_int, 0));
    if (@as(usize, @intCast(mem_kb)) * 1024 >= data.memory_limit) {
        _ = c.luaL_error(L_ptr, "memory limit exceeded");
    }
}

/// Reset the per-dispatch instruction budget and timeout deadline on `L`.
/// The instruction count is a per-session accumulator that nothing else
/// resets; without this, a busy plugin eventually fails every call with
/// "instruction limit exceeded" for the rest of the session. Resetting here
/// makes the limit mean "per tool call / per event", which matches intuition.
/// No-op when the hook data is null (full-access sandboxes have no hook).
pub fn resetInstructionBudget(L: *c.lua_State) void {
    const slot = @as(*?*HookData, @ptrCast(@alignCast(c.lua_getextraspace(L))));
    const data = slot.* orelse return;
    data.instruction_count = 0;
    data.deadline_ns = if (data.timeout_ms > 0)
        monotonicNowNs() + @as(i128, data.timeout_ms) * std.time.ns_per_ms
    else
        0;
}

/// Create a new sandboxed Lua state with restricted permissions.
/// `io` is optional — when provided, plugin API functions (read_file, etc.)
/// are registered in the `nova` table. When undefined, only the sandboxed
/// environment is created (for test runners that don't have a real Io).
/// Caller owns the returned State and must call `deinit`.
pub fn createSandboxedState(permissions: Permissions) !State {
    return createSandboxedStateWithIo(permissions, null);
}

/// Create a sandboxed state with a specific Io instance (for plugin API).
/// Returns `error.LuaInitFailed` if the Lua runtime cannot allocate the state.
pub fn createSandboxedStateWithIo(permissions: Permissions, io: ?std.Io) error{ LuaInitFailed, OutOfMemory }!State {
    const L = c.luaL_newstate() orelse return error.LuaInitFailed;

    // Initialize extraspace to null (no hook data yet)
    @as(*?*HookData, @ptrCast(@alignCast(c.lua_getextraspace(L)))).* = null;

    // Open all standard libraries
    c.luaL_openlibs(L);

    // Register plugin API functions when Io is provided
    if (io != null) {
        const io_storage = @as(*std.Io, @ptrCast(@alignCast(c.lua_newuserdata(L, @sizeOf(std.Io)))));
        io_storage.* = io.?;
        c.lua_setfield(L, c.LUA_REGISTRYINDEX, "nova_io");
        registerPluginApi(L);
    }

    // The `plugin` table needs no Io and must exist in full-access states
    // too (embedded plugins, the Lua test runner), which skip the restricted
    // environment below — hence unconditional registration.
    registerPluginTable(L);

    if (!permissions.full_access) {
        createRestrictedEnvironment(L, permissions);
        try setupInstructionHook(L, permissions);
    }

    return State{ .handle = L };
}

/// Registry key under which `PluginManager.loadOne` stores a plugin's
/// pre-encoded JSON settings string. `lua_pushlstring` copies the bytes into
/// the Lua GC, so the manager keeps no ownership of the stored value; the
/// string is re-parsed per `plugin.get_config()` call, yielding a fresh table
/// whose mutation cannot corrupt the stored settings.
pub const settings_registry_key = "nova_plugin_settings";

/// Register the `plugin` global table (`plugin.get_config`). Like `nova`, it is
/// set on the real _G AND copied into the restricted environment — full-access
/// states never swap _G, so a copy-only registration would hide the table from
/// embedded plugins and the Lua test runner.
fn registerPluginTable(L: *c.lua_State) void {
    c.lua_newtable(L);
    c.lua_pushcfunction(L, plugin_api.pluginGetConfig);
    _ = c.lua_setfield(L, -2, "get_config");
    c.lua_setglobal(L, "plugin");
}

/// Register Nova plugin API functions into the `nova` global table.
/// These are safe C functions that plugins can call instead of blocked
/// libraries like `io.*`.
fn registerPluginApi(L: *c.lua_State) void {
    // Initialize module cache in registry
    c.lua_newtable(L);
    c.lua_setfield(L, c.LUA_REGISTRYINDEX, "nova_loaded_modules");

    // Create the nova table
    c.lua_newtable(L);

    // Register each function
    const funcs = [_]struct { name: [:0]const u8, func: c.lua_CFunction }{
        .{ .name = "require", .func = plugin_api.requireModule },
        .{ .name = "read_file", .func = plugin_api.readFile },
        .{ .name = "write_file", .func = plugin_api.writeFile },
        .{ .name = "edit_file", .func = plugin_api.editFile },
        .{ .name = "search_files", .func = plugin_api.searchFiles },
        .{ .name = "find_files", .func = plugin_api.findFiles },
        .{ .name = "list_dir", .func = plugin_api.listDir },
        .{ .name = "file_info", .func = plugin_api.fileInfo },
        .{ .name = "mkdir", .func = plugin_api.mkdir },
        .{ .name = "copy_path", .func = plugin_api.copyPath },
        .{ .name = "move_path", .func = plugin_api.movePath },
        .{ .name = "delete_path", .func = plugin_api.deletePath },
        .{ .name = "run_bash", .func = plugin_api.runBash },
        .{ .name = "run_shell", .func = plugin_api.runShell },
        .{ .name = "get_env", .func = plugin_api.getEnv },
        .{ .name = "get_cwd", .func = plugin_api.getCwd },
        .{ .name = "get_project_root", .func = plugin_api.getProjectRoot },
        .{ .name = "register_tool", .func = plugin_api.registerTool },
        .{ .name = "on", .func = plugin_api.onEvent },
        .{ .name = "json_decode", .func = plugin_api.jsonDecode },
        .{ .name = "json_encode", .func = plugin_api.jsonEncode },
        .{ .name = "shell_quote", .func = plugin_api.shellQuote },
        .{ .name = "git_status", .func = plugin_api.gitStatus },
        .{ .name = "git_diff", .func = plugin_api.gitDiff },
        .{ .name = "git_log", .func = plugin_api.gitLog },
        .{ .name = "git_branch", .func = plugin_api.gitBranch },
        .{ .name = "git_add", .func = plugin_api.gitAdd },
        .{ .name = "git_commit", .func = plugin_api.gitCommit },
        .{ .name = "think", .func = plugin_api.think },
    };

    for (funcs) |f| {
        c.lua_pushcfunction(L, f.func);
        c.lua_setfield(L, -2, f.name.ptr);
    }

    // Set nova as a global
    c.lua_setglobal(L, "nova");
}

/// Create a restricted global environment by replacing _G with a new table
/// containing only safe functions and libraries.
fn createRestrictedEnvironment(L: *c.lua_State, permissions: Permissions) void {
    // Create a new environment table
    c.lua_newtable(L);
    const env_index = c.lua_gettop(L);

    // Copy safe basic functions from the real _G
    copyGlobal(L, env_index, "assert");
    copyGlobal(L, env_index, "error");
    copyGlobal(L, env_index, "getmetatable");
    copyGlobal(L, env_index, "ipairs");
    copyGlobal(L, env_index, "next");
    copyGlobal(L, env_index, "pairs");
    copyGlobal(L, env_index, "pcall");
    copyGlobal(L, env_index, "rawequal");
    copyGlobal(L, env_index, "rawlen");
    copyGlobal(L, env_index, "select");
    copyGlobal(L, env_index, "setmetatable");
    copyGlobal(L, env_index, "tonumber");
    copyGlobal(L, env_index, "tostring");
    copyGlobal(L, env_index, "type");
    copyGlobal(L, env_index, "xpcall");
    copyGlobal(L, env_index, "_VERSION");

    // Copy safe library tables
    copyGlobal(L, env_index, "string");
    copyGlobal(L, env_index, "table");
    copyGlobal(L, env_index, "math");
    copyGlobal(L, env_index, "coroutine");
    copyGlobal(L, env_index, "utf8");

    // Copy the Nova plugin API table so plugins can call nova.register_tool, etc.
    copyGlobal(L, env_index, "nova");
    // And the plugin table (plugin.get_config) beside it.
    copyGlobal(L, env_index, "plugin");

    // Safe os subset
    c.lua_newtable(L);
    const os_index = c.lua_gettop(L);
    _ = c.lua_getglobal(L, "os");
    if (!c.lua_isnil(L, -1)) {
        copyOsFunction(L, os_index, "clock");
        copyOsFunction(L, os_index, "date");
        copyOsFunction(L, os_index, "time");
        copyOsFunction(L, os_index, "difftime");
        if (permissions.allow_os_execute) {
            copyOsFunction(L, os_index, "execute");
        }
        if (permissions.allow_os_remove) {
            copyOsFunction(L, os_index, "remove");
            copyOsFunction(L, os_index, "rename");
        }
    }
    c.lua_pop(L, 1); // pop real os
    c.lua_setfield(L, env_index, "os");

    // Set _G in the environment to point to itself
    c.lua_pushvalue(L, env_index);
    c.lua_setfield(L, env_index, "_G");

    // Replace _G in the registry with the restricted environment
    c.lua_pushvalue(L, env_index);
    c.lua_rawseti(L, c.LUA_REGISTRYINDEX, c.LUA_RIDX_GLOBALS);

    // Pop the environment table
    c.lua_pop(L, 1);
}

/// Copy a global function/table from the real _G into the environment.
fn copyGlobal(L: *c.lua_State, env_index: c_int, name: [:0]const u8) void {
    _ = c.lua_getglobal(L, name.ptr);
    if (!c.lua_isnil(L, -1)) {
        _ = c.lua_setfield(L, env_index, name.ptr);
    } else {
        c.lua_pop(L, 1);
    }
}

/// Copy a single function from the os table into the sandbox os table.
fn copyOsFunction(L: *c.lua_State, os_index: c_int, name: [:0]const u8) void {
    _ = c.lua_getfield(L, -1, name.ptr);
    _ = c.lua_setfield(L, os_index, name.ptr);
}

/// Set up the instruction count hook for resource limits.
fn setupInstructionHook(L: *c.lua_State, permissions: Permissions) std.mem.Allocator.Error!void {
    if (permissions.instruction_limit == 0 and permissions.memory_limit_mb == 0) return;

    const allocator = std.heap.page_allocator;
    const data = try allocator.create(HookData);
    data.* = HookData{
        .instruction_limit = if (permissions.instruction_limit > 0) permissions.instruction_limit else std.math.maxInt(u32),
        .instruction_count = 0,
        .memory_limit = if (permissions.memory_limit_mb > 0) @as(usize, @intCast(permissions.memory_limit_mb)) * 1024 * 1024 else std.math.maxInt(usize),
        .timeout_ms = permissions.timeout_ms,
    };
    @as(*?*HookData, @ptrCast(@alignCast(c.lua_getextraspace(L)))).* = data;
    c.lua_sethook(L, instructionHook, c.LUA_MASKCOUNT, 1000);
}

/// Free the hook data allocated in setupInstructionHook.
/// Must be called before lua_close.
pub fn freeHookData(L: *c.lua_State) void {
    const slot = @as(*?*HookData, @ptrCast(@alignCast(c.lua_getextraspace(L))));
    if (slot.*) |data| {
        std.heap.page_allocator.destroy(data);
        slot.* = null;
    }
}

// ── Tests ────────────────────────────────────────────────────────────

test "sandbox: basic creation" {
    var L = try createSandboxedState(.{});
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    try std.testing.expect(L.doString("return 2 + 2"));
    try std.testing.expectEqual(@as(i64, 4), L.toInteger(-1));
    L.pop(1);
}

test "sandbox: blocks io" {
    var L = try createSandboxedState(.{});
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    try std.testing.expect(L.doString("return io == nil"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}

test "sandbox: blocks debug" {
    var L = try createSandboxedState(.{});
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    try std.testing.expect(L.doString("return debug == nil"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}

test "sandbox: blocks package" {
    var L = try createSandboxedState(.{});
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    try std.testing.expect(L.doString("return package == nil"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}

test "sandbox: globals like type() still work" {
    var L = try createSandboxedState(.{});
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    try std.testing.expect(L.doString("return type('hello')"));
    try std.testing.expectEqualStrings("string", L.toString(-1).?);
    L.pop(1);
}

test "sandbox: full access exposes all libraries" {
    var L = try createSandboxedState(.{ .full_access = true });
    defer L.deinit();

    try std.testing.expect(L.doString("return type(io) == 'table'"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}

test "sandbox: blocks rawget and rawset" {
    var L = try createSandboxedState(.{});
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    try std.testing.expect(L.doString("return rawget == nil and rawset == nil"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}


test "sandbox: blocks os.exit" {
    var L = try createSandboxedState(.{});
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    try std.testing.expect(L.doString("return os.exit == nil"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}

test "sandbox: blocks os.execute by default" {
    var L = try createSandboxedState(.{});
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    try std.testing.expect(L.doString("return os.execute == nil"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}

test "sandbox: allows os.execute when permitted" {
    var L = try createSandboxedState(.{ .allow_os_execute = true });
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    try std.testing.expect(L.doString("return type(os.execute) == 'function'"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}

test "sandbox: blocks dofile and loadfile" {
    var L = try createSandboxedState(.{});
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    try std.testing.expect(L.doString("return dofile == nil"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);

    try std.testing.expect(L.doString("return loadfile == nil"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}

test "sandbox: _G points to restricted environment" {
    var L = try createSandboxedState(.{});
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    // _G should not have io
    try std.testing.expect(L.doString("return _G.io == nil"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);

    // _G should have type()
    try std.testing.expect(L.doString("return type(_G.type) == 'function'"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}

test "sandbox: instruction limit triggers error" {
    var L = try createSandboxedState(.{ .instruction_limit = 100 });
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    // Infinite loop should hit the instruction limit
    try std.testing.expect(!L.doString("while true do end"));
    const err = L.getErrorMessage();
    try std.testing.expect(err != null);
    try std.testing.expect(std.mem.indexOf(u8, err.?, "instruction limit") != null);
    L.pop(1);
}

test "sandbox: memory limit triggers error" {
    var L = try createSandboxedState(.{ .memory_limit_mb = 1 });
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    // Allocate a large table to exceed 1MB
    try std.testing.expect(!L.doString(
        \\local t = {}
        \\for i = 1, 200000 do
        \\  t[i] = string.rep("x", 100)
        \\end
    ));
    const err = L.getErrorMessage();
    try std.testing.expect(err != null);
    try std.testing.expect(std.mem.indexOf(u8, err.?, "memory limit") != null);
    L.pop(1);
}

// ── T1/T2: per-dispatch budget reset + timeout enforcement ───────────

test "sandbox: instruction budget resets between dispatches (T1)" {
    // Set a low limit so one busy chunk passes but two cumulative would not.
    // The hook fires every 1000 instructions, so a 30k-iteration table loop is
    // ~40 hook ticks — under a limit of 100, but two cumulative would exceed it.
    var L = try createSandboxedState(.{ .instruction_limit = 100 });
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    // First dispatch consumes most of the budget but stays under it.
    // A successful doString with no return values leaves nothing on the stack.
    try std.testing.expect(L.doString("local t = {} for i = 1, 30000 do t[i] = i end"));

    // Without a reset, a second similar chunk would exceed the cumulative
    // budget. With resetInstructionBudget between dispatches, it passes.
    resetInstructionBudget(L.handle);
    try std.testing.expect(L.doString("local t = {} for i = 1, 30000 do t[i] = i end"));
}

test "sandbox: without a reset the cumulative budget is exhausted (T1 pins mechanism)" {
    var L = try createSandboxedState(.{ .instruction_limit = 100 });
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    // Consume most of the budget. A table-accumulating loop can't be optimized
    // away and produces enough instructions to cross the 100-tick limit across
    // two dispatches (the hook fires every 1000 instructions).
    try std.testing.expect(L.doString("local t = {} for i = 1, 30000 do t[i] = i end"));

    // A second chunk with NO reset must hit the instruction limit.
    try std.testing.expect(!L.doString("local t = {} for i = 1, 30000 do t[i] = i end"));
    const err = L.getErrorMessage();
    try std.testing.expect(err != null);
    try std.testing.expect(std.mem.indexOf(u8, err.?, "instruction limit") != null);
    L.pop(1);
}

test "sandbox: timeout_ms is enforced (T2)" {
    // High instruction limit so the timeout (not the count) is what fires.
    var L = try createSandboxedState(.{ .instruction_limit = 1_000_000, .timeout_ms = 1 });
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    // Arm the per-dispatch deadline, mirroring production (callToolHandler /
    // drainEventCallbacks call resetInstructionBudget before each dispatch).
    resetInstructionBudget(L.handle);

    // A tight infinite loop must error with "timeout", not "instruction limit".
    try std.testing.expect(!L.doString("while true do end"));
    const err = L.getErrorMessage();
    try std.testing.expect(err != null);
    try std.testing.expect(std.mem.indexOf(u8, err.?, "timeout") != null);
    L.pop(1);
}

// ── plugin table (P1: plugin.get_config) ─────────────────────────────

test "sandbox: plugin table present with get_config in the restricted env" {
    var L = try createSandboxedState(.{});
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    try std.testing.expect(L.doString("return type(plugin) == 'table' and type(plugin.get_config) == 'function'"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}

test "sandbox: plugin.get_config returns nil without a settings slot" {
    var L = try createSandboxedState(.{});
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    try std.testing.expect(L.doString("return plugin.get_config() == nil"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}

test "sandbox: plugin table visible in full-access states" {
    // Full-access states skip createRestrictedEnvironment entirely; the table
    // must still be reachable (embedded plugins, the Lua test runner).
    var L = try createSandboxedState(.{ .full_access = true });
    defer {
        freeHookData(L.handle);
        L.deinit();
    }

    try std.testing.expect(L.doString("return type(plugin.get_config) == 'function'"));
    try std.testing.expect(L.toBoolean(-1));
    L.pop(1);
}
