//! Nova's resolved preferences record and its layered loader.
//! Four sources, field-merged, later overrides earlier:
//!   1. built-in defaults
//!   2. global  `<home>/.config/nova/config.json`
//!   3. project `<cwd>/.nova/config.json`
//!   4. env vars: OPENAI_BASE_URL, OPENAI_API_KEY, OPENAI_MODEL,
//!                NOVA_USE_RESPONSES_ENDPOINT, NOVA_BASH_CLASSIFIER_URL
//!
//! `model` is a `<provider>/<model-id>` selection string. Model-specific
//! fields such as `reasoningEffort` live under `providers.<provider>.models`.
//!
//! This file is the public facade: types live here, provider/model types in
//! provider.zig, MCP types in mcp.zig, and all parse/serialize/IO/merge logic
//! in parse.zig.

const std = @import("std");

const assert = std.debug.assert;

const provider_types = @import("provider.zig");
const mcp_types = @import("mcp.zig");
const plugin_types = @import("plugin.zig");
const parse_mod = @import("parse.zig");
const context_assembly = @import("../context/assembly.zig");

// --- Provider & model re-exports ---

pub const Provider = provider_types.Provider;
pub const AdapterKind = provider_types.AdapterKind;
pub const Model = provider_types.Model;
pub const BaseUrl = provider_types.BaseUrl;
pub const ReasoningSetting = provider_types.ReasoningSetting;
pub const ProviderModel = provider_types.ProviderModel;
pub const ProviderConfig = provider_types.ProviderConfig;
pub const ModelSelectionRef = provider_types.ModelSelectionRef;
pub const ModelSelection = provider_types.ModelSelection;
pub const catalogueProviders = provider_types.catalogueProviders;
pub const allBuiltinLabels = provider_types.allBuiltinLabels;
pub const providers_by_name = provider_types.providers_by_name;

// --- MCP re-exports ---

pub const McpHeader = mcp_types.McpHeader;
pub const McpServerConfig = mcp_types.McpServerConfig;
pub const cloneHeaders = mcp_types.cloneHeaders;
pub const freeHeaders = mcp_types.freeHeaders;
pub const mcpServerFromUrl = mcp_types.mcpServerFromUrl;
pub const expandMcpServer = mcp_types.expandMcpServer;

// --- Plugin config re-exports ---

pub const PluginConfig = plugin_types.PluginConfig;

// --- Parse / serialize / IO re-exports ---

pub const load = parse_mod.load;
pub const syncModelSelectionFromLegacy = parse_mod.syncModelSelectionFromLegacy;
pub const writeGlobal = parse_mod.writeGlobal;
pub const readGlobal = parse_mod.readGlobal;
pub const mergeAndWriteGlobal = parse_mod.mergeAndWriteGlobal;
pub const readProject = parse_mod.readProject;
pub const writeProject = parse_mod.writeProject;
pub const mergeAndWriteProject = parse_mod.mergeAndWriteProject;
pub const projectConfigExists = parse_mod.projectConfigExists;
pub const globalConfigPath = parse_mod.globalConfigPath;

// --- Types owned by this file ---

/// Default cap on concurrent LLM requests across all lanes when the config
/// knob is unset. Single lane (1 request at a time) is unaffected; 2 lets a
/// lane stream while bounding the burst that saturates the provider. Mirrors
/// `request_limiter.default_permits`.
pub const default_max_concurrent_requests: u32 = 2;

/// Default per-turn bound on LLM→tool iterations. The parse layer accepts
/// 1–1000 and drops out-of-range values; this is the value used when the
/// knob is unset.
pub const default_tool_call_limit_per_turn: u32 = 100;

