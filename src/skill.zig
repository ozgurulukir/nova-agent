//! Project skill discovery, prompt formatting, and explicit invocation expansion.
const std = @import("std");

const assert = std.debug.assert;
const log = std.log.scoped(.skill);

pub const Skill = struct {
    name: []u8,
    description: []u8,
    path: []u8,
    base_dir: []u8,
    /// Frontmatter-stripped body, loaded once in `loadOne`. Cached here so
    /// `appendSkillBlock` (called every turn via `promptPrefix`) never re-reads
    /// the file from disk — `path` is kept only for diagnostics / listing.
    body: []u8,
    disable_model_invocation: bool = false,

    pub fn deinit(self: *Skill, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.description);
        gpa.free(self.path);
        gpa.free(self.base_dir);
        gpa.free(self.body);
        self.* = undefined;
    }
};

pub const skill_name_max_bytes: usize = 64;
pub const max_skill_depth: u32 = 8;
pub const max_total_invocation_bytes: usize = 256 * 1024;

pub fn loadProject(gpa: std.mem.Allocator, io: std.Io, home_dir: ?[]const u8, cwd: []const u8) ![]Skill {
    assert(cwd.len > 0);
    var skills: std.ArrayList(Skill) = .empty;
    errdefer {
        for (skills.items) |*skill| skill.deinit(gpa);
        skills.deinit(gpa);
    }

    if (home_dir) |home| if (home.len > 0) {
        const global_root = try std.fs.path.join(gpa, &.{ home, ".agents", "skills" });
        defer gpa.free(global_root);
        try loadFromDir(gpa, io, global_root, true, &skills, 0);
    };
    // Boundary index: entries at [0, global_count) come from the global root,
    // entries at [global_count, …) from the project root.
    const global_count = skills.items.len;
    const project_root = try std.fs.path.join(gpa, &.{ cwd, ".agents", "skills" });
    defer gpa.free(project_root);
    try loadFromDir(gpa, io, project_root, true, &skills, 0);

    shadowDuplicates(gpa, &skills, global_count);
    warnDuplicateNames(skills.items);
    return skills.toOwnedSlice(gpa);
}

/// Project entries (appended later) displace same-name global entries,
/// mirroring `plugin_prompt.replaceOrAppend` semantics (TD-9).
fn shadowDuplicates(gpa: std.mem.Allocator, skills: *std.ArrayList(Skill), global_count: usize) void {
    // Only a project entry (index >= global_count at scan time) displaces a
    // same-name global entry. Two same-name project (or two global) entries
    // are both kept — first-wins for `find`, warned by `warnDuplicateNames`.
    var i: usize = 0;
    while (i < global_count and i < skills.items.len) {
        var j: usize = global_count;
        while (j < skills.items.len) {
            if (std.ascii.eqlIgnoreCase(skills.items[i].name, skills.items[j].name)) {
                skills.items[i].deinit(gpa);
                skills.items[i] = skills.items[j];
                _ = skills.orderedRemove(j);
                break;
            }
            j += 1;
        }
        i += 1;
    }
}

/// Post-load duplicate scan: warn on case-insensitive collisions (TD-7).
fn warnDuplicateNames(skills: []const Skill) void {
    for (skills, 0..) |skill, i| {
        for (skills[i + 1 ..]) |other| {
            if (std.ascii.eqlIgnoreCase(skill.name, other.name)) {
                log.warn("duplicate skill name '{s}': {s} shadows {s}", .{ skill.name, skill.path, other.path });
            }
        }
    }
}

pub fn deinitAll(gpa: std.mem.Allocator, skills: []Skill) void {
    for (skills) |*skill| skill.deinit(gpa);
    gpa.free(skills);
}

/// Deep-copy a loaded skill list. Lanes reuse the primary's skills (same
/// project) rather than re-scanning the filesystem; each runtime owns its copy.
pub fn cloneAll(gpa: std.mem.Allocator, skills: []const Skill) ![]Skill {
    const out = try gpa.alloc(Skill, skills.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |*skill| skill.deinit(gpa);
        gpa.free(out);
    }
    for (skills, 0..) |skill, i| {
        const name = try gpa.dupe(u8, skill.name);
        errdefer gpa.free(name);
        const description = try gpa.dupe(u8, skill.description);
        errdefer gpa.free(description);
        const path = try gpa.dupe(u8, skill.path);
        errdefer gpa.free(path);
        const base_dir = try gpa.dupe(u8, skill.base_dir);
        errdefer gpa.free(base_dir);
        const body = try gpa.dupe(u8, skill.body);
        errdefer gpa.free(body);
        out[i] = .{
            .name = name,
            .description = description,
            .path = path,
            .base_dir = base_dir,
            .body = body,
            .disable_model_invocation = skill.disable_model_invocation,
        };
        done = i + 1;
    }
    return out;
}

