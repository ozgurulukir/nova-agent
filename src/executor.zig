//! The ExecutorService module: runs batches of ToolCalls and produces ToolResults.

const std = @import("std");

const agent_mod = @import("agent.zig");
const ai = @import("ai.zig");
const background = @import("background.zig");
const background_tool = @import("tools/background.zig");
const bash_tool = @import("tools/bash.zig");
const lane_bridge = @import("tools/lane_bridge.zig");
const lua_mod = @import("lua/root.zig");
const mcp_client_mod = @import("mcp/client.zig");
const mcp_mod = @import("mcp/manager.zig");
const os = @import("os.zig");
const pwsh_tool = @import("tools/pwsh.zig");
const schema_mod = @import("tools/schema.zig");
const shell_safety = @import("tools/bash_safety.zig");
const skill_mod = @import("skill.zig");
const skill_tool = @import("tools/skill.zig");
const tools = @import("tools.zig");
const tool_display = @import("tools/display.zig");
const executor_safety = @import("tools/executor_safety.zig");
const executor_validation = @import("tools/executor_validation.zig");

const assert = std.debug.assert;

/// The implementation module for the host shell. MUST stay in lockstep with
/// `registry.zig::shell_tool`: this selects the module whose `runContained` /
/// `wantsBackground` / `runBackground` surface is invoked, while the executor
/// routes calls on the canonical `registry.shell_tool.name` (the model-facing
/// name, not this alias). The two `if (os.is_windows)` selections are the ONLY
/// shell-selection points, and they mirror each other by construction.
const shell_tool = if (os.is_windows) pwsh_tool else bash_tool;

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
    /// Root-containment for lane workers (see `Agent.contained`): when set, a
    /// shell call is dispatched through `shell_tool.runContained`, which prepends
    /// a shell containment guard refusing to leave `cwd`. The guard is scoped
    /// here, not in the tool registry, so the driver's own shell (which
    /// legitimately changes into lane worktrees) is unaffected.
    contained: bool = false,
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
    /// The App-owned `LaneBridge` the `lane` tool posts its requests across,
    /// plus the requesting `*Agent` (as `*anyopaque`) that identifies the lane
    /// for the role guard and completion routing. Both are threaded through
    /// the slot in `produceOutput`; null disables the lane tool (headless).
    lane_bridge: ?*lane_bridge.LaneBridge = null,
    lane_requester: ?*anyopaque = null,
    skills: []const skill_mod.Skill = &.{},

    pub const InitOptions = struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        contained: bool = false,
        bash_classifier_url: ?[]const u8 = null,
        background: ?BackgroundStart = null,
        mcp_manager: ?*mcp_mod.McpManager = null,
        tool_registry: ?*tools.ToolRegistry = null,
        plugin_manager: ?*lua_mod.PluginManager = null,
        lane_bridge: ?*lane_bridge.LaneBridge = null,
        lane_requester: ?*anyopaque = null,
        skills: []const skill_mod.Skill = &.{},
    };

    pub fn init(options: InitOptions) ExecutorService {
        assert(options.cwd.len > 0);
        if (options.bash_classifier_url) |url| assert(url.len > 0);
        return .{
            .gpa = options.gpa,
            .io = options.io,
            .cwd = options.cwd,
            .contained = options.contained,
            .bash_classifier_url = options.bash_classifier_url,
            .background = options.background,
            .mcp_manager = options.mcp_manager,
            .tool_registry = options.tool_registry,
            .plugin_manager = options.plugin_manager,
            .lane_bridge = options.lane_bridge,
            .lane_requester = options.lane_requester,
            .skills = options.skills,
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
        // Shell-safety classifier URL for plugin `nova.run_bash`/`run_shell`
        // calls: set for the WHOLE batch, not just `produceOutput` — the
        // observers below fire plugin event callbacks (emitEvent → Lua) after
        // produceOutput's slots are unwound, and a handler shelling out there
        // must classify with the same remote classifier as the builtin tool.
        // Null (headless/tests) keeps the always-armed local matcher.
        const prev_classifier_url = lua_mod.bridge.bash_classifier_url_slot;
        lua_mod.bridge.bash_classifier_url_slot = self.bash_classifier_url;
        defer lua_mod.bridge.bash_classifier_url_slot = prev_classifier_url;

        // Plugin cwd slot for the whole batch: observer-driven event callbacks
        // (on_started/on_finished → emitEvent → drainEventCallbacks) fire
        // outside produceOutput's dispatch window, but still inside runAll on
        // the same thread. Setting it here ensures all plugin bridges see the
        // correct effective cwd (lane worktree OR resumed session) even from
        // event handlers. Refreshed by rerootFromRequester on mid-batch lane ops.
        const prev_cwd_slot = lua_mod.bridge.plugin_cwd_slot;
        lua_mod.bridge.plugin_cwd_slot = self.cwd;
        defer lua_mod.bridge.plugin_cwd_slot = prev_cwd_slot;

        const results = try self.gpa.alloc(ToolResult, calls.len);
        var initialized: usize = 0;
        errdefer {
            for (results[0..initialized]) |*r| r.deinit(self.gpa);
            self.gpa.free(results);
        }
        for (calls, 0..) |call, i| {
            try observer.on_started(observer.ctx, call);
            if (try self.shouldRejectUnsafeShell(call, observer)) {
                results[i] = try self.runRejected(call);
            } else {
                results[i] = try self.runOne(call);
            }
            initialized = i + 1;
            try observer.on_finished(observer.ctx, &results[i]);
            // A `lane enter`/`leave` in this batch re-rooted the requester's
            // workspace mid-batch; refresh so the remaining calls run at the
            // new root instead of the batch-start snapshot.
            if (std.mem.eql(u8, call.name, "lane")) self.rerootFromRequester();
        }
        return results;
    }

    /// Refresh `cwd` from the requester's live workspace after a `lane` call:
    /// `enter`/`leave` write `Agent.workspace` (via `setWorkspace`) before the
    /// tool returns, so the remaining calls in the batch must run at the new
    /// root, not the batch-start snapshot. No-op when no requester is attached
    /// (headless/tests) or when the workspace didn't change.
    fn rerootFromRequester(self: *ExecutorService) void {
        const ptr = self.lane_requester orelse return;
        const agent: *agent_mod.Agent = @ptrCast(@alignCast(ptr));
        self.cwd = agent.effectiveCwd();
        // Keep plugin_cwd_slot in sync: private fn, single call site inside
        // runAll's slot window by construction.
        lua_mod.bridge.plugin_cwd_slot = self.cwd;
    }

    fn shouldRejectUnsafeShell(self: *ExecutorService, call: ai.ToolCall, observer: anytype) !bool {
        return executor_safety.shouldRejectUnsafeShell(self.gpa, self.io, self.bash_classifier_url, self.cwd, call, observer);
    }

    /// Run one ToolCall. Tool arguments are validated against the tool's
    /// schema BEFORE dispatch, in a single choke point shared by all three
    /// channels (builtin / plugin / MCP): an invalid call returns a structured
    /// validation error to the model instead of letting the tool run on garbage
    /// input. Unknown tools (no schema) skip validation and dispatch — they
    /// already fail in `produceOutput`.
    fn runOne(self: *ExecutorService, call: ai.ToolCall) !ToolResult {
        if (self.resolveSchema(call)) |schema| {
            var validation_info = try executor_validation.validateAndCoerceCallArgs(self.gpa, schema, call);
            defer validation_info.deinit(self.gpa);

            if (!validation_info.validation.isValid()) {
                return self.runValidationError(call, &validation_info.validation);
            }
            // Dispatch the (possibly coerced) args so the tool receives real
            // numbers, not quoted strings. A shallow copy swaps only the
            // arguments slice; the rest of `call` is untouched and the coerced
            // buffer stays alive for the duration of dispatch.
            var effective = call;
            effective.arguments = validation_info.args;
            return self.dispatchCall(effective);
        }
        return self.dispatchCall(call);
    }

    /// Resolve the `tools.Schema` for a call across all three channels.
    /// Returns null when the tool is unknown — validation is then skipped.
    fn resolveSchema(self: *ExecutorService, call: ai.ToolCall) ?tools.Schema {
        return executor_validation.resolveSchema(self.tool_registry, self.mcp_manager, self.gpa, call);
    }

    /// Dispatch a call that passed validation. MCP calls route through the
    /// manager; plugin and builtin calls share the registry-backed path.
    fn dispatchCall(self: *ExecutorService, call: ai.ToolCall) !ToolResult {
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
            r.lookup(call.name)
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
        // The `lane` tool reaches the App-owned bridge + the requesting agent
        // through a thread-local slot (the `Tool.run` signature is fixed and
        // can't take a `*ExecutorService`). Set it around the WHOLE dispatch —
        // both the registry branch below and the registry-less fallback — so a
        // headless run never reads a stale slot, and restore in a defer so a
        // panic doesn't leak a dangling pointer into the next call.
        const prev_lane = lane_bridge.lane_bridge_slot;
        lane_bridge.lane_bridge_slot = .{ .bridge = self.lane_bridge, .requester = self.lane_requester };
        defer lane_bridge.lane_bridge_slot = prev_lane;

        const prev_bg = background_tool.background_slot;
        background_tool.background_slot = if (self.background) |bg|
            .{ .manager = bg.manager, .owner = bg.owner }
        else
            .{};
        defer background_tool.background_slot = prev_bg;

        const prev_skills = skill_tool.skills_slot;
        skill_tool.skills_slot = self.skills;
        defer skill_tool.skills_slot = prev_skills;
        if (self.contained) {
            // Lane worker: route through `runContained`, which prepends the
            // shell containment guard before running (background or foreground).
            // This bypasses the registry so the fixed `Tool.run` signature —
            // shared with plugins — stays untouched.
            if (std.mem.eql(u8, call.name, tools.shell_tool.name)) {
                const background_ctx: ?shell_tool.BackgroundCtx = if (self.background) |bg|
                    .{ .manager = bg.manager, .owner = bg.owner }
                else
                    null;
                return shell_tool.runContained(self.gpa, self.io, self.cwd, call.arguments, background_ctx);
            }
        }
        if (self.background) |bg| {
            if (std.mem.eql(u8, call.name, tools.shell_tool.name) and shell_tool.wantsBackground(self.gpa, call.arguments)) {
                return shell_tool.runBackground(self.gpa, self.io, self.cwd, call.arguments, bg.manager, bg.owner);
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
            const prev_cwd = lua_mod.bridge.plugin_cwd_slot;
            lua_mod.bridge.plugin_cwd_slot = self.cwd;
            const prev_classifier_url = lua_mod.bridge.bash_classifier_url_slot;
            lua_mod.bridge.bash_classifier_url_slot = self.bash_classifier_url;
            defer {
                lua_mod.registry_bridge.plugin_manager_slot = prev;
                lua_mod.bridge.plugin_cwd_slot = prev_cwd;
                lua_mod.bridge.bash_classifier_url_slot = prev_classifier_url;
            }
            const slice = try r.all(self.gpa);
            return tools.runWith(slice, self.gpa, self.io, self.cwd, call.name, call.arguments);
        }
        return tools.run(self.gpa, self.io, self.cwd, call.name, call.arguments);
    }

    /// Validation error — the tool never ran; the model sent bad arguments.
    /// Distinct from `runFailure` (execution errors): the message carries the
    /// structured violation list the model can act on directly.
    fn runValidationError(
        self: *ExecutorService,
        call: ai.ToolCall,
        validation: *const schema_mod.ValidationResult,
    ) !ToolResult {
        const detail = try validation.formatMessage(self.gpa);
        defer self.gpa.free(detail);
        const content = try std.fmt.allocPrint(self.gpa, "Invalid arguments for tool '{s}': {s}", .{ call.name, detail });
        errdefer self.gpa.free(content);

        var display = try tool_display.lookupDisplay(self.gpa, tools.lookupIn(tools.builtinRegistry(), call.name), call.name, call.arguments);
        errdefer display.deinit(self.gpa);
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
    // Bash-syntax spawn test — runs only on bash hosts (POSIX). On Windows the
    // model-facing shell is pwsh; `printf hello` is not valid PowerShell, and the
    // mirror test "executor runs pwsh and returns both channels" covers that host.
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = cwd });

    const calls = [_]ai.ToolCall{
        .{
            .call_id = .{ .value = try gpa.dupe(u8, "call_0") },
            .name = try gpa.dupe(u8, shell_tool.tool.name),
            .arguments = try gpa.dupe(u8, "{\"command\":\"printf hello\",\"description\":\"Print hello\"}"),
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
    // The model-facing observation echoes the command first.
    try std.testing.expect(std.mem.indexOf(u8, results[0].content, "hello") != null);
    try std.testing.expectEqualStrings("Print hello", results[0].display_label);
    try std.testing.expectEqualStrings("printf hello", results[0].display_expanded_label.?);
    try std.testing.expect(!results[0].failed);
}

test "executor runs pwsh and returns both channels" {
    // PowerShell-syntax spawn test — runs only on Windows (pwsh host).
    if (!os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = cwd });

    const calls = [_]ai.ToolCall{
        .{
            .call_id = .{ .value = try gpa.dupe(u8, "call_0") },
            .name = try gpa.dupe(u8, shell_tool.tool.name),
            .arguments = try gpa.dupe(u8, "{\"command\":\"Write-Output hello\",\"description\":\"Print hello\"}"),
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
    try std.testing.expect(std.mem.indexOf(u8, results[0].content, "hello") != null);
    try std.testing.expectEqualStrings("Print hello", results[0].display_label);
    try std.testing.expectEqualStrings("Write-Output hello", results[0].display_expanded_label.?);
    try std.testing.expect(!results[0].failed);
}

test "executor converts a tool execution error into a failed result" {
    const gpa = std.testing.allocator;
    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = "/tmp" });
    const call: ai.ToolCall = .{
        .call_id = .{ .value = try gpa.dupe(u8, "call_x") },
        .name = try gpa.dupe(u8, shell_tool.tool.name),
        .arguments = try gpa.dupe(u8, "{\"command\":\"search\",\"description\":\"search\"}"),
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

test "executor rejected shell result is failed and model-facing" {
    const gpa = std.testing.allocator;
    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = "/tmp" });
    const call: ai.ToolCall = .{
        .call_id = .{ .value = try gpa.dupe(u8, "call_reject") },
        .name = try gpa.dupe(u8, shell_tool.tool.name),
        .arguments = try gpa.dupe(u8, "{\"command\":\"rm -rf /\",\"description\":\"clean\"}"),
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

test "ExecutorService shouldRejectUnsafeShell consults the approval hook" {
    // No classifier URL configured (the default) routes straight through the
    // local destructive-command matcher — no network, and no spawn (the call
    // is rejected before dispatch), so this runs identically on both hosts.
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = cwd });

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

    // 1. Not a shell tool call => never rejected, approval hook not consulted.
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
    try std.testing.expect(!(try executor.shouldRejectUnsafeShell(non_bash_call, observer)));

    // 2. The local matcher flags `rm -rf /` unsafe and the observer declines
    //    => the call is rejected.
    const unsafe_call = ai.ToolCall{
        .call_id = .{ .value = try gpa.dupe(u8, "call_2") },
        .name = try gpa.dupe(u8, shell_tool.tool.name),
        .arguments = try gpa.dupe(u8, "{\"command\":\"rm -rf /\",\"description\":\"clean\"}"),
    };
    defer {
        gpa.free(unsafe_call.call_id.value);
        gpa.free(unsafe_call.name);
        gpa.free(unsafe_call.arguments);
    }
    ctx.should_approve = false;
    try std.testing.expect(try executor.shouldRejectUnsafeShell(unsafe_call, observer));

    // 3. Same unsafe call, but the observer approves => allowed.
    ctx.should_approve = true;
    try std.testing.expect(!(try executor.shouldRejectUnsafeShell(unsafe_call, observer)));
}

test "ExecutorService.runAll errdefer cleanup exists" {
    // This test verifies the errdefer cleanup logic in runAll (lines 202-205).
    // The errdefer deinitializes already-completed results if a later tool
    // call fails, preventing memory leaks.
    //
    // Strategy: add a 2nd tool call whose on_started errors, so initialized=1
    // when the error fires and the errdefer loop deinits results[0].
    // std.testing.allocator catches any leak if cleanup is wrong.
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = cwd });

    const calls = [_]ai.ToolCall{
        .{
            .call_id = .{ .value = try gpa.dupe(u8, "call_0") },
            .name = try gpa.dupe(u8, shell_tool.tool.name),
            .arguments = try gpa.dupe(u8, "{\"command\":\"printf test\",\"description\":\"Test\"}"),
        },
        .{
            .call_id = .{ .value = try gpa.dupe(u8, "call_1") },
            .name = try gpa.dupe(u8, shell_tool.tool.name),
            .arguments = try gpa.dupe(u8, "{\"command\":\"printf fail\",\"description\":\"Fail\"}"),
        },
    };
    defer for (calls) |c| {
        gpa.free(c.call_id.value);
        gpa.free(c.name);
        gpa.free(c.arguments);
    };

    const FailOnSecond = struct {
        call_count: usize = 0,
        fn onStarted(ctx: *@This(), _: ai.ToolCall) anyerror!void {
            ctx.call_count += 1;
            if (ctx.call_count == 2) return error.TestError;
        }
        fn onFinished(_: *@This(), _: *const ToolResult) anyerror!void {}
        fn approve(_: *@This(), _: ai.ToolCall, _: []const u8) anyerror!bool {
            return true;
        }
    };

    var fail_state = FailOnSecond{};
    const observer = ToolCallObserver(FailOnSecond){
        .ctx = &fail_state,
        .on_started = FailOnSecond.onStarted,
        .on_finished = FailOnSecond.onFinished,
        .approve_unsafe_bash = FailOnSecond.approve,
    };

    try std.testing.expectError(error.TestError, executor.runAll(&calls, observer));
}

