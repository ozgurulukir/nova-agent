//! Plugin API bridge — exposes Nova's filesystem to Lua plugins.
//!
//! Each function is a C-callable `lua_CFunction` registered in the `nova`
//! table before the sandbox is created. Plugins call these instead of `io.*`,
//! which is blocked by the sandbox. All file operations go through
//! path validation (traversal guard) and size limits.
//!
//! ## Registered functions
//!
//! - `nova.read_file(path, opts?)` — read file with line range + metadata
//! - `nova.write_file(path, content)` — atomic file write
//! - `nova.edit_file(path, old_string, new_string)` — safe find-and-replace
//! - `nova.search_files(root, pattern, opts?)` — recursive grep
//! - `nova.find_files(root, pattern, opts?)` — recursive filename glob match
//! - `nova.list_dir(path)` — list directory contents
//! - `nova.file_info(path)` — file metadata
//! - `nova.mkdir(path)` — create a directory (recursive)
//! - `nova.copy_path(src, dst)` — copy a file
//! - `nova.move_path(src, dst)` — move/rename a file or directory
//! - `nova.delete_path(path, opts?)` — delete a file or directory
//! - `nova.run_bash(cmd, opts?)` — shell command execution
//! - `nova.get_env(name)` — environment variable reading
//! - `nova.get_cwd()` — current working directory
//! - `nova.get_project_root()` — project root
//! - `nova.register_tool(spec)` — register a tool for the AI model
//! - `nova.on(event, callback)` — subscribe to a lifecycle event

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const os = @import("../os.zig");
const State = @import("state.zig").State;
const bridge = @import("bridge.zig");
const bash_exec = @import("../tools/bash_exec.zig");
const pwsh_exec = @import("../tools/pwsh_exec.zig");
const bash_safety = @import("../tools/bash_safety.zig");
const sandbox_mod = @import("sandbox.zig");

/// Maximum file size for read_file (1 MB).
const max_read_size: usize = 1 * 1024 * 1024;

/// Maximum results for search_files.
const max_search_results: u32 = 200;

/// Language map for file extension → language name.
const lang_map = std.StaticStringMap([]const u8).initComptime(.{
    .{ "lua", "lua" },
    .{ "py", "python" },
    .{ "js", "javascript" },
    .{ "ts", "typescript" },
    .{ "zig", "zig" },
    .{ "c", "c" },
    .{ "cpp", "cpp" },
    .{ "h", "c" },
    .{ "rs", "rust" },
    .{ "go", "go" },
    .{ "java", "java" },
    .{ "rb", "ruby" },
    .{ "php", "php" },
    .{ "sh", "bash" },
    .{ "bash", "bash" },
    .{ "zsh", "bash" },
    .{ "json", "json" },
    .{ "xml", "xml" },
    .{ "yaml", "yaml" },
    .{ "yml", "yaml" },
    .{ "toml", "toml" },
    .{ "md", "markdown" },
    .{ "txt", "text" },
    .{ "log", "log" },
    .{ "conf", "config" },
    .{ "cfg", "config" },
    .{ "ini", "ini" },
});

/// MIME type map.
const mime_map = std.StaticStringMap([]const u8).initComptime(.{
    .{ "lua", "text/x-lua" },
    .{ "py", "text/x-python" },
    .{ "js", "application/javascript" },
    .{ "json", "application/json" },
    .{ "html", "text/html" },
    .{ "css", "text/css" },
    .{ "xml", "application/xml" },
    .{ "md", "text/markdown" },
    .{ "txt", "text/plain" },
    .{ "png", "image/png" },
    .{ "jpg", "image/jpeg" },
    .{ "jpeg", "image/jpeg" },
    .{ "gif", "image/gif" },
    .{ "svg", "image/svg+xml" },
});

/// Retrieve the Io instance stored in the Lua registry.
fn getIo(L: *c.lua_State) std.Io {
    _ = c.lua_getfield(L, c.LUA_REGISTRYINDEX, "nova_io");
    defer c.lua_pop(L, 1);
    const ptr = c.lua_touserdata(L, -1);
    return @as(*const std.Io, @ptrCast(@alignCast(ptr))).*;
}

/// ── nova.require(path) ───────────────────────────────────────────────
///
/// Loads a Lua module relative to the plugin's root directory.
/// Modules are confined to the plugin directory (INV-REQ-1) and cached
/// in `nova_loaded_modules` (INV-REQ-3).
pub fn requireModule(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const mod_path = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("module path argument is required");
        return 2;
    };

    // Get plugin root directory from registry
    _ = c.lua_getfield(L_ptr, c.LUA_REGISTRYINDEX, "nova_plugin_dir");
    const plugin_dir_str = state.toString(-1);
    if (plugin_dir_str == null or plugin_dir_str.?.len == 0) {
        state.pop(1);
        state.pushNil();
        state.pushString("nova.require is only available within loaded plugins");
        return 2;
    }
    const plugin_dir = plugin_dir_str.?;
    const plugin_dir_owned = std.heap.page_allocator.dupe(u8, plugin_dir) catch {
        state.pop(1);
        state.pushNil();
        state.pushString("out of memory");
        return 2;
    };
    defer std.heap.page_allocator.free(plugin_dir_owned);
    state.pop(1);

    // Normalize module path: strip leading "./" or ".\\" if present
    const clean_mod_path = if (std.mem.startsWith(u8, mod_path, "./") or std.mem.startsWith(u8, mod_path, ".\\"))
        mod_path[2..]
    else
        mod_path;

    // Resolve candidates:
    // 1. If clean_mod_path ends with ".lua": try plugin_dir/clean_mod_path
    // 2. Else: try plugin_dir/clean_mod_path.lua, plugin_dir/clean_mod_path/init.lua, plugin_dir/clean_mod_path
    const CandidateType = enum { direct, lua_ext, init_lua };
    const candidates: []const CandidateType = if (std.mem.endsWith(u8, clean_mod_path, ".lua"))
        &.{.direct}
    else
        &.{ .lua_ext, .init_lua, .direct };

    var found_path: ?[]u8 = null;
    defer if (found_path) |p| std.heap.page_allocator.free(p);

    for (candidates) |cand| {
        const cand_rel: []u8 = switch (cand) {
            .direct => std.heap.page_allocator.dupe(u8, clean_mod_path) catch continue,
            .lua_ext => std.fmt.allocPrint(std.heap.page_allocator, "{s}.lua", .{clean_mod_path}) catch continue,
            .init_lua => std.fmt.allocPrint(std.heap.page_allocator, "{s}/init.lua", .{clean_mod_path}) catch continue,
        };
        defer std.heap.page_allocator.free(cand_rel);

        const resolved = std.fs.path.resolve(std.heap.page_allocator, &.{ plugin_dir_owned, cand_rel }) catch continue;
        errdefer std.heap.page_allocator.free(resolved);

        // Confinement check (INV-REQ-1):
        if (!std.mem.startsWith(u8, resolved, plugin_dir_owned) or
            (resolved.len > plugin_dir_owned.len and resolved[plugin_dir_owned.len] != std.fs.path.sep))
        {
            std.heap.page_allocator.free(resolved);
            state.pushNil();
            state.pushString("access denied: cannot require module outside plugin directory");
            return 2;
        }

        // Check if file exists
        if (std.Io.Dir.accessAbsolute(io, resolved, .{})) |_| {
            found_path = resolved;
            break;
        } else |_| {
            std.heap.page_allocator.free(resolved);
        }
    }

    const resolved_path = found_path orelse {
        state.pushNil();
        state.pushString("module not found");
        return 2;
    };

    // Check registry table nova_loaded_modules
    _ = c.lua_getfield(L_ptr, c.LUA_REGISTRYINDEX, "nova_loaded_modules");
    const reg_tbl_idx = c.lua_gettop(L_ptr);

    const resolved_path_z = std.heap.page_allocator.dupeZ(u8, resolved_path) catch {
        c.lua_pop(L_ptr, 1);
        state.pushNil();
        state.pushString("out of memory");
        return 2;
    };
    defer std.heap.page_allocator.free(resolved_path_z);

    _ = c.lua_getfield(L_ptr, reg_tbl_idx, resolved_path_z.ptr);
    if (!c.lua_isnil(L_ptr, -1)) {
        // Module is already loaded/cached. Remove the cache table from under the value.
        c.lua_remove(L_ptr, reg_tbl_idx);
        return 1;
    }
    // Pop the nil
    c.lua_pop(L_ptr, 1);

    // Read module file
    const content = readFileBytes(io, resolved_path, max_read_size) catch |err| {
        c.lua_pop(L_ptr, 1); // pop reg_tbl
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(content);

    // Load chunk
    const load_rc = c.luaL_loadbufferx(L_ptr, content.ptr, content.len, resolved_path_z.ptr, null);
    if (load_rc != c.LUA_OK) {
        c.lua_pop(L_ptr, 1); // pop reg_tbl
        // Error message is on top of stack from loadbuffer
        state.pushNil();
        c.lua_insert(L_ptr, -2); // swap so nil is 1st and err msg is 2nd
        return 2;
    }

    // Mark module as loading (boolean true sentinel to guard circular require)
    c.lua_pushboolean(L_ptr, 1);
    c.lua_setfield(L_ptr, reg_tbl_idx, resolved_path_z.ptr);

    // Execute chunk under pcall(0, 1)
    const run_rc = c.lua_pcallk(L_ptr, 0, 1, 0, 0, null);
    if (run_rc != c.LUA_OK) {
        // Clear cache on failure
        c.lua_pushnil(L_ptr);
        c.lua_setfield(L_ptr, reg_tbl_idx, resolved_path_z.ptr);
        c.lua_remove(L_ptr, reg_tbl_idx); // remove reg table
        // Error message is on top of stack
        state.pushNil();
        c.lua_insert(L_ptr, -2);
        return 2;
    }

    // Successful execution:
    // If the module returned nil, default to boolean true (standard Lua require convention)
    if (state.isNil(-1)) {
        c.lua_pop(L_ptr, 1);
        c.lua_pushboolean(L_ptr, 1);
    }

    // Cache the return value
    c.lua_pushvalue(L_ptr, -1);
    c.lua_setfield(L_ptr, reg_tbl_idx, resolved_path_z.ptr);

    // Remove the cache table, leaving the return value on top
    c.lua_remove(L_ptr, reg_tbl_idx);
    return 1;
}

/// ── nova.read_file(path, opts?) ──────────────────────────────────────
///
/// Reads a file and returns a table with:
///   { content, size, lines, language, mime_type, path }
///
/// Optional `opts` table fields:
///   start_line (number) — first line to return (1-indexed)
///   end_line   (number) — last line to return
///   max_size   (number) — max bytes to read (default 1MB)
///
/// Returns nil + error message on failure.
pub fn readFile(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const path = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("path argument is required");
        return 2;
    };

    const clean_path = sanitizePath(io, path) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_path);

    var start_line: ?u32 = null;
    var end_line: ?u32 = null;
    var max_size: usize = max_read_size;

    if (state.getTop() >= 2 and state.isTable(2)) {
        if (bridge.getTableInteger(&state, 2, "start_line")) |v| start_line = @intCast(@max(v, 1));
        if (bridge.getTableInteger(&state, 2, "end_line")) |v| end_line = @intCast(@max(v, 1));
        // Clamp on the i64 before the usize cast so a negative max_size can't
        // panic (safe builds) or wrap to ~2^64 (ReleaseFast) — same idiom as
        // searchFiles/findFiles/runBash (B2-Zig).
        if (bridge.getTableInteger(&state, 2, "max_size")) |v| max_size = @min(@as(usize, @intCast(@max(v, 0))), max_read_size);
    }

    const content = readFileBytes(io, clean_path, max_size) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(content);

    // Expose truncation so plugins can detect (and page around) the 1 MB cap.
    // full_size is the on-disk size; size is the number of bytes returned.
    const full_size = statFileSize(io, clean_path) catch @as(u64, content.len);

    const final_content = if (start_line != null or end_line != null)
        applyLineRange(content, start_line, end_line)
    else
        content;

    state.newTable();
    state.pushString(clean_path);
    _ = c.lua_setfield(L_ptr, -2, "path");
    state.pushString(final_content);
    _ = c.lua_setfield(L_ptr, -2, "content");
    state.pushInteger(@as(i64, @intCast(final_content.len)));
    _ = c.lua_setfield(L_ptr, -2, "size");
    state.pushInteger(@as(i64, @intCast(countLines(final_content))));
    _ = c.lua_setfield(L_ptr, -2, "lines");
    state.pushBoolean(full_size > final_content.len);
    _ = c.lua_setfield(L_ptr, -2, "truncated");
    state.pushInteger(@as(i64, @intCast(full_size)));
    _ = c.lua_setfield(L_ptr, -2, "full_size");
    state.pushString(detectLanguage(clean_path, content));
    _ = c.lua_setfield(L_ptr, -2, "language");
    state.pushString(getMimeType(clean_path));
    _ = c.lua_setfield(L_ptr, -2, "mime_type");
    return 1;
}

/// ── nova.write_file(path, content) ──────────────────────────────────
///
/// Writes content to a file atomically. Returns true on success.
/// Returns nil + error message on failure.
pub fn writeFile(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const path = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("path argument is required");
        return 2;
    };
    const content = bridge.pullValue(&state, []const u8, 2) orelse {
        state.pushNil();
        state.pushString("content argument is required");
        return 2;
    };

    const clean_path = sanitizePath(io, path) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_path);

    writeFileAtomic(io, clean_path, content) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };

    state.pushBoolean(true);
    return 1;
}

/// ── nova.edit_file(path, old_string, new_string) ─────────────────────
///
/// Replaces first occurrence of old_string with new_string in a file.
/// Returns true on success, or nil + error on failure.
pub fn editFile(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const path = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("path argument is required");
        return 2;
    };
    const old_string = bridge.pullValue(&state, []const u8, 2) orelse {
        state.pushNil();
        state.pushString("old_string argument is required");
        return 2;
    };
    const new_string = bridge.pullValue(&state, []const u8, 3) orelse {
        state.pushNil();
        state.pushString("new_string argument is required");
        return 2;
    };

    const clean_path = sanitizePath(io, path) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_path);

    editFileSplice(io, clean_path, old_string, new_string) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };

    state.pushBoolean(true);
    return 1;
}

/// Core of `nova.edit_file`: stat the file, refuse anything over the read cap
/// (a partial read would be written back and destroy data), then splice the
/// replacement and write atomically. Extracted so it is unit-testable without
/// a Lua state.
const EditFileError = error{ FileTooLarge, OldStringNotFound, OutOfMemory, WriteFailed };
fn editFileSplice(io: std.Io, clean_path: []const u8, old_string: []const u8, new_string: []const u8) EditFileError!void {
    // Refuse to edit files over the read cap. readFileBytes silently head-
    // truncates, so splicing a replacement into a partial read and writing it
    // back would destroy every byte past 1 MB. Never write back a partial read.
    const full_size = statFileSize(io, clean_path) catch return error.WriteFailed;
    if (full_size > max_read_size) return error.FileTooLarge;

    const content = readFileBytes(io, clean_path, max_read_size) catch return error.WriteFailed;
    defer std.heap.page_allocator.free(content);

    const index = std.mem.indexOf(u8, content, old_string) orelse return error.OldStringNotFound;

    const new_content = std.mem.concat(std.heap.page_allocator, u8, &.{
        content[0..index],
        new_string,
        content[index + old_string.len ..],
    }) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(new_content);

    writeFileAtomic(io, clean_path, new_content) catch return error.WriteFailed;
}

/// ── nova.search_files(root, pattern, opts?) ──────────────────────────
///
/// Recursively searches files matching pattern. Returns a table with:
///   { query, total_matches, results: [{file, line, content, match}], truncated }
///
/// Optional opts:
///   file_pattern  (string) — glob filter (e.g. "*.lua")
///   case_sensitive (bool)  — default false
///   max_results   (number) — default 50, max 200
pub fn searchFiles(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const root = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("root path argument is required");
        return 2;
    };
    const pattern = bridge.pullValue(&state, []const u8, 2) orelse {
        state.pushNil();
        state.pushString("pattern argument is required");
        return 2;
    };

    var file_pattern: ?[]const u8 = null;
    var case_sensitive = false;
    var max_results: u32 = 50;

    if (state.getTop() >= 3 and state.isTable(3)) {
        if (bridge.getTableString(&state, 3, "file_pattern")) |v| file_pattern = v;
        if (bridge.getTableBoolean(&state, 3, "case_sensitive")) |v| case_sensitive = v;
        if (bridge.getTableInteger(&state, 3, "max_results")) |v| max_results = @min(@as(u32, @intCast(@max(v, 1))), max_search_results);
    }

    const clean_root = sanitizePath(io, root) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_root);

    state.newTable();
    state.pushString(pattern);
    _ = c.lua_setfield(L_ptr, -2, "query");

    state.newTable();
    var total: u32 = 0;
    var result_count: u32 = 0;

    walkAndSearch(io, clean_root, file_pattern, pattern, case_sensitive, max_results, &total, &result_count, L_ptr) catch |err| {
        _ = c.lua_setfield(L_ptr, -2, "results");
        state.pushString(@errorName(err));
        _ = c.lua_setfield(L_ptr, -2, "error");
        state.pushInteger(@as(i64, @intCast(total)));
        _ = c.lua_setfield(L_ptr, -2, "total_matches");
        return 1;
    };

    _ = c.lua_setfield(L_ptr, -2, "results");
    state.pushInteger(@as(i64, @intCast(total)));
    _ = c.lua_setfield(L_ptr, -2, "total_matches");
    state.pushBoolean(result_count < total);
    _ = c.lua_setfield(L_ptr, -2, "truncated");
    return 1;
}

/// ── nova.list_dir(path) ─────────────────────────────────────────────
///
/// Lists directory contents. Returns a table with:
///   { path, files: [{name}], directories: [{name}], total_items }
pub fn listDir(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const path = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("path argument is required");
        return 2;
    };

    const clean_path = sanitizePath(io, path) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_path);

    var dir = std.Io.Dir.openDirAbsolute(io, clean_path, .{ .iterate = true }) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer dir.close(io);

    state.newTable();
    state.pushString(clean_path);
    _ = c.lua_setfield(L_ptr, -2, "path");

    state.newTable();
    const files_table = c.lua_gettop(L_ptr);
    state.newTable();
    const dirs_table = c.lua_gettop(L_ptr);
    var file_count: u32 = 0;
    var dir_count: u32 = 0;

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        switch (entry.kind) {
            .file => {
                file_count += 1;
                state.pushString(entry.name);
                _ = c.lua_rawseti(L_ptr, files_table, @as(c_int, @intCast(file_count)));
            },
            .directory => {
                dir_count += 1;
                state.pushString(entry.name);
                _ = c.lua_rawseti(L_ptr, dirs_table, @as(c_int, @intCast(dir_count)));
            },
            else => {},
        }
    }

    _ = c.lua_setfield(L_ptr, -3, "directories");
    _ = c.lua_setfield(L_ptr, -2, "files");
    state.pushInteger(@as(i64, @intCast(file_count + dir_count)));
    _ = c.lua_setfield(L_ptr, -2, "total_items");
    return 1;
}

