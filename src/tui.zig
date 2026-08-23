const std = @import("std");
const log = std.log.scoped(.tui);
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const agent_mod = @import("agent.zig");
const ai = @import("ai.zig");
pub const background_mod = @import("background.zig");
pub const BackgroundDelivery = app_state.BackgroundModalState.BackgroundDelivery;
pub const Agent = agent_mod.Agent;
pub const lane_bridge_mod = @import("tools/lane_bridge.zig");
const request_limiter_mod = @import("request_limiter.zig");
const search_mod = @import("search.zig");
const auth = @import("auth/store.zig");
const config_mod = @import("config/config.zig");
const mcp_mod = @import("mcp/manager.zig");
const lua_mod = @import("lua/root.zig");
const tools_mod = @import("tools.zig");
const runtime_mod = @import("runtime.zig");
const session_mod = @import("session.zig");
const vcs = @import("vcs.zig");
pub const transcript_mod = @import("transcript.zig");
const CountingAllocator = @import("counting_allocator").CountingAllocator;
pub const agent_worker = @import("tui/agent_worker.zig");
const model_catalogue = @import("tui/model_catalogue.zig");
const tui_turn_view = @import("tui/turn_view.zig");
const event_router = @import("tui/event_router.zig");
const command_router = @import("tui/command_router.zig");
const session_switcher = @import("tui/session_switcher.zig");
const app_state = @import("tui/app_state.zig");
const toast = @import("tui/toast.zig");
const background_delivery = @import("tui/background_delivery.zig");
const turn_lifecycle = @import("tui/turn_lifecycle.zig");
const checkpoint_mod = @import("tui/checkpoint.zig");
const mode_lifecycle = @import("tui/mode_lifecycle.zig");
const input_lifecycle = @import("tui/input_lifecycle.zig");
const transcript_lifecycle = @import("tui/transcript_lifecycle.zig");
pub const Thread = @import("tui/thread.zig");
const BoundedList = @import("tui/bounded_list.zig").BoundedList;
/// Maximum concurrent lanes (driver + 3 parallel workers).
pub const max_threads: u32 = 4;
const tui_metrics = @import("tui/metrics.zig");
const tui_layout = @import("tui/layout.zig");
const provider_model = @import("tui/provider_model.zig");
const diff_lifecycle = @import("tui/diff_lifecycle.zig");
pub const DiffCounts = diff_lifecycle.DiffCounts;
pub const DiffRefreshOutcome = diff_lifecycle.DiffRefreshOutcome;
const diff_utils = @import("tui/diff_utils.zig");
const lane_lifecycle = @import("tui/lane_lifecycle.zig");
const lifecycle = @import("tui/lifecycle.zig");
const settings_lifecycle = @import("tui/settings_lifecycle.zig");
const theme_lifecycle = @import("tui/theme_lifecycle.zig");
const search_lifecycle = @import("tui/search_lifecycle.zig");
const overlay = @import("tui/widgets/overlay.zig");
const root_layout_widget = @import("tui/root_layout.zig");
const input_mod = @import("tui/widgets/input.zig");
const tui_message = @import("tui/widgets/message.zig");
const blackhole = @import("tui/blackhole.zig");
const at_search = @import("tui/widgets/at_search.zig");
const diff = @import("tui/widgets/diff.zig");
const diff_viewer = @import("tui/diff_viewer.zig");
const model_picker = @import("tui/widgets/model_picker.zig");
const provider_picker = @import("tui/widgets/provider_picker.zig");
const tree_selector = @import("tui/widgets/tree_selector.zig");
const lanes_picker = @import("tui/widgets/lanes_picker.zig");
const tui_provider = @import("tui/provider_controller.zig");
const tui_style = @import("tui/style.zig");
pub const modelsdev = @import("models/registry.zig");

const ConversationLayout = tui_message.ConversationLayout;
const MessageWidget = tui_message.MessageWidget;
const mergedSelectedStyle = tui_style.mergedSelectedStyle;
const messageRowsCached = tui_metrics.messageRowsCached;

const loading_spinners = tui_turn_view.loading_spinners;
const loading_frame_ms = tui_message.loading_frame_ms;
const command_prefix: u8 = '/';
const long_message_scroll_step_rows: u16 = 3;
/// How many recent parent-lane messages ride along as branch-naming context
/// when a lane is forked with `/parallel`.
pub const lane_naming_context_max: usize = 3;
const transcript_nav = @import("tui/transcript_nav.zig");
pub const TranscriptNavigation = transcript_nav.TranscriptNavigation;
const at_search_mod = @import("tui/at_search.zig");
const permission_mod = @import("tui/permission.zig");
const event_callbacks = @import("tui/event_callbacks.zig");
const queue_mod = @import("tui/queue.zig");
pub const MentionSearchKind = at_search_mod.MentionSearchKind;

/// A single-row clickable region on screen (absolute coordinates). Used to
/// hit-test mouse clicks against the pink lanes chip.
pub const ChipRect = struct {
    row: u16,
    col: u16,
    width: u16,

    pub fn contains(self: ChipRect, row: i16, col: i16) bool {
        if (row < 0 or col < 0) return false;
        const r: u16 = @intCast(row);
        const c: u16 = @intCast(col);
        return r == self.row and c >= self.col and c < self.col + self.width;
    }
};

const CheckpointState = enum { unknown, ready, unavailable };
pub const catalogue_provider_count = config_mod.catalogueProviders().len;