pub fn formatForPrompt(gpa: std.mem.Allocator, skills: []const Skill) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();

    var visible: u32 = 0;
    for (skills) |skill| {
        if (!skill.disable_model_invocation) visible += 1;
    }
    if (visible == 0) return out.toOwnedSlice();

    // Markdown (not XML) — keeps the model from echoing literal <skill> tags back as text.
    // No `location` path is published: the model must invoke a skill via the `skill` tool
    // rather than `cat`-ing the file. Skill bodies can still reference each other once injected.
    try out.writer.writeAll("\n\nThe following skills provide specialized instructions for specific tasks.\n");
    try out.writer.writeAll("When a task matches a skill's description, use the `skill` tool with its name (e.g. `{\"name\": \"<skill-name>\"}`) to load its full instructions into context.\n\n");
    try out.writer.writeAll("<available_skills>\n");
    for (skills) |skill| {
        if (skill.disable_model_invocation) continue;
        try out.writer.writeAll("- **");
        try writeXmlEscaped(&out.writer, skill.name);
        try out.writer.writeAll("** — ");
        try writeXmlEscaped(&out.writer, skill.description);
        try out.writer.writeAll("\n");
    }
    try out.writer.writeAll("</available_skills>");
    return out.toOwnedSlice();
}

/// One line per loaded skill: `name — description (path)`. Empty slice -> "no skills loaded".
pub fn formatSkillsList(gpa: std.mem.Allocator, skills: []const Skill) ![]u8 {
    if (skills.len == 0) return gpa.dupe(u8, "no skills loaded");

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (skills) |skill| {
        try out.writer.print("{s} — {s} ({s})\n", .{ skill.name, skill.description, skill.path });
    }
    return out.toOwnedSlice();
}

pub fn activeQuery(before_cursor: []const u8) ?struct { start: usize, query: []const u8 } {
    var index: usize = before_cursor.len;
    while (index > 0) : (index -= 1) {
        const byte = before_cursor[index - 1];
        if (isBoundary(byte)) return null;
        if (byte == '$') {
            const start = index - 1;
            if (start == 0 or isBoundary(before_cursor[start - 1])) {
                return .{ .start = start, .query = before_cursor[start + 1 ..] };
            }
            return null;
        }
    }
    return null;
}

pub fn filterNames(gpa: std.mem.Allocator, skills: []const Skill, query: []const u8) ![][]const u8 {
    var results: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (results.items) |item| gpa.free(item);
        results.deinit(gpa);
    }
    const max_results = 50;
    for (skills) |skill| {
        if (results.items.len >= max_results) break;
        if (query.len > 0) {
            if (std.ascii.indexOfIgnoreCase(skill.name, query) == null) continue;
        }
        try results.append(gpa, try gpa.dupe(u8, skill.name));
    }
    return results.toOwnedSlice(gpa);
}

pub fn promptPrefix(gpa: std.mem.Allocator, skills: []const Skill, prompt: []const u8) ![]u8 {
    const names = try collectInvocations(gpa, skills, prompt);
    defer gpa.free(names);
    if (names.len == 0) return gpa.dupe(u8, "");

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var remaining: usize = max_total_invocation_bytes;
    for (names) |name| {
        const skill = find(skills, name) orelse continue;
        appendSkillBlock(&out.writer, skill, &remaining) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try out.writer.print("[skill '{s}' could not be loaded: {s}]\n\n", .{ name, @errorName(err) });
            if (err == error.SkillBudgetExhausted) break;
            continue;
        };
        try out.writer.writeAll("\n\n");
    }
    return out.toOwnedSlice();
}

/// Extract skill names from `<skill name="…"` markers previously injected by
/// `appendSkillBlock` — used to rebuild `[SKILL]` transcript rows on resume (TD-14).
pub fn collectInjectedSkillNames(gpa: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }

    const marker = "<skill name=\"";
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_from, marker)) |start| {
        const name_start = start + marker.len;
        const end = std.mem.indexOfScalarPos(u8, text, name_start, '"') orelse break;
        if (end > name_start) {
            try names.append(gpa, try gpa.dupe(u8, text[name_start..end]));
        }
        search_from = end + 1;
    }
    return names.toOwnedSlice(gpa);
}

pub fn collectInvocations(gpa: std.mem.Allocator, skills: []const Skill, prompt: []const u8) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(gpa);

    var index: usize = 0;
    while (index < prompt.len) {
        const at_boundary = index == 0 or isBoundary(prompt[index - 1]);
        if (prompt[index] == '$' and at_boundary) {
            var end = index + 1;
            while (end < prompt.len and !isBoundary(prompt[end])) end += 1;
            const name = trimTrailingPunctuation(prompt[index + 1 .. end]);
            if (name.len > 0 and find(skills, name) != null and !contains(names.items, name)) {
                try names.append(gpa, name);
            }
            index = end;
        } else {
            index += 1;
        }
    }
    return names.toOwnedSlice(gpa);
}

pub fn find(skills: []const Skill, name: []const u8) ?*const Skill {
    for (skills) |*skill| {
        if (std.ascii.eqlIgnoreCase(skill.name, name)) return skill;
    }
    return null;
}

