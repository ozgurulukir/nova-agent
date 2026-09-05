const std = @import("std");

const parts_mod = @import("tools/parts.zig");
const terminal_markdown = @import("terminal_markdown");

const assert = std.debug.assert;

/// How a tool's display body should be drawn in the TUI.
///   - `.plain`: single muted-gray body.
///   - `.diff`: per-line diff styling with `+` green, `-` red, others gray.
/// Failure overrides everything to red at draw time.
pub const Render = enum { plain, diff };

/// Tag of a transcript message. Kept as a separate enum (not the union
/// tag directly) so non-Message sites can name a kind without depending
/// on the union payload layout.
pub const MessageKind = enum {
    user,
    agent,
    skill,
    logo,
    thinking,
    tool,
    status,
    notice,
    success,
    info,

    fn selectable(self: MessageKind) bool {
        return self != .logo and self != .status;
    }

    pub fn dimmable(self: MessageKind) bool {
        return switch (self) {
            .user, .agent, .skill, .thinking, .tool, .notice, .success, .info => true,
            .logo, .status => false,
        };
    }
};

/// Memoized row count for a message at a given width. Computing it scans the
/// whole (possibly multi-KB, streaming) body, and the draw loop asks for it
/// several times per frame, so we cache the last result. Width is part of the
/// key (resize changes wrapping); content changes invalidate via
/// `Message.invalidateRowCache`, called by every `Transcript` mutator. Because the
/// only layout-affecting writes go through those mutators, width is the only
/// thing the lookup itself has to re-check.
pub const RowCache = struct {
    valid: bool = false,
    width: u16 = 0,
    rows: u16 = 0,
};

/// Payload shared by every non-tool transcript variant (user, agent,
/// skill, logo, thinking, status, notice, success, info). The fields
/// that were previously always-present on `Message` — title, body,
/// expanded — live here; tool-only fields live in `ToolView`. `failed`
/// is set when the source of the message reported a failure (skill
/// result); other variants leave it false.
pub const Basic = struct {
    title: []u8,
    body: []u8,
    expanded: bool = true,
    failed: bool = false,
    row_cache: RowCache = .{},
    render_inc: terminal_markdown.Incremental = .{},
};

/// Tool-specific payload. `running` flips between append (start) and
/// finishTool; `render` drives per-line styling; `failed` overrides
/// body color; `stderr_body`/`expanded_title` are optional.
pub const ToolView = struct {
    title: []u8,
    body: []u8,
    expanded: bool = false,
    running: bool = true,
    render: Render = .plain,
    failed: bool = false,
    stderr: ?[]u8 = null,
    expanded_title: ?[]u8 = null,
    /// Structured display parts derived at finish/append time (see AD-3). The
    /// renderer and metrics path both consume this; empty means fall back to
    /// `body` + `render`.
    parts: []parts_mod.Part = &.{},
    /// Beautified expanded title (name + pretty-printed JSON args). The raw
    /// `expanded_title` is kept intact because `toolDisplayMatches` compares it,
    /// so this is what draw/metrics display when expanded.
    expanded_title_formatted: ?[]u8 = null,
    row_cache: RowCache = .{},
    render_inc: terminal_markdown.Incremental = .{},
};