pub const App = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// All lanes the developer has open, heap-allocated so their addresses stay
    /// stable while live runtimes and (later) worker threads hold references.
    /// Owns the `Thread`s; freed in `deinit`.
    threads: BoundedList(*Thread, max_threads) = .{},
    /// Monotonic lane-generation counter, assigned to every Thread at its
    /// creation site (UI thread only). Spawned-worker completion routing uses
    /// it instead of a raw `*Agent` pointer so a session switch (which frees
    /// the spawner's agent) can't misroute a delivery via allocator address
    /// reuse.
    lane_generation_counter: u64 = 0,
    /// The lane currently on screen — always one of `threads`. A pointer (not an
    /// index) so every `self.thread.X` site reads/mutates the active lane through
    /// auto-deref, even from a `*const App`.
    thread: *Thread,
    /// Set when the active branch may have changed (lane switch, or any tool
    /// call that could have run `git`). `handleTick` refreshes `metrics.git_label`
    /// once and clears it — never polls, so idle time costs zero `git` calls.
    git_label_dirty: bool = true,
    /// The lane whose branch was last shown. `handleTick` compares it against
    /// `thread` to detect a lane switch (which changes the branch) without
    /// polling — a switch arms `git_label_dirty`.
    git_label_thread: ?*Thread = null,
    /// The multi-lane layout arrangement. `.tab` (single active-lane pane) is
    /// the legacy fullscreen; `.dual` (1:1 driver + focused worker) and `.grid`
    /// (2x2 tile) both show more than one lane. Set from the configured
    /// `tui.split_mode` on opening a parallel lane and cycled by `Ctrl+W`.
    split_mode: config_mod.SplitMode = .tab,
    /// Which worker lane (index >= 1) occupies the right pane in `.dual` and
    /// gets the focus highlight. A separate bit from `app.thread`: `app.thread`
    /// stays the input-routing lane (always the driver in `.dual`), while this
    /// selects the worker shown on the right. Cycled by `Ctrl+L` and set by
    /// `Alt+Left`/`Alt+Right` / mouse click-to-focus.
    focused_worker_index: usize = 1,
    /// The split column geometry computed this frame by `drawRoot`, reused by
    /// mouse click-to-focus routing so the render path and the mouse handler
    /// share one source of truth (`layout.computeSplitLayout`). Populated only
    /// in split modes; `split_rect_count` is 0 otherwise.
    split_rects: [4]tui_layout.ColumnRect = undefined,
    split_rect_count: usize = 0,
    /// Root-relative row where the input surface is drawn this frame; lets the
    /// input widget translate its local chip position into absolute coordinates
    /// for `lanes_chip_rect`.
    input_surface_row: u16 = 0,
    inputs: app_state.InputState,
    /// Cross-pane navigation cursors and the lane-chip hit-test rect.
    nav: app_state.NavState = .{},
    /// Back-pointer to the vxfw App that owns the event loop. Set in `tui.run`
    /// after both `App` and `fw_app` are constructed in their final stack
    /// frames. Lets `installRuntime` (called outside an event handler, with no
    /// EventContext) request a focus reset to the root widget before it deinits
    /// the old runtime — otherwise vxfw's `focused_widget` keeps pointing at a
    /// destroyed TextField and the next key event crashes (empty focus path).
    fw_app: ?*vxfw.App = null,
    /// The root widget vtable, captured so `installRuntime` can pin vxfw focus
    /// to it without holding a RootWidget pointer (the root lives in `tui.run`'s
    /// frame). Set alongside `fw_app`.
    root_widget: ?vxfw.Widget = null,
    /// Parsed state for the `/diff` viewer. Populated by `openDiffViewer`, reset
    /// to `.{}` on exit. Only meaningful while `mode == .diff_viewer`.
    diff: diff_viewer.State = .{},
    /// Lazily-resolved readiness of git-shadow snapshotting: `.unknown` until the
    /// first boundary probes git + that the cwd is a repo, then cached.
    /// `.unavailable` keeps the feature inert when git isn't available.
    checkpoint_state: CheckpointState = .unknown,
    /// True once a snapshot has failed and we've told the user. Stops the
    /// per-turn failure notice from repeating every turn while git is wedged.
    checkpoint_warned: bool = false,
    mode: Mode = .normal,
    resume_summaries: std.ArrayList(session_mod.SessionSummary) = .empty,
    resume_folded_projects: std.ArrayList([]u8) = .empty,
    pickers: app_state.PickerStates,
    codex_signed_in: bool = false,
    /// Provider connectivity, model catalogue, and API key state.
    provider_state: app_state.ProviderState = .{},
    /// Inline edit buffers for text fields across overlays.
    input_buffers: app_state.InputBuffers = .{},
    cached_config: config_mod.Config = .{},
    cached_config_owned: bool = false,
    /// Registry-aware theme catalogue (builtins seeded in `App.init`, custom
    /// JSON themes loaded by `initRuntime`). Owned; freed in `deinitApp`.
    theme_registry: tui_style.ThemeRegistry = .{},
    /// Snapshot of the active theme taken when the /theme picker opens, so
    /// `Esc` can restore the exact pre-open look. Set in `openThemePicker`,
    /// cleared on commit (`applyTheme`) or cancel (`closeThemePicker`).
    theme_preview_original: ?tui_style.Theme = null,
    /// Process environment map — stored once at startup so cross-project
    /// session resume can reload config (`.nova/config.json`) from the
    /// target project's cwd without re-reading the OS environment.
    environ_map: ?*std.process.Environ.Map = null,
    retired_transcripts: std.ArrayList(transcript_mod.Transcript) = .empty,
    /// Visual feedback state (loading spinner, black-hole intro, diff
    /// cache, git label) lives in MetricsState.
    metrics: app_state.MetricsState = .{},
    list_widgets: app_state.ListWidgets = .{},
    /// What the `Mode.lanes` overlay is doing: managing parked worktrees
    /// (`/lanes`, M/X) or choosing a merge destination (`/merge`, Enter).
    parked_lanes: []vcs.WorktreeEntry = &.{},
    /// `.merge_dest`: the source lane (current) whose work is being merged, and
    /// the candidate destination lane indices into `threads`. Owned.
    merge_source_index: usize = 0,
    merge_dest_indices: []usize = &.{},
    input_wrap_width: u16 = 0,
    at_search: app_state.AtSearchState = .closed,
    /// Shared manager for `run_in_background` bash commands. Heap-allocated (so
    /// its address is stable for the agents that borrow it) and owned here; null
    /// on the headless/test path. See `background.zig`.
    background: ?*background_mod.BackgroundManager = null,
    /// `Ctrl+O` background-jobs modal: open flag, selected row, the
    /// `[CANCEL]` button focus hint, and the pending-delivery queue.
    /// Mirrors the permission overlay's lightweight, mode-less state.
    background_modal_state: app_state.BackgroundModalState = .{},
    mcp_manager: mcp_mod.McpManager = undefined,
    plugin_manager: lua_mod.PluginManager = undefined,
    /// The `lane` tool's request/response bridge. Heap-allocated so its
    /// address stays stable while worker threads block on it; owned here,
    /// destroyed in `deinitApp` (after every lane's turn future is cancelled,
    /// which wakes any worker blocked on the bridge). See `tools/lane_bridge.zig`.
    lane_bridge: ?*lane_bridge_mod.LaneBridge = null,
    /// In-flight asynchronous worktree creation job.
    async_worktree_job: ?*lane_lifecycle.WorktreeJob = null,
    /// App-wide cap on concurrent LLM requests to the provider, shared by every
    /// lane's agent (turn, naming, and compaction requests all gate on it).
    /// Heap-allocated so its address stays stable while worker threads block
    /// on it; sized from `config.context.maxConcurrentRequests`; freed in
    /// `deinitApp` (after every lane's turn future is cancelled, which wakes
    /// any worker blocked on the limiter). See `request_limiter.zig`.
    request_limiter: ?*request_limiter_mod.RequestLimiter = null,
    /// Single source of truth for tools: builtin slice + plugin tools
    /// appended at runtime through `registerPluginTools`. Heap-allocated so
    /// its address stays put while agents borrow it; freed in `deinit`.
    tool_registry: *tools_mod.ToolRegistry = undefined,
    /// Completed background jobs awaiting delivery. Held here (not pushed into a
    /// busy transcript) so the notice + model message land only when the owning
    /// lane is idle — "auto-start if idle, queue if in-flight". Owned; freed in
    /// `deinit`.
    pub const ctrl_c_double_press_ms: u32 = 1500;
    pub const Mode = enum { normal, command, session_picker, provider_picker, model_picker, tree_picker, diff_viewer, save_message, lanes, help, settings, mcp, plugins, search, theme_picker };
    pub const LanesPurpose = app_state.NavState.LanesPurpose;
    pub const ModelCatalog = enum { connected_provider, openai_codex };
    pub const ModelScope = model_catalogue.ModelScope;

    pub fn init(io: std.Io, gpa: std.mem.Allocator, agent: *agent_mod.Agent) !App {
        const primary = try gpa.create(Thread);
        errdefer gpa.destroy(primary);
        primary.* = .{ .agent = agent, .worker_context = .{ .io = io, .gpa = agent.gpa } };
        var threads = BoundedList(*Thread, max_threads){};
        try threads.append(primary);
        const registry = try gpa.create(tools_mod.ToolRegistry);
        errdefer gpa.destroy(registry);
        registry.* = tools_mod.ToolRegistry.init(tools_mod.builtinRegistry());
        const bridge = try gpa.create(lane_bridge_mod.LaneBridge);
        errdefer gpa.destroy(bridge);
        // `create` allocates raw bytes — the mutex/condition must be
        // initialized to their `.init` values or the first lock waits forever.
        bridge.* = .{};
        const limiter = try gpa.create(request_limiter_mod.RequestLimiter);
        errdefer gpa.destroy(limiter);
        limiter.* = .{};
        // The primary lane is generation 1; every later lane gets the next
        // counter value at its creation site.
        primary.generation = 1;
        // Seed the theme registry's builtins (gpa only, no io/paths) so
        // `app.theme_registry.slice()` is non-empty for every App — including
        // the headless/test path. Custom themes load later in `initRuntime`.
        var theme_registry = try tui_style.ThemeRegistry.init(gpa);
        errdefer theme_registry.deinit(gpa);
        return .{
            .io = io,
            .gpa = gpa,
            .threads = threads,
            .thread = primary,
            .lane_generation_counter = 1,
            .inputs = .{ .input = .init(gpa), .palette = .init(gpa), .comment = .init(gpa) },
            .pickers = .{ .tree = .init(gpa) },
            .mcp_manager = mcp_mod.McpManager.init(gpa),
            .plugin_manager = lua_mod.PluginManager.init(gpa, io, "", ""),
            .tool_registry = registry,
            .lane_bridge = bridge,
            .request_limiter = limiter,
            .theme_registry = theme_registry,
        };
    }

    pub fn initRuntime(
        io: std.Io,
        gpa: std.mem.Allocator,
        runtime: *runtime_mod.AgentRuntime,
        config: config_mod.Config,
        environ_map: ?*std.process.Environ.Map,
    ) !App {
        var app = try init(io, gpa, &runtime.agent);
        app.cached_config = config;
        app.environ_map = environ_map;
        // Size the shared request limiter from the config knob (default 2 —
        // single lane is unaffected; 2 bounds the multi-lane burst).
        if (app.request_limiter) |limiter| {
            limiter.setPermits(io, config.context.max_concurrent_requests orelse config_mod.default_max_concurrent_requests);
        }
        app.mcp_manager.syncFromConfig(io, &app.cached_config) catch {};
        // The placeholder plugin_manager from `App.init` was built with
        // empty `home_dir`/`cwd` (the runtime values weren't available
        // there). Tear it down so the real one below is the only owner
        // of any Lua state — without this, a second `initRuntime` call
        // (session resume / new session) leaks the previous manager's
        // Lua state and double-frees the underlying allocations on
        // App.deinit.
        app.plugin_manager.deinit();
        app.plugin_manager = lua_mod.PluginManager.init(gpa, io, runtime.home_dir, runtime.cwd);
        // Clone plugin config entries into the manager before loadAll: the
        // manager outlives cached_config swaps (a session switch frees the old
        // Config mid-session), so borrowed slices would dangle.
        app.plugin_manager.syncPluginConfig(app.cached_config.plugins) catch |err| {
            log.warn("plugin_manager.syncPluginConfig failed: {s}", .{@errorName(err)});
        };
        const loaded_plugins = app.plugin_manager.loadAll() catch |err| blk: {
            log.warn("plugin_manager.loadAll failed: {s}", .{@errorName(err)});
            break :blk @as(usize, 0);
        };
        log.debug("plugin_manager loaded {d} plugin(s); home_dir={s} cwd={s}", .{ loaded_plugins, runtime.home_dir, runtime.cwd });
        // Materialize every active plugin's registered tools as `Tool`
        // entries on the app's `ToolRegistry`. From this point on, the
        // tool list is consistent across dispatch, display, and the AI
        // client's serialized schema — without waiting for a
        // `mcp_connect_pending` tick.
        provider_model.registerPluginTools(&app);
        search_mod.start(gpa, io, runtime.cwd);
        // One shared background manager for the whole session. Heap-allocated so
        // its address stays put as agents (primary + lanes) borrow it.
        const manager = try gpa.create(background_mod.BackgroundManager);
        errdefer gpa.destroy(manager);
        manager.* = .init(io, gpa);
        app.background = manager;
        runtime.agent.background_manager = manager;
        // mcp_manager pointer is set by the caller after `app` settles in its
        // final stack frame — setting it here would dangle when `app` is
        // returned by value.
        app.thread.engine = .{ .live = .{ .lane = .primary, .runtime = runtime, .owns = true } };
        app.thread.id = runtime.session_writer.session.id;
        app.codex_signed_in = !runtime.codex_connection_expired and
            (runtime.hasCodexClient() or tui_provider.detectCodexSignIn(gpa, io, runtime.home_dir));
        app.cached_config_owned = true;
        // Load custom themes and re-apply the theme registry-aware (M1). The
        // earlier `setActive(resolveTheme(...))` at tui.zig:~1160 is
        // builtin-only and runs before initRuntime; this second pass resolves
        // custom slugs so a config with `"theme": "<custom>"` is applied at
        // startup instead of silently falling back to `default`.
        try app.theme_registry.loadCustom(gpa, io, runtime.home_dir, runtime.cwd, app.cached_config.tui.custom_themes_dir);
        tui_style.setActive(app.theme_registry.resolve(app.cached_config.theme));
        return app;
    }

    /// The live lane's runtime, or null when no engine is attached (idle/test).
    /// Engine ownership lives in `thread.engine`; this read accessor replaced the
    /// former `App.runtime` field.
    pub fn liveRuntime(self: *const App) ?*runtime_mod.AgentRuntime {
        return switch (self.thread.engine) {
            .live => |live| live.runtime,
            .idle => null,
        };
    }

    /// The runtime whose allocator, home dir, and prompt/skills template seed
    /// new lanes: the first live lane (the primary, in practice). Null only in
    /// headless/test setups.
    pub fn templateRuntime(self: *const App) ?*runtime_mod.AgentRuntime {
        for (self.threads.slice()) |lane| {
            switch (lane.engine) {
                .live => |live| return live.runtime,
                else => {},
            }
        }
        return null;
    }

    pub fn bindInputCallbacks(self: *App) void {
        self.inputs.input.userdata = self;
        self.inputs.input.onChange = event_callbacks.inputChanged;
        self.inputs.palette.userdata = self;
        self.inputs.palette.onChange = event_callbacks.paletteInputChanged;
    }

    // --- Accessors for cross-module access (R1: event_router needs these
    // because Zig 0.16 forbids `pub` on struct fields). Pure read/write
    // forwarding — prefer existing semantic methods when one fits. ----------

    pub fn getIo(self: *const App) std.Io {
        return self.io;
    }

    pub fn inputWidget(self: *App) vxfw.Widget {
        return self.inputs.input.widget();
    }

    pub fn inputRealLength(self: *const App) usize {
        return self.inputs.input.buf.realLength();
    }

    pub fn isNormalMode(self: *const App) bool {
        return self.mode == .normal;
    }

    pub fn isDiffViewerMode(self: *const App) bool {
        return self.mode == .diff_viewer;
    }

    pub fn getMode(self: *const App) Mode {
        return self.mode;
    }

    pub fn getTreeState(self: *App) *tree_selector.TreeState {
        return &self.pickers.tree;
    }

    pub fn getProviderPicker(self: *App) *provider_picker.State {
        return &self.pickers.provider;
    }

    pub fn getProviderKeyInput(self: *App) *std.ArrayList(u8) {
        return &self.input_buffers.provider_key;
    }

    pub fn getModels(self: *App) *model_catalogue.ModelCatalogue {
        return &self.pickers.models;
    }

    pub fn toggleResumeGroupBy(self: *App) void {
        self.nav.resume_group_by = switch (self.nav.resume_group_by) {
            .flat => .project,
            .project => .date,
            .date => .flat,
        };
    }

    pub fn getResumeGroupBy(self: *const App) app_state.NavState.ResumeGroupBy {
        return self.nav.resume_group_by;
    }

    pub fn getResumeSelection(self: *const App) u32 {
        return self.nav.resume_selection;
    }

    pub fn setResumeSelection(self: *App, v: u32) void {
        self.nav.resume_selection = v;
    }

    pub fn getLanesSelection(self: *App) u32 {
        return self.nav.lanes_selection;
    }

    pub fn setLanesSelection(self: *App, v: u32) void {
        self.nav.lanes_selection = v;
    }

    pub fn getLanesPurpose(self: *const App) LanesPurpose {
        return self.nav.lanes_purpose;
    }

    pub fn getCommandSelection(self: *App) u32 {
        return self.nav.command_selection;
    }

    pub fn setCommandSelection(self: *App, v: u32) void {
        self.nav.command_selection = v;
    }

    pub fn popProviderKeyInput(self: *App) void {
        const items = self.input_buffers.provider_key.items;
        if (items.len == 0) return;
        var cut = items.len - 1;
        while (cut > 0 and (items[cut] & 0xC0) == 0x80) cut -= 1;
        self.input_buffers.provider_key.shrinkRetainingCapacity(cut);
    }

    pub fn popMcpUrlInput(self: *App) void {
        const items = self.input_buffers.mcp_url.items;
        if (items.len == 0) return;
        var cut = items.len - 1;
        while (cut > 0 and (items[cut] & 0xC0) == 0x80) cut -= 1;
        self.input_buffers.mcp_url.shrinkRetainingCapacity(cut);
    }

    pub fn popSessionRenameInput(self: *App) void {
        const items = self.input_buffers.session_rename_text.items;
        if (items.len == 0) return;
        var cut = items.len - 1;
        while (cut > 0 and (items[cut] & 0xC0) == 0x80) cut -= 1;
        self.input_buffers.session_rename_text.shrinkRetainingCapacity(cut);
    }

    pub fn isCodexSignedIn(self: *const App) bool {
        return self.codex_signed_in;
    }

    pub fn peekPaletteInput(self: *App) ![]u8 {
        const left = self.inputs.palette.buf.firstHalf();
        const right = self.inputs.palette.buf.secondHalf();
        const out = try self.gpa.alloc(u8, left.len + right.len);
        @memcpy(out[0..left.len], left);
        @memcpy(out[left.len..], right);
        return out;
    }

    /// Arena variant of `peekPaletteInput`: the same concatenated gap-buffer
    /// value, allocated from the caller's arena instead of `gpa`. The overlay
    /// draw path calls this once per frame for a filter that lives only until
    /// the frame ends, so paying a `gpa` alloc + free every frame is pure churn
    /// — the frame arena already bounds the lifetime.
    pub fn peekPaletteInputArena(self: *App, arena: std.mem.Allocator) ![]const u8 {
        const left = self.inputs.palette.buf.firstHalf();
        const right = self.inputs.palette.buf.secondHalf();
        const out = try arena.alloc(u8, left.len + right.len);
        @memcpy(out[0..left.len], left);
        @memcpy(out[left.len..], right);
        return out;
    }

    pub fn getBackgroundModal(self: *const App) bool {
        return self.background_modal_state.modal;
    }

    pub fn setBackgroundModal(self: *App, v: bool) void {
        self.background_modal_state.modal = v;
    }

    pub fn isAtSearchActive(self: *const App) bool {
        return self.at_search != .closed;
    }

    pub fn atSearchHasResults(self: *const App) bool {
        return self.at_search.results().len > 0;
    }

    pub fn getAtSelection(self: *const App) u32 {
        return switch (self.at_search) {
            .open => |o| o.selection,
            else => 0,
        };
    }

    pub fn setAtSelection(self: *App, v: u32) void {
        if (self.at_search == .open) self.at_search.open.selection = v;
    }

    pub fn atResultsLen(self: *const App) usize {
        return self.at_search.results().len;
    }

    pub fn threadsCount(self: *const App) usize {
        return self.threads.len();
    }

    pub fn toggleSelectedTranscriptBlock(self: *App) void {
        self.thread.transcript.toggleSelected();
    }

    pub fn getBlockNav(self: *const App) bool {
        return self.nav.block_nav;
    }

    pub fn setBlockNav(self: *App, v: bool) void {
        self.nav.block_nav = v;
    }

    pub fn getPendingQuitAt(self: *const App) ?std.Io.Timestamp {
        return switch (self.nav.quit) {
            .pending => |ts| ts,
            else => null,
        };
    }

    pub fn setPendingQuitAt(self: *App, v: ?std.Io.Timestamp) void {
        self.nav.quit = if (v) |ts| .{ .pending = ts } else .none;
    }

    pub fn clearPendingQuitAt(self: *App) void {
        if (self.nav.quit == .pending) self.nav.quit = .none;
    }

    pub fn setSplitMode(self: *App, mode: config_mod.SplitMode) void {
        self.split_mode = mode;
    }

    pub fn enterDual(self: *App) void {
        lane_lifecycle.enterDual(self);
    }

    pub fn getLanesChipRect(self: *const App) ?ChipRect {
        return self.nav.lanes_chip_rect;
    }

    pub fn turnStateIsActive(self: *const App) bool {
        return self.thread.turn.state == .active;
    }

    pub fn queuedCount(self: *const App) usize {
        return self.thread.queued.items.len;
    }

    pub fn transcriptHasSelection(self: *const App) bool {
        return self.thread.transcript.selected != null;
    }

    pub fn setThreadAutoScroll(self: *App, v: bool) void {
        self.thread.auto_scroll = v;
    }

    pub fn deinit(self: *App) void {
        lifecycle.deinitApp(self);
    }

    pub fn armGitLabelRefresh(self: *App) void {
        lifecycle.armGitLabelRefresh(self);
    }

    pub fn awaitTurn(self: *App) void {
        if (self.thread.turn_future) |*future| {
            future.await(self.io);
            self.thread.turn_future = null;
        }
    }

    pub fn handleInterrupt(self: *App) !void {
        return turn_lifecycle.handleInterrupt(self);
    }

    pub fn discardAbandonedTurn(self: *App) void {
        turn_lifecycle.discardAbandonedTurn(self);
    }

    pub fn beginSubmit(self: *App) !bool {
        return turn_lifecycle.beginSubmit(self);
    }

    pub fn setLaneTitleIfUnset(self: *App, prompt: []const u8) !void {
        return turn_lifecycle.setLaneTitleIfUnset(self, prompt);
    }

    pub fn formatNoProviderMessage(self: *App) ![]u8 {
        return turn_lifecycle.formatNoProviderMessage(self);
    }

    pub fn resetTurnState(self: *App) void {
        turn_lifecycle.resetTurnState(self);
    }

    pub fn startTurn(self: *App) !void {
        return turn_lifecycle.startTurn(self);
    }

    pub fn restartTurnForQueuedMessages(self: *App) !bool {
        return turn_lifecycle.restartTurnForQueuedMessages(self);
    }

    pub fn laneForAgent(self: *App, agent_ptr: *agent_mod.Agent) ?*Thread {
        for (self.threads.slice()) |lane| {
            if (lane.agent) |a| {
                if (a == agent_ptr) return lane;
            }
        }
        return null;
    }

    pub fn nextLaneGeneration(self: *App) u64 {
        self.lane_generation_counter += 1;
        return self.lane_generation_counter;
    }

    /// The open lane whose `generation` matches `g`, or null. Used to route a
    /// spawned worker's completion to its spawner across session switches.
    pub fn laneByGeneration(self: *App, g: u64) ?*Thread {
        for (self.threads.slice()) |lane| {
            if (lane.generation == g) return lane;
        }
        return null;
    }

    pub fn freeDelivery(self: *App, delivery: *BackgroundDelivery) void {
        return background_delivery.freeDelivery(self, delivery);
    }

    pub fn backgroundActive(self: *App) bool {
        return background_delivery.backgroundActive(self);
    }

    pub fn pollBackgroundJobs(self: *App) !bool {
        return background_delivery.pollBackgroundJobs(self);
    }

    pub fn formatBackgroundNotice(self: *App, job: *const background_mod.BackgroundManager.Finished) ![]u8 {
        return background_delivery.formatBackgroundNotice(self, job);
    }

    pub fn deliverPendingBackground(self: *App) !bool {
        return background_delivery.deliverPendingBackground(self);
    }

    pub fn startDeliveryTurnOnCurrentThread(self: *App) !void {
        return turn_lifecycle.startDeliveryTurnOnCurrentThread(self);
    }

    pub fn runningBackgroundCount(self: *App) usize {
        return background_delivery.runningBackgroundCount(self);
    }

    pub fn toggleBackgroundModal(self: *App) void {
        background_delivery.toggleBackgroundModal(self);
    }

    pub fn handleBackgroundModalKey(self: *App, key: vaxis.Key) bool {
        return background_delivery.handleBackgroundModalKey(self, key);
    }

    pub fn cancelSelectedBackgroundJob(self: *App) void {
        background_delivery.cancelSelectedBackgroundJob(self);
    }

    pub fn advanceLoadingFrame(self: *App) void {
        std.debug.assert(tui_message.loading_frames.len > 0);
        self.metrics.loading_frame +%= 1;
        if (self.metrics.loading_frame >= tui_message.loading_frames.len) self.metrics.loading_frame = 0;
    }

    pub fn advanceBlackholeFrame(self: *App) void {
        self.metrics.blackhole_frame += 1;
        if (self.metrics.blackhole_frame >= blackhole.frame_count) self.metrics.blackhole_frame = 0;
    }

    pub fn permissionPending(self: *App) bool {
        return permission_mod.permissionPending(self);
    }

    pub fn handlePermissionKey(self: *App, key: vaxis.Key) !bool {
        return permission_mod.handlePermissionKey(self, key);
    }

    pub fn resolvePermission(self: *App, decision: agent_worker.ApprovalDecision) !void {
        return permission_mod.resolvePermission(self, decision);
    }

    pub fn applyAgentEvent(self: *App, event: agent_mod.Agent.Event) !bool {
        return turn_lifecycle.applyAgentEvent(self, event);
    }

    pub fn sealCheckpoint(self: *App) checkpoint_mod.SealOutcome {
        return checkpoint_mod.sealCheckpoint(self);
    }

    pub fn noteCheckpointFailure(self: *App) void {
        checkpoint_mod.noteCheckpointFailure(self);
    }

    pub fn noteCheckpointSucceeded(self: *App) void {
        checkpoint_mod.noteCheckpointSucceeded(self);
    }

    pub fn checkpointBoundary(self: *App) void {
        checkpoint_mod.checkpointBoundary(self);
    }

    pub fn checkpointFinishedTurn(self: *App) void {
        checkpoint_mod.checkpointFinishedTurn(self);
    }

    pub fn beginSave(self: *App) !void {
        return checkpoint_mod.beginSave(self);
    }

    pub fn saveActiveLane(self: *App, message: []const u8) !void {
        return checkpoint_mod.saveActiveLane(self, message);
    }

    pub fn ensureCheckpointReady(self: *App) bool {
        return checkpoint_mod.ensureCheckpointReady(self);
    }

    pub fn handleCommandKey(self: *App, key: vaxis.Key) !bool {
        return command_router.handleCommandKey(self, key);
    }

    pub fn handleModelPickerKey(self: *App, key: vaxis.Key) !bool {
        return command_router.ModelPicker.handle(self, key);
    }

    pub fn handleSessionPickerKey(self: *App, key: vaxis.Key) !bool {
        return command_router.SessionPicker.handle(self, key);
    }

    pub fn handleCommandMenuKey(self: *App, key: vaxis.Key) !bool {
        return command_router.CommandMenu.handle(self, key);
    }

    pub fn handleTranscriptKey(self: *App, key: vaxis.Key) !bool {
        return command_router.Transcript.handle(self, key);
    }

    pub fn syncModeWithInput(self: *App, value: []const u8) !void {
        return mode_lifecycle.syncModeWithInput(self, value);
    }

    pub fn cancelMode(self: *App) !bool {
        return mode_lifecycle.cancelMode(self);
    }

    pub fn submitMode(self: *App) !bool {
        return mode_lifecycle.submitMode(self);
    }

    pub fn openCommandMenu(self: *App) !void {
        return mode_lifecycle.openCommandMenu(self);
    }

    // --- Transcript search (Ctrl+F / /search) -------------------------------

    pub fn openSearch(self: *App) !void {
        return search_lifecycle.openSearch(self);
    }

    pub fn acceptSearchSelection(self: *App) !void {
        return search_lifecycle.acceptSearchSelection(self);
    }

    pub fn openResumePicker(self: *App) !void {
        return session_switcher.openResumePicker(self);
    }

    pub fn reloadResumeSessions(self: *App) !void {
        return session_switcher.reloadResumeSessions(self);
    }

    pub fn selectedResumeSummary(self: *App) !?*session_mod.SessionSummary {
        return session_switcher.selectedResumeSummary(self);
    }

    pub fn visibleResumeCount(self: *App) !u32 {
        return session_switcher.visibleResumeCount(self);
    }

    pub fn toggleSelectedResumeProject(self: *App) !void {
        return session_switcher.toggleSelectedResumeProject(self);
    }

    pub fn resumeClearFolds(self: *App) void {
        session_switcher.resumeClearFolds(self);
    }

    pub fn resumeClear(self: *App) void {
        session_switcher.resumeClear(self);
    }

    pub fn syncResumeListCursor(self: *App) void {
        session_switcher.syncResumeListCursor(self);
    }

    pub fn reloadTreeNodes(self: *App) !void {
        return session_switcher.reloadTreeNodes(self);
    }

    pub fn navigateToEntry(self: *App, entry_id: []const u8) !void {
        return session_switcher.navigateToEntry(self, entry_id);
    }

    pub fn undoLastTurn(self: *App) !void {
        return session_switcher.undoLastTurn(self);
    }

    pub fn reportSessionSwitchError(self: *App, err: anyerror) !void {
        return session_switcher.reportSessionSwitchError(self, err);
    }

    pub fn beginRenameSelectedSession(self: *App) !void {
        return session_switcher.beginRenameSelectedSession(self);
    }

    pub fn confirmRenameSelectedSession(self: *App) !void {
        return session_switcher.confirmRenameSelectedSession(self);
    }

    pub fn beginDeleteSelectedSession(self: *App) !void {
        return session_switcher.beginDeleteSelectedSession(self);
    }

    pub fn confirmDeleteSelectedSession(self: *App) !void {
        return session_switcher.confirmDeleteSelectedSession(self);
    }

    pub fn cancelSessionAction(self: *App) void {
        session_switcher.cancelSessionAction(self);
    }

    pub fn reportConnectionError(self: *App, err: anyerror) !void {
        self.mode = .normal;
        self.clearInput();
        var buffer: [128]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "Could not connect to provider: {s}", .{@errorName(err)}) catch "Could not connect to provider.";
        _ = try self.thread.transcript.append(self.gpa, .agent, "agent", message);
    }

    pub fn switchToNewSession(self: *App) !void {
        return session_switcher.switchToNewSession(self);
    }

    pub fn switchToSession(self: *App, session_id: []const u8, cwd: []const u8) !void {
        return session_switcher.switchToSession(self, session_id, cwd);
    }

    pub fn createRuntime(self: *App, cwd: []const u8, session_dir: []const u8, session_id: ?[]const u8) !*runtime_mod.AgentRuntime {
        return session_switcher.createRuntime(self, cwd, session_dir, session_id);
    }

    pub fn clearInput(self: *App) void {
        input_lifecycle.clearInput(self);
    }

    pub fn clearPaletteInput(self: *App) void {
        input_lifecycle.clearPaletteInput(self);
    }

    pub fn peekCommentInput(self: *App) ![]u8 {
        return input_lifecycle.peekCommentInput(self);
    }

    // --- At-search (mention popup) ---------------------------------------

    pub fn updateAtSearch(self: *App) !void {
        return at_search_mod.updateAtSearch(self);
    }

    pub fn acceptAtSelection(self: *App) !void {
        return at_search_mod.acceptAtSelection(self);
    }

    pub fn closeAtSearch(self: *App) void {
        at_search_mod.closeAtSearch(self);
    }

    /// Repo root = the primary lane's working directory (it was launched there).
    /// Null only if the primary somehow has no runtime (headless/test).
    pub fn repoRoot(self: *const App) ?[]const u8 {
        return switch (self.threads.at(0).engine) {
            .live => |live| live.runtime.cwd,
            .idle => null,
        };
    }

    // --- Queue management ------------------------------------------------

    pub fn enqueueSubmit(self: *App) !bool {
        return queue_mod.enqueueSubmit(self);
    }

    pub fn selectPrevQueued(self: *App) void {
        queue_mod.selectPrevQueued(self);
    }

    pub fn selectNextQueued(self: *App) void {
        queue_mod.selectNextQueued(self);
    }

    pub fn steerSelectedQueued(self: *App) void {
        queue_mod.steerSelectedQueued(self);
    }

    pub fn flushQueuedUserMessagesToTranscript(self: *App, count: u32) !void {
        return queue_mod.flushQueuedUserMessagesToTranscript(self, count);
    }

    pub fn appendSkillInvocationsToTranscript(self: *App, prompt: []const u8) !void {
        return queue_mod.appendSkillInvocationsToTranscript(self, prompt);
    }

    pub fn clearQueuedUserMessages(self: *App) void {
        queue_mod.clearQueuedUserMessages(self);
    }

    pub fn createParallelLane(self: *App) !void {
        try lifecycle.createParallelLane(self);
    }

    pub fn captureLaneContext(self: *App, max: usize) ![][]u8 {
        return lane_lifecycle.captureLaneContext(self, max);
    }

    pub fn scheduleLaneNaming(self: *App, lane: *Thread, first_message: []const u8) !void {
        return lane_lifecycle.scheduleLaneNaming(self, lane, first_message);
    }

    pub fn drainLaneNaming(self: *App) !bool {
        return lane_lifecycle.drainLaneNaming(self);
    }

    pub fn cancelLaneNaming(self: *App, lane: *Thread) void {
        lane_lifecycle.cancelLaneNaming(self, lane);
    }

    pub fn namingActive(self: *const App) bool {
        return lane_lifecycle.namingActive(self);
    }

    pub fn reportLaneError(self: *App, err: anyerror) !void {
        return lane_lifecycle.reportLaneError(self, err);
    }

    pub fn anyTurnActive(self: *const App) bool {
        return lane_lifecycle.anyTurnActive(self);
    }

    pub fn activeIndex(self: *const App) u32 {
        return lane_lifecycle.activeIndex(self);
    }

    pub fn cycleLane(self: *App, delta: i32) void {
        lane_lifecycle.cycleLane(self, delta);
    }

    pub fn switchToNextLane(self: *App) void {
        lane_lifecycle.switchToNextLane(self);
    }

    pub fn cycleSplitMode(self: *App) void {
        lane_lifecycle.cycleSplitMode(self);
    }

    pub fn cycleFocusedWorker(self: *App) void {
        lane_lifecycle.cycleFocusedWorker(self);
    }

    pub fn shiftFocusedWorker(self: *App, delta: i32) void {
        lane_lifecycle.shiftFocusedWorker(self, delta);
    }

    pub fn closeActiveLane(self: *App) !void {
        return lane_lifecycle.closeActiveLane(self);
    }

    pub fn createMergePicker(self: *App) !void {
        return lane_lifecycle.createMergePicker(self);
    }

    pub fn confirmMergeDest(self: *App) !void {
        return lane_lifecycle.confirmMergeDest(self);
    }

    pub fn openLanesPicker(self: *App) !void {
        return lane_lifecycle.openLanesPicker(self);
    }

    pub fn mergeSelectedParked(self: *App) !void {
        return lane_lifecycle.mergeSelectedParked(self);
    }

    pub fn deleteSelectedParked(self: *App) !void {
        return lane_lifecycle.deleteSelectedParked(self);
    }

    pub fn laneEntryCount(self: *const App) u32 {
        return lane_lifecycle.laneEntryCount(self);
    }

    pub fn clearLanesState(self: *App) void {
        lane_lifecycle.clearLanesState(self);
    }

    pub fn buildLaneEntries(self: *App, arena: std.mem.Allocator) ![]lanes_picker.Entry {
        return lane_lifecycle.buildLaneEntries(self, arena);
    }

    pub fn handleLanesKey(self: *App, key: vaxis.Key) !bool {
        return lane_lifecycle.handleLanesKey(self, key);
    }

    pub fn installRuntime(self: *App, runtime: *runtime_mod.AgentRuntime) !void {
        return transcript_lifecycle.installRuntime(self, runtime);
    }

    pub fn clearConversation(self: *App) !void {
        return transcript_lifecycle.clearConversation(self);
    }

    pub fn rebuildTranscriptFromAgent(self: *App) !void {
        return transcript_lifecycle.rebuildTranscriptFromAgent(self);
    }

    pub fn resumedToolTitle(self: *App, message: ai.ChatMessage) ![]u8 {
        return transcript_lifecycle.resumedToolTitle(self, message);
    }

    pub fn peekInput(self: *App) ![]u8 {
        return input_lifecycle.peekInput(self);
    }

    pub fn inputTextRows(self: *App, ctx: vxfw.DrawContext, width: u16) !u16 {
        return input_lifecycle.inputTextRows(self, ctx, width);
    }

    pub fn insertInputNewline(self: *App) !void {
        return input_lifecycle.insertInputNewline(self);
    }

    pub fn moveInputCursorVertical(self: *App, move: input_mod.VerticalMove) !bool {
        return input_lifecycle.moveInputCursorVertical(self, move);
    }

    pub const HistoryDirection = Thread.HistoryDirection;

    pub fn navigatePromptHistory(self: *App, direction: HistoryDirection) !bool {
        return input_lifecycle.navigatePromptHistory(self, direction);
    }

    pub fn selectionIsLastMessage(self: *const App) bool {
        return transcript_nav.selectionIsLastMessage(self);
    }

    pub fn diffCountsVisible(self: *const App) bool {
        return diff_lifecycle.diffCountsVisible(self);
    }

    pub fn refreshDiffCounts(self: *App) !bool {
        return diff_lifecycle.refreshDiffCounts(self);
    }

    pub fn scheduleDiffRefresh(self: *App) !void {
        return diff_lifecycle.scheduleDiffRefresh(self);
    }

    pub fn cancelDiffRefresh(self: *App) void {
        diff_lifecycle.cancelDiffRefresh(self);
    }

    pub fn drainDiffRefresh(self: *App) !bool {
        return diff_lifecycle.drainDiffRefresh(self);
    }

    pub fn jumpTranscriptToBottom(self: *App) void {
        transcript_nav.jumpTranscriptToBottom(self);
    }

    pub fn updateMouseAutoScroll(self: *App) void {
        transcript_nav.updateMouseAutoScroll(self);
    }

    pub fn navigateTranscript(self: *App, direction: transcript_nav.TranscriptNavigation) bool {
        return transcript_nav.navigateTranscript(self, direction);
    }

    pub fn selectedMessageIsLong(self: *const App) bool {
        return transcript_nav.selectedMessageIsLong(self);
    }

    pub fn selectedMessageCanScrollDown(self: *const App) bool {
        return transcript_nav.selectedMessageCanScrollDown(self);
    }
};