fn loadFromDir(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8, include_root_files: bool, skills: *std.ArrayList(Skill), depth: u32) !void {
    var dir = std.Io.Dir.openDir(.cwd(), io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir => return,
        else => return err,
    };
    defer dir.close(io);

    const skill_path = try std.fs.path.join(gpa, &.{ dir_path, "SKILL.md" });
    defer gpa.free(skill_path);
    if (loadOne(gpa, io, skill_path)) |skill| {
        try skills.append(gpa, skill);
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn("skipping skill {s}: {s}", .{ skill_path, @errorName(err) }),
    }

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.name.len == 0) continue;
        if (entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "node_modules")) continue;
        const child = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
        defer gpa.free(child);
        switch (entry.kind) {
            .directory => try loadFromDir(gpa, io, child, false, skills, depth),
            .file => if (include_root_files and std.mem.endsWith(u8, entry.name, ".md")) {
                if (loadOne(gpa, io, child)) |skill| {
                    try skills.append(gpa, skill);
                } else |err| switch (err) {
                    error.FileNotFound => {},
                    else => log.warn("skipping skill {s}: {s}", .{ child, @errorName(err) }),
                }
            },
            .sym_link => {
                if (depth >= max_skill_depth) {
                    log.warn("skill symlink too deep, skipping: {s}", .{child});
                    continue;
                }
                // stat follows the link; dispatch on the target's kind.
                const st = dir.statFile(io, entry.name, .{}) catch continue;
                if (st.kind == .directory) {
                    try loadFromDir(gpa, io, child, false, skills, depth + 1);
                } else if (include_root_files and std.mem.endsWith(u8, entry.name, ".md")) {
                    if (loadOne(gpa, io, child)) |skill| {
                        try skills.append(gpa, skill);
                    } else |err| switch (err) {
                        error.FileNotFound => {},
                        else => log.warn("skipping skill {s}: {s}", .{ child, @errorName(err) }),
                    }
                }
            },
            else => {},
        }
    }
}

fn loadOne(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Skill {
    const file = try std.Io.Dir.openFile(.cwd(), io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > 256 * 1024) return error.FileTooBig;
    const raw = try gpa.alloc(u8, @intCast(stat.size));
    defer gpa.free(raw); // success and error paths both free (TD-1)
    var reader = file.reader(io, &.{});
    try reader.interface.readSliceAll(raw);
    const frontmatter = parseFrontmatter(raw);
    const description = frontmatterValue(frontmatter, "description") orelse return error.MissingDescription;
    if (isBlockScalarIndicator(description)) return error.BlockScalarUnsupported;
    const basename = std.fs.path.basename(path);
    const fallback = if (std.mem.eql(u8, basename, "SKILL.md"))
        std.fs.path.basename(std.fs.path.dirname(path) orelse path) // dir-named skill
    else
        std.fs.path.stem(path); // loose .md file
    const name_value = frontmatterValue(frontmatter, "name") orelse fallback;
    if (!isValidSkillName(name_value)) return error.InvalidSkillName;
    const base_dir = std.fs.path.dirname(path) orelse ".";
    // `stripFrontmatter` returns a sub-slice of `raw`, which is freed in this
    // function's defer — so the body must be duped into owned storage on the Skill.
    const body = try gpa.dupe(u8, stripFrontmatter(raw));
    errdefer gpa.free(body);
    return .{
        .name = try gpa.dupe(u8, name_value),
        .description = try gpa.dupe(u8, description),
        .path = try gpa.dupe(u8, path),
        .base_dir = try gpa.dupe(u8, base_dir),
        .body = body,
        .disable_model_invocation = frontmatterBool(frontmatter, "disable-model-invocation"),
    };
}

fn isValidSkillName(name: []const u8) bool {
    if (name.len == 0 or name.len > skill_name_max_bytes) return false;
    for (name) |byte| {
        // Whitespace and $ break the $token invocation grammar.
        // XML-special chars are rejected so appendSkillBlock's escaping stays
        // belt-and-braces and collectInjectedSkillNames needs no unescaping (TD-14).
        if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == '$') return false;
        if (byte == '"' or byte == '\'' or byte == '&' or byte == '<' or byte == '>') return false;
    }
    return true;
}

fn isBlockScalarIndicator(value: []const u8) bool {
    for ([_][]const u8{ "|", ">", "|-", ">-", "|+", ">+" }) |indicator| {
        if (std.mem.eql(u8, value, indicator)) return true;
    }
    return false;
}

/// Byte length of the opening `---` fence line, tolerating both LF and CRLF
/// line endings (SKILL.md authored on Windows ships as CRLF), or null when the
/// input does not open with a frontmatter fence.
fn frontmatterOpenLen(raw: []const u8) ?u32 {
    if (std.mem.startsWith(u8, raw, "---\r\n")) return 5;
    if (std.mem.startsWith(u8, raw, "---\n")) return 4;
    return null;
}

fn parseFrontmatter(raw: []const u8) []const u8 {
    const open_len = frontmatterOpenLen(raw) orelse return "";
    const rest = raw[open_len..];
    // `\n---` matches the closing fence under both LF and CRLF; any trailing
    // `\r` on a value line is stripped by `frontmatterValue`.
    const end = std.mem.indexOf(u8, rest, "\n---") orelse return "";
    return rest[0..end];
}

fn frontmatterValue(frontmatter: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, frontmatter, '\n');
    while (lines.next()) |line| {
        // YAML top-level keys are unindented; skip indented lines so nested
        // keys (e.g. `metadata:\n  description: …`) can't shadow the real value.
        if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const found = std.mem.trim(u8, line[0..colon], " \t\r");
        if (!std.mem.eql(u8, found, key)) continue;
        return stripQuotes(std.mem.trim(u8, line[colon + 1 ..], " \t\r"));
    }
    return null;
}

fn frontmatterBool(frontmatter: []const u8, key: []const u8) bool {
    const value = frontmatterValue(frontmatter, key) orelse return false;
    return std.ascii.eqlIgnoreCase(value, "true");
}

fn stripQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') return value[1 .. value.len - 1];
    if (value.len >= 2 and value[0] == '\'' and value[value.len - 1] == '\'') return value[1 .. value.len - 1];
    return value;
}

