//! JSON parse/serialize, file I/O, and layer-merge logic for Nova config.
//!
//! Extracted from config.zig to keep the facade small. This file owns:
//!   - Layered load (global → project → env) and merge algebra
//!   - JSON parse (camelCase + snake_case compat) and serialize
//!   - File read/write with atomic rename
//!   - All inline tests for the above
//!
//! Types (Config, Diagnostic, LoadResult, ContextSettings, CompactionSettings)
//! live in config.zig; provider/model types in provider.zig; MCP types in mcp.zig.

const std = @import("std");
const ai = @import("../ai.zig");
const platform = @import("platform");
const paths = @import("../paths.zig");

const config_mod = @import("config.zig");
const provider_types = @import("provider.zig");
const mcp_types = @import("mcp.zig");
const plugin_types = @import("plugin.zig");

const Config = config_mod.Config;
const ContextSettings = config_mod.ContextSettings;
const CompactionSettings = config_mod.CompactionSettings;
const ToastSettings = config_mod.ToastSettings;
const TuiSettings = config_mod.TuiSettings;
const FuzzyHighlightStyle = config_mod.FuzzyHighlightStyle;
const SplitMode = config_mod.SplitMode;
const Diagnostic = config_mod.Diagnostic;
const LoadResult = config_mod.LoadResult;

/// Default `TuiSettings` — the single source for the "still at its default?"
/// sentinels in `applyTuiOverlay`, `hasNonDefaultTui`, and `writeTui` (same
/// idiom as `d` in `hasNonDefaultContext`). Field initializers live in
/// `config.zig`; comparing against `default_tui.<field>` instead of re-typed
/// literals keeps serialization in lockstep when a default changes.
const default_tui: TuiSettings = .{};

/// Floor for `overrideContextWindow`/`contextWindow` parses — values below a
/// real model window are treated as absent rather than clamped.
const context_window_floor_tokens: u32 = 1024;
/// Accepted band for `toolCallLimitPerTurn`. The default lives in
/// `config.zig` (`default_tool_call_limit_per_turn`); out-of-band values are
/// dropped (the field stays null → default), matching sibling knobs.
const tool_call_limit_min: u32 = 1;
const tool_call_limit_max: u32 = 1000;
/// Accepted band for `minSplitWidth`; out-of-band values are dropped (the
/// field keeps its default), matching the toast-setting convention.
const min_split_width_min: u16 = 80;
const min_split_width_max: u16 = 500;

const Provider = provider_types.Provider;
const AdapterKind = provider_types.AdapterKind;
const Model = provider_types.Model;
const BaseUrl = provider_types.BaseUrl;
const ReasoningSetting = provider_types.ReasoningSetting;
const ProviderModel = provider_types.ProviderModel;
const ProviderConfig = provider_types.ProviderConfig;
const ModelSelection = provider_types.ModelSelection;
const providers_by_name = provider_types.providers_by_name;
const catalogueProviders = provider_types.catalogueProviders;

const McpHeader = mcp_types.McpHeader;
const McpServerConfig = mcp_types.McpServerConfig;
const cloneHeaders = mcp_types.cloneHeaders;
const freeHeaders = mcp_types.freeHeaders;
const mcpServerFromUrl = mcp_types.mcpServerFromUrl;
const expandMcpServer = mcp_types.expandMcpServer;

const PluginConfig = plugin_types.PluginConfig;

const assert = std.debug.assert;

pub fn load(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    home_dir: []const u8,
    env: anytype,
) !LoadResult {
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer {
        for (diagnostics.items) |*d| d.deinit(gpa);
        diagnostics.deinit(gpa);
    }

    var global = try loadGlobalFile(gpa, io, home_dir, &diagnostics);
    defer global.deinit(gpa);

    var project = try loadProjectFile(gpa, io, cwd, &diagnostics);
    defer project.deinit(gpa);

    var env_layer = try loadEnv(gpa, env, &diagnostics);
    defer env_layer.deinit(gpa);

    var merged = try mergeLayers(gpa, &.{ global, project, env_layer });
    errdefer merged.deinit(gpa);

    return .{
        .config = merged,
        .diagnostics = try diagnostics.toOwnedSlice(gpa),
    };
}

/// The pure layering algebra: fold each layer onto the result in
/// least-to-most-specific order (global, then project, then env), then hydrate
/// the chosen model against the fully merged provider list. No file IO — every
/// input is an already-parsed Config, so the precedence rules and hydration are
/// unit-testable without touching disk (see the "mergeLayers …" tests).
fn mergeLayers(gpa: std.mem.Allocator, layers: []const Config) !Config {
    var out: Config = .{};
    errdefer out.deinit(gpa);
    for (layers) |layer| try applyConfigOverlay(gpa, &out, layer);
    try hydrateActiveModel(gpa, &out);
    return out;
}

/// Merge `updates` onto `target`. `api_key` is merged like any other field —
/// it is needed in the in-memory runtime config. Persistence is a separate
/// concern: `serialize` is the single seam that decides what reaches disk, and
/// it never writes `api_key` (keys live only in auth.json). So this overlay
/// needs no "should I keep the key?" flag — the write path strips it anyway.
///
/// When `updates.model_selection` is present it is treated as the canonical
/// form and all legacy fields are derived from it. When absent, individual
/// legacy fields are applied and `target.model_selection` (if present) is
/// kept in sync so `serialize` — which prefers `model_selection` — always
/// writes the correct values.
fn applyConfigOverlay(gpa: std.mem.Allocator, target: *Config, updates: Config) !void {
    if (updates.model_selection) |ms| {
        // Canonical form: model_selection is the single source of truth.
        // Mirror all fields onto the target's legacy fields so the merge
        // result is self-consistent regardless of which path serialize uses.
        // Propagate provider_name so serialize's legacy fallback writes the
        // correct config key (e.g. "stepfun-ai-step-plan") instead of the
        // enum label ("openai_compatible").
        if (target.provider_name) |old| gpa.free(old);
        target.provider_name = try gpa.dupe(u8, ms.providerName());
        if (target.model) |*old| old.deinit(gpa);
        const model = switch (ms) {
            .builtin => |b| b.model,
            .custom => |c| c.model,
        };
        target.model = try model.clone(gpa);
        if (ms.baseUrl()) |base_url| try replaceOptionalSlice(gpa, &target.base_url, base_url);
        if (ms.apiKey()) |api_key| try replaceOptionalSlice(gpa, &target.api_key, api_key);
        target.use_responses_endpoint = ms.useResponsesEndpoint();
        if (ms.systemPrompt()) |s| try replaceOptionalSlice(gpa, &target.system_prompt, s);
        if (ms.bashClassifierUrl()) |s| try replaceOptionalSlice(gpa, &target.bash_classifier_url, s);
    } else {
        // Legacy fields: apply individual field overrides.
        if (updates.provider_name) |s| try replaceOptionalSlice(gpa, &target.provider_name, s);
        if (updates.use_responses_endpoint) |v| target.use_responses_endpoint = v;
        if (updates.strict_outputs) |v| target.strict_outputs = v;
        if (updates.base_url) |s| try replaceOptionalSlice(gpa, &target.base_url, s);
        if (updates.api_key) |s| try replaceOptionalSlice(gpa, &target.api_key, s);
        if (updates.bash_classifier_url) |s| try replaceOptionalSlice(gpa, &target.bash_classifier_url, s);
        if (updates.system_prompt) |s| try replaceOptionalSlice(gpa, &target.system_prompt, s);
        if (updates.model) |m| {
            if (target.model) |*old| old.deinit(gpa);
            target.model = try m.clone(gpa);
        }
        // Keep model_selection in sync with legacy fields so serialize
        // (which prefers model_selection) picks up the changes.
        try syncModelSelectionFromLegacy(gpa, target);
    }
    for (updates.providers) |provider| try applyProviderOverlay(gpa, target, provider);
    for (updates.mcp_servers) |mcp_server| try applyMcpServerOverlay(gpa, target, mcp_server);
    for (updates.plugins) |plugin| try applyPluginOverlay(gpa, target, plugin);
    applyContextOverlay(&target.context, updates.context);
    try applyToastOverlay(gpa, target, updates.toast);
    try applyTuiOverlay(gpa, target, updates.tui);
    // Theme is independent of model selection, so it merges unconditionally.
    if (updates.theme) |s| try replaceOptionalSlice(gpa, &target.theme, s);
}

/// Merge toast settings: non-default values in `updates` override `target`.
/// `position` is owned by `updates`; when it changes, the target's old value
/// is freed and the new one is duped.
fn applyToastOverlay(gpa: std.mem.Allocator, target: *Config, updates: ToastSettings) !void {
    if (updates.enabled != null) target.toast.enabled = updates.enabled;
    if (updates.duration_ms != null) target.toast.duration_ms = updates.duration_ms;
    if (updates.max_visible != null) target.toast.max_visible = updates.max_visible;
    if (updates.position) |s| {
        if (target.toast.position) |old| gpa.free(old);
        target.toast.position = try gpa.dupe(u8, s);
    }
}

/// Merge TUI settings: non-default values in `updates` override `target`.
/// `custom_themes_dir` is owned by `updates`; when it changes, the target's
/// old value is freed and the new one is duped.
fn applyTuiOverlay(gpa: std.mem.Allocator, target: *Config, updates: TuiSettings) !void {
    // Only non-default values override — a default `updates` must leave the
    // target's stored settings intact (unrelated partial config writes route
    // through here with an all-default `tui`).
    if (updates.theme_live_preview != default_tui.theme_live_preview) target.tui.theme_live_preview = updates.theme_live_preview;
    if (updates.custom_themes_dir) |s| {
        if (target.tui.custom_themes_dir) |old| gpa.free(old);
        target.tui.custom_themes_dir = try gpa.dupe(u8, s);
    }
    if (updates.fuzzy_highlight != default_tui.fuzzy_highlight) target.tui.fuzzy_highlight = updates.fuzzy_highlight;
    if (updates.fuzzy_highlight_style != default_tui.fuzzy_highlight_style) target.tui.fuzzy_highlight_style = updates.fuzzy_highlight_style;
    // Layout + telemetry knobs: only non-default values override.
    if (updates.split_mode != default_tui.split_mode) target.tui.split_mode = updates.split_mode;
    if (updates.min_split_width != default_tui.min_split_width) target.tui.min_split_width = updates.min_split_width;
    if (updates.highlight_focused_border != default_tui.highlight_focused_border) target.tui.highlight_focused_border = updates.highlight_focused_border;
    if (updates.show_token_velocity != default_tui.show_token_velocity) target.tui.show_token_velocity = updates.show_token_velocity;
    if (updates.show_context_meter != default_tui.show_context_meter) target.tui.show_context_meter = updates.show_context_meter;
    if (updates.velocity_smoothing_alpha != default_tui.velocity_smoothing_alpha) target.tui.velocity_smoothing_alpha = updates.velocity_smoothing_alpha;
    if (updates.context_threshold_warn != default_tui.context_threshold_warn) target.tui.context_threshold_warn = updates.context_threshold_warn;
    if (updates.context_threshold_alert != default_tui.context_threshold_alert) target.tui.context_threshold_alert = updates.context_threshold_alert;
}

/// Merge context settings: non-default values in `updates` override `target`.
fn applyContextOverlay(target: *ContextSettings, updates: ContextSettings) void {
    if (updates.override_context_window != null) target.override_context_window = updates.override_context_window;
    if (updates.max_output_tokens != null) target.max_output_tokens = updates.max_output_tokens;
    if (updates.max_parallel_tool_calls != null) target.max_parallel_tool_calls = updates.max_parallel_tool_calls;
    if (updates.request_timeout_seconds != null) target.request_timeout_seconds = updates.request_timeout_seconds;
    if (updates.max_concurrent_requests != null) target.max_concurrent_requests = updates.max_concurrent_requests;
    if (updates.disable_prompt_cache != null) target.disable_prompt_cache = updates.disable_prompt_cache;
    if (updates.tool_call_limit_per_turn != null) target.tool_call_limit_per_turn = updates.tool_call_limit_per_turn;
    if (updates.soft_stop_on_tool_call_limit != null) target.soft_stop_on_tool_call_limit = updates.soft_stop_on_tool_call_limit;
    const d: CompactionSettings = .{};
    if (updates.compaction.auto != d.auto) target.compaction.auto = updates.compaction.auto;
    if (updates.compaction.threshold != d.threshold) target.compaction.threshold = updates.compaction.threshold;
    if (updates.compaction.keep_recent_tokens != d.keep_recent_tokens) target.compaction.keep_recent_tokens = updates.compaction.keep_recent_tokens;
    if (updates.compaction.keep_recent_tool_turns != d.keep_recent_tool_turns) target.compaction.keep_recent_tool_turns = updates.compaction.keep_recent_tool_turns;
    if (updates.compaction.historical_tool_cap_bytes != d.historical_tool_cap_bytes) target.compaction.historical_tool_cap_bytes = updates.compaction.historical_tool_cap_bytes;
}

/// After applying legacy-field updates, mirror the changes onto
/// `target.model_selection` (if present) so `serialize` — which
/// prefers `model_selection` — writes the correct values.
pub fn syncModelSelectionFromLegacy(gpa: std.mem.Allocator, target: *Config) !void {
    if (target.model_selection) |*ms| {
        // Sync fields from legacy into the typed selection. If the provider
        // enum changed, rebuild the selection with the correct variant so
        // illegal state combinations are impossible.
        const provider = target.providerFromName() orelse return;
        const model = target.model orelse return;
        const provider_name = target.provider_name.?;
        const base_url = if (target.base_url) |s| s else "";
        const api_key = if (target.api_key) |s| s else "";
        const new_selection: ModelSelection = if (provider == .openai_compatible) .{
            .custom = .{
                .provider_name = try gpa.dupe(u8, provider_name),
                .base_url = try gpa.dupe(u8, base_url),
                .api_key = try gpa.dupe(u8, api_key),
                .model = try model.clone(gpa),
                .use_responses_endpoint = target.use_responses_endpoint orelse false,
                .system_prompt = if (target.system_prompt) |s| try gpa.dupe(u8, s) else null,
                .bash_classifier_url = if (target.bash_classifier_url) |s| try gpa.dupe(u8, s) else null,
            },
        } else .{
            .builtin = .{
                .provider = provider,
                .provider_name = try gpa.dupe(u8, provider_name),
                .model = try model.clone(gpa),
                .use_responses_endpoint = target.use_responses_endpoint orelse false,
                .system_prompt = if (target.system_prompt) |s| try gpa.dupe(u8, s) else null,
                .bash_classifier_url = if (target.bash_classifier_url) |s| try gpa.dupe(u8, s) else null,
            },
        };
        ms.deinit(gpa);
        target.model_selection = new_selection;
    }
}

fn applyMcpServerOverlay(gpa: std.mem.Allocator, target: *Config, updates: McpServerConfig) !void {
    for (target.mcp_servers, 0..) |*server, index| {
        if (!std.mem.eql(u8, server.name, updates.name)) continue;
        server.enabled = updates.enabled;
        server.request_timeout_ms = updates.request_timeout_ms;
        server.transport = switch (updates.transport) {
            .stdio => |t| blk: {
                var args = try gpa.alloc([]u8, t.args.len);
                errdefer gpa.free(args);
                for (t.args, 0..) |arg, i| args[i] = try gpa.dupe(u8, arg);
                break :blk .{ .stdio = .{
                    .command = try gpa.dupe(u8, t.command),
                    .args = args,
                } };
            },
            .sse => |t| .{ .sse = .{ .url = try gpa.dupe(u8, t.url) } },
        };
        target.mcp_servers[index] = server.*;
        return;
    }

    const next = if (target.mcp_servers.len == 0)
        try gpa.alloc(McpServerConfig, 1)
    else
        try gpa.realloc(target.mcp_servers, target.mcp_servers.len + 1);
    target.mcp_servers = next;
    target.mcp_servers[target.mcp_servers.len - 1] = try updates.clone(gpa);
}

fn applyPluginOverlay(gpa: std.mem.Allocator, target: *Config, updates: PluginConfig) !void {
    for (target.plugins, 0..) |*plugin, index| {
        if (!std.mem.eql(u8, plugin.name, updates.name)) continue;
        plugin.enabled = updates.enabled;
        if (updates.settings.len > 0) {
            if (plugin.settings.len > 0) gpa.free(plugin.settings);
            plugin.settings = try gpa.dupe(u8, updates.settings);
        }
        target.plugins[index] = plugin.*;
        return;
    }

    const next = if (target.plugins.len == 0)
        try gpa.alloc(PluginConfig, 1)
    else
        try gpa.realloc(target.plugins, target.plugins.len + 1);
    target.plugins = next;
    target.plugins[target.plugins.len - 1] = try updates.clone(gpa);
}

fn applyProviderOverlay(gpa: std.mem.Allocator, target: *Config, updates: ProviderConfig) !void {
    // Match by config map key, not by provider enum. Multiple custom/dynamic
    // providers share the `.openai_compatible` enum, so enum-based matching
    // causes collisions where the first matching entry absorbs all updates
    // and subsequent entries silently overwrite it.
    for (target.providers, 0..) |*provider, index| {
        if (!std.mem.eql(u8, provider.name, updates.name)) continue;
        switch (updates.base_url) {
            .custom => |s| try replaceBaseUrl(gpa, &provider.base_url, s),
            .default => {},
        }
        try applyProviderModelsOverlay(gpa, provider, updates.models);
        target.providers[index] = provider.*;
        return;
    }

    const next = if (target.providers.len == 0)
        try gpa.alloc(ProviderConfig, 1)
    else
        try gpa.realloc(target.providers, target.providers.len + 1);
    target.providers = next;
    target.providers[target.providers.len - 1] = try updates.clone(gpa);
}