pub fn nextIndex(current: u32, count: u32) u32 {
    if (count == 0) return 0;
    if (current + 1 >= count) return 0;
    return current + 1;
}

pub fn previousIndex(current: u32, count: u32) u32 {
    if (count == 0) return 0;
    if (current == 0) return count - 1;
    return current - 1;
}

pub fn run(
    init: std.process.Init,
    runtime: *runtime_mod.AgentRuntime,
    config: config_mod.Config,
    gpa: std.mem.Allocator,
) !void {
    // Allocator is provided by root.zig as `PageAllocator`. Thread-safe and
    // correct, but each allocation maps a whole page — traded off to avoid
    // `SmpAllocator`'s multi-threaded free-list corruption panic in Zig 0.16.
    // Must match `tui_gpa` in root.zig since `runtime`/`cached_config` cross
    // the seam and are freed in `App.deinit`.
    var tty_buffer: [8192]u8 = undefined;
    var fw_app = try vxfw.App.init(init.io, gpa, init.environ_map, &tty_buffer);
    defer fw_app.deinit();

    // Init the global toast bus (needs an io handle for its mutex) and apply
    // the config's toast settings.
    toast.global.init(init.io);
    if (config.toast.enabled) |enabled| toast.global.enabled = enabled;
    if (config.toast.duration_ms) |ms| toast.global.duration_ms = ms;
    if (config.toast.max_visible) |n| toast.global.max_visible = n;

    // Install the active color theme before the first frame is drawn.
    tui_style.setActive(tui_style.resolveTheme(config.theme));

    var app = try App.initRuntime(init.io, gpa, runtime, config, init.environ_map);
    // Set the manager pointers now that `app` is in its final stack frame.
    // Inside initRuntime, &app.X would dangle after return-by-value.
    runtime.agent.mcp_manager = &app.mcp_manager;
    runtime.agent.tool_registry = app.tool_registry;
    runtime.agent.plugin_manager = &app.plugin_manager;
    runtime.agent.lane_bridge = app.lane_bridge;
    runtime.agent.request_limiter = app.request_limiter;
    app.bindInputCallbacks();
    defer app.deinit();

    // Load stored catalogue-provider keys from auth.json up front so the first
    // model-catalogue build includes every connected provider. Without this the
    // keys only loaded when the provider picker was opened, so a cold model
    // picker silently skipped (and then cached) every keyed provider.
    provider_model.refreshProviderApiKeys(&app) catch {};

    // Rebuild transcript from agent when resuming a session (the agent was
    // rehydrated with messages in runtime.zig initSession). For a new session
    // the rebuild is a no-op — agent only has system messages, which are
    // skipped — so we fall through to the logo.
    try app.rebuildTranscriptFromAgent();
    if (app.thread.transcript.messages.items.len == 0) {
        // The logo message is a marker: the black-hole animation renders its
        // frames directly (see tui/blackhole.zig), so the body is intentionally
        // empty.
        _ = try app.thread.transcript.append(gpa, .logo, "logo", "");
    }

    app.metrics.git_label = diff_utils.loadGitLabel(gpa, init.io, runtime.cwd) catch "";
    _ = app.refreshDiffCounts() catch false;

    var root: RootWidget = .{ .app = &app };
    root.mcp_connect_pending = true;
    // Expose the framework handle + root widget to `installRuntime` so a
    // session switch/resume can reset focus to the root before the old
    // runtime (and its TextField userdata) is destroyed.
    app.fw_app = &fw_app;
    app.root_widget = root.widget();
    try fw_app.run(root.widget(), .{});
}

