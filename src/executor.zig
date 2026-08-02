//! The ExecutorService module: runs batches of ToolCalls and produces ToolResults.

const std = @import("std");

const ai = @import("ai.zig");
const background = @import("background.zig");
const bash_safety = @import("tools/bash_safety.zig");
const bash_tool = @import("tools/bash.zig");
const lua_mod = @import("lua/root.zig");
const mcp_mod = @import("mcp/manager.zig");
const tools = @import("tools.zig");
const tool_display = @import("tools/display.zig");

const assert = std.debug.assert;

/// Wiring for the background-bash path: the shared manager plus an opaque token
/// identifying the agent the job belongs to (the manager hands it back at
/// completion so the UI can route the delivery to the right lane). Threaded in
/// by the agent only when a `BackgroundManager` is attached.
pub const BackgroundStart = struct {
    manager: *background.BackgroundManager,
    owner: *anyopaque,
};

/// The output of one ToolCall, carrying both the LLM channel (the terse
/// observation that flows into history) and the human channel (display
/// label/body for the TUI) in one record.
pub const ToolResult = struct {
    /// LLM channel — the id this result is responding to.
    call_id: ai.CallId,
    /// LLM channel — the terse observation that flows into the assistant's
    /// next `tool` role message in history.
    content: []u8,
    /// Identity — the tool's name (e.g. "bash"). The TUI uses this to look
    /// up its display policy. Not strictly a channel — it's the same name
    /// the LM emitted.
    name: []u8,
    /// Human channel — the collapsed Display label.
    display_label: []u8,
    /// Human channel — label shown in place of `display_label` when expanded.
    display_expanded_label: ?[]u8,
    /// Human channel — the display body shown in the thread.
    display_body: []u8,
    /// Human channel — what `display_body` is (plain text or a diff). The TUI
    /// maps this to a draw style, overriding the per-tool-name policy.
    display_kind: tools.DisplayKind = .text,
    /// Human channel — stderr text rendered in red below the body, or null.
    stderr: ?[]u8,
    /// Human channel — overrides body styling to red at draw time.
    failed: bool,

    pub fn deinit(self: *ToolResult, gpa: std.mem.Allocator) void {
        gpa.free(self.call_id.value);
        gpa.free(self.content);
        gpa.free(self.name);
        gpa.free(self.display_label);
        if (self.display_expanded_label) |label| gpa.free(label);
        gpa.free(self.display_body);
        if (self.stderr) |s| gpa.free(s);
        self.* = undefined;
    }

    /// Build inputs for `ToolResult.init`. Split into "moved" (ownership
    /// transferred into the result on success; the caller keeps an `errdefer`
    /// for each until the call returns) and "borrowed" (`init` dupes these),
    /// so each call site states its intent explicitly instead of repeating
    /// the `call_id`/`name`/`stderr` dupe + struct-literal ladder inline.
    pub const Spec = struct {
        /// Borrowed; `init` dupes these.
        call_id: []const u8,
        name: []const u8,
        stderr: ?[]const u8 = null,
        /// MOVED into the result on success.
        content: []u8,
        display: tools.ToolDisplay,
        display_body: []u8,
        /// Copied by value.
        display_kind: tools.DisplayKind = .text,
        failed: bool = false,
    };

    /// Centralized constructor. Dupes `call_id`/`name`/`stderr` and assembles
    /// the result, adopting the moved fields (`content`, `display`,
    /// `display_body`) on success. `init` frees only the bytes it allocates
    /// (the dupes) on its own error; the caller's `errdefer`s still own the
    /// moved fields on that path, so the two never double-free. This removes
    /// the per-call-site identity-dupe + struct-literal boilerplate.
    pub fn init(gpa: std.mem.Allocator, spec: Spec) std.mem.Allocator.Error!ToolResult {
        const call_id = try gpa.dupe(u8, spec.call_id);
        errdefer gpa.free(call_id);
        const name = try gpa.dupe(u8, spec.name);
        errdefer gpa.free(name);
        const stderr = if (spec.stderr) |s| try gpa.dupe(u8, s) else null;
        errdefer if (stderr) |s| gpa.free(s);

        return .{
            .call_id = .{ .value = call_id },
            .content = spec.content,
            .name = name,
            .display_label = spec.display.label,
            .display_expanded_label = spec.display.expanded_label,
            .display_body = spec.display_body,
            .display_kind = spec.display_kind,
            .stderr = stderr,
            .failed = spec.failed,
        };
    }
};

