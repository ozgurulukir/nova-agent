const std = @import("std");
const log = std.log.scoped(.agent);

const ai = @import("ai.zig");
const at_mention = @import("at_mention.zig");
const background_mod = @import("background.zig");
const compaction = @import("context/compaction.zig");
const config_mod = @import("config/config.zig");
const context_mod = @import("context/manager.zig");
const context_assembly = @import("context/assembly.zig");
const executor_mod = @import("executor.zig");
const lane_bridge = @import("tools/lane_bridge.zig");
const request_limiter_mod = @import("request_limiter.zig");
const lua_mod = @import("lua/root.zig");
const mcp_mod = @import("mcp/manager.zig");
const session_mod = @import("session.zig");
const skill_mod = @import("skill.zig");
const text_tool_call = @import("ai/text_tool_call.zig");
const tools = @import("tools.zig");
const vcs = @import("vcs.zig");

const assert = std.debug.assert;
const agent_queue = @import("agent/queue.zig");
const tool_batch_mod = @import("agent/tool_batch.zig");

const QueuedUserMessage = agent_queue.QueuedUserMessage;
const MessageQueue = agent_queue.MessageQueue;
const ToolBatch = tool_batch_mod.ToolBatch;

const agent_compactor = @import("agent/compactor.zig");
const Compactor = agent_compactor.Compactor;

/// After this many consecutive background-compaction failures the automatic
/// path backs off (emitting one notice); the manual `/compact` command is
/// never gated (TD-6).
pub const compaction_failure_limit: u32 = 3;