/// ── nova.find_files(root, pattern, opts?) ───────────────────────────
///
/// Recursively walk `root` and return every file whose **path relative to
/// root** matches a glob `pattern`. The match covers the path relative to
/// `root`, so `**/*.zig` matches every `.zig` file at any depth and
/// `src/**/*.ts` only matches under `src/`.
///
/// Optional `opts` table fields:
///   max_results (number) — cap on returned paths (default 100, hard cap 200)
///
/// Returns a table: `{ root, total_matches, truncated, results: [{path, name}] }`.
/// `truncated` is true when more files matched than were returned. Directory
/// walk skips dotfile entries (names beginning with `.`). gitignore is NOT
/// honored (documented gap — use `run_bash` with `rg --files` if needed).
pub fn findFiles(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const root = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("root path argument is required");
        return 2;
    };
    const pattern = bridge.pullValue(&state, []const u8, 2) orelse {
        state.pushNil();
        state.pushString("pattern argument is required");
        return 2;
    };

    var max_results: u32 = 100;
    if (state.getTop() >= 3 and state.isTable(3)) {
        if (bridge.getTableInteger(&state, 3, "max_results")) |v| {
            max_results = @min(@as(u32, @intCast(@max(v, 1))), max_search_results);
        }
    }

    const clean_root = sanitizePath(io, root) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_root);

    state.newTable();
    state.pushString(clean_root);
    _ = c.lua_setfield(L_ptr, -2, "root");

    state.newTable();
    var ctx = FindCtx{ .total = 0, .result_count = 0, .max_results = max_results, .root_len = clean_root.len, .L = L_ptr };
    walkAndMatch(io, clean_root, pattern, &ctx) catch |err| {
        _ = c.lua_setfield(L_ptr, -2, "results");
        state.pushString(@errorName(err));
        _ = c.lua_setfield(L_ptr, -2, "error");
        state.pushInteger(@as(i64, @intCast(ctx.total)));
        _ = c.lua_setfield(L_ptr, -2, "total_matches");
        return 1;
    };

    _ = c.lua_setfield(L_ptr, -2, "results");
    state.pushInteger(@as(i64, @intCast(ctx.total)));
    _ = c.lua_setfield(L_ptr, -2, "total_matches");
    state.pushBoolean(ctx.result_count < ctx.total);
    _ = c.lua_setfield(L_ptr, -2, "truncated");
    return 1;
}

/// Accumulator threaded through `walkAndMatch`.
const FindCtx = struct {
    total: u32,
    result_count: u32,
    max_results: u32,
    /// Length of the cleaned root path, used to derive the relative path
    /// (the portion of `full_path` after `root + sep`) for glob matching.
    root_len: usize,
    L: ?*c.lua_State,
};

/// Walk a directory recursively, matching each file's relative path against
/// `pattern`. Mirrors `walkAndSearch`'s structure but matches filenames
/// instead of file contents, and never opens the file body.
fn walkAndMatch(io: std.Io, dir_path: []const u8, pattern: []const u8, ctx: *FindCtx) !void {
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.name.len == 0) continue;
        if (entry.name[0] == '.') continue;

        const full_path = try std.fs.path.join(std.heap.page_allocator, &.{ dir_path, entry.name });
        defer std.heap.page_allocator.free(full_path);

        switch (entry.kind) {
            .directory => try walkAndMatch(io, full_path, pattern, ctx),
            .file => {
                // Relative path = full_path with the root prefix stripped.
                const rel_offset = if (full_path.len > ctx.root_len) ctx.root_len + 1 else full_path.len;
                const rel_path = if (rel_offset <= full_path.len) full_path[rel_offset..] else entry.name;
                if (!matchGlob(rel_path, pattern) and !matchGlob(entry.name, pattern)) continue;

                ctx.total += 1;
                if (ctx.result_count < ctx.max_results) {
                    ctx.result_count += 1;
                    var st = State{ .handle = ctx.L orelse return };
                    // [ ... | results_table ]
                    st.newTable();
                    st.pushString(full_path);
                    _ = c.lua_setfield(ctx.L.?, -2, "path");
                    st.pushString(entry.name);
                    _ = c.lua_setfield(ctx.L.?, -2, "name");
                    _ = c.lua_rawseti(ctx.L.?, -2, @as(c_int, @intCast(ctx.result_count)));
                }
            },
            else => {},
        }
    }
}

/// Glob match `name` (a relative path or a bare filename) against `pattern`.
///
/// Supports the wildcards coding-agent models commonly emit:
///   `**` — match any number of path segments (incl. across separators)
///   `*`  — match any run of characters within a single path segment
///   `?`  — match exactly one character
///   literal text — match verbatim
/// An empty pattern matches everything. Matching is case-sensitive (paths are
/// case-sensitive on Linux); the `*` and `?` semantics deliberately do not
/// cross `/` so `src/*.ts` does not match `src/nested/a.ts`.
pub fn matchGlob(name: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return true;
    return globMatchSegment(name, pattern);
}

fn isPathSep(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

fn appendSegments(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), path: []const u8) !void {
    var start: usize = 0;
    for (path, 0..) |b, i| {
        if (isPathSep(b)) {
            if (i > start) try list.append(allocator, path[start..i]);
            start = i + 1;
        }
    }
    if (start < path.len) {
        try list.append(allocator, path[start..]);
    }
}

/// Recursive segment-aware glob matcher. `*` and `?` stop at `/` or `\`; only `**`
/// spans separators. Implemented iteratively over pattern segments to keep the
/// recursion bounded by pattern length (not input length).
fn globMatchSegment(name: []const u8, pattern: []const u8) bool {
    // Split the pattern and name into `/` and `\`-delimited segments and match segment
    // by segment. A `**` segment consumes zero or more name segments.
    var n_segs: std.ArrayList([]const u8) = .empty;
    defer n_segs.deinit(std.heap.page_allocator);
    var p_segs: std.ArrayList([]const u8) = .empty;
    defer p_segs.deinit(std.heap.page_allocator);

    appendSegments(std.heap.page_allocator, &n_segs, name) catch return false;
    appendSegments(std.heap.page_allocator, &p_segs, pattern) catch return false;

    return globMatchSegs(n_segs.items, p_segs.items);
}

fn globMatchSegs(name_segs: []const []const u8, pat_segs: []const []const u8) bool {
    var ni: usize = 0;
    var pi: usize = 0;
    var star_pi: ?usize = null;
    var star_ni: usize = 0;

    while (ni < name_segs.len) {
        if (pi < pat_segs.len and std.mem.eql(u8, pat_segs[pi], "**")) {
            // `**` matches zero or more segments; record backtrack point.
            star_pi = pi;
            star_ni = ni;
            pi += 1;
        }
        if (pi < pat_segs.len and segMatch(name_segs[ni], pat_segs[pi])) {
            ni += 1;
            pi += 1;
        } else if (star_pi) |spi| {
            // Backtrack: let `**` consume one more segment.
            pi = spi + 1;
            star_ni += 1;
            ni = star_ni;
        } else {
            return false;
        }
    }
    // Trailing `**` segments match the (now-empty) remainder.
    while (pi < pat_segs.len and std.mem.eql(u8, pat_segs[pi], "**")) pi += 1;
    return pi == pat_segs.len;
}

/// Match a single path segment (no `/`) against a single pattern segment
/// supporting `*` (zero+ chars) and `?` (one char).
fn segMatch(seg: []const u8, pat: []const u8) bool {
    if (std.mem.eql(u8, pat, "*")) return true;
    if (std.mem.eql(u8, pat, "**")) return true;
    var si: usize = 0;
    var pi: usize = 0;
    var star_pi: ?usize = null;
    var star_si: usize = 0;
    while (si < seg.len) {
        if (pi < pat.len and pat[pi] == '*') {
            star_pi = pi;
            star_si = si;
            pi += 1;
        } else if (pi < pat.len and (pat[pi] == '?' or pat[pi] == seg[si])) {
            si += 1;
            pi += 1;
        } else if (star_pi) |spi| {
            pi = spi + 1;
            star_si += 1;
            si = star_si;
        } else {
            return false;
        }
    }
    while (pi < pat.len and pat[pi] == '*') pi += 1;
    return pi == pat.len;
}

/// ── nova.mkdir(path) ─────────────────────────────────────────────────
///
/// Create a directory, including parents (recursive). Returns `true` or
/// `nil, err`. The path is sanitized — traversal outside the project root is
/// rejected. Prefer this over `run_bash("mkdir ...")` so the path stays
/// sandboxed.
pub fn mkdir(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const path = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("path argument is required");
        return 2;
    };

    const clean_path = sanitizePath(io, path) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_path);

    std.Io.Dir.createDirPath(.cwd(), io, clean_path) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    state.pushBoolean(true);
    return 1;
}

/// ── nova.copy_path(src, dst) ─────────────────────────────────────────
///
/// Copy a file from `src` to `dst`. Both paths are sanitized. Returns `true`
/// or `nil, err`. Directories are not supported (use `run_bash` for tree
/// copies); this keeps the operation simple and predictable.
pub fn copyPath(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const src = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("source path argument is required");
        return 2;
    };
    const dst = bridge.pullValue(&state, []const u8, 2) orelse {
        state.pushNil();
        state.pushString("destination path argument is required");
        return 2;
    };

    const clean_src = sanitizePath(io, src) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_src);
    const clean_dst = sanitizePath(io, dst) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_dst);

    std.Io.Dir.copyFileAbsolute(clean_src, clean_dst, io, .{}) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    state.pushBoolean(true);
    return 1;
}

/// ── nova.move_path(src, dst) ─────────────────────────────────────────
///
/// Move (rename) a file or directory from `src` to `dst`. Both paths are
/// sanitized; works across directory boundaries on the same filesystem.
/// Returns `true` or `nil, err`.
pub fn movePath(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const src = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("source path argument is required");
        return 2;
    };
    const dst = bridge.pullValue(&state, []const u8, 2) orelse {
        state.pushNil();
        state.pushString("destination path argument is required");
        return 2;
    };

    const clean_src = sanitizePath(io, src) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_src);
    const clean_dst = sanitizePath(io, dst) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_dst);

    std.Io.Dir.renameAbsolute(clean_src, clean_dst, io) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    state.pushBoolean(true);
    return 1;
}

/// ── nova.delete_path(path, opts?) ───────────────────────────────────
///
/// Delete a file or directory. Optional `opts.recursive` (boolean, default
/// `false`) controls whether a non-empty directory is removed with its
/// contents. The path is sanitized — traversal outside the project root is
/// rejected, and `recursive` defaults off so a plugin must explicitly opt in
/// to tree deletion. Prefer this over `run_bash("rm -rf ...")` which runs
/// unclassified and unguarded in the plugin sandbox.
pub fn deletePath(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const path = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("path argument is required");
        return 2;
    };
    var recursive = false;
    if (state.getTop() >= 2 and state.isTable(2)) {
        if (bridge.getTableBoolean(&state, 2, "recursive")) |v| recursive = v;
    }

    const clean_path = sanitizePath(io, path) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_path);

    // Prevent deleting the workspace root itself
    var cwd_buf: ?[]u8 = null;
    defer if (cwd_buf) |b| std.heap.page_allocator.free(b);
    const cwd: []const u8 = if (bridge.plugin_cwd_slot) |s| s else blk: {
        cwd_buf = std.process.currentPathAlloc(io, std.heap.page_allocator) catch null;
        break :blk if (cwd_buf) |b| b else "";
    };
    if (cwd.len > 0 and std.mem.eql(u8, clean_path, cwd)) {
        state.pushNil();
        state.pushString("cannot delete project root directory");
        return 2;
    }

    // Stat to decide file vs directory, then call the matching deleter.
    // Try opening as directory first. If it succeeds, it's a directory; if not, treat as file.
    var is_dir = false;
    if (std.Io.Dir.openDirAbsolute(io, clean_path, .{})) |*dir| {
        dir.close(io);
        is_dir = true;
    } else |_| {}

    if (is_dir) {
        if (recursive) {
            // No static `deleteTreeAbsolute`; open the parent and delete the
            // leaf by basename so the whole tree is removed in one call.
            const parent = std.fs.path.dirname(clean_path) orelse {
                state.pushNil();
                state.pushString("cannot determine parent directory");
                return 2;
            };
            const base = std.fs.path.basename(clean_path);
            var parent_dir = std.Io.Dir.openDirAbsolute(io, parent, .{}) catch |err| {
                state.pushNil();
                state.pushString(@errorName(err));
                return 2;
            };
            defer parent_dir.close(io);
            parent_dir.deleteTree(io, base) catch |err| {
                state.pushNil();
                state.pushString(@errorName(err));
                return 2;
            };
        } else {
            std.Io.Dir.deleteDirAbsolute(io, clean_path) catch |err| {
                state.pushNil();
                state.pushString(@errorName(err));
                return 2;
            };
        }
    } else {
        std.Io.Dir.deleteFileAbsolute(io, clean_path) catch |err| {
            state.pushNil();
            state.pushString(@errorName(err));
            return 2;
        };
    }
    state.pushBoolean(true);
    return 1;
}

/// ── nova.file_info(path) ─────────────────────────────────────────────
///
/// Returns file metadata: { size, type, extension, language, mime_type }
/// Returns nil + error on failure.
pub fn fileInfo(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const path = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("path argument is required");
        return 2;
    };

    const clean_path = sanitizePath(io, path) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer std.heap.page_allocator.free(clean_path);

    var file = std.Io.Dir.openFileAbsolute(io, clean_path, .{}) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer file.close(io);

    const stat = file.stat(io) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };

    state.newTable();
    state.pushInteger(@as(i64, @intCast(stat.size)));
    _ = c.lua_setfield(L_ptr, -2, "size");

    const kind_str = switch (stat.kind) {
        .file => "file",
        .directory => "directory",
        else => "other",
    };
    state.pushString(kind_str);
    _ = c.lua_setfield(L_ptr, -2, "type");

    state.pushString(getExtension(clean_path));
    _ = c.lua_setfield(L_ptr, -2, "extension");

    state.pushString(detectLanguage(clean_path, ""));
    _ = c.lua_setfield(L_ptr, -2, "language");

    state.pushString(getMimeType(clean_path));
    _ = c.lua_setfield(L_ptr, -2, "mime_type");
    return 1;
}

/// Best-effort plugin directory for the shell-block audit log; empty when the
/// Lua state carries no plugin (bridge unit tests). Borrowed from the Lua GC —
/// consumed synchronously by the log call before returning.
fn pluginDirBestEffort(L: *c.lua_State) []const u8 {
    _ = c.lua_getfield(L, c.LUA_REGISTRYINDEX, "nova_plugin_dir");
    if (c.lua_isnil(L, -1)) {
        c.lua_pop(L, 1);
        return "";
    }
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, -1, &len);
    const dir = if (ptr) |p| p[0..len] else "";
    c.lua_pop(L, 1);
    return dir;
}

/// The exec backend a plugin shell call routes to: `run_bash` always uses
/// bash (git-bash on Windows); `run_shell` uses the native shell (pwsh on
/// Windows, bash on POSIX).
const ShellBackend = enum { bash, pwsh };

/// Map a backend spawn failure to an actionable Lua-facing message. Only
/// `error.FileNotFound` (the backend binary is missing) is remapped — every
/// other error name (Timeout, StreamTooLong, …) is already meaningful to
/// plugin authors.
fn shellBackendErrorMessage(err: anyerror, backend: ShellBackend) []const u8 {
    if (err == error.FileNotFound) {
        return switch (backend) {
            .bash => "ShellUnavailable: bash not found (install Git Bash on Windows, or ensure bash is on PATH); consider nova.run_shell",
            .pwsh => "ShellUnavailable: pwsh not found (install PowerShell 7, or ensure powershell.exe is on PATH)",
        };
    }
    return @errorName(err);
}

/// Quote one argument for a shell command line. `pwsh_rules` selects the
/// PowerShell single-quote rule (`'` doubled) over the POSIX rule (`'\''`);
/// both wrap the argument in single quotes so no expansion can occur.
/// Exact-size allocation with a final length assert: the size is computed
/// upfront, so a mismatch means an arithmetic bug, not a runtime condition.
fn quoteShellArg(gpa: std.mem.Allocator, s: []const u8, pwsh_rules: bool) std.mem.Allocator.Error![]u8 {
    var quotes: usize = 0;
    for (s) |ch| {
        if (ch == '\'') quotes += 1;
    }
    const extra: usize = if (pwsh_rules) quotes else quotes * 3; // `''` vs `'\''`
    const out = try gpa.alloc(u8, s.len + 2 + extra);
    var i: usize = 0;
    out[i] = '\'';
    i += 1;
    for (s) |ch| {
        out[i] = ch;
        i += 1;
        if (ch == '\'') {
            if (pwsh_rules) {
                out[i] = '\'';
                i += 1;
            } else {
                out[i] = '\\';
                out[i + 1] = '\'';
                out[i + 2] = '\'';
                i += 3;
            }
        }
    }
    out[i] = '\'';
    i += 1;
    std.debug.assert(i == out.len);
    return out;
}