fn appendSkillBlock(writer: *std.Io.Writer, skill: *const Skill, remaining: *usize) !void {
    // Body is cached on the Skill since `loadOne` — no per-turn disk read.
    // `max_total_invocation_bytes` is shared by `formatForPrompt`, so guard on it too.
    if (skill.body.len > max_total_invocation_bytes) return error.FileTooBig;
    const body = skill.body;
    if (body.len > remaining.*) return error.SkillBudgetExhausted; // checked BEFORE write
    remaining.* -= body.len;
    try writer.writeAll("<skill name=\"");
    try writeXmlEscaped(writer, skill.name);
    try writer.writeAll("\" location=\"");
    try writeXmlEscaped(writer, skill.path);
    try writer.writeAll("\">\n");
    try writer.print("References are relative to {s}.\n\n", .{skill.base_dir});
    try writer.writeAll(body);
    try writer.writeAll("\n</skill>");
}

/// Public so `plugin_prompt.zig` can reuse the exact same body extraction
/// logic (frontmatter → markdown body) for `prompt.md` files.
pub fn stripFrontmatter(raw: []const u8) []const u8 {
    const open_len = frontmatterOpenLen(raw) orelse return raw;
    const rest = raw[open_len..];
    const end = std.mem.indexOf(u8, rest, "\n---") orelse return raw;
    const after_fence = rest[end + 4 ..];
    // Drop the remainder of the closing fence line (LF or CRLF) so the body
    // starts on its own line.
    const newline = std.mem.indexOfScalar(u8, after_fence, '\n') orelse return "";
    return after_fence[newline + 1 ..];
}

test "frontmatter parses CRLF line endings" {
    const raw = "---\r\nname: demo\r\ndescription: \"a demo skill\"\r\n---\r\nbody line\r\n";
    const frontmatter = parseFrontmatter(raw);
    try std.testing.expectEqualStrings("demo", frontmatterValue(frontmatter, "name").?);
    try std.testing.expectEqualStrings("a demo skill", frontmatterValue(frontmatter, "description").?);
    try std.testing.expectEqualStrings("body line\r\n", stripFrontmatter(raw));
}

test "frontmatter parses LF line endings" {
    const raw = "---\nname: demo\ndescription: d\n---\nbody\n";
    const frontmatter = parseFrontmatter(raw);
    try std.testing.expectEqualStrings("demo", frontmatterValue(frontmatter, "name").?);
    try std.testing.expectEqualStrings("d", frontmatterValue(frontmatter, "description").?);
    try std.testing.expectEqualStrings("body\n", stripFrontmatter(raw));
}

// Regression: a value containing a colon must keep everything after the FIRST
// colon (frontmatterValue splits on indexOfScalar(':'); only the key is split,
// not the value). `description: rule: a and b` -> "rule: a and b".
test "frontmatter preserves colons inside a value" {
    const raw = "---\nname: demo\ndescription: rule: a and b\n---\nbody\n";
    const frontmatter = parseFrontmatter(raw);
    try std.testing.expectEqualStrings("rule: a and b", frontmatterValue(frontmatter, "description").?);
}

/// Public so `plugin_prompt.zig` can reuse XML escaping for the
/// `<plugin_prompts>` block it emits into the system prompt.
pub fn writeXmlEscaped(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| {
        switch (byte) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&apos;"),
            else => try writer.writeByte(byte),
        }
    }
}

fn isBoundary(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn trimTrailingPunctuation(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0) : (end -= 1) {
        switch (value[end - 1]) {
            '.', ',', ';', ':', '!', '?' => {},
            else => break,
        }
    }
    return value[0..end];
}

fn contains(values: []const []const u8, candidate: []const u8) bool {
    for (values) |value| {
        if (std.ascii.eqlIgnoreCase(value, candidate)) return true;
    }
    return false;
}

test "activeQuery detects dollar skill token" {
    const active = activeQuery("use $tiger").?;
    try std.testing.expectEqual(@as(usize, 4), active.start);
    try std.testing.expectEqualStrings("tiger", active.query);
}

test "collectInvocations finds known skills only" {
    const gpa = std.testing.allocator;
    const skills = [_]Skill{.{ .name = @constCast("how"), .description = @constCast("d"), .path = @constCast("p"), .base_dir = @constCast("."), .body = @constCast("") }};
    const names = try collectInvocations(gpa, &skills, "$how and $missing");
    defer gpa.free(names);
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("how", names[0]);
}

test "collectInvocations matches skill names case-insensitively" {
    const gpa = std.testing.allocator;
    const skills = [_]Skill{.{ .name = @constCast("tiger"), .description = @constCast("d"), .path = @constCast("p"), .base_dir = @constCast("."), .body = @constCast("") }};
    const names = try collectInvocations(gpa, &skills, "$Tiger");
    defer gpa.free(names);
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("Tiger", names[0]);
}

test "frontmatter ignores indented nested keys" {
    const raw = "---\nmetadata:\n  description: nested wrong\ndescription: real description\n---\nbody\n";
    const frontmatter = parseFrontmatter(raw);
    try std.testing.expectEqualStrings("real description", frontmatterValue(frontmatter, "description").?);
}