/// One entry in the conversation transcript. Variants make illegal
/// combinations unrepresentable: only the `.tool` variant has `running`
/// or `stderr`; only the `.user`/`.agent`/`.logo` variants start
/// `expanded`; the kind drives the draw path via a tag switch.
pub const Message = union(enum) {
    user: Basic,
    agent: Basic,
    skill: Basic,
    logo: Basic,
    thinking: Basic,
    status: Basic,
    notice: Basic,
    success: Basic,
    info: Basic,
    tool: ToolView,

    /// Map a variant back to the loose `MessageKind` enum that older
    /// call sites switch on. Kept for the renderer's switch — once the
    /// renderer is converted to a tag switch, this can go.
    pub fn kind(self: Message) MessageKind {
        return switch (self) {
            .user => .user,
            .agent => .agent,
            .skill => .skill,
            .logo => .logo,
            .thinking => .thinking,
            .tool => .tool,
            .status => .status,
            .notice => .notice,
            .success => .success,
            .info => .info,
        };
    }

    /// Convenience: a reference to the title of whichever variant
    /// holds one. Used by the selection/toggle paths.
    pub fn titlePtr(self: *Message) *[]u8 {
        return switch (self.*) {
            inline .user, .agent, .skill, .logo, .thinking, .status, .notice, .success, .info => |*m| &m.title,
            .tool => |*t| &t.title,
        };
    }

    /// Convenience: a reference to the body of whichever variant
    /// holds one. Used by the streaming append paths.
    pub fn bodyPtr(self: *Message) *[]u8 {
        return switch (self.*) {
            inline .user, .agent, .skill, .logo, .thinking, .status, .notice, .success, .info => |*m| &m.body,
            .tool => |*t| &t.body,
        };
    }

    /// Convenience: a reference to the expanded flag.
    pub fn expandedPtr(self: *Message) *bool {
        return switch (self.*) {
            inline .user, .agent, .skill, .logo, .thinking, .status, .notice, .success, .info => |*m| &m.expanded,
            .tool => |*t| &t.expanded,
        };
    }

    /// Convenience: pointer to the `row_cache` field.
    pub fn rowCachePtr(self: *Message) *RowCache {
        return switch (self.*) {
            inline .user, .agent, .skill, .logo, .thinking, .status, .notice, .success, .info => |*m| &m.row_cache,
            .tool => |*t| &t.row_cache,
        };
    }

    /// Convenience: pointer to the `render_inc` field.
    pub fn renderIncPtr(self: *Message) *terminal_markdown.Incremental {
        return switch (self.*) {
            inline .user, .agent, .skill, .logo, .thinking, .status, .notice, .success, .info => |*m| &m.render_inc,
            .tool => |*t| &t.render_inc,
        };
    }

    pub fn deinit(self: *Message, gpa: std.mem.Allocator) void {
        switch (self.*) {
            inline .user, .agent, .skill, .logo, .thinking, .status, .notice, .success, .info => |*m| {
                gpa.free(m.title);
                gpa.free(m.body);
                m.render_inc.deinit(gpa);
            },
            .tool => |*t| {
                gpa.free(t.title);
                gpa.free(t.body);
                if (t.stderr) |stderr| gpa.free(stderr);
                if (t.expanded_title) |title| gpa.free(title);
                if (t.expanded_title_formatted) |f| gpa.free(f);
                for (t.parts) |*part| part.deinit(gpa);
                if (t.parts.len > 0) gpa.free(t.parts); // M5: guard the empty-slice free
                t.render_inc.deinit(gpa);
            },
        }
        self.* = undefined;
    }

    pub fn invalidateRowCache(self: *Message) void {
        self.rowCachePtr().valid = false;
    }

    /// Test-only flat view of this `Message`. The TUI tests access
    /// fields like `message.body` directly; with the union shape, those
    /// become variant-specific. The mirror reconstructs the flat view for
    /// tests that don't care which variant they're inspecting. Not for
    /// production use.
    pub fn mirror(self: Message) Mirror {
        return switch (self) {
            inline .user, .agent, .skill, .logo, .thinking, .status, .notice, .success, .info => |m| .{
                .kind = self.kind(),
                .title = m.title,
                .body = m.body,
                .expanded = m.expanded,
                .failed = m.failed,
                .tool_running = false,
                .tool_render = .plain,
                .tool_expanded_title = null,
                .stderr_body = null,
            },
            .tool => |t| .{
                .kind = .tool,
                .title = t.title,
                .body = t.body,
                .expanded = t.expanded,
                .failed = t.failed,
                .tool_running = t.running,
                .tool_render = t.render,
                .tool_expanded_title = t.expanded_title,
                .stderr_body = t.stderr,
            },
        };
    }
};

