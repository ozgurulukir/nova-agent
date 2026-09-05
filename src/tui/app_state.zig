//! Grouped `App` state sub-structs.
//!
//! Pulled out of `tui.zig` (R3 of `_pm/Projects/tui-split`) — the central
//! `App` struct grew to 70+ fields and the per-concern state kept bleeding
//! into each other. R3 splits the state into focused sub-structs, each
//! owning one concern. R1/R2 already routed cross-module access through
//! `pub` accessors, so this refactor is internal to `tui.zig` — every
//! call site of `self.<field>` inside `tui.zig` becomes
//! `self.<sub>.<field>`.
//!
//! Behavioural identity is preserved: every field keeps its default and
//! every operation mutates the same memory, just one struct level deeper.

const std = @import("std");
const vaxis = @import("vaxis");
const tui = @import("../tui.zig");
const agent_mod = @import("../agent.zig");
const auth = @import("../auth/store.zig");
const modelsdev = @import("../models/registry.zig");
const model_picker = @import("widgets/model_picker.zig");
const tree_selector = @import("widgets/tree_selector.zig");
const model_catalogue = @import("model_catalogue.zig");
const provider_picker = @import("widgets/provider_picker.zig");
const settings_widget = @import("widgets/settings.zig");
const help_picker = @import("widgets/help_picker.zig");
const theme_picker = @import("widgets/theme_picker.zig");
const mcp_status = @import("widgets/mcp_status.zig");
const plugins_status = @import("widgets/plugins_status.zig");
const search_widget = @import("widgets/search.zig");
const vxfw = vaxis.vxfw;
const telemetry_mod = @import("telemetry.zig");

const MentionSearchKind = tui.MentionSearchKind;

/// State for the @-mention search popup. The logical state is a 3-arm
/// union: closed (no popup), indexing (a background scan is in flight),
/// open (a query is active with a result list). The previous flat
/// struct (active/indexing flags + always-on results/kind/query/
/// selection) allowed illegal combinations like `active = false` with
/// non-empty `results`, or `indexing = true` with no query set. The
/// new shape makes those unrepresentable.
///
/// `closed` is a tag-only variant. `indexing` carries kind + results
/// (the scan populates results as it finds matches). `open` carries
/// kind + query + results + selection. Callers switch on the variant
/// to access the payload; there's no flat-field fallback.
pub const AtSearchState = union(enum) {
    closed,
    indexing: IndexingPayload,
    open: OpenPayload,

    pub const IndexingPayload = struct {
        kind: MentionSearchKind,
        results: std.ArrayList([]const u8) = .empty,
    };

    pub const OpenPayload = struct {
        kind: MentionSearchKind,
        query: []const u8 = "",
        results: std.ArrayList([]const u8) = .empty,
        selection: u32 = 0,
        /// True when an async fuzzy search for the current `query` is still
        /// in progress. The UI may keep showing stale results until it
        /// completes.
        searching: bool = false,
        /// Optional inline error / status notice shown below the result list.
        /// Owned by the state; freed on `close`.
        notice: ?[]u8 = null,
        /// Debounce deadline for the next async search. The render loop
        /// waits until `now >= deadline` before starting/polling a search.
        debounce_deadline: ?std.Io.Timestamp = null,
    };

    /// Convenience: the kind of mention being searched, regardless of
    /// which variant is active. Returns `.file` for `closed` (the
    /// default the UI uses when no popup is open).
    pub fn kind(self: AtSearchState) MentionSearchKind {
        return switch (self) {
            .closed => .file,
            .indexing => |i| i.kind,
            .open => |o| o.kind,
        };
    }

    /// Convenience: the active result list, or an empty slice when
    /// closed. Returned slice is owned by the state.
    pub fn results(self: *const AtSearchState) []const []const u8 {
        return switch (self.*) {
            .closed => &.{},
            .indexing => |*i| i.results.items,
            .open => |*o| o.results.items,
        };
    }

    /// Convenience: the mutable result list pointer, or null when
    /// closed. Used by at_search.zig to populate the list.
    pub fn resultsPtr(self: *AtSearchState) ?*std.ArrayList([]const u8) {
        return switch (self.*) {
            .closed => null,
            .indexing => |*i| &i.results,
            .open => |*o| &o.results,
        };
    }

    /// Free every owned buffer in whichever payload is active and
    /// transition to `closed`. Safe to call multiple times.
    pub fn close(self: *AtSearchState, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .closed => {},
            .indexing => |*i| {
                for (i.results.items) |path| gpa.free(path);
                i.results.deinit(gpa);
            },
            .open => |*o| {
                if (o.query.len > 0) gpa.free(o.query);
                if (o.notice) |n| gpa.free(n);
                for (o.results.items) |path| gpa.free(path);
                o.results.deinit(gpa);
            },
        }
        self.* = .closed;
    }

    /// Return true when no debounce deadline is set or it has already
    /// expired. The render loop uses this to coalesce rapid query changes.
    pub fn debounceExpired(self: *const AtSearchState, io: std.Io) bool {
        const deadline = switch (self.*) {
            .open => |o| o.debounce_deadline,
            .indexing => null,
            .closed => null,
        } orelse return true;

        const now = std.Io.Timestamp.now(io, .awake);
        return now.nanoseconds >= deadline.nanoseconds;
    }

    /// Push the debounce deadline forward by `ms` from now.
    /// No-op when the popup is not open.
    pub fn refreshDebounce(self: *AtSearchState, io: std.Io, ms: u64) void {
        if (self.* != .open) return;
        const now = std.Io.Timestamp.now(io, .awake);
        self.open.debounce_deadline = .{ .nanoseconds = now.nanoseconds + @as(i96, ms) * std.time.ns_per_ms };
    }
};