pub const Agent = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    /// Workspace-mode scoping (S5): when set (a borrowed lane worktree path),
    /// tools root at this path instead of `cwd`; `effectiveCwd()` is the
    /// single read. Written by the `lane` tool on this agent's worker thread
    /// (`setWorkspace`), between tool batches; reset to null by the tool
    /// (`lane leave`) or by the UI's S17 invariant while this agent's turn is
    /// idle. The path is owned by the lane's `Thread`, never freed here.
    ///
    /// Cross-thread: the worker thread writes it (`lane enter`/`leave`), the
    /// UI thread reads it (`driverWorkspace`, `clearWorkspaceBorrowForPath`).
    /// A 16-byte slice store can tear, so the field is guarded by
    /// `workspace_mutex`; `setWorkspace`/`workspaceBorrow`/`effectiveCwd` are
    /// the only accessors. The lock is never held across tool dispatch.
    workspace: ?[]const u8 = null,
    workspace_mutex: std.Io.Mutex = .init,
    /// Root-containment for lane workers: when set, the agent's bash tool
    /// refuses `cd` to a directory outside the project root (the lane
    /// worktree), so a worker can't drift into the main tree and write there.
    /// The driver/primary agents keep this false — they legitimately `cd` to
    /// lane worktrees to inspect them.
    contained: bool = false,
    /// The App-owned `LaneBridge` the `lane` tool posts across. Borrowed
    /// (owned by the App); null disables the lane tool (headless/tests).
    lane_bridge: ?*lane_bridge.LaneBridge = null,
    client: ai.LanguageModel,
    context_manager: context_mod.ContextManager,
    skills: []const skill_mod.Skill = &.{},
    /// Context window of the connected model, in tokens. Set by the runtime
    /// when a client is attached. 0 means unknown — compaction is disabled.
    context_window_tokens: u32 = 0,
    /// Token usage reported by the most recent turn, the anchor for the
    /// compaction watermark estimate. Null until the first turn completes or
    /// after a compaction / branch switch (forcing a full re-estimate).
    last_usage: ?ai.Usage = null,
    /// Message count when `last_usage` was captured (just after the assistant
    /// reply landed). Messages beyond this index are estimated and added to
    /// `last_usage`, so tool results not yet reflected in provider usage still
    /// count toward the watermark.
    last_usage_anchor_count: u32 = 0,
    /// Dedicated client for background summarization, distinct from `client` so
    /// the two never share a connection. `.none` disables compaction.
    compaction_client: ai.LanguageModel = .none,
    /// Optional local classifier endpoint for bash approval gating.
    bash_classifier_url: ?[]const u8 = null,
    /// Optional synchronous approval hook used by the TUI worker.
    bash_approval: ?BashApproval = null,
    /// Optional shared manager for long-running bash commands launched with
    /// `run_in_background`. Borrowed (owned by the App); null disables the
    /// background path so such calls fall back to a normal blocking run.
    background_manager: ?*background_mod.BackgroundManager = null,
    /// Optional MCP manager for dispatching `mcp__` tool calls.
    /// Borrowed (owned by the App); null disables MCP dispatch.
    mcp_manager: ?*mcp_mod.McpManager = null,
    /// Optional tool registry (builtin + plugin). Borrowed (owned by the
    /// App); null falls back to the builtin-only registry, which is what
    /// headless tests use. The registry is read at every `runToolBatch` to
    /// route plugin calls through the shared dispatcher.
    tool_registry: ?*tools.ToolRegistry = null,
    /// Optional plugin manager (set from the App). Null falls back to
    /// `builtinRegistry()` only, which is what headless tests use. The
    /// manager is read at every `runToolBatch` to route plugin tool
    /// calls through the shared dispatcher.
    plugin_manager: ?*lua_mod.PluginManager = null,
    /// Background summarizer state machine.
    compactor: Compactor = .{},
    /// A manual `/compact` was requested and is mid-flight. The TUI drives it
    /// by polling `pollManualCompact` from its tick loop instead of blocking
    /// on `joinCompactor`, so the UI stays live while the summarizer runs.
    manual_compact_pending: bool = false,
    /// Whether the manual compact's own summarizer run has been started, as
    /// opposed to still waiting on a stale auto-run to land first. When false
    /// and the compactor reaches a terminal state, that state belongs to the
    /// stale run and must be discarded before starting the manual one.
    manual_compact_started: bool = false,
    /// Config-driven compaction policy. Set by the runtime from
    /// `config.context.compaction`; defaults match the old hardcoded
    /// constants so agents created without a config still compact.
    compaction_settings: config_mod.CompactionSettings = .{},
    /// Process-wide cap on concurrent LLM requests to the provider, shared by
    /// every lane's agent. Borrowed from the App (never freed here); null in
    /// headless/tests = no gate. Acquired around each `client.prompt` so at
    /// most `permits` requests are in flight at once (see `request_limiter.zig`).
    request_limiter: ?*request_limiter_mod.RequestLimiter = null,
    /// Consecutive background-compaction failures. The automatic path
    /// disables itself (emitting one notice) once this reaches
    /// `compaction_failure_limit`; `/compact` stays available (TD-6).
    compaction_failures: u32 = 0,
    /// Whether the one-shot "automatic compaction disabled" notice was
    /// already emitted for this trip. Reset on a successful apply.
    compaction_breaker_notified: bool = false,
    /// Whether the one-shot "context full but nothing to cut" notice was
    /// already emitted. Reset on a successful apply.
    compaction_stuck_notified: bool = false,
    message_queue: MessageQueue = .{},
    message_queue_storage: [agent_queue.capacity]QueuedUserMessage = undefined,
    message_queue_mutex: std.Io.Mutex = .init,
    /// git-shadow snapshot state (see `snapshotAfterBatch`). The dedicated index
    /// path is resolved once and cached; `last_snapshot_tree` dedups unchanged
    /// batches; `snapshots_disabled` latches off when git/the repo is absent.
    snapshot_index: ?[]u8 = null,
    last_snapshot_tree: ?vcs.ObjectId = null,
    snapshots_disabled: bool = false,
    /// Monotonic counter minting `textcall_<n>` ids for tool calls recovered
    /// from text (T3). Kept on the agent (not the stream parser) because
    /// recovery runs on the finished turn, post-stream, so the stream's own
    /// `tool_call_seq` is not in scope.
    text_tool_seq: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, client: ai.LanguageModel) Agent {
        return .{
            .gpa = gpa,
            .io = io,
            .cwd = cwd,
            .client = client,
            .context_manager = .{ .gpa = gpa },
        };
    }

    /// The directory tools run in: the workspace root when entered in a lane
    /// (S5), else the session cwd. Read per tool batch by `runToolBatch` and
    /// per `@`-mention expansion by `addUserPrompt` — both on the worker
    /// thread, but the UI thread reads the same field, so the read is guarded
    /// by `workspace_mutex`. The returned slice is borrowed (the backing path
    /// is Thread-owned and outlives the borrow).
    pub fn effectiveCwd(self: *Agent) []const u8 {
        self.workspace_mutex.lock(self.io) catch return self.cwd;
        defer self.workspace_mutex.unlock(self.io);
        return self.workspace orelse self.cwd;
    }

    /// Set the workspace borrow (worker thread, `lane enter`/`leave`). The
    /// path is borrowed from the lane's `Thread`, never copied or freed here.
    pub fn setWorkspace(self: *Agent, path: ?[]const u8) void {
        self.workspace_mutex.lock(self.io) catch return;
        defer self.workspace_mutex.unlock(self.io);
        self.workspace = path;
    }

    /// Read the workspace borrow (UI thread). Returns a borrowed slice; the
    /// backing path is Thread-owned and outlives the borrow.
    pub fn workspaceBorrow(self: *Agent) ?[]const u8 {
        self.workspace_mutex.lock(self.io) catch return null;
        defer self.workspace_mutex.unlock(self.io);
        return self.workspace;
    }

    /// The cached message projection the agent prompts with. Source of truth
    /// is the session tree; see `ContextManager`.
    pub fn messages(self: *const Agent) []ai.ChatMessage {
        return self.context_manager.items();
    }

    pub fn attachSessionWriter(self: *Agent, session_writer: *session_mod.SessionWriter) void {
        self.context_manager.attachSessionWriter(session_writer);
    }

    pub fn addSystem(self: *Agent, content: []const u8) !void {
        try self.appendMessage(.system, content);
    }

    pub fn deinit(self: *Agent) void {
        // Wait for any background summarizer before tearing down the state it
        // reads (the client), then release its result.
        self.drainBackgroundCompaction();
        self.context_manager.deinit();
        if (self.message_queue_mutex.lock(self.io)) |_| {
            defer self.message_queue_mutex.unlock(self.io);
            while (self.message_queue.pop(&self.message_queue_storage)) |queued| {
                self.gpa.free(queued.prompt);
            }
        } else |_| {
            // Lock failed (canceled) — skip critical section, continue cleanup.
        }
        if (self.snapshot_index) |path| self.gpa.free(path);
        if (self.bash_classifier_url) |url| self.gpa.free(url);
        self.* = undefined;
    }

    pub fn addUser(self: *Agent, content: []const u8) !void {
        try self.appendMessage(.user, content);
    }

    pub fn enqueueUser(self: *Agent, content: []const u8) !void {
        assert(content.len > 0);
        const owned = try self.gpa.dupe(u8, content);
        errdefer self.gpa.free(owned);
        try self.message_queue_mutex.lock(self.io);
        defer self.message_queue_mutex.unlock(self.io);
        if (!self.message_queue.push(&self.message_queue_storage, .{ .prompt = owned })) return error.QueueFull;
    }

    /// Queue a machine-generated user message delivered verbatim (no `@`-mention
    /// expansion or skill prefixing) at the next turn boundary. Thread-safe — the
    /// `BackgroundManager` callers reach it from the UI thread while the worker
    /// may be draining the same queue. See `QueuedUserMessage.raw`.
    pub fn enqueueRaw(self: *Agent, content: []const u8) !void {
        assert(content.len > 0);
        const owned = try self.gpa.dupe(u8, content);
        errdefer self.gpa.free(owned);
        try self.message_queue_mutex.lock(self.io);
        defer self.message_queue_mutex.unlock(self.io);
        if (!self.message_queue.push(&self.message_queue_storage, .{ .prompt = owned, .raw = true })) return error.QueueFull;
    }

    /// Queue a user message marked to steer (inject after the next tool batch).
    /// Atomic push + mark under one lock, so the lane-steer path can't
    /// interleave a concurrent drain between `enqueueUser` and `setQueuedSteer`.
    pub fn enqueueSteer(self: *Agent, content: []const u8) !void {
        assert(content.len > 0);
        const owned = try self.gpa.dupe(u8, content);
        errdefer self.gpa.free(owned);
        try self.message_queue_mutex.lock(self.io);
        defer self.message_queue_mutex.unlock(self.io);
        if (!self.message_queue.push(&self.message_queue_storage, .{ .prompt = owned, .steer = true })) return error.QueueFull;
    }

    /// Whether any user message is waiting in the queue. The UI uses this to
    /// decide whether an idle lane should start a turn to deliver a background
    /// completion that was enqueued while no turn was running.
    pub fn hasQueuedMessages(self: *Agent) bool {
        self.message_queue_mutex.lock(self.io) catch return false;
        defer self.message_queue_mutex.unlock(self.io);
        return self.message_queue.len() > 0;
    }

    /// Expand `@`-mentions in `prompt` (embedding text files inline, attaching
    /// images as real content blocks) and append the result as a user message.
    /// Reads files, so this is meant to run on the agent worker thread.
    pub fn addUserPrompt(self: *Agent, prompt: []const u8) !void {
        // A turn interrupted mid-tool-batch leaves the assistant's `tool_call`s
        // with no matching tool result. Providers reject a turn whose history has
        // a tool_use without a corresponding tool_result, so fill them in before
        // this user message lands — keeping the synthetic results right after the
        // assistant call, ahead of the new user turn.
        try self.reconcileInterruptedToolCalls();

        // @-mention expansion follows the workspace (M6): in workspace mode a
        // mention of a file edited in the lane reads the lane's copy. Runs on
        // the worker thread, so `effectiveCwd` is race-free against the tool.
        const blocks = try at_mention.buildUserMessage(self.gpa, self.io, self.effectiveCwd(), prompt);
        errdefer {
            for (blocks) |*block| block.deinit(self.gpa);
            self.gpa.free(blocks);
        }
        try self.prependSkillBlocks(prompt, blocks);
        try self.context_manager.appendPersisted(.{ .user = .{ .content = blocks } });
    }

    /// Result text recorded for a tool call the user interrupted before it
    /// finished — surfaced to the model so it knows the call was cancelled.
    const interrupted_tool_result = "The user interrupted the turn before this tool call completed; it produced no result.";

    /// Append a synthetic, failed tool result for every `tool_call` on the active
    /// branch that has no matching result yet. Runs before a new user message so
    /// the dangling calls (from a mid-batch interrupt) don't break the next turn.
    /// A no-op when every call already has a result.
    fn reconcileInterruptedToolCalls(self: *Agent) !void {
        const history = self.context_manager.items();

        var resolved = std.StringHashMap(void).init(self.gpa);
        defer resolved.deinit();
        for (history) |message| {
            switch (message) {
                .tool => |t| try resolved.put(t.call_id.slice(), {}),
                else => {},
            }
        }

        // Copy the unmatched ids out before appending — `appendPersisted` may
        // realloc the message array, invalidating slices into it.
        var missing: std.ArrayList([]u8) = .empty;
        defer {
            for (missing.items) |id| self.gpa.free(id);
            missing.deinit(self.gpa);
        }
        for (history) |message| {
            switch (message) {
                .assistant => |a| {
                    for (a.content) |block| {
                        if (block != .tool_call) continue;
                        if (resolved.contains(block.tool_call.call_id.slice())) continue;
                        try missing.append(self.gpa, try self.gpa.dupe(u8, block.tool_call.call_id.slice()));
                    }
                },
                else => continue,
            }
        }

        for (missing.items) |id| {
            const blocks = try self.gpa.alloc(ai.ContentBlock, 1);
            errdefer self.gpa.free(blocks);
            blocks[0] = .{ .text = .{ .text = try self.gpa.dupe(u8, interrupted_tool_result) } };
            try self.context_manager.appendPersisted(.{
                .tool = .{
                    .content = blocks,
                    .call_id = .{ .value = try self.gpa.dupe(u8, id) },
                    .display_label = try self.gpa.dupe(u8, "cancelled"),
                    .failed = true,
                },
            });
        }
    }

    fn prependSkillBlocks(self: *Agent, prompt: []const u8, blocks: []ai.ContentBlock) !void {
        assert(blocks.len > 0);
        assert(blocks[0] == .text);
        const prefix = try skill_mod.promptPrefix(self.gpa, self.io, self.skills, prompt);
        defer self.gpa.free(prefix);
        if (prefix.len == 0) return;

        const old_text = blocks[0].text.text;
        const new_text = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ prefix, old_text });
        self.gpa.free(old_text);
        blocks[0].text.text = new_text;
    }

    pub fn takeMessage(self: *Agent, message: ai.ChatMessage) !void {
        try self.context_manager.appendUnpersisted(message);
    }

    /// Drop every non-system message, freeing it. Keeps the system prompt(s) in
    /// place so the conversation can be rehydrated from a different branch (see
    /// `AgentRuntime.reloadMessages`). Only safe at a turn boundary, never while
    /// a response is streaming.
    pub fn clearNonSystemMessages(self: *Agent) void {
        self.context_manager.clearNonSystem();
    }

    /// The tagged union the agent emits to describe what is happening.
    /// Single public seam — the TUI (and any future consumer) subscribes
    /// to this stream of events via `Agent.Listener`.
    ///
    /// Variant payloads are C-flattenable (flat fields, strings as
    /// `[]const u8`, integers, enums, single-level structs) so an FFI shim
    /// can wrap them later without redesigning the type.
    pub const Event = union(enum) {
        turn_started,
        thinking_delta: []const u8,
        response_delta: []const u8,
        tool_delta: ai.ToolDelta,
        delta_end,
        tool_call_finished: ToolCallFinished,
        tool_batch_finished,
        queued_messages_flushed: u32,
        turn_finished,
        turn_failed: []const u8,
        history_compacted: HistoryCompacted,
        /// One-shot user-facing compaction notices (breaker tripped, stuck above
        /// the swap watermark with nothing to cut, overflow wait). The variant
        /// is a bare enum so no allocation is involved — the renderer owns the
        /// message text (TD-6, TD-2 event plumbing).
        compaction_notice: CompactionNotice,

        /// The fixed notice kinds `maybeCompact` can emit while it degrades
        /// gracefully instead of looping into provider overflow errors.
        pub const CompactionNotice = enum {
            /// Automatic compaction disabled after 3 consecutive failures.
            breaker_tripped,
            /// Past the swap watermark but nothing can be cut — the recent
            /// history already fits the retention budget.
            stuck,
            /// A synchronous overflow wait is about to join the summarizer.
            waiting,
        };

        /// Emitted after the agent replaces summarized history with a compaction
        /// summary. Token counts are estimates for display only.
        pub const HistoryCompacted = struct {
            tokens_before: u32,
            tokens_after: u32,
        };

        pub const ToolCallFinished = struct {
            index: u32,
            call_id: []const u8 = "",
            name: []const u8,
            display_label: []const u8,
            display_expanded_label: ?[]const u8 = null,
            display_body: []const u8,
            display_kind: tools.DisplayKind = .text,
            stderr: ?[]const u8 = null,
            failed: bool = false,
        };

        pub fn deinit(self: *Event, gpa: std.mem.Allocator) void {
            switch (self.*) {
                .thinking_delta, .response_delta, .turn_failed => |text| gpa.free(text),
                .tool_delta => |tool| {
                    gpa.free(tool.name);
                    gpa.free(tool.arguments);
                },
                .tool_call_finished => |tool| {
                    gpa.free(tool.call_id);
                    gpa.free(tool.name);
                    gpa.free(tool.display_label);
                    if (tool.display_expanded_label) |label| gpa.free(label);
                    gpa.free(tool.display_body);
                    if (tool.stderr) |stderr| gpa.free(stderr);
                },
                .turn_started, .delta_end, .tool_batch_finished, .queued_messages_flushed, .turn_finished, .history_compacted, .compaction_notice => {},
            }
            self.* = undefined;
        }
    };

    /// The typed seam consumers attach to receive `Agent.Event`s. Generic
    /// over the consumer's context type — the `*Ctx` is supplied at the call
    /// site, so callbacks receive their own typed context without
    /// `@ptrCast`. `nullListener(Ctx)` is the branch-free default for
    /// callers that don't subscribe; the `Ctx` type is supplied by the
    /// caller.
    pub fn Listener(Ctx: type) type {
        return struct {
            ctx: *Ctx,
            on_event: *const fn (ctx: *Ctx, event: Event) anyerror!void,

            pub fn emit(self: @This(), event: Event) anyerror!void {
                return self.on_event(self.ctx, event);
            }
        };
    }

    /// Build a no-op `Listener(Ctx)`. The ctx pointer is left undefined —
    /// the callback ignores its argument.
    pub fn nullListener(Ctx: type) Listener(Ctx) {
        return .{
            .ctx = undefined,
            .on_event = onNothingCtx,
        };
    }

    fn onNothingCtx(_: *anyopaque, _: Event) anyerror!void {}

    pub fn run(self: *Agent, listener: anytype) !void {
        // The listener's `ctx` field is `*Ctx`; extract `Ctx` (the pointee
        // type) so `Listener(Ctx)` matches the struct the caller built.
        const Ctx = @typeInfo(@TypeOf(listener.ctx)).pointer.child;
        const L = Agent.Listener(Ctx);
        const l: L = listener;
        try l.emit(.turn_started);
        const tool_call_limit = 100;
        var calls: u32 = 0;
        while (calls < tool_call_limit) : (calls += 1) {
            self.maybeCompact(l);
            var stream_context: StreamContext(L) = .{
                .agent = self,
                .listener = l,
            };
            defer stream_context.deinit();
            const prompt_messages = try context_assembly.pruneHistoricalToolResultsViews(
                self.gpa,
                self.messages(),
                self.compaction_settings.keep_recent_tool_turns,
                self.compaction_settings.historical_tool_cap_bytes,
            );
            defer context_assembly.freePrunedViews(self.gpa, prompt_messages);

            // A permit is held only for the request itself (not across tool
            // execution), so a long bash call on one lane never head-of-line
            // blocks another lane's next request. Retries inside `prompt` hold
            // the permit too, so lanes can't retry-burst the provider together.
            const limiter = self.request_limiter;
            var turn = blk: {
                if (limiter) |lim| try lim.acquire(self.io);
                defer if (limiter) |lim| lim.release(self.io);
                break :blk try self.client.prompt(prompt_messages, stream_context.observer());
            };
            const usage = turn.usage;
            var turn_owned = true;
            defer if (turn_owned) turn.deinit(self.gpa);

            const tool_calls_initial = try self.collectToolCalls(turn.assistant);
            defer self.gpa.free(tool_calls_initial);

            // T3: recover tool calls the model emitted as literal text (weak
            // function-calling models do this). Only when there were zero
            // structured calls, and only over the assistant's text blocks —
            // never mid-stream. Runs BEFORE takeAssistantMessage so the
            // recovered calls are persisted (turn.assistant is still live and
            // owned by the turn here). See plan §1.1, §2.2.
            var recovered: []ai.ToolCall = &.{};
            if (tool_calls_initial.len == 0) {
                recovered = try self.recoverTextToolCalls(turn.assistant);
            }
            // Ownership: when recovered.len > 0 the payloads were MOVED into
            // the message's new blocks by injectRecoveredToolCalls; the
            // `recovered` slice shell itself is freed here, but NOT its
            // element strings (they were moved). When recovery didn't fire,
            // recovered is &.{} (empty literal, nothing to free).
            defer if (recovered.len > 0) self.gpa.free(recovered);
            if (recovered.len > 0) {
                try self.injectRecoveredToolCalls(&turn.assistant, recovered);
            }
            // The slice that drives execution. When recovery fired, execution
            // runs the recovered calls; otherwise it runs the structured ones.
            // Both `tool_calls_initial` and `recovered` are freed by their
            // defers at scope end; execution (runToolBatch) completes before
            // that, and runToolBatch copies the ToolCall values into the
            // executor before returning, so neither slice is read post-free.
            const tool_calls: []const ai.ToolCall = if (recovered.len > 0) recovered else tool_calls_initial;

            if (turn.assistant == .assistant and hasWireContent(turn.assistant)) {
                try self.takeAssistantMessage(&turn.assistant);
                turn_owned = false;
            } else {
                turn.deinit(self.gpa);
                turn_owned = false;
            }
            // Anchor after the assistant reply is in history: `usage` accounts
            // for everything up to and including it; later appends are trailing.
            self.recordUsage(usage);

            if (tool_calls.len == 0) {
                // Turn would otherwise go idle: drain the front queued message
                // (steer or not) and continue, so anything still waiting is
                // handled at the natural turn end.
                const drained_count = try self.drainQueuedUserMessage(false);
                if (drained_count > 0) {
                    try l.emit(.{ .queued_messages_flushed = drained_count });
                    continue;
                }
                return;
            }
            try Agent.runToolBatch(L, self, ToolBatch.init(tool_calls), &stream_context, l);
            // Mid-turn we only inject messages explicitly marked to steer, and
            // only from the front so FIFO order holds — a default-queued
            // message ahead of a steer one keeps it waiting for turn end.
            var steered: u32 = 0;
            while ((try self.drainQueuedUserMessage(true)) > 0) steered += 1;
            if (steered > 0) try l.emit(.{ .queued_messages_flushed = steered });
        }
        return error.ToolCallLimit;
    }

    /// Hand the batch of tool_calls to the ExecutorService, bridge its
    /// ToolCallObserver callbacks into the agent's Event stream, and move
    /// the LLM-channel of each ToolResult into history.
    fn runToolBatch(
        comptime L: type,
        self: *Agent,
        tool_batch: ToolBatch,
        stream_context: *const StreamContext(L),
        listener: L,
    ) !void {
        var bridge: ExecutorBridge(L) = .{
            .agent = self,
            .listener = listener,
            .stream_context = stream_context,
        };
        var executor = executor_mod.ExecutorService.init(.{
            .gpa = self.gpa,
            .io = self.io,
            .cwd = self.effectiveCwd(),
            .contained = self.contained,
            .bash_classifier_url = self.bash_classifier_url,
            .background = if (self.background_manager) |manager|
                .{ .manager = manager, .owner = self }
            else
                null,
            .mcp_manager = self.mcp_manager,
            .tool_registry = self.tool_registry,
            .plugin_manager = self.plugin_manager,
            .lane_bridge = self.lane_bridge,
            .lane_requester = self,
        });
        const results = try executor.runAll(tool_batch.calls, bridge.observer());
        defer self.gpa.free(results);
        errdefer for (results) |*r| r.deinit(self.gpa);
        try self.takeToolResults(results);
        self.snapshotAfterBatch();
        try listener.emit(.tool_batch_finished);
    }

    /// After a tool batch, snapshot the working tree (git-shadow) and bind it to
    /// the batch's last conversation entry, giving per-tool-batch timeline
    /// granularity. Runs on the worker thread — the only thread that writes
    /// session entries during a turn — so binding via `setLeafSnapshot` (which
    /// flushes the writer) can't race a concurrent append.
    ///
    /// Authoritative change-detection without trusting tool output: the
    /// content-addressed tree id is compared to the last snapshot's; an unchanged
    /// tree (a read-only batch, or a build that only touched gitignored files) is
    /// skipped, creating no object and no binding. Best-effort — any failure
    /// latches snapshots off for the session rather than failing the turn.
    fn snapshotAfterBatch(self: *Agent) void {
        if (self.snapshots_disabled) return;
        const session_writer = self.context_manager.session_writer orelse return;
        const index = self.snapshot_index orelse blk: {
            if (!vcs.isAvailable(self.gpa, self.io) or !vcs.isRepo(self.gpa, self.io, self.cwd)) {
                self.snapshots_disabled = true;
                return;
            }
            const path = vcs.indexPath(self.gpa, self.io, self.cwd) catch {
                self.snapshots_disabled = true;
                return;
            };
            self.snapshot_index = path;
            break :blk path;
        };
        const tree = vcs.workingTreeId(self.gpa, self.io, self.cwd, index) catch return;
        if (self.last_snapshot_tree) |last| {
            if (tree.eql(last)) return; // batch changed nothing tracked — no node
        }
        const commit = vcs.commitTree(self.gpa, self.io, self.cwd, tree) catch return;
        session_writer.setLeafSnapshot(commit.slice()) catch return;
        if (session_writer.leaf()) |leaf_id| vcs.keepRef(self.gpa, self.io, self.cwd, leaf_id, commit) catch {};
        self.last_snapshot_tree = tree;
    }

    /// Bridges ExecutorService's `ToolCallObserver` callbacks into the
    /// agent's Event stream. Tracks tool_index across the batch so the
    /// events line up with the tool_indexes the TUI saw during deltas.
    fn ExecutorBridge(comptime L: type) type {
        return struct {
            agent: *Agent,
            listener: L,
            stream_context: *const StreamContext(L),
            tool_index: u32 = 0,

            fn onStarted(ctx: *@This(), call: ai.ToolCall) anyerror!void {
                // Synthesise a tool_delta for the TUI if the LM did not stream
                // one for this tool_call (some servers emit the whole call in
                // one shot without intermediate deltas).
                if (!ctx.stream_context.toolDeltaSeen(ctx.tool_index)) {
                    try Agent.emitToolDelta(L, ctx.agent, ctx.listener, ctx.tool_index, call.name, call.arguments);
                    try ctx.listener.emit(.delta_end);
                }
                // Notify plugins at the tool-call boundary — safe because the
                // plugin's own handler has not been entered yet on this thread.
                if (ctx.agent.plugin_manager) |pm| pm.emitEvent(.{
                    .tool_call_started = .{ .name = call.name, .call_id = call.call_id.slice() },
                });
            }

            fn onFinished(ctx: *@This(), result: *const executor_mod.ToolResult) anyerror!void {
                // Notify plugins that the tool call completed.
                if (ctx.agent.plugin_manager) |pm| pm.emitEvent(.{
                    .tool_call_finished = .{
                        .name = result.name,
                        .call_id = result.call_id.slice(),
                        .success = !result.failed,
                    },
                });
                try Agent.emitToolCallFinished(
                    L,
                    ctx.agent,
                    ctx.listener,
                    ctx.tool_index,
                    result.call_id.slice(),
                    result.name,
                    result.display_label,
                    result.display_expanded_label,
                    result.display_body,
                    result.display_kind,
                    result.stderr,
                    result.failed,
                );
                ctx.tool_index += 1;
            }

            fn approveUnsafeBash(ctx: *@This(), call: ai.ToolCall, command: []const u8) anyerror!bool {
                _ = call;
                const approval = ctx.agent.bash_approval orelse return true;
                return approval.request(approval.ptr, command);
            }

            /// Build the executor's `ToolCallObserver` for this bridge. The
            /// observer's ctx is `*@This()` (the bridge itself), and the
            /// callbacks receive it typed — no `@ptrCast` at the seam.
            fn observer(self: *@This()) executor_mod.ToolCallObserver(@This()) {
                return .{
                    .ctx = self,
                    .on_started = onStarted,
                    .on_finished = onFinished,
                    .approve_unsafe_bash = approveUnsafeBash,
                };
            }
        };
    }

    /// Per-stream context shared between the agent and the ai client's
    /// stream observer callbacks. Holds the typed listener plus the
    /// delta-tracking list. The `observer()` method builds a
    /// `StreamObserver(*Self)` whose callbacks are comptime-baked wrappers
    /// around this `StreamContext` and its typed listener — no
    /// `@ptrCast` at the seam.
    fn StreamContext(comptime L: type) type {
        return struct {
            agent: *Agent,
            listener: L,
            tool_delta_seen: std.ArrayList(bool) = .empty,

            const Self = @This();

            fn deinit(self: *Self) void {
                self.tool_delta_seen.deinit(self.agent.gpa);
            }

            fn toolDeltaSeen(self: *const Self, tool_index: u32) bool {
                if (tool_index >= self.tool_delta_seen.items.len) return false;
                return self.tool_delta_seen.items[tool_index];
            }

            fn markToolDeltaSeen(self: *Self, tool_index: u32) !void {
                while (self.tool_delta_seen.items.len <= tool_index) {
                    try self.tool_delta_seen.append(self.agent.gpa, false);
                }
                self.tool_delta_seen.items[tool_index] = true;
            }

            fn observer(self: *Self) ai.StreamObserver(Self) {
                return .{
                    .ctx = self,
                    .on_content = onContentDeltaImpl(L),
                    .on_reasoning = onReasoningDeltaImpl(L),
                    .on_tool_delta = onToolDeltaImpl(L),
                    .on_delta_end = onDeltaEndImpl(L),
                };
            }
        };
    }

    fn onContentDeltaImpl(comptime L: type) *const fn (*StreamContext(L), []const u8) anyerror!void {
        const F = struct {
            fn call(ctx: *StreamContext(L), delta: []const u8) anyerror!void {
                const owned = try ctx.agent.gpa.dupe(u8, delta);
                try ctx.listener.emit(.{ .response_delta = owned });
            }
        };
        return &F.call;
    }

    fn onReasoningDeltaImpl(comptime L: type) *const fn (*StreamContext(L), []const u8) anyerror!void {
        const F = struct {
            fn call(ctx: *StreamContext(L), delta: []const u8) anyerror!void {
                const owned = try ctx.agent.gpa.dupe(u8, delta);
                try ctx.listener.emit(.{ .thinking_delta = owned });
            }
        };
        return &F.call;
    }

    fn onToolDeltaImpl(comptime L: type) *const fn (*StreamContext(L), ai.ToolDelta) anyerror!void {
        const F = struct {
            fn call(ctx: *StreamContext(L), delta: ai.ToolDelta) anyerror!void {
                try ctx.markToolDeltaSeen(delta.index);
                try Agent.emitToolDelta(L, ctx.agent, ctx.listener, delta.index, delta.name, delta.arguments);
            }
        };
        return &F.call;
    }

    fn onDeltaEndImpl(comptime L: type) *const fn (*StreamContext(L)) anyerror!void {
        const F = struct {
            fn call(ctx: *StreamContext(L)) anyerror!void {
                try ctx.listener.emit(.delta_end);
            }
        };
        return &F.call;
    }

    fn emitToolDelta(
        comptime L: type,
        self: *Agent,
        listener: L,
        tool_index: u32,
        name: []const u8,
        arguments: []const u8,
    ) !void {
        const owned_name = try self.gpa.dupe(u8, name);
        const owned_arguments = try self.gpa.dupe(u8, arguments);
        try listener.emit(.{
            .tool_delta = .{
                .index = tool_index,
                .name = owned_name,
                .arguments = owned_arguments,
            },
        });
    }

    fn emitToolCallFinished(
        comptime L: type,
        self: *Agent,
        listener: L,
        tool_index: u32,
        call_id: []const u8,
        name: []const u8,
        display_label: []const u8,
        display_expanded_label: ?[]const u8,
        display_body: []const u8,
        display_kind: tools.DisplayKind,
        stderr: ?[]const u8,
        failed: bool,
    ) !void {
        const owned_id = try self.gpa.dupe(u8, call_id);
        const owned_name = try self.gpa.dupe(u8, name);
        const owned_label = try self.gpa.dupe(u8, display_label);
        const owned_expanded_label: ?[]u8 = if (display_expanded_label) |label|
            try self.gpa.dupe(u8, label)
        else
            null;
        const owned_body = try self.gpa.dupe(u8, display_body);
        const owned_stderr: ?[]u8 = if (stderr) |s|
            try self.gpa.dupe(u8, s)
        else
            null;
        try listener.emit(.{
            .tool_call_finished = .{
                .index = tool_index,
                .call_id = owned_id,
                .name = owned_name,
                .display_label = owned_label,
                .display_expanded_label = owned_expanded_label,
                .display_body = owned_body,
                .display_kind = display_kind,
                .stderr = owned_stderr,
                .failed = failed,
            },
        });
    }

    fn appendMessage(self: *Agent, role: ai.Role, content: []const u8) !void {
        var message = try self.makeTextMessage(role, content);
        errdefer message.deinit(self.gpa);
        try self.context_manager.appendPersisted(message);
    }

    /// True when the assistant message carries content the chat-completions wire
    /// format can represent: non-empty text or a tool call. Reasoning blocks are
    /// dropped by the serializer, so a reasoning-only message would go out as
    /// empty content with no tool_calls — rejected by strict providers.
    fn hasWireContent(message: ai.ChatMessage) bool {
        for (message.assistant.content) |block| switch (block) {
            .text => |t| if (t.text.len > 0) return true,
            .tool_call => return true,
            .reasoning, .image => {},
        };
        return false;
    }

    fn makeTextMessage(self: *Agent, role: ai.Role, content: []const u8) !ai.ChatMessage {
        assert(content.len > 0);
        const blocks = try self.gpa.alloc(ai.ContentBlock, 1);
        errdefer self.gpa.free(blocks);
        blocks[0] = .{ .text = .{ .text = try self.gpa.dupe(u8, content) } };
        errdefer blocks[0].deinit(self.gpa);
        return switch (role) {
            .system => .{ .system = .{ .content = blocks } },
            .user => .{ .user = .{ .content = blocks } },
            .assistant => .{ .assistant = .{ .content = blocks } },
            .tool => error.InvalidToolRole,
        };
    }

    /// Build a fake tool message for tests that need a tool result without
    /// going through the executor. `call_id` defaults to "test_call".
    fn makeToolMessage(self: *Agent, content: []const u8) !ai.ChatMessage {
        assert(content.len > 0);
        const blocks = try self.gpa.alloc(ai.ContentBlock, 1);
        errdefer self.gpa.free(blocks);
        blocks[0] = .{ .text = .{ .text = try self.gpa.dupe(u8, content) } };
        errdefer blocks[0].deinit(self.gpa);
        return .{
            .tool = .{
                .call_id = .{ .value = try self.gpa.dupe(u8, "test_call") },
                .content = blocks,
            },
        };
    }

    fn drainQueuedUserMessage(self: *Agent, steer_only: bool) !u32 {
        const queued = self.takeQueuedUserMessage(steer_only) orelse return 0;
        defer self.gpa.free(queued.prompt);
        // Raw (machine-generated) messages bypass `@`-mention expansion and skill
        // prefixing so their body is never reinterpreted; user-typed prompts go
        // through the full expansion path.
        if (queued.raw) try self.addUser(queued.prompt) else try self.addUserPrompt(queued.prompt);
        return 1;
    }

    /// Move every queued message into history in FIFO order, returning how many
    /// were drained. Used to deliver a stranded queue as a fresh turn (e.g.
    /// after a user interrupt): the leading messages become context and the
    /// last one is the latest user message the next prompt answers.
    pub fn drainAllQueuedToHistory(self: *Agent) !u32 {
        var count: u32 = 0;
        while ((try self.drainQueuedUserMessage(false)) > 0) count += 1;
        return count;
    }

    /// Drop every queued message without delivering it. Thread-safe; the worker
    /// drains under the same mutex.
    pub fn clearQueue(self: *Agent) void {
        if (self.message_queue_mutex.lock(self.io) catch null) |_| {
            defer self.message_queue_mutex.unlock(self.io);
            while (self.message_queue.pop(&self.message_queue_storage)) |queued| {
                self.gpa.free(queued.prompt);
            }
        }
    }

    /// Pop and return the front queued message. When `steer_only` is set, only
    /// pops if the front message is marked to steer (otherwise returns null,
    /// leaving the queue untouched). Caller owns `queued.prompt`.
    fn takeQueuedUserMessage(self: *Agent, steer_only: bool) ?QueuedUserMessage {
        if (self.message_queue_mutex.lock(self.io)) |_| {
            defer self.message_queue_mutex.unlock(self.io);
            if (steer_only) {
                const front = self.message_queue.peek(&self.message_queue_storage) orelse return null;
                if (!front.steer) return null;
            }
            return self.message_queue.pop(&self.message_queue_storage);
        } else |_| {
            return null;
        }
    }

    /// Mark the queued message at logical `index` to steer (inject after the
    /// next tool batch). Called from the UI thread; guarded by the queue mutex
    /// the worker also holds while draining.
    pub fn setQueuedSteer(self: *Agent, index: u32) void {
        if (self.message_queue_mutex.lock(self.io) catch null) |_| {
            defer self.message_queue_mutex.unlock(self.io);
            if (self.message_queue.at(&self.message_queue_storage, index)) |entry| entry.steer = true;
        }
    }

    fn takeAssistantMessage(self: *Agent, assistant: *ai.ChatMessage) !void {
        assert(assistant.* == .assistant);
        try self.context_manager.appendPersisted(assistant.*);
        assistant.* = undefined;
    }

    fn collectToolCalls(self: *Agent, assistant: ai.ChatMessage) ![]ai.ToolCall {
        assert(assistant == .assistant);
        const content = assistant.assistant.content;
        var count: usize = 0;
        for (content) |block| {
            if (block == .tool_call) count += 1;
        }
        const calls = try self.gpa.alloc(ai.ToolCall, count);
        var index: usize = 0;
        for (content) |block| {
            if (block != .tool_call) continue;
            calls[index] = block.tool_call;
            index += 1;
        }
        return calls;
    }

    /// T3: scan the assistant message's text blocks for tool calls a model
    /// emitted as literal text (weak function-calling models do this). Returns
    /// a freshly-allocated `[]ai.ToolCall` (possibly empty) whose element
    /// strings are independently owned — NOT aliased onto the message — so
    /// `injectRecoveredToolCalls` can move them into new blocks cleanly.
    /// Only scans `.text` blocks; reasoning blocks are ignored.
    fn recoverTextToolCalls(self: *Agent, assistant: ai.ChatMessage) ![]ai.ToolCall {
        if (assistant != .assistant) return &.{};
        var all: std.ArrayList(ai.ToolCall) = .empty;
        errdefer {
            for (all.items) |*c| c.deinit(self.gpa);
            all.deinit(self.gpa);
        }
        for (assistant.assistant.content) |block| {
            if (block != .text) continue;
            const found = try text_tool_call.extractFromText(self.gpa, block.text.text, &self.text_tool_seq);
            // `found`'s element strings are owned; appendSlice copies the
            // ToolCall values (shallow) into `all` — the element strings stay
            // alive because `all` now holds the only references. Free `found`'s
            // shell; the strings move with the values into `all`.
            defer self.gpa.free(found);
            try all.appendSlice(self.gpa, found);
        }
        return all.toOwnedSlice(self.gpa);
    }

    /// T3: append recovered tool calls as new `.tool_call` ContentBlocks into
    /// the assistant message's content slice, reallocating the slice.
    ///
    /// Ownership contract: the recovered `ToolCall`s' owned strings
    /// (call_id/name/arguments) are MOVED into the new blocks — callers must
    /// NOT free those strings, only the `recovered` slice shell. This mirrors
    /// `collectToolCalls`'s aliasing contract (slice shell caller-freed,
    /// element strings belong to the message). Existing blocks keep their
    /// strings — only the slice shell is reallocated.
    fn injectRecoveredToolCalls(self: *Agent, assistant: *ai.ChatMessage, recovered: []ai.ToolCall) !void {
        assert(assistant.* == .assistant);
        if (recovered.len == 0) return;
        const old = assistant.assistant.content;
        const new_blocks = try self.gpa.alloc(ai.ContentBlock, old.len + recovered.len);
        // Shallow copy: old blocks keep their owned strings.
        @memcpy(new_blocks[0..old.len], old);
        var i: usize = old.len;
        for (recovered) |tc| {
            new_blocks[i] = .{ .tool_call = tc }; // MOVED: strings now owned by this block
            i += 1;
        }
        // Free only the old slice shell — element strings were moved into new_blocks.
        self.gpa.free(old);
        assistant.assistant.content = new_blocks;
    }

    fn takeToolResults(self: *Agent, results: []executor_mod.ToolResult) !void {
        assert(results.len > 0);
        var moved: usize = 0;
        errdefer {
            for (results[moved..]) |*r| r.deinit(self.gpa);
        }
        for (results) |*r| {
            assert(r.call_id.value.len > 0);
            const blocks = try self.gpa.alloc(ai.ContentBlock, 1);
            errdefer self.gpa.free(blocks);
            blocks[0] = .{ .text = .{ .text = r.content } };
            try self.context_manager.appendPersisted(.{
                .tool = .{
                    .content = blocks,
                    .call_id = r.call_id,
                    .display_label = r.display_label,
                    .failed = r.failed,
                },
            });
            self.gpa.free(r.name);
            if (r.display_expanded_label) |label| self.gpa.free(label);
            self.gpa.free(r.display_body);
            if (r.stderr) |s| self.gpa.free(s);
            r.* = undefined;
            moved += 1;
        }
    }

    /// Keep the prompt within the model's window using a background summarizer,
    /// so the agent never waits. Two watermarks: start the summary at the lower
    /// one (giving it time to finish), and swap it into history at the higher
    /// one (by when it is normally ready, so the swap is instant). Messages
    /// appended between the two watermarks survive the swap verbatim — the
    /// boundary references a tree entry id and the projection emits from it to
    /// the leaf. Best-effort: every failure is logged and swallowed so
    /// compaction never aborts the turn.
    fn maybeCompact(self: *Agent, listener: anytype) void {
        if (!self.compaction_settings.auto) return;
        if (self.compaction_client == .none) return;
        if (self.context_window_tokens == 0) return;
        if (self.context_manager.session_writer == null) return;

        // Circuit breaker (TD-6): after `compaction_failure_limit` consecutive
        // failures the automatic path backs off so it stops respawning a doomed
        // summarizer every turn. One notice is emitted; `/compact` is not gated.
        if (self.compactionBreakerTripped()) {
            if (!self.compaction_breaker_notified) {
                self.compaction_breaker_notified = true;
                self.emitCompactionNotice(listener, .breaker_tripped);
            }
            return;
        }

        const used = self.currentContextTokens();
        const threshold = self.compaction_settings.threshold;

        // Past the swap watermark: install the ready background summary.
        if (compaction.shouldSwap(used, self.context_window_tokens, threshold)) {
            Agent.applyReadyCompaction(@TypeOf(listener), self, listener) catch |err| log.warn("compaction apply failed: {s}", .{@errorName(err)});
        }

        // Past the start watermark: kick off the summary so it is ready by the
        // time the footprint reaches the swap watermark.
        if (compaction.shouldStartSummary(used, self.context_window_tokens, threshold) and
            self.compactor.stateIs(.idle))
        {
            self.startCompaction() catch |err| switch (err) {
                // Nothing worth cutting while already past the swap watermark:
                // emit a one-shot notice instead of looping silently into
                // provider overflow errors (TD-6).
                error.NothingToCompact => if (compaction.shouldSwap(used, self.context_window_tokens, threshold)) {
                    if (!self.compaction_stuck_notified) {
                        self.compaction_stuck_notified = true;
                        self.emitCompactionNotice(listener, .stuck);
                    }
                },
                else => log.warn("compaction start failed: {s}", .{@errorName(err)}),
            };
        }

        // If used tokens still exceed the swap watermark and compaction is running,
        // wait synchronously so prompt sent to LLM fits within window. The wait
        // can take up to the (user-configurable) request timeout, so make it
        // visible before blocking (H2).
        if (compaction.shouldSwap(self.currentContextTokens(), self.context_window_tokens, threshold) and
            self.compactor.stateIs(.running))
        {
            self.emitCompactionNotice(listener, .waiting);
            self.joinCompactor();
            Agent.applyReadyCompaction(@TypeOf(listener), self, listener) catch |err| log.warn("compaction apply failed: {s}", .{@errorName(err)});
        }
    }

    /// Manually trigger a full compaction cycle: snapshot, summarize, swap.
    /// Synchronous wrapper over `requestManualCompact` + `pollManualCompact`,
    /// kept for the headless/test path. The TUI does NOT use this — it drives
    /// the two phases from its tick loop so the UI never blocks on the
    /// summarizer request. Returns the token counts before and after on
    /// success, or an error describing what went wrong.
    pub fn forceCompact(self: *Agent) !Event.HistoryCompacted {
        try self.requestManualCompact();
        // A deferred start (a stale auto-run was still producing) resolves on
        // the first poll; loop until the manual run lands. The poll returns
        // non-null or an error once the state resolves, so this always
        // terminates. 1000 yields is a defensive bound against a state that
        // never resolves (e.g. a torn-down client the poll failed to clear).
        var spins: u32 = 0;
        while (spins < 1000) : (spins += 1) {
            if (try self.pollManualCompact()) |info| return info;
            std.Thread.yield() catch {};
        }
        return error.CompactionNotReady;
    }

    /// Non-blocking phase 1 of the manual compact: snapshot the prefix and
    /// hand it to the summarizer thread, then return. The UI polls
    /// `pollManualCompact` to learn when the summary lands. A stale
    /// auto-compaction still in flight is not joined here — the poll discards
    /// it when it lands and starts the manual run then, so this never blocks
    /// on the summarizer's request.
    pub fn requestManualCompact(self: *Agent) !void {
        if (self.compaction_client == .none) return error.NoCompactionClient;
        if (self.context_window_tokens == 0) return error.UnknownContextWindow;
        if (self.context_manager.session_writer == null) return error.NoSessionWriter;
        if (self.manual_compact_pending) return error.CompactionInProgress;

        if (self.compactor.stateIs(.running)) {
            // A stale auto-run is still producing. Wait for it to land; the
            // poll discards it and starts the manual run (TD-1).
            self.manual_compact_pending = true;
            self.manual_compact_started = false;
            return;
        }

        // Instant when no thread is alive: a `.ready`/`.failed` residue is
        // drained, then the manual run starts.
        self.drainBackgroundCompaction();
        try self.startCompaction();
        self.manual_compact_pending = true;
        self.manual_compact_started = true;
    }

    /// Non-blocking phase 2 of the manual compact: polled by the UI each tick
    /// while `manual_compact_pending`. Returns null while the summarizer is
    /// still producing, the token-count event once the manual summary is
    /// installed, or an error describing what went wrong. Never blocks —
    /// `joinCompactor` is only reached once the thread has already finished.
    pub fn pollManualCompact(self: *Agent) !?Event.HistoryCompacted {
        if (!self.manual_compact_pending) return null;

        // Client torn down mid-flight (disconnect/reconnect): the summarizer
        // was drained, so abort the manual compact rather than strand the
        // submit gate forever.
        if (self.compaction_client == .none) {
            self.manual_compact_pending = false;
            self.manual_compact_started = false;
            return error.CompactionFailed;
        }

        const state = self.compactor.state.load(.acquire);
        if (state == .running or state == .idle) return null;

        if (!self.manual_compact_started) {
            // The run that just landed is the stale auto one — discard it,
            // then start the manual run (TD-1).
            self.joinCompactor();
            self.finishCompactor();
            self.startCompaction() catch |err| {
                self.manual_compact_pending = false;
                self.manual_compact_started = false;
                return err;
            };
            self.manual_compact_started = true;
            return null;
        }

        // The manual run landed.
        self.joinCompactor();
        defer self.finishCompactor();
        self.manual_compact_pending = false;
        self.manual_compact_started = false;
        if (state == .failed) return error.CompactionFailed;

        const result = self.compactor.result.?;
        const session_writer = self.context_manager.session_writer.?;
        const tokens_before = self.estimateContextTokens();
        try session_writer.appendCompaction(result.first_kept_id.slice(), result.stored_summary);
        try self.reloadFromSession();
        self.resetContextUsage();
        // A successful manual compact proves the pipeline works: reset the
        // breaker so automatic compaction resumes.
        self.compaction_failures = 0;
        self.compaction_breaker_notified = false;
        self.compaction_stuck_notified = false;
        return .{
            .tokens_before = tokens_before,
            .tokens_after = self.estimateContextTokens(),
        };
    }

    /// Snapshot the frozen prefix and hand it to the summarizer thread. The
    /// snapshot (rendered text + first-kept entry id) is self-contained, so the
    /// thread never touches live history.
    fn startCompaction(self: *Agent) !void {
        const session_writer = self.context_manager.session_writer orelse return;
        // Scale the keep-recent budget by the ratio of the provider's real
        // token count to this estimator's, so languages where chars/4
        // undercounts (CJK ≈ 1.5 chars/token) keep fewer messages and still
        // compact below the swap watermark (TD-6). Falls back to the base
        // budget when there is no usage anchor yet.
        const base_keep = compaction.keepRecentTokens(self.context_window_tokens, self.compaction_settings.keep_recent_tokens);
        const recent_tokens = compaction.calibrateKeepBudget(base_keep, self.currentContextTokens(), self.estimateContextTokens());
        const cut = (try session_writer.compactionCut(self.gpa, recent_tokens)) orelse return error.NothingToCompact;
        self.compactor.result = null;
        self.compactor.job = .{
            .gpa = self.gpa,
            .io = self.io,
            .client = self.compaction_client,
            .limiter = self.request_limiter,
            .first_kept_id = cut.first_kept_id,
            .prefix_text = cut.prefix_text,
        };
        self.compactor.state.store(.running, .release);
        self.compactor.thread = std.Thread.spawn(.{}, agent_compactor.Compactor.runThread, .{&self.compactor}) catch |err| {
            self.gpa.free(cut.prefix_text);
            self.compactor.job = null;
            self.compactor.state.store(.idle, .release);
            return err;
        };
    }

    /// Install a finished background summary: write the boundary, reproject, and
    /// emit the notice — instant, because the summary already exists. A failed
    /// run is logged and discarded. No-op while idle or still running.
    fn applyReadyCompaction(comptime L: type, self: *Agent, listener: L) !void {
        const state = self.compactor.state.load(.acquire);
        if (state == .idle or state == .running) return;
        self.joinCompactor();
        defer self.finishCompactor();
        if (state == .failed) {
            self.compaction_failures +|= 1;
            log.warn("background compaction failed ({d}/{d})", .{ self.compaction_failures, compaction_failure_limit });
            return;
        }
        const result = self.compactor.result.?;
        const session_writer = self.context_manager.session_writer orelse return;
        const tokens_before = self.estimateContextTokens();
        try session_writer.appendCompaction(result.first_kept_id.slice(), result.stored_summary);
        try self.reloadFromSession();
        self.resetContextUsage();
        // A successful apply proves the pipeline works: clear the breaker and
        // re-arm the one-shot stuck notice for a future episode.
        self.compaction_failures = 0;
        self.compaction_breaker_notified = false;
        self.compaction_stuck_notified = false;
        try listener.emit(.{ .history_compacted = .{
            .tokens_before = tokens_before,
            .tokens_after = self.estimateContextTokens(),
        } });
    }

    /// Join the summarizer thread if one is alive. Blocks until it finishes —
    /// used both for the overflow wait and at teardown.
    fn joinCompactor(self: *Agent) void {
        if (self.compactor.thread) |thread| {
            thread.join();
            self.compactor.thread = null;
        }
    }

    /// Release the finished job/result and return the compactor to idle.
    fn finishCompactor(self: *Agent) void {
        if (self.compactor.result) |*result| self.gpa.free(result.stored_summary);
        self.compactor.result = null;
        self.compactor.job = null;
        self.compactor.state.store(.idle, .release);
    }

    /// Wait for any in-flight background summary and discard it. Call before
    /// freeing or replacing `compaction_client` so the summarizer thread is
    /// never left running against a client that is about to be torn down.
    /// Also aborts any in-flight manual compact: the run (if any) is gone, so
    /// the pending flags are reset to keep the TUI's submit gate from
    /// dangling on a summary that can never land.
    pub fn drainBackgroundCompaction(self: *Agent) void {
        self.joinCompactor();
        self.finishCompactor();
        self.manual_compact_pending = false;
        self.manual_compact_started = false;
    }

    /// Whether the automatic path should back off after repeated failures.
    fn compactionBreakerTripped(self: *const Agent) bool {
        return self.compaction_failures >= compaction_failure_limit;
    }

    /// Emit a one-shot compaction notice through the agent's event stream. The
    /// notice is a bare enum — no allocation — so the renderer owns the text
    /// and a dropped event (noop listener, full queue) leaks nothing.
    fn emitCompactionNotice(self: *Agent, listener: anytype, notice: Event.CompactionNotice) void {
        _ = self;
        const Ctx = @typeInfo(@TypeOf(listener.ctx)).pointer.child;
        const L = Listener(Ctx);
        const l: L = listener;
        l.emit(.{ .compaction_notice = notice }) catch {};
    }

    /// Rehydrate the cached message list from the session projection after a
    /// compaction boundary was written — the swap. Keeps the system prompt.
    /// Called between turn iterations, where every message is already persisted
    /// and no stream is active; never mid-stream.
    fn reloadFromSession(self: *Agent) !void {
        const session_writer = self.context_manager.session_writer orelse return;
        // Project first, swap second: a failed reprojection leaves the live
        // cache intact instead of stranded with only the system prompt (TD-5).
        const projected = try session_writer.messages(self.gpa);
        errdefer self.gpa.free(projected);
        self.context_manager.clearNonSystem();
        for (projected) |message| try self.context_manager.appendUnpersisted(message);
        self.gpa.free(projected);
    }

    /// Best estimate of the footprint the *next* request will carry: the last
    /// turn's real reported usage (prompt + completion) as an anchor, plus a
    /// size estimate of every message appended since (tool results, queued user
    /// turns) — the part the provider has not accounted for yet. Falls back to
    /// a full estimate when no usage has been reported.
    pub fn currentContextTokens(self: *Agent) u32 {
        const usage = self.last_usage orelse return self.estimateContextTokens();
        const anchored = usage.input_tokens +| usage.output_tokens;
        return anchored +| self.estimateTrailingTokens(self.last_usage_anchor_count);
    }

    /// Sum the estimated tokens of cached messages from `anchor_count` onward —
    /// the messages appended after `last_usage` was captured — counting
    /// historical tool output as the pruned request would send it.
    fn estimateTrailingTokens(self: *Agent, anchor_count: u32) u32 {
        const items = self.context_manager.items();
        return context_assembly.estimatePrunedTokensRange(
            items,
            anchor_count,
            self.compaction_settings.keep_recent_tool_turns,
            self.compaction_settings.historical_tool_cap_bytes,
        );
    }

    /// Record a completed turn's usage as the watermark anchor. The anchor is
    /// the message count *after* the assistant reply landed, so everything
    /// appended later counts as trailing tokens.
    fn recordUsage(self: *Agent, usage: ?ai.Usage) void {
        self.last_usage = usage;
        self.last_usage_anchor_count = self.context_manager.count();
    }

    /// Drop the usage anchor, forcing a full re-estimate next turn. Used after
    /// the history is rebuilt (compaction, branch switch).
    pub fn resetContextUsage(self: *Agent) void {
        self.last_usage = null;
        self.last_usage_anchor_count = 0;
    }

    fn estimateContextTokens(self: *Agent) u32 {
        return context_assembly.estimatePrunedTokensRange(
            self.context_manager.items(),
            0,
            self.compaction_settings.keep_recent_tool_turns,
            self.compaction_settings.historical_tool_cap_bytes,
        );
    }
};