pub const RootWidget = struct {
    app: *App,
    spinner_tick_accum: u32 = 0,
    blackhole_tick_accum: u32 = 0,
    diff_tick_accum: u32 = 0,
    diff_refresh_pending: bool = false,
    mcp_connect_pending: bool = false,

    pub fn widget(self: *RootWidget) vxfw.Widget {
        return .{
            .userdata = self,
            .captureHandler = captureEvent,
            .eventHandler = handleEvent,
            .drawFn = drawRoot,
        };
    }

    pub fn captureEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *RootWidget = @ptrCast(@alignCast(ptr));
        try event_router.captureEvent(self.app, self, ctx, event);
    }

    fn handleEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *RootWidget = @ptrCast(@alignCast(ptr));
        switch (event) {
            .tick => try lifecycle.handleTick(self, ctx),
            else => {},
        }
    }

    pub const drain_tick_ms: u32 = 30;
    pub const spinner_tick_threshold_ms: u32 = loading_frame_ms;
    pub const diff_tick_threshold_ms: u32 = 300;

    fn handleTick(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        try lifecycle.handleTick(self, ctx);
    }

    pub fn ensureTick(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        try lifecycle.ensureTick(self, ctx);
    }

    pub fn submit(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        try lifecycle.submit(self, ctx);
    }

    pub fn syncFocus(self: *RootWidget, ctx: *vxfw.EventContext) !void {
        try lifecycle.syncFocus(self, ctx);
    }

    fn drainAgentEvents(self: *RootWidget, ctx: *vxfw.EventContext) !bool {
        return lifecycle.drainAgentEvents(self, ctx);
    }

    fn drawRoot(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *RootWidget = @ptrCast(@alignCast(ptr));
        return root_layout_widget.drawRoot(self.app, self.widget(), ctx);
    }

    /// Draw one lane's transcript as a bordered column for split view. The
    /// border label marks the lane (● active / ○ background) and the active
    /// column's border is undimmed.
    // --- Diff viewer ------------------------------------------------------

    pub fn handleDiffViewerEvent(self: *RootWidget, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        try lifecycle.handleDiffViewerEvent(self, ctx, key);
    }

    fn handleDiffBrowseKey(self: *RootWidget, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        try lifecycle.handleDiffBrowseKey(self, ctx, key);
    }

    fn handleDiffSearchKey(self: *RootWidget, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        try lifecycle.handleDiffSearchKey(self, ctx, key);
    }

    fn handleDiffCommentKey(self: *RootWidget, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        try lifecycle.handleDiffCommentKey(self, ctx, key);
    }

    fn closeDiff(self: *RootWidget, ctx: *vxfw.EventContext, send: bool) !void {
        try lifecycle.closeDiff(self, ctx, send);
    }
};