/// The three text-input widgets: the main prompt, the slash-palette
/// search, and the commit-message editor. Owns the vxfw.TextField
/// structs and their backing buffers.
pub const InputState = struct {
    input: vxfw.TextField,
    palette: vxfw.TextField,
    comment: vxfw.TextField,
};

/// The four picker widgets: file tree (overlay), model catalogue,
/// provider list with API-key form, and the settings panel.
/// Owns the per-picker state structs.
pub const PickerStates = struct {
    tree: tree_selector.TreeState,
    models: model_catalogue.ModelCatalogue = .{},
    provider: provider_picker.State = .{},
    settings: settings_widget.State = .{},
    help: help_picker.State = .{},
    mcp: mcp_status.State = .{},
    plugins: plugins_status.State = .{},
    search: search_widget.State = .{},
    theme: theme_picker.State = .{},
};

/// Navigation cursors and the cross-pane selection state. Owns the
/// current position in each picker/menu (command, resume, lanes,
/// transcript) plus the quit-double-tap timestamp and the lane-chip
/// hit-test rect.
pub const NavState = struct {
    pub const LanesPurpose = enum { manage, merge_dest };
    /// Sub-state of the session resume picker: browsing the list, typing a
    /// new title (rename), confirming a deletion, or showing a blocked-action
    /// popup (e.g. "cannot delete active session"). Follows the MCP `adding`
    /// pattern — a sub-state that captures all keys until submitted or
    /// cancelled.
    pub const SessionAction = enum { browsing, renaming, deleting, blocked };
    /// How the resume picker groups sessions. `flat` shows only the current
    /// project's sessions (no grouping). `project` groups by project
    /// directory. `date` groups by date (Today, Yesterday, This Week, etc.).
    pub const ResumeGroupBy = enum { flat, project, date };
    pub const QuitState = union(enum) {
        none,
        pending: std.Io.Timestamp,
        confirmed,
    };

    block_nav: bool = false,
    command_selection: u32 = 0,
    resume_selection: u32 = 0,
    /// How the resume picker groups sessions. Cycles through flat (current
    /// project, no grouping), project (all projects, grouped by project), and
    /// date (all projects, grouped by date).
    resume_group_by: ResumeGroupBy = .flat,
    session_action: SessionAction = .browsing,
    lanes_selection: u32 = 0,
    lanes_purpose: LanesPurpose = .manage,
    queued_selection: usize = 0,
    /// Quit state machine: none -> pending (user pressed Ctrl+Q once,
    /// waiting for a confirm within the window) -> confirmed (a slash
    /// exit command was issued; the next event loop drains it).
    quit: QuitState = .none,
    lanes_chip_rect: ?tui.ChipRect = null,
};