/// The narrow private callback interface ExecutorService uses to report
/// ToolCall lifecycle back to the agent. `on_finished` receives a const
/// pointer into the executor's already-allocated result slot — no
/// projection allocation. Generic over the consumer's context type so
/// the callbacks receive `*Ctx` directly (no `@ptrCast` at the seam).
pub fn ToolCallObserver(Ctx: type) type {
    return struct {
        ctx: *Ctx,
        on_started: *const fn (ctx: *Ctx, call: ai.ToolCall) anyerror!void,
        on_finished: *const fn (ctx: *Ctx, result: *const ToolResult) anyerror!void,
        approve_unsafe_bash: *const fn (ctx: *Ctx, call: ai.ToolCall, arg: []const u8) anyerror!bool,
    };
}

/// Build a no-op `ToolCallObserver(Ctx)`. The ctx pointer is left
/// undefined — the callbacks ignore their context argument.
pub fn noopObserver(Ctx: type) ToolCallObserver(Ctx) {
    const Noop = struct {
        fn onStarted(_: *Ctx, _: ai.ToolCall) anyerror!void {}
        fn onFinished(_: *Ctx, _: *const ToolResult) anyerror!void {}
        fn approve(_: *Ctx, _: ai.ToolCall, _: []const u8) anyerror!bool {
            return true;
        }
    };
    return .{
        .ctx = undefined,
        .on_started = Noop.onStarted,
        .on_finished = Noop.onFinished,
        .approve_unsafe_bash = Noop.approve,
    };
}