test "loose root skill falls back to its file stem name" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);
    const rel_dir = ".zig-cache/skill-stem-test";
    const full_dir = try std.fs.path.join(gpa, &.{ root, rel_dir });
    defer gpa.free(full_dir);
    const agents_dir = try std.fs.path.join(gpa, &.{ full_dir, ".agents", "skills" });
    defer gpa.free(agents_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, agents_dir);

    const md_path = try std.fs.path.join(gpa, &.{ agents_dir, "tips.md" });
    defer gpa.free(md_path);
    var file = try std.Io.Dir.createFile(.cwd(), io, md_path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, "---\ndescription: tips skill\n---\nbody\n");

    const skills = try loadProject(gpa, io, null, full_dir);
    defer deinitAll(gpa, skills);
    try std.testing.expectEqual(@as(usize, 1), skills.len);
    try std.testing.expectEqualStrings("tips", skills[0].name);
}

test "block scalar description skips the skill" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);
    const rel_dir = ".zig-cache/skill-block-scalar-test";
    const full_dir = try std.fs.path.join(gpa, &.{ root, rel_dir });
    defer gpa.free(full_dir);
    const agents_dir = try std.fs.path.join(gpa, &.{ full_dir, ".agents", "skills" });
    defer gpa.free(agents_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, agents_dir);

    // Block scalar skill: description: |
    const bad_dir = try std.fs.path.join(gpa, &.{ agents_dir, "badskill" });
    defer gpa.free(bad_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, bad_dir);
    const bad_md = try std.fs.path.join(gpa, &.{ bad_dir, "SKILL.md" });
    defer gpa.free(bad_md);
    var bad_file = try std.Io.Dir.createFile(.cwd(), io, bad_md, .{ .truncate = true });
    defer bad_file.close(io);
    try bad_file.writeStreamingAll(io, "---\nname: badskill\ndescription: |\n  some multiline text\n---\nbody\n");

    // Valid sibling
    const good_dir = try std.fs.path.join(gpa, &.{ agents_dir, "goodskill" });
    defer gpa.free(good_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, good_dir);
    const good_md = try std.fs.path.join(gpa, &.{ good_dir, "SKILL.md" });
    defer gpa.free(good_md);
    var good_file = try std.Io.Dir.createFile(.cwd(), io, good_md, .{ .truncate = true });
    defer good_file.close(io);
    try good_file.writeStreamingAll(io, "---\nname: goodskill\ndescription: good skill\n---\nbody\n");

    const skills = try loadProject(gpa, io, null, full_dir);
    defer deinitAll(gpa, skills);
    try std.testing.expectEqual(@as(usize, 1), skills.len);
    try std.testing.expectEqualStrings("goodskill", skills[0].name);
}

test "loadProject skips skills with invalid names" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);
    const rel_dir = ".zig-cache/skill-invalid-name-test";
    const full_dir = try std.fs.path.join(gpa, &.{ root, rel_dir });
    defer gpa.free(full_dir);
    const agents_dir = try std.fs.path.join(gpa, &.{ full_dir, ".agents", "skills" });
    defer gpa.free(agents_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, agents_dir);

    // Invalid: name with space
    const space_dir = try std.fs.path.join(gpa, &.{ agents_dir, "spacey" });
    defer gpa.free(space_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, space_dir);
    const space_md = try std.fs.path.join(gpa, &.{ space_dir, "SKILL.md" });
    defer gpa.free(space_md);
    var space_file = try std.Io.Dir.createFile(.cwd(), io, space_md, .{ .truncate = true });
    defer space_file.close(io);
    try space_file.writeStreamingAll(io, "---\nname: My Skill\ndescription: d\n---\nbody\n");

    // Invalid: name with $
    const dollar_dir = try std.fs.path.join(gpa, &.{ agents_dir, "dollar" });
    defer gpa.free(dollar_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, dollar_dir);
    const dollar_md = try std.fs.path.join(gpa, &.{ dollar_dir, "SKILL.md" });
    defer gpa.free(dollar_md);
    var dollar_file = try std.Io.Dir.createFile(.cwd(), io, dollar_md, .{ .truncate = true });
    defer dollar_file.close(io);
    try dollar_file.writeStreamingAll(io, "---\nname: a$b\ndescription: d\n---\nbody\n");

    // Invalid: too long (65 x's)
    const long_dir = try std.fs.path.join(gpa, &.{ agents_dir, "long" });
    defer gpa.free(long_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, long_dir);
    const long_md = try std.fs.path.join(gpa, &.{ long_dir, "SKILL.md" });
    defer gpa.free(long_md);
    var long_file = try std.Io.Dir.createFile(.cwd(), io, long_md, .{ .truncate = true });
    defer long_file.close(io);
    try long_file.writeStreamingAll(io, "---\nname: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\ndescription: d\n---\nbody\n");

    // Valid sibling
    const good_dir = try std.fs.path.join(gpa, &.{ agents_dir, "goodskill" });
    defer gpa.free(good_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, good_dir);
    const good_md = try std.fs.path.join(gpa, &.{ good_dir, "SKILL.md" });
    defer gpa.free(good_md);
    var good_file = try std.Io.Dir.createFile(.cwd(), io, good_md, .{ .truncate = true });
    defer good_file.close(io);
    try good_file.writeStreamingAll(io, "---\nname: goodskill\ndescription: good skill\n---\nbody\n");

    const skills = try loadProject(gpa, io, null, full_dir);
    defer deinitAll(gpa, skills);
    try std.testing.expectEqual(@as(usize, 1), skills.len);
    try std.testing.expectEqualStrings("goodskill", skills[0].name);
}