// ── Schema validation tests (builtin / plugin / MCP) ──

// Test doubles for fake plugin tools: validation rejects before `run` ever
// fires, but `addPluginTool` requires well-formed callbacks.
const test_dummy_free: *const fn (gpa: std.mem.Allocator, ud: *anyopaque) void = struct {
    fn free(gpa: std.mem.Allocator, ud: *anyopaque) void {
        _ = gpa;
        _ = ud;
    }
}.free;

const test_dummy_run: *const fn (
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    args: []const u8,
    userdata: *anyopaque,
) tools.Error!tools.Output = struct {
    fn run(
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        args: []const u8,
        userdata: *anyopaque,
    ) tools.Error!tools.Output {
        _ = io;
        _ = cwd;
        _ = args;
        _ = userdata;
        const stdout = try gpa.dupe(u8, "ok");
        const stderr = try gpa.alloc(u8, 0);
        return .{ .stdout = stdout, .stderr = stderr, .code = 0 };
    }
}.run;

const test_dummy_display: *const fn (
    gpa: std.mem.Allocator,
    args: []const u8,
    userdata: *anyopaque,
) std.mem.Allocator.Error!tools.ToolDisplay = struct {
    fn display(
        gpa: std.mem.Allocator,
        args: []const u8,
        userdata: *anyopaque,
    ) std.mem.Allocator.Error!tools.ToolDisplay {
        _ = args;
        _ = userdata;
        return .{ .label = try gpa.dupe(u8, "dummy") };
    }
}.display;