fn applyProviderModelsOverlay(gpa: std.mem.Allocator, target: *ProviderConfig, updates: []const ProviderModel) !void {
    for (updates) |update| {
        var replaced = false;
        for (target.models) |*model| {
            if (!std.mem.eql(u8, model.id, update.id)) continue;
            switch (update.reasoning) {
                .effort => model.reasoning = update.reasoning,
                .unset => {},
            }
            if (update.reasoning_options.len > 0) {
                if (model.reasoning_options.len > 0) gpa.free(model.reasoning_options);
                model.reasoning_options = try gpa.dupe(ai.ReasoningEffort, update.reasoning_options);
            }
            replaced = true;
            break;
        }
        if (replaced) continue;
        const next = if (target.models.len == 0)
            try gpa.alloc(ProviderModel, 1)
        else
            try gpa.realloc(target.models, target.models.len + 1);
        target.models = next;
        target.models[target.models.len - 1] = try update.clone(gpa);
    }
}

fn hydrateActiveModel(gpa: std.mem.Allocator, config: *Config) !void {
    const ms_opt = &config.model_selection;
    if (ms_opt.*) |*ms| {
        // Hydrate the model inside model_selection from the providers map.
        const name = ms.providerName();
        const model_ptr: *Model = switch (ms.*) {
            .builtin => |*b| &b.model,
            .custom => |*c| &c.model,
        };
        for (config.providers) |entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            for (entry.models) |entry_model| {
                if (!std.mem.eql(u8, entry_model.id, model_ptr.id)) continue;
                if (model_ptr.reasoning == .unset and entry_model.reasoning == .effort) {
                    model_ptr.reasoning = entry_model.reasoning;
                }
                model_ptr.context_window = entry_model.context_window;
                model_ptr.max_output_tokens = entry_model.max_output_tokens;
                if (entry_model.reasoning_options.len > 0) {
                    if (model_ptr.reasoning_options.len > 0) gpa.free(model_ptr.reasoning_options);
                    model_ptr.reasoning_options = try gpa.dupe(ai.ReasoningEffort, entry_model.reasoning_options);
                }
                return;
            }
        }
        return;
    }
    const provider = config.providerFromName() orelse return;
    if (config.model == null) return;
    const name = config.provider_name.?;
    for (config.providers) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        try hydrateFromProviderEntry(gpa, config, entry);
        return;
    }
    // Recovery: configs written before the provider_name serialization
    // fix have provider_name = "openai_compatible" (the enum label)
    // while the providers[] key is the actual id (e.g. "stepfun-ai").
    // Match by provider enum and repair provider_name so auth.json
    // lookups and subsequent serializations use the correct key.
    if (provider == .openai_compatible) {
        for (config.providers) |entry| {
            if (entry.provider != .openai_compatible) continue;
            if (config.provider_name) |old| gpa.free(old);
            config.provider_name = try gpa.dupe(u8, entry.name);
            try hydrateFromProviderEntry(gpa, config, entry);
            return;
        }
    }
}

fn hydrateFromProviderEntry(gpa: std.mem.Allocator, config: *Config, entry: ProviderConfig) !void {
    switch (entry.base_url) {
        .custom => |base_url| try replaceOptionalSlice(gpa, &config.base_url, base_url),
        .default => {},
    }
    for (entry.models) |model| {
        if (!std.mem.eql(u8, model.id, config.model.?.id)) continue;
        // When adding fields to Model, also copy them here so they
        // survive the merge → hydrate cycle.
        switch (model.reasoning) {
            .effort => config.model.?.reasoning = model.reasoning,
            .unset => {},
        }
        config.model.?.context_window = model.context_window;
        config.model.?.max_output_tokens = model.max_output_tokens;
        if (model.reasoning_options.len > 0) {
            if (config.model.?.reasoning_options.len > 0) gpa.free(config.model.?.reasoning_options);
            config.model.?.reasoning_options = try gpa.dupe(ai.ReasoningEffort, model.reasoning_options);
        }
        return;
    }
}

fn replaceOptionalSlice(gpa: std.mem.Allocator, target: *?[]u8, source: []const u8) !void {
    const next = try gpa.dupe(u8, source);
    if (target.*) |old| gpa.free(old);
    target.* = next;
}

fn replaceBaseUrl(gpa: std.mem.Allocator, target: *BaseUrl, source: []const u8) !void {
    const next = try gpa.dupe(u8, source);
    switch (target.*) {
        .custom => |old| gpa.free(old),
        .default => {},
    }
    target.* = .{ .custom = next };
}

fn loadGlobalFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    home_dir: []const u8,
    diagnostics: *std.ArrayList(Diagnostic),
) !Config {
    const path = globalConfigPath(gpa, io, home_dir) catch return .{};
    defer gpa.free(path);
    return loadFile(gpa, io, path, diagnostics);
}

fn loadProjectFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    diagnostics: *std.ArrayList(Diagnostic),
) !Config {
    const path = try std.fs.path.join(gpa, &.{ cwd, ".nova", "config.json" });
    defer gpa.free(path);
    return loadFile(gpa, io, path, diagnostics);
}

fn loadFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    diagnostics: *std.ArrayList(Diagnostic),
) !Config {
    const file = std.Io.Dir.openFile(.cwd(), io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => {
            try diagnostics.append(gpa, .{ .config_parse_error = .{
                .path = try gpa.dupe(u8, path),
                .reason = try gpa.dupe(u8, @errorName(err)),
            } });
            return .{};
        },
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > 32 * 1024) {
        try diagnostics.append(gpa, .{ .config_parse_error = .{
            .path = try gpa.dupe(u8, path),
            .reason = try gpa.dupe(u8, "FileTooBig"),
        } });
        return .{};
    }
    const bytes = try gpa.alloc(u8, @intCast(stat.size));
    defer gpa.free(bytes);
    var reader = file.reader(io, &.{});
    try reader.interface.readSliceAll(bytes);
    return parseFile(gpa, path, bytes, diagnostics);
}

fn parseFile(
    gpa: std.mem.Allocator,
    path: []const u8,
    bytes: []const u8,
    diagnostics: *std.ArrayList(Diagnostic),
) !Config {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch |err| {
        try diagnostics.append(gpa, .{ .config_parse_error = .{
            .path = try gpa.dupe(u8, path),
            .reason = try std.fmt.allocPrint(gpa, "invalid JSON: {s}", .{@errorName(err)}),
        } });
        return .{};
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        try diagnostics.append(gpa, .{ .config_parse_error = .{
            .path = try gpa.dupe(u8, path),
            .reason = try gpa.dupe(u8, "top-level value must be an object"),
        } });
        return .{};
    }
    return parseObject(gpa, path, parsed.value, diagnostics);
}

fn parseObject(
    gpa: std.mem.Allocator,
    path: []const u8,
    value: std.json.Value,
    diagnostics: *std.ArrayList(Diagnostic),
) !Config {
    var out: Config = .{};
    errdefer out.deinit(gpa);

    // Version: accept semver string ("2.0.0") or legacy integer (1).
    if (value.object.get("version")) |ver| {
        switch (ver) {
            .string => |s| out.version = try gpa.dupe(u8, s),
            .integer => |v| out.version = try std.fmt.allocPrint(gpa, "{d}.0.0", .{v}),
            else => {},
        }
    }

    // Model: accept "defaultModel" (camelCase) or "model" (legacy).
    const model_str = stringFieldCompat(value, "defaultModel", "model");
    if (model_str) |s| {
        if (parseModelSelection(gpa, s)) |selection| {
            out.provider_name = selection.provider_name;
            out.model = selection.model;
        } else |err| {
            try diagnostics.append(gpa, .{ .config_parse_error = .{
                .path = try gpa.dupe(u8, path),
                .reason = try std.fmt.allocPrint(gpa, "invalid model selection: {s}", .{@errorName(err)}),
            } });
        }
    }
    if (value.object.get("providers")) |providers_value| {
        if (providers_value == .object) out.providers = try parseProviders(gpa, providers_value);
    }
    const mcp_val = value.object.get("mcpServers") orelse value.object.get("mcp_servers") orelse value.object.get("mcp");
    if (mcp_val) |val| {
        if (val == .object) out.mcp_servers = try parseMcpServers(gpa, val);
    }
    if (value.object.get("plugins")) |plugins_val| {
        if (plugins_val == .object) out.plugins = try parsePlugins(gpa, plugins_val);
    }

    // Scalar fields: camelCase primary, snake_case fallback.
    if (stringFieldCompat(value, "baseURL", "base_url")) |s| {
        out.base_url = try gpa.dupe(u8, s);
    }
    if (stringFieldCompat(value, "bashClassifierUrl", "bash_classifier_url")) |s| {
        if (s.len > 0) out.bash_classifier_url = try gpa.dupe(u8, s);
    }
    if (boolFieldCompat(value, "useResponsesEndpoint", "use_responses_endpoint")) |b| out.use_responses_endpoint = b;
    // The legacy `enableThinking` / `enable_thinking` key is accepted but
    // discarded: reasoning is controlled per-model via `reasoningEffort`
    // (see the reasoning-effort-lifecycle plan, Phase 2). Existing configs
    // that still carry the key parse without error; the next save drops it.
    if (boolFieldCompat(value, "strictOutputs", "strict_outputs")) |b| out.strict_outputs = b;
    if (stringFieldCompat(value, "systemPrompt", "system_prompt")) |s| {
        out.system_prompt = try gpa.dupe(u8, s);
    }
    // Theme name (single snake_case key; empty means "default" at resolve time).
    if (stringField(value, "theme")) |s| {
        if (s.len > 0) out.theme = try gpa.dupe(u8, s);
    }

    // Context window and compaction settings.
    if (value.object.get("context")) |ctx_val| {
        if (ctx_val == .object) out.context = parseContext(ctx_val);
    }

    // Toast notification settings.
    if (value.object.get("toast")) |toast_val| {
        if (toast_val == .object) out.toast = try parseToast(gpa, toast_val);
    }

    // TUI appearance / live preview / picker settings.
    if (value.object.get("tui")) |tui_val| {
        if (tui_val == .object) out.tui = try parseTui(gpa, tui_val);
    }

    // Populate the typed `model_selection` when all required fields
    // are present. Missing any of them leaves it null — the legacy
    // optional fields stay so existing callers keep working until
    // they migrate to `model_selection`.
    if (out.provider_name != null and out.model != null and
        out.base_url != null and out.api_key != null)
    {
        const provider = providers_by_name.get(out.provider_name.?) orelse .openai_compatible;
        const model = out.model.?; // ownership moves; clear the legacy field
        if (provider == .openai_compatible) {
            out.model_selection = .{
                .custom = .{
                    .provider_name = out.provider_name orelse try gpa.dupe(u8, provider.label()),
                    .base_url = out.base_url.?,
                    .api_key = out.api_key.?,
                    .model = model,
                    .use_responses_endpoint = out.use_responses_endpoint orelse false,
                    .system_prompt = out.system_prompt,
                    .bash_classifier_url = out.bash_classifier_url,
                },
            };
        } else {
            out.model_selection = .{
                .builtin = .{
                    .provider = provider,
                    .provider_name = out.provider_name orelse try gpa.dupe(u8, provider.label()),
                    .model = model,
                    .use_responses_endpoint = out.use_responses_endpoint orelse false,
                    .system_prompt = out.system_prompt,
                    .bash_classifier_url = out.bash_classifier_url,
                },
            };
        }
        out.provider_name = null;
        out.model = null;
        out.base_url = null;
        out.api_key = null;
        out.use_responses_endpoint = null;
        out.system_prompt = null;
        out.bash_classifier_url = null;
    }

    // Parsing is pure: producing a single layer's Config never reaches into the
    // provider catalogue. Hydration runs once after all layers merge, against
    // the fully merged provider list (see `mergeLayers`).
    return out;
}

/// String field with camelCase primary and snake_case fallback.
fn stringFieldCompat(value: std.json.Value, camel: []const u8, snake: []const u8) ?[]const u8 {
    if (fieldCompat(value.object, camel, snake)) |field| {
        if (field == .string) return field.string;
    }
    return null;
}

/// Bool field with camelCase primary and snake_case fallback.
fn boolFieldCompat(value: std.json.Value, camel: []const u8, snake: []const u8) ?bool {
    if (fieldCompat(value.object, camel, snake)) |field| {
        if (field == .bool) return field.bool;
    }
    return null;
}

/// `u32field` with camelCase primary and snake_case fallback. Out-of-u32-range
/// values yield null exactly like `u32field` — the lower/upper-bound checks
/// stay at the call site so per-field bands are explicit.
fn u32fieldCompat(value: std.json.Value, camel: []const u8, snake: []const u8) ?u32 {
    if (fieldCompat(value.object, camel, snake)) |field| {
        if (field == .integer) return std.math.cast(u32, field.integer);
    }
    return null;
}

/// Parse the `"context"` object into `ContextSettings`. Pure — no
/// allocation (all fields are scalars).
fn parseContext(value: std.json.Value) ContextSettings {
    var ctx: ContextSettings = .{};
    if (u32field(value, "overrideContextWindow")) |v| {
        if (v >= context_window_floor_tokens) ctx.override_context_window = v;
    }
    if (u32field(value, "maxOutputTokens")) |v| {
        if (v >= 1) ctx.max_output_tokens = v;
    }
    if (u32field(value, "maxParallelToolCalls")) |v| {
        if (v >= 1 and v <= 64) ctx.max_parallel_tool_calls = v;
    }
    if (u32field(value, "requestTimeoutSeconds")) |v| {
        if (v >= 1) ctx.request_timeout_seconds = v;
    }
    if (u32field(value, "maxConcurrentRequests")) |v| {
        if (v >= 1) ctx.max_concurrent_requests = v;
    }
    if (boolFieldCompat(value, "disablePromptCache", "disable_prompt_cache")) |b| {
        ctx.disable_prompt_cache = b;
    }
    if (u32fieldCompat(value, "toolCallLimitPerTurn", "tool_call_limit_per_turn")) |v| {
        if (v >= tool_call_limit_min and v <= tool_call_limit_max) ctx.tool_call_limit_per_turn = v;
    }
    if (boolFieldCompat(value, "softStopOnToolCallLimit", "soft_stop_on_tool_call_limit")) |b| {
        ctx.soft_stop_on_tool_call_limit = b;
    }
    if (value.object.get("compaction")) |comp_val| {
        if (comp_val == .object) ctx.compaction = parseCompaction(comp_val);
    }
    return ctx;
}

/// Ceiling for the configurable compaction threshold. The swap watermark is
/// `threshold + 0.20` capped at 0.95, so a threshold above 0.90 would let the
/// swap watermark fall *below* the start watermark and invert the watermarks
/// (C3). Values are clamped here so configs self-heal on next save.
const compaction_threshold_max: f64 = 0.90;

fn parseCompaction(value: std.json.Value) CompactionSettings {
    var comp: CompactionSettings = .{};
    if (boolField(value, "auto")) |b| comp.auto = b;
    if (floatField(value, "threshold")) |f| {
        if (f >= 0.1 and f <= 1.0) comp.threshold = @min(f, compaction_threshold_max);
    }
    if (u32field(value, "keepRecentTokens")) |v| {
        comp.keep_recent_tokens = v;
    }
    if (u32field(value, "keepRecentToolTurns")) |v| {
        // Minimum 1: 0 would prune every tool result immediately and break
        // tool-calling (the model would never see a result in full).
        if (v >= 1) comp.keep_recent_tool_turns = v;
    }
    if (u32field(value, "historicalToolCapBytes")) |v| {
        // Minimum 1: a 0 cap would render every pruned result empty.
        if (v >= 1) comp.historical_tool_cap_bytes = v;
    }
    return comp;
}

/// Clamp bounds for the toast knobs. `duration_ms` is clamped to [500, 30000]
/// and `max_visible` to [1, 5] so a config typo can't produce a toast that
/// never dismisses or a stack that covers the whole screen.
const toast_duration_min: u32 = 500;
const toast_duration_max: u32 = 30_000;
const toast_max_visible_min: u8 = 1;
const toast_max_visible_max: u8 = 5;

fn parseToast(gpa: std.mem.Allocator, value: std.json.Value) !ToastSettings {
    var toast: ToastSettings = .{};
    if (boolField(value, "enabled")) |b| toast.enabled = b;
    if (intField(value, "durationMs")) |v| {
        if (v >= toast_duration_min and v <= toast_duration_max) toast.duration_ms = @intCast(v);
    }
    if (intField(value, "maxVisible")) |v| {
        if (v >= toast_max_visible_min and v <= toast_max_visible_max) toast.max_visible = @intCast(v);
    }
    if (stringField(value, "position")) |s| toast.position = try gpa.dupe(u8, s);
    return toast;
}

fn parseTui(gpa: std.mem.Allocator, value: std.json.Value) !TuiSettings {
    var tui: TuiSettings = .{};
    if (boolField(value, "themeLivePreview")) |b| tui.theme_live_preview = b;
    if (stringField(value, "customThemesDir")) |s| tui.custom_themes_dir = try gpa.dupe(u8, s);
    if (boolField(value, "fuzzyHighlight")) |b| tui.fuzzy_highlight = b;
    if (stringField(value, "fuzzyHighlightStyle")) |s| {
        tui.fuzzy_highlight_style = std.meta.stringToEnum(FuzzyHighlightStyle, s) orelse .accent;
    }
    if (stringField(value, "splitMode")) |s| {
        tui.split_mode = std.meta.stringToEnum(SplitMode, s) orelse .dual;
    }
    if (u32field(value, "minSplitWidth")) |v| {
        if (v >= min_split_width_min and v <= min_split_width_max) tui.min_split_width = @intCast(v);
    }
    if (boolField(value, "highlightFocusedBorder")) |b| tui.highlight_focused_border = b;
    if (boolField(value, "showTokenVelocity")) |b| tui.show_token_velocity = b;
    if (boolField(value, "showContextMeter")) |b| tui.show_context_meter = b;
    if (floatField(value, "velocitySmoothingAlpha")) |f| {
        if (f >= 0.05 and f <= 1.0) tui.velocity_smoothing_alpha = f;
    }
    if (floatField(value, "contextThresholdWarn")) |f| {
        if (f >= 0.1 and f <= 0.9) tui.context_threshold_warn = f;
    }
    if (floatField(value, "contextThresholdAlert")) |f| {
        if (f >= 0.2 and f <= 0.99) tui.context_threshold_alert = f;
    }
    return tui;
}