pub fn shouldOpenCommandMenuForSlash(app: *const App, key: vaxis.Key) bool {
    return mode_lifecycle.shouldOpenCommandMenuForSlash(app, key);
}

pub const Command = enum { connect, model, mcp, new, resume_session, timeline, undo, diff, parallel, save, close, merge, lanes, search, clear, compact, status, help, export_session, settings, copy, paste, exit_cmd, plugins, skills, theme };
/// `multi_lane` commands act on another lane, so they're hidden from the palette
/// (and unresolvable) until more than one lane exists.
pub const CommandEntry = struct { name: []const u8, command: Command, description: []const u8 = "", category: []const u8 = "", multi_lane: bool = false };
pub const commands = [_]CommandEntry{
    .{ .name = "Connect", .command = .connect, .description = "Configure AI provider & API key", .category = "AI & MODELS" },
    .{ .name = "Models", .command = .model, .description = "Select model & reasoning effort", .category = "AI & MODELS" },
    .{ .name = "Mcp", .command = .mcp, .description = "Model Context Protocol status & servers", .category = "AI & MODELS" },
    .{ .name = "Plugins", .command = .plugins, .description = "List & manage Lua plugins", .category = "AI & MODELS" },
    .{ .name = "Settings", .command = .settings, .description = "View and edit configuration settings", .category = "AI & MODELS" },
    .{ .name = "Skills", .command = .skills, .description = "List loaded skills & invocation names", .category = "AI & MODELS" },
    .{ .name = "New", .command = .new, .description = "Start a fresh session", .category = "SESSION" },
    .{ .name = "Resume", .command = .resume_session, .description = "Resume a past session", .category = "SESSION" },
    .{ .name = "Timeline", .command = .timeline, .description = "Browse session tree history", .category = "SESSION" },
    .{ .name = "Undo", .command = .undo, .description = "Rewind the last turn and restore its prompt", .category = "SESSION" },
    .{ .name = "Clear", .command = .clear, .description = "Clear current transcript view", .category = "SESSION" },
    .{ .name = "Compact", .command = .compact, .description = "Compact session context history", .category = "SESSION" },
    .{ .name = "Export", .command = .export_session, .description = "Save conversation transcript as Markdown", .category = "SESSION" },
    .{ .name = "Copy", .command = .copy, .description = "Copy selected transcript message to clipboard", .category = "SESSION" },
    .{ .name = "Paste", .command = .paste, .description = "Paste text from clipboard into prompt", .category = "SESSION" },
    .{ .name = "Search", .command = .search, .description = "Search the current transcript (Ctrl+F)", .category = "SESSION" },
    .{ .name = "Diff", .command = .diff, .description = "View git diff & add comments", .category = "GIT & WORKTREE" },
    .{ .name = "Parallel", .command = .parallel, .description = "Fork worktree into parallel lane", .category = "GIT & WORKTREE" },
    .{ .name = "Save", .command = .save, .description = "Save working copy snapshot", .category = "GIT & WORKTREE" },
    .{ .name = "Merge", .command = .merge, .description = "Merge lane into target", .category = "GIT & WORKTREE", .multi_lane = true },
    .{ .name = "Close", .command = .close, .description = "Park and close active lane", .category = "GIT & WORKTREE", .multi_lane = true },
    .{ .name = "Lanes", .command = .lanes, .description = "Manage parked worktree lanes", .category = "GIT & WORKTREE" },
    .{ .name = "Theme", .command = .theme, .description = "Switch color theme (highlight current)", .category = "SYSTEM" },
    .{ .name = "Status", .command = .status, .description = "Show agent runtime & git state", .category = "SYSTEM" },
    .{ .name = "Help", .command = .help, .description = "Show keyboard shortcuts & guide", .category = "SYSTEM" },
    .{ .name = "Exit", .command = .exit_cmd, .description = "Quit Nova agent", .category = "SYSTEM" },
    .{ .name = "Quit", .command = .exit_cmd, .description = "Quit Nova agent", .category = "SYSTEM" },
};