/// ── nova.shell_quote(s, dialect?) ────────────────────────────────────
///
/// Quote one argument for a shell command line. Dialects:
///   "posix"  (default) — for run_bash on every platform (git-bash on
///             Windows is a POSIX shell): wrap in '...' escaping ' as '\''.
///   "native" — for run_shell's interpreter: identical to posix on POSIX;
///             on Windows PowerShell escapes ' as ''.
/// Returns the quoted string, or nil + an error for an unknown dialect.
/// Quoting is what keeps the *intended* command equal to the *classified*
/// command (the safety gate classifies the final string) — always quote
/// interpolated values instead of concatenating raw strings.
pub fn shellQuote(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };

    const s = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("string argument is required");
        return 2;
    };

    var pwsh_rules = false;
    if (state.getTop() >= 2 and !state.isNil(2)) {
        const dialect = bridge.pullValue(&state, []const u8, 2) orelse {
            state.pushNil();
            state.pushString("shell_quote: dialect must be \"posix\" or \"native\"");
            return 2;
        };
        if (std.mem.eql(u8, dialect, "posix")) {
            // POSIX quoting is the default.
        } else if (std.mem.eql(u8, dialect, "native")) {
            pwsh_rules = os.is_windows;
        } else {
            state.pushNil();
            state.pushString("shell_quote: dialect must be \"posix\" or \"native\"");
            return 2;
        }
    }

    const gpa = std.heap.page_allocator;
    const quoted = quoteShellArg(gpa, s, pwsh_rules) catch {
        state.pushNil();
        state.pushString("out of memory");
        return 2;
    };
    defer gpa.free(quoted);
    state.pushString(quoted); // copies into the Lua GC
    return 1;
}

/// ── nova.run_bash(cmd, opts?) ────────────────────────────────────────
///
/// Runs a shell command and returns a table with:
///   { stdout, stderr, code }
///
/// Optional `opts` table fields:
///   cwd     (string) — working directory (default: project root)
///   timeout (number) — timeout in seconds (default: 30)
///   stdin   (string) — bytes written to the child's stdin, then closed
///
/// Returns nil + error message on failure.
fn runShellWithBackend(L: ?*c.lua_State, backend: ShellBackend) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const cmd = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("command argument is required");
        return 2;
    };

    // Empty commands are rejected before anything else: `bash_safety.classify`
    // and both exec backends assert `command.len > 0`, and asserts are UB in
    // ReleaseFast — the guard must fire before either can see the empty slice.
    if (cmd.len == 0) {
        state.pushNil();
        state.pushString("command argument must not be empty");
        return 2;
    }

    var cwd: ?[]const u8 = null;
    var timeout_seconds: u32 = bash_exec.timeout_seconds_default;
    // Borrowed from the Lua GC (the opts table at index 2 pins the string for
    // the whole C call); safe without a copy because both exec backends join
    // their stdin writer thread before returning — the bytes are consumed
    // before the Lua stack can unwind.
    var stdin_bytes: ?[]const u8 = null;

    if (state.getTop() >= 2 and state.isTable(2)) {
        if (bridge.getTableString(&state, 2, "cwd")) |v| cwd = v;
        if (bridge.getTableString(&state, 2, "stdin")) |v| stdin_bytes = v;
        if (bridge.getTableInteger(&state, 2, "timeout")) |v| timeout_seconds = @min(@max(@as(u32, @intCast(@max(v, 1))), 1), bash_exec.timeout_seconds_max);
    }

    const resolved_cwd = if (cwd) |path| blk: {
        break :blk sanitizePath(io, path) catch {
            state.pushNil();
            state.pushString("invalid cwd path");
            return 2;
        };
    } else blk: {
        if (bridge.plugin_cwd_slot) |slot_cwd| {
            break :blk std.heap.page_allocator.dupe(u8, slot_cwd) catch {
                state.pushNil();
                state.pushString("out of memory");
                return 2;
            };
        }
        break :blk std.process.currentPathAlloc(io, std.heap.page_allocator) catch {
            state.pushNil();
            state.pushString("could not resolve cwd");
            return 2;
        };
    };
    defer std.heap.page_allocator.free(resolved_cwd);

    // P5: gate plugin shell execution through the same classifier as the
    // builtin tool. Hard-block on `.unsafe` — there is no interactive
    // approval at the Lua C boundary (no observer handle, worker thread), so
    // the channel for destructive work remains the model-facing builtin bash
    // tool with its full approval flow. `.safe`/`.unavailable` pass through,
    // exact parity with the builtin gate (executor_safety).
    const verdict = bash_safety.classify(std.heap.page_allocator, io, bridge.bash_classifier_url_slot, resolved_cwd, cmd);
    if (verdict == .unsafe) {
        const backend_name = if (backend == .pwsh) "pwsh" else "bash";
        std.log.warn("plugin.shell.blocked plugin_dir={s} backend={s} cmd=\"{s}\"", .{
            pluginDirBestEffort(L_ptr),
            backend_name,
            cmd[0..@min(cmd.len, 80)],
        });
        state.pushNil();
        state.pushString("UnsafeShellBlocked: command rejected by Nova's shell safety classifier; use the built-in bash tool for destructive commands");
        return 2;
    }

    if (backend == .pwsh) {
        var result = pwsh_exec.runWithOptions(std.heap.page_allocator, io, .{
            .cwd = resolved_cwd,
            .command = cmd,
            .stdin = stdin_bytes,
            .timeout = pwsh_exec.timeoutFromSeconds(timeout_seconds),
        }) catch |err| {
            state.pushNil();
            state.pushString(shellBackendErrorMessage(err, backend));
            return 2;
        };
        defer result.deinit(std.heap.page_allocator);

        state.newTable();
        state.pushString(result.stdout);
        _ = c.lua_setfield(L_ptr, -2, "stdout");
        state.pushString(result.stderr);
        _ = c.lua_setfield(L_ptr, -2, "stderr");
        state.pushInteger(@as(i64, @intCast(result.code)));
        _ = c.lua_setfield(L_ptr, -2, "code");
        return 1;
    } else {
        var result = bash_exec.runWithOptions(std.heap.page_allocator, io, .{
            .cwd = resolved_cwd,
            .command = cmd,
            .stdin = stdin_bytes,
            .timeout = bash_exec.timeoutFromSeconds(timeout_seconds),
        }) catch |err| {
            state.pushNil();
            state.pushString(shellBackendErrorMessage(err, backend));
            return 2;
        };
        defer result.deinit(std.heap.page_allocator);

        state.newTable();
        state.pushString(result.stdout);
        _ = c.lua_setfield(L_ptr, -2, "stdout");
        state.pushString(result.stderr);
        _ = c.lua_setfield(L_ptr, -2, "stderr");
        state.pushInteger(@as(i64, @intCast(result.code)));
        _ = c.lua_setfield(L_ptr, -2, "code");
        return 1;
    }
}

/// ── nova.run_bash(cmd, opts?) ────────────────────────────────────────
///
/// Runs a bash command and returns a table with:
///   { stdout, stderr, code }
///
/// Optional `opts` table fields:
///   cwd     (string) — working directory (default: project root)
///   timeout (number) — timeout in seconds (default: 30)
///   stdin   (string) — bytes written to the child's stdin, then closed
///
/// Returns nil + error message on failure.
pub fn runBash(L: ?*c.lua_State) callconv(.c) c_int {
    return runShellWithBackend(L, .bash);
}

/// ── nova.run_shell(cmd, opts?) ───────────────────────────────────────
///
/// Runs a shell command using the host platform's native shell:
/// PowerShell (`pwsh.exe`) on Windows, bash on POSIX. Accepts the same
/// `opts` as run_bash (cwd / timeout / stdin).
/// Returns a table with:
///   { stdout, stderr, code }
pub fn runShell(L: ?*c.lua_State) callconv(.c) c_int {
    return runShellWithBackend(L, if (os.is_windows) .pwsh else .bash);
}

/// ── nova.get_env(name) ───────────────────────────────────────────────
///
/// Returns the value of an environment variable, or nil if not set.
pub fn getEnv(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };

    const name = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("name argument is required");
        return 2;
    };

    // Ensure null-terminated for C API
    const name_buf = std.heap.page_allocator.alloc(u8, name.len + 1) catch {
        state.pushNil();
        state.pushString("out of memory");
        return 2;
    };
    defer std.heap.page_allocator.free(name_buf);
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;

    const value_ptr = std.c.getenv(name_buf[0..name.len :0]) orelse {
        state.pushNil();
        return 1;
    };

    const value = std.mem.sliceTo(value_ptr, 0);
    state.pushString(value);
    return 1;
}

/// ── nova.get_cwd() ──────────────────────────────────────────────────
///
/// Returns the current working directory as a string.
pub fn getCwd(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const cwd = std.process.currentPathAlloc(io, std.heap.page_allocator) catch {
        state.pushNil();
        state.pushString("could not resolve cwd");
        return 2;
    };
    defer std.heap.page_allocator.free(cwd);

    state.pushString(cwd);
    return 1;
}

/// ── nova.get_project_root() ─────────────────────────────────────────
///
/// Returns the project root directory (git repo root, or cwd if not a repo).
pub fn getProjectRoot(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const cwd = std.process.currentPathAlloc(io, std.heap.page_allocator) catch {
        state.pushNil();
        state.pushString("could not resolve cwd");
        return 2;
    };
    defer std.heap.page_allocator.free(cwd);

    const root = findGitRoot(io, cwd) catch cwd;
    defer if (root.ptr != cwd.ptr) std.heap.page_allocator.free(root);

    state.pushString(root);
    return 1;
}

/// ── nova.git_status() ───────────────────────────────────────────────
///
/// Returns git status as a string (porcelain format).
pub fn gitStatus(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const cwd = std.process.currentPathAlloc(io, std.heap.page_allocator) catch {
        state.pushNil();
        state.pushString("could not resolve cwd");
        return 2;
    };
    defer std.heap.page_allocator.free(cwd);

    var result = bash_exec.run(std.heap.page_allocator, io, cwd, "git status --porcelain") catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer result.deinit(std.heap.page_allocator);

    if (result.code != 0) {
        state.pushNil();
        state.pushString(gitErrorString(result.stderr, result.code));
        return 2;
    }

    state.pushString(result.stdout);
    return 1;
}

/// Build a plugin-facing error string for a failed git command. Prefers the
/// trimmed stderr (git's own message, e.g. "fatal: not a git repository"),
/// falling back to a generic exit-code message. Returns a slice valid for the
/// duration of the caller's `result` (no allocation).
fn gitErrorString(stderr: []const u8, code: u32) []const u8 {
    const trimmed = std.mem.trim(u8, stderr, " \n\r\t");
    if (trimmed.len > 0) return trimmed;
    return std.fmt.bufPrint(&git_err_buf, "git exited with code {d}", .{code}) catch "git failed";
}

var git_err_buf: [64]u8 = undefined;

/// ── nova.git_diff(path?) ─────────────────────────────────────────────
///
/// Returns git diff as a string. Optional path limits diff to a file.
pub fn gitDiff(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const path = bridge.pullValue(&state, []const u8, 1);
    const cwd = std.process.currentPathAlloc(io, std.heap.page_allocator) catch {
        state.pushNil();
        state.pushString("could not resolve cwd");
        return 2;
    };
    defer std.heap.page_allocator.free(cwd);

    // Build `git diff [-- <escaped-path>]`. The path is single-quote-escaped so
    // a malicious `path = "x; rm -rf ~"` cannot break out of the argument —
    // it becomes a literal argument to `git diff`, not shell syntax. Quotes
    // inside the path are neutralized by the `'` → `'\''` transform.
    var cmd: []u8 = undefined;
    if (path) |p| {
        const quoted = quoteShellArg(std.heap.page_allocator, p, false) catch {
            state.pushNil();
            state.pushString("out of memory");
            return 2;
        };
        defer std.heap.page_allocator.free(quoted);
        cmd = std.fmt.allocPrint(std.heap.page_allocator, "git diff -- {s}", .{quoted}) catch {
            state.pushNil();
            state.pushString("out of memory");
            return 2;
        };
    } else {
        cmd = std.heap.page_allocator.dupe(u8, "git diff") catch {
            state.pushNil();
            state.pushString("out of memory");
            return 2;
        };
    }
    defer std.heap.page_allocator.free(cmd);

    var result = bash_exec.runWithOptions(std.heap.page_allocator, io, .{ .cwd = cwd, .command = cmd }) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer result.deinit(std.heap.page_allocator);

    if (result.code != 0) {
        state.pushNil();
        state.pushString(gitErrorString(result.stderr, result.code));
        return 2;
    }

    state.pushString(result.stdout);
    return 1;
}

/// ── nova.git_log(n) ─────────────────────────────────────────────────
///
/// Returns recent git log entries as a string. n = number of commits (default 10).
pub fn gitLog(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    var n: u32 = 10;
    if (bridge.pullValue(&state, i64, 1)) |v| n = @intCast(@max(v, 1));

    const cwd = std.process.currentPathAlloc(io, std.heap.page_allocator) catch {
        state.pushNil();
        state.pushString("could not resolve cwd");
        return 2;
    };
    defer std.heap.page_allocator.free(cwd);

    const cmd = std.fmt.allocPrint(std.heap.page_allocator, "git log --oneline -{d}", .{n}) catch {
        state.pushNil();
        state.pushString("out of memory");
        return 2;
    };
    defer std.heap.page_allocator.free(cmd);

    // `n` is a clamped integer, so it carries no injection risk; routing through
    // runWithOptions keeps the command on the classified path regardless.
    var result = bash_exec.runWithOptions(std.heap.page_allocator, io, .{ .cwd = cwd, .command = cmd }) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer result.deinit(std.heap.page_allocator);

    if (result.code != 0) {
        state.pushNil();
        state.pushString(gitErrorString(result.stderr, result.code));
        return 2;
    }

    state.pushString(result.stdout);
    return 1;
}

/// ── nova.git_branch() ───────────────────────────────────────────────
///
/// Returns the current git branch name.
pub fn gitBranch(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const cwd = std.process.currentPathAlloc(io, std.heap.page_allocator) catch {
        state.pushNil();
        state.pushString("could not resolve cwd");
        return 2;
    };
    defer std.heap.page_allocator.free(cwd);

    var result = bash_exec.run(std.heap.page_allocator, io, cwd, "git branch --show-current") catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer result.deinit(std.heap.page_allocator);

    if (result.code != 0) {
        state.pushNil();
        state.pushString(gitErrorString(result.stderr, result.code));
        return 2;
    }

    // Trim trailing newline
    const output = std.mem.trimEnd(u8, result.stdout, "\n\r ");
    state.pushString(output);
    return 1;
}

/// Helper: shell-quote an argument using single quotes and append to ArrayList.
fn appendQuotedArg(list: *std.ArrayList(u8), gpa: std.mem.Allocator, arg: []const u8) !void {
    try list.append(gpa, '\'');
    for (arg) |byte| {
        if (byte == '\'') {
            try list.appendSlice(gpa, "'\\''");
        } else {
            try list.append(gpa, byte);
        }
    }
    try list.append(gpa, '\'');
}

/// ── nova.git_add(files) ─────────────────────────────────────────────
///
/// Stages specific files for git commit. Accepts a single file path string,
/// or an array of file path strings. Returns { success, output }.
pub fn gitAdd(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    if (state.getTop() < 1 or state.isNil(1)) {
        state.pushNil();
        state.pushString("files argument is required");
        return 2;
    }

    var cwd_buf: ?[]u8 = null;
    defer if (cwd_buf) |b| std.heap.page_allocator.free(b);

    const cwd: []const u8 = if (bridge.plugin_cwd_slot) |slot_cwd|
        slot_cwd
    else blk: {
        cwd_buf = std.process.currentPathAlloc(io, std.heap.page_allocator) catch {
            state.pushNil();
            state.pushString("could not resolve cwd");
            return 2;
        };
        break :blk cwd_buf.?;
    };

    var cmd_buf: std.ArrayList(u8) = .empty;
    defer cmd_buf.deinit(std.heap.page_allocator);

    cmd_buf.appendSlice(std.heap.page_allocator, "git add --") catch {
        state.pushNil();
        state.pushString("out of memory");
        return 2;
    };

    if (state.isString(1)) {
        const file_str = state.toString(1) orelse {
            state.pushNil();
            state.pushString("invalid files string");
            return 2;
        };
        if (std.mem.eql(u8, file_str, ".") or std.mem.eql(u8, file_str, "-A")) {
            cmd_buf.clearRetainingCapacity();
            cmd_buf.appendSlice(std.heap.page_allocator, "git add -A") catch {
                state.pushNil();
                state.pushString("out of memory");
                return 2;
            };
        } else {
            var it = std.mem.tokenizeScalar(u8, file_str, ',');
            while (it.next()) |item| {
                const trimmed = std.mem.trim(u8, item, " \t\r\n");
                if (trimmed.len == 0) continue;
                cmd_buf.append(std.heap.page_allocator, ' ') catch continue;
                appendQuotedArg(&cmd_buf, std.heap.page_allocator, trimmed) catch continue;
            }
        }
    } else if (state.isTable(1)) {
        const len = c.lua_rawlen(L_ptr, 1);
        var i: usize = 1;
        while (i <= len) : (i += 1) {
            _ = c.lua_rawgeti(L_ptr, 1, @intCast(i));
            if (state.isString(-1)) {
                if (state.toString(-1)) |s| {
                    cmd_buf.append(std.heap.page_allocator, ' ') catch continue;
                    appendQuotedArg(&cmd_buf, std.heap.page_allocator, s) catch continue;
                }
            }
            c.lua_pop(L_ptr, 1);
        }
    } else {
        state.pushNil();
        state.pushString("files argument must be a string or table of strings");
        return 2;
    }

    const cmd = cmd_buf.toOwnedSlice(std.heap.page_allocator) catch {
        state.pushNil();
        state.pushString("out of memory");
        return 2;
    };
    defer std.heap.page_allocator.free(cmd);

    var result = bash_exec.runWithOptions(std.heap.page_allocator, io, .{
        .cwd = cwd,
        .command = cmd,
    }) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer result.deinit(std.heap.page_allocator);

    state.newTable();
    state.pushBoolean(result.code == 0);
    _ = c.lua_setfield(L_ptr, -2, "success");
    state.pushString(if (result.code == 0) result.stdout else result.stderr);
    _ = c.lua_setfield(L_ptr, -2, "output");
    return 1;
}

