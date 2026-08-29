//! Plugin prompt injection — optional `prompt.md` per plugin.
//!
//! Each plugin directory MAY ship a `prompt.md` describing how the model
//! should use that plugin's tools. The body (frontmatter stripped) is
//! injected into the AI model's system prompt as a `<plugin_prompts>` block,
//! mirroring the `SKILL.md` → `<available_skills>` flow. The scan is pure
//! text — no Lua state is created here — so it runs early in `initSession`,
//! before the full `PluginManager` exists.

const std = @import("std");
const os = @import("os.zig");

const assert = std.debug.assert;

const skill_mod = @import("skill.zig");

const log = std.log.scoped(.plugin_prompt);

/// Per-plugin limit on a `prompt.md` body (32 KB per plugin).
pub const max_body_bytes: u32 = 32 * 1024;

/// Maximum aggregate bytes of all plugin prompt bodies combined (64 KB).
pub const max_aggregate_prompt_bytes: usize = 64 * 1024;

/// One plugin's prompt text, ready to render into the system prompt.
///
/// `name` is the plugin directory name (the key the user sees in
/// `~/.config/nova/plugins/<name>`). `body` is the markdown with any
/// frontmatter fence stripped. All fields are owned by the caller's `gpa`
/// and freed via `deinit`.
pub const PluginPrompt = struct {
    name: []u8,
    body: []u8,
    path: []u8,

    const Self = @This();

    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.body);
        gpa.free(self.path);
        self.* = undefined;
    }
};

/// Discover and load every plugin's `prompt.md` across both plugin roots.
///
/// Scans `<home_dir>/.config/nova/plugins/<plugin>/prompt.md` first, then
/// `<cwd>/.nova/plugins/<plugin>/prompt.md`. A project entry with the same
/// directory name overrides the global one (matching `PluginManager`'s
/// load order). Plugins without a `prompt.md`, or whose body is empty after
/// frontmatter stripping, are silently skipped — a missing or blank prompt
/// is not an error.
pub fn loadAll(
    gpa: std.mem.Allocator,
    io: std.Io,
    home_dir: []const u8,
    cwd: []const u8,
) ![]PluginPrompt {
    var prompts: std.ArrayList(PluginPrompt) = .empty;
    errdefer deinitAll(gpa, prompts.items);

    const global_parts = [_][]const u8{ ".config", "nova", "plugins" };
    const project_parts = [_][]const u8{ ".nova", "plugins" };
    if (os.is_windows and home_dir.len > 0) {
        const appdata_parts = [_][]const u8{ "AppData", "Roaming", "nova", "plugins" };
        try scanRoot(gpa, io, home_dir, &appdata_parts, &prompts);
    }
    try scanRoot(gpa, io, home_dir, &global_parts, &prompts);
    try scanRoot(gpa, io, cwd, &project_parts, &prompts);

    return prompts.toOwnedSlice(gpa);
}

/// Render loaded plugin prompts into a system-prompt fragment.
///
/// Returns an empty string when there are no prompts so callers can append
/// unconditionally. The output opens with a one-line preamble and wraps each
/// prompt in `<plugin_prompts>` / `<plugin>` tags, parallel to
/// `skill_mod.formatForPrompt`. Enforces the aggregate plugin prompt budget (64 KB).
pub fn formatForPrompt(gpa: std.mem.Allocator, prompts: []const PluginPrompt) ![]u8 {
    if (prompts.len == 0) return gpa.alloc(u8, 0);

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();

    try out.writer.writeAll("\n\nThe following plugins provide tools. Use their instructions to call the tools correctly.\n\n");
    try out.writer.writeAll("<plugin_prompts>\n");
    var total_bytes: usize = 0;
    for (prompts) |prompt| {
        assert(prompt.name.len > 0);
        assert(prompt.body.len > 0);
        if (total_bytes + prompt.body.len <= max_aggregate_prompt_bytes) {
            try out.writer.writeAll("  <plugin name=\"");
            try skill_mod.writeXmlEscaped(&out.writer, prompt.name);
            try out.writer.writeAll("\">\n");
            // The body is untrusted (a plugin author's prompt.md); escape it so a
            // `</plugin>` / `</plugin_prompts>` inside cannot break out of the block.
            try skill_mod.writeXmlEscaped(&out.writer, prompt.body);
            try out.writer.writeAll("\n  </plugin>\n");
            total_bytes += prompt.body.len;
        } else {
            try out.writer.writeAll("  <plugin name=\"");
            try skill_mod.writeXmlEscaped(&out.writer, prompt.name);
            try out.writer.writeAll("\" error=\"aggregate plugin prompt budget exhausted (64 KB)\"></plugin>\n");
            total_bytes = max_aggregate_prompt_bytes;
        }
    }
    try out.writer.writeAll("</plugin_prompts>");
    return out.toOwnedSlice();
}