/// State for the Ctrl+O background-jobs modal: the open flag, the
/// selected row, the cancel-button focus hint, and the pending-delivery
/// queue of background results to surface. The `owner_generation` is the stable
/// lane generation that owns the job (so the delivery site resolves the
/// lane via `laneByGeneration` without holding raw pointers or risking use-after-free).
pub const BackgroundModalState = struct {
    pub const BackgroundDelivery = struct {
        owner_generation: u64,
        notice: []u8,
        message: ?[]u8,
    };

    modal: bool = false,
    selection: usize = 0,
    cancel_focus: bool = false,
    pending: std.ArrayList(BackgroundDelivery) = .empty,
};

/// The four scrollable list views used by overlays: session resume,
/// file tree, model picker, and lanes management. Grouped to keep the
/// `App` struct lean.
pub const ListWidgets = struct {
    resume_list: vxfw.ListView = .{
        .children = .{ .slice = &.{} },
        .draw_cursor = false,
        .wheel_scroll = 3,
    },
    tree_list: vxfw.ListView = .{
        .children = .{ .slice = &.{} },
        .draw_cursor = false,
        .wheel_scroll = 3,
    },
    model_list: vxfw.ListView = .{
        .children = .{ .slice = &.{} },
        .draw_cursor = false,
        .wheel_scroll = 3,
    },
    lanes_list: vxfw.ListView = .{
        .children = .{ .slice = &.{} },
        .draw_cursor = false,
        .wheel_scroll = 3,
    },
};

/// Provider connectivity, model catalogue, and API key state. Grouped
/// to keep the `App` struct lean.
pub const ProviderState = struct {
    /// API keys per provider, loaded from `auth.json`. Owned; freed in `deinit`.
    api_keys: auth.ApiKeyMap = .empty,
    /// Models.dev dynamic provider registry, loaded on `/connect` open.
    /// Owned; freed in `deinit`.
    modelsdev_registry: ?modelsdev.Registry = null,
    /// Background models.dev refresh (see registry_job.zig). The open path
    /// installs the disk cache synchronously; this job keeps it fresh without
    /// a blocking network fetch on the UI thread.
    registry_refresh: RegistryRefreshState = .idle,
    /// Backing slice for provider picker's merged provider list. Owned; freed in `deinit`.
    entries_slice: ?[]const provider_picker.ProviderHandle = null,
    /// Per-model reasoning options from config, cached for the model picker.
    /// Rebuilt when the picker opens or the active model changes. Empty
    /// means "fall back to the global hardcoded list".
    reasoning_opts_cache: [8]model_picker.ReasoningOption = undefined,
    reasoning_opts_len: u32 = 0,
    /// Live connectivity per catalogue provider, indexed by `catalogueProviders()`
    /// order. Derived from the model load's per-provider outcome.
    conn_status: [tui.catalogue_provider_count]provider_picker.Status = @splat(.unknown),
    /// True while the in-flight model load is a full connected-provider sweep,
    /// so the picker knows to reset `conn_status` when outcomes arrive.
    conn_recompute: bool = false,

    /// Background refresh state machine for the models.dev registry. Mirrors
    /// `ModelCatalogue.LoadState`'s "illegal combinations unrepresentable"
    /// rule: an armed `.loading` always carries a spawned future.
    pub const RegistryRefreshState = union(enum) {
        idle,
        loading: struct {
            future: std.Io.Future(modelsdev.Registry),
            done: std.atomic.Value(bool) = .init(false),
        },
    };
};