/// Register a fake plugin tool with a required string enum property, the
/// `lua__<plugin>__<tool>` shape the registry dispatches.
fn addPluginModeTool(gpa: std.mem.Allocator, registry: *tools.ToolRegistry) !void {
    const name = try gpa.dupe(u8, "lua__p__mode");
    errdefer gpa.free(name);
    const desc = try gpa.dupe(u8, "plugin mode tool");
    errdefer gpa.free(desc);
    try registry.addPluginTool(gpa, .{
        .name = name,
        .description = desc,
        .schema = .{ .properties = &.{
            .{
                .name = "mode",
                .kind = .string,
                .description = "Run mode",
                .required = true,
                .enum_values = &.{ "fast", "slow" },
            },
        } },
        .run = test_dummy_run,
        .display = test_dummy_display,
        .userdata = undefined,
        .userdata_free = test_dummy_free,
    });
}

/// Attach a connected stdio client named `test` carrying one tool
/// `mcp__test__search` with a required string `query` property. The client has
/// no live process — validation rejects before any transport I/O.
///
/// The properties array is heap-allocated (not a `&.{…}` compound literal,
/// which lives on this frame's stack): `McpTool.deinit` frees each property's
/// `name`/`description` and reads the array back when the manager is torn
/// down, long after this helper has returned.
fn addTestMcpSearchTool(gpa: std.mem.Allocator, manager: *mcp_mod.McpManager) !void {
    const props = try gpa.alloc(tools.Schema.Property, 1);
    errdefer gpa.free(props);
    props[0] = .{
        .name = try gpa.dupe(u8, "query"),
        .kind = .string,
        .description = try gpa.dupe(u8, "Query text"),
        .required = true,
    };
    var client = try mcp_client_mod.McpClient.init(gpa, "test", "echo", &.{}, null);
    client.lifecycle = .{
        .stdio = .{
            .process = mcp_client_mod.zeroedChild(),
            .status = .ready,
        },
    };
    try client.addTool("search", "Search the index", .{ .properties = props });
    try manager.clients.append(gpa, client);
}