pub fn openMcp(app: *App) void {
    app.mode = .mcp;
    app.pickers.mcp.reset();
    if (app.liveRuntime() != null) {
        // Sync servers and push the resulting tool schemas into the live client.
        provider_model.refreshMcpTools(app);
    } else {
        app.mcp_manager.syncFromConfig(app.io, &app.cached_config) catch {};
    }
    app.clearInput();
    app.clearPaletteInput();
}

pub fn closeMcp(app: *App) void {
    app.mode = .normal;
    app.clearInput();
    app.clearPaletteInput();
}

pub fn openPlugins(app: *App) void {
    app.mode = .plugins;
    app.pickers.plugins.reset();
    if (app.liveRuntime() != null) {
        // Push the current tool set into the live AI client. Deliberately NO
        // `registerPluginTools` here: the loaded-plugin set is now known to
        // change only at initRuntime and at a guarded cross-project resume
        // (createRuntime with the anyLaneTurnActive guard). This site has no
        // such guard, and createRuntime already owns the refresh, so calling
        // registerPluginTools here would be both unnecessary and unsafe — its
        // strip-and-rebuild frees tool records that worker threads may be
        // dispatching through the shared registry right now (use-after-free).
        // Registration is an initRuntime-time and guarded-resume-time operation.
        provider_model.refreshMcpTools(app);
    }
    app.clearInput();
    app.clearPaletteInput();
}