fn parseProviders(gpa: std.mem.Allocator, value: std.json.Value) ![]ProviderConfig {
    var providers: std.ArrayList(ProviderConfig) = .empty;
    errdefer {
        for (providers.items) |*provider| provider.deinit(gpa);
        providers.deinit(gpa);
    }
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        // Builtin labels resolve to their enum; unknown keys are custom
        // providers using the openai_compatible adapter.
        const provider = providers_by_name.get(entry.key_ptr.*) orelse .openai_compatible;
        try providers.append(gpa, try parseProviderConfig(gpa, entry.key_ptr.*, provider, entry.value_ptr.*));
    }
    return try providers.toOwnedSlice(gpa);
}

fn parseMcpServers(gpa: std.mem.Allocator, value: std.json.Value) ![]McpServerConfig {
    var servers: std.ArrayList(McpServerConfig) = .empty;
    errdefer {
        for (servers.items) |*server| server.deinit(gpa);
        servers.deinit(gpa);
    }
    // `{env:VAR}` placeholders in command/args/url/headers are stored RAW here
    // and expanded only at connect time (`expandMcpServer`, called by the MCP
    // manager). Keeping the raw placeholder means `serialize` writes the
    // placeholder back to config.json rather than the resolved secret.
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const val = entry.value_ptr.*;

        const cmd = stringField(val, "command");
        const url = stringField(val, "url");
        // Exactly one transport: stdio (command) or remote (url). Both or
        // neither is invalid — mirrors the transport union and the
        // MCPServerConfig oneOf in schema/config.schema.json. Checked before
        // `server`/its errdefer so a rejection never deinits a server whose
        // transport is still undefined.
        if (cmd != null and url != null) return error.InvalidMcpServerConfig;
        if (cmd == null and url == null) return error.InvalidMcpServerConfig;

        var server: McpServerConfig = undefined;
        server.name = try gpa.dupe(u8, entry.key_ptr.*);
        server.enabled = boolField(val, "enabled") orelse true;
        server.request_timeout_ms = u32field(val, "requestTimeoutMs");
        errdefer server.deinit(gpa);

        if (cmd) |c| {
            var args: [][]u8 = &.{};
            if (val.object.get("args")) |args_val| {
                if (args_val == .array) {
                    var args_list: std.ArrayList([]u8) = .empty;
                    errdefer {
                        for (args_list.items) |arg| gpa.free(arg);
                        args_list.deinit(gpa);
                    }
                    for (args_val.array.items) |arg_item| {
                        if (arg_item == .string) {
                            try args_list.append(gpa, try gpa.dupe(u8, arg_item.string));
                        }
                    }
                    args = try args_list.toOwnedSlice(gpa);
                }
            }
            server.transport = .{ .stdio = .{
                .command = try gpa.dupe(u8, c),
                .args = args,
            } };
        } else {
            // url is guaranteed non-null by the guards above (exactly one transport).
            var headers: []McpHeader = &.{};
            if (val.object.get("headers")) |headers_val| {
                if (headers_val == .object) {
                    var headers_list: std.ArrayList(McpHeader) = .empty;
                    errdefer {
                        for (headers_list.items) |h| {
                            gpa.free(h.name);
                            gpa.free(h.value);
                        }
                        headers_list.deinit(gpa);
                    }
                    var header_it = headers_val.object.iterator();
                    while (header_it.next()) |header_entry| {
                        if (header_entry.value_ptr.* != .string) continue;
                        try headers_list.append(gpa, .{
                            .name = try gpa.dupe(u8, header_entry.key_ptr.*),
                            .value = try gpa.dupe(u8, header_entry.value_ptr.string),
                        });
                    }
                    headers = try headers_list.toOwnedSlice(gpa);
                }
            }
            server.transport = .{ .sse = .{
                .url = try gpa.dupe(u8, url.?),
                .headers = headers,
            } };
        }
        try servers.append(gpa, server);
    }
    return try servers.toOwnedSlice(gpa);
}

fn parsePlugins(gpa: std.mem.Allocator, value: std.json.Value) ![]PluginConfig {
    var plugins: std.ArrayList(PluginConfig) = .empty;
    errdefer {
        for (plugins.items) |*plugin| plugin.deinit(gpa);
        plugins.deinit(gpa);
    }
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const val = entry.value_ptr.*;

        var plugin: PluginConfig = .{
            .name = try gpa.dupe(u8, entry.key_ptr.*),
            .enabled = boolField(val, "enabled") orelse true,
        };
        errdefer plugin.deinit(gpa);

        if (stringField(val, "settings")) |s| {
            plugin.settings = try gpa.dupe(u8, s);
        } else if (val.object.get("settings")) |sv| {
            // Inline-object settings are normalized to the canonical JSON
            // string here so both config forms reach the plugin bridge
            // identically (`plugin.get_config()` parses the string). Arrays
            // and other types stay parse-ignored: get_config demands an
            // object, so accepting them would be a half-contract.
            if (sv == .object) {
                var buf: std.Io.Writer.Allocating = .init(gpa);
                defer buf.deinit();
                try std.json.Stringify.value(sv, .{}, &buf.writer);
                plugin.settings = try buf.toOwnedSlice();
            }
        }

        try plugins.append(gpa, plugin);
    }
    return try plugins.toOwnedSlice(gpa);
}

fn parseProviderConfig(gpa: std.mem.Allocator, name: []const u8, provider: Provider, value: std.json.Value) !ProviderConfig {
    var out: ProviderConfig = .{
        .name = try gpa.dupe(u8, name),
        .provider = provider,
    };
    errdefer out.deinit(gpa);
    if (stringFieldCompat(value, "baseURL", "base_url")) |s| out.base_url = .{ .custom = try gpa.dupe(u8, s) };
    if (value.object.get("models")) |models_value| {
        if (models_value == .object) out.models = try parseProviderModels(gpa, models_value);
    }
    return out;
}

fn parseProviderModels(gpa: std.mem.Allocator, value: std.json.Value) ![]ProviderModel {
    var models: std.ArrayList(ProviderModel) = .empty;
    errdefer {
        for (models.items) |*model| model.deinit(gpa);
        models.deinit(gpa);
    }
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const val = entry.value_ptr.*;
        var model: ProviderModel = .{
            .id = try gpa.dupe(u8, entry.key_ptr.*),
            .reasoning = if (stringField(val, "reasoningEffort")) |effort|
                if (reasoning_efforts_by_name.get(effort)) |e| .{ .effort = e } else .unset
            else
                .unset,
        };
        if (u32field(val, "contextWindow")) |v| {
            if (v >= context_window_floor_tokens) model.context_window = v;
        }
        if (u32field(val, "maxOutputTokens")) |v| {
            if (v >= 1) model.max_output_tokens = v;
        }
        if (val.object.get("reasoningOptions")) |opts| {
            if (opts == .array) {
                var list: std.ArrayList(ai.ReasoningEffort) = .empty;
                errdefer list.deinit(gpa);
                for (opts.array.items) |item| {
                    if (item != .string) continue;
                    if (reasoning_efforts_by_name.get(item.string)) |e| {
                        try list.append(gpa, e);
                    }
                }
                if (list.items.len > 0) {
                    model.reasoning_options = try list.toOwnedSlice(gpa);
                }
            }
        }
        try models.append(gpa, model);
    }
    return try models.toOwnedSlice(gpa);
}

fn loadEnv(
    gpa: std.mem.Allocator,
    env: anytype,
    diagnostics: *std.ArrayList(Diagnostic),
) !Config {
    var out: Config = .{};
    errdefer out.deinit(gpa);

    if (env.get("OPENAI_BASE_URL")) |s| out.base_url = try gpa.dupe(u8, s);
    if (env.get("OPENAI_API_KEY")) |s| out.api_key = try gpa.dupe(u8, s);
    if (env.get("NOVA_BASH_CLASSIFIER_URL")) |s| {
        if (s.len > 0) out.bash_classifier_url = try gpa.dupe(u8, s);
    }
    if (env.get("NOVA_USE_RESPONSES_ENDPOINT")) |s| {
        out.use_responses_endpoint = parseBool(s);
    }
    if (env.get("NOVA_STRICT_OUTPUTS")) |s| {
        out.strict_outputs = parseBool(s);
    }
    if (env.get("OPENAI_MODEL")) |raw| {
        if (parseModelSelection(gpa, raw)) |parsed| {
            out.provider_name = parsed.provider_name;
            out.model = parsed.model;
        } else |_| {
            try diagnostics.append(gpa, .{ .bad_env_model = try gpa.dupe(u8, raw) });
        }
    }
    return out;
}

const ParsedModelSelection = struct {
    /// Resolved builtin provider, or `.openai_compatible` for custom names.
    provider: Provider,
    /// The raw provider name as written in the selection string. For
    /// builtins this equals `provider.label()`; for custom providers
    /// it's the user-chosen name (e.g. "qwen-cloud").
    provider_name: []u8,
    model: Model,
};

fn parseModelSelection(gpa: std.mem.Allocator, raw: []const u8) !ParsedModelSelection {
    const slash = std.mem.findScalar(u8, raw, '/') orelse return error.MissingSeparator;
    const provider_part = raw[0..slash];
    const model_part = raw[slash + 1 ..];
    if (provider_part.len == 0) return error.MissingProvider;
    if (model_part.len == 0) return error.MissingModel;
    // Builtin providers resolve to their enum; unknown names are treated
    // as custom providers using the openai_compatible adapter. The name
    // is preserved for display, auth lookup, and providers-map matching.
    const provider = providers_by_name.get(provider_part) orelse .openai_compatible;
    return .{
        .provider = provider,
        .provider_name = try gpa.dupe(u8, provider_part),
        .model = .{ .id = try gpa.dupe(u8, model_part) },
    };
}

fn parseBool(s: []const u8) bool {
    if (std.mem.eql(u8, s, "1")) return true;
    if (std.ascii.eqlIgnoreCase(s, "true")) return true;
    return false;
}

/// Extract the major version number from a semver string ("2.0.0" → 2).
/// Returns null when the string is not a valid semver.
pub fn parseSemverMajor(s: []const u8) ?u32 {
    const dot = std.mem.findScalar(u8, s, '.') orelse {
        // Bare integer ("2") is accepted as major-only.
        return std.fmt.parseInt(u32, s, 10) catch null;
    };
    return std.fmt.parseInt(u32, s[0..dot], 10) catch null;
}

const reasoning_efforts_by_name = std.StaticStringMap(ai.ReasoningEffort).initComptime(.{
    .{ "default", .default },
    .{ "minimal", .minimal },
    .{ "low", .low },
    .{ "none", .none },
    .{ "medium", .medium },
    .{ "high", .high },
    .{ "xhigh", .xhigh },
});

fn intField(value: std.json.Value, name: []const u8) ?i64 {
    const field = value.object.get(name) orelse return null;
    if (field != .integer) return null;
    return field.integer;
}

/// Same as `intField` but narrowed to `u32`. `intField` returns the raw JSON
/// integer as `i64`, so a too-large value (e.g. a config typo like
/// `"maxOutputTokens": 9999999999`) is out of `u32` range. Narrowing with
/// `@intCast` would panic in Debug / silently truncate in ReleaseFast; instead
/// an out-of-range value yields null and is treated as an absent field, the
/// same as a non-integer or below-minimum value. The lower-bound check stays
/// at each call site so per-field minimums are explicit.
fn u32field(value: std.json.Value, name: []const u8) ?u32 {
    const v = intField(value, name) orelse return null;
    return std.math.cast(u32, v);
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    const field = value.object.get(name) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn boolField(value: std.json.Value, name: []const u8) ?bool {
    const field = value.object.get(name) orelse return null;
    if (field != .bool) return null;
    return field.bool;
}

fn floatField(value: std.json.Value, name: []const u8) ?f64 {
    const field = value.object.get(name) orelse return null;
    return switch (field) {
        .float => field.float,
        .integer => @floatFromInt(field.integer),
        else => null,
    };
}

/// Look up a JSON key trying camelCase first, then snake_case fallback.
/// Returns the value from whichever key exists (camelCase wins).
fn fieldCompat(object: std.json.ObjectMap, camel: []const u8, snake: []const u8) ?std.json.Value {
    return object.get(camel) orelse object.get(snake);
}

pub fn writeGlobal(
    gpa: std.mem.Allocator,
    io: std.Io,
    home_dir: []const u8,
    config: Config,
) !void {
    const path = try globalConfigPath(gpa, io, home_dir);
    defer gpa.free(path);

    const dirname = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.Io.Dir.createDirPath(.cwd(), io, dirname);

    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp_path);

    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try serialize(gpa, &payload.writer, config);

    {
        var file = try std.Io.Dir.createFile(.cwd(), io, tmp_path, .{ .truncate = true });
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try writer.interface.writeAll(payload.written());
        try writer.interface.flush();
    }

    try std.Io.Dir.rename(.cwd(), tmp_path, .cwd(), path, io);
}

pub fn readGlobal(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) !Config {
    const path = try globalConfigPath(gpa, io, home_dir);
    defer gpa.free(path);
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (sink.items) |*d| d.deinit(gpa);
        sink.deinit(gpa);
    }
    return loadFile(gpa, io, path, &sink);
}

pub fn mergeAndWriteGlobal(
    gpa: std.mem.Allocator,
    io: std.Io,
    home_dir: []const u8,
    updates: Config,
) !void {
    var current = try readGlobal(gpa, io, home_dir);
    defer current.deinit(gpa);
    try applyConfigOverlay(gpa, &current, updates);
    try writeGlobal(gpa, io, home_dir, current);
}

pub fn readProject(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) !Config {
    const path = try projectConfigPath(gpa, cwd);
    defer gpa.free(path);
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (sink.items) |*d| d.deinit(gpa);
        sink.deinit(gpa);
    }
    return loadFile(gpa, io, path, &sink);
}

pub fn writeProject(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    config: Config,
) !void {
    const path = try projectConfigPath(gpa, cwd);
    defer gpa.free(path);

    const dirname = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.Io.Dir.createDirPath(.cwd(), io, dirname);

    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp_path);

    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try serialize(gpa, &payload.writer, config);

    {
        var file = try std.Io.Dir.createFile(.cwd(), io, tmp_path, .{ .truncate = true });
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try writer.interface.writeAll(payload.written());
        try writer.interface.flush();
    }

    try std.Io.Dir.rename(.cwd(), tmp_path, .cwd(), path, io);
}

pub fn mergeAndWriteProject(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    updates: Config,
) !void {
    var current = try readProject(gpa, io, cwd);
    defer current.deinit(gpa);
    try applyConfigOverlay(gpa, &current, updates);
    try writeProject(gpa, io, cwd, current);
}

pub fn projectConfigExists(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) bool {
    const path = projectConfigPath(gpa, cwd) catch return false;
    defer gpa.free(path);
    std.Io.Dir.access(.cwd(), io, path, .{}) catch return false;
    return true;
}