/// Context window management and automatic compaction policy.
/// Serialized as `"context"` in JSON (camelCase keys inside).
pub const ContextSettings = struct {
    /// Explicit context window override in tokens. When set, overrides
    /// the model catalogue lookup (useful for local Ollama/LMStudio).
    override_context_window: ?u32 = null,
    /// Maximum tokens per single model generation turn.
    max_output_tokens: ?u32 = null,
    /// Upper bound on parallel tool calls accepted from the model.
    /// Providers exceeding this get a logged error. Default 16.
    max_parallel_tool_calls: ?u32 = null,
    /// Socket read timeout in seconds for streaming responses.
    /// Prevents indefinite hangs when the server stops mid-stream.
    request_timeout_seconds: ?u32 = null,
    /// Maximum number of LLM requests in flight across ALL lanes at once.
    /// Lanes each run their own worker + HTTP client, so without this cap N
    /// active lanes fire N independent requests at the provider, which
    /// degrades or rate-limits the burst (every lane slows down together).
    /// Null = `default_max_concurrent_requests`. 1 serializes requests.
    max_concurrent_requests: ?u32 = null,
    /// Disable provider prompt-caching fields entirely. When true, neither
    /// top-level `cache_control` nor native `session_id` (OpenRouter) nor
    /// `prompt_cache_key` (OpenAI) is emitted, regardless of the resolved
    /// wire dialect — in both the chat-completions client and the Responses
    /// API client. Use for providers/models that reject these fields with
    /// HTTP 400 (some OpenRouter `:free` / gateway-fronted models — kimi,
    /// inclusionai/ling).
    disable_prompt_cache: ?bool = null,
    /// Upper bound on LLM→tool iterations (one assistant batch of tool calls
    /// = one iteration) within a single turn. A runaway model loop terminates
    /// the turn instead of spinning forever. Null = default (100); parse
    /// accepts 1–1000 and drops out-of-range values.
    tool_call_limit_per_turn: ?u32 = null,
    /// When true (default), reaching `tool_call_limit_per_turn` does NOT fail
    /// the turn: the loop exits cleanly, queued user messages are delivered,
    /// a continuation hint is left in history, and a typed event lets the
    /// TUI render a resumable notice. When false, the turn ends with
    /// `error.ToolCallLimit` as in previous releases.
    soft_stop_on_tool_call_limit: ?bool = null,
    compaction: CompactionSettings = .{},
};

/// Automatic context summarization policy when approaching the model
/// context window limit. All fields have sensible defaults matching
/// the previous hardcoded constants in compaction.zig.
pub const CompactionSettings = struct {
    /// Enable automatic context compaction before reaching limits.
    auto: bool = true,
    /// Fraction of context window (0.1–0.9) that triggers compaction. The swap
    /// watermark is derived as threshold + 0.20 (capped at 0.95); values above
    /// 0.90 would let the swap watermark fall below the start watermark, so
    /// parse clamps to this ceiling (C3).
    threshold: f64 = 0.75,
    /// Recent conversation tokens retained verbatim alongside the summary.
    keep_recent_tokens: u32 = 8_000,
    /// Number of most recent tool-result turns kept in full when assembling
    /// each prompt. Older tool results are pruned to `historical_tool_cap_bytes`
    /// (see `context/assembly.zig`). Minimum 1.
    keep_recent_tool_turns: u32 = context_assembly.default_keep_recent_tool_turns,
    /// Byte cap applied to tool results older than `keep_recent_tool_turns` —
    /// a head+tail sandwich (first half + last half, joined by
    /// `common.elideMiddle`) keeps both the start and the conclusion, with a
    /// "[... N of M bytes elided to save context ...]" notice.
    /// Defaults match the previous hardcoded constant in context/assembly.zig.
    historical_tool_cap_bytes: u32 = context_assembly.default_historical_tool_cap_bytes,
};

/// Toast notification settings for the generic toast bus. All fields are
/// optional so a default config omits the section entirely.
pub const ToastSettings = struct {
    /// Master switch. When false, no toasts are shown.
    enabled: ?bool = null,
    /// Auto-dismiss delay in milliseconds. Clamped to [500, 30000] at parse.
    duration_ms: ?u32 = null,
    /// Max toasts stacked at once. Clamped to [1, 5] at parse.
    max_visible: ?u8 = null,
    /// Corner position. Only "top-right" is supported today.
    position: ?[]u8 = null,
};

/// How fuzzy-matched runes are styled in the search pickers.
pub const FuzzyHighlightStyle = enum { accent, bold, underline };

/// Multi-lane layout arrangement when more than one lane is open.
pub const SplitMode = enum {
    /// 1:1 full-height split: left = driver (lane 0), right = focused worker.
    dual,
    /// 2x2 tiled grid showing all open lanes simultaneously (legacy split).
    grid,
    /// Single active-lane pane (legacy fullscreen).
    tab,
};