/// Synchronous bash-approval hook. The TUI worker attaches a
/// `*Context` via the opaque `ptr`; `requestBashApproval` (in
/// `tui/agent_worker.zig`) is the bridge and is the only `@ptrCast`
/// left on this seam — making the field generic would require the
/// `Agent` struct itself to be generic, which is invasive. Kept as a
/// vtable; see type-safety-refactor.md P1-A follow-up for `BashApproval(Ctx)`.
pub const BashApproval = struct {
    ptr: *anyopaque,
    request: *const fn (*anyopaque, []const u8) anyerror!bool,
};

const tool_display = @import("tools/display.zig");
pub const parseCommand = tool_display.parseCommand;
pub const formatToolDisplay = tool_display.formatToolDisplay;

test "streaming callbacks emit owned events" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");
    var openai_compatible_client: openai_compatible.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    const Seen = struct {
        events: std.ArrayList(Agent.Event) = .empty,

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            for (self.events.items) |*event| {
                event.deinit(allocator);
            }
            self.events.deinit(allocator);
        }

        fn onEvent(ctx: *@This(), event: Agent.Event) !void {
            try ctx.events.append(std.testing.allocator, event);
        }
    };
    var seen: Seen = .{};
    defer seen.deinit(gpa);
    const Listener = Agent.Listener(Seen);
    var context: Agent.StreamContext(Listener) = .{
        .agent = &agent,
        .listener = .{ .ctx = &seen, .on_event = Seen.onEvent },
    };
    defer context.deinit();

    // Drive the wrapper functions the same way the ai stream layer would.
    try Agent.onReasoningDeltaImpl(Listener)(&context, "checking");
    try Agent.onContentDeltaImpl(Listener)(&context, "hello");
    try Agent.onToolDeltaImpl(Listener)(&context, .{
        .index = 1,
        .name = "bash",
        .arguments = "{\"command\":\"pwd\"}",
    });
    try Agent.onDeltaEndImpl(Listener)(&context);

    try std.testing.expectEqual(@as(usize, 4), seen.events.items.len);
    try std.testing.expectEqualStrings("checking", seen.events.items[0].thinking_delta);
    try std.testing.expectEqualStrings("hello", seen.events.items[1].response_delta);
    try std.testing.expectEqual(@as(u32, 1), seen.events.items[2].tool_delta.index);
    try std.testing.expectEqualStrings("bash", seen.events.items[2].tool_delta.name);
    try std.testing.expectEqualStrings("{\"command\":\"pwd\"}", seen.events.items[2].tool_delta.arguments);
    try std.testing.expectEqual(.delta_end, seen.events.items[3]);
    try std.testing.expect(context.toolDeltaSeen(1));
    try std.testing.expect(!context.toolDeltaSeen(0));
}