/// The single seam between an in-memory Config and config.json on disk.
/// Invariant: `api_key` is NEVER written here — API keys live only in
/// auth.json (see auth.ApiKeyMap). This is the one place that enforces it, so
/// callers never have to thread a "should I persist the key?" flag through the
/// merge path. The "serialize: skips api_key even if present" test guards it.
///
/// JSON keys are camelCase (schema v2). Parse accepts both camelCase and
/// legacy snake_case for backward compatibility.
fn serialize(gpa: std.mem.Allocator, writer: *std.Io.Writer, config: Config) !void {
    // Version: semver string.
    try writer.writeAll("{\n  \"version\": ");
    try std.json.Stringify.value(config.version orelse Config.default_version, .{}, writer);
    var wrote_any = true;

    // Prefer the typed `model_selection` when present; fall back to
    // legacy fields for Configs that bypass parseObject (tests).
    // "provider" is NOT written — defaultModel already encodes the
    // provider name as its "provider/model" prefix, and parseObject
    // only reads defaultModel (via parseModelSelection).
    if (config.model_selection) |ms| {
        try writeKey(writer, "defaultModel", &wrote_any);
        try writeModelSelection(gpa, writer, ms.providerName(), ms.model().id);
        if (ms.useResponsesEndpoint()) {
            try writeKey(writer, "useResponsesEndpoint", &wrote_any);
            try writer.writeAll("true");
        }
        if (ms.systemPrompt()) |s| {
            try writeKey(writer, "systemPrompt", &wrote_any);
            try std.json.Stringify.value(s, .{}, writer);
        }
        if (ms.bashClassifierUrl()) |url| {
            try writeKey(writer, "bashClassifierUrl", &wrote_any);
            try std.json.Stringify.value(url, .{}, writer);
        }
        // `strict_outputs` is a global setting (re-synced from cached_config at
        // every client attach), not a model-selection-specific one like the
        // four fields above. `parseObject` doesn't clear `out.strict_outputs`
        // when building `model_selection` (the other four are cleared), so it
        // stays on `config` and is read here. Without this, a user enabling
        // `strictOutputs: true` would see it vanish on the next serialize —
        // `model_selection` is set in normal operation, so the legacy branch
        // below (which does write it) never runs.
        if (config.strict_outputs) |b| {
            try writeKey(writer, "strictOutputs", &wrote_any);
            try writer.writeAll(if (b) "true" else "false");
        }
    } else {
        if (config.use_responses_endpoint) |b| {
            try writeKey(writer, "useResponsesEndpoint", &wrote_any);
            try writer.writeAll(if (b) "true" else "false");
        }
        if (config.strict_outputs) |b| {
            try writeKey(writer, "strictOutputs", &wrote_any);
            try writer.writeAll(if (b) "true" else "false");
        }
        if (config.model) |m| {
            if (config.provider_name) |name| {
                try writeKey(writer, "defaultModel", &wrote_any);
                try writeModelSelection(gpa, writer, name, m.id);
            }
        }
        if (config.system_prompt) |s| {
            try writeKey(writer, "systemPrompt", &wrote_any);
            try std.json.Stringify.value(s, .{}, writer);
        }
        if (config.bash_classifier_url) |url| {
            try writeKey(writer, "bashClassifierUrl", &wrote_any);
            try std.json.Stringify.value(url, .{}, writer);
        }
    }
    if (config.providers.len > 0) {
        try writeKey(writer, "providers", &wrote_any);
        try writeProviders(writer, config.providers);
    }
    if (config.mcp_servers.len > 0) {
        try writeKey(writer, "mcpServers", &wrote_any);
        try writeMcpServers(writer, config.mcp_servers);
    }
    if (config.plugins.len > 0) {
        try writeKey(writer, "plugins", &wrote_any);
        try writePlugins(writer, config.plugins);
    }
    // Context: only written when at least one field differs from defaults.
    if (hasNonDefaultContext(config.context)) {
        try writeKey(writer, "context", &wrote_any);
        try writeContext(writer, config.context);
    }
    // Toast: only written when at least one field differs from defaults.
    if (hasNonDefaultToast(config.toast)) {
        try writeKey(writer, "toast", &wrote_any);
        try writeToast(writer, config.toast);
    }
    // TUI: only written when at least one field differs from defaults.
    if (hasNonDefaultTui(config.tui)) {
        try writeKey(writer, "tui", &wrote_any);
        try writeTui(writer, config.tui);
    }
    // Theme: written when set and non-empty. Absent = default at resolve time.
    if (config.theme) |t| {
        if (t.len > 0) {
            try writeKey(writer, "theme", &wrote_any);
            try std.json.Stringify.value(t, .{}, writer);
        }
    }
    try writer.writeAll("\n}\n");
}

fn hasNonDefaultToast(toast: ToastSettings) bool {
    if (toast.enabled != null) return true;
    if (toast.duration_ms != null) return true;
    if (toast.max_visible != null) return true;
    if (toast.position != null) return true;
    return false;
}

fn writeToast(writer: *std.Io.Writer, toast: ToastSettings) !void {
    try writer.writeByte('{');
    var wrote_any = false;
    if (toast.enabled) |b| {
        try writeKeyNoIndent(writer, "enabled", &wrote_any);
        try writer.writeAll(if (b) "true" else "false");
    }
    if (toast.duration_ms) |v| {
        try writeKeyNoIndent(writer, "durationMs", &wrote_any);
        try writer.print("{d}", .{v});
    }
    if (toast.max_visible) |v| {
        try writeKeyNoIndent(writer, "maxVisible", &wrote_any);
        try writer.print("{d}", .{v});
    }
    if (toast.position) |s| {
        try writeKeyNoIndent(writer, "position", &wrote_any);
        try std.json.Stringify.value(s, .{}, writer);
    }
    try writer.writeByte('}');
}

fn hasNonDefaultTui(tui: TuiSettings) bool {
    if (tui.theme_live_preview != default_tui.theme_live_preview) return true;
    if (tui.custom_themes_dir != null) return true;
    if (tui.fuzzy_highlight != default_tui.fuzzy_highlight) return true;
    if (tui.fuzzy_highlight_style != default_tui.fuzzy_highlight_style) return true;
    if (tui.split_mode != default_tui.split_mode) return true;
    if (tui.min_split_width != default_tui.min_split_width) return true;
    if (tui.highlight_focused_border != default_tui.highlight_focused_border) return true;
    if (tui.show_token_velocity != default_tui.show_token_velocity) return true;
    if (tui.show_context_meter != default_tui.show_context_meter) return true;
    if (tui.velocity_smoothing_alpha != default_tui.velocity_smoothing_alpha) return true;
    if (tui.context_threshold_warn != default_tui.context_threshold_warn) return true;
    if (tui.context_threshold_alert != default_tui.context_threshold_alert) return true;
    return false;
}

fn writeTui(writer: *std.Io.Writer, tui: TuiSettings) !void {
    try writer.writeByte('{');
    var wrote_any = false;
    if (tui.theme_live_preview != default_tui.theme_live_preview) {
        try writeKeyNoIndent(writer, "themeLivePreview", &wrote_any);
        try writer.writeAll(if (tui.theme_live_preview) "true" else "false");
    }
    if (tui.custom_themes_dir) |s| {
        try writeKeyNoIndent(writer, "customThemesDir", &wrote_any);
        try std.json.Stringify.value(s, .{}, writer);
    }
    if (tui.fuzzy_highlight != default_tui.fuzzy_highlight) {
        try writeKeyNoIndent(writer, "fuzzyHighlight", &wrote_any);
        try writer.writeAll(if (tui.fuzzy_highlight) "true" else "false");
    }
    if (tui.fuzzy_highlight_style != default_tui.fuzzy_highlight_style) {
        try writeKeyNoIndent(writer, "fuzzyHighlightStyle", &wrote_any);
        try std.json.Stringify.value(@tagName(tui.fuzzy_highlight_style), .{}, writer);
    }
    if (tui.split_mode != default_tui.split_mode) {
        try writeKeyNoIndent(writer, "splitMode", &wrote_any);
        try std.json.Stringify.value(@tagName(tui.split_mode), .{}, writer);
    }
    if (tui.min_split_width != default_tui.min_split_width) {
        try writeKeyNoIndent(writer, "minSplitWidth", &wrote_any);
        try writer.print("{d}", .{tui.min_split_width});
    }
    if (tui.highlight_focused_border != default_tui.highlight_focused_border) {
        try writeKeyNoIndent(writer, "highlightFocusedBorder", &wrote_any);
        try writer.writeAll(if (tui.highlight_focused_border) "true" else "false");
    }
    if (tui.show_token_velocity != default_tui.show_token_velocity) {
        try writeKeyNoIndent(writer, "showTokenVelocity", &wrote_any);
        try writer.writeAll(if (tui.show_token_velocity) "true" else "false");
    }
    if (tui.show_context_meter != default_tui.show_context_meter) {
        try writeKeyNoIndent(writer, "showContextMeter", &wrote_any);
        try writer.writeAll(if (tui.show_context_meter) "true" else "false");
    }
    if (tui.velocity_smoothing_alpha != default_tui.velocity_smoothing_alpha) {
        try writeKeyNoIndent(writer, "velocitySmoothingAlpha", &wrote_any);
        try writer.print("{d:.2}", .{tui.velocity_smoothing_alpha});
    }
    if (tui.context_threshold_warn != default_tui.context_threshold_warn) {
        try writeKeyNoIndent(writer, "contextThresholdWarn", &wrote_any);
        try writer.print("{d:.2}", .{tui.context_threshold_warn});
    }
    if (tui.context_threshold_alert != default_tui.context_threshold_alert) {
        try writeKeyNoIndent(writer, "contextThresholdAlert", &wrote_any);
        try writer.print("{d:.2}", .{tui.context_threshold_alert});
    }
    try writer.writeByte('}');
}

fn hasNonDefaultContext(ctx: ContextSettings) bool {
    const d: ContextSettings = .{};
    if (ctx.override_context_window != null) return true;
    if (ctx.max_output_tokens != null) return true;
    if (ctx.max_parallel_tool_calls != null) return true;
    if (ctx.request_timeout_seconds != null) return true;
    if (ctx.max_concurrent_requests != null) return true;
    if (ctx.disable_prompt_cache != null) return true;
    if (ctx.tool_call_limit_per_turn != null) return true;
    if (ctx.soft_stop_on_tool_call_limit != null) return true;
    if (ctx.compaction.auto != d.compaction.auto) return true;
    if (ctx.compaction.threshold != d.compaction.threshold) return true;
    if (ctx.compaction.keep_recent_tokens != d.compaction.keep_recent_tokens) return true;
    if (ctx.compaction.keep_recent_tool_turns != d.compaction.keep_recent_tool_turns) return true;
    if (ctx.compaction.historical_tool_cap_bytes != d.compaction.historical_tool_cap_bytes) return true;
    return false;
}

fn writeContext(writer: *std.Io.Writer, ctx: ContextSettings) !void {
    try writer.writeByte('{');
    var wrote_any = false;
    if (ctx.override_context_window) |v| {
        try writeKeyNoIndent(writer, "overrideContextWindow", &wrote_any);
        try writer.print("{d}", .{v});
    }
    if (ctx.max_output_tokens) |v| {
        try writeKeyNoIndent(writer, "maxOutputTokens", &wrote_any);
        try writer.print("{d}", .{v});
    }
    if (ctx.max_parallel_tool_calls) |v| {
        try writeKeyNoIndent(writer, "maxParallelToolCalls", &wrote_any);
        try writer.print("{d}", .{v});
    }
    if (ctx.request_timeout_seconds) |v| {
        try writeKeyNoIndent(writer, "requestTimeoutSeconds", &wrote_any);
        try writer.print("{d}", .{v});
    }
    if (ctx.max_concurrent_requests) |v| {
        try writeKeyNoIndent(writer, "maxConcurrentRequests", &wrote_any);
        try writer.print("{d}", .{v});
    }
    if (ctx.disable_prompt_cache) |b| {
        try writeKeyNoIndent(writer, "disablePromptCache", &wrote_any);
        try writer.writeAll(if (b) "true" else "false");
    }
    if (ctx.tool_call_limit_per_turn) |v| {
        try writeKeyNoIndent(writer, "toolCallLimitPerTurn", &wrote_any);
        try writer.print("{d}", .{v});
    }
    if (ctx.soft_stop_on_tool_call_limit) |b| {
        try writeKeyNoIndent(writer, "softStopOnToolCallLimit", &wrote_any);
        try writer.writeAll(if (b) "true" else "false");
    }
    // Compaction: always written when context is present.
    try writeKeyNoIndent(writer, "compaction", &wrote_any);
    try writeCompaction(writer, ctx.compaction);
    try writer.writeByte('}');
}

fn writeCompaction(writer: *std.Io.Writer, comp: CompactionSettings) !void {
    try writer.writeByte('{');
    var wrote_any = false;
    if (!comp.auto) {
        try writeKeyNoIndent(writer, "auto", &wrote_any);
        try writer.writeAll("false");
    }
    {
        try writeKeyNoIndent(writer, "threshold", &wrote_any);
        try writer.print("{d:.2}", .{comp.threshold});
    }
    {
        try writeKeyNoIndent(writer, "keepRecentTokens", &wrote_any);
        try writer.print("{d}", .{comp.keep_recent_tokens});
    }
    const d: CompactionSettings = .{};
    if (comp.keep_recent_tool_turns != d.keep_recent_tool_turns) {
        try writeKeyNoIndent(writer, "keepRecentToolTurns", &wrote_any);
        try writer.print("{d}", .{comp.keep_recent_tool_turns});
    }
    if (comp.historical_tool_cap_bytes != d.historical_tool_cap_bytes) {
        try writeKeyNoIndent(writer, "historicalToolCapBytes", &wrote_any);
        try writer.print("{d}", .{comp.historical_tool_cap_bytes});
    }
    try writer.writeByte('}');
}

fn writeModelSelection(gpa: std.mem.Allocator, writer: *std.Io.Writer, provider_name: []const u8, model_id: []const u8) !void {
    const selection = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ provider_name, model_id });
    defer gpa.free(selection);
    try std.json.Stringify.value(selection, .{}, writer);
}

fn writeProviders(writer: *std.Io.Writer, providers: []const ProviderConfig) !void {
    try writer.writeByte('{');
    var wrote_provider = false;
    for (providers) |provider| {
        if (wrote_provider) try writer.writeByte(',');
        try std.json.Stringify.value(provider.name, .{}, writer);
        try writer.writeByte(':');
        try writeProvider(writer, provider);
        wrote_provider = true;
    }
    try writer.writeByte('}');
}

fn writeProvider(writer: *std.Io.Writer, provider: ProviderConfig) !void {
    try writer.writeByte('{');
    var wrote_any = false;
    switch (provider.base_url) {
        .custom => |base_url| {
            try writeKeyNoIndent(writer, "baseURL", &wrote_any);
            try std.json.Stringify.value(base_url, .{}, writer);
        },
        .default => {},
    }
    if (provider.models.len > 0) {
        try writeKey(writer, "models", &wrote_any);
        try writeProviderModels(writer, provider.models);
    }
    try writer.writeByte('}');
}

fn writeProviderModels(writer: *std.Io.Writer, models: []const ProviderModel) !void {
    try writer.writeByte('{');
    var wrote_model = false;
    for (models) |model| {
        if (wrote_model) try writer.writeByte(',');
        try std.json.Stringify.value(model.id, .{}, writer);
        try writer.writeByte(':');
        try writer.writeByte('{');
        var wrote_field = false;
        if (model.reasoning == .effort) {
            try std.json.Stringify.value("reasoningEffort", .{}, writer);
            try writer.writeByte(':');
            try std.json.Stringify.value(model.reasoning.effort.label(), .{}, writer);
            wrote_field = true;
        }
        if (model.context_window) |cw| {
            if (wrote_field) try writer.writeByte(',');
            try std.json.Stringify.value("contextWindow", .{}, writer);
            try writer.writeByte(':');
            try writer.print("{d}", .{cw});
            wrote_field = true;
        }
        if (model.max_output_tokens) |mot| {
            if (wrote_field) try writer.writeByte(',');
            try std.json.Stringify.value("maxOutputTokens", .{}, writer);
            try writer.writeByte(':');
            try writer.print("{d}", .{mot});
            wrote_field = true;
        }
        if (model.reasoning_options.len > 0) {
            if (wrote_field) try writer.writeByte(',');
            try std.json.Stringify.value("reasoningOptions", .{}, writer);
            try writer.writeByte(':');
            try writer.writeByte('[');
            for (model.reasoning_options, 0..) |opt, idx| {
                if (idx > 0) try writer.writeByte(',');
                try std.json.Stringify.value(opt.label(), .{}, writer);
            }
            try writer.writeByte(']');
        }
        try writer.writeByte('}');
        wrote_model = true;
    }
    try writer.writeByte('}');
}

fn writeMcpServers(writer: *std.Io.Writer, servers: []const McpServerConfig) !void {
    try writer.writeByte('{');
    var wrote_server = false;
    for (servers) |server| {
        if (wrote_server) try writer.writeByte(',');
        try std.json.Stringify.value(server.name, .{}, writer);
        try writer.writeByte(':');
        try writeMcpServer(writer, server);
        wrote_server = true;
    }
    try writer.writeByte('}');
}

fn writeMcpServer(writer: *std.Io.Writer, server: McpServerConfig) !void {
    try writer.writeByte('{');
    var wrote_any = false;
    switch (server.transport) {
        .stdio => |t| {
            try writeKeyNoIndent(writer, "command", &wrote_any);
            try std.json.Stringify.value(t.command, .{}, writer);
            if (t.args.len > 0) {
                try writeKeyNoIndent(writer, "args", &wrote_any);
                try writer.writeByte('[');
                for (t.args, 0..) |arg, i| {
                    if (i > 0) try writer.writeByte(',');
                    try std.json.Stringify.value(arg, .{}, writer);
                }
                try writer.writeByte(']');
            }
        },
        .sse => |t| {
            try writeKeyNoIndent(writer, "url", &wrote_any);
            try std.json.Stringify.value(t.url, .{}, writer);
            // Headers are written back RAW (placeholder preserved) so a settings
            // save never drops them nor leaks a resolved secret to disk. Mirrors
            // the parser, which reads this same `headers` object.
            if (t.headers.len > 0) {
                try writeKeyNoIndent(writer, "headers", &wrote_any);
                try writer.writeByte('{');
                for (t.headers, 0..) |h, i| {
                    if (i > 0) try writer.writeByte(',');
                    try std.json.Stringify.value(h.name, .{}, writer);
                    try writer.writeByte(':');
                    try std.json.Stringify.value(h.value, .{}, writer);
                }
                try writer.writeByte('}');
            }
        },
    }
    if (!server.enabled) {
        try writeKeyNoIndent(writer, "enabled", &wrote_any);
        try writer.writeAll("false");
    }
    if (server.request_timeout_ms) |ms| {
        try writeKeyNoIndent(writer, "requestTimeoutMs", &wrote_any);
        try writer.print("{d}", .{ms});
    }
    try writer.writeByte('}');
}

fn writePlugins(writer: *std.Io.Writer, plugins: []const PluginConfig) !void {
    try writer.writeByte('{');
    var wrote_plugin = false;
    for (plugins) |plugin| {
        if (wrote_plugin) try writer.writeByte(',');
        try std.json.Stringify.value(plugin.name, .{}, writer);
        try writer.writeByte(':');
        try writePlugin(writer, plugin);
        wrote_plugin = true;
    }
    try writer.writeByte('}');
}

fn writePlugin(writer: *std.Io.Writer, plugin: PluginConfig) !void {
    try writer.writeByte('{');
    var wrote_any = false;
    if (!plugin.enabled) {
        try writeKeyNoIndent(writer, "enabled", &wrote_any);
        try writer.writeAll("false");
    }
    if (plugin.settings.len > 0) {
        try writeKeyNoIndent(writer, "settings", &wrote_any);
        try std.json.Stringify.value(plugin.settings, .{}, writer);
    }
    try writer.writeByte('}');
}