/// ── nova.git_commit(msg, opts?) ────────────────────────────────────
///
/// Creates a git commit with the given message. Returns { success, output }
/// (output = git stderr on failure, or the commit summary on success).
///
/// Optional `opts` table fields:
///   files       (string or array of strings) — stage specific files before commit
///   staged_only (boolean) — only commit already-staged files (no git add)
///   stage_all   (boolean) — stage all changes (git add -A) before commit
pub fn gitCommit(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const io = getIo(L_ptr);

    const msg = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("commit message argument is required");
        return 2;
    };

    var cwd_buf: ?[]u8 = null;
    defer if (cwd_buf) |b| std.heap.page_allocator.free(b);

    const cwd: []const u8 = if (bridge.plugin_cwd_slot) |slot_cwd|
        slot_cwd
    else blk: {
        cwd_buf = std.process.currentPathAlloc(io, std.heap.page_allocator) catch {
            state.pushNil();
            state.pushString("could not resolve cwd");
            return 2;
        };
        break :blk cwd_buf.?;
    };

    var cmd_buf: std.ArrayList(u8) = .empty;
    defer cmd_buf.deinit(std.heap.page_allocator);

    var has_custom_command = false;

    if (state.getTop() >= 2 and state.isTable(2)) {
        if (bridge.getTableBoolean(&state, 2, "staged_only")) |staged_only| {
            if (staged_only) {
                cmd_buf.appendSlice(std.heap.page_allocator, "git commit -F -") catch {};
                has_custom_command = true;
            }
        }

        if (!has_custom_command) {
            _ = c.lua_getfield(L_ptr, 2, "files");
            if (!state.isNil(-1)) {
                if (state.isString(-1)) {
                    if (state.toString(-1)) |f_str| {
                        cmd_buf.appendSlice(std.heap.page_allocator, "git add --") catch {};
                        var it = std.mem.tokenizeScalar(u8, f_str, ',');
                        while (it.next()) |item| {
                            const trimmed = std.mem.trim(u8, item, " \t\r\n");
                            if (trimmed.len == 0) continue;
                            cmd_buf.append(std.heap.page_allocator, ' ') catch continue;
                            appendQuotedArg(&cmd_buf, std.heap.page_allocator, trimmed) catch continue;
                        }
                        cmd_buf.appendSlice(std.heap.page_allocator, " && git commit -F -") catch {};
                        has_custom_command = true;
                    }
                } else if (state.isTable(-1)) {
                    cmd_buf.appendSlice(std.heap.page_allocator, "git add --") catch {};
                    const len = c.lua_rawlen(L_ptr, -1);
                    var i: usize = 1;
                    while (i <= len) : (i += 1) {
                        _ = c.lua_rawgeti(L_ptr, -1, @intCast(i));
                        if (state.isString(-1)) {
                            if (state.toString(-1)) |s| {
                                cmd_buf.append(std.heap.page_allocator, ' ') catch continue;
                                appendQuotedArg(&cmd_buf, std.heap.page_allocator, s) catch continue;
                            }
                        }
                        c.lua_pop(L_ptr, 1);
                    }
                    cmd_buf.appendSlice(std.heap.page_allocator, " && git commit -F -") catch {};
                    has_custom_command = true;
                }
            }
            c.lua_pop(L_ptr, 1); // pop "files"
        }
    }

    if (!has_custom_command) {
        cmd_buf.appendSlice(std.heap.page_allocator, "git add -A && git commit -F -") catch {
            state.pushNil();
            state.pushString("out of memory");
            return 2;
        };
    }

    const cmd = cmd_buf.toOwnedSlice(std.heap.page_allocator) catch {
        state.pushNil();
        state.pushString("out of memory");
        return 2;
    };
    defer std.heap.page_allocator.free(cmd);

    // Stage and commit. The message is piped via stdin to `git commit -F -`
    // so shell metacharacters in `msg` are never interpreted.
    var result = bash_exec.runWithOptions(std.heap.page_allocator, io, .{
        .cwd = cwd,
        .command = cmd,
        .stdin = msg,
    }) catch |err| {
        state.pushNil();
        state.pushString(@errorName(err));
        return 2;
    };
    defer result.deinit(std.heap.page_allocator);

    state.newTable();
    state.pushBoolean(result.code == 0);
    _ = c.lua_setfield(L_ptr, -2, "success");
    state.pushString(if (result.code == 0) result.stdout else result.stderr);
    _ = c.lua_setfield(L_ptr, -2, "output");
    return 1;
}

/// ── nova.think(prompt) ──────────────────────────────────────────────
///
/// Sends a prompt to the LLM and returns the response.
/// This is a stub implementation — full integration requires access to
/// the active AI client, which will be wired in a future phase.
/// For now, returns an error message indicating the feature is not yet available.
pub fn think(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };

    const prompt = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("prompt argument is required");
        return 2;
    };

    // Stub: full implementation requires threading the AI client into the
    // plugin API. The Lua registry only stores std.Io; we'd need to also
    // store a pointer to the LanguageModel for recursive LLM calls.
    // For now, return an informative message.
    _ = prompt;
    state.pushNil();
    state.pushString("nova.think() is not yet implemented — requires AI client integration");
    return 2;
}

/// ── nova.register_tool(spec) ─────────────────────────────────────────
///
/// Registers a tool that the AI model can call. The spec table must have:
///   name (string) — tool name (lowercase, underscores)
///   description (string) — description for the model
///   parameters (table) — parameter definitions
///   handler (function) — called with params when the model invokes the tool
///
/// Stores the spec in the Lua registry under "nova_tools" as a table of
/// { name, description, parameters, handler_ref } entries. The handler is
/// stored as a registry reference (luaL_ref) so it survives garbage collection.
/// Returns true on success.
/// Validate a tool name against Nova's convention: lowercase letter first,
/// then lowercase letters, digits, and underscores, max 64 chars. Provider
/// tool names must match `^[a-zA-Z0-9_-]+$`; this stricter rule keeps names
/// provider-safe and consistent.
fn isValidToolName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (!std.ascii.isLower(name[0])) return false;
    for (name) |ch| {
        if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '_') return false;
    }
    return true;
}

/// Validate an event name against the seven names emitted by
/// `events.Event.name()`. Unknown names would silently never fire.
fn isValidEventName(name: []const u8) bool {
    const valid = [_][]const u8{
        "turn_started",
        "turn_ended",
        "tool_call_started",
        "tool_call_finished",
        "response_received",
        "plugin_loaded",
        "plugin_unloaded",
    };
    for (valid) |v| {
        if (std.mem.eql(u8, name, v)) return true;
    }
    return false;
}

pub fn registerTool(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };

    // arg 1: spec table
    if (!state.isTable(1)) {
        state.pushNil();
        state.pushString("spec table argument is required");
        return 2;
    }

    std.log.debug("plugin.registerTool.start", .{});

    // Extract fields from spec
    const name = bridge.getTableString(&state, 1, "name") orelse {
        state.pushNil();
        state.pushString("spec.name is required");
        return 2;
    };
    // Fail fast on invalid tool names: provider tool names must match
    // `^[a-zA-Z0-9_-]+$`, and Nova's convention is lowercase + underscores.
    if (name.len == 0 or name.len > 64 or !isValidToolName(name)) {
        const msg = std.fmt.allocPrint(std.heap.page_allocator, "invalid tool name '{s}' (must be lowercase letters, digits, and underscores, starting with a letter, max 64 chars)", .{name}) catch {
            state.pushNil();
            state.pushString("invalid tool name");
            return 2;
        };
        defer std.heap.page_allocator.free(msg);
        state.pushNil();
        state.pushString(msg);
        return 2;
    }
    const description = bridge.getTableString(&state, 1, "description") orelse {
        state.pushNil();
        state.pushString("spec.description is required");
        return 2;
    };

    // Get the handler function and store it as a registry reference
    _ = c.lua_getfield(L_ptr, 1, "handler");
    if (!state.isFunction(-1)) {
        state.pop(1);
        state.pushNil();
        state.pushString("spec.handler must be a function");
        return 2;
    }
    const handler_ref = c.luaL_ref(L_ptr, c.LUA_REGISTRYINDEX);

    // Get or create the nova_tools table in the registry
    _ = c.lua_getfield(L_ptr, c.LUA_REGISTRYINDEX, "nova_tools");
    if (state.isNil(-1)) {
        state.pop(1);
        state.newTable();
        _ = c.lua_pushvalue(L_ptr, -1);
        _ = c.lua_setfield(L_ptr, c.LUA_REGISTRYINDEX, "nova_tools");
    }
    const tools_table = c.lua_gettop(L_ptr);

    // Count existing entries to get next index
    const next_idx = c.lua_rawlen(L_ptr, tools_table) + 1;

    // Create entry table: { name, description, parameters, handler_ref }
    state.newTable();
    state.pushString(name);
    _ = c.lua_setfield(L_ptr, -2, "name");
    state.pushString(description);
    _ = c.lua_setfield(L_ptr, -2, "description");

    // Copy parameters table from spec
    _ = c.lua_getfield(L_ptr, 1, "parameters");
    if (state.isTable(-1)) {
        _ = c.lua_setfield(L_ptr, -2, "parameters");
    } else {
        state.pop(1);
        state.newTable();
        _ = c.lua_setfield(L_ptr, -2, "parameters");
    }

    // Store handler_ref as integer
    state.pushInteger(@as(i64, @intCast(handler_ref)));
    _ = c.lua_setfield(L_ptr, -2, "handler_ref");

    // Append entry to tools table
    _ = c.lua_rawseti(L_ptr, tools_table, @as(c_int, @intCast(next_idx)));

    // Pop tools table
    state.pop(1);

    std.log.debug("plugin.registerTool.ok name={s}", .{name});
    state.pushBoolean(true);
    return 1;
}

/// ── nova.on(event, callback) ────────────────────────────────────────
///
/// Subscribes to a lifecycle event. Stores the callback as a registry
/// reference in the "nova_events" table keyed by event name.
/// Returns true on success.
pub fn onEvent(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };

    const event_name = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("event name argument is required");
        return 2;
    };

    // Fail fast on unknown event names — a typo would otherwise silently
    // never fire. Validate against the seven names in events.Event.name().
    if (!isValidEventName(event_name)) {
        const msg = std.fmt.allocPrint(std.heap.page_allocator, "unknown event '{s}' (valid: turn_started, turn_ended, tool_call_started, tool_call_finished, response_received, plugin_loaded, plugin_unloaded)", .{event_name}) catch {
            state.pushNil();
            state.pushString("unknown event");
            return 2;
        };
        defer std.heap.page_allocator.free(msg);
        state.pushNil();
        state.pushString(msg);
        return 2;
    }

    if (!state.isFunction(2)) {
        state.pushNil();
        state.pushString("callback must be a function");
        return 2;
    }

    // Store callback as registry reference
    const callback_ref = c.luaL_ref(L_ptr, c.LUA_REGISTRYINDEX);

    // Get or create nova_events table in registry
    _ = c.lua_getfield(L_ptr, c.LUA_REGISTRYINDEX, "nova_events");
    if (state.isNil(-1)) {
        state.pop(1);
        state.newTable();
        _ = c.lua_pushvalue(L_ptr, -1);
        _ = c.lua_setfield(L_ptr, c.LUA_REGISTRYINDEX, "nova_events");
    }
    const events_table = c.lua_gettop(L_ptr);

    // Get or create the event's sub-table
    _ = c.lua_getfield(L_ptr, events_table, event_name.ptr);
    if (state.isNil(-1)) {
        state.pop(1);
        state.newTable();
        _ = c.lua_pushvalue(L_ptr, -1);
        _ = c.lua_setfield(L_ptr, events_table, event_name.ptr);
    }
    const event_subtable = c.lua_gettop(L_ptr);

    // Append callback_ref to the event's sub-table
    const next_idx = c.lua_rawlen(L_ptr, event_subtable) + 1;
    state.pushInteger(@as(i64, @intCast(callback_ref)));
    _ = c.lua_rawseti(L_ptr, event_subtable, @as(c_int, @intCast(next_idx)));

    state.pop(2); // pop event_subtable and events_table

    state.pushBoolean(true);
    return 1;
}

/// Count registered tools in a Lua state by reading "nova_tools" from registry.
pub fn countTools(L: *c.lua_State) u32 {
    _ = c.lua_getfield(L, c.LUA_REGISTRYINDEX, "nova_tools");
    defer c.lua_pop(L, 1);
    if (c.lua_isnil(L, -1)) return 0;
    return @intCast(c.lua_rawlen(L, -1));
}

/// Find the index of a registered tool by name in the Lua registry.
/// Returns the 1-based index used by `callToolHandler`, or null if not found.
pub fn findToolIndex(L: *c.lua_State, tool_name: []const u8) ?c_int {
    _ = c.lua_getfield(L, c.LUA_REGISTRYINDEX, "nova_tools");
    defer c.lua_pop(L, 1);
    if (c.lua_isnil(L, -1)) return null;

    const tools_len = c.lua_rawlen(L, -1);
    var i: c_int = 1;
    while (i <= @as(c_int, @intCast(tools_len))) : (i += 1) {
        _ = c.lua_rawgeti(L, -1, i);
        _ = c.lua_getfield(L, -1, "name");
        var len: usize = 0;
        const ptr = c.lua_tolstring(L, -1, &len);
        const found = if (ptr) |p| std.mem.eql(u8, p[0..len], tool_name) else false;
        c.lua_pop(L, 2); // pop name string and entry table
        if (found) return i;
    }
    return null;
}

/// Parse a JSON string and push the result onto the Lua stack as a Lua value
/// (table, string, number, boolean, or nil). The caller owns the parsed JSON
/// value; it is freed before returning.
fn pushJsonToLua(L: *c.lua_State, gpa: std.mem.Allocator, json: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    try pushJsonValue(L, gpa, parsed.value);
}

/// ── plugin.get_config() ──────────────────────────────────────────────
///
/// Returns the plugin's configured settings as a fresh table, or nil when the
/// plugin has no config entry or no settings. The settings JSON string is
/// stored in the registry (`sandbox.settings_registry_key`) by the manager at
/// load time; re-parsing per call yields a fresh table, so plugin-side
/// mutation cannot corrupt the stored view. Malformed or non-object settings
/// return `nil, "get_config: settings must be a JSON object"`.
pub fn pluginGetConfig(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };

    // Absent slot → unconfigured → plain nil.
    _ = c.lua_getfield(L_ptr, c.LUA_REGISTRYINDEX, sandbox_mod.settings_registry_key);
    if (c.lua_isnil(L_ptr, -1)) {
        c.lua_pop(L_ptr, 1);
        state.pushNil();
        return 1;
    }
    var len: usize = 0;
    const ptr = c.lua_tolstring(L_ptr, -1, &len);
    const json = if (ptr) |p| p[0..len] else "";
    c.lua_pop(L_ptr, 1);

    // Parse first, push second: the object-vs-non-object verdict must be known
    // before anything lands on the stack (a JSON array also decodes to a Lua
    // table, so a post-push type check cannot distinguish it from an object).
    const gpa = std.heap.page_allocator;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch {
        state.pushNil();
        state.pushString("get_config: settings must be a JSON object");
        return 2;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        state.pushNil();
        state.pushString("get_config: settings must be a JSON object");
        return 2;
    }
    pushJsonValue(L_ptr, gpa, parsed.value) catch {
        state.pushNil();
        state.pushString("get_config: out of memory");
        return 2;
    };
    return 1;
}

// ── nova.json_decode / nova.json_encode ──────────────────────────────
//
// Plugins had no way to parse or emit JSON: incoming tool params are
// auto-parsed by `callToolHandler` (pushJsonToLua), but a plugin reading a
// JSON file or building structured output had to hand-roll a parser or shell
// out to `jq`. These two bridges close that gap by reusing the existing
// std.json ↔ Lua value conversion.
//
// - `nova.json_decode(str)` reuses `pushJsonValue` (Zig JSON Value → Lua).
// - `nova.json_encode(value, opts?)` traverses the Lua value with lua_next and
//   writes JSON to an allocating writer. Tables with contiguous 1..N integer
//   keys serialize as arrays; everything else (mixed/non-int keys) is an
//   object. This mirrors how Lua itself treats tables: there is no array/map
//   distinction, so the encoder infers it from the key shape.

/// ── nova.json_decode(string) ─────────────────────────────────────────
///
/// Parses a JSON string into a native Lua value (table/string/number/boolean/
/// nil). Returns the value on success, or nil + error message on failure.
pub fn jsonDecode(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const gpa = std.heap.page_allocator;

    const json = bridge.pullValue(&state, []const u8, 1) orelse {
        state.pushNil();
        state.pushString("json_decode: string argument is required");
        return 2;
    };

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch |err| {
        state.pushNil();
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "json_decode: {s}", .{@errorName(err)}) catch "json_decode: parse error";
        state.pushString(msg);
        return 2;
    };
    defer parsed.deinit();

    pushJsonValue(L_ptr, gpa, parsed.value) catch {
        state.pushNil();
        state.pushString("json_decode: failed to push value");
        return 2;
    };
    return 1;
}

/// ── nova.json_encode(value, opts?) ───────────────────────────────────
///
/// Converts a Lua value to a JSON string. `opts` is an optional table with:
///   pretty (bool) — emit indented (indent_2) output for human editing.
/// Returns the JSON string on success, or nil + error message on failure.
pub fn jsonEncode(L: ?*c.lua_State) callconv(.c) c_int {
    const L_ptr = L orelse return 0;
    var state = State{ .handle = L_ptr };
    const gpa = std.heap.page_allocator;

    // Optional opts table at index 2: { pretty: bool }.
    var pretty: bool = false;
    if (c.lua_gettop(L_ptr) >= 2 and c.lua_istable(L_ptr, 2)) {
        pretty = bridge.getTableBoolean(&state, 2, "pretty") orelse false;
    }

    const out = luaValueToJsonString(gpa, L_ptr, 1, pretty, 0) catch |err| {
        state.pushNil();
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "json_encode: {s}", .{@errorName(err)}) catch "json_encode: failed";
        state.pushString(msg);
        return 2;
    };
    defer gpa.free(out);

    state.pushString(out);
    return 1;
}

/// Recursively serialize the Lua value at `index` into a JSON string.
///
/// `index` is the absolute-ish stack slot of the value (kept stable because
/// traversal pushes/pops its own frames; the caller passes the original index,
/// which `lua_next`/`lua_gettable` keep valid as long as we pop what we push).
/// `pretty` enables indent_2 output; `depth` tracks the recursion for indent.
///
/// Table shape detection: a table is serialized as a JSON array iff every key
/// is an integer in the contiguous range 1..N. Otherwise it is an object. This
/// matches how plugins build "arrays" (sequential 1-indexed) vs "maps".
fn luaValueToJsonString(
    gpa: std.mem.Allocator,
    L: *c.lua_State,
    index: c_int,
    pretty: bool,
    depth: usize,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try writeLuaValueJson(&aw.writer, L, index, pretty, depth);
    return aw.toOwnedSlice();
}