test "stream callbacks do not double-free when the listener returns an error" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");
    var openai_compatible_client: openai_compatible.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    const FailingListener = struct {
        gpa: std.mem.Allocator,
        fn onEvent(self: *@This(), event: Agent.Event) anyerror!void {
            // Mirror `postAgentEvent`'s error path: it frees the event's owned
            // data before propagating the failure. The callbacks under test
            // must NOT free it again (that was the double-free bug).
            var ev = event;
            ev.deinit(self.gpa);
            return error.TestFailure;
        }
    };
    var failing: FailingListener = .{ .gpa = gpa };
    const Listener = Agent.Listener(FailingListener);
    var context: Agent.StreamContext(Listener) = .{
        .agent = &agent,
        .listener = .{ .ctx = &failing, .on_event = FailingListener.onEvent },
    };
    defer context.deinit();

    // Each callback must propagate the listener's error without double-freeing
    // the owned slice it passed into `emit`. Before the fix, the `errdefer
    // gpa.free(owned)` in the callback raced with `postAgentEvent`'s own
    // `errdefer event.deinit`, crashing with SIGABRT.
    try std.testing.expectError(error.TestFailure, Agent.onContentDeltaImpl(Listener)(&context, "delta"));
    try std.testing.expectError(error.TestFailure, Agent.onReasoningDeltaImpl(Listener)(&context, "reasoning"));
    try std.testing.expectError(error.TestFailure, Agent.emitToolDelta(Listener, &agent, context.listener, 0, "name", "args"));
    try std.testing.expectError(error.TestFailure, Agent.emitToolCallFinished(Listener, &agent, context.listener, 0, "id", "name", "label", null, "body", .text, null, false));
}