pub const ExecutorService = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    bash_classifier_url: ?[]const u8 = null,
    background: ?BackgroundStart = null,
    /// MCP manager for dispatching `mcp__` tool calls. null disables MCP dispatch.
    mcp_manager: ?*mcp_mod.McpManager = null,
    /// Tool registry (builtin + plugin). null falls back to `builtinRegistry`
    /// only, which is what tests use.
    tool_registry: ?*tools.ToolRegistry = null,
    /// Pointer to the App's `plugin_manager`. Set on every by-value copy
    /// of the App so the dispatcher can reach the live field, no matter
    /// how many times the App has been copied through the run call
    /// chain (`init` → `initRuntime` → `run`). Without this, plugin
    /// tool dispatch segfaults because the `PluginToolKey.manager`
    /// indirection slot is written from `initRuntime`'s scope — which
    /// is freed by the time `run` calls `executor.runOne`.
    plugin_manager: ?*lua_mod.PluginManager = null,

    pub const InitOptions = struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        bash_classifier_url: ?[]const u8 = null,
        background: ?BackgroundStart = null,
        mcp_manager: ?*mcp_mod.McpManager = null,
        tool_registry: ?*tools.ToolRegistry = null,
        plugin_manager: ?*lua_mod.PluginManager = null,
    };

    pub fn init(options: InitOptions) ExecutorService {
        assert(options.cwd.len > 0);
        if (options.bash_classifier_url) |url| assert(url.len > 0);
        return .{
            .gpa = options.gpa,
            .io = options.io,
            .cwd = options.cwd,
            .bash_classifier_url = options.bash_classifier_url,
            .background = options.background,
            .mcp_manager = options.mcp_manager,
            .tool_registry = options.tool_registry,
            .plugin_manager = options.plugin_manager,
        };
    }

    /// Run a batch of ToolCalls. For each call:
    ///   1. `observer.on_started(call)` fires.
    ///   2. The tool runs via the Tool registry.
    ///   3. A ToolResult is built with both channels.
    ///   4. `observer.on_finished(&result)` fires with a const pointer.
    /// Returns an owned slice. The agent moves the LLM-channel fields into
    /// history via `Agent.takeToolResults` and frees the rest.
    pub fn runAll(
        self: *ExecutorService,
        calls: []const ai.ToolCall,
        observer: anytype,
    ) ![]ToolResult {
        const results = try self.gpa.alloc(ToolResult, calls.len);
        var initialized: usize = 0;
        errdefer {
            for (results[0..initialized]) |*r| r.deinit(self.gpa);
            self.gpa.free(results);
        }
        for (calls, 0..) |call, i| {
            try observer.on_started(observer.ctx, call);
            if (try self.shouldRejectUnsafeBash(call, observer)) {
                results[i] = try self.runRejected(call);
            } else {
                results[i] = try self.runOne(call);
            }
            initialized = i + 1;
            try observer.on_finished(observer.ctx, &results[i]);
        }
        return results;
    }

    fn shouldRejectUnsafeBash(self: *ExecutorService, call: ai.ToolCall, observer: anytype) !bool {
        const url = self.bash_classifier_url orelse return false;
        if (!std.mem.eql(u8, call.name, "bash")) return false;
        const command = bash_safety.commandFromArguments(self.gpa, call.arguments) catch return false;
        defer self.gpa.free(command);
        const verdict = bash_safety.classify(self.gpa, self.io, url, self.cwd, command);
        if (verdict != .unsafe) return false;
        const approved = try observer.approve_unsafe_bash(observer.ctx, call, command);
        return !approved;
    }

    fn runOne(self: *ExecutorService, call: ai.ToolCall) !ToolResult {
        // MCP tool calls are dispatched through the MCP manager, not the tool registry.
        if (std.mem.startsWith(u8, call.name, "mcp__")) {
            return self.runMcpTool(call);
        }
        // Plugin and builtin tool calls share one path: the registry's
        // `all` slice backs a single lookup, and the matched tool's `run`
        // callback routes through whatever `userdata` it carries (bash
        // ignores it, plugins carry their `(manager, plugin, tool)` key).
        var output = self.produceOutput(call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return self.runFailure(call, err),
        };
        defer output.deinit(self.gpa);

        const content = try tool_display.formatLlmObservation(self.gpa, output);
        errdefer self.gpa.free(content);
        const looked_up = if (self.tool_registry) |r|
            try r.lookup(self.gpa, call.name)
        else
            tools.lookupIn(tools.builtinRegistry(), call.name);
        var display = try tool_display.lookupDisplay(self.gpa, looked_up, call.name, call.arguments);
        errdefer display.deinit(self.gpa);
        const display_body = try tool_display.makeDisplayBody(self.gpa, output);
        errdefer self.gpa.free(display_body);

        // `ToolResult.init` dupes call_id/name/stderr and adopts the moved
        // fields above on success; the errdefers clean up only on error.
        return try ToolResult.init(self.gpa, .{
            .call_id = call.call_id.slice(),
            .name = call.name,
            .content = content,
            .display = display,
            .display_body = display_body,
            .stderr = if (output.stderr.len > 0) output.stderr else null,
            .display_kind = switch (output.display) {
                .diff => .diff,
                .text, .none => .text,
            },
            .failed = output.code != 0,
        });
    }

    /// Route an `mcp__` tool call to the MCP transport.
    /// Tool name format: `mcp__<server_name>__<tool_name>`
    fn runMcpTool(self: *ExecutorService, call: ai.ToolCall) !ToolResult {
        const manager = self.mcp_manager orelse return self.runFailure(call, error.McpNotConfigured);

        // Parse server name and tool name from `mcp__server__tool`
        const prefix = "mcp__";
        if (!std.mem.startsWith(u8, call.name, prefix)) return self.runFailure(call, error.InvalidMcpToolName);
        const rest = call.name[prefix.len..];
        const sep = std.mem.indexOfScalar(u8, rest, '_') orelse
            return self.runFailure(call, error.InvalidMcpToolName);
        // Skip the second underscore
        const after_server = rest[sep + 1 ..];
        if (after_server.len == 0 or after_server[0] != '_') return self.runFailure(call, error.InvalidMcpToolName);
        const server_name = rest[0..sep];
        const tool_name = after_server[1..];

        // Find the client
        const client = for (manager.clients.items) |*c| {
            if (c.status() == .connected and std.mem.eql(u8, c.name, server_name)) break c;
        } else return self.runFailure(call, error.McpServerNotFound);

        // Call the tool
        const result_text = client.callTool(self.io, tool_name, call.arguments) catch |err| {
            return self.runFailure(call, err);
        };

        const content = if (result_text.len > 0) blk: {
            break :blk result_text;
        } else blk: {
            self.gpa.free(result_text);
            break :blk try self.gpa.dupe(u8, "(no output)");
        };
        errdefer self.gpa.free(content);
        const display_label = try self.gpa.dupe(u8, tool_name);
        errdefer self.gpa.free(display_label);
        const display_body = try self.gpa.dupe(u8, content);
        errdefer self.gpa.free(display_body);

        // `ToolResult.init` dupes call_id/name (stderr stays null) and adopts
        // the moved fields above on success.
        return try ToolResult.init(self.gpa, .{
            .call_id = call.call_id.slice(),
            .name = call.name,
            .content = content,
            .display = .{ .label = display_label },
            .display_body = display_body,
        });
    }

    /// Source the tool's `Output`, routing a `run_in_background` bash call to the
    /// `BackgroundManager` (which spawns the job and returns immediately) and
    /// everything else through the tool registry (builtin + plugin, looked up
    /// in one shot).
    fn produceOutput(self: *ExecutorService, call: ai.ToolCall) tools.Error!tools.Output {
        if (self.background) |bg| {
            if (std.mem.eql(u8, call.name, "bash") and bash_tool.wantsBackground(self.gpa, call.arguments)) {
                return bash_tool.runBackground(self.gpa, self.io, self.cwd, call.arguments, bg.manager, bg.owner);
            }
        }
        if (self.tool_registry) |r| {
            // Plugin tool dispatchers reach `*PluginManager` through a
            // thread-local slot (the `Tool.run` signature is fixed and
            // can't take a `*ExecutorService`). The slot must point at
            // the live `self.plugin_manager` for the duration of the
            // call — set it here, dispatch, then clear it in a defer
            // so a panic doesn't leak a dangling pointer into the next
            // call.
            const prev = lua_mod.registry_bridge.plugin_manager_slot;
            lua_mod.registry_bridge.plugin_manager_slot = self.plugin_manager;
            defer lua_mod.registry_bridge.plugin_manager_slot = prev;
            const slice = try r.all(self.gpa);
            return tools.runWith(slice, self.gpa, self.io, self.cwd, call.name, call.arguments);
        }
        return tools.run(self.gpa, self.io, self.cwd, call.name, call.arguments);
    }

    fn runFailure(self: *ExecutorService, call: ai.ToolCall, err: anyerror) !ToolResult {
        var display = try tool_display.lookupDisplay(self.gpa, tools.lookupIn(tools.builtinRegistry(), call.name), call.name, call.arguments);
        errdefer display.deinit(self.gpa);
        const content = try std.fmt.allocPrint(self.gpa, "tool '{s}' failed to execute: {s}", .{ call.name, errorDescription(err) });
        errdefer self.gpa.free(content);
        const display_body = try self.gpa.dupe(u8, content);
        errdefer self.gpa.free(display_body);
        return try ToolResult.init(self.gpa, .{
            .call_id = call.call_id.slice(),
            .name = call.name,
            .content = content,
            .display = display,
            .display_body = display_body,
            .failed = true,
        });
    }

    fn runRejected(self: *ExecutorService, call: ai.ToolCall) !ToolResult {
        const message = "The tool call was rejected by the user for being unsafe. Try something else.";
        var display = try tool_display.lookupDisplay(self.gpa, tools.lookupIn(tools.builtinRegistry(), call.name), call.name, call.arguments);
        errdefer display.deinit(self.gpa);
        const content = try self.gpa.dupe(u8, message);
        errdefer self.gpa.free(content);
        const display_body = try self.gpa.dupe(u8, message);
        errdefer self.gpa.free(display_body);
        return try ToolResult.init(self.gpa, .{
            .call_id = call.call_id.slice(),
            .name = call.name,
            .content = content,
            .display = display,
            .display_body = display_body,
            .failed = true,
        });
    }
};