pub const Transcript = struct {
    messages: std.ArrayList(Message) = .empty,
    selected: ?u32 = null,

    pub fn deinit(self: *Transcript, gpa: std.mem.Allocator) void {
        for (self.messages.items) |*message| {
            message.deinit(gpa);
        }
        self.messages.deinit(gpa);
        self.* = undefined;
    }

    pub fn append(
        self: *Transcript,
        gpa: std.mem.Allocator,
        kind: MessageKind,
        title: []const u8,
        body: []const u8,
    ) !u32 {
        assert(title.len > 0);
        const owned_title = try gpa.dupe(u8, title);
        errdefer gpa.free(owned_title);
        const owned_body = try gpa.dupe(u8, body);
        errdefer gpa.free(owned_body);

        const index: u32 = @intCast(self.messages.items.len);
        const following_tail = self.isFollowingTail();
        const expanded = kind == .user or kind == .agent or kind == .logo;
        const payload = Basic{
            .title = owned_title,
            .body = owned_body,
            .expanded = expanded,
        };
        try self.messages.append(gpa, try payloadToMessage(kind, payload));
        if (kind.selectable() and following_tail) self.selected = index;
        return index;
    }

    /// True when no message is selected, or when the selection is at the last
    /// selectable message in the transcript (so streaming a new selectable message
    /// should follow). Users who have scrolled up to an earlier message stop
    /// "following the tail" and won't get yanked forward on the next append.
    ///
    /// `selected` is always a selectable index by invariant, and the only
    /// non-selectable message that ever sits at the tail is the lone status
    /// spinner — so it suffices to check the final one or two slots. O(1).
    pub fn isFollowingTail(self: *const Transcript) bool {
        const selected = self.selected orelse return true;
        const count: u32 = @intCast(self.messages.items.len);
        if (selected + 1 == count) return true;
        if (selected + 2 == count and !self.messages.items[count - 1].kind().selectable()) return true;
        return false;
    }

    /// Test-visibility probe: true when any user-, agent-, or notice-visible
    /// message body contains `needle`. The variant set is load-bearing: TUI
    /// tests assert negatives (background-job results, final-state lines,
    /// discarded results) that must never match `.tool`/`.thinking`/`.skill`
    /// bodies — model- or tool-authored text that is not a visible user-facing
    /// message. Do NOT widen this to `bodyPtr()`'s variant list.
    pub fn containsText(self: *const Transcript, needle: []const u8) bool {
        for (self.messages.items) |m| {
            const body: []const u8 = switch (m) {
                .user => |x| x.body,
                .agent => |x| x.body,
                .notice => |x| x.body,
                else => continue,
            };
            if (std.mem.indexOf(u8, body, needle) != null) return true;
        }
        return false;
    }

    pub fn appendAgentDelta(
        self: *Transcript,
        gpa: std.mem.Allocator,
        index: u32,
        delta: []const u8,
    ) !void {
        assert(index < self.messages.items.len);
        const message = &self.messages.items[index];
        assert(message.* == .agent);
        try appendOwned(gpa, message.bodyPtr(), delta);
        message.invalidateRowCache();
    }

    pub fn appendThinkingDelta(
        self: *Transcript,
        gpa: std.mem.Allocator,
        index: u32,
        delta: []const u8,
    ) !void {
        assert(index < self.messages.items.len);
        const message = &self.messages.items[index];
        assert(message.* == .thinking);
        try appendOwned(gpa, message.bodyPtr(), delta);
        message.invalidateRowCache();
    }

    /// Append a finished tool message (used when rehydrating from a
    /// session). Distinct from `startTool` because the tool is already
    /// done — `running` is false, `expanded` follows the diff policy.
    pub fn appendTool(
        self: *Transcript,
        gpa: std.mem.Allocator,
        title: []const u8,
        body: []const u8,
        failed: bool,
    ) !u32 {
        assert(title.len > 0);
        const owned_title = try gpa.dupe(u8, title);
        errdefer gpa.free(owned_title);
        const owned_body = try gpa.dupe(u8, body);
        errdefer gpa.free(owned_body);
        // Resume bodies are the LLM observation; JSON detection still applies.
        // Build before appending so an OOM here leaves nothing half-constructed,
        // and the ownership errdefers stay scoped to the pre-append work.
        const parts = try parts_mod.buildParts(gpa, owned_body, .text);
        errdefer {
            for (parts) |*part| part.deinit(gpa);
            if (parts.len > 0) gpa.free(parts);
        }

        const index: u32 = @intCast(self.messages.items.len);
        const following_tail = self.isFollowingTail();
        try self.messages.append(gpa, .{
            .tool = .{
                .title = owned_title,
                .body = owned_body,
                .expanded = false,
                .running = false,
                .failed = failed,
                .parts = parts,
            },
        });
        if (MessageKind.tool.selectable() and following_tail) self.selected = index;
        return index;
    }

    pub fn insert(
        self: *Transcript,
        gpa: std.mem.Allocator,
        index: u32,
        kind: MessageKind,
        title: []const u8,
        body: []const u8,
    ) !u32 {
        assert(index <= self.messages.items.len);
        assert(title.len > 0);
        const owned_title = try gpa.dupe(u8, title);
        errdefer gpa.free(owned_title);
        const owned_body = try gpa.dupe(u8, body);
        errdefer gpa.free(owned_body);

        const expanded = kind == .user or kind == .agent or kind == .logo;
        const payload = Basic{
            .title = owned_title,
            .body = owned_body,
            .expanded = expanded,
        };
        try self.messages.insert(gpa, index, try payloadToMessage(kind, payload));
        if (self.selected) |selected| {
            if (selected >= index) self.selected = selected + 1;
        }
        return index;
    }

    pub fn select(self: *Transcript, index: u32) void {
        assert(index < self.messages.items.len);
        assert(self.messages.items[index].kind().selectable());
        self.selected = index;
    }

    pub fn selectLast(self: *Transcript) void {
        if (self.messages.items.len == 0) {
            self.selected = null;
            return;
        }
        var index: u32 = @intCast(self.messages.items.len);
        while (index > 0) {
            index -= 1;
            if (self.messages.items[index].kind().selectable()) {
                self.selected = index;
                return;
            }
        }
        self.selected = null;
    }

    pub fn remove(self: *Transcript, gpa: std.mem.Allocator, index: u32) void {
        assert(index < self.messages.items.len);
        self.messages.items[index].deinit(gpa);
        _ = self.messages.orderedRemove(index);

        if (self.messages.items.len == 0) {
            self.selected = null;
            return;
        }

        if (self.selected) |selected| {
            self.selected = if (selected == index)
                self.nearestSelectable(@min(index, @as(u32, @intCast(self.messages.items.len - 1))))
            else if (selected > index)
                selected - 1
            else
                selected;
        }
    }

    pub fn startTool(self: *Transcript, gpa: std.mem.Allocator, command: []const u8) !u32 {
        const title = try toolTitle(gpa, command);
        defer gpa.free(title);
        const index: u32 = @intCast(self.messages.items.len);
        const following_tail = self.isFollowingTail();
        try self.messages.append(gpa, .{
            .tool = .{
                .title = try gpa.dupe(u8, title),
                .body = try gpa.dupe(u8, ""),
                .expanded = false,
                .running = true,
            },
        });
        if (MessageKind.tool.selectable() and following_tail) self.selected = index;
        return index;
    }

    pub fn updateTool(self: *Transcript, gpa: std.mem.Allocator, index: u32, command: []const u8) !void {
        try self.updateToolExpanded(gpa, index, command, null);
    }

    pub fn updateToolExpanded(
        self: *Transcript,
        gpa: std.mem.Allocator,
        index: u32,
        command: []const u8,
        expanded_command: ?[]const u8,
    ) !void {
        assert(index < self.messages.items.len);
        const message = &self.messages.items[index];
        assert(message.* == .tool);

        const title = try toolTitle(gpa, command);
        errdefer gpa.free(title);
        const expanded_title = if (expanded_command) |value| try toolTitle(gpa, value) else null;
        errdefer if (expanded_title) |value| gpa.free(value);
        const expanded_title_formatted = if (expanded_command) |value|
            try parts_mod.formatExpandedTitle(gpa, value)
        else
            null;
        errdefer if (expanded_title_formatted) |value| gpa.free(value);
        const t = &message.tool;
        gpa.free(t.title);
        if (t.expanded_title) |value| gpa.free(value);
        if (t.expanded_title_formatted) |value| gpa.free(value);
        t.title = title;
        t.expanded_title = expanded_title;
        t.expanded_title_formatted = expanded_title_formatted;
        message.invalidateRowCache();
    }

    pub fn finishThinking(self: *Transcript, gpa: std.mem.Allocator, index: u32) !void {
        assert(index < self.messages.items.len);
        const message = &self.messages.items[index];
        assert(message.* == .thinking);
        if (std.mem.eql(u8, message.thinking.title, "Thoughts")) return;

        const title = try gpa.dupe(u8, "Thoughts");
        gpa.free(message.thinking.title);
        message.thinking.title = title;
    }

    pub fn finishTool(
        self: *Transcript,
        gpa: std.mem.Allocator,
        index: u32,
        body: []const u8,
        stderr_body: ?[]const u8,
        failed: bool,
        render: Render,
    ) !void {
        assert(index < self.messages.items.len);
        const message = &self.messages.items[index];
        assert(message.* == .tool);
        const t = &message.tool;
        t.running = false;
        try appendOwned(gpa, &t.body, body);
        if (stderr_body) |stderr| {
            assert(stderr.len > 0);
            const owned = try gpa.dupe(u8, stderr);
            if (t.stderr) |existing| gpa.free(existing);
            t.stderr = owned;
        }
        t.failed = failed;
        t.render = render;
        // Rebuild parts from the finalized body. Free prior parts first (and
        // reset to empty so a failing build can't leave a dangling pointer).
        for (t.parts) |*part| part.deinit(gpa);
        if (t.parts.len > 0) gpa.free(t.parts);
        t.parts = &.{};
        t.parts = try parts_mod.buildParts(gpa, t.body, if (render == .diff) .diff else .text);
        message.invalidateRowCache();
    }

    pub fn finishSkill(
        self: *Transcript,
        gpa: std.mem.Allocator,
        index: u32,
        body: []const u8,
        failed: bool,
    ) !void {
        assert(index < self.messages.items.len);
        const message = &self.messages.items[index];
        assert(message.* == .skill);
        try appendOwned(gpa, &message.skill.body, body);
        message.skill.failed = failed;
        message.invalidateRowCache();
    }

    /// Set a message's expanded state, invalidating its cached row count. The
    /// The turn view mutates `expanded` when a tool finishes; route it
    /// through here so the cache stays correct.
    pub fn setExpanded(self: *Transcript, index: u32, value: bool) void {
        assert(index < self.messages.items.len);
        const message = &self.messages.items[index];
        message.expandedPtr().* = value;
        message.invalidateRowCache();
    }

    pub fn moveSelection(self: *Transcript, direction: enum { previous, next }) void {
        if (self.messages.items.len == 0) {
            self.selected = null;
            return;
        }

        const selected = self.selected orelse self.nearestSelectable(0) orelse return;
        self.selected = switch (direction) {
            .previous => self.previousSelectable(selected) orelse selected,
            .next => self.nextSelectable(selected) orelse selected,
        };
    }

    pub fn hasRunningTool(self: *const Transcript) bool {
        for (self.messages.items) |message| {
            if (message != .tool) continue;
            if (message.tool.running) return true;
        }
        return false;
    }

    pub fn stopRunningTools(self: *Transcript) bool {
        var stopped = false;
        for (self.messages.items) |*message| {
            if (message.* != .tool) continue;
            if (!message.tool.running) continue;
            message.tool.running = false;
            stopped = true;
        }
        return stopped;
    }

    pub fn toggleSelected(self: *Transcript) void {
        const selected = self.selected orelse return;
        assert(selected < self.messages.items.len);
        const message = &self.messages.items[selected];
        switch (message.*) {
            .thinking, .tool => {
                message.expandedPtr().* = !message.expandedPtr().*;
                message.invalidateRowCache();
            },
            .skill => if (message.skill.body.len > 0) {
                message.skill.expanded = !message.skill.expanded;
                message.invalidateRowCache();
            },
            .user, .agent, .logo, .status, .notice, .success, .info => {},
        }
    }

    fn nearestSelectable(self: *const Transcript, index: u32) ?u32 {
        assert(self.messages.items.len > 0);
        assert(index < self.messages.items.len);
        if (self.messages.items[index].kind().selectable()) return index;
        if (self.nextSelectable(index)) |next| return next;
        return self.previousSelectable(index);
    }

    fn previousSelectable(self: *const Transcript, index: u32) ?u32 {
        assert(index < self.messages.items.len);
        var current = index;
        while (current > 0) {
            current -= 1;
            if (self.messages.items[current].kind().selectable()) return current;
        }
        return null;
    }

    fn nextSelectable(self: *const Transcript, index: u32) ?u32 {
        assert(index < self.messages.items.len);
        var current = index + 1;
        while (current < self.messages.items.len) : (current += 1) {
            if (self.messages.items[current].kind().selectable()) return @intCast(current);
        }
        return null;
    }
};