fn writeKeyNoIndent(writer: *std.Io.Writer, name: []const u8, wrote_any: *bool) !void {
    if (wrote_any.*) try writer.writeByte(',');
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeByte(':');
    wrote_any.* = true;
}

fn writeKey(writer: *std.Io.Writer, name: []const u8, wrote_any: *bool) !void {
    if (wrote_any.*) try writer.writeByte(',');
    try writer.writeAll("\n  ");
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeAll(": ");
    wrote_any.* = true;
}

pub fn globalConfigPath(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) ![]u8 {
    if (home_dir.len == 0) return error.HomeNotSet;

    // Platform-correct base: Windows -> %APPDATA%\nova, POSIX -> ~/.config/nova.
    // (See paths.platformConfigDir; matches the plugin-discovery probe.)
    const base = try paths.platformConfigDir(gpa, home_dir);
    errdefer gpa.free(base);
    const config_path = try std.fs.path.join(gpa, &.{ base, "config.json" });
    gpa.free(base);
    errdefer gpa.free(config_path);

    // Prefer an existing platform-correct config file.
    if (std.Io.Dir.access(.cwd(), io, config_path, .{})) |_| {
        return config_path;
    } else |_| {}

    // Backward-compat: a legacy XDG layout (~/.config/nova/config.json) may exist
    // on a POSIX system whose home prefix differs from platformConfigDir's base.
    // (No-op on the common path — platformConfigDir already returns ~/.config/nova
    // there — but harmless and keeps old installs readable.) Only probed when the
    // platform-correct file is absent.
    const xdg_path = try std.fs.path.join(gpa, &.{ home_dir, ".config", "nova", "config.json" });
    errdefer gpa.free(xdg_path);

    if (std.Io.Dir.access(.cwd(), io, xdg_path, .{})) |_| {
        gpa.free(config_path);
        return xdg_path;
    } else |_| {}

    // No existing file: return the platform-correct path so new writes land there.
    gpa.free(xdg_path);
    return config_path;
}

fn projectConfigPath(gpa: std.mem.Allocator, cwd: []const u8) ![]u8 {
    if (cwd.len == 0) return error.InvalidPath;
    return std.fs.path.join(gpa, &.{ cwd, ".nova", "config.json" });
}

const TestEnv = struct {
    entries: []const Entry,

    const Entry = struct { key: []const u8, value: []const u8 };

    pub fn get(self: TestEnv, key: []const u8) ?[]const u8 {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }
};

test "providers_by_name recognizes known vendor names" {
    try std.testing.expectEqual(Provider.openai, providers_by_name.get("openai").?);
    try std.testing.expectEqual(Provider.openai_compatible, providers_by_name.get("openai_compatible").?);
    try std.testing.expectEqual(Provider.ollama, providers_by_name.get("ollama").?);
    try std.testing.expectEqual(Provider.llama_cpp, providers_by_name.get("llama.cpp").?);
    try std.testing.expectEqual(Provider.openrouter, providers_by_name.get("openrouter").?);
    try std.testing.expectEqual(Provider.cerebras, providers_by_name.get("cerebras").?);
    try std.testing.expectEqual(Provider.ollama_cloud, providers_by_name.get("ollama_cloud").?);
    try std.testing.expectEqual(Provider.huggingface, providers_by_name.get("huggingface").?);
    try std.testing.expectEqual(Provider.nvidia_nim, providers_by_name.get("nvidia_nim").?);
    try std.testing.expectEqual(Provider.opencode_zen, providers_by_name.get("opencode_zen").?);
    try std.testing.expectEqual(Provider.anthropic, providers_by_name.get("anthropic").?);
    try std.testing.expectEqual(@as(?Provider, null), providers_by_name.get("mystery"));
}

test "every catalogue provider round-trips through providers_by_name and has a base url" {
    for (catalogueProviders()) |provider| {
        try std.testing.expectEqual(provider, providers_by_name.get(provider.label()).?);
        try std.testing.expect(provider.defaultBaseUrl() != null);
        try std.testing.expectEqual(AdapterKind.openai_compatible, provider.adapter().?);
    }
    // OpenCode Zen is the one catalogue provider with an anonymous (free) tier.
    try std.testing.expect(!Provider.opencode_zen.requiresApiKey());
    try std.testing.expectEqualStrings("public", Provider.opencode_zen.anonymousApiKey().?);
    try std.testing.expect(Provider.cerebras.requiresApiKey());
    try std.testing.expectEqual(@as(?[]const u8, null), Provider.cerebras.anonymousApiKey());
}

test "Provider.adapter returns null for unimplemented anthropic" {
    try std.testing.expectEqual(AdapterKind.codex_responses, Provider.openai.adapter().?);
    try std.testing.expectEqual(AdapterKind.openai_compatible, Provider.ollama.adapter().?);
    try std.testing.expectEqual(@as(?AdapterKind, null), Provider.anthropic.adapter());
}

test "parseContext drops integer fields outside u32 range instead of truncating" {
    // A config typo like `"maxOutputTokens": 9999999999` is a valid i64 but
    // overflows u32. It must be dropped (left null) rather than panicking on
    // @intCast (Debug) or silently truncating to 1410065407 (ReleaseFast).
    const json =
        \\{"maxOutputTokens":9999999999,"requestTimeoutSeconds":5000000000,"maxParallelToolCalls":8}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const ctx = parseContext(parsed.value);
    try std.testing.expectEqual(@as(?u32, null), ctx.max_output_tokens);
    try std.testing.expectEqual(@as(?u32, null), ctx.request_timeout_seconds);
    // An in-range value is still applied.
    try std.testing.expectEqual(@as(?u32, 8), ctx.max_parallel_tool_calls);
}

test "parseContext accepts tool budget keys in both cases, drops out-of-range" {
    const json =
        \\{"toolCallLimitPerTurn":250,"softStopOnToolCallLimit":false}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const ctx = parseContext(parsed.value);
    try std.testing.expectEqual(@as(?u32, 250), ctx.tool_call_limit_per_turn);
    try std.testing.expectEqual(@as(?bool, false), ctx.soft_stop_on_tool_call_limit);

    // snake_case aliases parse to the same fields.
    const snake_json =
        \\{"tool_call_limit_per_turn":40,"soft_stop_on_tool_call_limit":true}
    ;
    const snake_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, snake_json, .{});
    defer snake_parsed.deinit();
    const snake_ctx = parseContext(snake_parsed.value);
    try std.testing.expectEqual(@as(?u32, 40), snake_ctx.tool_call_limit_per_turn);
    try std.testing.expectEqual(@as(?bool, true), snake_ctx.soft_stop_on_tool_call_limit);

    // Out-of-band values are dropped (stay null → defaults), never clamped.
    const bad_json =
        \\{"toolCallLimitPerTurn":1001,"softStopOnToolCallLimit":true}
    ;
    const bad_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bad_json, .{});
    defer bad_parsed.deinit();
    const bad_ctx = parseContext(bad_parsed.value);
    try std.testing.expectEqual(@as(?u32, null), bad_ctx.tool_call_limit_per_turn);
    try std.testing.expectEqual(@as(?bool, true), bad_ctx.soft_stop_on_tool_call_limit);

    const zero_json =
        \\{"toolCallLimitPerTurn":0}
    ;
    const zero_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, zero_json, .{});
    defer zero_parsed.deinit();
    try std.testing.expectEqual(@as(?u32, null), parseContext(zero_parsed.value).tool_call_limit_per_turn);

    // A value beyond u32 (a config typo) is dropped, not truncated.
    const huge_json =
        \\{"toolCallLimitPerTurn":9999999999}
    ;
    const huge_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, huge_json, .{});
    defer huge_parsed.deinit();
    try std.testing.expectEqual(@as(?u32, null), parseContext(huge_parsed.value).tool_call_limit_per_turn);
}

test "parseCompaction drops integer fields outside u32 range instead of truncating" {
    const json = "{\"keepRecentTokens\":4294967296,\"keepRecentToolTurns\":3}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const comp = parseCompaction(parsed.value);
    // 4294967296 > u32 max → dropped, so the field keeps its 8_000 default
    // (not 0, and not a truncated value).
    try std.testing.expectEqual(@as(u32, 8_000), comp.keep_recent_tokens);
    try std.testing.expectEqual(@as(u32, 3), comp.keep_recent_tool_turns); // in-range kept
}

test "parseModelSelection: valid <provider>/<model>" {
    const gpa = std.testing.allocator;
    var parsed = try parseModelSelection(gpa, "openai/gpt-5.5");
    defer parsed.model.deinit(gpa);
    defer gpa.free(parsed.provider_name);
    try std.testing.expectEqual(Provider.openai, parsed.provider);
    try std.testing.expectEqualStrings("openai", parsed.provider_name);
    try std.testing.expectEqualStrings("gpt-5.5", parsed.model.id);
}

test "parseModelSelection: ollama/llama3.1:8b" {
    const gpa = std.testing.allocator;
    var parsed = try parseModelSelection(gpa, "ollama/llama3.1:8b");
    defer parsed.model.deinit(gpa);
    defer gpa.free(parsed.provider_name);
    try std.testing.expectEqual(Provider.ollama, parsed.provider);
    try std.testing.expectEqualStrings("llama3.1:8b", parsed.model.id);
}

test "parseModelSelection: missing slash is error" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.MissingSeparator, parseModelSelection(gpa, "gpt-5.5"));
}

test "parseModelSelection: model id may contain slashes" {
    const gpa = std.testing.allocator;
    var parsed = try parseModelSelection(gpa, "openrouter/anthropic/claude-3.7-sonnet");
    defer parsed.model.deinit(gpa);
    defer gpa.free(parsed.provider_name);
    try std.testing.expectEqual(Provider.openrouter, parsed.provider);
    try std.testing.expectEqualStrings("anthropic/claude-3.7-sonnet", parsed.model.id);
}

test "parseModelSelection: unknown provider resolves to openai_compatible" {
    const gpa = std.testing.allocator;
    var parsed = try parseModelSelection(gpa, "qwen-cloud/qwen-plus");
    defer parsed.model.deinit(gpa);
    defer gpa.free(parsed.provider_name);
    try std.testing.expectEqual(Provider.openai_compatible, parsed.provider);
    try std.testing.expectEqualStrings("qwen-cloud", parsed.provider_name);
    try std.testing.expectEqualStrings("qwen-plus", parsed.model.id);
}

test "parseModelSelection: anthropic parses (validity checked downstream)" {
    const gpa = std.testing.allocator;
    var parsed = try parseModelSelection(gpa, "anthropic/claude-3.7-sonnet");
    defer parsed.model.deinit(gpa);
    defer gpa.free(parsed.provider_name);
    try std.testing.expectEqual(Provider.anthropic, parsed.provider);
}

test "parseObject: minimal config" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var cfg = try parseFile(gpa, "<test>", "{\"model\":\"ollama/llama3.1:8b\"}", &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(Provider.ollama, cfg.providerFromName().?);
    try std.testing.expectEqualStrings("llama3.1:8b", cfg.model.?.id);
    try std.testing.expectEqual(@as(usize, 0), sink.items.len);
}

test "parseFile is pure; merge hydrates model reasoningEffort from providers" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var cfg = try parseFile(gpa, "<test>", "{\"model\":\"openai/gpt-5.5\",\"providers\":{\"openai\":{\"models\":{\"gpt-5.5\":{\"reasoningEffort\":\"high\"}}}}}", &sink);
    defer cfg.deinit(gpa);
    // Parsing one layer never reaches into the provider catalogue.
    try std.testing.expectEqual(ReasoningSetting.unset, cfg.model.?.reasoning);
    // Merging hydrates the active model against the parsed providers.
    var merged = try mergeLayers(gpa, &.{cfg});
    defer merged.deinit(gpa);
    try std.testing.expectEqual(ai.ReasoningEffort.high, merged.model.?.reasoning.effort);
}

test "parseObject: unknown provider resolves to openai_compatible custom" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (sink.items) |*d| d.deinit(gpa);
        sink.deinit(gpa);
    }
    var cfg = try parseFile(gpa, "<test>", "{\"defaultModel\":\"qwen-cloud/qwen-plus\"}", &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(Provider.openai_compatible, cfg.providerFromName().?);
    try std.testing.expectEqualStrings("qwen-cloud", cfg.provider_name.?);
    try std.testing.expectEqualStrings("qwen-plus", cfg.model.?.id);
    try std.testing.expectEqual(@as(usize, 0), sink.items.len);
}

test "parseObject: invalid JSON records diagnostic" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (sink.items) |*d| d.deinit(gpa);
        sink.deinit(gpa);
    }
    var cfg = try parseFile(gpa, "<test>", "not json", &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(?Provider, null), cfg.providerFromName());
    try std.testing.expectEqual(@as(usize, 1), sink.items.len);
}

test "parseMcpServers rejects a server config missing a transport" {
    // A server with neither `command` nor `url` is rejected at parse time:
    // the transport union makes the misconfiguration unrepresentable in the
    // struct form, so the manager never needs a runtime fallback. The error
    // propagates up through the public parseFile → parseObject path.
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const config_json =
        \\{
        \\  "mcpServers": {
        \\    "broken_server": {
        \\      "env": { "FOO": "bar" }
        \\    }
        \\  }
        \\}
    ;
    try std.testing.expectError(
        error.InvalidMcpServerConfig,
        parseFile(gpa, "<test>", config_json, &sink),
    );
}

test "mergeLayers: later layer overrides earlier" {
    const gpa = std.testing.allocator;
    var layer1: Config = .{
        .provider_name = try gpa.dupe(u8, "openai"),
        .base_url = try gpa.dupe(u8, "http://layer1"),
        .model = .{ .id = try gpa.dupe(u8, "m1"), .reasoning = .{ .effort = .low } },
    };
    defer layer1.deinit(gpa);
    var layer2: Config = .{
        .base_url = try gpa.dupe(u8, "http://layer2"),
    };
    defer layer2.deinit(gpa);

    var merged = try mergeLayers(gpa, &.{ layer1, layer2 });
    defer merged.deinit(gpa);

    try std.testing.expectEqual(Provider.openai, merged.providerFromName().?);
    try std.testing.expectEqualStrings("http://layer2", merged.base_url.?);
    try std.testing.expectEqualStrings("m1", merged.model.?.id);
    try std.testing.expectEqual(ai.ReasoningEffort.low, merged.model.?.reasoning.effort);
}

test "mergeLayers: model is indivisible — higher layer's model replaces whole" {
    const gpa = std.testing.allocator;
    var layer1: Config = .{
        .model = .{ .id = try gpa.dupe(u8, "m1"), .reasoning = .{ .effort = .high } },
    };
    defer layer1.deinit(gpa);
    var layer2: Config = .{
        .model = .{ .id = try gpa.dupe(u8, "m2") }, // no reasoning
    };
    defer layer2.deinit(gpa);

    var merged = try mergeLayers(gpa, &.{ layer1, layer2 });
    defer merged.deinit(gpa);

    try std.testing.expectEqualStrings("m2", merged.model.?.id);
    // Higher layer's model replaces whole — lower layer's reasoning
    // does NOT survive, because model is indivisible during merge.
    try std.testing.expectEqual(ReasoningSetting.unset, merged.model.?.reasoning);
}

test "loadEnv: OPENAI_MODEL sets both provider and model" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const env: TestEnv = .{ .entries = &.{
        .{ .key = "OPENAI_MODEL", .value = "openai/gpt-5.5" },
    } };
    var cfg = try loadEnv(gpa, env, &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(Provider.openai, cfg.providerFromName().?);
    try std.testing.expectEqualStrings("gpt-5.5", cfg.model.?.id);
}

test "loadEnv: malformed OPENAI_MODEL records diagnostic, does not set fields" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (sink.items) |*d| d.deinit(gpa);
        sink.deinit(gpa);
    }
    const env: TestEnv = .{ .entries = &.{
        .{ .key = "OPENAI_MODEL", .value = "gpt-5.5" },
    } };
    var cfg = try loadEnv(gpa, env, &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(?Provider, null), cfg.providerFromName());
    try std.testing.expectEqual(@as(?Model, null), cfg.model);
    try std.testing.expectEqual(@as(usize, 1), sink.items.len);
    try std.testing.expect(sink.items[0] == .bad_env_model);
    try std.testing.expectEqualStrings("gpt-5.5", sink.items[0].bad_env_model);
}

test "loadEnv: NOVA_USE_RESPONSES_ENDPOINT parses bools" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const env: TestEnv = .{ .entries = &.{
        .{ .key = "NOVA_USE_RESPONSES_ENDPOINT", .value = "1" },
    } };
    var cfg = try loadEnv(gpa, env, &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(true, cfg.use_responses_endpoint.?);
}

test "serialize: skips api_key even if present" {
    const gpa = std.testing.allocator;
    var provider_models = try gpa.alloc(ProviderModel, 1);
    provider_models[0] = .{ .id = try gpa.dupe(u8, "gpt-5.5"), .reasoning = .{ .effort = .medium } };
    var providers = try gpa.alloc(ProviderConfig, 1);
    providers[0] = .{ .name = try gpa.dupe(u8, "openai"), .provider = .openai, .models = provider_models };
    var cfg: Config = .{
        .provider_name = try gpa.dupe(u8, "openai"),
        .api_key = try gpa.dupe(u8, "sk-should-never-appear"),
        .model = .{ .id = try gpa.dupe(u8, "gpt-5.5"), .reasoning = .{ .effort = .medium } },
        .providers = providers,
    };
    defer cfg.deinit(gpa);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try serialize(gpa, &buf.writer, cfg);

    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "api_key") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "sk-should-never-appear") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "\"defaultModel\": \"openai/gpt-5.5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "\"openai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "\"reasoningEffort\":\"medium\"") != null);
}