test "ExecutorService runs bash and returns both channels" {
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = cwd });

    const calls = [_]ai.ToolCall{
        .{
            .call_id = .{ .value = try gpa.dupe(u8, "call_0") },
            .name = try gpa.dupe(u8, "bash"),
            .arguments = try gpa.dupe(u8, "{\"command\":\"printf hello\",\"reason\":\"Print hello\"}"),
        },
    };
    defer for (calls) |c| {
        gpa.free(c.call_id.value);
        gpa.free(c.name);
        gpa.free(c.arguments);
    };

    const results = try executor.runAll(&calls, noopObserver(u8));
    defer {
        for (results) |*r| r.deinit(gpa);
        gpa.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("call_0", results[0].call_id.slice());
    try std.testing.expectEqualStrings("hello", results[0].content);
    try std.testing.expectEqualStrings("Print hello", results[0].display_label);
    try std.testing.expectEqualStrings("printf hello", results[0].display_expanded_label.?);
    try std.testing.expect(!results[0].failed);
}

test "executor converts a tool execution error into a failed result" {
    const gpa = std.testing.allocator;
    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = "/tmp" });
    const call: ai.ToolCall = .{
        .call_id = .{ .value = try gpa.dupe(u8, "call_x") },
        .name = try gpa.dupe(u8, "bash"),
        .arguments = try gpa.dupe(u8, "{\"command\":\"rg foo\",\"reason\":\"search\"}"),
    };
    defer {
        gpa.free(call.call_id.value);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    var result = try executor.runFailure(call, error.Unexpected);
    defer result.deinit(gpa);
    try std.testing.expect(result.failed);
    try std.testing.expectEqualStrings("call_x", result.call_id.slice());
    try std.testing.expectEqualStrings("search", result.display_label);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "failed to execute") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "Unexpected") != null);
}