/// TUI appearance, live theme preview, and picker settings.
pub const TuiSettings = struct {
    /// Recolor the UI live while browsing themes in the /theme picker.
    theme_live_preview: bool = true,
    /// Optional directory containing user theme JSON files. When set, it
    /// REPLACES the default scan of `~/.config/nova/themes/` and
    /// `.nova/themes/`. Owned when parsed from disk.
    custom_themes_dir: ?[]u8 = null,
    /// Highlight matching characters in search pickers.
    fuzzy_highlight: bool = true,
    /// Style of matched runes: 'accent', 'bold', or 'underline'.
    fuzzy_highlight_style: FuzzyHighlightStyle = .accent,
    /// Multi-lane layout arrangement when multiple lanes are open.
    split_mode: SplitMode = .dual,
    /// Minimum terminal column width required to trigger split layout.
    min_split_width: u16 = 140,
    /// Render a high-contrast accent border around the focused split column.
    highlight_focused_border: bool = true,
    /// Show real-time streaming token velocity (⚡ tok/s) in the status bar.
    show_token_velocity: bool = true,
    /// Display the visual context window capacity progress bar in the status bar.
    show_context_meter: bool = true,
    /// EMA smoothing coefficient for token velocity.
    velocity_smoothing_alpha: f64 = 0.35,
    /// Context usage fraction that transitions the meter to amber warning.
    context_threshold_warn: f64 = 0.70,
    /// Context usage fraction that transitions the meter to red alert.
    context_threshold_alert: f64 = 0.85,
};