test "mergeLayers: later layers win for scalar fields" {
    const gpa = std.testing.allocator;
    var global: Config = .{ .provider_name = try gpa.dupe(u8, "openai"), .base_url = try gpa.dupe(u8, "https://global") };
    defer global.deinit(gpa);
    var project: Config = .{ .base_url = try gpa.dupe(u8, "https://project") };
    defer project.deinit(gpa);
    var env: Config = .{ .base_url = try gpa.dupe(u8, "https://env") };
    defer env.deinit(gpa);

    // Least-to-most-specific: env is applied last and wins; provider survives
    // from the only layer that set it.
    var merged = try mergeLayers(gpa, &.{ global, project, env });
    defer merged.deinit(gpa);

    try std.testing.expectEqual(Provider.openai, merged.providerFromName().?);
    try std.testing.expectEqualStrings("https://env", merged.base_url.?);
}

test "mergeLayers: active model is hydrated from the merged provider list" {
    const gpa = std.testing.allocator;
    // The provider catalogue entry (reasoning + base_url) comes from one layer...
    const models = try gpa.alloc(ProviderModel, 1);
    models[0] = .{ .id = try gpa.dupe(u8, "gpt-5.5"), .reasoning = .{ .effort = .medium } };
    const providers = try gpa.alloc(ProviderConfig, 1);
    providers[0] = .{ .name = try gpa.dupe(u8, "openai"), .provider = .openai, .base_url = .{ .custom = try gpa.dupe(u8, "https://from-provider") }, .models = models };
    var global: Config = .{ .providers = providers };
    defer global.deinit(gpa);
    // ...the active model selection comes from another, carrying no reasoning.
    var project: Config = .{ .provider_name = try gpa.dupe(u8, "openai"), .model = .{ .id = try gpa.dupe(u8, "gpt-5.5") } };
    defer project.deinit(gpa);

    var merged = try mergeLayers(gpa, &.{ global, project });
    defer merged.deinit(gpa);

    // Hydration runs once over the merged providers, so the cross-layer match
    // copies reasoning effort and base_url onto the chosen model.
    try std.testing.expectEqual(ai.ReasoningEffort.medium, merged.model.?.reasoning.effort);
    try std.testing.expectEqualStrings("https://from-provider", merged.base_url.?);
}

test "serialize then parse roundtrips" {
    const gpa = std.testing.allocator;
    var provider_models = try gpa.alloc(ProviderModel, 1);
    provider_models[0] = .{ .id = try gpa.dupe(u8, "llama3.1:8b") };
    var providers = try gpa.alloc(ProviderConfig, 1);
    providers[0] = .{
        .name = try gpa.dupe(u8, "ollama"),
        .provider = .ollama,
        .base_url = .{ .custom = try gpa.dupe(u8, "http://localhost:11434/v1") },
        .models = provider_models,
    };
    var original: Config = .{
        .provider_name = try gpa.dupe(u8, "ollama"),
        .base_url = try gpa.dupe(u8, "http://localhost:11434/v1"),
        .use_responses_endpoint = false,
        .strict_outputs = true,
        .model = .{ .id = try gpa.dupe(u8, "llama3.1:8b") },
        .providers = providers,
    };
    defer original.deinit(gpa);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try serialize(gpa, &buf.writer, original);

    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var parsed = try parseFile(gpa, "<test>", buf.written(), &sink);
    defer parsed.deinit(gpa);
    // base_url is not serialized; it is rehydrated from the provider entry when
    // the parsed layer is merged.
    var roundtrip = try mergeLayers(gpa, &.{parsed});
    defer roundtrip.deinit(gpa);

    try std.testing.expectEqual(Provider.ollama, roundtrip.providerFromName().?);
    try std.testing.expectEqualStrings("http://localhost:11434/v1", roundtrip.base_url.?);
    try std.testing.expectEqual(false, roundtrip.use_responses_endpoint.?);
    try std.testing.expectEqual(true, roundtrip.strict_outputs.?);
    try std.testing.expectEqualStrings("llama3.1:8b", roundtrip.model.?.id);
}

test "serialize writes strictOutputs even when model_selection is set" {
    // Regression: serialize'in `model_selection` kolu (normal üretim durumu)
    // eskiden useResponsesEndpoint/systemPrompt/bashClassifierUrl
    // yazıyordu ama strictOutputs'u yazmıyordu — yalnızca legacy kol (model_selection
    // null iken) yazıyordu. Üretimde model_selection set olduğu için kullanıcı
    // strictOutputs: true ayarlasa bile config'e kayboluyor, restart'ta false'a
    // düşüyordu. strict_outputs global bir ayardır (model_selection'a bağlı değil),
    // bu yüzden config.strict_outputs'tan doğrudan okunur.
    const gpa = std.testing.allocator;
    var cfg: Config = .{};
    defer cfg.deinit(gpa);
    // Normal üretim durumu: model_selection set (parseObject böyle kurar),
    // strict_outputs ise cleared EDİLMEMİŞ (diğer 4 ayarın aksine) ve config'te kalır.
    cfg.model_selection = .{
        .builtin = .{
            .provider = .openai,
            .provider_name = try gpa.dupe(u8, "openai"),
            .model = .{ .id = try gpa.dupe(u8, "gpt-5.5") },
        },
    };
    cfg.strict_outputs = true;

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try serialize(gpa, &buf.writer, cfg);

    // strictOutputs serialize çıktısında görünmeli.
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "\"strictOutputs\": true") != null);
}

test "globalConfigPath resolves the platform-correct config.json path" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const path = try globalConfigPath(gpa, io, "/home/testuser");
    defer gpa.free(path);

    // The returned path must end in the platform-correct config file location.
    // On POSIX that is ~/.config/nova/config.json; on Windows %APPDATA%\nova\config.json.
    // Build the expected suffix with path.join so the separator matches the host.
    const expected = try std.fs.path.join(gpa, &.{ "nova", "config.json" });
    defer gpa.free(expected);
    try std.testing.expect(std.mem.endsWith(u8, path, expected));
}

test "Config.validate validates schema version and base_url scheme" {
    const gpa = std.testing.allocator;
    var cfg: Config = .{
        .version = try gpa.dupe(u8, "3.0.0"),
        .base_url = try gpa.dupe(u8, "ftp://invalid-scheme"),
    };
    defer cfg.deinit(gpa);

    const diags = try cfg.validate(gpa);
    defer {
        for (diags) |*d| d.deinit(gpa);
        gpa.free(diags);
    }

    try std.testing.expectEqual(@as(usize, 2), diags.len);
}

test "config.load with missing files returns default config with version 1 and zero diagnostics" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const env: TestEnv = .{ .entries = &.{} };

    var res = try load(gpa, io, "/nonexistent/cwd", "/nonexistent/home", env);
    defer res.deinit(gpa);

    try std.testing.expectEqual(@as(?[]u8, null), res.config.version);
    try std.testing.expectEqual(@as(?Provider, null), res.config.providerFromName());
    try std.testing.expectEqual(@as(usize, 0), res.diagnostics.len);
}

test "serialize outputs semver version and camelCase 2-space indented JSON" {
    const gpa = std.testing.allocator;
    var cfg: Config = .{
        .provider_name = try gpa.dupe(u8, "openai"),
        .use_responses_endpoint = true,
    };
    defer cfg.deinit(gpa);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try serialize(gpa, &buf.writer, cfg);

    const text = buf.written();
    try std.testing.expect(std.mem.startsWith(u8, text, "{\n  \"version\": \"2.0.0\""));
    // "provider" is no longer written — defaultModel encodes the provider.
    try std.testing.expect(std.mem.indexOf(u8, text, "\"provider\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  \"useResponsesEndpoint\": true") != null);
}

test "serialize writes sse headers raw and round-trips through parseFile" {
    const gpa = std.testing.allocator;

    var servers = try gpa.alloc(McpServerConfig, 1);
    servers[0] = .{
        .name = try gpa.dupe(u8, "context7"),
        .enabled = true,
        .transport = .{ .sse = .{
            .url = try gpa.dupe(u8, "https://mcp.context7.com/mcp"),
            .headers = try cloneHeaders(gpa, &[_]McpHeader{
                .{ .name = @constCast("CONTEXT7_API_KEY"), .value = @constCast("{env:CONTEXT7_API_KEY}") },
            }),
        } },
    };
    var cfg: Config = .{ .mcp_servers = servers };
    defer cfg.deinit(gpa);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try serialize(gpa, &buf.writer, cfg);
    const text = buf.written();

    // Headers are written back raw — placeholder preserved, never a resolved secret.
    try std.testing.expect(std.mem.indexOf(u8, text, "\"headers\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "{env:CONTEXT7_API_KEY}") != null);

    // Round-trip: parse the serialized text and confirm the header survives a save.
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var parsed = try parseFile(gpa, "<test>", text, &sink);
    defer parsed.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), parsed.mcp_servers.len);
    switch (parsed.mcp_servers[0].transport) {
        .sse => |t| {
            try std.testing.expectEqual(@as(usize, 1), t.headers.len);
            try std.testing.expectEqualStrings("CONTEXT7_API_KEY", t.headers[0].name);
            try std.testing.expectEqualStrings("{env:CONTEXT7_API_KEY}", t.headers[0].value);
        },
        .stdio => return error.Unexpected,
    }
}

test "parseFile parses mcp_servers objects" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const json = "{\"mcp_servers\":{\"memory\":{\"command\":\"npx\",\"args\":[\"-y\",\"@modelcontextprotocol/server-memory\"],\"enabled\":true}}}";
    var cfg = try parseFile(gpa, "<test>", json, &sink);
    defer cfg.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), cfg.mcp_servers.len);
    try std.testing.expectEqualStrings("memory", cfg.mcp_servers[0].name);
    switch (cfg.mcp_servers[0].transport) {
        .stdio => |t| {
            try std.testing.expectEqualStrings("npx", t.command);
            try std.testing.expectEqual(@as(usize, 2), t.args.len);
            try std.testing.expectEqualStrings("-y", t.args[0]);
        },
        .sse => return error.Unexpected,
    }
    try std.testing.expectEqual(true, cfg.mcp_servers[0].enabled);
}

test "parseFile parses mcpServers (Claude Desktop format)" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const json = "{\"mcpServers\":{\"codebase-memory-mcp\":{\"command\":\"/path/to/codebase-memory-mcp\",\"args\":[]}}}";
    var cfg = try parseFile(gpa, "<test>", json, &sink);
    defer cfg.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), cfg.mcp_servers.len);
    try std.testing.expectEqualStrings("codebase-memory-mcp", cfg.mcp_servers[0].name);
    switch (cfg.mcp_servers[0].transport) {
        .stdio => |t| {
            try std.testing.expectEqualStrings("/path/to/codebase-memory-mcp", t.command);
            try std.testing.expectEqual(@as(usize, 0), t.args.len);
        },
        .sse => return error.Unexpected,
    }
}

test "mcpServers requestTimeoutMs parses, serializes, and round-trips" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const json = "{\"mcpServers\":{\"timed\":{\"command\":\"mcp-server\",\"requestTimeoutMs\":5000},\"default\":{\"command\":\"mcp-server\"}}}";
    var cfg = try parseFile(gpa, "<test>", json, &sink);
    defer cfg.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), cfg.mcp_servers.len);
    var timed: ?*McpServerConfig = null;
    var default: ?*McpServerConfig = null;
    for (cfg.mcp_servers) |*s| {
        if (std.mem.eql(u8, s.name, "timed")) {
            timed = s;
        } else if (std.mem.eql(u8, s.name, "default")) {
            default = s;
        }
    }
    try std.testing.expect(timed != null);
    try std.testing.expect(default != null);
    // The knob is parsed for the server that sets it...
    try std.testing.expectEqual(@as(?u32, 5000), timed.?.request_timeout_ms);
    // ...and stays null for a server that omits it.
    try std.testing.expectEqual(@as(?u32, null), default.?.request_timeout_ms);

    // Serialize back out, then re-parse to confirm the round-trip survives.
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try serialize(gpa, &buf.writer, cfg);

    var sink2: std.ArrayList(Diagnostic) = .empty;
    defer sink2.deinit(gpa);
    var parsed = try parseFile(gpa, "<test>", buf.written(), &sink2);
    defer parsed.deinit(gpa);
    for (parsed.mcp_servers) |s| {
        if (std.mem.eql(u8, s.name, "timed")) {
            try std.testing.expectEqual(@as(?u32, 5000), s.request_timeout_ms);
        }
    }
}

test "parseFile parses mcp (short key format)" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const json = "{\"mcp\":{\"test-server\":{\"command\":\"node\",\"args\":[\"index.js\"]}}}";
    var cfg = try parseFile(gpa, "<test>", json, &sink);
    defer cfg.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), cfg.mcp_servers.len);
    try std.testing.expectEqualStrings("test-server", cfg.mcp_servers[0].name);
    switch (cfg.mcp_servers[0].transport) {
        .stdio => |t| try std.testing.expectEqualStrings("node", t.command),
        .sse => return error.Unexpected,
    }
}

test "parseFile parses remote mcp server (url transport)" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const json = "{\"mcp_servers\":{\"remote\":{\"url\":\"https://mcp.example.com/mcp\"}}}";
    var cfg = try parseFile(gpa, "<test>", json, &sink);
    defer cfg.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), cfg.mcp_servers.len);
    try std.testing.expectEqualStrings("remote", cfg.mcp_servers[0].name);
    switch (cfg.mcp_servers[0].transport) {
        .sse => |t| try std.testing.expectEqualStrings("https://mcp.example.com/mcp", t.url),
        .stdio => return error.Unexpected,
    }
}

test "parseFile parses remote mcp server headers (kept raw)" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const json = "{\"mcp_servers\":{\"context7\":{\"url\":\"https://mcp.context7.com/mcp\",\"headers\":{\"CONTEXT7_API_KEY\":\"{env:NOVA_TEST_UNSET_MCP_VAR}\"}}}}";
    var cfg = try parseFile(gpa, "<test>", json, &sink);
    defer cfg.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), cfg.mcp_servers.len);
    switch (cfg.mcp_servers[0].transport) {
        .sse => |t| {
            try std.testing.expectEqualStrings("https://mcp.context7.com/mcp", t.url);
            try std.testing.expectEqual(@as(usize, 1), t.headers.len);
            try std.testing.expectEqualStrings("CONTEXT7_API_KEY", t.headers[0].name);
            // Header values keep their placeholder until expandMcpServer runs.
            try std.testing.expectEqualStrings("{env:NOVA_TEST_UNSET_MCP_VAR}", t.headers[0].value);
        },
        .stdio => return error.Unexpected,
    }
}

test "parseFile rejects mcp server configuring both transports" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    // command + url is ambiguous — the transport union allows exactly one,
    // matching schema/config.schema.json's MCPServerConfig oneOf.
    const json = "{\"mcp_servers\":{\"bad\":{\"command\":\"npx\",\"url\":\"https://mcp.example.com/mcp\"}}}";
    try std.testing.expectError(
        error.InvalidMcpServerConfig,
        parseFile(gpa, "<test>", json, &sink),
    );
}

test "parseFile rejects mcp server with neither command nor url" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const json = "{\"mcp_servers\":{\"bad\":{\"enabled\":true}}}";
    try std.testing.expectError(
        error.InvalidMcpServerConfig,
        parseFile(gpa, "<test>", json, &sink),
    );
}

test "parseFile keeps {env:VAR} placeholders raw in mcp url" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    // Placeholders are stored verbatim at parse time so serialize() can write
    // them back unchanged; expansion happens later, at connect time
    // (expandMcpServer). This keeps resolved secrets out of config.json.
    const json = "{\"mcp_servers\":{\"tavily\":{\"url\":\"https://mcp.tavily.com/mcp/?key={env:NOVA_TEST_UNSET_MCP_VAR}\"}}}";
    var cfg = try parseFile(gpa, "<test>", json, &sink);
    defer cfg.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), cfg.mcp_servers.len);
    switch (cfg.mcp_servers[0].transport) {
        .sse => |t| try std.testing.expectEqualStrings("https://mcp.tavily.com/mcp/?key={env:NOVA_TEST_UNSET_MCP_VAR}", t.url),
        .stdio => return error.Unexpected,
    }
}

test "expandMcpServer resolves {env:VAR} in url and headers, leaving the source raw" {
    const gpa = std.testing.allocator;
    // A raw server as the parser produces it: placeholders in url + header value.
    var raw = try mcpServerFromUrl(gpa, "ctx", "https://mcp.context7.com/mcp?key={env:NOVA_TEST_UNSET_MCP_VAR}");
    defer raw.deinit(gpa);
    const headers = try gpa.alloc(McpHeader, 1);
    headers[0] = .{
        .name = try gpa.dupe(u8, "CONTEXT7_API_KEY"),
        .value = try gpa.dupe(u8, "{env:NOVA_TEST_UNSET_MCP_VAR}"),
    };
    raw.transport.sse.headers = headers;

    var expanded = try expandMcpServer(gpa, raw);
    defer expanded.deinit(gpa);

    // Unset variable → empty substitution, in both the url and the header value.
    switch (expanded.transport) {
        .sse => |t| {
            try std.testing.expectEqualStrings("https://mcp.context7.com/mcp?key=", t.url);
            try std.testing.expectEqual(@as(usize, 1), t.headers.len);
            try std.testing.expectEqualStrings("CONTEXT7_API_KEY", t.headers[0].name);
            try std.testing.expectEqualStrings("", t.headers[0].value);
        },
        .stdio => return error.Unexpected,
    }
    // The source keeps its placeholders (still safe to serialize).
    switch (raw.transport) {
        .sse => |t| try std.testing.expectEqualStrings("https://mcp.context7.com/mcp?key={env:NOVA_TEST_UNSET_MCP_VAR}", t.url),
        .stdio => return error.Unexpected,
    }
}