fn payloadToMessage(kind: MessageKind, payload: Basic) !Message {
    return switch (kind) {
        .user => .{ .user = payload },
        .agent => .{ .agent = payload },
        .skill => .{ .skill = payload },
        .logo => .{ .logo = payload },
        .thinking => .{ .thinking = payload },
        .status => .{ .status = payload },
        .notice => .{ .notice = payload },
        .success => .{ .success = payload },
        .info => .{ .info = payload },
        .tool => error.InvalidToolRole,
    };
}

fn appendOwned(gpa: std.mem.Allocator, target: *[]u8, suffix: []const u8) !void {
    if (suffix.len == 0) return;
    // `realloc` grows the buffer in place when the allocator's size class has
    // room, so streaming deltas don't recopy the whole (ever-growing) body on
    // every append. A fresh alloc + memcpy here is O(N) per delta — O(N²) over
    // a long response, the main driver of mid-stream slowdown.
    const old_len = target.len;
    const joined = try gpa.realloc(target.*, old_len + suffix.len);
    @memcpy(joined[old_len..], suffix);
    target.* = joined;
}

pub fn toolTitle(gpa: std.mem.Allocator, command: []const u8) ![]u8 {
    return try std.fmt.allocPrint(gpa, "🛠  {s}", .{command});
}