test "run gates the request on the limiter and releases on the error path" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");
    var client: openai_compatible.Client = undefined;
    try client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer client.deinit();

    var agent = Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &client });
    defer agent.deinit();

    var limiter: request_limiter_mod.RequestLimiter = .{ .permits = 1 };
    agent.request_limiter = &limiter;

    var noop: NoopListener = .{};
    const listener: Agent.Listener(NoopListener) = .{
        .ctx = &noop,
        .on_event = NoopListener.onEvent,
    };
    // Dead server → the request fails after its retries; the labeled-block
    // `defer` must have released the permit, so none leaks on the error path.
    try std.testing.expectError(error.ConnectionFailed, agent.run(listener));
    try std.testing.expectEqual(@as(u32, 0), limiter.in_flight);
}

test "queued user messages wait for completed assistant turn" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    try agent.addUser("first");
    try agent.enqueueUser("queued");

    try std.testing.expectEqual(@as(u32, 1), try agent.drainQueuedUserMessage(false));
    try std.testing.expectEqual(@as(usize, 2), agent.messages().len);
    try std.testing.expectEqualStrings("queued", agent.messages()[1].text());
}

test "interrupted tool calls get synthetic cancelled results" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // Assistant issues two tool calls; only the first got a result before the
    // user interrupted — leaving call_b dangling.
    const calls = try gpa.alloc(ai.ContentBlock, 2);
    calls[0] = .{ .tool_call = .{ .call_id = .{ .value = try gpa.dupe(u8, "call_a") }, .name = try gpa.dupe(u8, "read"), .arguments = try gpa.dupe(u8, "{}") } };
    calls[1] = .{ .tool_call = .{ .call_id = .{ .value = try gpa.dupe(u8, "call_b") }, .name = try gpa.dupe(u8, "bash"), .arguments = try gpa.dupe(u8, "{}") } };
    try agent.context_manager.appendUnpersisted(.{ .assistant = .{ .content = calls } });

    const result = try gpa.alloc(ai.ContentBlock, 1);
    result[0] = .{ .text = .{ .text = try gpa.dupe(u8, "ok") } };
    try agent.context_manager.appendUnpersisted(.{ .tool = .{ .call_id = .{ .value = try gpa.dupe(u8, "call_a") }, .content = result } });

    try agent.reconcileInterruptedToolCalls();

    // A synthetic failed result for call_b is appended right after; call_a is left
    // alone.
    const items = agent.messages();
    try std.testing.expectEqual(@as(usize, 3), items.len);
    const synthetic = items[2];
    try std.testing.expect(synthetic == .tool);
    try std.testing.expectEqualStrings("call_b", synthetic.tool.call_id.slice());
    try std.testing.expect(synthetic.tool.failed);

    // Idempotent: every call now has a result, so a second pass adds nothing.
    try agent.reconcileInterruptedToolCalls();
    try std.testing.expectEqual(@as(usize, 3), agent.messages().len);
}