test "duplicate skill names keep the first occurrence" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);
    const rel_dir = ".zig-cache/skill-dupe-test";
    const full_dir = try std.fs.path.join(gpa, &.{ root, rel_dir });
    defer gpa.free(full_dir);
    const agents_dir = try std.fs.path.join(gpa, &.{ full_dir, ".agents", "skills" });
    defer gpa.free(agents_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, agents_dir);

    const dir1 = try std.fs.path.join(gpa, &.{ agents_dir, "dupe1" });
    defer gpa.free(dir1);
    try std.Io.Dir.createDirPath(.cwd(), io, dir1);
    const md1 = try std.fs.path.join(gpa, &.{ dir1, "SKILL.md" });
    defer gpa.free(md1);
    var f1 = try std.Io.Dir.createFile(.cwd(), io, md1, .{ .truncate = true });
    defer f1.close(io);
    try f1.writeStreamingAll(io, "---\nname: samename\ndescription: first\n---\nbody1\n");

    const dir2 = try std.fs.path.join(gpa, &.{ agents_dir, "dupe2" });
    defer gpa.free(dir2);
    try std.Io.Dir.createDirPath(.cwd(), io, dir2);
    const md2 = try std.fs.path.join(gpa, &.{ dir2, "SKILL.md" });
    defer gpa.free(md2);
    var f2 = try std.Io.Dir.createFile(.cwd(), io, md2, .{ .truncate = true });
    defer f2.close(io);
    try f2.writeStreamingAll(io, "---\nname: samename\ndescription: second\n---\nbody2\n");

    const skills = try loadProject(gpa, io, null, full_dir);
    defer deinitAll(gpa, skills);
    try std.testing.expectEqual(@as(usize, 2), skills.len);
    const found = find(skills, "samename").?;
    try std.testing.expectEqualStrings("first", found.description);
}

test "loadProject follows symlinked skill directories" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);
    const rel_dir = ".zig-cache/skill-symlink-test";
    const full_dir = try std.fs.path.join(gpa, &.{ root, rel_dir });
    defer gpa.free(full_dir);
    const agents_dir = try std.fs.path.join(gpa, &.{ full_dir, ".agents", "skills" });
    defer gpa.free(agents_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, agents_dir);

    const external_dir = try std.fs.path.join(gpa, &.{ full_dir, "external-skill" });
    defer gpa.free(external_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, external_dir);
    const external_md = try std.fs.path.join(gpa, &.{ external_dir, "SKILL.md" });
    defer gpa.free(external_md);
    var f = try std.Io.Dir.createFile(.cwd(), io, external_md, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, "---\nname: linkedskill\ndescription: linked skill\n---\nbody\n");

    const link_path = try std.fs.path.join(gpa, &.{ agents_dir, "linked" });
    defer gpa.free(link_path);
    std.Io.Dir.symLink(.cwd(), io, external_dir, link_path, .{ .is_directory = true }) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const skills = try loadProject(gpa, io, null, full_dir);
    defer deinitAll(gpa, skills);
    try std.testing.expectEqual(@as(usize, 1), skills.len);
    try std.testing.expectEqualStrings("linkedskill", skills[0].name);
}

test "project skill shadows same-name global skill" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);
    const rel_dir = ".zig-cache/skill-shadow-test";
    const full_dir = try std.fs.path.join(gpa, &.{ root, rel_dir });
    defer gpa.free(full_dir);

    const home_dir = try std.fs.path.join(gpa, &.{ full_dir, "home" });
    defer gpa.free(home_dir);
    const global_agents = try std.fs.path.join(gpa, &.{ home_dir, ".agents", "skills" });
    defer gpa.free(global_agents);
    try std.Io.Dir.createDirPath(.cwd(), io, global_agents);

    const global_skill_dir = try std.fs.path.join(gpa, &.{ global_agents, "globalskill" });
    defer gpa.free(global_skill_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, global_skill_dir);
    const global_md = try std.fs.path.join(gpa, &.{ global_skill_dir, "SKILL.md" });
    defer gpa.free(global_md);
    var global_file = try std.Io.Dir.createFile(.cwd(), io, global_md, .{ .truncate = true });
    defer global_file.close(io);
    try global_file.writeStreamingAll(io, "---\nname: sharedskill\ndescription: global version\n---\nglobal body\n");

    const project_agents = try std.fs.path.join(gpa, &.{ full_dir, ".agents", "skills" });
    defer gpa.free(project_agents);
    try std.Io.Dir.createDirPath(.cwd(), io, project_agents);

    const project_skill_dir = try std.fs.path.join(gpa, &.{ project_agents, "projectskill" });
    defer gpa.free(project_skill_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, project_skill_dir);
    const project_md = try std.fs.path.join(gpa, &.{ project_skill_dir, "SKILL.md" });
    defer gpa.free(project_md);
    var project_file = try std.Io.Dir.createFile(.cwd(), io, project_md, .{ .truncate = true });
    defer project_file.close(io);
    try project_file.writeStreamingAll(io, "---\nname: sharedskill\ndescription: project version\n---\nproject body\n");

    const skills = try loadProject(gpa, io, home_dir, full_dir);
    defer deinitAll(gpa, skills);
    try std.testing.expectEqual(@as(usize, 1), skills.len);
    try std.testing.expectEqualStrings("project version", skills[0].description);
}