test "expandMcpServer resolves a SET {env:VAR} from the real environment" {
    const gpa = std.testing.allocator;
    // Read PATH through the same raw-environ path loadEnvMap uses, so the
    // expected value matches what expandMcpServer sees. Exercises the SET-var
    // path the unset-only test above never covers.
    var env_map = try platform.getEnvMap(gpa);
    defer env_map.deinit();
    const path = env_map.get("PATH") orelse return error.SkipZigTest;

    var raw = try mcpServerFromUrl(gpa, "tavily", "https://x/mcp/?key={env:PATH}");
    defer raw.deinit(gpa);

    var expanded = try expandMcpServer(gpa, raw);
    defer expanded.deinit(gpa);

    switch (expanded.transport) {
        .sse => |t| {
            // Placeholder fully resolved to the real PATH value.
            try std.testing.expect(std.mem.indexOf(u8, t.url, "{env:") == null);
            try std.testing.expect(std.mem.indexOf(u8, t.url, path) != null);
        },
        .stdio => return error.Unexpected,
    }
}

test "mcpServerFromUrl builds an enabled remote server with duped name and url" {
    const gpa = std.testing.allocator;
    var server = try mcpServerFromUrl(gpa, "tavily", "https://mcp.tavily.com/mcp/");
    defer server.deinit(gpa);
    try std.testing.expectEqualStrings("tavily", server.name);
    try std.testing.expect(server.enabled);
    switch (server.transport) {
        .sse => |t| try std.testing.expectEqualStrings("https://mcp.tavily.com/mcp/", t.url),
        .stdio => return error.Unexpected,
    }
}

test "mergeLayers merges mcp_servers across config layers" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);

    var layer1 = try parseFile(gpa, "<layer1>", "{\"mcp_servers\":{\"global-server\":{\"command\":\"python\",\"args\":[]}}}", &sink);
    defer layer1.deinit(gpa);
    var layer2 = try parseFile(gpa, "<layer2>", "{\"mcp\":{\"proj-server\":{\"command\":\"node\",\"args\":[]}}}", &sink);
    defer layer2.deinit(gpa);

    var merged = try mergeLayers(gpa, &.{ layer1, layer2 });
    defer merged.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), merged.mcp_servers.len);
    try std.testing.expectEqualStrings("global-server", merged.mcp_servers[0].name);
    try std.testing.expectEqualStrings("proj-server", merged.mcp_servers[1].name);
}

test "applyConfigOverlay: model_selection present uses canonical form" {
    const gpa = std.testing.allocator;
    var target: Config = .{
        .provider_name = try gpa.dupe(u8, "ollama"),
        .model = .{ .id = try gpa.dupe(u8, "llama3.1:8b") },
    };
    defer target.deinit(gpa);

    // Updates carry model_selection (canonical) — legacy fields should be
    // ignored in favour of model_selection.
    var updates: Config = .{
        .provider_name = try gpa.dupe(u8, "openai"), // legacy — should be ignored
        .model_selection = .{
            .builtin = .{
                .provider = .anthropic,
                .provider_name = try gpa.dupe(u8, "anthropic"),
                .model = .{ .id = try gpa.dupe(u8, "claude-3.7-sonnet") },
            },
        },
    };
    defer updates.deinit(gpa);

    try applyConfigOverlay(gpa, &target, updates);

    try std.testing.expectEqual(Provider.anthropic, target.providerFromName().?);
    try std.testing.expectEqualStrings("claude-3.7-sonnet", target.model.?.id);
    // builtin providers don't carry base_url/api_key in model_selection;
    // they resolve from the provider catalogue at connection time.
    try std.testing.expect(target.base_url == null);
    try std.testing.expect(target.api_key == null);
}

test "applyConfigOverlay: legacy fields sync to model_selection" {
    const gpa = std.testing.allocator;

    // Target starts with model_selection populated.
    var target: Config = .{};
    defer target.deinit(gpa);
    target.provider_name = try gpa.dupe(u8, "openai");
    target.model = .{ .id = try gpa.dupe(u8, "gpt-5.5") };
    target.base_url = try gpa.dupe(u8, "https://api.openai.com");
    target.api_key = try gpa.dupe(u8, "sk-test");
    target.use_responses_endpoint = false;
    // Manually populate model_selection (normally done by parseObject).
    target.model_selection = .{
        .builtin = .{
            .provider = .openai,
            .provider_name = try gpa.dupe(u8, "openai"),
            .model = .{ .id = try gpa.dupe(u8, "gpt-5.5") },
        },
    };

    // Updates carry only legacy fields (no model_selection).
    var updates: Config = .{
        .system_prompt = try gpa.dupe(u8, "You are a helpful assistant."),
    };
    defer updates.deinit(gpa);

    try applyConfigOverlay(gpa, &target, updates);

    // Legacy fields updated.
    try std.testing.expectEqualStrings("You are a helpful assistant.", target.system_prompt.?);

    // model_selection should also be in sync.
    try std.testing.expectEqualStrings("You are a helpful assistant.", target.model_selection.?.systemPrompt().?);

    // Provider/model should be unchanged.
    try std.testing.expectEqual(Provider.openai, target.providerFromName().?);
    try std.testing.expectEqualStrings("gpt-5.5", target.model.?.id);
}

test "mergeLayers: settings-only overlay does not overwrite provider/model" {
    const gpa = std.testing.allocator;

    // Simulate a global config with provider/model set.
    var global: Config = .{
        .provider_name = try gpa.dupe(u8, "openai"),
        .model = .{ .id = try gpa.dupe(u8, "gpt-5.5") },
    };
    defer global.deinit(gpa);

    // Simulate a project config with a different provider/model.
    var project: Config = .{
        .provider_name = try gpa.dupe(u8, "ollama"),
        .model = .{ .id = try gpa.dupe(u8, "llama3.1:8b") },
    };
    defer project.deinit(gpa);

    // Simulate a settings-only update (no provider/model).
    var settings: Config = .{
        .use_responses_endpoint = true,
    };
    defer settings.deinit(gpa);

    // Merge: global → project → settings
    var merged = try mergeLayers(gpa, &.{ global, project, settings });
    defer merged.deinit(gpa);

    // Provider/model should come from project (last layer that set them).
    try std.testing.expectEqual(Provider.ollama, merged.providerFromName().?);
    try std.testing.expectEqualStrings("llama3.1:8b", merged.model.?.id);
    // use_responses_endpoint should come from settings.
    try std.testing.expectEqual(true, merged.use_responses_endpoint.?);
}

// ---------------------------------------------------------------------------
// Schema v2: camelCase, semver version, context/compaction
// ---------------------------------------------------------------------------

test "parseObject accepts camelCase keys (schema v2)" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const json =
        \\{"defaultModel":"ollama/llama3.1:8b","baseURL":"http://localhost:11434","useResponsesEndpoint":true,"enableThinking":true,"systemPrompt":"You are Nova.","bashClassifierUrl":"http://localhost:9999"}
    ;
    var cfg = try parseFile(gpa, "<test>", json, &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(Provider.ollama, cfg.providerFromName().?);
    try std.testing.expectEqualStrings("llama3.1:8b", cfg.model.?.id);
    try std.testing.expectEqualStrings("http://localhost:11434", cfg.base_url.?);
    try std.testing.expectEqual(true, cfg.use_responses_endpoint.?);
    try std.testing.expectEqualStrings("You are Nova.", cfg.system_prompt.?);
    try std.testing.expectEqualStrings("http://localhost:9999", cfg.bash_classifier_url.?);
    // The legacy `enableThinking` key is accepted and discarded — no diagnostics.
    try std.testing.expectEqual(@as(usize, 0), sink.items.len);
}

test "parseObject accepts legacy snake_case keys (backward compat)" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const json =
        \\{"model":"openai/gpt-5.5","base_url":"https://api.openai.com","use_responses_endpoint":false,"enable_thinking":false,"system_prompt":"Legacy.","bash_classifier_url":"http://old:8080"}
    ;
    var cfg = try parseFile(gpa, "<test>", json, &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(Provider.openai, cfg.providerFromName().?);
    try std.testing.expectEqualStrings("gpt-5.5", cfg.model.?.id);
    try std.testing.expectEqualStrings("https://api.openai.com", cfg.base_url.?);
    try std.testing.expectEqual(false, cfg.use_responses_endpoint.?);
    try std.testing.expectEqualStrings("Legacy.", cfg.system_prompt.?);
    try std.testing.expectEqualStrings("http://old:8080", cfg.bash_classifier_url.?);
    // The legacy snake_case `enable_thinking` key is accepted and discarded.
}

test "parseObject: camelCase wins over snake_case when both present" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const json =
        \\{"defaultModel":"ollama/llama3.1:8b","model":"openai/gpt-5.5","baseURL":"http://camel","base_url":"http://snake"}
    ;
    var cfg = try parseFile(gpa, "<test>", json, &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(Provider.ollama, cfg.providerFromName().?);
    try std.testing.expectEqualStrings("http://camel", cfg.base_url.?);
}

test "parseObject: semver string version" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var cfg = try parseFile(gpa, "<test>", "{\"version\":\"2.1.0\"}", &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqualStrings("2.1.0", cfg.version.?);
}

test "parseObject: legacy integer version normalized to semver" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var cfg = try parseFile(gpa, "<test>", "{\"version\":1}", &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqualStrings("1.0.0", cfg.version.?);
}

test "parseObject: context with compaction settings" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const json =
        \\{"context":{"overrideContextWindow":32000,"maxOutputTokens":4096,"maxConcurrentRequests":3,"compaction":{"auto":false,"threshold":0.80,"keepRecentTokens":5000,"keepRecentToolTurns":8,"historicalToolCapBytes":8192}}}
    ;
    var cfg = try parseFile(gpa, "<test>", json, &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 32_000), cfg.context.override_context_window.?);
    try std.testing.expectEqual(@as(u32, 4_096), cfg.context.max_output_tokens.?);
    try std.testing.expectEqual(@as(u32, 3), cfg.context.max_concurrent_requests.?);
    try std.testing.expectEqual(false, cfg.context.compaction.auto);
    try std.testing.expectApproxEqAbs(@as(f64, 0.80), cfg.context.compaction.threshold, 0.001);
    try std.testing.expectEqual(@as(u32, 5_000), cfg.context.compaction.keep_recent_tokens);
    try std.testing.expectEqual(@as(u32, 8), cfg.context.compaction.keep_recent_tool_turns);
    try std.testing.expectEqual(@as(u32, 8_192), cfg.context.compaction.historical_tool_cap_bytes);
}

test "parseObject: context defaults when absent" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var cfg = try parseFile(gpa, "<test>", "{}", &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(?u32, null), cfg.context.override_context_window);
    try std.testing.expectEqual(@as(?u32, null), cfg.context.max_output_tokens);
    try std.testing.expectEqual(@as(?u32, null), cfg.context.max_concurrent_requests);
    try std.testing.expectEqual(true, cfg.context.compaction.auto);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), cfg.context.compaction.threshold, 0.001);
    try std.testing.expectEqual(@as(u32, 8_000), cfg.context.compaction.keep_recent_tokens);
    try std.testing.expectEqual(@as(u32, 4), cfg.context.compaction.keep_recent_tool_turns);
    try std.testing.expectEqual(@as(u32, 1_024), cfg.context.compaction.historical_tool_cap_bytes);
}

test "parseCompaction clamps pruning knobs to their minimum" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);

    // Below minimum (0): keep the defaults — 0 turns would prune every tool
    // result and a 0-byte cap would render pruned results empty.
    var zero = try parseFile(gpa, "<test>", "{\"context\":{\"compaction\":{\"keepRecentToolTurns\":0,\"historicalToolCapBytes\":0}}}", &sink);
    defer zero.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 4), zero.context.compaction.keep_recent_tool_turns);
    try std.testing.expectEqual(@as(u32, 1_024), zero.context.compaction.historical_tool_cap_bytes);

    // Minimum 1 passes through.
    var min = try parseFile(gpa, "<test>", "{\"context\":{\"compaction\":{\"keepRecentToolTurns\":1,\"historicalToolCapBytes\":1}}}", &sink);
    defer min.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 1), min.context.compaction.keep_recent_tool_turns);
    try std.testing.expectEqual(@as(u32, 1), min.context.compaction.historical_tool_cap_bytes);
}

test "parseContext clamps maxConcurrentRequests to its minimum" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);

    // Below minimum (0): keep the default (null) — a 0 cap would deadlock
    // every request behind the limiter.
    var zero = try parseFile(gpa, "<test>", "{\"context\":{\"maxConcurrentRequests\":0}}", &sink);
    defer zero.deinit(gpa);
    try std.testing.expectEqual(@as(?u32, null), zero.context.max_concurrent_requests);

    // Minimum 1 passes through.
    var min = try parseFile(gpa, "<test>", "{\"context\":{\"maxConcurrentRequests\":1}}", &sink);
    defer min.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 1), min.context.max_concurrent_requests.?);
}

test "parseObject: compaction threshold clamped to valid range" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var cfg = try parseFile(gpa, "<test>", "{\"context\":{\"compaction\":{\"threshold\":5.0}}}", &sink);
    defer cfg.deinit(gpa);
    // Out-of-range threshold keeps the default.
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), cfg.context.compaction.threshold, 0.001);
}

test "parseCompaction clamps threshold to the 0.90 ceiling" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);

    // Above the ceiling (0.90): clamped so swap = min(t+0.20, 0.95) stays > t.
    var high = try parseFile(gpa, "<test>", "{\"context\":{\"compaction\":{\"threshold\":0.97}}}", &sink);
    defer high.deinit(gpa);
    try std.testing.expectApproxEqAbs(@as(f64, 0.90), high.context.compaction.threshold, 0.001);

    var maxed = try parseFile(gpa, "<test>", "{\"context\":{\"compaction\":{\"threshold\":1.0}}}", &sink);
    defer maxed.deinit(gpa);
    try std.testing.expectApproxEqAbs(@as(f64, 0.90), maxed.context.compaction.threshold, 0.001);

    // In-range values pass through unchanged.
    var mid = try parseFile(gpa, "<test>", "{\"context\":{\"compaction\":{\"threshold\":0.5}}}", &sink);
    defer mid.deinit(gpa);
    try std.testing.expectApproxEqAbs(@as(f64, 0.50), mid.context.compaction.threshold, 0.001);

    // Below the floor keeps the default.
    var low = try parseFile(gpa, "<test>", "{\"context\":{\"compaction\":{\"threshold\":0.05}}}", &sink);
    defer low.deinit(gpa);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), low.context.compaction.threshold, 0.001);
}

test "serialize writes camelCase keys and context section" {
    const gpa = std.testing.allocator;
    var cfg: Config = .{
        .provider_name = try gpa.dupe(u8, "ollama"),
        .model = .{ .id = try gpa.dupe(u8, "llama3.1:8b") },
        .use_responses_endpoint = true,
        .system_prompt = try gpa.dupe(u8, "Be helpful."),
        .context = .{
            .override_context_window = 32_000,
            .compaction = .{ .threshold = 0.80, .keep_recent_tokens = 5_000 },
        },
    };
    defer cfg.deinit(gpa);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try serialize(gpa, &buf.writer, cfg);

    const text = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"defaultModel\": \"ollama/llama3.1:8b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"useResponsesEndpoint\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"systemPrompt\": \"Be helpful.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"context\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"overrideContextWindow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"compaction\"") != null);
}

test "serialize omits context section when all defaults" {
    const gpa = std.testing.allocator;
    var cfg: Config = .{ .provider_name = try gpa.dupe(u8, "openai") };
    defer cfg.deinit(gpa);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try serialize(gpa, &buf.writer, cfg);

    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "\"context\"") == null);
}

test "serialize then parse roundtrips with camelCase and context" {
    const gpa = std.testing.allocator;
    var original: Config = .{
        .provider_name = try gpa.dupe(u8, "ollama"),
        .base_url = try gpa.dupe(u8, "http://localhost:11434/v1"),
        .use_responses_endpoint = false,
        .model = .{ .id = try gpa.dupe(u8, "llama3.1:8b") },
        .context = .{
            .override_context_window = 16_000,
            .max_concurrent_requests = 3,
            .compaction = .{ .auto = false, .keep_recent_tokens = 4_000, .keep_recent_tool_turns = 6, .historical_tool_cap_bytes = 4_096 },
        },
    };
    defer original.deinit(gpa);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try serialize(gpa, &buf.writer, original);

    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var parsed = try parseFile(gpa, "<test>", buf.written(), &sink);
    defer parsed.deinit(gpa);
    var roundtrip = try mergeLayers(gpa, &.{parsed});
    defer roundtrip.deinit(gpa);

    try std.testing.expectEqual(Provider.ollama, roundtrip.providerFromName().?);
    try std.testing.expectEqualStrings("llama3.1:8b", roundtrip.model.?.id);
    try std.testing.expectEqual(false, roundtrip.use_responses_endpoint.?);
    try std.testing.expectEqual(@as(u32, 16_000), roundtrip.context.override_context_window.?);
    try std.testing.expectEqual(@as(u32, 3), roundtrip.context.max_concurrent_requests.?);
    try std.testing.expectEqual(false, roundtrip.context.compaction.auto);
    try std.testing.expectEqual(@as(u32, 4_000), roundtrip.context.compaction.keep_recent_tokens);
    try std.testing.expectEqual(@as(u32, 6), roundtrip.context.compaction.keep_recent_tool_turns);
    try std.testing.expectEqual(@as(u32, 4_096), roundtrip.context.compaction.historical_tool_cap_bytes);
}