test "recoverTextToolCalls recovers from a text block when there are zero structured calls" {
    // T3 unit test: the recovery helper, exercised on a realistic assistant
    // message — a single text block containing the DB-observed XML shape.
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "<tool_call>bash<arg_key=\"command\">echo recovered</arg_key></tool_call>") } };
    var assistant: ai.ChatMessage = .{ .assistant = .{ .content = blocks } };
    defer assistant.deinit(gpa);

    const recovered = try agent.recoverTextToolCalls(assistant);
    defer {
        for (recovered) |*c| c.deinit(gpa);
        gpa.free(recovered);
    }
    try std.testing.expectEqual(@as(usize, 1), recovered.len);
    try std.testing.expectEqualStrings("bash", recovered[0].name);
    // The arg_key="command" pair is captured (the value sits on the opening tag).
    try std.testing.expectEqualStrings("{\"arg_key\":\"command\"}", recovered[0].arguments);
    try std.testing.expect(std.mem.startsWith(u8, recovered[0].call_id.slice(), "textcall_"));
}

test "injectRecoveredToolCalls appends without dropping existing blocks" {
    // T3 ownership test — the highest-risk failure mode. Build an assistant
    // with a text block, recover one call, inject it, and assert the message
    // now has 2 blocks (text + tool_call) with the original text intact. Run
    // under std.testing.allocator to catch any leak/double-free (the recovered
    // strings are MOVED into the new block, so the slice shell is freed but
    // NOT the element strings).
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "prefix <tool_call>{\"name\":\"bash\",\"arguments\":{\"command\":\"x\"}}</tool_call> suffix") } };
    var assistant: ai.ChatMessage = .{ .assistant = .{ .content = blocks } };
    defer assistant.deinit(gpa);

    const recovered = try agent.recoverTextToolCalls(assistant);
    // After inject, the element strings belong to the message — free only the shell.
    defer gpa.free(recovered);
    try std.testing.expectEqual(@as(usize, 1), recovered.len);

    try agent.injectRecoveredToolCalls(&assistant, recovered);
    // 2 blocks now: the original text + the injected tool_call.
    try std.testing.expectEqual(@as(usize, 2), assistant.assistant.content.len);
    try std.testing.expect(assistant.assistant.content[0] == .text);
    try std.testing.expectEqualStrings("prefix <tool_call>{\"name\":\"bash\",\"arguments\":{\"command\":\"x\"}}</tool_call> suffix", assistant.assistant.content[0].text.text);
    try std.testing.expect(assistant.assistant.content[1] == .tool_call);
    try std.testing.expectEqualStrings("bash", assistant.assistant.content[1].tool_call.name);

    // collectToolCalls now sees the recovered call (the turn-loop window).
    const recollected = try agent.collectToolCalls(assistant);
    defer gpa.free(recollected);
    try std.testing.expectEqual(@as(usize, 1), recollected.len);
    try std.testing.expectEqualStrings("bash", recollected[0].name);
}

test "T3 turn-loop window: zero structured calls + text recovery yields executable tool_calls" {
    // Integration of the exact turn-loop window (collect → recover → inject)
    // without firing a full HTTP turn. Mirrors the ordering fact in plan §1.1:
    // recovery must run BEFORE takeAssistantMessage, and the recovered slice
    // drives execution via re-collection. No use-after-free because the
    // message is live throughout the window.
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // Simulate a turn whose assistant emitted a tool call as TEXT (zero
    // structured .tool_call blocks).
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "Sure! <tool_call>{\"name\":\"bash\",\"arguments\":{\"command\":\"echo done\"}}</tool_call>") } };
    var assistant: ai.ChatMessage = .{ .assistant = .{ .content = blocks } };
    defer assistant.deinit(gpa);

    // Step 1: collect — zero structured calls.
    const initial = try agent.collectToolCalls(assistant);
    defer gpa.free(initial);
    try std.testing.expectEqual(@as(usize, 0), initial.len);

    // Step 2: recover — fire because initial is empty.
    const recovered = try agent.recoverTextToolCalls(assistant);
    defer gpa.free(recovered);
    try std.testing.expectEqual(@as(usize, 1), recovered.len);

    // Step 3: inject so takeAssistantMessage persists the recovered call.
    try agent.injectRecoveredToolCalls(&assistant, recovered);

    // Step 4: the slice that would drive execution (recovered, per plan §2.2)
    // has length > 0 → runToolBatch would fire, not the idle-drain branch.
    const tool_calls: []const ai.ToolCall = recovered;
    try std.testing.expect(tool_calls.len > 0);
    try std.testing.expectEqualStrings("bash", tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"echo done\"}", tool_calls[0].arguments);
}