pub const Config = struct {
    /// Semantic version of the configuration schema instance.
    /// Null means the default ("2.0.0"). Stored as an owned slice
    /// when parsed from disk; the default points to static memory.
    version: ?[]u8 = null,
    /// The provider name as written in config (defaultModel prefix or
    /// providers map key). For builtins equals `provider.label()`; for
    /// custom providers it's the user-chosen name. Used for display,
    /// auth.json lookup, and providers-map matching.
    provider_name: ?[]u8 = null,
    base_url: ?[]u8 = null,
    api_key: ?[]u8 = null,
    bash_classifier_url: ?[]u8 = null,
    model: ?Model = null,
    providers: []ProviderConfig = &.{},
    mcp_servers: []McpServerConfig = &.{},
    /// Plugin configuration. Each entry maps a plugin name to its
    /// enabled state and settings. Merged across config layers:
    /// project plugins override global plugins with the same name.
    plugins: []PluginConfig = &.{},
    use_responses_endpoint: ?bool = null,
    system_prompt: ?[]u8 = null,
    /// Name of the builtin color theme; unknown names fall back to the default
    /// theme at resolve time in `tui/style.zig`.
    theme: ?[]u8 = null,
    /// Whether to send OpenAI strict structured-outputs mode in tool
    /// definitions. Default `false` — strict mode is OpenAI-only and
    /// silently breaks function-calling on gateways (OpenRouter/Ollama/
    /// vLLM), causing the model to emit tool calls as plain text. Enable
    /// only when talking directly to the OpenAI API.
    strict_outputs: ?bool = null,
    /// Context window management and compaction policy.
    context: ContextSettings = .{},
    /// Toast notification settings (the generic toast bus).
    toast: ToastSettings = .{},
    /// TUI appearance, live preview, and picker settings.
    tui: TuiSettings = .{},
    /// Typed view of the model selection. `null` when the required
    /// fields (provider, base_url, api_key, model) aren't all set.
    /// Equivalent to the old `assertModelSelection` check — but the
    /// presence is now encoded in the type, not enforced at runtime.
    model_selection: ?ModelSelection = null,

    /// Runtime-only: the human-readable provider name from models.dev
    /// (e.g. "StepFun", "DeepSeek"). Set when a dynamic provider is
    /// selected; cleared when switching to a builtin. Never serialized.
    /// Falls back to `provider.label()` when null.
    dynamic_provider_name: ?[]u8 = null,

    /// Runtime-only: the provider ID used as the auth.json key
    /// (e.g. "stepfun-ai"). For dynamic providers this is `provider.id`;
    /// for config providers it equals `provider.name`. Used to resolve
    /// the stored API key on session resume.
    dynamic_provider_id: ?[]u8 = null,

    /// The default schema version written by `serialize` when
    /// `version` is null.
    pub const default_version = "2.0.0";

    /// Resolve the provider enum from the loose `provider_name` field, the same
    /// way `parseModelSelection` does. Returns null when no name is set.
    pub fn providerFromName(self: *const Config) ?Provider {
        const name = self.provider_name orelse return null;
        return providers_by_name.get(name) orelse .openai_compatible;
    }

    pub fn deinit(self: *Config, gpa: std.mem.Allocator) void {
        if (self.version) |s| gpa.free(s);
        if (self.provider_name) |s| gpa.free(s);
        if (self.base_url) |s| gpa.free(s);
        if (self.api_key) |s| gpa.free(s);
        if (self.bash_classifier_url) |s| gpa.free(s);
        if (self.model) |*m| m.deinit(gpa);
        for (self.providers) |*provider| provider.deinit(gpa);
        if (self.providers.len > 0) gpa.free(self.providers);
        for (self.mcp_servers) |*server| server.deinit(gpa);
        if (self.mcp_servers.len > 0) gpa.free(self.mcp_servers);
        for (self.plugins) |*plugin| plugin.deinit(gpa);
        if (self.plugins.len > 0) gpa.free(self.plugins);
        if (self.system_prompt) |s| gpa.free(s);
        if (self.theme) |s| gpa.free(s);
        if (self.dynamic_provider_name) |s| gpa.free(s);
        if (self.dynamic_provider_id) |s| gpa.free(s);
        if (self.toast.position) |s| gpa.free(s);
        if (self.tui.custom_themes_dir) |s| gpa.free(s);
        if (self.model_selection) |*ms| ms.deinit(gpa);
        self.* = undefined;
    }

    pub fn clone(self: Config, gpa: std.mem.Allocator) !Config {
        var out: Config = .{
            .use_responses_endpoint = self.use_responses_endpoint,
            .strict_outputs = self.strict_outputs,
            .context = self.context,
        };
        errdefer out.deinit(gpa);
        if (self.version) |s| out.version = try gpa.dupe(u8, s);
        if (self.provider_name) |s| out.provider_name = try gpa.dupe(u8, s);
        if (self.base_url) |s| out.base_url = try gpa.dupe(u8, s);
        if (self.api_key) |s| out.api_key = try gpa.dupe(u8, s);
        if (self.bash_classifier_url) |s| out.bash_classifier_url = try gpa.dupe(u8, s);
        if (self.model) |m| out.model = try m.clone(gpa);
        out.providers = try gpa.alloc(ProviderConfig, self.providers.len);
        for (self.providers, 0..) |provider, index| out.providers[index] = try provider.clone(gpa);
        out.mcp_servers = try gpa.alloc(McpServerConfig, self.mcp_servers.len);
        for (self.mcp_servers, 0..) |server, index| out.mcp_servers[index] = try server.clone(gpa);
        out.plugins = try gpa.alloc(PluginConfig, self.plugins.len);
        for (self.plugins, 0..) |plugin, index| out.plugins[index] = try plugin.clone(gpa);
        if (self.system_prompt) |s| out.system_prompt = try gpa.dupe(u8, s);
        if (self.theme) |s| out.theme = try gpa.dupe(u8, s);
        if (self.dynamic_provider_name) |s| out.dynamic_provider_name = try gpa.dupe(u8, s);
        if (self.dynamic_provider_id) |s| out.dynamic_provider_id = try gpa.dupe(u8, s);
        if (self.toast.position) |s| out.toast.position = try gpa.dupe(u8, s);
        out.tui = self.tui;
        if (self.tui.custom_themes_dir) |s| out.tui.custom_themes_dir = try gpa.dupe(u8, s);
        if (self.model_selection) |ms| out.model_selection = try ms.clone(gpa);
        return out;
    }

    pub fn validate(self: *const Config, gpa: std.mem.Allocator) ![]Diagnostic {
        var list: std.ArrayList(Diagnostic) = .empty;
        errdefer {
            for (list.items) |*d| d.deinit(gpa);
            list.deinit(gpa);
        }
        if (self.version) |v| {
            const major = parse_mod.parseSemverMajor(v) orelse {
                try list.append(gpa, .{ .config_parse_error = .{
                    .path = try gpa.dupe(u8, "version"),
                    .reason = try std.fmt.allocPrint(gpa, "invalid semver '{s}'", .{v}),
                } });
                return try list.toOwnedSlice(gpa);
            };
            if (major > 2) {
                try list.append(gpa, .{ .config_parse_error = .{
                    .path = try gpa.dupe(u8, "version"),
                    .reason = try std.fmt.allocPrint(gpa, "unsupported schema version {s}", .{v}),
                } });
            }
        }
        if (self.base_url) |url| {
            if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
                try list.append(gpa, .{ .config_parse_error = .{
                    .path = try gpa.dupe(u8, "base_url"),
                    .reason = try std.fmt.allocPrint(gpa, "invalid URL scheme in '{s}'", .{url}),
                } });
            }
        }
        return try list.toOwnedSlice(gpa);
    }

    /// Alias for `clone`, used by `nova.run` to hand the TUI an owned
    /// copy of the merged config that outlives `load_result`.
    pub fn cloneForTui(self: Config, gpa: std.mem.Allocator) !Config {
        return self.clone(gpa);
    }

    pub fn activeModelSelection(self: *const Config) ?ModelSelectionRef {
        if (self.model_selection) |*ms| {
            // Pointer captures (`|*|`), NOT value captures: `&b.model` must
            // point into `self.model_selection`'s own storage, which lives as
            // long as the Config does. A value capture would hand back a
            // pointer into this function's (popped) stack frame — a dangling
            // ref that reads garbage once the caller makes any further calls
            // (e.g. applyFromConfig reading `reasoning` after attaching a
            // client). Regression: switch-on-corrupt-value in ReasoningSetting.resolve.
            return switch (ms.*) {
                .builtin => |*b| ModelSelectionRef{ .builtin = .{ .provider = b.provider, .provider_name = b.provider_name, .model = &b.model } },
                .custom => |*c| ModelSelectionRef{ .custom = .{ .provider_name = c.provider_name, .base_url = c.base_url, .api_key = c.api_key, .model = &c.model } },
            };
        }
        const provider = self.providerFromName() orelse return null;
        const model_ptr = if (self.model) |*m| m else return null;
        // providerFromName() non-null ⇒ provider_name non-null (see providerFromName).
        const name = self.provider_name.?;
        if (provider == .openai_compatible) {
            return ModelSelectionRef{ .custom = .{ .provider_name = name, .base_url = self.base_url orelse "", .api_key = self.api_key orelse "", .model = model_ptr } };
        }
        return ModelSelectionRef{ .builtin = .{ .provider = provider, .provider_name = name, .model = model_ptr } };
    }
};