fn makeCall(gpa: std.mem.Allocator, id: []const u8, name: []const u8, args: []const u8) !ai.ToolCall {
    return .{
        .call_id = .{ .value = try gpa.dupe(u8, id) },
        .name = try gpa.dupe(u8, name),
        .arguments = try gpa.dupe(u8, args),
    };
}

test "valid bash call still dispatches after schema validation" {
    // Positive control: the runAll happy path (bash host). On Windows the model
    // faces pwsh; the mirror "valid pwsh call still dispatches" covers that host.
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = cwd });

    const call = try makeCall(gpa, "call_ok", shell_tool.tool.name, "{\"command\":\"printf ok\",\"description\":\"Print ok\"}");
    defer {
        gpa.free(call.call_id.value);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    var result = try executor.runOne(call);
    defer result.deinit(gpa);
    try std.testing.expect(!result.failed);
    // The model-facing observation echoes the command first.
    try std.testing.expect(std.mem.indexOf(u8, result.content, "ok") != null);
}

test "valid pwsh call still dispatches after schema validation" {
    // Windows-only mirror of the positive-control above (pwsh host).
    if (!os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const cwd = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd);
    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = cwd });

    const call = try makeCall(gpa, "call_ok", shell_tool.tool.name, "{\"command\":\"Write-Output pwsh-ok\",\"description\":\"Print ok\"}");
    defer {
        gpa.free(call.call_id.value);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    var result = try executor.runOne(call);
    defer result.deinit(gpa);
    try std.testing.expect(!result.failed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "pwsh-ok") != null);
}