/// Test-only flat view of a `Message`. The TUI tests access fields like
/// `message.body` directly; with the union shape, those become
/// variant-specific. The mirror reconstructs the flat view for tests that
/// don't care which variant they're inspecting. Not for production use.
pub const Mirror = struct {
    kind: MessageKind,
    title: []const u8,
    body: []const u8,
    expanded: bool,
    failed: bool,
    tool_running: bool,
    tool_render: Render,
    tool_expanded_title: ?[]const u8,
    stderr_body: ?[]const u8,
};

test "containsText searches only user/agent/notice bodies" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .user, "user", "NEEDLE from user");
    _ = try transcript.append(gpa, .agent, "agent", "agent NEEDLE body");
    _ = try transcript.append(gpa, .notice, "notice", "notice NEEDLE body");
    try std.testing.expect(transcript.containsText("NEEDLE"));

    // Every other variant must be invisible to the probe — widening the
    // variant set flips negative assertions across the TUI tests.
    _ = try transcript.append(gpa, .thinking, "thinking", "NEEDLE_THINKING");
    _ = try transcript.append(gpa, .skill, "skill", "NEEDLE_SKILL");
    _ = try transcript.append(gpa, .status, "status", "NEEDLE_STATUS");
    _ = try transcript.append(gpa, .success, "success", "NEEDLE_SUCCESS");
    _ = try transcript.append(gpa, .info, "info", "NEEDLE_INFO");
    _ = try transcript.append(gpa, .logo, "logo", "NEEDLE_LOGO");
    _ = try transcript.appendTool(gpa, "tool", "NEEDLE_TOOL", false);

    try std.testing.expect(!transcript.containsText("NEEDLE_THINKING"));
    try std.testing.expect(!transcript.containsText("NEEDLE_SKILL"));
    try std.testing.expect(!transcript.containsText("NEEDLE_STATUS"));
    try std.testing.expect(!transcript.containsText("NEEDLE_SUCCESS"));
    try std.testing.expect(!transcript.containsText("NEEDLE_INFO"));
    try std.testing.expect(!transcript.containsText("NEEDLE_LOGO"));
    try std.testing.expect(!transcript.containsText("NEEDLE_TOOL"));
    // Positives still hold after the excluded variants were appended.
    try std.testing.expect(transcript.containsText("NEEDLE"));
}

