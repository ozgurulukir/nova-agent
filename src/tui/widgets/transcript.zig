//! The transcript pane widget: scrollable list of messages per lane.
//!
//! Pulled out of `tui.zig` (R5.1d of `_pm/Projects/tui-split`) — the widget
//! reads the `Thread` lane state, drives the underlying vxfw list view, and
//! handles viewport/cursor sync. INV-WIDGET-1: it carries only scalars and
//! the `Thread` handle (no `App` reference); the per-frame construction site
//! computes them, and `blackhole_visible` writes back into `App.metrics` via
//! pointer so the intro-animation tick can stop.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui_message = @import("message.zig");
const tui_metrics = @import("../metrics.zig");
const Thread = @import("../thread.zig");
const transcript_mod = @import("../../transcript.zig");

const MessageWidget = tui_message.MessageWidget;
const ConversationLayout = tui_message.ConversationLayout;
const messageRowsCached = tui_metrics.messageRowsCached;

pub const TranscriptWidget = struct {
    /// The lane this pane renders — the active lane today; any lane once tiled.
    thread: *Thread,
    /// Per-frame scalars computed by the construction site (INV-WIDGET-1).
    gpa: std.mem.Allocator,
    /// `tui_status.modelStatus(live_runtime, cached_config) != null` —
    /// precomputed so this leaf never touches the App or config modules.
    has_model_configured: bool,
    loading_frame: u8,
    blackhole_frame: u16,
    /// Write-back into `App.metrics.blackhole_visible` — see
    /// `updateBlackholeVisibility`.
    blackhole_visible: *bool,

    pub fn widget(self: *TranscriptWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = drawTranscript,
        };
    }

    fn drawTranscript(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *TranscriptWidget = @ptrCast(@alignCast(ptr));
        self.syncViewport(ctx);

        var builder: MessageListBuilder = .{
            .arena = ctx.arena,
            .messages = self.thread.transcript.messages.items,
            .selected = self.thread.transcript.selected,
            .loading_frame = self.loading_frame,
            .blackhole_frame = self.blackhole_frame,
            .gpa = self.gpa,
            .has_model_configured = self.has_model_configured,
        };
        self.thread.transcript_list.children = .{ .builder = .{ .userdata = &builder, .buildFn = MessageListBuilder.build } };
        self.thread.transcript_list.item_count = @intCast(self.thread.transcript.messages.items.len);
        self.syncCursor(ctx);

        var list_padding: vxfw.Padding = .{
            .child = self.thread.transcript_list.widget(),
            .padding = ConversationLayout.verticalPadding(),
        };
        const surface = try list_padding.widget().draw(ctx);
        self.updateBlackholeVisibility();
        return surface;
    }

    // The intro animation only runs while the startup logo (message 0) is the
    // first item the list view is rendering. Once a turn pushes it off the top,
    // `scroll.top` advances and the animation tick is allowed to stop.
    fn updateBlackholeVisibility(self: *TranscriptWidget) void {
        const messages = self.thread.transcript.messages.items;
        self.blackhole_visible.* = messages.len > 0 and
            messages[0] == .logo and
            self.thread.transcript_list.scroll.top == 0;
    }

    fn syncViewport(self: *TranscriptWidget, ctx: vxfw.DrawContext) void {
        const max_width = ctx.max.width orelse ctx.min.width;
        const max_height = ctx.max.height orelse ctx.min.height;
        self.thread.transcript_view_width = max_width;
        self.thread.transcript_view_height = max_height -| ConversationLayout.top -| ConversationLayout.bottom;
        if (self.thread.transcript_view_height == 0) self.thread.transcript_view_height = 1;
    }

    fn syncCursor(self: *TranscriptWidget, ctx: vxfw.DrawContext) void {
        const messages = self.thread.transcript.messages.items;
        if (messages.len == 0) return;
        if (self.thread.auto_scroll) {
            const cursor: u32 = @intCast(messages.len - 1);
            self.thread.transcript_list.cursor = cursor;
            self.scrollCursorToTail(ctx, cursor);
            return;
        }
        const cursor = self.thread.transcript.selected orelse 0;
        const cursor_changed = self.thread.transcript_list.cursor != cursor;
        self.thread.transcript_list.cursor = cursor;
        if (cursor_changed) self.thread.transcript_list.ensureScroll();
    }

    fn scrollCursorToTail(self: *TranscriptWidget, ctx: vxfw.DrawContext, cursor: u32) void {
        const message_count: u32 = @intCast(self.thread.transcript.messages.items.len);
        if (cursor >= message_count) return;
        const max_width = ctx.max.width orelse ctx.min.width;
        const max_height = ctx.max.height orelse ctx.min.height;
        const list_height = max_height -| ConversationLayout.top -| ConversationLayout.bottom;
        const message_height = messageRowsCached(&self.thread.transcript.messages.items[cursor], ConversationLayout.contentWidth(max_width));
        self.thread.transcript_list.scroll.top = cursor;
        self.thread.transcript_list.scroll.pending_lines = 0;
        self.thread.transcript_list.scroll.wants_cursor = false;
        if (message_height > list_height) {
            self.thread.transcript_list.scroll.offset = @intCast(message_height - list_height);
        } else {
            self.thread.transcript_list.scroll.offset = 0;
        }
    }
};