test "executor rejects bash call with missing required argument" {
    const gpa = std.testing.allocator;
    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = "/tmp" });

    const call = try makeCall(gpa, "call_v", shell_tool.tool.name, "{}");
    defer {
        gpa.free(call.call_id.value);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    var result = try executor.runOne(call);
    defer result.deinit(gpa);
    try std.testing.expect(result.failed);
    const prefix = try std.fmt.allocPrint(gpa, "Invalid arguments for tool '{s}'", .{shell_tool.tool.name});
    defer gpa.free(prefix);
    try std.testing.expect(std.mem.indexOf(u8, result.content, prefix) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "`command` is required") != null);
}

test "executor rejects bash call with wrong type" {
    const gpa = std.testing.allocator;
    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = "/tmp" });

    const call = try makeCall(gpa, "call_t", shell_tool.tool.name, "{\"command\":42}");
    defer {
        gpa.free(call.call_id.value);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    var result = try executor.runOne(call);
    defer result.deinit(gpa);
    try std.testing.expect(result.failed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "`command` must be string") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "(got: 42)") != null);
}

test "executor rejects bash call with invalid JSON" {
    const gpa = std.testing.allocator;
    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = "/tmp" });

    const call = try makeCall(gpa, "call_j", shell_tool.tool.name, "{bad");
    defer {
        gpa.free(call.call_id.value);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    var result = try executor.runOne(call);
    defer result.deinit(gpa);
    try std.testing.expect(result.failed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "must be valid JSON") != null);
}