pub fn deinitAll(gpa: std.mem.Allocator, prompts: []PluginPrompt) void {
    for (prompts) |*prompt| prompt.deinit(gpa);
    gpa.free(prompts);
}

/// Deep-copy a prompt slice for lane isolation (a sub-lane gets its own
/// copy so teardown of one lane never frees another's strings). Mirrors
/// `skill_mod.cloneAll`.
pub fn cloneAll(gpa: std.mem.Allocator, prompts: []const PluginPrompt) ![]PluginPrompt {
    if (prompts.len == 0) return &.{};

    var out = try gpa.alloc(PluginPrompt, prompts.len);
    errdefer gpa.free(out);
    var built: usize = 0;
    errdefer for (out[0..built]) |*p| p.deinit(gpa);

    for (prompts, 0..) |prompt, i| {
        const name = try gpa.dupe(u8, prompt.name);
        errdefer gpa.free(name);
        const body = try gpa.dupe(u8, prompt.body);
        errdefer gpa.free(body);
        const path = try gpa.dupe(u8, prompt.path);
        out[i] = .{
            .name = name,
            .body = body,
            .path = path,
        };
        built = i + 1;
    }
    return out;
}

/// Scan one plugin root (`<root>/<parts...>/<plugin>/prompt.md`) and append
/// any loaded prompts to `out`. A plugin whose directory name already has a
/// prompt in `out` overrides the earlier entry (project shadows global),
/// freeing the displaced one.
fn scanRoot(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    parts: []const []const u8,
    out: *std.ArrayList(PluginPrompt),
) !void {
    if (root.len == 0) return;

    var dir_path_buf: std.ArrayList(u8) = .empty;
    defer dir_path_buf.deinit(gpa);
    try dir_path_buf.appendSlice(gpa, root);
    for (parts) |part| {
        try dir_path_buf.append(gpa, std.fs.path.sep);
        try dir_path_buf.appendSlice(gpa, part);
    }

    var dir = std.Io.Dir.openDir(.cwd(), io, dir_path_buf.items, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;

        const plugin_dir = try std.fs.path.join(gpa, &.{ dir_path_buf.items, entry.name });
        defer gpa.free(plugin_dir);
        const prompt_path = try std.fs.path.join(gpa, &.{ plugin_dir, "prompt.md" });
        defer gpa.free(prompt_path);

        if (loadOne(gpa, io, prompt_path, entry.name)) |prompt| {
            replaceOrAppend(gpa, out, prompt) catch |err| {
                var mut = prompt;
                mut.deinit(gpa);
                return err;
            };
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => log.warn("skipping plugin prompt {s}: {s}", .{ prompt_path, @errorName(err) }),
        }
    }
}

/// Read one `prompt.md`, strip frontmatter, and return a `PluginPrompt`
/// named after its directory. `error.FileNotFound` lets the caller skip
/// plugins that ship no prompt. An empty body after stripping is treated
/// as "nothing to say" and returns `error.FileNotFound` so the caller's
/// skip path stays uniform.
fn loadOne(gpa: std.mem.Allocator, io: std.Io, path: []const u8, plugin_name: []const u8) !PluginPrompt {
    const file = try std.Io.Dir.openFile(.cwd(), io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > max_body_bytes) return error.FileTooBig;
    if (stat.size == 0) return error.FileNotFound;

    const raw = try gpa.alloc(u8, @intCast(stat.size));
    errdefer gpa.free(raw);
    var reader = file.reader(io, &.{});
    try reader.interface.readSliceAll(raw);

    const body = skill_mod.stripFrontmatter(raw);
    if (body.len == 0) {
        gpa.free(raw);
        return error.FileNotFound;
    }

    const body_owned = try gpa.dupe(u8, body);
    gpa.free(raw);
    errdefer gpa.free(body_owned);

    return .{
        .name = try gpa.dupe(u8, plugin_name),
        .body = body_owned,
        .path = try gpa.dupe(u8, path),
    };
}