test "context token estimate anchors on usage plus trailing messages" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // Anchor on a reported usage just after an assistant reply (1 message).
    try agent.context_manager.appendUnpersisted(try agent.makeTextMessage(.assistant, "a" ** 40));
    agent.recordUsage(.{ .input_tokens = 1000, .output_tokens = 200, .total_tokens = 1200 });
    // A tool result appended afterwards (~40 bytes -> 10 estimated tokens).
    try agent.context_manager.appendUnpersisted(try agent.makeToolMessage("b" ** 40));

    // anchor total (1000 + 200) + trailing estimate (10) = 1210
    try std.testing.expectEqual(@as(u32, 1210), agent.currentContextTokens());
}

test "queued user messages drain one at a time" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    try agent.enqueueUser("first");
    try agent.enqueueUser("second");

    try std.testing.expectEqual(@as(u32, 1), try agent.drainQueuedUserMessage(false));
    try std.testing.expectEqual(@as(usize, 1), agent.messages().len);
    try std.testing.expectEqual(@as(u32, 1), agent.message_queue.len());
    try std.testing.expectEqualStrings("first", agent.messages()[0].text());
}

test "steer-only drain pops a steered front but leaves default-queued messages" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    try agent.enqueueUser("steer me");
    try agent.enqueueUser("later");
    agent.setQueuedSteer(0);

    // The steered front injects mid-turn...
    try std.testing.expectEqual(@as(u32, 1), try agent.drainQueuedUserMessage(true));
    try std.testing.expectEqualStrings("steer me", agent.messages()[0].text());
    // ...but the default-queued one behind it waits for turn end.
    try std.testing.expectEqual(@as(u32, 0), try agent.drainQueuedUserMessage(true));
    try std.testing.expectEqual(@as(u32, 1), agent.message_queue.len());
    // The turn-end drain (steer_only = false) takes it.
    try std.testing.expectEqual(@as(u32, 1), try agent.drainQueuedUserMessage(false));
    try std.testing.expectEqualStrings("later", agent.messages()[1].text());
}

test "drain all queued moves the whole queue to history in FIFO order" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    try agent.enqueueUser("a");
    try agent.enqueueUser("b");
    try agent.enqueueUser("c");

    try std.testing.expectEqual(@as(u32, 3), try agent.drainAllQueuedToHistory());
    try std.testing.expectEqual(@as(usize, 3), agent.messages().len);
    try std.testing.expectEqualStrings("a", agent.messages()[0].text());
    try std.testing.expectEqualStrings("c", agent.messages()[2].text());
    try std.testing.expectEqual(@as(u32, 0), agent.message_queue.len());
}

test "raw enqueued messages are delivered verbatim without @-mention expansion" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    try std.testing.expect(!agent.hasQueuedMessages());
    // A background completion notice may contain an `@` that must not be treated
    // as a file mention.
    try agent.enqueueRaw("Background command bg_1 (`echo @no/such/file`) finished — exit 0");
    try std.testing.expect(agent.hasQueuedMessages());

    try std.testing.expectEqual(@as(u32, 1), try agent.drainQueuedUserMessage(false));
    try std.testing.expectEqual(@as(usize, 1), agent.messages().len);
    try std.testing.expectEqualStrings(
        "Background command bg_1 (`echo @no/such/file`) finished — exit 0",
        agent.messages()[0].text(),
    );
    try std.testing.expect(!agent.hasQueuedMessages());
}

test "clear queue drops messages without delivering them" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    try agent.enqueueUser("x");
    try agent.enqueueUser("y");
    agent.clearQueue();

    try std.testing.expectEqual(@as(u32, 0), agent.message_queue.len());
    try std.testing.expectEqual(@as(usize, 0), agent.messages().len);
}

// ── P1: compaction / checkpoint core regression tests ──────────────────
//
// The highest-edge-density cluster (snapshotAfterBatch, runToolBatch,
// maybeCompact, forceCompact, applyReadyCompaction) was entirely test-free,
// the same path the da7c761 resume-segfault class of regressions comes from.
// These cover the no-op / early-return contracts documented in the pseudocode:
// disabled compaction, sub-watermark, the failed-compactor discard, and the
// snapshot short-circuits that latch `snapshots_disabled` off silently.

/// No-op listener for `maybeCompact`: compaction events are discarded. The
/// agent owns nothing from it, so there is no per-test cleanup.
const NoopListener = struct {
    fn onEvent(_: *@This(), _: Agent.Event) !void {}
};

test "snapshotAfterBatch: disabled snapshots return without touching git" {
    // `snapshots_disabled = true` is the early return before any vcs call, so
    // this exercises the no-git-available branch without needing a repo.
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    agent.snapshots_disabled = true;
    agent.snapshotAfterBatch(); // must not error or allocate

    try std.testing.expect(agent.snapshots_disabled);
    try std.testing.expect(agent.snapshot_index == null);
    try std.testing.expect(agent.last_snapshot_tree == null);
}

test "snapshotAfterBatch: no session writer short-circuits silently" {
    // Without a session_writer the function returns at the second guard, also
    // never touching git — confirming the best-effort contract holds even when
    // git IS available but no session is attached.
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // snapshots_disabled stays false, but no session_writer is attached.
    agent.snapshotAfterBatch();

    // No panic, no error; the guard left the disabled flag untouched because
    // it never reached the git-availability probe.
    try std.testing.expect(!agent.snapshots_disabled);
}

test "maybeCompact: disabled auto stays a no-op below the watermark" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // No compaction_client and no context window: every guard short-circuits.
    // Setting auto=false first makes the intent explicit even though the other
    // guards would also bail.
    agent.compaction_settings.auto = false;
    var noop: NoopListener = .{};
    const listener: Agent.Listener(NoopListener) = .{
        .ctx = &noop,
        .on_event = NoopListener.onEvent,
    };
    agent.maybeCompact(listener);

    // Compactor never left idle, no event emitted (noop listener would error
    // otherwise — there is nothing to assert beyond not panicking).
    try std.testing.expect(agent.compactor.stateIs(.idle));
}

test "forceCompact: no compaction client returns NoCompactionClient without swapping" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // The very first guard: compaction_client == .none.
    try std.testing.expectError(error.NoCompactionClient, agent.forceCompact());
    try std.testing.expect(agent.compactor.stateIs(.idle));
}

test "forceCompact: window guard fires before the writer guard" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // The guard order is NoCompactionClient → UnknownContextWindow →
    // NoSessionWriter (see forceCompact body). With a `.none` client the first
    // guard wins regardless of the other fields, so the function never reaches
    // the writer check — confirming the order matches the source.
    agent.context_window_tokens = 4096; // would pass the window guard
    try std.testing.expectError(error.NoCompactionClient, agent.forceCompact());
    try std.testing.expect(agent.compactor.stateIs(.idle));
}

/// Add `count` long persisted user messages so a compaction cut exists under
/// the default keep budget. Each message is ~370 tokens; `cutByTokenBudget`
/// only cuts once the newest (len-1) messages already exceed the budget, so
/// `count` must be comfortably past the 1433-token budget for a 4096 window.
/// 10 × 370 = 3700 total, newest 9 = 3330 > budget — a cut past the first
/// message. Pub so the TUI tests can reuse the same session shape.
pub fn fillSessionForCompaction(agent: *Agent, count: usize) !void {
    const filler =
        "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua ut enim ad minim veniam quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur excepteur sint occaecat cupidatat non proident sunt in culpa qui officia deserunt mollit anim id est laborum " ++
        "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua ut enim ad minim veniam quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur excepteur sint occaecat cupidatat non proident sunt in culpa qui officia deserunt mollit anim id est laborum " ++
        "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua ut enim ad minim veniam quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur excepteur sint occaecat cupidatat non proident sunt in culpa qui officia deserunt mollit anim id est laborum " ++
        "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua";
    var i: usize = 0;
    while (i < count) : (i += 1) try agent.addUser(filler);
}

test "requestManualCompact: guard order matches forceCompact" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // The very first guard: compaction_client == .none.
    try std.testing.expectError(error.NoCompactionClient, agent.requestManualCompact());
    try std.testing.expect(!agent.manual_compact_pending);
    try std.testing.expect(agent.compactor.stateIs(.idle));

    // Window guard fires before the writer guard (same order as forceCompact).
    agent.context_window_tokens = 4096;
    try std.testing.expectError(error.NoCompactionClient, agent.requestManualCompact());
    try std.testing.expect(!agent.manual_compact_pending);
}

test "requestManualCompact: defers to a stale run instead of starting a second" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".config/nova");
    const home_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_dir);

    var writer: session_mod.SessionWriter = undefined;
    try session_mod.SessionWriter.initDefault(&writer, gpa, std.testing.io, home_dir, "/tmp");
    defer writer.deinit();

    var client: openai_compatible.Client = undefined;
    try client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer client.deinit();

    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    agent.attachSessionWriter(&writer);
    agent.compaction_client = .{ .openai_compatible = &client };
    agent.context_window_tokens = 4096;

    // A stale auto-run is in flight: request must defer, not spawn a second
    // thread or disturb the running state.
    agent.compactor.state.store(.running, .release);
    try agent.requestManualCompact();
    try std.testing.expect(agent.manual_compact_pending);
    try std.testing.expect(!agent.manual_compact_started);
    try std.testing.expect(agent.compactor.stateIs(.running));

    // A second request while pending is refused.
    try std.testing.expectError(error.CompactionInProgress, agent.requestManualCompact());
}

test "requestManualCompact starts a run; poll fails it against a dead server" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".config/nova");
    const home_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_dir);

    var writer: session_mod.SessionWriter = undefined;
    try session_mod.SessionWriter.initDefault(&writer, gpa, std.testing.io, home_dir, "/tmp");
    defer writer.deinit();

    var client: openai_compatible.Client = undefined;
    try client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer client.deinit();

    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    agent.attachSessionWriter(&writer);
    agent.compaction_client = .{ .openai_compatible = &client };
    agent.context_window_tokens = 4096;
    try fillSessionForCompaction(&agent, 10);

    try agent.requestManualCompact();
    try std.testing.expect(agent.manual_compact_pending);
    try std.testing.expect(agent.manual_compact_started);
    try std.testing.expect(agent.compactor.stateIs(.running));

    // The summarizer fails against the dead server; the poll surfaces it and
    // clears the pending flags.
    var spins: u32 = 0;
    while (!agent.compactor.stateIs(.failed) and spins < 10_000) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(agent.compactor.stateIs(.failed));
    try std.testing.expectError(error.CompactionFailed, agent.pollManualCompact());
    try std.testing.expect(!agent.manual_compact_pending);
    try std.testing.expect(!agent.manual_compact_started);
    try std.testing.expect(agent.compactor.stateIs(.idle));
}

test "pollManualCompact: returns null while the summarizer is running" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");
    var client: openai_compatible.Client = undefined;
    try client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer client.deinit();

    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    agent.compaction_client = .{ .openai_compatible = &client };
    agent.manual_compact_pending = true;
    agent.manual_compact_started = true;
    agent.compactor.state.store(.running, .release);

    try std.testing.expect((try agent.pollManualCompact()) == null);
    try std.testing.expect(agent.manual_compact_pending);
}

test "pollManualCompact: torn-down client aborts and clears the pending flags" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    agent.manual_compact_pending = true;
    agent.manual_compact_started = true;

    // compaction_client stays .none — simulates a disconnect mid-compact.
    try std.testing.expectError(error.CompactionFailed, agent.pollManualCompact());
    try std.testing.expect(!agent.manual_compact_pending);
    try std.testing.expect(!agent.manual_compact_started);
}