/// Write one Lua value (at `index`) as JSON into `writer`. Helper split out so
/// compound values can recurse without each allocating its own buffer.
///
/// The error set is declared explicitly to break the inferred-error-set cycle
/// created by mutual recursion (writeLuaValueJson ↔ writeTableJson ↔
/// writeTableAsArray/Object). Any error from the writer surfaces here.
const JsonWriteError = std.Io.Writer.Error;
fn writeLuaValueJson(
    writer: *std.Io.Writer,
    L: *c.lua_State,
    index: c_int,
    pretty: bool,
    depth: usize,
) JsonWriteError!void {
    switch (c.lua_type(L, index)) {
        c.LUA_TNIL => try writer.writeAll("null"),
        c.LUA_TBOOLEAN => try writer.writeAll(if (c.lua_toboolean(L, index) != 0) "true" else "false"),
        c.LUA_TNUMBER => {
            // lua_tolstring on a number performs the standard Lua number→string
            // conversion (preserves integer vs float formatting).
            var len: usize = 0;
            const ptr = c.lua_tolstring(L, index, &len);
            if (ptr) |p| try writer.writeAll(p[0..len]) else try writer.writeAll("0");
        },
        c.LUA_TSTRING => {
            var len: usize = 0;
            const ptr = c.lua_tolstring(L, index, &len) orelse {
                try writer.writeAll("\"\"");
                return;
            };
            try writeJsonString(writer, ptr[0..len]);
        },
        c.LUA_TTABLE => try writeTableJson(writer, L, index, pretty, depth),
        // Functions, userdata, threads have no JSON representation; emit null
        // rather than failing so an accidental non-serializable field doesn't
        // poison the whole encode (matches Lua's "everything is a table" ethos).
        else => try writer.writeAll("null"),
    }
}

/// Quote and escape a byte slice as a JSON string literal.
fn writeJsonString(writer: *std.Io.Writer, s: []const u8) JsonWriteError!void {
    try writer.writeByte('"');
    for (s) |b| switch (b) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x08 => try writer.writeAll("\\b"),
        0x0c => try writer.writeAll("\\f"),
        else => {
            if (b < 0x20) {
                var hex_buf: [6]u8 = undefined;
                const hex = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{b}) catch unreachable;
                try writer.writeAll(hex);
            } else {
                try writer.writeByte(b);
            }
        },
    };
    try writer.writeByte('"');
}

/// Serialize a Lua table, inferring array vs object from its key shape.
fn writeTableJson(
    writer: *std.Io.Writer,
    L: *c.lua_State,
    index: c_int,
    pretty: bool,
    depth: usize,
) JsonWriteError!void {
    // lua_rawlen returns the "length" of the array part: the number of
    // consecutive integer keys starting at 1. If that equals the total number
    // of entries (counted via a lua_next sweep), the table is a pure array.
    const array_len = c.lua_rawlen(L, index);

    // Determine total entry count. We must not consume keys during counting
    // (lua_next would), so a separate sweep is used; both sweeps call lua_next
    // which leaves the table unmodified after a full iteration.
    var total: usize = 0;
    c.lua_pushnil(L);
    while (c.lua_next(L, index) != 0) : (total += 1) {
        c.lua_pop(L, 1); // pop value, keep key for next iteration
    }

    if (total == 0) {
        // Empty table: prefer "[]" to match Lua's common use of {} as an empty
        // list, but this is ambiguous (could be an empty map). Array is the
        // safer default for plugins building output collections.
        try writer.writeAll("[]");
        return;
    }

    if (array_len == total) {
        try writeTableAsArray(writer, L, index, pretty, depth, @intCast(array_len));
    } else {
        try writeTableAsObject(writer, L, index, pretty, depth);
    }
}

/// Serialize a table known to have contiguous integer keys 1..len as a JSON array.
fn writeTableAsArray(
    writer: *std.Io.Writer,
    L: *c.lua_State,
    index: c_int,
    pretty: bool,
    depth: usize,
    len: c_int,
) JsonWriteError!void {
    try writer.writeByte('[');
    var i: c_int = 1;
    while (i <= len) : (i += 1) {
        if (i > 1) try writer.writeByte(',');
        if (pretty) try writeIndent(writer, depth + 1);
        // lua_rawgeti pushes t[key] without metamethods; safe for plain data.
        // It returns the type of the pushed value, which we ignore.
        _ = c.lua_rawgeti(L, index, i);
        try writeLuaValueJson(writer, L, c.lua_gettop(L), pretty, depth + 1);
        c.lua_pop(L, 1);
    }
    if (pretty and len > 0) try writeIndent(writer, depth);
    try writer.writeByte(']');
}

/// Serialize a table as a JSON object, iterating all key/value pairs.
fn writeTableAsObject(
    writer: *std.Io.Writer,
    L: *c.lua_State,
    index: c_int,
    pretty: bool,
    depth: usize,
) JsonWriteError!void {
    try writer.writeByte('{');
    var first = true;
    c.lua_pushnil(L);
    while (c.lua_next(L, index) != 0) {
        // Stack: [... | table | key | value]. value on top (-1), key at -2.
        if (!first) try writer.writeByte(',');
        first = false;
        if (pretty) try writeIndent(writer, depth + 1);

        // Keys must be strings for JSON objects. Coerce number/bool keys to
        // their string form; other types skip (can't be a JSON key).
        const key_type = c.lua_type(L, -2);
        switch (key_type) {
            c.LUA_TSTRING, c.LUA_TNUMBER => {
                var klen: usize = 0;
                const kptr = c.lua_tolstring(L, -2, &klen) orelse continue;
                try writeJsonString(writer, kptr[0..klen]);
            },
            c.LUA_TBOOLEAN => {
                const s = if (c.lua_toboolean(L, -2) != 0) "true" else "false";
                try writeJsonString(writer, s);
            },
            else => continue, // non-stringifiable key: skip this pair
        }

        if (pretty) try writer.writeAll(": ") else try writer.writeByte(':');
        try writeLuaValueJson(writer, L, c.lua_gettop(L), pretty, depth + 1);
        c.lua_pop(L, 1); // pop value; lua_next uses the key for the next step
    }
    if (pretty and !first) try writeIndent(writer, depth);
    try writer.writeByte('}');
}

/// Write `depth` levels of 2-space indentation (the indent_2 convention).
fn writeIndent(writer: *std.Io.Writer, depth: usize) JsonWriteError!void {
    try writer.writeByte('\n');
    var i: usize = 0;
    while (i < depth) : (i += 1) try writer.writeAll("  ");
}

/// Recursively push a `std.json.Value` onto the Lua stack.
///
/// Public because `nova.json_decode` reuses this same conversion (Zig JSON
/// Value → Lua value) rather than re-implementing it.
pub fn pushJsonValue(L: *c.lua_State, gpa: std.mem.Allocator, value: std.json.Value) !void {
    switch (value) {
        .null => c.lua_pushnil(L),
        .bool => |b| c.lua_pushboolean(L, if (b) 1 else 0),
        .integer => |i| c.lua_pushinteger(L, i),
        .float => |f| c.lua_pushnumber(L, f),
        .number_string => |s| {
            // Try integer first, then float
            const num = std.fmt.parseFloat(f64, s) catch {
                _ = c.lua_pushstring(L, s.ptr);
                return;
            };
            c.lua_pushnumber(L, num);
        },
        .string => |s| {
            _ = c.lua_pushlstring(L, s.ptr, s.len);
        },
        .array => |items| {
            c.lua_createtable(L, @intCast(items.items.len), 0);
            for (items.items, 0..) |item, i| {
                try pushJsonValue(L, gpa, item);
                c.lua_rawseti(L, -2, @intCast(i + 1));
            }
        },
        .object => |obj| {
            c.lua_createtable(L, 0, @intCast(obj.count()));
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                _ = c.lua_pushlstring(L, entry.key_ptr.ptr, entry.key_ptr.len);
                try pushJsonValue(L, gpa, entry.value_ptr.*);
                _ = c.lua_settable(L, -3);
            }
        },
    }
}

/// Call a registered tool handler by index. Pushes the params table onto
/// the Lua stack, calls the handler, and returns the result string.
/// The caller must keep the Lua state alive during the call.
/// Returns the handler's return value as a string (owned by caller).
pub fn callToolHandler(
    L: *c.lua_State,
    gpa: std.mem.Allocator,
    tool_index: c_int,
    params_json: []const u8,
) ![]u8 {
    // Get nova_tools[index].handler_ref
    _ = c.lua_getfield(L, c.LUA_REGISTRYINDEX, "nova_tools");
    if (c.lua_isnil(L, -1)) {
        c.lua_pop(L, 1);
        return error.NoToolsRegistered;
    }
    _ = c.lua_rawgeti(L, -1, tool_index);
    _ = c.lua_getfield(L, -1, "handler_ref");
    var isnum: c_int = 0;
    const handler_ref = @as(c_int, @intCast(c.lua_tointegerx(L, -1, &isnum)));
    c.lua_pop(L, 2); // pop handler_ref and entry table

    // Get the handler function from registry
    _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, handler_ref);

    // Parse JSON params into a Lua table so handlers can use table access
    // (e.g. params.depth, params.pattern) instead of manual JSON parsing.
    pushJsonToLua(L, gpa, params_json) catch {
        c.lua_newtable(L);
    };

    // Reset the per-dispatch instruction budget and timeout deadline so the
    // limits mean "per tool call", not "per session" (T1/T2).
    sandbox_mod.resetInstructionBudget(L);

    // Call handler(params_json)
    const rc = c.lua_pcallk(L, 1, 1, 0, 0, null);
    if (rc != c.LUA_OK) {
        const err_msg = c.lua_tolstring(L, -1, null);
        const msg = if (err_msg) |p| std.mem.sliceTo(p, 0) else "unknown error";
        const result = try std.fmt.allocPrint(gpa, "Lua tool error: {s}", .{msg});
        c.lua_pop(L, 1); // pop error
        c.lua_pop(L, 1); // pop tools table
        return result;
    }

    // Get result string
    var len: usize = 0;
    const result_ptr = c.lua_tolstring(L, -1, &len);
    const result = if (result_ptr) |p| try gpa.dupe(u8, p[0..len]) else try gpa.dupe(u8, "");

    c.lua_pop(L, 2); // pop result and tools table
    return result;
}

// ── helpers ──────────────────────────────────────────────────────────

/// Sanitize a path: resolve `..` and `.` segments, reject traversal.
///
/// The lexical check (resolve + prefix) is necessary but not sufficient: a
/// symlink inside the project pointing outside (`ln -s /etc .nova/link`)
/// resolves lexically inside cwd and would be served. Mirror the documented
/// `validateCwd` pattern — after the lexical check passes, best-effort
/// `realpathAlloc` on the resolved path; if realpath succeeds, re-check the
/// prefix against realpath(cwd). If realpath fails (ENOENT — a new file being
/// written), fall back to the lexical verdict.
fn sanitizePath(io: std.Io, path: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;

    var cwd_buf: ?[]u8 = null;
    defer if (cwd_buf) |b| std.heap.page_allocator.free(b);

    const raw_cwd: []const u8 = if (bridge.plugin_cwd_slot) |slot_cwd|
        slot_cwd
    else blk: {
        cwd_buf = try std.process.currentPathAlloc(io, std.heap.page_allocator);
        break :blk cwd_buf.?;
    };

    var abs_cwd_buf: ?[]u8 = null;
    defer if (abs_cwd_buf) |b| std.heap.page_allocator.free(b);
    const cwd = if (std.fs.path.isAbsolute(raw_cwd))
        raw_cwd
    else blk: {
        abs_cwd_buf = try std.fs.path.resolve(std.heap.page_allocator, &.{raw_cwd});
        break :blk abs_cwd_buf.?;
    };

    const resolved = try std.fs.path.resolve(std.heap.page_allocator, &.{ cwd, path });
    errdefer std.heap.page_allocator.free(resolved);
    if (!std.mem.startsWith(u8, resolved, cwd)) return error.PathTraversal;
    if (resolved.len > cwd.len and resolved[cwd.len] != std.fs.path.sep) return error.PathTraversal;

    // Best-effort realpath re-check to catch a symlink escaping the root.
    // std.c.realpath returns null on failure (including ENOENT for a new file
    // being written), in which case we fall back to the lexical verdict.
    // Skipped on Windows (no realpath in ucrt; lexical check is sufficient).
    if (!os.is_windows) {
        const resolved_z = std.heap.page_allocator.dupeZ(u8, resolved) catch return resolved;
        defer std.heap.page_allocator.free(resolved_z);
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const real_ptr = std.c.realpath(resolved_z.ptr, &real_buf);
        if (real_ptr) |rp| {
            const real = std.mem.span(rp);
            const cwd_z = std.heap.page_allocator.dupeZ(u8, cwd) catch return resolved;
            defer std.heap.page_allocator.free(cwd_z);
            var real_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const rcwd_ptr = std.c.realpath(cwd_z.ptr, &real_cwd_buf);
            const real_cwd = if (rcwd_ptr) |rcp| std.mem.span(rcp) else cwd;
            if (!std.mem.startsWith(u8, real, real_cwd)) return error.PathTraversal;
            if (real.len > real_cwd.len and real[real_cwd.len] != std.fs.path.sep) return error.PathTraversal;
        }
    }

    return resolved;
}

/// Read file bytes with size limit.
fn readFileBytes(io: std.Io, path: []const u8, max_size: usize) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const read_size = @min(@as(usize, @intCast(stat.size)), max_size);
    const bytes = try std.heap.page_allocator.alloc(u8, read_size);
    errdefer std.heap.page_allocator.free(bytes);
    var reader = file.reader(io, &.{});
    try reader.interface.readSliceAll(bytes);
    return bytes;
}

/// Stat a file and return its on-disk size in bytes. Best-effort: returns
/// `error.FileNotFound` when the file is absent, which callers may fall back on.
fn statFileSize(io: std.Io, path: []const u8) !u64 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    return stat.size;
}