/// If `out` already holds a prompt with the same name, free and replace it
/// (project root shadows global); otherwise append. Keeps the caller's
/// override semantics in one place.
fn replaceOrAppend(gpa: std.mem.Allocator, out: *std.ArrayList(PluginPrompt), prompt: PluginPrompt) !void {
    for (out.items) |*existing| {
        if (std.mem.eql(u8, existing.name, prompt.name)) {
            existing.deinit(gpa);
            existing.* = prompt;
            return;
        }
    }
    try out.append(gpa, prompt);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "loadAll finds prompt.md and strips frontmatter" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);

    const rel_dir = ".zig-cache/plugin-prompt-test";
    const plugins_dir = rel_dir ++ "/.nova/plugins/write-tool";
    try std.Io.Dir.createDirPath(.cwd(), io, plugins_dir);

    var file = try std.Io.Dir.createFile(.cwd(), io, plugins_dir ++ "/prompt.md", .{ .truncate = true });
    defer file.close(io);
    var buf: [256]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll("---\ndescription: Write files.\n---\nCall this tool to create or overwrite a file.\nPrefer it over bash for edits.");
    try writer.interface.flush();

    const cwd = try std.fs.path.join(gpa, &.{ root, rel_dir });
    defer gpa.free(cwd);

    const prompts = try loadAll(gpa, io, "", cwd);
    defer deinitAll(gpa, prompts);

    try std.testing.expectEqual(@as(usize, 1), prompts.len);
    try std.testing.expectEqualStrings("write-tool", prompts[0].name);
    try std.testing.expect(std.mem.indexOf(u8, prompts[0].body, "Call this tool to create") != null);
    // Frontmatter must be stripped.
    try std.testing.expect(std.mem.indexOf(u8, prompts[0].body, "description:") == null);
}

test "loadAll skips plugins without prompt.md" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);

    const rel_dir = ".zig-cache/plugin-prompt-noop-test";
    try std.Io.Dir.createDirPath(.cwd(), io, rel_dir ++ "/.nova/plugins/no-prompt");

    const cwd = try std.fs.path.join(gpa, &.{ root, rel_dir });
    defer gpa.free(cwd);

    const prompts = try loadAll(gpa, io, "", cwd);
    defer deinitAll(gpa, prompts);
    try std.testing.expectEqual(@as(usize, 0), prompts.len);
}

test "loadAll: project overrides global with same plugin name" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);

    const rel_dir = ".zig-cache/plugin-prompt-override-test";
    // Global plugin dir.
    const global_plugins = rel_dir ++ "/global/.config/nova/plugins/shared";
    try std.Io.Dir.createDirPath(.cwd(), io, global_plugins);
    var gfile = try std.Io.Dir.createFile(.cwd(), io, global_plugins ++ "/prompt.md", .{ .truncate = true });
    defer gfile.close(io);
    var gbuf: [128]u8 = undefined;
    var gw = gfile.writer(io, &gbuf);
    try gw.interface.writeAll("Global instructions.");
    try gw.interface.flush();

    // Project plugin dir with the same name.
    const proj_plugins = rel_dir ++ "/project/.nova/plugins/shared";
    try std.Io.Dir.createDirPath(.cwd(), io, proj_plugins);
    var pfile = try std.Io.Dir.createFile(.cwd(), io, proj_plugins ++ "/prompt.md", .{ .truncate = true });
    defer pfile.close(io);
    var pbuf: [128]u8 = undefined;
    var pw = pfile.writer(io, &pbuf);
    try pw.interface.writeAll("Project instructions override.");
    try pw.interface.flush();

    const global_home = try std.fs.path.join(gpa, &.{ root, rel_dir, "global" });
    defer gpa.free(global_home);
    const cwd = try std.fs.path.join(gpa, &.{ root, rel_dir, "project" });
    defer gpa.free(cwd);

    const prompts = try loadAll(gpa, io, global_home, cwd);
    defer deinitAll(gpa, prompts);

    try std.testing.expectEqual(@as(usize, 1), prompts.len);
    try std.testing.expectEqualStrings("Project instructions override.", prompts[0].body);
}

test "formatForPrompt emits plugin_prompts block" {
    const gpa = std.testing.allocator;

    var prompts = try gpa.alloc(PluginPrompt, 1);
    prompts[0] = .{
        .name = try gpa.dupe(u8, "write-tool"),
        .body = try gpa.dupe(u8, "Always confirm overwrite."),
        .path = try gpa.dupe(u8, "/tmp/prompt.md"),
    };
    defer deinitAll(gpa, prompts);

    const text = try formatForPrompt(gpa, prompts);
    defer gpa.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "<plugin_prompts>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<plugin name=\"write-tool\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Always confirm overwrite.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "</plugin_prompts>") != null);
}