test "pollManualCompact: a failed summarizer surfaces CompactionFailed and clears the flags" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");
    var client: openai_compatible.Client = undefined;
    try client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer client.deinit();

    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    agent.compaction_client = .{ .openai_compatible = &client };

    // Fake an in-flight manual run: the summarizer thread fails (dead server →
    // connection refused) and flips to `.failed`; poll must surface it and
    // return the compactor to idle without leaking the result slot.
    agent.compactor.job = .{
        .gpa = gpa,
        .io = std.testing.io,
        .client = .{ .openai_compatible = &client },
        .limiter = null,
        .first_kept_id = undefined, // never read on the failure path
        .prefix_text = try gpa.dupe(u8, "some prefix"),
    };
    agent.compactor.state.store(.running, .release);
    agent.compactor.thread = try std.Thread.spawn(.{}, agent_compactor.Compactor.runThread, .{&agent.compactor});
    agent.manual_compact_pending = true;
    agent.manual_compact_started = true;

    var spins: u32 = 0;
    while (!agent.compactor.stateIs(.failed) and spins < 10_000) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(agent.compactor.stateIs(.failed));

    try std.testing.expectError(error.CompactionFailed, agent.pollManualCompact());
    try std.testing.expect(!agent.manual_compact_pending);
    try std.testing.expect(!agent.manual_compact_started);
    try std.testing.expect(agent.compactor.stateIs(.idle));
}

test "pollManualCompact: discards a stale background result before the manual run" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".config/nova");
    const home_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_dir);

    var writer: session_mod.SessionWriter = undefined;
    try session_mod.SessionWriter.initDefault(&writer, gpa, std.testing.io, home_dir, "/tmp");
    defer writer.deinit();

    var client: openai_compatible.Client = undefined;
    try client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer client.deinit();

    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    agent.attachSessionWriter(&writer);
    agent.compaction_client = .{ .openai_compatible = &client };
    agent.context_window_tokens = 4096;
    try fillSessionForCompaction(&agent, 10);

    // A stale auto summary is ready (no thread) and the manual run has not
    // started yet: the request deferred on an in-flight auto-run.
    agent.manual_compact_pending = true;
    agent.manual_compact_started = false;
    agent.compactor.result = .{
        .first_kept_id = undefined,
        .stored_summary = try gpa.dupe(u8, "stale summary"),
    };
    agent.compactor.state.store(.ready, .release);

    // First poll: the stale result is discarded (TD-1) and the manual run
    // starts. Returns null — the manual run is now in flight.
    try std.testing.expect((try agent.pollManualCompact()) == null);
    try std.testing.expect(agent.manual_compact_started);

    // The manual run fails against the dead server; the poll surfaces it.
    var spins: u32 = 0;
    while (!agent.compactor.stateIs(.failed) and spins < 10_000) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(agent.compactor.stateIs(.failed));
    try std.testing.expectError(error.CompactionFailed, agent.pollManualCompact());
    try std.testing.expect(!agent.manual_compact_pending);
    try std.testing.expect(!agent.manual_compact_started);
    try std.testing.expect(agent.compactor.stateIs(.idle));
}

test "compaction watermarks: shouldStartSummary fires before shouldSwap" {
    // Pure checks of the watermark contracts the maybeCompact/forceCompact
    // logic depends on. A 10 000-token window, default threshold 0.75:
    // start = round(10000 * 0.75) = 7500, swap = round(10000 * 0.95) = 9500.
    const context_window: u32 = 10_000;
    const threshold: f64 = 0.75;

    try std.testing.expect(!compaction.shouldStartSummary(7_000, context_window, threshold));
    try std.testing.expect(compaction.shouldStartSummary(8_000, context_window, threshold));
    try std.testing.expect(!compaction.shouldSwap(8_000, context_window, threshold));
    try std.testing.expect(compaction.shouldSwap(9_600, context_window, threshold));

    // keepRecentTokens scales with the window: 35% capped at the config keep.
    try std.testing.expectEqual(@as(u32, 3_500), compaction.keepRecentTokens(context_window, 8_000));
    // Small-context model: the %35 of 8000 is 2800, under the 8k cap, but the
    // 1000 floor applies only when the window is tiny.
    try std.testing.expectEqual(@as(u32, 1_000), compaction.keepRecentTokens(1_000, 8_000));
}

test "drain discards a ready summary and returns the compactor to idle" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // A finished background summary sitting in `.ready` — no thread. Drain
    // must free the stored summary (leak-checked) and return to idle (TD-1).
    agent.compactor.result = .{
        .first_kept_id = undefined,
        .stored_summary = try gpa.dupe(u8, "stale summary"),
    };
    agent.compactor.state.store(.ready, .release);

    agent.drainBackgroundCompaction();

    try std.testing.expect(agent.compactor.stateIs(.idle));
    try std.testing.expect(agent.compactor.result == null);
    try std.testing.expect(agent.compactor.thread == null);
}

test "drain joins a running summarizer that fails against a dead server" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");
    var client: openai_compatible.Client = undefined;
    try client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer client.deinit();
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // Fake an in-flight job: the summarizer thread will fail (dead server →
    // connection refused) and flip to `.failed`; drain must join it and return
    // the compactor to idle without leaking the result slot (TD-1).
    agent.compactor.job = .{
        .gpa = gpa,
        .io = std.testing.io,
        .client = .{ .openai_compatible = &client },
        .limiter = null,
        .first_kept_id = undefined, // never read on the failure path
        .prefix_text = try gpa.dupe(u8, "some prefix"),
    };
    agent.compactor.state.store(.running, .release);
    agent.compactor.thread = try std.Thread.spawn(.{}, agent_compactor.Compactor.runThread, .{&agent.compactor});

    // Wait for the summarizer to fail (connection refused, so this is fast).
    var spins: u32 = 0;
    while (!agent.compactor.stateIs(.failed) and spins < 10_000) : (spins += 1) {
        std.testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(agent.compactor.stateIs(.failed));

    agent.drainBackgroundCompaction();
    try std.testing.expect(agent.compactor.stateIs(.idle));
    try std.testing.expect(agent.compactor.thread == null);
}

test "compaction breaker trips after repeated failures and backs off automatically" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".config/nova");
    const home_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_dir);

    var writer: session_mod.SessionWriter = undefined;
    try session_mod.SessionWriter.initDefault(&writer, gpa, std.testing.io, home_dir, "/tmp");
    defer writer.deinit();

    var client: openai_compatible.Client = undefined;
    try client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer client.deinit();

    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    agent.attachSessionWriter(&writer);
    agent.compaction_client = .{ .openai_compatible = &client };
    agent.context_window_tokens = 4096;
    agent.compaction_failures = compaction_failure_limit;
    agent.compaction_breaker_notified = false;

    const Seen = struct {
        notices: std.ArrayList(Agent.Event.CompactionNotice) = .empty,

        fn onEvent(ctx: *@This(), event: Agent.Event) !void {
            switch (event) {
                .compaction_notice => |notice| try ctx.notices.append(std.testing.allocator, notice),
                else => {},
            }
        }
    };
    var seen: Seen = .{};
    defer seen.notices.deinit(gpa);
    const Listener = Agent.Listener(Seen);
    const listener: Listener = .{ .ctx = &seen, .on_event = Seen.onEvent };

    // Tripped: maybeCompact emits the one-shot breaker notice and backs off.
    agent.maybeCompact(listener);
    try std.testing.expectEqual(@as(usize, 1), seen.notices.items.len);
    try std.testing.expectEqual(Agent.Event.CompactionNotice.breaker_tripped, seen.notices.items[0]);
    try std.testing.expect(agent.compactor.stateIs(.idle));

    // The notice is one-shot: a second call emits nothing new.
    agent.maybeCompact(listener);
    try std.testing.expectEqual(@as(usize, 1), seen.notices.items.len);

    // Failure bookkeeping: each failed apply increments toward the limit.
    agent.compaction_failures = compaction_failure_limit - 1;
    agent.compactor.state.store(.failed, .release);
    try Agent.applyReadyCompaction(Listener, &agent, listener);
    try std.testing.expectEqual(compaction_failure_limit, agent.compaction_failures);
}

test "applyReadyCompaction resets the breaker on a successful swap" {
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".config/nova");
    const home_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(home_dir);

    var writer: session_mod.SessionWriter = undefined;
    try session_mod.SessionWriter.initDefault(&writer, gpa, std.testing.io, home_dir, "/tmp");
    defer writer.deinit();

    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    agent.attachSessionWriter(&writer);

    // Two persisted user messages so a 1-token keep budget cuts after the first.
    try agent.addUser("hello");
    try agent.addUser("world");
    const cut = (try writer.compactionCut(gpa, 1)) orelse return error.TestFailed;
    defer gpa.free(cut.prefix_text);

    // Simulate a ready background summary while the breaker was tripped.
    agent.compactor.result = .{
        .first_kept_id = cut.first_kept_id,
        .stored_summary = try gpa.dupe(u8, "SUMMARY"),
    };
    agent.compactor.state.store(.ready, .release);
    agent.compaction_failures = compaction_failure_limit;
    agent.compaction_breaker_notified = true;
    agent.compaction_stuck_notified = true;

    const Seen = struct {
        fn onEvent(_: *@This(), _: Agent.Event) !void {}
    };
    var seen: Seen = .{};
    const Listener = Agent.Listener(Seen);
    const listener: Listener = .{ .ctx = &seen, .on_event = Seen.onEvent };

    try Agent.applyReadyCompaction(Listener, &agent, listener);

    // A successful swap proves the pipeline works: breaker cleared, notices
    // re-armed for a future episode.
    try std.testing.expectEqual(@as(u32, 0), agent.compaction_failures);
    try std.testing.expect(!agent.compaction_breaker_notified);
    try std.testing.expect(!agent.compaction_stuck_notified);
}

test "assistant message with only reasoning is dropped from history" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");
    var openai_compatible_client: openai_compatible.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    // A reasoning-only assistant message has no wire content.
    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .reasoning = .{ .text = try gpa.dupe(u8, "thinking") } };
    var message: ai.ChatMessage = .{ .assistant = .{ .content = blocks } };
    defer message.deinit(gpa);
    try std.testing.expect(!Agent.hasWireContent(message));
}

test "assistant message with text or tool calls is kept" {
    const gpa = std.testing.allocator;
    const openai_compatible = @import("ai/openai_compatible.zig");
    var openai_compatible_client: openai_compatible.Client = undefined;
    try openai_compatible_client.init(gpa, std.testing.io, .{ .base_url = "http://127.0.0.1:1", .api_key = "test", .model = "test" });
    defer openai_compatible_client.deinit();
    var agent = Agent.init(gpa, std.testing.io, ".", .{ .openai_compatible = &openai_compatible_client });
    defer agent.deinit();

    const blocks = try gpa.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "answer") } };
    var text_message: ai.ChatMessage = .{ .assistant = .{ .content = blocks } };
    defer text_message.deinit(gpa);
    try std.testing.expect(Agent.hasWireContent(text_message));

    const call_blocks = try gpa.alloc(ai.ContentBlock, 1);
    call_blocks[0] = .{ .tool_call = .{
        .call_id = .{ .value = try gpa.dupe(u8, "c1") },
        .name = try gpa.dupe(u8, "bash"),
        .arguments = try gpa.dupe(u8, "{}"),
    } };
    var call_message: ai.ChatMessage = .{ .assistant = .{ .content = call_blocks } };
    defer call_message.deinit(gpa);
    try std.testing.expect(Agent.hasWireContent(call_message));
}

test "I3: setWorkspace/effectiveCwd round-trip under the test allocator" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();

    // No borrow: effectiveCwd falls back to the session cwd.
    try std.testing.expectEqualStrings(".", agent.effectiveCwd());
    try std.testing.expect(agent.workspaceBorrow() == null);

    // Set a borrow (a lane worktree path, borrowed — never freed here).
    agent.setWorkspace("/tmp/nova-lanes/abc123");
    try std.testing.expectEqualStrings("/tmp/nova-lanes/abc123", agent.effectiveCwd());
    try std.testing.expectEqualStrings("/tmp/nova-lanes/abc123", agent.workspaceBorrow().?);

    // Clear it back.
    agent.setWorkspace(null);
    try std.testing.expectEqualStrings(".", agent.effectiveCwd());
    try std.testing.expect(agent.workspaceBorrow() == null);
}