test "thinking and tool messages are compact until toggled" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .thinking, "thinking", "one two three four");
    try std.testing.expect(!transcript.messages.items[0].thinking.expanded);
    transcript.toggleSelected();
    try std.testing.expect(transcript.messages.items[0].thinking.expanded);
}

test "selectLast selects last selectable before status tail" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .agent, "agent", "one");
    _ = try transcript.append(gpa, .status, "status", "loading");
    transcript.selected = null;

    transcript.selectLast();

    try std.testing.expectEqual(@as(?u32, 0), transcript.selected);
}

test "consecutive tools remain separate messages" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    const first = try transcript.startTool(gpa, "ls");
    try transcript.finishTool(gpa, first, "ls\n", null, false, .plain);
    const second = try transcript.startTool(gpa, "pwd");
    try std.testing.expect(first != second);
    try std.testing.expectEqual(@as(usize, 2), transcript.messages.items.len);
    try std.testing.expectEqualStrings("🛠  ls", transcript.messages.items[0].tool.title);
    try std.testing.expectEqualStrings("🛠  pwd", transcript.messages.items[1].tool.title);
    try std.testing.expect(!transcript.messages.items[0].tool.expanded);
    try std.testing.expect(!transcript.messages.items[1].tool.expanded);
}

test "remove keeps selection in range" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .user, "you", "one");
    _ = try transcript.append(gpa, .agent, "agent", "two");
    transcript.remove(gpa, 1);

    try std.testing.expectEqual(@as(usize, 1), transcript.messages.items.len);
    try std.testing.expectEqual(@as(u32, 0), transcript.selected.?);
}