/// Atomic file write: write to temp, then rename.
fn writeFileAtomic(io: std.Io, path: []const u8, content: []const u8) !void {
    // Random hex tmp name so two concurrent writers to the same path never
    // race on one tmp file (the bash tool's convention, AGENTS.md §Safety).
    var random: [4]u8 = undefined;
    io.random(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const tmp_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.{s}.tmp", .{ path, hex[0..] });
    defer std.heap.page_allocator.free(tmp_path);

    var file = std.Io.Dir.createFileAbsolute(io, tmp_path, .{}) catch |err| {
        // Nothing to clean up — the tmp file was never created.
        return err;
    };

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    writer.interface.writeAll(content) catch |err| {
        file.close(io);
        deleteFileBestEffort(io, tmp_path);
        return err;
    };
    writer.interface.flush() catch |err| {
        file.close(io);
        deleteFileBestEffort(io, tmp_path);
        return err;
    };
    file.close(io);

    std.Io.Dir.renameAbsolute(tmp_path, path, io) catch |err| {
        deleteFileBestEffort(io, tmp_path);
        return err;
    };
}

/// Best-effort delete of a tmp file after a failed atomic write. Ignores
/// errors — the file is already in a failure path and a stray tmp is
/// preferable to masking the original error.
fn deleteFileBestEffort(io: std.Io, path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
}

/// Apply line range to content.
fn applyLineRange(content: []const u8, start_line: ?u32, end_line: ?u32) []const u8 {
    const start = start_line orelse 1;
    if (start <= 1 and end_line == null) return content;

    var line_start: usize = 0;
    var current_line: u32 = 1;

    // Advance to start line
    while (current_line < start) {
        if (std.mem.indexOfScalarPos(u8, content, line_start, '\n')) |pos| {
            line_start = pos + 1;
            current_line += 1;
        } else {
            return content[0..0];
        }
    }

    // If no end line, return from start to end of content
    if (end_line == null) return content[line_start..];

    const end = end_line.?;
    var line_end = line_start;
    while (current_line <= end) {
        if (std.mem.indexOfScalarPos(u8, content, line_end, '\n')) |pos| {
            line_end = pos + 1;
            current_line += 1;
        } else {
            line_end = content.len;
            break;
        }
    }

    // Remove trailing newline if present
    if (line_end > line_start and content[line_end - 1] == '\n') {
        return content[line_start .. line_end - 1];
    }
    return content[line_start..line_end];
}

/// Count lines in text.
fn countLines(text: []const u8) u32 {
    var count: u32 = 1;
    for (text) |ch| {
        if (ch == '\n') count += 1;
    }
    return count;
}

/// Detect programming language from file extension.
fn detectLanguage(path: []const u8, content: []const u8) []const u8 {
    const ext = getExtension(path);
    if (lang_map.get(ext)) |lang| return lang;
    if (content.len > 0 and content[0] == '#' and content.len > 1 and content[1] == '!') return "script";
    return "text";
}

/// Get MIME type from file extension.
fn getMimeType(path: []const u8) []const u8 {
    const ext = getExtension(path);
    return mime_map.get(ext) orelse "application/octet-stream";
}

/// Get file extension (lowercase).
fn getExtension(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "";
    return path[dot + 1 ..];
}

/// Find git repository root by walking up from `cwd`.
fn findGitRoot(io: std.Io, cwd: []const u8) ![]u8 {
    var abs_cwd_buf: ?[]u8 = null;
    defer if (abs_cwd_buf) |b| std.heap.page_allocator.free(b);

    const abs_cwd = if (std.fs.path.isAbsolute(cwd))
        cwd
    else blk: {
        const proc_cwd = try std.process.currentPathAlloc(io, std.heap.page_allocator);
        defer std.heap.page_allocator.free(proc_cwd);
        abs_cwd_buf = try std.fs.path.resolve(std.heap.page_allocator, &.{ proc_cwd, cwd });
        break :blk abs_cwd_buf.?;
    };

    var current = try std.heap.page_allocator.dupe(u8, abs_cwd);
    defer std.heap.page_allocator.free(current);

    while (current.len > 0) {
        const git_path = try std.fs.path.join(std.heap.page_allocator, &.{ current, ".git" });
        defer std.heap.page_allocator.free(git_path);

        var is_git = false;
        if (std.Io.Dir.openDirAbsolute(io, git_path, .{})) |*d| {
            d.close(io);
            is_git = true;
        } else |_| {
            if (std.Io.Dir.openFileAbsolute(io, git_path, .{})) |*f| {
                f.close(io);
                is_git = true;
            } else |_| {}
        }

        if (is_git) {
            return try std.heap.page_allocator.dupe(u8, current);
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const new_current = try std.heap.page_allocator.dupe(u8, parent);
        std.heap.page_allocator.free(current);
        current = new_current;
    }

    return error.GitRootNotFound;
}

/// Test whether `name` matches the user-supplied `file_pattern`.
///
/// `file_pattern` is the loose glob the plugin passed (e.g. `"*.lua"`). It is
/// matched as a suffix test:
///   - empty  → matches everything (the historical segfault: `fp[1..]` indexed
///     a zero-length slice and panicked with SIGABRT on `list_project_files("")`)
///   - `"*x"` → strip the leading `*`, then suffix-match on `"x"`
///   - `"x"`  → suffix-match verbatim
///
/// Kept as a free function so the suffix logic is unit-testable in isolation.
fn fileNameMatches(name: []const u8, file_pattern: []const u8) bool {
    if (file_pattern.len == 0) return true;
    const suffix = if (file_pattern[0] == '*') file_pattern[1..] else file_pattern;
    return std.mem.endsWith(u8, name, suffix);
}

/// Walk directory recursively and search for pattern.
fn walkAndSearch(
    io: std.Io,
    dir_path: []const u8,
    file_pattern: ?[]const u8,
    pattern: []const u8,
    case_sensitive: bool,
    max_results: u32,
    total: *u32,
    result_count: *u32,
    L: ?*c.lua_State,
) !void {
    const L_ptr = L orelse return;
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.name.len == 0) continue;
        if (entry.name[0] == '.') continue;

        const full_path = try std.fs.path.join(std.heap.page_allocator, &.{ dir_path, entry.name });
        defer std.heap.page_allocator.free(full_path);

        switch (entry.kind) {
            .directory => {
                try walkAndSearch(io, full_path, file_pattern, pattern, case_sensitive, max_results, total, result_count, L);
            },
            .file => {
                if (file_pattern) |fp| {
                    if (!fileNameMatches(entry.name, fp)) continue;
                }

                var file = std.Io.Dir.openFileAbsolute(io, full_path, .{}) catch continue;
                defer file.close(io);

                var reader = file.reader(io, &.{});
                const content = reader.interface.allocRemaining(std.heap.page_allocator, .limited(max_read_size)) catch continue;
                defer std.heap.page_allocator.free(content);

                var line_num: u32 = 0;
                var pos: usize = 0;
                while (pos < content.len) {
                    const next_newline = std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse content.len;
                    const line = content[pos..next_newline];
                    pos = next_newline + 1;
                    line_num += 1;

                    const found = if (case_sensitive)
                        std.mem.indexOf(u8, line, pattern) != null
                    else
                        std.ascii.indexOfIgnoreCase(line, pattern) != null;

                    if (found) {
                        total.* += 1;
                        if (result_count.* < max_results) {
                            result_count.* += 1;
                            // Stack layout here: [ ... | results_table ]
                            // Build the entry, then `results[result_count] = entry`
                            // via lua_rawseti which pops it and leaves the
                            // results table on top. The previous code pushed an
                            // extra integer and used -3 as the table index,
                            // which leaked one entry table per match and wrote
                            // the bare integer into results[i] instead of the
                            // entry.
                            var st = State{ .handle = L_ptr };
                            st.newTable(); // [ ... | results_table | entry ]
                            st.pushString(full_path);
                            _ = c.lua_setfield(L_ptr, -2, "file");
                            st.pushInteger(@as(i64, @intCast(line_num)));
                            _ = c.lua_setfield(L_ptr, -2, "line");
                            const truncated = if (line.len > 200) line[0..200] else line;
                            st.pushString(truncated);
                            _ = c.lua_setfield(L_ptr, -2, "content");
                            _ = c.lua_rawseti(L_ptr, -2, @as(c_int, @intCast(result_count.*)));
                            // [ ... | results_table ]
                        }
                    }
                }
            },
            else => {},
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────

test "fileNameMatches: empty pattern matches everything (regression for SIGABRT)" {
    // Used to be `fp[1..]` which panicked (index-out-of-bounds) on `""`,
    // crashing the agent when a plugin passed an empty file_pattern
    // (Lua treats "" as truthy, so project-info/search-tool forwarded it).
    try std.testing.expect(fileNameMatches("anything.lua", ""));
    try std.testing.expect(fileNameMatches("Makefile", ""));
}

test "fileNameMatches: star glob strips leading star" {
    try std.testing.expect(fileNameMatches("main.lua", "*.lua"));
    try std.testing.expect(fileNameMatches("vendor/init.lua", "*.lua"));
    try std.testing.expect(!fileNameMatches("main.zig", "*.lua"));
}

test "fileNameMatches: bare suffix matches verbatim" {
    try std.testing.expect(fileNameMatches("main.lua", ".lua"));
    try std.testing.expect(fileNameMatches("config.json", "json"));
    try std.testing.expect(!fileNameMatches("config.json", ".lua"));
}

test "fileNameMatches: star-only pattern matches everything" {
    try std.testing.expect(fileNameMatches("anything.lua", "*"));
    try std.testing.expect(fileNameMatches("README", "*"));
}

test "detectLanguage: known extensions" {
    try std.testing.expectEqualStrings("zig", detectLanguage("main.zig", ""));
    try std.testing.expectEqualStrings("lua", detectLanguage("init.lua", ""));
    try std.testing.expectEqualStrings("python", detectLanguage("script.py", ""));
    try std.testing.expectEqualStrings("javascript", detectLanguage("app.js", ""));
    try std.testing.expectEqualStrings("markdown", detectLanguage("README.md", ""));
}

test "detectLanguage: shebang detection" {
    try std.testing.expectEqualStrings("script", detectLanguage("script", "#!/usr/bin/env bash"));
}

test "detectLanguage: unknown extension" {
    try std.testing.expectEqualStrings("text", detectLanguage("file.xyz", ""));
}

test "getMimeType: known types" {
    try std.testing.expectEqualStrings("text/x-lua", getMimeType("test.lua"));
    try std.testing.expectEqualStrings("application/json", getMimeType("config.json"));
    try std.testing.expectEqualStrings("text/markdown", getMimeType("README.md"));
}

test "getMimeType: unknown extension" {
    try std.testing.expectEqualStrings("application/octet-stream", getMimeType("file.xyz"));
}

test "getExtension: extracts extension" {
    try std.testing.expectEqualStrings("zig", getExtension("main.zig"));
    try std.testing.expectEqualStrings("lua", getExtension("init.lua"));
}

test "getExtension: no extension" {
    try std.testing.expectEqualStrings("", getExtension("Makefile"));
}

test "countLines: empty text" {
    try std.testing.expectEqual(@as(u32, 1), countLines(""));
}

test "countLines: single line" {
    try std.testing.expectEqual(@as(u32, 1), countLines("hello world"));
}

test "countLines: multiple lines" {
    try std.testing.expectEqual(@as(u32, 3), countLines("line1\nline2\nline3"));
}

test "applyLineRange: no range returns full content" {
    const content = "line1\nline2\nline3";
    try std.testing.expectEqualStrings(content, applyLineRange(content, null, null));
}

test "applyLineRange: start_line only" {
    const content = "line1\nline2\nline3\nline4";
    try std.testing.expectEqualStrings("line2\nline3\nline4", applyLineRange(content, 2, null));
}

test "applyLineRange: start and end" {
    const content = "line1\nline2\nline3\nline4";
    try std.testing.expectEqualStrings("line2\nline3", applyLineRange(content, 2, 3));
}

test "applyLineRange: past end returns empty" {
    const content = "line1\nline2";
    try std.testing.expectEqualStrings("", applyLineRange(content, 10, null));
}

test "registerTool + countTools: sandboxed state" {
    const sandbox = @import("sandbox.zig");

    // Create a sandboxed state with Io (so registerPluginApi is called).
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    // Before registration, there should be 0 tools.
    try std.testing.expectEqual(@as(u32, 0), countTools(L.handle));

    // Register a tool via Lua code (same as what init.lua does).
    const ok = L.doString(
        \\nova.register_tool({
        \\  name = "test_tool",
        \\  description = "A test tool",
        \\  parameters = {
        \\    foo = { type = "string", description = "A foo param" },
        \\  },
        \\  handler = function(params) return "ok" end,
        \\})
    );
    if (!ok) {
        const err = L.getErrorMessage();
        std.debug.print("Lua error: {s}\n", .{err orelse "unknown"});
        L.pop(1);
    }
    try std.testing.expect(ok);

    // After registration, countTools should see 1 tool.
    try std.testing.expectEqual(@as(u32, 1), countTools(L.handle));
}

test "registerTool rejects invalid tool names (T6)" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    // Uppercase, space, colon, empty, and over-long names are all rejected.
    try expectLuaOk(&L,
        \\local function try(name)
        \\  local ok, err = nova.register_tool({
        \\    name = name, description = "d",
        \\    handler = function() return "x" end,
        \\  })
        \\  assert(ok == nil, "should reject: " .. tostring(name))
        \\  assert(err ~= nil and err:find("invalid tool name") ~= nil, tostring(err))
        \\end
        \\try("BadName")
        \\try("has space")
        \\try("has:colon")
        \\try("")
        \\try(string.rep("a", 65))
        \\return "OK"
    );

    // A valid lowercase/underscore name still registers.
    try expectLuaOk(&L,
        \\local ok, err = nova.register_tool({
        \\  name = "valid_tool_2", description = "d",
        \\  handler = function() return "x" end,
        \\})
        \\assert(ok == true, tostring(err))
        \\return "OK"
    );
    try std.testing.expectEqual(@as(u32, 1), countTools(L.handle));
}

test "onEvent rejects unknown event names (T6)" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    // A typo'd event name must fail fast, not silently never fire.
    try expectLuaOk(&L,
        \\local ok, err = nova.on("turn_strated", function() end)
        \\assert(ok == nil, "unknown event should fail")
        \\assert(err ~= nil and err:find("unknown event") ~= nil, tostring(err))
        \\return "OK"
    );

    // All seven valid names are accepted.
    try expectLuaOk(&L,
        \\local names = {
        \\  "turn_started", "turn_ended", "tool_call_started",
        \\  "tool_call_finished", "response_received",
        \\  "plugin_loaded", "plugin_unloaded",
        \\}
        \\for _, n in ipairs(names) do
        \\  local ok, err = nova.on(n, function() end)
        \\  assert(ok == true, n .. ": " .. tostring(err))
        \\end
        \\return "OK"
    );
}

// ── nova.write_file / writeFileAtomic tests ──────────────────────────
//
// writeFileAtomic is the shared write+rename core behind both nova.write_file
// and nova.edit_file; the Lua-level tests exercise the binding surface
// (argument validation, path sanitization, and a real write under cwd).

test "writeFileAtomic writes, overwrites, and leaves no temp file" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // std.testing.tmpDir lives under <cwd>/.zig-cache/tmp/<sub_path>.
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const target = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "write-test.txt" });
    defer gpa.free(target);

    // First write creates the file.
    try writeFileAtomic(io, target, "hello");
    {
        const content = try readFileBytes(io, target, 4096);
        defer std.heap.page_allocator.free(content);
        try std.testing.expectEqualStrings("hello", content);
    }

    // A second write replaces the whole content atomically.
    try writeFileAtomic(io, target, "hello world");
    {
        const content = try readFileBytes(io, target, 4096);
        defer std.heap.page_allocator.free(content);
        try std.testing.expectEqualStrings("hello world", content);
    }

    // The temp file was renamed away — nothing is left behind. The tmp name
    // is now `<path>.<8-hex>.tmp`, so check for any stray `*.tmp` in the dir.
    const dir = std.fs.path.dirname(target) orelse ".";
    var dir_handle = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer dir_handle.close(io);
    // Freshly opened dir — skip the reset-seek that testing.io's threaded
    // vtable can't do on a dir fd (BADF).
    var it = dir_handle.iterateAssumeFirstIteration();
    while (try it.next(io)) |entry| {
        try std.testing.expect(!std.mem.endsWith(u8, entry.name, ".tmp"));
    }
}

test "nova.write_file validates its arguments" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    try expectLuaOk(&L,
        \\local ok, err = nova.write_file()
        \\assert(ok == nil, "missing path should fail")
        \\assert(err == "path argument is required", tostring(err))
        \\local ok2, err2 = nova.write_file("x.txt")
        \\assert(ok2 == nil, "missing content should fail")
        \\assert(err2 == "content argument is required", tostring(err2))
        \\return "OK"
    );
}

test "nova.write_file rejects traversal and invalid paths without writing" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    try expectLuaOk(&L,
        \\local ok, err = nova.write_file("../escape.txt", "x")
        \\assert(ok == nil, "path traversal should fail")
        \\assert(err == "PathTraversal", tostring(err))
        \\local p = "bad" .. string.char(0) .. "path.txt"
        \\local ok2, err2 = nova.write_file(p, "x")
        \\assert(ok2 == nil, "nul byte should fail")
        \\assert(err2 == "InvalidPath", tostring(err2))
        \\return "OK"
    );
}

test "nova.write_file writes content to a path under cwd" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // sanitizePath resolves relative paths against cwd and rejects writes that
    // escape it; the tmp dir sits under <cwd>/.zig-cache/tmp so a relative path
    // reaches it.
    const rel = try std.fmt.allocPrintSentinel(gpa, ".zig-cache/tmp/{s}/lua-write.txt", .{&tmp.sub_path}, 0);
    defer gpa.free(rel);
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const target = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "lua-write.txt" });
    defer gpa.free(target);

    const chunk = try std.fmt.allocPrintSentinel(gpa, "local ok, err = nova.write_file(\"{s}\", \"hello from lua\")\nassert(ok == true, tostring(err))\nreturn \"OK\"", .{rel}, 0);
    defer gpa.free(chunk);

    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L, chunk);

    // The file exists with the exact content written from Lua.
    const content = try readFileBytes(io, target, 4096);
    defer std.heap.page_allocator.free(content);
    try std.testing.expectEqualStrings("hello from lua", content);
}

// ── S3: edit_file / read_file size-limit tests ───────────────────────

test "editFile refuses to edit a file over 1 MB and leaves it byte-identical" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const target = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "big-edit.txt" });
    defer gpa.free(target);

    // Write a file just over the 1 MB cap.
    const big = try gpa.alloc(u8, max_read_size + 100);
    defer gpa.free(big);
    @memset(big, 'x');
    try writeFileAtomic(io, target, big);

    // editFile must return an error and leave the file untouched.
    try std.testing.expectError(error.FileTooLarge, editFileSplice(io, target, "x", "y"));

    const after = try readFileBytes(io, target, max_read_size + 200);
    defer std.heap.page_allocator.free(after);
    try std.testing.expectEqual(big.len, after.len);
    try std.testing.expectEqualStrings(big, after);
}

test "readFile exposes truncation on a file over 1 MB" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const target = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "big-read.txt" });
    defer gpa.free(target);

    const big = try gpa.alloc(u8, max_read_size + 100);
    defer gpa.free(big);
    @memset(big, 'x');
    try writeFileAtomic(io, target, big);

    const content = try readFileBytes(io, target, max_read_size);
    defer std.heap.page_allocator.free(content);
    try std.testing.expectEqual(@as(usize, max_read_size), content.len);
    try std.testing.expectEqual(@as(u64, big.len), try statFileSize(io, target));

    // Drive the Lua surface: read_file must expose truncated/full_size/size
    // so a plugin can detect the head-truncation and page around it (S3).
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    const lua_target = try forwardSlashDup(gpa, target);
    defer gpa.free(lua_target);
    const chunk = try std.fmt.allocPrintSentinel(gpa,
        \\local r = nova.read_file("{s}", {{}})
        \\assert(type(r) == "table", "read_file returns a table")
        \\assert(r.truncated == true, "truncated flag set for >1MB file")
        \\assert(r.full_size == {d}, "full_size is the on-disk size, got " .. tostring(r.full_size))
        \\assert(r.size <= {d}, "size is the bytes returned (capped)")
        \\assert(r.size == #r.content, "size matches content length")
        \\return "OK"
    , .{ lua_target, big.len, max_read_size }, 0);
    defer gpa.free(chunk);
    try expectLuaOk(&L, chunk);
}

test "readFile clamps a negative max_size without panicking" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const target = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "neg-max.txt" });
    defer gpa.free(target);
    try writeFileAtomic(io, target, "hello");

    // A negative max_size used to be `@intCast(v)` on the raw i64 — a cast
    // panic in safe builds, a wrap to ~2^64 in ReleaseFast. It must now clamp.
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    const lua_target = try forwardSlashDup(gpa, target);
    defer gpa.free(lua_target);
    const chunk = try std.fmt.allocPrintSentinel(gpa,
        \\local r = nova.read_file("{s}", {{ max_size = -1 }})
        \\assert(type(r) == "table", "clamped read returns a table")
        \\return "OK"
    , .{lua_target}, 0);
    defer gpa.free(chunk);
    try expectLuaOk(&L, chunk);
}

// ── nova.json_decode / nova.json_encode tests ────────────────────────
//
// Each test drives the bridge through real Lua code (doString) and asserts
// inside Lua, returning a sentinel string ("OK") on success. This avoids
// fragile manual stack inspection from Zig and exercises the exact path a
// plugin takes. A failing assertion makes doString return false, surfacing
// the Lua error message via getErrorMessage.

/// Duplicate a filesystem path replacing every backslash with a forward slash,
/// so it can be interpolated safely into a Lua string literal. A Windows path
/// like `C:\work\nova` carries `\w`/`\n` sequences that Lua mangles (or rejects
/// for invalid escapes like `\G`) when embedded verbatim. Windows accepts
/// forward slashes, so the replacement is lossless for path resolution.
fn forwardSlashDup(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, path.len);
    for (path, 0..) |byte, index| {
        out[index] = if (byte == '\\') '/' else byte;
    }
    return out;
}

/// Helper: run a Lua chunk that must end by returning the literal "OK".
/// On failure, prints the Lua error so the test failure is debuggable.
fn expectLuaOk(L: *State, chunk: [:0]const u8) !void {
    const ok = L.doString(chunk);
    if (!ok) {
        const err = L.getErrorMessage();
        std.debug.print("Lua error: {s}\n", .{err orelse "unknown"});
        L.pop(1);
        try std.testing.expect(ok);
    }
    // The chunk pushes "OK" onto the stack on success.
    var len: usize = 0;
    const ptr = c.lua_tolstring(L.handle, -1, &len);
    const got = if (ptr) |p| p[0..len] else "";
    defer c.lua_pop(L.handle, 1);
    try std.testing.expectEqualStrings("OK", got);
}