test "global-only skills load" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);
    const rel_dir = ".zig-cache/skill-global-only-test";
    const full_dir = try std.fs.path.join(gpa, &.{ root, rel_dir });
    defer gpa.free(full_dir);

    const home_dir = try std.fs.path.join(gpa, &.{ full_dir, "home" });
    defer gpa.free(home_dir);
    const global_agents = try std.fs.path.join(gpa, &.{ home_dir, ".agents", "skills" });
    defer gpa.free(global_agents);
    try std.Io.Dir.createDirPath(.cwd(), io, global_agents);

    const global_skill_dir = try std.fs.path.join(gpa, &.{ global_agents, "globalskill" });
    defer gpa.free(global_skill_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, global_skill_dir);
    const global_md = try std.fs.path.join(gpa, &.{ global_skill_dir, "SKILL.md" });
    defer gpa.free(global_md);
    var global_file = try std.Io.Dir.createFile(.cwd(), io, global_md, .{ .truncate = true });
    defer global_file.close(io);
    try global_file.writeStreamingAll(io, "---\nname: globalonly\ndescription: global\n---\nbody\n");

    const skills = try loadProject(gpa, io, home_dir, full_dir);
    defer deinitAll(gpa, skills);
    try std.testing.expectEqual(@as(usize, 1), skills.len);
    try std.testing.expectEqualStrings("globalonly", skills[0].name);
}

// promptPrefix surfaces any appendSkillBlock failure as a "[skill 'x' could not
// be loaded]" notice rather than aborting the whole prefix. With bodies cached
// at load time, the realistic in-prompt failure is budget exhaustion for a skill
// whose body exceeds the remaining per-turn cap.
test "promptPrefix reports a skill that exceeds the budget as a notice" {
    const gpa = std.testing.allocator;
    const big = try gpa.alloc(u8, max_total_invocation_bytes + 1);
    defer gpa.free(big);
    @memset(big, 'x');
    const skills = [_]Skill{.{ .name = @constCast("huge"), .description = @constCast("d"), .path = @constCast("/p"), .base_dir = @constCast("."), .body = big }};
    const prefix = try promptPrefix(gpa, &skills, "use $huge");
    defer gpa.free(prefix);
    try std.testing.expect(std.mem.indexOf(u8, prefix, "could not be loaded") != null);
}

test "appendSkillBlock refuses to exceed the remaining budget" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);
    const rel_dir = ".zig-cache/skill-budget-test";
    const full_dir = try std.fs.path.join(gpa, &.{ root, rel_dir });
    defer gpa.free(full_dir);
    const agents_dir = try std.fs.path.join(gpa, &.{ full_dir, ".agents", "skills" });
    defer gpa.free(agents_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, agents_dir);

    const skill_dir = try std.fs.path.join(gpa, &.{ agents_dir, "budgetskill" });
    defer gpa.free(skill_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, skill_dir);
    const skill_md = try std.fs.path.join(gpa, &.{ skill_dir, "SKILL.md" });
    defer gpa.free(skill_md);
    var f = try std.Io.Dir.createFile(.cwd(), io, skill_md, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, "---\nname: budgetskill\ndescription: d\n---\nbody content\n");

    const skills = try loadProject(gpa, io, null, full_dir);
    defer deinitAll(gpa, skills);

    var remaining: usize = 1;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const err = appendSkillBlock(&out.writer, &skills[0], &remaining);
    try std.testing.expectError(error.SkillBudgetExhausted, err);
    try std.testing.expectEqual(@as(usize, 1), remaining);
}

test "formatSkillsList lists every loaded skill" {
    const gpa = std.testing.allocator;
    const skills = [_]Skill{
        .{ .name = @constCast("one"), .description = @constCast("first"), .path = @constCast("/a/one"), .base_dir = @constCast("/a"), .body = @constCast("") },
        .{ .name = @constCast("two"), .description = @constCast("second"), .path = @constCast("/b/two"), .base_dir = @constCast("/b"), .body = @constCast("") },
    };
    const list = try formatSkillsList(gpa, &skills);
    defer gpa.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, "one") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "first") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "/a/one") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "two") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "second") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "/b/two") != null);
}

test "formatSkillsList empty slice reports no skills" {
    const gpa = std.testing.allocator;
    const list = try formatSkillsList(gpa, &.{});
    defer gpa.free(list);
    try std.testing.expectEqualStrings("no skills loaded", list);
}

test "formatForPrompt renders markdown bullets with name and description" {
    const gpa = std.testing.allocator;
    const skills = [_]Skill{
        .{ .name = @constCast("tigerstyle"), .description = @constCast("Use when writing any code."), .path = @constCast("/secret/tigerstyle/SKILL.md"), .base_dir = @constCast("/secret/tigerstyle"), .body = @constCast("") },
        .{ .name = @constCast("how"), .description = @constCast("Use for how does X work."), .path = @constCast("/secret/how/SKILL.md"), .base_dir = @constCast("/secret/how"), .body = @constCast("") },
    };
    const text = try formatForPrompt(gpa, &skills);
    defer gpa.free(text);

    // Markdown form, not XML — no literal `<skill>` tags so weak models don't echo them back.
    try std.testing.expect(std.mem.indexOf(u8, text, "<available_skills>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "</available_skills>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "**tigerstyle**") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "**how**") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Use when writing any code.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Use for how does X work.") != null);

    // The model is taught `skill` tool invocation, not bash — and the path is never published.
    try std.testing.expect(std.mem.indexOf(u8, text, "use the `skill` tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Use bash") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/secret/tigerstyle/SKILL.md") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/secret/how/SKILL.md") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<location>") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  <skill>") == null);
}

