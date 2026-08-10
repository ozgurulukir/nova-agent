const std = @import("std");
const nova = @import("nova");
const logger = @import("logger");

pub const std_options: std.Options = .{
    .unexpected_error_tracing = false,
    .logFn = novaLog,
};

fn novaLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = "[" ++ comptime level.asText() ++ "] (" ++ @tagName(scope) ++ ") ";
    logger.dispatch(level, @tagName(scope), prefix ++ format, args);
}

pub const panic = std.debug.FullPanic(novaPanic);

fn novaPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    std.debug.print("\x1b[?1049l\x1b[?1003l\x1b[?1000l\x1b[?25h\x1b[0m\r\n", .{});
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub fn runMain(init: std.process.Init, comptime runFn: anytype) !void {
    var page_allocator = std.heap.PageAllocator{};
    const gpa = std.mem.Allocator{ .ptr = &page_allocator, .vtable = &std.heap.PageAllocator.vtable };
    try runFn(init, gpa);
}

pub fn main(init: std.process.Init) !void {
    try runMain(init, nova.run);
}

test "runMain injects gpa and calls runner" {
    const Mock = struct {
        var called = false;
        fn run(init: std.process.Init, gpa: std.mem.Allocator) anyerror!void {
            _ = init;
            _ = gpa;
            called = true;
        }
    };
    // Safe to pass undefined since our Mock runner completely ignores the init value.
    const dummy_init: std.process.Init = undefined;
    try runMain(dummy_init, Mock.run);
    try std.testing.expect(Mock.called);
}