test "json_decode: object becomes Lua table" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local t = nova.json_decode('{"a": 1, "b": "hi"}')
        \\assert(type(t) == "table", "expected table")
        \\assert(t.a == 1, "a should be 1")
        \\assert(t.b == "hi", "b should be hi")
        \\return "OK"
    );
}

test "json_decode: array becomes 1-indexed table" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local arr = nova.json_decode('[10, 20, 30]')
        \\assert(arr[1] == 10, "arr[1] should be 10")
        \\assert(arr[2] == 20, "arr[2] should be 20")
        \\assert(arr[3] == 30, "arr[3] should be 30")
        \\return "OK"
    );
}

test "json_decode: primitives (null/bool/number/string)" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\assert(nova.json_decode('null') == nil, "null -> nil")
        \\assert(nova.json_decode('true') == true, "true -> true")
        \\assert(nova.json_decode('false') == false, "false -> false")
        \\assert(nova.json_decode('42') == 42, "int -> number")
        \\assert(nova.json_decode('3.5') == 3.5, "float -> number")
        \\assert(nova.json_decode('"word"') == "word", "string -> string")
        \\return "OK"
    );
}

test "json_decode: malformed input returns nil + error" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local v, err = nova.json_decode('{bad json')
        \\assert(v == nil, "malformed should yield nil")
        \\assert(type(err) == "string" and #err > 0, "error string expected")
        \\return "OK"
    );
}

test "json_encode: object table to JSON" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local s = nova.json_encode({ a = 1, b = "hi" })
        \\assert(type(s) == "string", "encode returns string")
        \\-- object key order is not guaranteed; check both pairs round-trip
        \\local back = nova.json_decode(s)
        \\assert(back.a == 1 and back.b == "hi", "round-trip preserves values")
        \\return "OK"
    );
}

test "json_encode: array table to JSON bracket" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local s = nova.json_encode({ 10, 20, 30 })
        \\assert(s:sub(1, 1) == "[", "array starts with [")
        \\assert(s:sub(-1) == "]", "array ends with ]")
        \\local back = nova.json_decode(s)
        \\assert(back[1] == 10 and back[2] == 20 and back[3] == 30, "round-trip")
        \\return "OK"
    );
}

test "json_encode: pretty option indents output" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local compact = nova.json_encode({ a = 1 })
        \\local pretty = nova.json_encode({ a = 1 }, { pretty = true })
        \\assert(not compact:find("\n", 1, true), "compact has no newline")
        \\assert(pretty:find("\n", 1, true) ~= nil, "pretty has newlines")
        \\assert(pretty:find("  ", 1, true) ~= nil, "pretty has indent")
        \\return "OK"
    );
}

test "json_encode: escapes quotes and special chars in strings" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local s = nova.json_encode({ msg = 'he said "hi"\nbye' })
        \\assert(s:find('\\"', 1, true), "quotes escaped")
        \\assert(s:find('\\n', 1, true), "newline escaped")
        \\-- round-trip must recover the original string
        \\local back = nova.json_decode(s)
        \\assert(back.msg == 'he said "hi"\nbye', "round-trip preserves escapes")
        \\return "OK"
    );
}

test "json_encode: nested table (object with array value)" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local s = nova.json_encode({ name = "x", items = { 1, 2 } })
        \\local back = nova.json_decode(s)
        \\assert(back.name == "x", "scalar field preserved")
        \\assert(type(back.items) == "table", "nested table preserved")
        \\assert(back.items[1] == 1 and back.items[2] == 2, "array preserved")
        \\return "OK"
    );
}

test "json round-trip: decode then encode preserves structure" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local original = '{"id": 7, "steps": [{"text": "a", "done": true}]}'
        \\local decoded = nova.json_decode(original)
        \\local encoded = nova.json_encode(decoded)
        \\local redecoded = nova.json_decode(encoded)
        \\assert(redecoded.id == 7, "top-level scalar preserved")
        \\assert(redecoded.steps[1].text == "a", "nested object.text preserved")
        \\assert(redecoded.steps[1].done == true, "nested object.done preserved")
        \\return "OK"
    );
}

// ── glob matcher unit tests ──────────────────────────────────────────

test "matchGlob: empty pattern matches everything" {
    try std.testing.expect(matchGlob("a.zig", ""));
    try std.testing.expect(matchGlob("src/foo.ts", ""));
}

test "matchGlob: literal pattern matches verbatim" {
    try std.testing.expect(matchGlob("main.zig", "main.zig"));
    try std.testing.expect(!matchGlob("main.zig", "main.lua"));
}

test "matchGlob: star within segment" {
    try std.testing.expect(matchGlob("main.zig", "*.zig"));
    try std.testing.expect(matchGlob("a.ts", "*.ts"));
    try std.testing.expect(!matchGlob("a.js", "*.ts"));
}

test "matchGlob: star does not cross separator" {
    try std.testing.expect(!matchGlob("src/a.ts", "*.ts"));
    try std.testing.expect(matchGlob("a.ts", "*"));
}

test "matchGlob: double-star spans directories" {
    try std.testing.expect(matchGlob("src/a.zig", "**/*.zig"));
    try std.testing.expect(matchGlob("src/nested/b.zig", "**/*.zig"));
    try std.testing.expect(matchGlob("a.zig", "**/*.zig"));
    try std.testing.expect(!matchGlob("a.lua", "**/*.zig"));
}

test "matchGlob: double-star under prefix" {
    try std.testing.expect(matchGlob("src/nested/a.ts", "src/**/*.ts"));
    try std.testing.expect(matchGlob("src/a.ts", "src/**/*.ts"));
    try std.testing.expect(!matchGlob("lib/a.ts", "src/**/*.ts"));
}

test "matchGlob: single-char question mark" {
    try std.testing.expect(matchGlob("a.ts", "?.ts"));
    try std.testing.expect(matchGlob("ab.ts", "a?.ts"));
    try std.testing.expect(!matchGlob("abc.ts", "a?.ts"));
}

test "matchGlob: trailing double-star matches remainder" {
    try std.testing.expect(matchGlob("src/a/b/c", "src/**"));
    try std.testing.expect(matchGlob("src", "src/**"));
    try std.testing.expect(!matchGlob("lib/a", "src/**"));
}

// ── P0: shell-injection regression tests ──────────────────────────────
//
// The git bridges (`gitDiff`/`gitLog`/`gitCommit`) previously embedded
// plugin-supplied strings into a `bash -c` command, letting a malicious plugin
// break out of quotes. Each test drives the exact escaping/stdin path the
// bridges now use and asserts an injection payload leaves no side effect.

/// Run a shell command, discarding its output and any error. For best-effort
/// test cleanup (`rm -rf`) where the result is irrelevant; keeps call sites a
/// single line instead of repeating the bind/deinit/discard ladder.
fn ignoreRun(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, command: []const u8) void {
    var result = bash_exec.run(gpa, io, cwd, command) catch return;
    result.deinit(gpa);
}

/// True when `git` is on PATH (so the git-backed injection tests can run).
fn gitAvailable() bool {
    if (std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "git", "--version" },
    })) |r| {
        std.testing.allocator.free(r.stdout);
        std.testing.allocator.free(r.stderr);
        return true;
    } else |_| return false;
}

/// Create an empty git repo under `/tmp/nova-inject-test`, returning the path.
/// Caller frees the path; the dir is removed via the shell. Sets a deterministic
/// identity so `git commit` does not refuse to run.
fn makeInjectionTestRepo(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const dir = try std.fs.path.join(gpa, &.{ "/tmp", "nova-inject-test" });
    errdefer gpa.free(dir);
    ignoreRun(gpa, io, "/tmp", "rm -rf nova-inject-test");
    var result = try bash_exec.run(
        gpa,
        io,
        "/tmp",
        "mkdir -p nova-inject-test && git -C nova-inject-test init -q && " ++
            "git -C nova-inject-test config user.email t@t && " ++
            "git -C nova-inject-test config user.name t",
    );
    result.deinit(gpa);
    return dir;
}

/// True iff the file at `absolute_path` exists. Routed through the shell so the
/// test does not depend on a specific Dir API name for absolute paths.
fn fileExists(gpa: std.mem.Allocator, io: std.Io, absolute_path: []const u8) bool {
    const cmd = std.fmt.allocPrint(gpa, "test -f {s}", .{absolute_path}) catch return false;
    defer gpa.free(cmd);
    var result = bash_exec.run(gpa, io, "/tmp", cmd) catch return false;
    defer result.deinit(gpa);
    return result.code == 0;
}

test "shellQuote: plain argument is wrapped in single quotes" {
    const gpa = std.testing.allocator;
    const quoted = try quoteShellArg(gpa, "src/main.zig", false);
    defer gpa.free(quoted);
    try std.testing.expectEqualStrings("'src/main.zig'", quoted);
}

test "shellQuote: embedded quote is escaped (injection vector neutralized)" {
    const gpa = std.testing.allocator;
    const quoted = try quoteShellArg(gpa, "x'; rm -rf ~; #", false);
    defer gpa.free(quoted);
    try std.testing.expectEqualStrings("'x'\\''; rm -rf ~; #'", quoted);
}

test "shellQuote: empty argument becomes two quotes" {
    const gpa = std.testing.allocator;
    const quoted = try quoteShellArg(gpa, "", false);
    defer gpa.free(quoted);
    try std.testing.expectEqualStrings("''", quoted);
}

test "gitCommit: injection payload stays a literal commit message (stdin path)" {
    // Gate on OS first (before gitAvailable): on Windows these tests spawn a
    // real `bash`/git via bash_exec with /tmp paths, which is unsupported.
    if (os.is_windows) return error.SkipZigTest;
    if (!gitAvailable()) return;

    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = try makeInjectionTestRepo(gpa, io);
    defer {
        ignoreRun(gpa, io, "/tmp", "rm -rf nova-inject-test");
        gpa.free(dir);
    }

    // The injection vector from the plan: a quote-break-out attempt. With the
    // old `-m "{msg}"` it would run `touch /tmp/pwned_nova`; with `-F -` +
    // stdin it must become the literal commit subject.
    const marker = "/tmp/pwned_nova_commit";
    ignoreRun(gpa, io, "/tmp", "rm -f pwned_nova_commit");
    const payload = "x\"; touch " ++ marker ++ "; #";
    var result = try bash_exec.runWithOptions(gpa, io, .{
        .cwd = dir,
        .command = "git add -A && git commit -F -",
        .stdin = payload,
    });
    result.deinit(gpa);

    // The marker file must NOT exist: the payload never reached the shell.
    try std.testing.expect(!fileExists(gpa, io, marker));
    ignoreRun(gpa, io, "/tmp", "rm -f pwned_nova_commit");
}

test "gitDiff: injection payload stays a literal pathspec (shellQuote path)" {
    // See gitCommit: OS-gate first so it's counted as skipped on Windows.
    if (os.is_windows) return error.SkipZigTest;
    if (!gitAvailable()) return;

    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = try makeInjectionTestRepo(gpa, io);
    defer {
        ignoreRun(gpa, io, "/tmp", "rm -rf nova-inject-test");
        gpa.free(dir);
    }

    // A commit so `git diff` has something to diff against.
    var setup = try bash_exec.run(gpa, io, dir, "echo a > f && git add -A && git commit -q -m init");
    setup.deinit(gpa);

    const marker = "/tmp/pwned_nova_diff";
    ignoreRun(gpa, io, "/tmp", "rm -f pwned_nova_diff");
    // The quote-break-out payload, funneled through `shellQuote` exactly as
    // `gitDiff` does, must become one inert pathspec.
    const quoted = try quoteShellArg(gpa, "x'; touch " ++ marker ++ "; #", false);
    defer gpa.free(quoted);
    const cmd = try std.fmt.allocPrint(gpa, "git diff -- {s}", .{quoted});
    defer gpa.free(cmd);
    var result = try bash_exec.runWithOptions(gpa, io, .{
        .cwd = dir,
        .command = cmd,
    });
    result.deinit(gpa);

    try std.testing.expect(!fileExists(gpa, io, marker));
    ignoreRun(gpa, io, "/tmp", "rm -f pwned_nova_diff");
}

test "RunOptions.stdin bypasses shell interpretation" {
    // The stdin path passes the payload verbatim to the child, so shell
    // metacharacters in it are data, not syntax. Confirm `cat` echoes the
    // payload untouched (no command-substitution, no quoting collapse).
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var result = try bash_exec.runWithOptions(gpa, std.testing.io, .{
        .cwd = cwd,
        .command = "cat",
        .stdin = "a$(touch /tmp/pwned_nova_stdin)b",
    });
    defer result.deinit(gpa);
    try std.testing.expectEqualStrings("a$(touch /tmp/pwned_nova_stdin)b", result.stdout);
    ignoreRun(gpa, std.testing.io, "/tmp", "rm -f pwned_nova_stdin");
}

// ── B2-Zig: negative table integers clamp before the u32 cast ───────

test "searchFiles clamps a negative max_results without panicking" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    // A negative max_results used to be `@intCast(v)` on the raw i64 — a cast
    // panic in safe builds. It must now clamp to 1 and return a normal result.
    try expectLuaOk(&L,
        \\local r = nova.search_files(".", "no-such-pattern-xyz", { max_results = -1 })
        \\assert(type(r) == "table", "clamped search returns a table")
        \\return "OK"
    );
}

test "findFiles clamps a negative max_results without panicking" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local r = nova.find_files(".", "no-such-glob-xyz", { max_results = -1 })
        \\assert(type(r) == "table", "clamped find returns a table")
        \\return "OK"
    );
}

test "runBash clamps a negative timeout without panicking" {
    if (os.is_windows) return error.SkipZigTest;
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local r = nova.run_bash("true", { timeout = -1 })
        \\assert(type(r) == "table", "clamped run_bash returns a table")
        \\assert(r.code == 0, "true exits 0")
        \\return "OK"
    );
}

test "runBash pipes opts.stdin to the child (P4)" {
    if (os.is_windows) return error.SkipZigTest;
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local r = nova.run_bash("cat", { stdin = "hello stdin" })
        \\assert(type(r) == "table", "stdin run returns a table")
        \\assert(r.stdout == "hello stdin", "stdout echoes stdin: " .. tostring(r.stdout))
        \\assert(r.code == 0, "cat exits 0")
        \\
        \\-- No stdin: the child's stdin is simply absent/closed.
        \\local r2 = nova.run_bash("printf ok")
        \\assert(r2.stdout == "ok", "plain run unaffected")
        \\return "OK"
    );
}

// ── shell safety gate (P5) ───────────────────────────────────────────

test "runBash blocks unsafe commands via the local matcher (P5)" {
    // No classifier URL configured (null slot): the always-armed local
    // matcher must still block destructive commands.
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    bridge.bash_classifier_url_slot = null;
    try expectLuaOk(&L,
        \\local r, err = nova.run_bash("rm -rf /")
        \\assert(r == nil, "unsafe command returns nil")
        \\assert(string.find(err, "UnsafeShellBlocked", 1, true) ~= nil, "error carries UnsafeShellBlocked: " .. tostring(err))
        \\return "OK"
    );
}

test "runBash safety gate holds with a configured-but-unreachable classifier (P5)" {
    // classify falls back to the local matcher on fetch failure, so an
    // unreachable URL blocks locally-matched destructive commands just the
    // same; safe commands are unaffected with the slot set. NOTE: the local
    // matcher covers root-target deletion forms (`rm -rf /`-class), not every
    // destructive spelling — the remote classifier covers the full surface.
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    const prev = bridge.bash_classifier_url_slot;
    defer bridge.bash_classifier_url_slot = prev;
    bridge.bash_classifier_url_slot = "http://127.0.0.1:1/classify";
    if (os.is_windows) return error.SkipZigTest;

    try expectLuaOk(&L,
        \\local r, err = nova.run_bash("rm -rf /")
        \\assert(r == nil, "locally-matched unsafe command still blocked with a down classifier")
        \\assert(string.find(err, "UnsafeShellBlocked", 1, true) ~= nil, "got: " .. tostring(err))
        \\local ok = nova.run_bash("printf fine")
        \\assert(type(ok) == "table" and ok.stdout == "fine", "safe command passes")
        \\return "OK"
    );
}

test "runBash and run_shell reject an empty command before any spawn (P5)" {
    // The guard is backend-independent and fires before classify and before
    // either backend's command.len > 0 assert.
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local r1, e1 = nova.run_bash("")
        \\assert(r1 == nil, "empty command returns nil")
        \\assert(e1 == "command argument must not be empty", "got: " .. tostring(e1))
        \\local r2, e2 = nova.run_shell("")
        \\assert(r2 == nil and e2 == "command argument must not be empty", "run_shell guards too")
        \\return "OK"
    );
}

// ── shell_quote + ShellUnavailable mapping (P7) ──────────────────────

test "quoteShellArg posix and pwsh rules" {
    const gpa = std.testing.allocator;

    // POSIX: wrap in '...', escape ' as '\''.
    {
        const q = try quoteShellArg(gpa, "a'b", false);
        defer gpa.free(q);
        try std.testing.expectEqualStrings("'a'\\''b'", q);
    }
    {
        const q = try quoteShellArg(gpa, "", false);
        defer gpa.free(q);
        try std.testing.expectEqualStrings("''", q);
    }
    {
        const q = try quoteShellArg(gpa, "plain", false);
        defer gpa.free(q);
        try std.testing.expectEqualStrings("'plain'", q);
    }

    // pwsh: wrap in '...', double ' as ''.
    {
        const q = try quoteShellArg(gpa, "a'b", true);
        defer gpa.free(q);
        try std.testing.expectEqualStrings("'a''b'", q);
    }
    {
        const q = try quoteShellArg(gpa, "plain", true);
        defer gpa.free(q);
        try std.testing.expectEqualStrings("'plain'", q);
    }
}

test "quoteShellArg posix output survives a real shell round-trip" {
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const original = "it's a $HOME `test` \"double\"";

    const q = try quoteShellArg(gpa, original, false);
    defer gpa.free(q);
    const command = try std.fmt.allocPrint(gpa, "printf %s {s}", .{q});
    defer gpa.free(command);
    var r = try bash_exec.runWithOptions(gpa, std.testing.io, .{ .cwd = "/tmp", .command = command });
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings(original, r.stdout);
    try std.testing.expect(r.code == 0);
}