test "executor rejects plugin tool call with enum violation" {
    const gpa = std.testing.allocator;
    var registry = try tools.ToolRegistry.init(gpa, tools.builtinRegistry());
    defer registry.deinit(gpa);
    try addPluginModeTool(gpa, &registry);

    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = "/tmp", .tool_registry = &registry });

    const call = try makeCall(gpa, "call_e", "lua__p__mode", "{\"mode\":\"turbo\"}");
    defer {
        gpa.free(call.call_id.value);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    var result = try executor.runOne(call);
    defer result.deinit(gpa);
    try std.testing.expect(result.failed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "`mode` must be one of: fast, slow") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "turbo") != null);
}

test "executor rejects plugin tool call with missing required argument" {
    const gpa = std.testing.allocator;
    var registry = try tools.ToolRegistry.init(gpa, tools.builtinRegistry());
    defer registry.deinit(gpa);
    try addPluginModeTool(gpa, &registry);

    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = "/tmp", .tool_registry = &registry });

    const call = try makeCall(gpa, "call_m", "lua__p__mode", "{}");
    defer {
        gpa.free(call.call_id.value);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    var result = try executor.runOne(call);
    defer result.deinit(gpa);
    try std.testing.expect(result.failed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "`mode` is required") != null);
}

test "executor rejects plugin tool call with wrong type" {
    const gpa = std.testing.allocator;
    var registry = try tools.ToolRegistry.init(gpa, tools.builtinRegistry());
    defer registry.deinit(gpa);
    try addPluginModeTool(gpa, &registry);

    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = "/tmp", .tool_registry = &registry });

    const call = try makeCall(gpa, "call_pt", "lua__p__mode", "{\"mode\":42}");
    defer {
        gpa.free(call.call_id.value);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    var result = try executor.runOne(call);
    defer result.deinit(gpa);
    try std.testing.expect(result.failed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "`mode` must be string") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "(got: 42)") != null);
}

test "executor rejects plugin tool call with invalid JSON" {
    const gpa = std.testing.allocator;
    var registry = try tools.ToolRegistry.init(gpa, tools.builtinRegistry());
    defer registry.deinit(gpa);
    try addPluginModeTool(gpa, &registry);

    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = "/tmp", .tool_registry = &registry });

    const call = try makeCall(gpa, "call_pj", "lua__p__mode", "{bad");
    defer {
        gpa.free(call.call_id.value);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    var result = try executor.runOne(call);
    defer result.deinit(gpa);
    try std.testing.expect(result.failed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "must be valid JSON") != null);
}

test "executor rejects MCP tool call with missing required field" {
    const gpa = std.testing.allocator;
    var manager = mcp_mod.McpManager.init(gpa);
    defer manager.deinit(std.testing.io);
    try addTestMcpSearchTool(gpa, &manager);

    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = "/tmp", .mcp_manager = &manager });

    const call = try makeCall(gpa, "call_mcp", "mcp__test__search", "{}");
    defer {
        gpa.free(call.call_id.value);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    var result = try executor.runOne(call);
    defer result.deinit(gpa);
    try std.testing.expect(result.failed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "`query` is required") != null);
}

test "ExecutorService.runAll sets plugin_cwd_slot around observer callbacks" {
    // POSIX-gated: uses tmpDir for a temp dir whose path differs from the
    // process cwd, simulating the lane/resume differential.
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_abs = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd_abs);
    const fake_cwd = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(fake_cwd);

    // Recording observer captures plugin_cwd_slot at on_started and on_finished.
    const Recording = struct {
        started_slot: ?[]const u8 = null,
        finished_slot: ?[]const u8 = null,
    };
    var rec = Recording{};

    const Obs = struct {
        pub fn onStarted(ctx: *Recording, _: ai.ToolCall) anyerror!void {
            ctx.started_slot = lua_mod.bridge.plugin_cwd_slot;
        }
        pub fn onFinished(ctx: *Recording, _: *const ToolResult) anyerror!void {
            ctx.finished_slot = lua_mod.bridge.plugin_cwd_slot;
        }
        pub fn approve(_: *Recording, _: ai.ToolCall, _: []const u8) anyerror!bool {
            return true;
        }
    };

    var executor = ExecutorService.init(.{
        .gpa = gpa,
        .io = std.testing.io,
        .cwd = fake_cwd,
        .tool_registry = null,
        .mcp_manager = null,
        .lane_bridge = null,
        .lane_requester = null,
    });

    // Use a non-empty call list so observer fires. We use a call with an
    // unknown tool name that will produce a failure result quickly.
    const calls = [_]ai.ToolCall{
        try makeCall(gpa, "call_1", "nonexistent_tool", "{}"),
    };
    defer for (calls) |c| {
        gpa.free(c.call_id.value);
        gpa.free(c.name);
        gpa.free(c.arguments);
    };

    const observer: ToolCallObserver(Recording) = .{
        .ctx = &rec,
        .on_started = Obs.onStarted,
        .on_finished = Obs.onFinished,
        .approve_unsafe_bash = Obs.approve,
    };
    const results = try executor.runAll(&calls, observer);
    defer {
        for (results) |*r| r.deinit(gpa);
        gpa.free(results);
    }

    try std.testing.expectEqualStrings(fake_cwd, rec.started_slot orelse "");
    try std.testing.expectEqualStrings(fake_cwd, rec.finished_slot orelse "");
    // Verify slot is restored after runAll
    try std.testing.expect(lua_mod.bridge.plugin_cwd_slot == null);
}