test "formatForPrompt escapes XML-special chars in skill names and descriptions" {
    const gpa = std.testing.allocator;
    const skills = [_]Skill{
        .{ .name = @constCast("a&b"), .description = @constCast("1 < 2 > 0"), .path = @constCast("/x"), .base_dir = @constCast("/x"), .body = @constCast("") },
    };
    const text = try formatForPrompt(gpa, &skills);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "**a&amp;b**") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1 &lt; 2 &gt; 0") != null);
    // Raw chars must not leak into the rendered prompt.
    try std.testing.expect(std.mem.indexOf(u8, text, "**a&b**") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1 < 2 > 0") == null);
}

test "formatForPrompt hides disable_model_invocation skills" {
    const gpa = std.testing.allocator;
    const skills = [_]Skill{
        .{ .name = @constCast("public"), .description = @constCast("shown"), .path = @constCast("/p"), .base_dir = @constCast("/p"), .body = @constCast("") },
        .{ .name = @constCast("secret"), .description = @constCast("hidden"), .path = @constCast("/s"), .base_dir = @constCast("/s"), .body = @constCast(""), .disable_model_invocation = true },
    };
    const text = try formatForPrompt(gpa, &skills);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "**public**") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "**secret**") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "hidden") == null);
}

test "formatForPrompt returns empty when every skill disables model invocation" {
    const gpa = std.testing.allocator;
    const skills = [_]Skill{
        .{ .name = @constCast("a"), .description = @constCast("x"), .path = @constCast("/a"), .base_dir = @constCast("/a"), .body = @constCast(""), .disable_model_invocation = true },
        .{ .name = @constCast("b"), .description = @constCast("y"), .path = @constCast("/b"), .base_dir = @constCast("/b"), .body = @constCast(""), .disable_model_invocation = true },
    };
    const text = try formatForPrompt(gpa, &skills);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("", text);
}

test "collectInjectedSkillNames parses injected markers" {
    const gpa = std.testing.allocator;
    const text = "Before\n<skill name=\"tiger\">body</skill>\n<skill name=\"how\">more</skill>\nAfter";
    const names = try collectInjectedSkillNames(gpa, text);
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("tiger", names[0]);
    try std.testing.expectEqualStrings("how", names[1]);
}

test "collectInjectedSkillNames no markers returns empty" {
    const gpa = std.testing.allocator;
    const names = try collectInjectedSkillNames(gpa, "no markers here");
    defer gpa.free(names);
    try std.testing.expectEqual(@as(usize, 0), names.len);
}

test "cloneAll produces independent copies" {
    const gpa = std.testing.allocator;
    const skills = [_]Skill{.{ .name = @constCast("how"), .description = @constCast("d"), .path = @constCast("p"), .base_dir = @constCast("."), .body = @constCast("") }};
    const copies = try cloneAll(gpa, &skills);
    defer deinitAll(gpa, copies);
    try std.testing.expect(copies[0].name.ptr != skills[0].name.ptr);
    try std.testing.expectEqualStrings("how", copies[0].name);
}

test "collectInvocations deduplicates case-insensitively" {
    const gpa = std.testing.allocator;
    const skills = [_]Skill{.{ .name = @constCast("tiger"), .description = @constCast("d"), .path = @constCast("p"), .base_dir = @constCast("."), .body = @constCast("") }};
    // $Tiger and $tiger both resolve to skill "tiger" via case-insensitive find.
    // contains must also be case-insensitive, otherwise the body is injected twice.
    const names = try collectInvocations(gpa, &skills, "$Tiger and $tiger");
    defer gpa.free(names);
    try std.testing.expectEqual(@as(usize, 1), names.len);
}

test "isValidSkillName rejects XML-special characters" {
    try std.testing.expect(!isValidSkillName("a\"b"));
    try std.testing.expect(!isValidSkillName("a'b"));
    try std.testing.expect(!isValidSkillName("a&b"));
    try std.testing.expect(!isValidSkillName("a<b"));
    try std.testing.expect(!isValidSkillName("a>b"));
    try std.testing.expect(isValidSkillName("abc"));
    try std.testing.expect(isValidSkillName("c++"));
    try std.testing.expect(isValidSkillName("c#"));
}

test "appendSkillBlock escapes XML special characters in attributes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);
    const rel_dir = ".zig-cache/skill-escape-test";
    const full_dir = try std.fs.path.join(gpa, &.{ root, rel_dir });
    defer gpa.free(full_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, full_dir);

    const md_path = try std.fs.path.join(gpa, &.{ full_dir, "SKILL.md" });
    defer gpa.free(md_path);
    var file = try std.Io.Dir.createFile(.cwd(), io, md_path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, "---\nname: dummy\ndescription: d\n---\nbody\n");

    // Construct a Skill with XML-special chars in the name (bypasses loadOne
    // validation — tests the belt-and-braces escaping in appendSkillBlock, TD-4).
    const skill: Skill = .{
        .name = @constCast("a\"b&c<d>"),
        .description = @constCast("d"),
        .path = md_path,
        .base_dir = full_dir,
        .body = @constCast("body\n"),
    };

    var remaining: usize = max_total_invocation_bytes;
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try appendSkillBlock(&out.writer, &skill, &remaining);
    const result = try out.toOwnedSlice();
    defer gpa.free(result);

    // All XML-special chars in the name must be escaped inside the opening tag.
    try std.testing.expect(std.mem.indexOf(u8, result, "a&quot;b&amp;c&lt;d&gt;") != null);
}