test "executor rejected bash result is failed and model-facing" {
    const gpa = std.testing.allocator;
    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = "/tmp" });
    const call: ai.ToolCall = .{
        .call_id = .{ .value = try gpa.dupe(u8, "call_reject") },
        .name = try gpa.dupe(u8, "bash"),
        .arguments = try gpa.dupe(u8, "{\"command\":\"rm -rf /\",\"reason\":\"clean\"}"),
    };
    defer {
        gpa.free(call.call_id.value);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    var result = try executor.runRejected(call);
    defer result.deinit(gpa);
    try std.testing.expect(result.failed);
    try std.testing.expectEqualStrings("The tool call was rejected by the user for being unsafe. Try something else.", result.content);
    try std.testing.expectEqualStrings(result.content, result.display_body);
}

/// Map common Zig errors to human-readable descriptions for the model.
/// Falls back to @errorName for unmapped errors.
fn errorDescription(err: anyerror) []const u8 {
    return switch (err) {
        error.McpServerCrashed => "MCP server process terminated unexpectedly",
        error.Timeout => "MCP server did not respond within the timeout period",
        error.NotConnected => "MCP server is not connected",
        error.McpToolCallFailed => "MCP tool call failed on the server",
        error.McpServerNotFound => "MCP server not found",
        error.InvalidMcpToolName => "invalid MCP tool name format",
        error.McpNotConfigured => "no MCP manager is configured",
        error.NoTransport => "MCP server has no command or url configured",
        error.SseNotImplemented => "SSE transport is not yet supported",
        else => @errorName(err),
    };
}

test "executor converts errorDescription accurately" {
    try std.testing.expectEqualStrings("MCP server process terminated unexpectedly", errorDescription(error.McpServerCrashed));
    try std.testing.expectEqualStrings("MCP server did not respond within the timeout period", errorDescription(error.Timeout));
    try std.testing.expectEqualStrings("OutOfMemory", errorDescription(error.OutOfMemory));
}