test "executor rejects MCP tool call with wrong type" {
    const gpa = std.testing.allocator;
    var manager = mcp_mod.McpManager.init(gpa);
    defer manager.deinit(std.testing.io);
    try addTestMcpSearchTool(gpa, &manager);

    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = "/tmp", .mcp_manager = &manager });

    const call = try makeCall(gpa, "call_mcp", "mcp__test__search", "{\"query\":42}");
    defer {
        gpa.free(call.call_id.value);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    var result = try executor.runOne(call);
    defer result.deinit(gpa);
    try std.testing.expect(result.failed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "`query` must be string") != null);
}

test "executor rejects MCP tool call with invalid JSON" {
    const gpa = std.testing.allocator;
    var manager = mcp_mod.McpManager.init(gpa);
    defer manager.deinit(std.testing.io);
    try addTestMcpSearchTool(gpa, &manager);

    var executor = ExecutorService.init(.{ .gpa = gpa, .io = std.testing.io, .cwd = "/tmp", .mcp_manager = &manager });

    const call = try makeCall(gpa, "call_mcp", "mcp__test__search", "{bad");
    defer {
        gpa.free(call.call_id.value);
        gpa.free(call.name);
        gpa.free(call.arguments);
    }

    var result = try executor.runOne(call);
    defer result.deinit(gpa);
    try std.testing.expect(result.failed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "must be valid JSON") != null);
}

// ── Mid-batch re-rooting tests (C1) ──

/// Outcome shuttle for running `runAll` on a worker thread while the main
/// thread services the bridge.
const RerootOutcome = struct {
    results: []ToolResult = &.{},
    err: ?anyerror = null,
    /// Captured plugin_cwd_slot value at on_started of the post-enter call.
    captured_slot: ?[]const u8 = null,
};

/// Spin until the bridge has a pending request, then service until `done` —
/// covers batches that post several lane ops in sequence.
fn serviceUntilDone(
    bridge: *lane_bridge.LaneBridge,
    ctx: *anyopaque,
    handler: *const fn (*anyopaque, *const lane_bridge.Request) ?lane_bridge.Response,
    done: *const std.atomic.Value(bool),
) void {
    while (!done.load(.acquire)) {
        bridge.service(std.testing.io, ctx, handler);
        std.testing.io.sleep(.fromMilliseconds(2), .awake) catch {};
    }
    // Drain anything posted between the last service and the done flag.
    bridge.service(std.testing.io, ctx, handler);
}