test "finishTool builds a json part and sets render" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    const index = try transcript.startTool(gpa, "curl");
    try transcript.finishTool(gpa, index, "{\"a\":1}", null, false, .plain);
    const t = &transcript.messages.items[index].tool;
    try std.testing.expectEqual(Render.plain, t.render);
    try std.testing.expectEqual(@as(usize, 1), t.parts.len);
    try std.testing.expect(parts_mod.PartKind.json == t.parts[0].kind);
    // JSON body is pretty-printed into the part text.
    try std.testing.expect(std.mem.indexOf(u8, t.parts[0].text, "\n") != null);
}

test "diff render yields a single diff part" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    const index = try transcript.startTool(gpa, "git diff");
    try transcript.finishTool(gpa, index, "+ added\n- removed", null, false, .diff);
    const t = &transcript.messages.items[index].tool;
    try std.testing.expectEqual(Render.diff, t.render);
    try std.testing.expectEqual(@as(usize, 1), t.parts.len);
    try std.testing.expect(parts_mod.PartKind.diff == t.parts[0].kind);
}

test "updateToolExpanded formats JSON args into expanded_title_formatted" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    const index = try transcript.startTool(gpa, "greet");
    try transcript.updateToolExpanded(gpa, index, "greet", "greet {\"name\":\"x\"}");
    const t = &transcript.messages.items[index].tool;
    try std.testing.expect(t.expanded_title_formatted != null);
    try std.testing.expect(std.mem.startsWith(u8, t.expanded_title_formatted.?, "greet {"));
    try std.testing.expect(std.mem.indexOf(u8, t.expanded_title_formatted.?, "\n") != null);
    // The raw expanded_title is deliberately untouched (toolDisplayMatches reads it).
    try std.testing.expectEqualStrings("🛠  greet {\"name\":\"x\"}", t.expanded_title.?);
}

test "appendTool builds a json part from a JSON resume body" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    const index = try transcript.appendTool(gpa, "curl", "{\"ok\":true}", false);
    const t = &transcript.messages.items[index].tool;
    try std.testing.expectEqual(@as(usize, 1), t.parts.len);
    try std.testing.expect(parts_mod.PartKind.json == t.parts[0].kind);
}
