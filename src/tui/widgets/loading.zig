//! The transcript loading-spinner widget.
//!
//! Pulled out of `tui.zig` (R5.1c of `_pm/Projects/tui-split`) — the widget
//! is a thin wrapper that delegates the actual frame rendering to
//! `tui_message.MessageWidget.drawLoading`. INV-WIDGET-1: it carries only
//! the scalars it draws (no `App` reference); the per-frame construction
//! site computes them, so there is no staleness window.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui_message = @import("message.zig");
const tui_turn_view = @import("../turn_view.zig");

const loading_spinners = tui_turn_view.loading_spinners;

pub const LoadingWidget = struct {
    /// True while the lane's turn is streaming — the spinner only draws then.
    awaiting_output: bool,
    /// Current spinner word (`turn_view.loading_word_index`).
    word_index: u8,
    /// Animation frame counter (`metrics.loading_frame`).
    loading_frame: u8,

    pub fn widget(self: *LoadingWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = drawLoading,
        };
    }

    fn drawLoading(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *LoadingWidget = @ptrCast(@alignCast(ptr));
        const width = ctx.max.width orelse ctx.min.width;
        const height = ctx.max.height orelse ctx.min.height;
        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{
            .width = width,
            .height = height,
        });
        if (height > 0 and self.awaiting_output) {
            var row: u16 = if (height > 1) 1 else 0;
            const word = loading_spinners[self.word_index];
            tui_message.MessageWidget.drawLoading(&surface, word, self.loading_frame, &row, ctx);
        }
        return surface;
    }
};