test "parseSemverMajor extracts major from various formats" {
    try std.testing.expectEqual(@as(?u32, 2), parseSemverMajor("2.0.0"));
    try std.testing.expectEqual(@as(?u32, 1), parseSemverMajor("1.2.3"));
    try std.testing.expectEqual(@as(?u32, 10), parseSemverMajor("10.0.0"));
    try std.testing.expectEqual(@as(?u32, 3), parseSemverMajor("3"));
    try std.testing.expectEqual(@as(?u32, null), parseSemverMajor("abc"));
    try std.testing.expectEqual(@as(?u32, null), parseSemverMajor(""));
}

test "serialize then parse roundtrips disablePromptCache" {
    // C1: the cache-disable flag survives serialize → parse and merges into
    // both camelCase and snake_case form. Mirrors the existing context
    // round-trip test for max_concurrent_requests.
    const gpa = std.testing.allocator;
    var original: Config = .{
        .provider_name = try gpa.dupe(u8, "ollama"),
        .base_url = try gpa.dupe(u8, "http://localhost:11434/v1"),
        .model = .{ .id = try gpa.dupe(u8, "llama3.1:8b") },
        .context = .{ .disable_prompt_cache = true },
    };
    defer original.deinit(gpa);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try serialize(gpa, &buf.writer, original);

    // Sanity: the serialized JSON carries the camelCase key. `writeContext`
    // uses `writeKeyNoIndent` (no space after the colon), so the form is
    // `"disablePromptCache":true`.
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "\"disablePromptCache\":true") != null);

    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var parsed = try parseFile(gpa, "<test>", buf.written(), &sink);
    defer parsed.deinit(gpa);
    var roundtrip = try mergeLayers(gpa, &.{parsed});
    defer roundtrip.deinit(gpa);

    try std.testing.expectEqual(@as(?bool, true), roundtrip.context.disable_prompt_cache);

    // snake_case form parses too (the helper is a compat reader).
    const snake_json =
        \\{"version":"2.0.0","provider":"ollama","baseUrl":"http://localhost:11434/v1",
        \\ "model":{"id":"llama3.1:8b"},
        \\ "context":{"disable_prompt_cache":true}}
    ;
    var snake_parsed = try parseFile(gpa, "<snake>", snake_json, &sink);
    defer snake_parsed.deinit(gpa);
    var snake_rt = try mergeLayers(gpa, &.{snake_parsed});
    defer snake_rt.deinit(gpa);
    try std.testing.expectEqual(@as(?bool, true), snake_rt.context.disable_prompt_cache);
}

test "serialize then parse roundtrips tool budget keys" {
    const gpa = std.testing.allocator;
    var original: Config = .{
        .provider_name = try gpa.dupe(u8, "ollama"),
        .base_url = try gpa.dupe(u8, "http://localhost:11434/v1"),
        .model = .{ .id = try gpa.dupe(u8, "llama3.1:8b") },
        .context = .{ .tool_call_limit_per_turn = 40, .soft_stop_on_tool_call_limit = false },
    };
    defer original.deinit(gpa);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try serialize(gpa, &buf.writer, original);

    // Serialized form carries the camelCase keys (writeKeyNoIndent = no space
    // after the colon).
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "\"toolCallLimitPerTurn\":40") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "\"softStopOnToolCallLimit\":false") != null);

    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var parsed = try parseFile(gpa, "<test>", buf.written(), &sink);
    defer parsed.deinit(gpa);
    var roundtrip = try mergeLayers(gpa, &.{parsed});
    defer roundtrip.deinit(gpa);

    try std.testing.expectEqual(@as(?u32, 40), roundtrip.context.tool_call_limit_per_turn);
    try std.testing.expectEqual(@as(?bool, false), roundtrip.context.soft_stop_on_tool_call_limit);

    // snake_case form parses to the same values (compat reader).
    const snake_json =
        \\{"version":"2.0.0","provider":"ollama","baseUrl":"http://localhost:11434/v1",
        \\ "model":{"id":"llama3.1:8b"},
        \\ "context":{"tool_call_limit_per_turn":40,"soft_stop_on_tool_call_limit":false}}
    ;
    var snake_parsed = try parseFile(gpa, "<snake>", snake_json, &sink);
    defer snake_parsed.deinit(gpa);
    var snake_rt = try mergeLayers(gpa, &.{snake_parsed});
    defer snake_rt.deinit(gpa);
    try std.testing.expectEqual(@as(?u32, 40), snake_rt.context.tool_call_limit_per_turn);
    try std.testing.expectEqual(@as(?bool, false), snake_rt.context.soft_stop_on_tool_call_limit);
}

test "parseProviderConfig accepts baseURL (camelCase)" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const json = "{\"providers\":{\"ollama\":{\"baseURL\":\"http://custom:11434\"}}}";
    var cfg = try parseFile(gpa, "<test>", json, &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), cfg.providers.len);
    switch (cfg.providers[0].base_url) {
        .custom => |url| try std.testing.expectEqualStrings("http://custom:11434", url),
        .default => return error.Unexpected,
    }
}

test "applyContextOverlay merges non-default values" {
    var target: ContextSettings = .{};
    const updates: ContextSettings = .{
        .override_context_window = 64_000,
        .max_concurrent_requests = 4,
        .compaction = .{ .threshold = 0.90, .keep_recent_tool_turns = 10, .historical_tool_cap_bytes = 16_384 },
    };
    applyContextOverlay(&target, updates);
    try std.testing.expectEqual(@as(u32, 64_000), target.override_context_window.?);
    try std.testing.expectEqual(@as(u32, 4), target.max_concurrent_requests.?);
    try std.testing.expectApproxEqAbs(@as(f64, 0.90), target.compaction.threshold, 0.001);
    try std.testing.expectEqual(@as(u32, 10), target.compaction.keep_recent_tool_turns);
    try std.testing.expectEqual(@as(u32, 16_384), target.compaction.historical_tool_cap_bytes);
    // Defaults preserved for fields not in updates.
    try std.testing.expectEqual(true, target.compaction.auto);
    try std.testing.expectEqual(@as(u32, 8_000), target.compaction.keep_recent_tokens);
}

test "parseToast clamps out-of-range values" {
    const gpa = std.testing.allocator;
    const json = std.json.parseFromSlice(std.json.Value, gpa,
        \\{"enabled":true,"durationMs":999999,"maxVisible":99,"position":"top-right"}
    , .{}) catch unreachable;
    defer json.deinit();

    const toast = try parseToast(gpa, json.value);
    defer if (toast.position) |pos| gpa.free(pos);
    // Out-of-range values are dropped (left null), not clamped to a bad value.
    try std.testing.expectEqual(true, toast.enabled.?);
    try std.testing.expectEqual(@as(?u32, null), toast.duration_ms);
    try std.testing.expectEqual(@as(?u8, null), toast.max_visible);
    try std.testing.expectEqualStrings("top-right", toast.position.?);
}

test "parseToast accepts in-range values" {
    const gpa = std.testing.allocator;
    const json = std.json.parseFromSlice(std.json.Value, gpa,
        \\{"enabled":false,"durationMs":2500,"maxVisible":2}
    , .{}) catch unreachable;
    defer json.deinit();

    const toast = try parseToast(gpa, json.value);
    defer if (toast.position) |pos| gpa.free(pos);
    try std.testing.expectEqual(false, toast.enabled.?);
    try std.testing.expectEqual(@as(u32, 2500), toast.duration_ms.?);
    try std.testing.expectEqual(@as(u8, 2), toast.max_visible.?);
}

test "serialize then parse roundtrips toast section" {
    const gpa = std.testing.allocator;
    var original: Config = .{
        .toast = .{
            .enabled = false,
            .duration_ms = 2500,
            .max_visible = 2,
            .position = try gpa.dupe(u8, "top-right"),
        },
    };
    defer original.deinit(gpa);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try serialize(gpa, &buf.writer, original);
    const text = buf.written();
    // Section is written only when non-default.
    try std.testing.expect(std.mem.indexOf(u8, text, "\"toast\"") != null);

    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var parsed = try parseFile(gpa, "<test>", text, &sink);
    defer parsed.deinit(gpa);
    try std.testing.expectEqual(false, parsed.toast.enabled.?);
    try std.testing.expectEqual(@as(u32, 2500), parsed.toast.duration_ms.?);
    try std.testing.expectEqual(@as(u8, 2), parsed.toast.max_visible.?);
    try std.testing.expectEqualStrings("top-right", parsed.toast.position.?);
}

test "default config omits toast section" {
    const gpa = std.testing.allocator;
    var cfg: Config = .{};
    defer cfg.deinit(gpa);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try serialize(gpa, &buf.writer, cfg);
    const text = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"toast\"") == null);
}

test "parseFile parses the theme field" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var cfg = try parseFile(gpa, "<test>", "{\"theme\":\"cappuccino\"}", &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqualStrings("cappuccino", cfg.theme.?);
}

test "serialize then parse roundtrips the theme field" {
    const gpa = std.testing.allocator;
    var original: Config = .{ .theme = try gpa.dupe(u8, "cappuccino") };
    defer original.deinit(gpa);

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try serialize(gpa, &buf.writer, original);
    // The theme is written only when set and non-empty.
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "\"theme\"") != null);

    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var parsed = try parseFile(gpa, "<test>", buf.written(), &sink);
    defer parsed.deinit(gpa);
    var roundtrip = try mergeLayers(gpa, &.{parsed});
    defer roundtrip.deinit(gpa);
    try std.testing.expectEqualStrings("cappuccino", roundtrip.theme.?);
}

test "mergeLayers: later-layer theme wins" {
    const gpa = std.testing.allocator;
    var global: Config = .{ .theme = try gpa.dupe(u8, "default") };
    defer global.deinit(gpa);
    var project: Config = .{ .theme = try gpa.dupe(u8, "cappuccino") };
    defer project.deinit(gpa);

    var merged = try mergeLayers(gpa, &.{ global, project });
    defer merged.deinit(gpa);
    try std.testing.expectEqualStrings("cappuccino", merged.theme.?);
}

test "parseObject parses the tui object's four fields" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const json =
        \\{"tui":{"themeLivePreview":false,"customThemesDir":"/tmp/my-themes","fuzzyHighlight":false,"fuzzyHighlightStyle":"bold"}}
    ;
    var cfg = try parseFile(gpa, "<test>", json, &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(false, cfg.tui.theme_live_preview);
    try std.testing.expectEqualStrings("/tmp/my-themes", cfg.tui.custom_themes_dir.?);
    try std.testing.expectEqual(false, cfg.tui.fuzzy_highlight);
    try std.testing.expectEqual(FuzzyHighlightStyle.bold, cfg.tui.fuzzy_highlight_style);
}

test "parseTui falls back to .accent on an unknown fuzzyHighlightStyle" {
    const gpa = std.testing.allocator;
    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    const json = "{\"tui\":{\"fuzzyHighlightStyle\":\"rainbow\"}}";
    var cfg = try parseFile(gpa, "<test>", json, &sink);
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(FuzzyHighlightStyle.accent, cfg.tui.fuzzy_highlight_style);
}

test "serialize omits tui when default and writes it when non-default" {
    const gpa = std.testing.allocator;

    // Default tui → section omitted.
    var default_cfg: Config = .{};
    defer default_cfg.deinit(gpa);
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try serialize(gpa, &buf.writer, default_cfg);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "\"tui\"") == null);

    // Non-default tui → section written and round-trips.
    var non_default: Config = .{
        .tui = .{
            .theme_live_preview = false,
            .custom_themes_dir = try gpa.dupe(u8, "/tmp/my-themes"),
            .fuzzy_highlight = false,
            .fuzzy_highlight_style = .underline,
        },
    };
    defer non_default.deinit(gpa);
    var buf2: std.Io.Writer.Allocating = .init(gpa);
    defer buf2.deinit();
    try serialize(gpa, &buf2.writer, non_default);
    const text = buf2.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"tui\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"themeLivePreview\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"customThemesDir\":\"/tmp/my-themes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"fuzzyHighlight\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"fuzzyHighlightStyle\":\"underline\"") != null);

    var sink: std.ArrayList(Diagnostic) = .empty;
    defer sink.deinit(gpa);
    var parsed = try parseFile(gpa, "<test>", text, &sink);
    defer parsed.deinit(gpa);
    try std.testing.expectEqual(false, parsed.tui.theme_live_preview);
    try std.testing.expectEqualStrings("/tmp/my-themes", parsed.tui.custom_themes_dir.?);
    try std.testing.expectEqual(false, parsed.tui.fuzzy_highlight);
    try std.testing.expectEqual(FuzzyHighlightStyle.underline, parsed.tui.fuzzy_highlight_style);
}

test "applyTuiOverlay overrides non-default values and dupes customThemesDir" {
    const gpa = std.testing.allocator;
    var target: Config = .{};
    defer target.deinit(gpa);

    var updates: Config = .{
        .tui = .{
            .theme_live_preview = false,
            .custom_themes_dir = try gpa.dupe(u8, "/tmp/custom"),
            .fuzzy_highlight = false,
            .fuzzy_highlight_style = .bold,
        },
    };
    defer updates.deinit(gpa);

    try applyConfigOverlay(gpa, &target, updates);
    try std.testing.expectEqual(false, target.tui.theme_live_preview);
    try std.testing.expectEqualStrings("/tmp/custom", target.tui.custom_themes_dir.?);
    try std.testing.expectEqual(false, target.tui.fuzzy_highlight);
    try std.testing.expectEqual(FuzzyHighlightStyle.bold, target.tui.fuzzy_highlight_style);
}

test "applyTuiOverlay with default updates preserves stored non-default settings" {
    // Regression: unrelated partial config writes (theme apply, model save,
    // settings save) route through applyConfigOverlay with an all-default
    // `updates.tui`. It must NOT clobber stored themeLivePreview:false /
    // fuzzyHighlight:false — otherwise serialize drops the whole "tui" section.
    const gpa = std.testing.allocator;
    var target: Config = .{
        .tui = .{
            .theme_live_preview = false,
            .fuzzy_highlight = false,
            .fuzzy_highlight_style = .underline,
        },
    };
    defer target.deinit(gpa);

    // updates.tui is entirely default.
    const updates: Config = .{};
    try applyConfigOverlay(gpa, &target, updates);

    try std.testing.expectEqual(false, target.tui.theme_live_preview);
    try std.testing.expectEqual(false, target.tui.fuzzy_highlight);
    try std.testing.expectEqual(FuzzyHighlightStyle.underline, target.tui.fuzzy_highlight_style);
}

test "parseTui round-trips all eight layout + telemetry fields" {
    const json =
        \\{"splitMode":"grid","minSplitWidth":200,"highlightFocusedBorder":false,"showTokenVelocity":false,"showContextMeter":false,"velocitySmoothingAlpha":0.6,"contextThresholdWarn":0.5,"contextThresholdAlert":0.9}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const tui = try parseTui(std.testing.allocator, parsed.value);
    try std.testing.expectEqual(SplitMode.grid, tui.split_mode);
    try std.testing.expectEqual(@as(u16, 200), tui.min_split_width);
    try std.testing.expect(!tui.highlight_focused_border);
    try std.testing.expect(!tui.show_token_velocity);
    try std.testing.expect(!tui.show_context_meter);
    try std.testing.expectEqual(@as(f64, 0.6), tui.velocity_smoothing_alpha);
    try std.testing.expectEqual(@as(f64, 0.5), tui.context_threshold_warn);
    try std.testing.expectEqual(@as(f64, 0.9), tui.context_threshold_alert);
}

test "parseTui drops out-of-range layout + telemetry values" {
    // Each value is outside its clamp band and must be dropped (kept at the
    // default), mirroring the schema's min/max so a config typo self-heals.
    const json =
        \\{"minSplitWidth":50,"velocitySmoothingAlpha":2.0,"contextThresholdWarn":0.05,"contextThresholdAlert":1.0}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const tui = try parseTui(std.testing.allocator, parsed.value);
    try std.testing.expectEqual(@as(u16, 140), tui.min_split_width); // 50 < 80 dropped
    try std.testing.expectEqual(@as(f64, 0.35), tui.velocity_smoothing_alpha); // 2.0 > 1.0 dropped
    try std.testing.expectEqual(@as(f64, 0.70), tui.context_threshold_warn); // 0.05 < 0.1 dropped
    try std.testing.expectEqual(@as(f64, 0.85), tui.context_threshold_alert); // 1.0 > 0.99 dropped
}

test "parsePlugins normalizes inline-object settings to canonical JSON" {
    const gpa = std.testing.allocator;
    const json =
        \\{"my-plugin":{"enabled":true,"settings":{"duckdb_path":"/opt/duckdb","retries":3}}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    const plugins = try parsePlugins(gpa, parsed.value);
    defer {
        for (plugins) |*p| p.deinit(gpa);
        gpa.free(plugins);
    }
    try std.testing.expectEqual(@as(usize, 1), plugins.len);
    try std.testing.expectEqualStrings("my-plugin", plugins[0].name);
    try std.testing.expect(plugins[0].enabled);
    // Canonical compact JSON string, key order preserved from the source map.
    try std.testing.expectEqualStrings("{\"duckdb_path\":\"/opt/duckdb\",\"retries\":3}", plugins[0].settings);
}

test "parsePlugins keeps string settings and ignores non-object forms" {
    const gpa = std.testing.allocator;
    const json =
        \\{"str-form":{"settings":"{\"x\":1}"},"arr":{"settings":[1,2]},"num":{"settings":42},"none":{}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    const plugins = try parsePlugins(gpa, parsed.value);
    defer {
        for (plugins) |*p| p.deinit(gpa);
        gpa.free(plugins);
    }
    try std.testing.expectEqual(@as(usize, 4), plugins.len);
    for (plugins) |*p| {
        if (std.mem.eql(u8, p.name, "str-form")) {
            try std.testing.expectEqualStrings("{\"x\":1}", p.settings);
        } else {
            // Array/number settings are parse-ignored; absent stays empty.
            try std.testing.expectEqual(@as(usize, 0), p.settings.len);
        }
    }
}