test "executor re-roots mid-batch after lane enter" {
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    // The lane worktree the fake UI resolves `enter` with.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_abs = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd_abs);
    const lane_path = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(lane_path);

    var agent = agent_mod.Agent.init(gpa, std.testing.io, cwd_abs, .none);
    defer agent.deinit();
    var bridge: lane_bridge.LaneBridge = .{};

    const Handler = struct {
        fn handle(ctx: *anyopaque, req: *const lane_bridge.Request) ?lane_bridge.Response {
            const path: *const []u8 = @ptrCast(@alignCast(ctx));
            std.debug.assert(req.op == .enter);
            return lane_bridge.response(std.testing.allocator, "entered\n", .{}, null, path.*) catch unreachable;
        }
    };

    const SlotObserver = struct {
        pub fn on_started(ctx: *RerootOutcome, _: ai.ToolCall) !void {
            ctx.captured_slot = lua_mod.bridge.plugin_cwd_slot;
        }
        pub fn on_finished(_: *RerootOutcome, _: *const ToolResult) !void {}
        pub fn approve_unsafe_bash(_: *RerootOutcome, _: ai.ToolCall, _: []const u8) anyerror!bool {
            return true;
        }
    };

    const calls = [_]ai.ToolCall{
        try makeCall(gpa, "call_enter", "lane", "{\"command\":\"enter\",\"lane\":\"abc\"}"),
        try makeCall(gpa, "call_pwd", shell_tool.tool.name, "{\"command\":\"pwd\",\"description\":\"Show cwd\"}"),
    };
    defer for (calls) |c| {
        gpa.free(c.call_id.value);
        gpa.free(c.name);
        gpa.free(c.arguments);
    };

    var executor = ExecutorService.init(.{
        .gpa = gpa,
        .io = std.testing.io,
        .cwd = cwd_abs,
        .lane_bridge = &bridge,
        .lane_requester = &agent,
    });

    const Worker = struct {
        fn run(exec: *ExecutorService, batch: []const ai.ToolCall, out: *RerootOutcome, done: *std.atomic.Value(bool)) void {
            const observer: ToolCallObserver(RerootOutcome) = .{
                .ctx = out,
                .on_started = SlotObserver.on_started,
                .on_finished = SlotObserver.on_finished,
                .approve_unsafe_bash = SlotObserver.approve_unsafe_bash,
            };
            out.results = exec.runAll(batch, observer) catch |err| {
                out.err = err;
                done.store(true, .release);
                return;
            };
            done.store(true, .release);
        }
    };

    var outcome = RerootOutcome{};
    var done: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ &executor, &calls, &outcome, &done });
    const lane_ctx: *anyopaque = @ptrCast(@constCast(&lane_path));
    serviceUntilDone(&bridge, lane_ctx, &Handler.handle, &done);
    thread.join();

    if (outcome.err) |err| return err;
    defer {
        for (outcome.results) |*r| r.deinit(gpa);
        gpa.free(outcome.results);
    }
    try std.testing.expectEqual(@as(usize, 2), outcome.results.len);
    try std.testing.expect(!outcome.results[1].failed);
    // The bash call after `enter` ran in the lane worktree, not the batch-start root.
    try std.testing.expect(std.mem.indexOf(u8, outcome.results[1].content, lane_path) != null);
    // Verify plugin_cwd_slot was refreshed to the lane path for the post-enter call.
    try std.testing.expectEqualStrings(lane_path, outcome.captured_slot orelse "");
}

test "executor re-roots back on lane leave" {
    if (os.is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd_abs = try std.process.currentPathAlloc(std.testing.io, gpa);
    defer gpa.free(cwd_abs);
    const lane_path = try std.fs.path.join(gpa, &.{ cwd_abs, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(lane_path);

    var agent = agent_mod.Agent.init(gpa, std.testing.io, cwd_abs, .none);
    defer agent.deinit();
    var bridge: lane_bridge.LaneBridge = .{};

    const Handler = struct {
        fn handle(ctx: *anyopaque, req: *const lane_bridge.Request) ?lane_bridge.Response {
            const path: *const []u8 = @ptrCast(@alignCast(ctx));
            return switch (req.op) {
                .enter => lane_bridge.response(std.testing.allocator, "entered\n", .{}, null, path.*) catch unreachable,
                .leave => lane_bridge.response(std.testing.allocator, "left\n", .{}, null, null) catch unreachable,
                else => unreachable,
            };
        }
    };

    const calls = [_]ai.ToolCall{
        try makeCall(gpa, "call_enter", "lane", "{\"command\":\"enter\",\"lane\":\"abc\"}"),
        try makeCall(gpa, "call_leave", "lane", "{\"command\":\"leave\",\"lane\":\"abc\"}"),
        try makeCall(gpa, "call_pwd", shell_tool.tool.name, "{\"command\":\"pwd\",\"description\":\"Show cwd\"}"),
    };
    defer for (calls) |c| {
        gpa.free(c.call_id.value);
        gpa.free(c.name);
        gpa.free(c.arguments);
    };

    var executor = ExecutorService.init(.{
        .gpa = gpa,
        .io = std.testing.io,
        .cwd = cwd_abs,
        .lane_bridge = &bridge,
        .lane_requester = &agent,
    });

    const Worker = struct {
        fn run(exec: *ExecutorService, batch: []const ai.ToolCall, out: *RerootOutcome, done: *std.atomic.Value(bool)) void {
            out.results = exec.runAll(batch, noopObserver(u8)) catch |err| {
                out.err = err;
                done.store(true, .release);
                return;
            };
            done.store(true, .release);
        }
    };

    var outcome = RerootOutcome{};
    var done: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ &executor, &calls, &outcome, &done });
    const lane_ctx: *anyopaque = @ptrCast(@constCast(&lane_path));
    serviceUntilDone(&bridge, lane_ctx, &Handler.handle, &done);
    thread.join();

    if (outcome.err) |err| return err;
    defer {
        for (outcome.results) |*r| r.deinit(gpa);
        gpa.free(outcome.results);
    }
    try std.testing.expectEqual(@as(usize, 3), outcome.results.len);
    try std.testing.expect(!outcome.results[2].failed);
    // After `leave` the root is back at the session cwd.
    try std.testing.expect(std.mem.indexOf(u8, outcome.results[2].content, cwd_abs) != null);
    try std.testing.expect(agent.workspaceBorrow() == null);
}