pub fn closePlugins(app: *App) void {
    app.mode = .normal;
    app.clearInput();
    app.clearPaletteInput();
}

/// Whether `entry` should appear in the palette given the current lane count.
pub fn commandVisible(app: *const App, entry: CommandEntry) bool {
    if (entry.multi_lane and app.threads.len() < 2) return false;
    return true;
}

pub fn resolveCommand(app: *App, filter: []const u8) ?Command {
    return mode_lifecycle.resolveCommand(app, filter);
}

pub fn commandMatchesCount(app: *App) u32 {
    return mode_lifecycle.commandMatchesCount(app);
}

pub fn commandMatchesCountForFilter(app: *const App, filter: []const u8) u32 {
    return mode_lifecycle.commandMatchesCountForFilter(app, filter);
}

/// Builds the floating `@`-results panel from app state. Presentational only;
/// the main input keeps focus.
pub const AtSearchWidget = struct {
    app: *App,

    pub fn widget(self: *AtSearchWidget) vxfw.Widget {
        return .{ .userdata = self, .drawFn = drawAtSearch };
    }

    fn drawAtSearch(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *AtSearchWidget = @ptrCast(@alignCast(ptr));
        const kind = self.app.at_search.kind();
        const indexing = self.app.at_search == .indexing;
        const sel = self.app.getAtSelection();
        const query: []const u8 = switch (self.app.at_search) {
            .open => |o| o.query,
            else => "",
        };
        var content: at_search.Content = .{
            .results = self.app.at_search.results(),
            .selection = sel,
            .query = query,
            .indexing = indexing,
            .sigil = if (kind == .file) '@' else '$',
            .title = if (kind == .file) "Files" else "Skills",
        };
        return content.widget().draw(ctx);
    }
};