test "formatForPrompt returns empty for no prompts" {
    const gpa = std.testing.allocator;
    const text = try formatForPrompt(gpa, &.{});
    defer gpa.free(text);
    try std.testing.expectEqual(@as(usize, 0), text.len);
}

test "plugin prompt body cannot break out of the plugin block" {
    const gpa = std.testing.allocator;

    var prompts = try gpa.alloc(PluginPrompt, 1);
    prompts[0] = .{
        .name = try gpa.dupe(u8, "write-tool"),
        .body = try gpa.dupe(u8, "before </plugin> after"),
        .path = try gpa.dupe(u8, "/tmp/prompt.md"),
    };
    defer deinitAll(gpa, prompts);

    const text = try formatForPrompt(gpa, prompts);
    defer gpa.free(text);
    // The breakout sequence from the body must be escaped, never raw.
    try std.testing.expect(std.mem.indexOf(u8, text, "&lt;/plugin&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "before </plugin> after") == null);
}

test "cloneAll produces independent copies" {
    const gpa = std.testing.allocator;

    var src = try gpa.alloc(PluginPrompt, 1);
    src[0] = .{
        .name = try gpa.dupe(u8, "p"),
        .body = try gpa.dupe(u8, "body"),
        .path = try gpa.dupe(u8, "/p/prompt.md"),
    };
    defer deinitAll(gpa, src);

    const clone = try cloneAll(gpa, src);
    defer deinitAll(gpa, clone);

    try std.testing.expectEqual(@as(usize, 1), clone.len);
    try std.testing.expectEqualStrings("p", clone[0].name);
    try std.testing.expect(clone[0].body.ptr != src[0].body.ptr);
}

test "loadOne rejects prompt.md exceeding max_body_bytes (32 KB)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);

    const rel_dir = ".zig-cache/plugin-prompt-oversized-test";
    const plugins_dir = rel_dir ++ "/.nova/plugins/big-plugin";
    try std.Io.Dir.createDirPath(.cwd(), io, plugins_dir);

    const prompt_path = plugins_dir ++ "/prompt.md";
    var file = try std.Io.Dir.createFile(.cwd(), io, prompt_path, .{ .truncate = true });
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    const chunk = "a" ** 1024;
    var written: usize = 0;
    while (written <= max_body_bytes) : (written += chunk.len) {
        try writer.interface.writeAll(chunk);
    }
    try writer.interface.flush();
    file.close(io);

    const full_path = try std.fs.path.join(gpa, &.{ root, prompt_path });
    defer gpa.free(full_path);

    try std.testing.expectError(error.FileTooBig, loadOne(gpa, io, full_path, "big-plugin"));
}

test "formatForPrompt enforces 64 KB aggregate cap and emits omission notice" {
    const gpa = std.testing.allocator;

    var prompts = try gpa.alloc(PluginPrompt, 3);
    defer deinitAll(gpa, prompts);

    // Plugin 1: 30 KB
    const body1 = try gpa.alloc(u8, 30 * 1024);
    @memset(body1, 'a');
    prompts[0] = .{
        .name = try gpa.dupe(u8, "plugin-1"),
        .body = body1,
        .path = try gpa.dupe(u8, "/tmp/p1.md"),
    };

    // Plugin 2: 30 KB (cumulative = 60 KB <= 64 KB)
    const body2 = try gpa.alloc(u8, 30 * 1024);
    @memset(body2, 'b');
    prompts[1] = .{
        .name = try gpa.dupe(u8, "plugin-2"),
        .body = body2,
        .path = try gpa.dupe(u8, "/tmp/p2.md"),
    };

    // Plugin 3: 10 KB (cumulative would be 70 KB > 64 KB -> omitted with error)
    const body3 = try gpa.alloc(u8, 10 * 1024);
    @memset(body3, 'c');
    prompts[2] = .{
        .name = try gpa.dupe(u8, "plugin-3"),
        .body = body3,
        .path = try gpa.dupe(u8, "/tmp/p3.md"),
    };

    const text = try formatForPrompt(gpa, prompts);
    defer gpa.free(text);

    // Plugin 1 and Plugin 2 are rendered with content
    try std.testing.expect(std.mem.indexOf(u8, text, "<plugin name=\"plugin-1\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<plugin name=\"plugin-2\">") != null);
    // Plugin 3 is omitted with error attribute
    try std.testing.expect(std.mem.indexOf(u8, text, "<plugin name=\"plugin-3\" error=\"aggregate plugin prompt budget exhausted (64 KB)\"></plugin>") != null);
}