pub const MessageListBuilder = struct {
    arena: std.mem.Allocator,
    messages: []transcript_mod.Message,
    selected: ?u32 = null,
    loading_frame: u8 = 0,
    blackhole_frame: u16 = 0,
    gpa: std.mem.Allocator,
    has_model_configured: bool = false,

    pub fn build(ptr: *const anyopaque, idx: usize, cursor: usize) ?vxfw.Widget {
        _ = cursor;
        const self: *const MessageListBuilder = @ptrCast(@alignCast(ptr));
        if (idx >= self.messages.len) return null;
        const body = self.arena.create(MessageWidget) catch return null;
        body.* = .{
            .message = &self.messages[idx],
            .selected = if (self.selected) |selected| selected == idx else false,
            .loading_frame = self.loading_frame,
            .blackhole_frame = self.blackhole_frame,
            .gpa = self.gpa,
            .has_model_configured = self.has_model_configured,
        };
        return body.widget();
    }
};

test "MessageListBuilder.build returns null for out-of-bounds index" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .user, "user", "hello");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const builder: MessageListBuilder = .{
        .arena = arena.allocator(),
        .messages = transcript.messages.items,
        .selected = null,
        .gpa = gpa,
        .has_model_configured = true,
    };

    try std.testing.expect(MessageListBuilder.build(&builder, 0, 0) != null);
    try std.testing.expect(MessageListBuilder.build(&builder, 1, 0) == null);
    try std.testing.expect(MessageListBuilder.build(&builder, 999, 0) == null);
}

test "MessageListBuilder.build constructs widget with correct message and selection state" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .user, "user", "first");
    _ = try transcript.append(gpa, .agent, "agent", "second");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const builder: MessageListBuilder = .{
        .arena = arena.allocator(),
        .messages = transcript.messages.items,
        .selected = 1,
        .loading_frame = 3,
        .blackhole_frame = 7,
        .gpa = gpa,
        .has_model_configured = true,
    };

    const widget0 = MessageListBuilder.build(&builder, 0, 0);
    try std.testing.expect(widget0 != null);
    const msg0: *const MessageWidget = @ptrCast(@alignCast(widget0.?.userdata));
    try std.testing.expectEqual(false, msg0.selected);
    try std.testing.expectEqual(true, msg0.has_model_configured);
    try std.testing.expectEqual(@as(u8, 3), msg0.loading_frame);
    try std.testing.expectEqual(@as(u16, 7), msg0.blackhole_frame);

    const widget1 = MessageListBuilder.build(&builder, 1, 0);
    try std.testing.expect(widget1 != null);
    const msg1: *const MessageWidget = @ptrCast(@alignCast(widget1.?.userdata));
    try std.testing.expectEqual(true, msg1.selected);
    try std.testing.expectEqualStrings("second", msg1.message.bodyPtr().*);
}

test "MessageListBuilder.build handles empty transcript cleanly" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const builder: MessageListBuilder = .{
        .arena = arena.allocator(),
        .messages = &.{},
        .selected = null,
        .gpa = gpa,
        .has_model_configured = true,
    };

    try std.testing.expect(MessageListBuilder.build(&builder, 0, 0) == null);
    try std.testing.expect(MessageListBuilder.build(&builder, 1, 0) == null);
}

test "MessageListBuilder.build handles out-of-range selection index" {
    const gpa = std.testing.allocator;
    var transcript: transcript_mod.Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .user, "user", "msg1");
    _ = try transcript.append(gpa, .agent, "agent", "msg2");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const builder: MessageListBuilder = .{
        .arena = arena.allocator(),
        .messages = transcript.messages.items,
        .selected = 100, // Deliberately out of bounds
        .gpa = gpa,
        .has_model_configured = true,
    };

    const w0 = MessageListBuilder.build(&builder, 0, 0);
    try std.testing.expect(w0 != null);
    const m0: *const MessageWidget = @ptrCast(@alignCast(w0.?.userdata));
    try std.testing.expectEqual(false, m0.selected);

    const w1 = MessageListBuilder.build(&builder, 1, 0);
    try std.testing.expect(w1 != null);
    const m1: *const MessageWidget = @ptrCast(@alignCast(w1.?.userdata));
    try std.testing.expectEqual(false, m1.selected);
}