test "ExecutorService shouldRejectUnsafeBash works" {
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = cwd });
    // Give it a mock URL so shouldRejectUnsafeBash doesn't immediately exit.
    executor.bash_classifier_url = "http://localhost:1234/classify";

    const ApprovalContext = struct {
        should_approve: bool = false,
    };
    const MockObserver = struct {
        fn onStarted(_: *ApprovalContext, _: ai.ToolCall) anyerror!void {}
        fn onFinished(_: *ApprovalContext, _: *const ToolResult) anyerror!void {}
        fn approve(ctx: *ApprovalContext, _: ai.ToolCall, _: []const u8) anyerror!bool {
            return ctx.should_approve;
        }
    };

    var ctx = ApprovalContext{};
    const observer: ToolCallObserver(ApprovalContext) = .{
        .ctx = &ctx,
        .on_started = MockObserver.onStarted,
        .on_finished = MockObserver.onFinished,
        .approve_unsafe_bash = MockObserver.approve,
    };

    // 1. Not a bash tool call => doesn't reject.
    const non_bash_call = ai.ToolCall{
        .call_id = .{ .value = try gpa.dupe(u8, "call_1") },
        .name = try gpa.dupe(u8, "not_bash"),
        .arguments = try gpa.dupe(u8, "{}"),
    };
    defer {
        gpa.free(non_bash_call.call_id.value);
        gpa.free(non_bash_call.name);
        gpa.free(non_bash_call.arguments);
    }
    try std.testing.expect(!(try executor.shouldRejectUnsafeBash(non_bash_call, observer)));

    // 2. Dangerous bash call with disapproval => reject.
    const unsafe_call = ai.ToolCall{
        .call_id = .{ .value = try gpa.dupe(u8, "call_2") },
        .name = try gpa.dupe(u8, "bash"),
        .arguments = try gpa.dupe(u8, "{\"command\":\"rm -rf /\",\"reason\":\"clean\"}"),
    };
    defer {
        gpa.free(unsafe_call.call_id.value);
        gpa.free(unsafe_call.name);
        gpa.free(unsafe_call.arguments);
    }
    ctx.should_approve = false;
    // When remote server is unreachable, local classifier kicks in, flags "rm -rf /" as unsafe
    // Observer disapproves => reject (returns true).
    try std.testing.expect(try executor.shouldRejectUnsafeBash(unsafe_call, observer));

    // 3. Dangerous bash call with approval => allow.
    ctx.should_approve = true;
    try std.testing.expect(!(try executor.shouldRejectUnsafeBash(unsafe_call, observer)));
}

test "ExecutorService.runAll errdefer cleanup exists" {
    // This test verifies the errdefer cleanup logic exists in runAll.
    // The errdefer deinitializes already-completed
    // results if a later tool call fails, preventing memory leaks.
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = cwd });

    const FailingObserverContext = struct {
        call_count: usize = 0,
    };
    const FailingObserver = struct {
        fn onStarted(ctx: *FailingObserverContext, _: ai.ToolCall) anyerror!void {
            ctx.call_count += 1;
            if (ctx.call_count == 2) return error.InjectedFailure;
        }
        fn onFinished(_: *FailingObserverContext, _: *const ToolResult) anyerror!void {}
        fn approve(_: *FailingObserverContext, _: ai.ToolCall, _: []const u8) anyerror!bool {
            return true;
        }
    };

    const calls = [_]ai.ToolCall{
        .{
            .call_id = .{ .value = try gpa.dupe(u8, "call_0") },
            .name = try gpa.dupe(u8, "bash"),
            .arguments = try gpa.dupe(u8, "{\"command\":\"printf test\",\"reason\":\"Test\"}"),
        },
        .{
            .call_id = .{ .value = try gpa.dupe(u8, "call_1") },
            .name = try gpa.dupe(u8, "bash"),
            .arguments = try gpa.dupe(u8, "{\"command\":\"printf fail\",\"reason\":\"Fail\"}"),
        },
    };
    defer for (calls) |c| {
        gpa.free(c.call_id.value);
        gpa.free(c.name);
        gpa.free(c.arguments);
    };

    var ctx = FailingObserverContext{};
    const observer: ToolCallObserver(FailingObserverContext) = .{
        .ctx = &ctx,
        .on_started = FailingObserver.onStarted,
        .on_finished = FailingObserver.onFinished,
        .approve_unsafe_bash = FailingObserver.approve,
    };

    try std.testing.expectError(error.InjectedFailure, executor.runAll(&calls, observer));
    try std.testing.expectEqual(@as(usize, 2), ctx.call_count);
}