test "shellBackendErrorMessage maps only FileNotFound" {
    try std.testing.expect(std.mem.indexOf(u8, shellBackendErrorMessage(error.FileNotFound, .bash), "ShellUnavailable: bash not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, shellBackendErrorMessage(error.FileNotFound, .pwsh), "ShellUnavailable: pwsh not found") != null);
    try std.testing.expectEqualStrings("Timeout", shellBackendErrorMessage(error.Timeout, .bash));
    try std.testing.expectEqualStrings("StreamTooLong", shellBackendErrorMessage(error.StreamTooLong, .pwsh));
}

test "nova.shell_quote dialects and error contract (P7)" {
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\assert(nova.shell_quote("a'b") == "'a'\\''b'", "default is posix")
        \\assert(nova.shell_quote("a'b", "posix") == "'a'\\''b'")
        \\assert(nova.shell_quote("") == "''", "empty string quotes to ''")
        \\assert(nova.shell_quote(nil, "posix") == nil, "missing string arg: nil+err")
        \\
        \\-- On POSIX, native == posix; the pwsh doubling rule is only
        \\-- observable on Windows (covered by a Windows-gated test).
        \\local native = nova.shell_quote("x y", "native")
        \\assert(native == "'x y'", "native == posix on POSIX")
        \\
        \\local v, err = nova.shell_quote("x", "bogus")
        \\assert(v == nil, "unknown dialect yields nil")
        \\assert(err == "shell_quote: dialect must be \"posix\" or \"native\"", "got: " .. tostring(err))
        \\return "OK"
    );
}

test "nova.shell_quote native dispatches to pwsh rules on Windows (P7)" {
    if (!os.is_windows) return error.SkipZigTest;
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\assert(nova.shell_quote("a'b", "native") == "'a''b'", "pwsh doubles quotes")
        \\return "OK"
    );
}

// ── M-symlink: sanitizePath realpath re-check ────────────────────────

test "sanitizePath rejects a symlink escaping the project root" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    // The tmp dir lives under <cwd>/.zig-cache/tmp/<sub>; create a symlink
    // inside it pointing at /tmp (outside the project root).
    const link_dir = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(link_dir);
    const link_path = try std.fs.path.join(gpa, &.{ link_dir, "escape" });
    defer gpa.free(link_path);
    std.Io.Dir.cwd().createDirPath(io, link_dir) catch {};
    const link_z = try std.fmt.allocPrintSentinel(gpa, "{s}", .{link_path}, 0);
    defer gpa.free(link_z);
    const target_z = try std.fmt.allocPrintSentinel(gpa, "{s}", .{"/tmp"}, 0);
    defer gpa.free(target_z);
    _ = std.c.symlink(target_z, link_z); // skip if symlink unsupported

    // Create a real file in /tmp so realpath resolves the final component.
    const marker = try std.fmt.allocPrintSentinel(gpa, "{s}", .{"/tmp/nova_symlink_marker"}, 0);
    defer gpa.free(marker);
    var mf = std.Io.Dir.createFileAbsolute(io, "/tmp/nova_symlink_marker", .{}) catch return;
    mf.close(io);
    defer std.Io.Dir.deleteFileAbsolute(io, "/tmp/nova_symlink_marker") catch {};

    // Reading through the symlink must be rejected.
    const target = try std.fs.path.join(gpa, &.{ link_path, "nova_symlink_marker" });
    defer gpa.free(target);
    try std.testing.expectError(error.PathTraversal, sanitizePath(io, target));
}

test "sanitizePath allows a nonexistent new-file path (realpath-failure fallback)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const dir = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const new_file = try std.fs.path.join(gpa, &.{ dir, "brand-new.txt" });
    defer gpa.free(new_file);

    // The file does not exist yet; realpath fails and the lexical verdict holds.
    const resolved = try sanitizePath(io, new_file);
    defer std.heap.page_allocator.free(resolved);
    try std.testing.expect(std.mem.endsWith(u8, resolved, "brand-new.txt"));
}

// ── S4: git bridges return nil + error outside a repo ────────────────
//
// The bridges previously pushed only stdout, so in a non-repo dir `git status
// --porcelain` exited 128 with empty stdout and the plugin received "" instead
// of nil — the nil-check in git-tools never fired and the model was told the
// tree was clean. These tests drive the real git binary (a hard dependency of
// the bridge) in a temp dir that is NOT a repo, and in a fresh repo.

test "gitStatus returns nil + error outside a repo" {
    // See gitCommit: OS-gate first so it's counted as skipped on Windows.
    if (os.is_windows) return error.SkipZigTest;
    if (!gitAvailable()) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = try std.fs.path.join(gpa, &.{ "/tmp", "nova-git-notrepo" });
    defer gpa.free(dir);
    ignoreRun(gpa, io, "/tmp", "rm -rf nova-git-notrepo && mkdir -p nova-git-notrepo");

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    // The bridge runs git in cwd (repo root), which IS a repo here. To test the
    // non-repo path we invoke the underlying command in the temp dir directly.
    var result = try bash_exec.run(gpa, io, dir, "git status --porcelain");
    defer result.deinit(gpa);
    try std.testing.expect(result.code != 0);
    try std.testing.expect(result.stdout.len == 0);
    const err = gitErrorString(result.stderr, result.code);
    try std.testing.expect(err.len > 0);
    ignoreRun(gpa, io, "/tmp", "rm -rf nova-git-notrepo");
}

test "gitErrorString prefers stderr over generic exit code" {
    try std.testing.expectEqualStrings("fatal: not a git repository", gitErrorString("fatal: not a git repository\n", 128));
    try std.testing.expect(std.mem.indexOf(u8, gitErrorString("", 128), "code 128") != null);
}

test "git bridges return strings inside a repo (S4 success path)" {
    // See gitCommit: OS-gate first so it's counted as skipped on Windows.
    if (os.is_windows) return error.SkipZigTest;
    if (!gitAvailable()) return;
    // The test process runs at the repo root, which IS a git repo, so all four
    // bridges must return strings here (the nil+error path is covered by the
    // non-repo test above).
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, std.testing.io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    try expectLuaOk(&L,
        \\local s = nova.git_status()
        \\assert(type(s) == "string", "git_status returns a string in a repo, got " .. type(s))
        \\local d = nova.git_diff()
        \\assert(type(d) == "string", "git_diff returns a string in a repo, got " .. type(d))
        \\local l = nova.git_log(1)
        \\assert(type(l) == "string", "git_log returns a string in a repo, got " .. type(l))
        \\local b = nova.git_branch()
        \\assert(type(b) == "string", "git_branch returns a string in a repo, got " .. type(b))
        \\return "OK"
    );
}

test "plugin_api: deletePath removes regular file, empty dir, and recursive tree" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);

    const test_base = ".zig-cache/test_delete_path_fixture";
    std.Io.Dir.cwd().deleteTree(io, test_base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, test_base);
    defer std.Io.Dir.cwd().deleteTree(io, test_base) catch {};

    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    // 1. Create and delete regular file
    const file_rel = test_base ++ "/sample.txt";
    var file = try std.Io.Dir.cwd().createFile(io, file_rel, .{});
    file.close(io);

    try expectLuaOk(&L,
        \\local ok, err = nova.delete_path(".zig-cache/test_delete_path_fixture/sample.txt")
        \\assert(ok == true, "delete file failed: " .. tostring(err))
        \\return "OK"
    );

    // 2. Create and delete empty directory
    const dir_rel = test_base ++ "/empty_dir";
    try std.Io.Dir.cwd().createDirPath(io, dir_rel);

    try expectLuaOk(&L,
        \\local ok, err = nova.delete_path(".zig-cache/test_delete_path_fixture/empty_dir")
        \\assert(ok == true, "delete empty dir failed: " .. tostring(err))
        \\return "OK"
    );

    // 3. Create and delete recursive tree
    const tree_rel = test_base ++ "/tree_dir";
    try std.Io.Dir.cwd().createDirPath(io, tree_rel ++ "/sub");
    var subfile = try std.Io.Dir.cwd().createFile(io, tree_rel ++ "/sub/nested.txt", .{});
    subfile.close(io);

    try expectLuaOk(&L,
        \\local ok, err = nova.delete_path(".zig-cache/test_delete_path_fixture/tree_dir", { recursive = true })
        \\assert(ok == true, "delete tree failed: " .. tostring(err))
        \\return "OK"
    );
}

test "plugin_api: sanitizePath respects bridge.plugin_cwd_slot" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const fake_worktree = ".zig-cache/test_fake_worktree";
    std.Io.Dir.cwd().deleteTree(io, fake_worktree) catch {};
    try std.Io.Dir.cwd().createDirPath(io, fake_worktree);
    defer std.Io.Dir.cwd().deleteTree(io, fake_worktree) catch {};

    const abs_worktree = try std.fs.path.resolve(gpa, &.{fake_worktree});
    defer gpa.free(abs_worktree);

    bridge.plugin_cwd_slot = abs_worktree;
    defer {
        bridge.plugin_cwd_slot = null;
    }

    const sanitized = try sanitizePath(io, "file.txt");
    defer std.heap.page_allocator.free(sanitized);

    try std.testing.expect(std.mem.startsWith(u8, sanitized, abs_worktree));
}

test "plugin_api: findGitRoot finds directory .git and file .git worktree" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);

    const test_dir = ".zig-cache/test_git_root_fixture";
    std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, test_dir);
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    // 1. Directory .git
    const dir_repo = test_dir ++ "/dir_repo";
    try std.Io.Dir.cwd().createDirPath(io, dir_repo ++ "/.git");
    try std.Io.Dir.cwd().createDirPath(io, dir_repo ++ "/src/nested");

    const abs_dir_nested = try std.fs.path.resolve(gpa, &.{ root, dir_repo ++ "/src/nested" });
    defer gpa.free(abs_dir_nested);

    const root1 = try findGitRoot(io, abs_dir_nested);
    defer std.heap.page_allocator.free(root1);

    const abs_dir_repo = try std.fs.path.resolve(gpa, &.{ root, dir_repo });
    defer gpa.free(abs_dir_repo);
    try std.testing.expectEqualStrings(abs_dir_repo, root1);

    // 2. File .git (worktree mock)
    const file_repo = test_dir ++ "/file_repo";
    try std.Io.Dir.cwd().createDirPath(io, file_repo ++ "/src/nested");
    var gitfile = try std.Io.Dir.cwd().createFile(io, file_repo ++ "/.git", .{});
    gitfile.close(io);

    const abs_file_nested = try std.fs.path.resolve(gpa, &.{ root, file_repo ++ "/src/nested" });
    defer gpa.free(abs_file_nested);

    const root2 = try findGitRoot(io, abs_file_nested);
    defer std.heap.page_allocator.free(root2);

    const abs_file_repo = try std.fs.path.resolve(gpa, &.{ root, file_repo });
    defer gpa.free(abs_file_repo);
    try std.testing.expectEqualStrings(abs_file_repo, root2);
}

test "plugin_api: globMatchSegment handles Windows backslashes and forward slashes interchangeably" {
    // 1. Windows path with forward-slash glob pattern
    try std.testing.expect(globMatchSegment("src\\tools\\bash.zig", "src/**/*.zig"));
    try std.testing.expect(globMatchSegment("src\\tools\\bash.zig", "src/*/*.zig"));
    try std.testing.expect(globMatchSegment("src\\tools\\bash.zig", "**/*.zig"));
    try std.testing.expect(globMatchSegment("src\\tools\\bash.zig", "src/tools/bash.zig"));

    // 2. Windows path with backslash glob pattern
    try std.testing.expect(globMatchSegment("src\\tools\\bash.zig", "src\\**\\*.zig"));
    try std.testing.expect(globMatchSegment("src\\tools\\bash.zig", "src\\*\\*.zig"));

    // 3. POSIX path with forward-slash pattern
    try std.testing.expect(globMatchSegment("src/tools/bash.zig", "src/**/*.zig"));
    try std.testing.expect(globMatchSegment("src/tools/bash.zig", "**/*.zig"));

    // 4. Non-matching paths
    try std.testing.expect(!globMatchSegment("src\\tools\\bash.zig", "src/*.zig"));
    try std.testing.expect(!globMatchSegment("src\\tools\\bash.zig", "lib/**/*.zig"));
}

test "plugin_api: run_shell executes native shell on current OS" {
    const io = std.testing.io;
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{ .allow_os_execute = true }, io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    try expectLuaOk(&L,
        \\local res, err = nova.run_shell("echo nova_shell_ok")
        \\assert(res ~= nil, "run_shell failed: " .. tostring(err))
        \\assert(res.code == 0, "run_shell exited with non-zero code: " .. tostring(res.code))
        \\assert(string.find(res.stdout, "nova_shell_ok") ~= nil, "stdout did not contain expected message: " .. tostring(res.stdout))
        \\return "OK"
    );
}

test "plugin_api: nova.require loads modules, caches results, and rejects breakouts" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);

    const test_plugin_dir = ".zig-cache/test_multi_file_plugin";
    std.Io.Dir.cwd().deleteTree(io, test_plugin_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, test_plugin_dir);
    defer std.Io.Dir.cwd().deleteTree(io, test_plugin_dir) catch {};

    // 1. Create helper.lua
    var buf: [4096]u8 = undefined;
    var helper_file = try std.Io.Dir.cwd().createFile(io, test_plugin_dir ++ "/helper.lua", .{});
    var w1 = helper_file.writer(io, &buf);
    try w1.interface.writeAll(
        \\local M = { count = 1 }
        \\function M.add(a, b) return a + b end
        \\return M
    );
    try w1.interface.flush();
    helper_file.close(io);

    // 2. Create submod/init.lua
    try std.Io.Dir.cwd().createDirPath(io, test_plugin_dir ++ "/submod");
    var submod_file = try std.Io.Dir.cwd().createFile(io, test_plugin_dir ++ "/submod/init.lua", .{});
    var w2 = submod_file.writer(io, &buf);
    try w2.interface.writeAll(
        \\return { name = "submodule" }
    );
    try w2.interface.flush();
    submod_file.close(io);

    const abs_plugin_dir = try std.fs.path.resolve(gpa, &.{ root, test_plugin_dir });
    defer gpa.free(abs_plugin_dir);

    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    // Set plugin directory in registry
    _ = c.lua_pushlstring(L.handle, abs_plugin_dir.ptr, abs_plugin_dir.len);
    c.lua_setfield(L.handle, c.LUA_REGISTRYINDEX, "nova_plugin_dir");

    // Test relative require and caching
    try expectLuaOk(&L,
        \\local helper1 = nova.require("./helper")
        \\assert(type(helper1) == "table", "expected table, got " .. type(helper1))
        \\assert(helper1.add(10, 20) == 30, "add failed")
        \\
        \\-- Modify table to verify caching
        \\helper1.count = 42
        \\local helper2 = nova.require("helper.lua")
        \\assert(helper2.count == 42, "cache failed: did not get same instance")
        \\
        \\-- Require submod/init.lua
        \\local submod = nova.require("submod")
        \\assert(submod.name == "submodule", "submod require failed")
        \\
        \\-- Reject breakout attempt
        \\local outside, err = nova.require("../outside")
        \\assert(outside == nil, "breakout should have failed")
        \\assert(string.find(err, "access denied") ~= nil, "unexpected error: " .. tostring(err))
        \\
        \\return "OK"
    );
}

test "plugin_api: nova.git_add and selective nova.git_commit validate arguments" {
    const io = std.testing.io;
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    // git_add requires files argument
    try expectLuaOk(&L,
        \\local ok, err = nova.git_add()
        \\assert(ok == nil, "git_add without args should fail")
        \\assert(string.find(err, "files argument is required") ~= nil, "unexpected error: " .. tostring(err))
        \\
        \\local ok2, err2 = nova.git_commit()
        \\assert(ok2 == nil, "git_commit without message should fail")
        \\assert(string.find(err2, "commit message argument is required") ~= nil, "unexpected error: " .. tostring(err2))
        \\
        \\return "OK"
    );
}

// ── plugin.get_config (P1) ───────────────────────────────────────────

/// Seed the settings registry slot exactly the way `PluginManager.loadOne`
/// does: `lua_pushlstring` (copies into the Lua GC) + `lua_setfield`.
fn seedSettingsSlot(L: *State, json: []const u8) void {
    _ = c.lua_pushlstring(L.handle, json.ptr, json.len);
    _ = c.lua_setfield(L.handle, c.LUA_REGISTRYINDEX, sandbox_mod.settings_registry_key);
}

test "plugin.get_config decodes object settings into a fresh table" {
    const io = std.testing.io;
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    seedSettingsSlot(&L, "{\"theme\":\"dark\",\"retries\":3}");

    try expectLuaOk(&L,
        \\local cfg = plugin.get_config()
        \\assert(type(cfg) == "table", "settings decode to a table")
        \\assert(cfg.theme == "dark", "string field readable")
        \\assert(cfg.retries == 3, "number field readable")
        \\cfg.theme = "mutated"
        \\local cfg2 = plugin.get_config()
        \\assert(cfg2.theme == "dark", "fresh table per call: mutation does not leak")
        \\return "OK"
    );
}

test "plugin.get_config returns nil when unconfigured" {
    const io = std.testing.io;
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }
    // No settings slot seeded — the unconfigured default.
    try expectLuaOk(&L,
        \\assert(plugin.get_config() == nil, "unconfigured plugin gets nil")
        \\return "OK"
    );
}

test "plugin.get_config rejects malformed and non-object settings" {
    const io = std.testing.io;
    const sandbox = @import("sandbox.zig");
    var L = try sandbox.createSandboxedStateWithIo(.{}, io);
    defer {
        sandbox.freeHookData(L.handle);
        L.deinit();
    }

    seedSettingsSlot(&L, "not json at all");
    try expectLuaOk(&L,
        \\local v, err = plugin.get_config()
        \\assert(v == nil, "malformed settings yield nil")
        \\assert(err == "get_config: settings must be a JSON object", "got: " .. tostring(err))
        \\return "OK"
    );

    // A JSON scalar also decodes to a Lua value — the object check must
    // reject it before the push.
    seedSettingsSlot(&L, "42");
    try expectLuaOk(&L,
        \\local v, err = plugin.get_config()
        \\assert(v == nil, "scalar settings yield nil")
        \\assert(err == "get_config: settings must be a JSON object", "got: " .. tostring(err))
        \\return "OK"
    );

    // A JSON array decodes to a Lua table — it must be rejected too.
    seedSettingsSlot(&L, "[1,2]");
    try expectLuaOk(&L,
        \\local v, err = plugin.get_config()
        \\assert(v == nil, "array settings yield nil")
        \\assert(err == "get_config: settings must be a JSON object", "got: " .. tostring(err))
        \\return "OK"
    );
}