/// Inline edit buffers for text fields across overlays. Grouped to keep
/// the `App` struct lean.
pub const InputBuffers = struct {
    /// Inline edit buffer for the provider setup form's API-key field. Owned;
    /// freed in `deinit`.
    provider_key: std.ArrayList(u8) = .empty,
    /// Inline edit buffer for the settings panel text fields (system_prompt,
    /// bash_classifier_url). Shared across all edit targets because only one
    /// can be active at a time. Owned; freed in `deinit`.
    settings_text: std.ArrayList(u8) = .empty,
    /// Inline edit buffer for the MCP overlay's "add server by URL" form.
    /// Owned; freed in `deinit`.
    mcp_url: std.ArrayList(u8) = .empty,
    /// Inline edit buffer for the resume picker's rename-session form.
    /// Owned; freed in `deinit`.
    session_rename_text: std.ArrayList(u8) = .empty,
};

/// Visual feedback state: the loading spinner frame, the black-hole
/// intro animation frame, the cached git label, and the diff-cache
/// state machine. The rendering code reads from here; the loader
/// thread writes here.
pub const MetricsState = struct {
    loading_frame: u8 = 0,
    loading_tick_active: bool = false,
    blackhole_frame: u16 = 0,
    blackhole_visible: bool = true,
    git_label: []const u8 = "",
    context_tokens_used: u32 = 0,
    context_tokens_max: u32 = 128000,
    /// Accumulator for the active lane's `response_delta` and `thinking_delta` text bytes, fed as
    /// `streamed_bytes / 4` (the chars/4 token estimate) into `telemetry` on
    /// the UI tick. UI-thread-only; reset when the lane's turn leaves
    /// `.writing_response` / `.thinking`. The `TelemetryTracker` itself is a pure value type
    /// with no byte counter — the accumulation lives here.
    streamed_bytes: usize = 0,
    /// EMA token-velocity tracker + context-meter formatter. Updated on the UI
    /// tick (`lifecycle.handleTick`); read by the status bar (`input.zig`).
    telemetry: telemetry_mod.TelemetryTracker = .{},
    diff_counts: tui.DiffCounts = .{},
    /// Diff-cache state machine. The previous 5 flat fields
    /// (diff_refresh_future/done/again, diff_cache, diff_loading)
    /// allowed illegal combinations like future=null with cache set,
    /// or diff_loading=true with future=null. The union makes those
    /// unrepresentable.
    diff: DiffState = .idle,

    pub const DiffState = union(enum) {
        idle,
        loading: struct {
            future: std.Io.Future(tui.DiffRefreshOutcome),
            /// Set by the worker before it returns; callers check this
            /// non-blockingly before awaiting.
            done: std.atomic.Value(bool) = .init(false),
        },
        /// A successful fetch has populated `cache`; subsequent renders
        /// read from it. A refresh transitions to `refreshing`, which
        /// keeps the old cache visible while the new one loads.
        ready: struct {
            cache: []u8,
        },
        refreshing: struct {
            future: std.Io.Future(tui.DiffRefreshOutcome),
            done: std.atomic.Value(bool) = .init(false),
            cache: []u8,
        },
    };

    /// Backward-compat: future != null.
    pub fn diff_refresh_future(self: *const MetricsState) ?std.Io.Future(tui.DiffRefreshOutcome) {
        return switch (self.diff) {
            .loading => |l| l.future,
            .refreshing => |r| r.future,
            else => null,
        };
    }
    /// Backward-compat: done flag.
    pub fn diff_refresh_done(self: *const MetricsState) std.atomic.Value(bool) {
        return switch (self.diff) {
            .loading => |l| l.done,
            .refreshing => |r| r.done,
            else => .init(false),
        };
    }
    /// Backward-compat: diff_loading flag (any future-bearing state).
    pub fn diff_loading(self: *const MetricsState) bool {
        return switch (self.diff) {
            .loading, .refreshing => true,
            else => false,
        };
    }
    /// Backward-compat: diff_refresh_again (superseded by `refreshing`
    /// but kept for callers that read it). Always false now — the
    /// union's `refreshing` arm encodes the same intent.
    pub fn diff_refresh_again(self: *const MetricsState) bool {
        _ = self;
        return false;
    }
    /// Backward-compat: diff_cache (the cached body, null when idle).
    pub fn diff_cache(self: *const MetricsState) ?[]u8 {
        return switch (self.diff) {
            .ready => |r| r.cache,
            .refreshing => |r| r.cache,
            else => null,
        };
    }
};