/// Legacy runtime check. With `model_selection: ?ModelSelection`, the
/// invariant is encoded in the type: either the selection is fully
/// populated or it's absent. Kept for callers that still pass a Config
/// without going through parseObject (tests); it's a no-op when
/// `model_selection` is set.
pub fn assertModelSelection(config: *const Config) void {
    if (config.model_selection) |_| return;
    // When model_selection is null but the legacy fields are partially
    // set, that's a programming error. Catch it loudly.
    assert(config.model == null);
    assert(config.base_url == null);
    assert(config.api_key == null);
}

pub const Diagnostic = union(enum) {
    config_parse_error: ParseError,
    bad_env_model: []u8,

    pub const ParseError = struct {
        path: []u8,
        reason: []u8,

        fn deinit(self: *ParseError, gpa: std.mem.Allocator) void {
            gpa.free(self.path);
            gpa.free(self.reason);
            self.* = undefined;
        }
    };

    pub fn deinit(self: *Diagnostic, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .config_parse_error => |*e| e.deinit(gpa),
            .bad_env_model => |s| gpa.free(s),
        }
        self.* = undefined;
    }
};

pub const LoadResult = struct {
    config: Config,
    diagnostics: []Diagnostic,

    pub fn deinit(self: *LoadResult, gpa: std.mem.Allocator) void {
        self.config.deinit(gpa);
        for (self.diagnostics) |*d| d.deinit(gpa);
        gpa.free(self.diagnostics);
        self.* = undefined;
    }

    /// Detach the diagnostics slice so it outlives this LoadResult.
    /// Caller owns the returned slice; `deinit` after this no-ops on it.
    pub fn takeDiagnostics(self: *LoadResult) []Diagnostic {
        const out = self.diagnostics;
        self.diagnostics = &.{};
        return out;
    }
};

test "provider identity derives from provider_name" {
    const gpa = std.testing.allocator;
    // A builtin name resolves to its enum.
    var builtin: Config = .{ .provider_name = try gpa.dupe(u8, "ollama") };
    defer builtin.deinit(gpa);
    try std.testing.expectEqual(Provider.ollama, builtin.providerFromName().?);

    // A custom name (not in the builtin map) resolves to openai_compatible.
    var custom: Config = .{ .provider_name = try gpa.dupe(u8, "qwen-cloud") };
    defer custom.deinit(gpa);
    try std.testing.expectEqual(Provider.openai_compatible, custom.providerFromName().?);

    // No name set yields null.
    var empty: Config = .{};
    defer empty.deinit(gpa);
    try std.testing.expectEqual(@as(?Provider, null), empty.providerFromName());
}

test "SplitMode stringToEnum round-trips" {
    try std.testing.expectEqual(SplitMode.dual, std.meta.stringToEnum(SplitMode, "dual").?);
    try std.testing.expectEqual(SplitMode.grid, std.meta.stringToEnum(SplitMode, "grid").?);
    try std.testing.expectEqual(SplitMode.tab, std.meta.stringToEnum(SplitMode, "tab").?);
    // Unknown names resolve to null (the parser falls back to `.dual`).
    try std.testing.expectEqual(@as(?SplitMode, null), std.meta.stringToEnum(SplitMode, "bogus"));
}