const reasoning_options = [_]model_picker.ReasoningOption{
    .{ .label = "default", .effort = .default },
    .{ .label = "medium", .effort = .medium },
    .{ .label = "high", .effort = .high },
    .{ .label = "xhigh", .effort = .xhigh },
    .{ .label = "max", .effort = .max },
    .{ .label = "low", .effort = .low },
    .{ .label = "nothink", .effort = .none },
};

pub fn reasoningOptions() []const model_picker.ReasoningOption {
    return &reasoning_options;
}

/// Rebuild the per-model reasoning options cache from the active model's
/// config entry. Call when the model picker opens or the active model
/// changes. Empty cache → fall back to the global hardcoded list.
pub fn rebuildReasoningOptsCache(self: *App) void {
    self.provider_state.reasoning_opts_len = 0;
    if (!self.cached_config_owned) return;
    const ms = self.cached_config.model_selection orelse return;
    for (ms.model().reasoning_options) |effort| {
        if (self.provider_state.reasoning_opts_len >= self.provider_state.reasoning_opts_cache.len) break;
        self.provider_state.reasoning_opts_cache[self.provider_state.reasoning_opts_len] = .{
            .label = effort.label(),
            .effort = effort,
        };
        self.provider_state.reasoning_opts_len += 1;
    }
    std.debug.assert(self.provider_state.reasoning_opts_len == ms.model().reasoning_options.len);
}

/// Effective reasoning options: per-model config list if non-empty,
/// otherwise the global hardcoded list.
pub fn activeReasoningOptions(self: *const App) []const model_picker.ReasoningOption {
    if (self.provider_state.reasoning_opts_len > 0) return self.provider_state.reasoning_opts_cache[0..self.provider_state.reasoning_opts_len];
    return &reasoning_options;
}

// --- Settings delegates (settings_lifecycle forwarding) -------------------

pub fn openSettings(app: *App) void {
    settings_lifecycle.openSettings(app);
}

pub fn closeSettings(app: *App) void {
    settings_lifecycle.closeSettings(app);
}

pub fn saveSettings(app: *App) !bool {
    return settings_lifecycle.saveSettings(app);
}

pub fn cancelSettings(app: *App) void {
    settings_lifecycle.cancelSettings(app);
}

pub fn submitSettings(app: *App) !void {
    try settings_lifecycle.submitSettings(app);
}

pub fn clearSettingsField(app: *App) void {
    settings_lifecycle.clearCurrentField(app);
}

pub fn handleSettingsTextEditKey(app: *App, key: vaxis.Key) !bool {
    return settings_lifecycle.handleTextEditKey(app, key);
}

// --- Theme delegates (theme_lifecycle forwarding) --------------------------

pub fn openThemePicker(app: *App) void {
    theme_lifecycle.openThemePicker(app);
}

pub fn closeThemePicker(app: *App) void {
    theme_lifecycle.closeThemePicker(app);
}

pub fn applyTheme(app: *App, raw_name: []const u8) !void {
    try theme_lifecycle.applyTheme(app, raw_name);
}

pub fn reportThemeError(app: *App, err: anyerror) !void {
    try theme_lifecycle.reportThemeError(app, err);
}
