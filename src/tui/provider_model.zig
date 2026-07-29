//! Provider connection, model catalogue loading, and model selection.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const tui = @import("../tui.zig");
const lua_c = @import("c");
const ai = @import("../ai.zig");
const auth = @import("../auth/store.zig");
const bash_mod = @import("../tools/bash_exec.zig");
const codex = @import("../auth/codex.zig");
const config_mod = @import("../config/config.zig");
const model_catalogue = @import("model_catalogue.zig");
const model_cache = @import("model_cache.zig");
const model_loader = @import("model_loader.zig");
const model_picker = @import("widgets/model_picker.zig");
const openai_compatible_mod = @import("../ai/openai_compatible.zig");
const provider_picker = @import("widgets/provider_picker.zig");
const runtime_mod = @import("../runtime.zig");
const session_mod = @import("../session.zig");
const tui_provider = @import("provider_controller.zig");
const tui_status = @import("status.zig");
const tools_common = @import("../tools/common.zig");
const modelsdev = @import("../models/registry.zig");

const App = tui.App;
const ModelCatalog = tui.App.ModelCatalog;
const ModelScope = model_catalogue.ModelScope;
const ModelSource = model_loader.ModelSource;
pub fn openProviderPicker(self: *App) !void {
    self.mode = .provider_picker;
    self.pickers.provider.reset();
    self.clearInput();
    self.clearPaletteInput();
    try refreshProviderApiKeys(self);
    // Always refresh the models.dev registry so newly added providers
    // appear immediately instead of waiting for the 24h cache TTL.
    if (self.provider_state.modelsdev_registry) |*r| {
        r.deinit(self.gpa);
        self.provider_state.modelsdev_registry = null;
    }
    try ensureModelsDevRegistry(self);
    // Refresh the badges from a live model load (merge, so the catalogue isn't
    // cleared). The load's per-provider outcome drives `conn_status`, so the
    // badge reads the same source as the model picker and can't disagree.
    startModelLoad(self, .connected_provider, true) catch {};
}

pub fn ensureModelsDevRegistry(self: *App) !void {
    if (self.provider_state.modelsdev_registry == null) {
        const home = if (self.liveRuntime()) |r| r.home_dir else "";
        self.provider_state.modelsdev_registry = modelsdev.loadOrFetchRegistry(self.gpa, self.io, home);
    }
    if (self.provider_state.modelsdev_registry) |*reg| {
        try buildMergedProviderList(self, reg.providers);
    }
}

/// Three-layer merge: builtin catalogue → models.dev (overrides) → config
/// (overrides). The result is a single `[]ProviderHandle` that the picker
/// renders uniformly.
fn buildMergedProviderList(self: *App, all_providers: []const modelsdev.Provider) !void {
    var entries: std.ArrayList(provider_picker.ProviderHandle) = .empty;
    defer entries.deinit(self.gpa);

    // Layer 1: builtin catalogue (lowest priority).
    for (config_mod.catalogueProviders()) |p| {
        try entries.append(self.gpa, .{ .builtin = p });
    }

    // Layer 2: models.dev registry (overrides builtins with same id).
    for (all_providers) |p| {
        if (std.mem.eql(u8, p.id, "openai")) continue;
        if (findEntryIndex(entries.items, p.id)) |idx| {
            entries.items[idx] = .{ .dynamic = p };
        } else {
            try entries.append(self.gpa, .{ .dynamic = p });
        }
    }

    // Layer 3: config providers (overrides everything with same name).
    // Skip entries already covered by the models.dev registry — those are
    // dynamic providers whose model selection is persisted in the providers
    // array but whose identity (name, base_url) comes from the registry.
    // Without this guard the config entry shadows the .dynamic handle and
    // the picker shows the provider as a custom/config provider.
    if (self.cached_config_owned) {
        for (self.cached_config.providers) |cp| {
            if (self.provider_state.modelsdev_registry) |*reg| {
                if (reg.lookup(cp.name) != null) continue;
            }
            if (findEntryIndex(entries.items, cp.name)) |idx| {
                entries.items[idx] = .{ .config = cp };
            } else {
                try entries.append(self.gpa, .{ .config = cp });
            }
        }
    }

    if (self.provider_state.entries_slice) |old| self.gpa.free(old);
    const owned = try entries.toOwnedSlice(self.gpa);
    self.provider_state.entries_slice = owned;
    self.pickers.provider.entries = owned;
}

fn findEntryIndex(entries: []const provider_picker.ProviderHandle, id: []const u8) ?usize {
    for (entries, 0..) |e, i| {
        if (std.mem.eql(u8, e.id(), id)) return i;
    }
    return null;
}

pub fn catalogueIndexById(id: []const u8) ?usize {
    for (config_mod.catalogueProviders(), 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate.label(), id)) return index;
    }
    return null;
}

/// Reload the cached provider API keys from `~/.config/nova/auth.json`. Drives the
/// picker badges and the multi-provider model catalogue.
pub fn refreshProviderApiKeys(self: *App) !void {
    const home = self.liveRuntime().?.home_dir;
    if (home.len == 0) return;
    var fresh = try auth.loadAllProviderApiKeys(self.gpa, self.io, home);
    auth.freeApiKeyMap(self.gpa, &self.provider_state.api_keys);
    self.provider_state.api_keys = fresh;
    fresh = .empty;
}

/// Index of `provider` within `catalogueProviders()` — the order `conn_status`
/// is keyed by. Null when it isn't a catalogue provider (no badge row).
pub fn catalogueIndex(provider: config_mod.Provider) ?usize {
    for (config_mod.catalogueProviders(), 0..) |candidate, index| {
        if (candidate == provider) return index;
    }
    return null;
}

/// Fold a finished model load's per-provider outcomes into the picker badges.
/// A full connected-provider sweep (`conn_recompute`) first clears every badge
/// to `.unknown`, so a provider dropped from the configured set (key removed)
/// stops reading connected; a single-provider load updates only what it
/// fetched.
pub fn applyProviderOutcomes(self: *App, outcomes: []const model_loader.ProviderOutcome) void {
    if (self.provider_state.conn_recompute) self.provider_state.conn_status = @splat(.unknown);
    for (outcomes) |outcome| {
        const index = catalogueIndex(outcome.provider) orelse continue;
        self.provider_state.conn_status[index] = if (outcome.ok) .connected else .failed;
    }
}

pub fn openProviderEntryForm(self: *App, handle: provider_picker.ProviderHandle) void {
    self.pickers.provider.stage = .form;
    self.pickers.provider.form_handle = handle;
    self.pickers.provider.form_error = null;
    self.input_buffers.provider_key.clearRetainingCapacity();
    if (self.provider_state.api_keys.get(handle.id())) |existing| {
        self.input_buffers.provider_key.appendSlice(self.gpa, existing) catch {};
    }
}

pub fn openModelPicker(self: *App) !void {
    self.mode = .model_picker;
    tui.rebuildReasoningOptsCache(self);
    self.pickers.models.model_column = .model;
    self.pickers.models.model_selection = 0;
    self.pickers.models.model_scope = defaultModelScope(
        self,
    );
    self.clearInput();

    if (self.pickers.models.models_cached and self.pickers.models.len() > 0) {
        try finishModelCatalogReload(
            self,
        );
        try snapshotModelPickerState(
            self,
        );
        return;
    }

    if (try restoreModelCache(
        self,
    )) {
        // Stale-while-revalidate (same pattern as the diff cache): the disk
        // cache shows instantly, but it can predate a provider connected
        // since it was written — e.g. an Ollama Cloud key added or renewed
        // later, so the cache holds only the providers that were live then.
        // Refresh connected providers in the background and MERGE: present
        // providers update in place, newly-reachable ones appear, and any
        // that fail keep their cached entries.
        startModelLoad(self, .connected_provider, true) catch {};
        return;
    }

    // Cold path — clear stale state, kick off the async load.
    codexModelsClear(
        self,
    );
    self.pickers.models.reasoning_snapshot.clearRetainingCapacity();
    self.pickers.models.model_selection_snapshot = 0;
    try startModelLoad(self, .connected_provider, false);
}

pub fn snapshotModelPickerState(self: *App) !void {
    try self.pickers.models.snapshot(self.gpa);
}

pub fn startModelLoad(self: *App, catalog: ModelCatalog, merge: bool) !void {
    cancelModelLoad(self);
    // A connected-provider sweep fetches every configured provider, so its
    // result is authoritative for all badges; an openai_codex load touches no
    // catalogue providers and must not reset them.
    self.provider_state.conn_recompute = catalog == .connected_provider;
    if (self.pickers.models.load == .failed) {
        self.gpa.free(self.pickers.models.load.failed.message);
        self.pickers.models.load = .idle;
    }

    const job = try self.gpa.create(model_loader.Job);
    errdefer self.gpa.destroy(job);

    const configured = try collectConfiguredProviders(self, catalog);
    errdefer {
        for (configured) |c| {
            self.gpa.free(c.base_url);
            self.gpa.free(c.api_key);
        }
        if (configured.len > 0) self.gpa.free(configured);
    }

    // Transition load to .loading. The job captures the address of the
    // union's `done` field; the union must stay in .loading (no other
    // writes to load) until drainModelLoad moves it out.
    self.pickers.models.load = .{
        .loading = .{
            .future = undefined, // set below
            .done = .init(false),
            .merge = merge,
        },
    };
    job.* = .{
        .gpa = self.gpa,
        .io = self.io,
        .catalog = switch (catalog) {
            .connected_provider => .connected_provider,
            .openai_codex => .openai_codex,
        },
        .configured = configured,
        .include_locals = catalog == .connected_provider,
        .codex_signed_in = self.isCodexSignedIn(),
        .done = &self.pickers.models.load.loading.done,
    };
    self.pickers.models.load.loading.future = try self.io.concurrent(model_loader.run, .{job});
}

/// Every OpenAI-compatible provider to fetch for a full catalogue reload:
/// each catalogue provider with a stored key (or an anonymous tier), plus a
/// non-catalogue env/config provider when one is configured. Caller owns the slice.
pub fn collectConfiguredProviders(self: *App, catalog: ModelCatalog) ![]model_loader.Configured {
    var list: std.ArrayList(model_loader.Configured) = .empty;
    errdefer {
        for (list.items) |c| {
            self.gpa.free(c.base_url);
            self.gpa.free(c.api_key);
            if (c.display_name) |d| self.gpa.free(d);
        }
        list.deinit(self.gpa);
    }
    if (catalog == .connected_provider) {
        for (config_mod.catalogueProviders()) |provider| {
            const base_url = provider.defaultBaseUrl() orelse continue;
            // Stored key wins; otherwise an anonymous-tier provider (OpenCode
            // Zen) still loads via its `public` sentinel (free models only).
            const key = self.provider_state.api_keys.get(provider.label()) orelse anon: {
                break :anon provider.anonymousApiKey() orelse continue;
            };
            // Katalog provider'ları auth.json'a label'larıyla kaydolur; null
            // bırakmak compatibleSource'a label'a düşürür.
            try appendConfigured(self, &list, provider, base_url, key, null);
        }
        if (self.provider_state.modelsdev_registry) |*reg| {
            var it = self.provider_state.api_keys.iterator();
            while (it.next()) |entry| {
                const id = entry.key_ptr.*;
                if (catalogueIndexById(id) != null) continue;
                if (reg.lookup(id)) |dyn_p| {
                    // auth_key_id = registry id (auth.json anahtarı). entry.key_ptr.*
                    // zaten bu id'ye eşittir.
                    try appendConfiguredDynamic(self, &list, dyn_p.base_url, entry.value_ptr.*, dyn_p.name, id);
                }
            }
        }
        if (shouldLoadConfiguredCompatibleCatalog(self)) {
            const ms = self.cached_config.model_selection orelse return list.toOwnedSlice(self.gpa);
            const provider = ms.provider();
            // Catalogue providers are covered by block 1; dynamic providers
            // with a stored key are covered by block 2 (models.dev registry).
            // Only add a block-3 entry for providers neither block handles
            // (e.g. a config-defined custom endpoint not in models.dev).
            const covered_by_registry = blk: {
                // After session resume dynamic_provider_id is null (runtime-only);
                // fall back to the serialized model_selection.provider_name.
                const id = self.cached_config.dynamic_provider_id orelse ms.providerName();
                if (self.provider_state.api_keys.get(id) == null) break :blk false;
                if (self.provider_state.modelsdev_registry) |*reg| {
                    if (reg.lookup(id) != null) break :blk true;
                }
                break :blk false;
            };
            if (!provider.isCatalogue() and !covered_by_registry) {
                // base_url may be "" when synthesized from session metadata or
                // legacy fields; resolve through the provider default.
                const base_url = if (ms.baseUrl()) |url| if (url.len > 0) url else provider.defaultBaseUrl() orelse return list.toOwnedSlice(self.gpa) else provider.defaultBaseUrl() orelse return list.toOwnedSlice(self.gpa);
                // ms.api_key is always "" (keys live in auth.json). Resolve
                // the stored key so the model fetch authenticates correctly.
                const api_key = blk: {
                    if (ms.apiKey()) |key| {
                        if (key.len > 0) break :blk key;
                    }
                    if (self.cached_config.dynamic_provider_id) |id| {
                        break :blk self.provider_state.api_keys.get(id) orelse "";
                    }
                    break :blk self.provider_state.api_keys.get(ms.providerName()) orelse "";
                };
                try appendConfigured(self, &list, provider, base_url, api_key, ms.providerName());
            }
        }
    }
    return list.toOwnedSlice(self.gpa);
}

pub fn appendConfiguredDynamic(
    self: *App,
    list: *std.ArrayList(model_loader.Configured),
    base_url: []const u8,
    api_key: []const u8,
    display_name: []const u8,
    auth_key_id: []const u8,
) !void {
    const url = try self.gpa.dupe(u8, base_url);
    errdefer self.gpa.free(url);
    const key = try self.gpa.dupe(u8, api_key);
    errdefer self.gpa.free(key);
    const name = try self.gpa.dupe(u8, display_name);
    errdefer self.gpa.free(name);
    const id = try self.gpa.dupe(u8, auth_key_id);
    errdefer self.gpa.free(id);
    try list.append(self.gpa, .{
        .provider = .openai_compatible,
        .base_url = url,
        .api_key = key,
        .display_name = name,
        .auth_key_id = id,
    });
}

pub fn appendConfigured(
    self: *App,
    list: *std.ArrayList(model_loader.Configured),
    provider: config_mod.Provider,
    base_url: []const u8,
    api_key: []const u8,
    auth_key_id: ?[]const u8,
) !void {
    const url = try self.gpa.dupe(u8, base_url);
    errdefer self.gpa.free(url);
    const key = try self.gpa.dupe(u8, api_key);
    errdefer self.gpa.free(key);
    const id: ?[]u8 = if (auth_key_id) |k| try self.gpa.dupe(u8, k) else null;
    errdefer if (id) |owned| self.gpa.free(owned);
    try list.append(self.gpa, .{ .provider = provider, .base_url = url, .api_key = key, .auth_key_id = id });
}

pub const model_loader_job = @import("model_loader_job.zig");
pub const cancelModelLoad = model_loader_job.cancelModelLoad;
pub const drainModelLoad = model_loader_job.drainModelLoad;
pub const installModelLoadResult = model_loader_job.installModelLoadResult;
pub const dropModelsForProvider = model_loader_job.dropModelsForProvider;
pub const restoreModelCache = model_loader_job.restoreModelCache;
pub const saveModelCache = model_loader_job.saveModelCache;
pub const collectModelCacheConfigured = model_loader_job.collectModelCacheConfigured;

pub fn defaultModelScope(self: *App) ModelScope {
    const runtime = self.liveRuntime() orelse return .global;
    if (config_mod.projectConfigExists(self.gpa, self.io, runtime.cwd)) return .project;
    return .global;
}

pub fn connectCodex(self: *App) !void {
    if (self.thread.turn.isActive()) return error.InFlightTurn;
    var credentials = try codex.login(self.gpa, self.io, self.liveRuntime().?.home_dir);
    defer credentials.deinit(self.gpa);
    self.pickers.models.models_cached = false;
    try reloadModelCatalog(self, .openai_codex);
    const model = selectedCodexModel(
        self,
    ) orelse return error.NoModels;
    const effort = selectedReasoningEffort(
        self,
    );
    try connectCodexClient(self, credentials, model.id, effort);
    self.codex_signed_in = true;
    self.liveRuntime().?.codex_connection_expired = false;
    try persistModelSelection(self, .openai, null, model.id, effort, .global);
    self.mode = .normal;
    self.clearInput();
    _ = try self.thread.transcript.append(self.gpa, .agent, "agent", "Connected to OpenAI Codex.");
}

pub fn signOutCodex(self: *App) !void {
    if (self.thread.turn.isActive()) return error.InFlightTurn;
    // The naming client is about to be freed; no job may still borrow it.
    self.cancelLaneNaming(self.thread);
    try codex.signOut(self.gpa, self.io, self.liveRuntime().?.home_dir);
    self.liveRuntime().?.disconnectCodexClient();
    self.codex_signed_in = false;
    self.liveRuntime().?.codex_connection_expired = false;
    self.thread.agent.?.client = self.liveRuntime().?.client;
    codexModelsClear(
        self,
    );
    self.pickers.models.models_cached = false;
    self.mode = .normal;
    self.clearInput();
    _ = try self.thread.transcript.append(self.gpa, .agent, "agent", "Signed out from OpenAI Codex.");
}

/// Save the entered API key for a catalogue provider, then fetch just that
/// provider's models and merge them into the catalogue before handing off to
/// the model picker. A blank key is allowed only for providers that don't
/// require one (`requiresApiKey() == false`); all current ones do.
pub fn submitProviderSetup(self: *App, provider: config_mod.Provider) !void {
    if (self.thread.turn.isActive()) return error.InFlightTurn;
    var key = std.mem.trim(u8, self.input_buffers.provider_key.items, " \t\r\n");
    if (key.len == 0) {
        if (self.provider_state.api_keys.get(provider.label())) |existing| {
            key = existing;
        }
    }

    // A required key cannot be blank — keep the form open so the user can type.
    if (key.len == 0 and provider.requiresApiKey()) {
        self.pickers.provider.form_error = "API key is required to connect to this provider.";
        return;
    }

    const home = self.liveRuntime().?.home_dir;
    if (key.len > 0) {
        try auth.saveProviderApiKey(self.gpa, self.io, home, provider.label(), key);
    } else {
        // Anonymous free tier: drop any stale key so we connect without one.
        auth.removeProviderApiKey(self.gpa, self.io, home, provider.label()) catch {};
    }
    try refreshProviderApiKeys(
        self,
    );

    // Clear stale connection state when switching to a builtin. Without
    // this, legacy fields from a previous dynamic/config provider linger
    // and hasOpenAICompatibleCredentials (or any direct legacy reader)
    // sees the wrong provider's URL and key.
    if (self.cached_config_owned) {
        if (self.cached_config.dynamic_provider_name) |prev| self.gpa.free(prev);
        self.cached_config.dynamic_provider_name = null;
        if (self.cached_config.dynamic_provider_id) |prev| self.gpa.free(prev);
        self.cached_config.dynamic_provider_id = null;
        if (self.cached_config.base_url) |prev| self.gpa.free(prev);
        self.cached_config.base_url = null;
        if (self.cached_config.api_key) |prev| self.gpa.free(prev);
        self.cached_config.api_key = null;
        self.cached_config.provider = provider;
    }

    // With no key, connect via the provider's anonymous sentinel (e.g.
    // OpenCode Zen's `public`, which the gateway limits to free models).
    const connect_key = if (key.len > 0) key else (provider.anonymousApiKey() orelse key);
    // `connect_key` may alias the input buffer — fetch (which dupes it) first.
    try startProviderModelLoad(self, provider, connect_key);

    self.pickers.provider.stage = .list;
    self.pickers.provider.form_handle = null;
    self.input_buffers.provider_key.clearRetainingCapacity();

    self.mode = .model_picker;
    tui.rebuildReasoningOptsCache(self);
    self.pickers.models.model_column = .model;
    self.pickers.models.model_selection = 0;
    self.pickers.models.model_scope = defaultModelScope(
        self,
    );
    self.pickers.models.reasoning_snapshot.clearRetainingCapacity();
    self.pickers.models.model_selection_snapshot = 0;
    self.clearInput();
    self.clearPaletteInput();
}

pub fn submitDynamicProviderSetup(self: *App, provider: modelsdev.Provider) !void {
    if (self.thread.turn.isActive()) return error.InFlightTurn;
    var key = std.mem.trim(u8, self.input_buffers.provider_key.items, " \t\r\n");
    if (key.len == 0) {
        if (self.provider_state.api_keys.get(provider.id)) |existing| {
            key = existing;
        }
    }

    if (key.len == 0 and provider.requires_api_key) {
        self.pickers.provider.form_error = "API key is required to connect to this provider.";
        return;
    }

    const home = self.liveRuntime().?.home_dir;
    if (key.len > 0) {
        try auth.saveProviderApiKey(self.gpa, self.io, home, provider.id, key);
    } else {
        auth.removeProviderApiKey(self.gpa, self.io, home, provider.id) catch {};
    }
    try refreshProviderApiKeys(self);

    // Stash the dynamic provider's base_url and api_key into cached_config.
    // applySelectedModel artık doğrudan seçili entry'nin conn'undan çözüm
    // yaptığı için bunlara güvenmez; stash session resume
    // (tryAttachOpenAiCompatibleFromConfig) ve hasOpenAICompatibleCredentials
    // için tutulur. Seçim anında updateCachedModelSelection bunları entry'den
    // gelen değerlerle tutarlı kılar.
    if (self.cached_config_owned) {
        const owned_url = try self.gpa.dupe(u8, provider.base_url);
        if (self.cached_config.base_url) |prev| self.gpa.free(prev);
        self.cached_config.base_url = owned_url;

        const owned_key = try self.gpa.dupe(u8, key);
        if (self.cached_config.api_key) |prev| self.gpa.free(prev);
        self.cached_config.api_key = owned_key;

        self.cached_config.provider = .openai_compatible;

        // Stash the human-readable provider name for the status bar.
        if (self.cached_config.dynamic_provider_name) |prev| self.gpa.free(prev);
        self.cached_config.dynamic_provider_name = try self.gpa.dupe(u8, provider.name);

        // Stash the provider id (auth.json key, e.g. "stepfun-ai") so
        // model_selection.provider_name and auth lookups resolve correctly.
        if (self.cached_config.dynamic_provider_id) |prev| self.gpa.free(prev);
        self.cached_config.dynamic_provider_id = try self.gpa.dupe(u8, provider.id);
    }

    const connect_key = if (key.len > 0) key else (provider.anonymous_key orelse key);
    try startDynamicProviderModelLoad(self, provider, connect_key);

    self.pickers.provider.stage = .list;
    self.pickers.provider.form_handle = null;
    self.input_buffers.provider_key.clearRetainingCapacity();

    self.mode = .model_picker;
    tui.rebuildReasoningOptsCache(self);
    self.pickers.models.model_column = .model;
    self.pickers.models.model_selection = 0;
    self.pickers.models.model_scope = defaultModelScope(self);
    self.pickers.models.reasoning_snapshot.clearRetainingCapacity();
    self.pickers.models.model_selection_snapshot = 0;
    self.clearInput();
    self.clearPaletteInput();
}

pub fn submitConfigProviderSetup(self: *App, provider: config_mod.ProviderConfig) !void {
    if (self.thread.turn.isActive()) return error.InFlightTurn;
    var key = std.mem.trim(u8, self.input_buffers.provider_key.items, " \t\r\n");
    if (key.len == 0) {
        if (self.provider_state.api_keys.get(provider.name)) |existing| {
            key = existing;
        }
    }

    if (key.len == 0) {
        self.pickers.provider.form_error = "API key is required to connect to this provider.";
        return;
    }

    const home = self.liveRuntime().?.home_dir;
    try auth.saveProviderApiKey(self.gpa, self.io, home, provider.name, key);
    try refreshProviderApiKeys(self);

    // Resolve the base URL: explicit custom URL wins, otherwise fall back
    // to the provider enum's default (e.g. openai_compatible has none).
    const base_url: []const u8 = switch (provider.base_url) {
        .custom => |url| url,
        .default => provider.provider.defaultBaseUrl() orelse "",
    };

    if (self.cached_config_owned) {
        const owned_url = try self.gpa.dupe(u8, base_url);
        if (self.cached_config.base_url) |prev| self.gpa.free(prev);
        self.cached_config.base_url = owned_url;

        const owned_key = try self.gpa.dupe(u8, key);
        if (self.cached_config.api_key) |prev| self.gpa.free(prev);
        self.cached_config.api_key = owned_key;

        self.cached_config.provider = .openai_compatible;

        if (self.cached_config.dynamic_provider_name) |prev| self.gpa.free(prev);
        self.cached_config.dynamic_provider_name = try self.gpa.dupe(u8, provider.name);

        // For config providers, the auth.json key equals the config map key.
        if (self.cached_config.dynamic_provider_id) |prev| self.gpa.free(prev);
        self.cached_config.dynamic_provider_id = try self.gpa.dupe(u8, provider.name);
    }

    // For config providers, the auth.json key equals the config map key
    // (provider.name) — thread it so models are stamped with the right id.
    try startOpenAiCompatibleModelLoad(self, base_url, key, provider.name, provider.name);

    self.pickers.provider.stage = .list;
    self.pickers.provider.form_handle = null;
    self.input_buffers.provider_key.clearRetainingCapacity();

    self.mode = .model_picker;
    tui.rebuildReasoningOptsCache(self);
    self.pickers.models.model_column = .model;
    self.pickers.models.model_selection = 0;
    self.pickers.models.model_scope = defaultModelScope(self);
    self.pickers.models.reasoning_snapshot.clearRetainingCapacity();
    self.pickers.models.model_selection_snapshot = 0;
    self.clearInput();
    self.clearPaletteInput();
}

pub fn startDynamicProviderModelLoad(self: *App, provider: modelsdev.Provider, key: []const u8) !void {
    // provider.id is the auth.json key (e.g. "stepfun-ai"). Threading it as
    // auth_key_id keeps every fetched model associated with the right provider
    // so the disk cache round-trips and applySelectedModel resolves the key.
    try startOpenAiCompatibleModelLoad(self, provider.base_url, key, provider.name, provider.id);
}

/// Shared model-load path for any OpenAI-compatible endpoint (models.dev
/// dynamic providers and user-defined config providers).
///
/// `auth_key_id` is the auth.json key identity (e.g. "stepfun-ai") that the
/// fetched models are stamped with. It MUST be the real provider id, never
/// null for dynamic/config providers — otherwise `compatibleSource` falls back
/// to `provider.label()` ("openai_compatible"), every dynamic provider's models
/// become indistinguishable, the disk cache can't match them on restart, and
/// `applySelectedModel` resolves the wrong (empty) API key. Catalogue builtin
/// callers may pass null to keep the `provider.label()` fallback.
pub fn startOpenAiCompatibleModelLoad(
    self: *App,
    base_url: []const u8,
    key: []const u8,
    display_name: []const u8,
    auth_key_id: ?[]const u8,
) !void {
    cancelModelLoad(self);
    self.provider_state.conn_recompute = false;
    if (self.pickers.models.load == .failed) {
        self.gpa.free(self.pickers.models.load.failed.message);
        self.pickers.models.load = .idle;
    }

    var configured = try self.gpa.alloc(model_loader.Configured, 1);
    errdefer self.gpa.free(configured);

    const url = try self.gpa.dupe(u8, base_url);
    errdefer self.gpa.free(url);
    const k = try self.gpa.dupe(u8, key);
    errdefer self.gpa.free(k);
    const name = try self.gpa.dupe(u8, display_name);
    errdefer self.gpa.free(name);
    const owned_auth_key_id: ?[]u8 = if (auth_key_id) |id| try self.gpa.dupe(u8, id) else null;
    errdefer if (owned_auth_key_id) |id| self.gpa.free(id);

    configured[0] = .{
        .provider = .openai_compatible,
        .base_url = url,
        .api_key = k,
        .display_name = name,
        .auth_key_id = owned_auth_key_id,
    };

    const job = try self.gpa.create(model_loader.Job);
    errdefer self.gpa.destroy(job);

    self.pickers.models.load = .{ .loading = .{
        .future = undefined,
        .done = .init(false),
        .merge = false,
    } };
    job.* = .{
        .gpa = self.gpa,
        .io = self.io,
        .catalog = .single_provider,
        .configured = configured,
        .include_locals = false,
        .codex_signed_in = false,
        .done = &self.pickers.models.load.loading.done,
    };
    self.pickers.models.load.loading.future = try self.io.concurrent(model_loader.run, .{job});
}

/// Incremental, merge-on-arrival load of a single provider's `/models`.
pub fn startProviderModelLoad(self: *App, provider: config_mod.Provider, key: []const u8) !void {
    cancelModelLoad(self);
    // Single provider: its outcome updates only this provider's badge, never
    // a full recompute that would wipe the others.
    self.provider_state.conn_recompute = false;
    if (self.pickers.models.load == .failed) {
        self.gpa.free(self.pickers.models.load.failed.message);
        self.pickers.models.load = .idle;
    }

    const base_url_default = provider.defaultBaseUrl() orelse return error.NotConnected;

    const job = try self.gpa.create(model_loader.Job);
    errdefer self.gpa.destroy(job);

    const configured = try self.gpa.alloc(model_loader.Configured, 1);
    errdefer self.gpa.free(configured);
    const base_url = try self.gpa.dupe(u8, base_url_default);
    errdefer self.gpa.free(base_url);
    const api_key = try self.gpa.dupe(u8, key);
    errdefer self.gpa.free(api_key);
    configured[0] = .{ .provider = provider, .base_url = base_url, .api_key = api_key };

    self.pickers.models.load = .{ .loading = .{
        .future = undefined,
        .done = .init(false),
        .merge = true,
    } };
    job.* = .{
        .gpa = self.gpa,
        .io = self.io,
        .catalog = .single_provider,
        .configured = configured,
        .include_locals = false,
        .codex_signed_in = self.isCodexSignedIn(),
        .done = &self.pickers.models.load.loading.done,
    };
    self.pickers.models.load.loading.future = try self.io.concurrent(model_loader.run, .{job});
}

pub fn applySelectedModel(self: *App) !void {
    if (self.thread.turn.state == .interrupting) self.discardAbandonedTurn();
    if (self.thread.turn.isActive()) return error.InFlightTurn;
    const model = selectedCodexModel(
        self,
    ) orelse return error.NoModels;
    const effort = selectedReasoningEffort(
        self,
    );

    const source = selectedModelSource(
        self,
    ) orelse return error.NoModels;
    // Resolve the auth/config provider identity to persist into the session DB
    // so initResume restores the last-used model on restart. This mirrors what
    // runtime.applyFromConfig writes (selection.providerName()). Without it the
    // picker only updated config.json and the session row kept its original
    // model, so restart restored a stale selection.
    const provider_name: []const u8 = switch (source) {
        .openai_codex => config_mod.Provider.openai.label(),
        .openai_compatible => |conn| conn.auth_key_id,
    };
    // A null/empty model_id flows into Client.init's non-optional `[]u8`
    // (openai_compatible.zig:59) and segfaults on resume. selectedCodexModel
    // guards storage validity but not an empty id, so check it explicitly.
    // A real early return (not assert): `unreachable` is UB in ReleaseFast,
    // which is the install target, so an assert would not protect that build.
    if (model.id.len == 0) return error.EmptyModelId;
    switch (source) {
        .openai_codex => {
            const loaded = try codex.load(self.gpa, self.io, self.liveRuntime().?.home_dir);
            if (loaded) |codex_creds| {
                var credentials = codex_creds;
                defer credentials.deinit(self.gpa);
                try connectCodexClient(self, credentials, model.id, effort);
                self.codex_signed_in = true;
                try persistModelSelection(self, .openai, null, model.id, effort, self.pickers.models.model_scope);
            } else {
                return error.NotConnected;
            }
        },
        .openai_compatible => |conn| {
            // Entry kendi tam bağlantı bilgisini taşır (base_url + auth_key_id).
            // cached_config'in global tek değerine bakmak yerine doğrudan entry'den
            // çözümle — çoklu provider kataloğunda yanlış provider'a bağlanmayı
            // önler.
            const api_key = compatibleApiKeyForConn(self, conn);
            if (api_key.len == 0 and conn.provider.requiresApiKey()) return error.NotConnected;
            try attachOpenAiCompatibleClient(self, conn.base_url, api_key, model.id, effort);
            try persistModelSelection(self, conn.provider, conn, model.id, effort, self.pickers.models.model_scope);
        },
    }
    // Persist the new selection into the session DB so resume restores the
    // last-used model, not the one active at session creation. Best-effort: a
    // DB error must not roll back the (already applied) client switch. Only
    // run when the writer is started — some test harnesses build a partial
    // runtime with an undefined session_writer.
    if (self.liveRuntime()) |rt| {
        if (rt.session_writer_started) {
            rt.session_writer.updateModel(provider_name, model.id) catch |err| {
                std.log.warn("session.updateModel.failed provider={s} model={s} err={s}", .{ provider_name, model.id, @errorName(err) });
            };
        }
    }
    self.mode = .normal;
    self.clearInput();
}

pub fn persistModelSelection(
    self: *App,
    provider: config_mod.Provider,
    conn: ?model_loader.Compatible,
    model_id: []const u8,
    effort: ai.ReasoningEffort,
    scope: ModelScope,
) !void {
    try updateCachedModelSelection(self, provider, conn, model_id, effort);
    if (scope == .session) return;

    var updates = try modelSelectionUpdates(self, provider, conn, model_id, effort);
    defer updates.deinit(self.gpa);
    switch (scope) {
        .global => config_mod.mergeAndWriteGlobal(self.gpa, self.io, self.liveRuntime().?.home_dir, updates) catch |err| {
            std.log.warn("config.write.failed err={s}", .{@errorName(err)});
        },
        .project => config_mod.mergeAndWriteProject(self.gpa, self.io, self.liveRuntime().?.cwd, updates) catch |err| {
            std.log.warn("project.config.write.failed err={s}", .{@errorName(err)});
        },
        .session => unreachable,
    }
}

pub fn updateCachedModelSelection(
    self: *App,
    provider: config_mod.Provider,
    conn: ?model_loader.Compatible,
    model_id: []const u8,
    effort: ai.ReasoningEffort,
) !void {
    const new_id = try self.gpa.dupe(u8, model_id);
    errdefer self.gpa.free(new_id);
    if (self.cached_config_owned) {
        const resolved = resolveConn(provider, conn);
        if (self.cached_config.model_selection) |*ms| {
            ms.deinit(self.gpa);
            if (provider == .openai_compatible) {
                self.cached_config.model_selection = .{
                    .custom = .{
                        .provider_name = try self.gpa.dupe(u8, resolved.auth_key_id),
                        .base_url = try self.gpa.dupe(u8, resolved.base_url),
                        .api_key = try self.gpa.dupe(u8, ""),
                        .model = .{ .id = new_id, .reasoning = .{ .effort = effort } },
                    },
                };
            } else {
                self.cached_config.model_selection = .{
                    .builtin = .{
                        .provider = provider,
                        .provider_name = try self.gpa.dupe(u8, resolved.auth_key_id),
                        .model = .{ .id = new_id, .reasoning = .{ .effort = effort } },
                    },
                };
            }
            try updateCachedProviderConnection(self, provider, resolved);
        } else {
            // No selection yet — bootstrap a minimal one from the resolved
            // connection (provider default for builtins, entry values for
            // compatible).
            if (provider == .openai_compatible) {
                self.cached_config.model_selection = .{
                    .custom = .{
                        .provider_name = try self.gpa.dupe(u8, resolved.auth_key_id),
                        .base_url = try self.gpa.dupe(u8, resolved.base_url),
                        .api_key = try self.gpa.dupe(u8, ""),
                        .model = .{ .id = new_id, .reasoning = .{ .effort = effort } },
                    },
                };
            } else {
                self.cached_config.model_selection = .{
                    .builtin = .{
                        .provider = provider,
                        .provider_name = try self.gpa.dupe(u8, resolved.auth_key_id),
                        .model = .{ .id = new_id, .reasoning = .{ .effort = effort } },
                    },
                };
            }
            try updateCachedProviderConnection(self, provider, resolved);
        }
    } else {
        self.gpa.free(new_id);
    }
}

/// Bir seçim için çözümlenmiş bağlantı: provider default URL/key (builtin'ler
/// için) ya da entry'nin kendi `conn` değerleri (compatible yolu). `conn` null
/// olduğunda (codex, veya güvenli olmayan eski çağrılar) cached_config'in
/// dynamic_provider_id/base_url stash'ine düşer.
const ResolvedConn = struct {
    base_url: []const u8,
    auth_key_id: []const u8,
};

fn resolveConn(provider: config_mod.Provider, conn: ?model_loader.Compatible) ResolvedConn {
    if (conn) |c| return .{ .base_url = c.base_url, .auth_key_id = c.auth_key_id };
    // conn null yalnızca codex (.openai) yolunda olabilir; builtin/custom
    // seçimleri daima conn ile gelir. Provider default'una düş.
    return .{
        .base_url = provider.defaultBaseUrl() orelse "",
        .auth_key_id = provider.label(),
    };
}

pub fn updateCachedProviderConnection(self: *App, provider: config_mod.Provider, resolved: ResolvedConn) !void {
    if (provider == .openai_compatible) {
        // Compatible providers: entry'nin tam bağlantısını cached_config
        // legacy alanlarına ve model_selection'a aynala, böylece session resume
        // (tryAttachOpenAiCompatibleFromConfig) doğru endpoint + auth.json
        // anahtarını çözümler.
        if (resolved.base_url.len > 0) {
            try stashCachedBaseUrl(self, resolved.base_url);
            try replaceCachedBaseUrl(self, resolved.base_url);
        }
        if (resolved.auth_key_id.len > 0) {
            try stashCachedDynamicId(self, resolved.auth_key_id);
            try replaceCachedProviderName(self, resolved.auth_key_id);
        }
        return;
    }
    if (provider.defaultBaseUrl()) |base_url| try replaceCachedBaseUrl(self, base_url);
    clearCachedApiKey(
        self,
    );
}

pub fn replaceCachedBaseUrl(self: *App, base_url: []const u8) !void {
    const owned = try self.gpa.dupe(u8, base_url);
    if (self.cached_config.model_selection) |*ms| {
        switch (ms.*) {
            .builtin => {
                self.gpa.free(owned);
            },
            .custom => |*c| {
                self.gpa.free(c.base_url);
                c.base_url = owned;
            },
        }
    } else {
        self.gpa.free(owned);
    }
}

pub fn replaceCachedProviderName(self: *App, name: []const u8) !void {
    const owned = try self.gpa.dupe(u8, name);
    errdefer self.gpa.free(owned);
    if (self.cached_config.model_selection) |*ms| {
        switch (ms.*) {
            .builtin => |*b| {
                self.gpa.free(b.provider_name);
                b.provider_name = owned;
            },
            .custom => |*c| {
                self.gpa.free(c.provider_name);
                c.provider_name = owned;
            },
        }
    } else {
        self.gpa.free(owned);
    }
}

pub fn clearCachedApiKey(self: *App) void {
    if (self.cached_config.model_selection) |*ms| {
        // Replace with empty string (api_key is non-optional in
        // ModelSelection; clearing means the user will be prompted
        // again). The previous key is freed.
        switch (ms.*) {
            .custom => |*c| {
                const new_key = self.gpa.dupe(u8, "") catch return;
                self.gpa.free(c.api_key);
                c.api_key = new_key;
            },
            .builtin => {},
        }
    }
}

/// `cached_config.base_url` legacy alanını (runtime-only, serialize edilmez)
/// yenisiyle değiştir. Session resume ve hasOpenAICompatibleCredentials hâlâ
/// bu alanı okur.
pub fn stashCachedBaseUrl(self: *App, base_url: []const u8) !void {
    const owned = try self.gpa.dupe(u8, base_url);
    if (self.cached_config.base_url) |prev| self.gpa.free(prev);
    self.cached_config.base_url = owned;
}

/// `cached_config.dynamic_provider_id` legacy alanını (runtime-only) yenisiyle
/// değiştir. compatibleApiKey ve status bar bu alanı okur.
pub fn stashCachedDynamicId(self: *App, id: []const u8) !void {
    const owned = try self.gpa.dupe(u8, id);
    if (self.cached_config.dynamic_provider_id) |prev| self.gpa.free(prev);
    self.cached_config.dynamic_provider_id = owned;
}

pub fn modelSelectionUpdates(
    self: *App,
    provider: config_mod.Provider,
    conn: ?model_loader.Compatible,
    model_id: []const u8,
    effort: ai.ReasoningEffort,
) !config_mod.Config {
    const model_id_copy = try self.gpa.dupe(u8, model_id);
    errdefer self.gpa.free(model_id_copy);
    var provider_model_id_moved = false;
    const provider_model_id = try self.gpa.dupe(u8, model_id);
    errdefer if (!provider_model_id_moved) self.gpa.free(provider_model_id);
    var models_moved = false;
    var models = try self.gpa.alloc(config_mod.ProviderModel, 1);
    errdefer if (!models_moved) self.gpa.free(models);
    models[0] = .{ .id = provider_model_id, .reasoning = .{ .effort = effort } };
    provider_model_id_moved = true;
    var providers = try self.gpa.alloc(config_mod.ProviderConfig, 1);
    errdefer {
        for (providers) |*entry| entry.deinit(self.gpa);
        self.gpa.free(providers);
    }
    // For dynamic/custom providers the config-map key and auth.json key is
    // the provider id (e.g. "stepfun-ai"), carried by the selected entry's
    // conn.auth_key_id. Codex (.openai) için provider.label() kullanılır.
    const resolved = resolveConn(provider, conn);

    providers[0] = .{ .name = try self.gpa.dupe(u8, resolved.auth_key_id), .provider = provider, .models = models };
    models_moved = true;
    if (provider != .openai) {
        if (resolved.base_url.len > 0) providers[0].base_url = .{ .custom = try self.gpa.dupe(u8, resolved.base_url) };
    }

    const base_url_slice: ?[]u8 = switch (providers[0].base_url) {
        .custom => |base_url| try self.gpa.dupe(u8, base_url),
        .default => null,
    };
    errdefer if (base_url_slice) |s| self.gpa.free(s);

    const ms_model_id = try self.gpa.dupe(u8, model_id);
    errdefer self.gpa.free(ms_model_id);

    const model_selection = if (provider == .openai_compatible) blk: {
        const ms_base_url = if (base_url_slice) |s| try self.gpa.dupe(u8, s) else try self.gpa.dupe(u8, resolved.base_url);
        const ms_api_key = try self.gpa.dupe(u8, "");
        break :blk config_mod.ModelSelection{
            .custom = .{
                .provider_name = try self.gpa.dupe(u8, resolved.auth_key_id),
                .base_url = ms_base_url,
                .api_key = ms_api_key,
                .model = .{ .id = ms_model_id, .reasoning = .{ .effort = effort } },
            },
        };
    } else blk: {
        break :blk config_mod.ModelSelection{
            .builtin = .{
                .provider = provider,
                .provider_name = try self.gpa.dupe(u8, resolved.auth_key_id),
                .model = .{ .id = ms_model_id, .reasoning = .{ .effort = effort } },
            },
        };
    };

    return .{
        .provider = provider,
        .base_url = base_url_slice,
        .model = .{ .id = model_id_copy, .reasoning = .{ .effort = effort } },
        .providers = providers,
        .model_selection = model_selection,
    };
}

pub fn reloadModelCatalog(self: *App, catalog: ModelCatalog) !void {
    codexModelsClear(
        self,
    );
    switch (catalog) {
        .connected_provider => {
            if (shouldLoadConfiguredCompatibleCatalog(
                self,
            )) {
                loadCompatibleCatalog(
                    self,
                ) catch |err| {
                    if (!self.isCodexSignedIn()) return err;
                    std.log.warn("compatible.models.failed err={s}", .{@errorName(err)});
                };
            }
            try loadLocalCompatibleCatalogs(
                self,
            );
            if (self.isCodexSignedIn()) try loadCodexStaticCatalog(
                self,
            );
        },
        .openai_codex => try loadCodexStaticCatalog(
            self,
        ),
    }
    try finishModelCatalogReload(
        self,
    );
}

pub fn finishModelCatalogReload(self: *App) !void {
    self.pickers.models.resetReasoning();
}

pub fn activeModelId(self: *const App) ?[]const u8 {
    const status = tui_status.modelStatus(self.liveRuntime(), self.cached_config) orelse return null;
    return status.model;
}

pub fn loadCodexStaticCatalog(self: *App) !void {
    const models = try codex.loadStaticModels(self.gpa);
    defer self.gpa.free(models);
    for (models) |*model| {
        try self.pickers.models.append(self.gpa, model.*, .openai_codex);
        model.* = .{ .id = &.{}, .label = &.{} };
    }
    for (models) |*model| {
        if (model.id.len == 0) continue;
        model.deinit(self.gpa);
    }
}

pub fn loadCompatibleCatalog(self: *App) !void {
    if (!self.pickers.models.compatible_models_fetched) try fetchCompatibleCatalog(
        self,
    );
    const base_url = self.cached_config.base_url.?;
    const provider = tui_provider.compatibleProviderFromBaseUrl(base_url);
    // Bu yol yalnızca cached_config.base_url'den gelen tek bir (env/config)
    // provider için geçerlidir; auth_key_id olarak provider label'ını kullan
    // (catalogue dışı config provider'ları auth.json'a isimle kaydolur).
    for (self.pickers.models.compatible_models.items) |model| {
        const id = try self.gpa.dupe(u8, model.id);
        errdefer self.gpa.free(id);
        const label = try self.gpa.dupe(u8, model.label);
        errdefer self.gpa.free(label);
        try self.pickers.models.append(self.gpa, .{ .id = id, .label = label }, .{
            .openai_compatible = try model_loader.compatibleSource(self.gpa, provider, base_url, provider.label()),
        });
    }
}

pub fn loadLocalCompatibleCatalogs(self: *App) !void {
    loadLocalCompatibleCatalog(self, .ollama) catch {};
    loadLocalCompatibleCatalog(self, .llama_cpp) catch {};
}

pub fn loadLocalCompatibleCatalog(self: *App, provider: config_mod.Provider) !void {
    const base_url = provider.defaultBaseUrl() orelse return;
    const api_key = providerLocalApiKey(provider);
    const fetched = try openai_compatible_mod.listModels(self.gpa, self.io, base_url, api_key);
    defer {
        for (fetched) |*entry| entry.deinit(self.gpa);
        self.gpa.free(fetched);
    }
    for (fetched) |entry| {
        if (!includeLocalModel(provider, entry.id)) continue;
        const id = try self.gpa.dupe(u8, entry.id);
        errdefer self.gpa.free(id);
        const label = try localModelLabel(self.gpa, provider, entry.id);
        errdefer self.gpa.free(label);
        try self.pickers.models.append(self.gpa, .{ .id = id, .label = label }, .{
            .openai_compatible = try model_loader.compatibleSource(self.gpa, provider, base_url, providerLocalApiKey(provider)),
        });
    }
}

pub fn fetchCompatibleCatalog(self: *App) !void {
    std.debug.assert(!self.pickers.models.compatible_models_fetched);
    const base_url = self.cached_config.base_url.?;
    const api_key = self.cached_config.api_key.?;
    const provider = self.cached_config.provider orelse tui_provider.compatibleProviderFromBaseUrl(base_url);
    const fetched = try openai_compatible_mod.listModels(self.gpa, self.io, base_url, api_key);
    defer {
        for (fetched) |*entry| entry.deinit(self.gpa);
        self.gpa.free(fetched);
    }
    errdefer compatibleModelsCacheClear(
        self,
    );
    for (fetched) |entry| {
        if (!includeLocalModel(provider, entry.id)) continue;
        const id = try self.gpa.dupe(u8, entry.id);
        errdefer self.gpa.free(id);
        const label = try self.gpa.dupe(u8, entry.id);
        errdefer self.gpa.free(label);
        try self.pickers.models.compatible_models.append(self.gpa, .{ .id = id, .label = label });
    }
    self.pickers.models.compatible_models_fetched = true;
}

pub fn compatibleModelsCacheClear(self: *App) void {
    for (self.pickers.models.compatible_models.items) |*model| model.deinit(self.gpa);
    self.pickers.models.compatible_models.clearRetainingCapacity();
    self.pickers.models.compatible_models_fetched = false;
}

pub fn hasOpenAICompatibleCredentials(self: *const App) bool {
    return tui_provider.hasOpenAICompatibleCredentials(self.cached_config);
}

pub fn shouldLoadConfiguredCompatibleCatalog(self: *const App) bool {
    if (!hasOpenAICompatibleCredentials(
        self,
    )) return false;
    // base_url may be null after restart when the legacy stash wasn't hydrated
    // (it is normally repopulated by hydrateActiveModel from the providers[]
    // map, but the typed model_selection.baseUrl() is the durable signal).
    const base_url = self.cached_config.base_url orelse blk: {
        if (self.cached_config.model_selection) |ms| {
            if (ms.baseUrl()) |url| break :blk url;
        }
        return false;
    };
    const provider = self.cached_config.provider orelse tui_provider.compatibleProviderFromBaseUrl(base_url);
    if (provider == .ollama) return false;
    if (provider == .llama_cpp) return false;
    return true;
}

pub fn compatibleBaseUrl(self: *const App, provider: config_mod.Provider) ?[]const u8 {
    if (self.cached_config.base_url) |base_url| {
        const url_provider = tui_provider.compatibleProviderFromBaseUrl(base_url);
        if (url_provider == provider) return base_url;
    }
    return provider.defaultBaseUrl();
}

/// Resolve the API key for an OpenAI-compatible provider: a key stored in
/// auth.json wins, then the env/config key, then the provider's anonymous
/// sentinel (e.g. OpenCode Zen's `public`), then the local-daemon sentinel.
/// For dynamic/custom providers (.openai_compatible), the auth.json key is
/// the stashed provider id (e.g. "stepfun-ai"), not the enum label.
pub fn compatibleApiKey(self: *const App, provider: config_mod.Provider) []const u8 {
    // Dynamic/custom providers: auth.json key is the stashed provider id.
    if (provider == .openai_compatible) {
        if (self.cached_config.dynamic_provider_id) |id| {
            if (self.provider_state.api_keys.get(id)) |key| return key;
        }
        // After session resume dynamic_provider_id is null (runtime-only).
        // Fall back to model_selection.provider_name which IS serialized.
        if (self.cached_config.model_selection) |ms| {
            if (self.provider_state.api_keys.get(ms.providerName())) |key| return key;
        }
    } else {
        if (self.provider_state.api_keys.get(provider.label())) |key| return key;
    }
    if (self.cached_config.api_key) |key| return key;
    if (provider.anonymousApiKey()) |anon| return anon;
    return providerLocalApiKey(provider);
}

/// `compatibleApiKey`'ın conn-bazlı versiyonu: seçilen entry'nin kendi
/// `auth_key_id`'sini birincil çözüm olarak kullanır (cached_config'in global
/// stash'ine bağımlı olmadan). Bu, çoklu provider kataloğunda yanlış
/// provider'ın anahtarını çözümlemeyi önler.
pub fn compatibleApiKeyForConn(self: *const App, conn: model_loader.Compatible) []const u8 {
    if (self.provider_state.api_keys.get(conn.auth_key_id)) |key| return key;
    if (self.cached_config.api_key) |key| return key;
    if (conn.provider.anonymousApiKey()) |anon| return anon;
    return providerLocalApiKey(conn.provider);
}

pub fn providerLocalApiKey(provider: config_mod.Provider) []const u8 {
    return switch (provider) {
        .ollama => "ollama",
        .llama_cpp => "llama.cpp",
        else => "",
    };
}

pub fn providerModelLabel(provider: config_mod.Provider) []const u8 {
    return switch (provider) {
        .ollama => "Ollama",
        .llama_cpp => "llama.cpp",
        else => provider.label(),
    };
}

pub fn localModelLabel(gpa: std.mem.Allocator, provider: config_mod.Provider, model_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s} · {s}", .{ providerModelLabel(provider), model_id });
}

pub fn includeLocalModel(provider: config_mod.Provider, model_id: []const u8) bool {
    if (provider == .ollama) {
        if (std.mem.endsWith(u8, model_id, "-cloud")) return false;
    }
    return true;
}

pub fn selectedReasoningIndex(self: *const App) u32 {
    if (self.pickers.models.model_selection >= self.pickers.models.len()) return 0;
    return self.pickers.models.entries.items[self.pickers.models.model_selection].reasoning_index;
}

pub fn selectedReasoningEffort(self: *const App) ai.ReasoningEffort {
    const opts = tui.activeReasoningOptions(self);
    const idx = selectedReasoningIndex(self);
    if (idx >= opts.len) return .medium;
    return opts[idx].effort;
}

pub fn cycleModelScope(self: *App) void {
    self.pickers.models.model_scope = switch (self.pickers.models.model_scope) {
        .global => .project,
        .project => .session,
        .session => .global,
    };
}

pub fn cycleSelectedReasoning(self: *App) !void {
    if (self.pickers.models.model_selection >= self.pickers.models.len()) return;
    const entry = &self.pickers.models.entries.items[self.pickers.models.model_selection];
    const opts = tui.activeReasoningOptions(self);
    entry.reasoning_index = tui.nextIndex(entry.reasoning_index, @intCast(opts.len));
}

pub fn selectedCodexModel(self: *App) ?codex.Model {
    if (self.pickers.models.model_selection >= self.pickers.models.len()) return null;
    const active_storage_idx = self.pickers.models.activeStorageIdx(activeModelId(
        self,
    ));
    const idx = model_picker.displayToStorage(active_storage_idx, self.pickers.models.model_selection);
    return self.pickers.models.entries.items[idx].model;
}

pub fn modelDisplayMatches(self: *const App, display_pos: u32, filter: []const u8) bool {
    const count: u32 = self.pickers.models.len();
    if (display_pos >= count) return false;
    const active = self.pickers.models.activeStorageIdx(activeModelId(
        self,
    ));
    const storage = model_picker.displayToStorage(active, display_pos);
    if (storage >= count) return false;
    return model_picker.matches(self.pickers.models.entries.items[storage].model, filter);
}

pub fn firstMatchingModelDisplay(self: *const App, filter: []const u8) ?u32 {
    const count: u32 = self.pickers.models.len();
    var d: u32 = 0;
    while (d < count) : (d += 1) {
        if (modelDisplayMatches(self, d, filter)) return d;
    }
    return null;
}

pub fn stepModelSelection(self: *App, forward: bool) !void {
    const count: u32 = self.pickers.models.len();
    if (count == 0) return;
    const filter = try self.peekPaletteInput();
    defer self.gpa.free(filter);
    var next = self.pickers.models.model_selection;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        next = if (forward) tui.nextIndex(next, count) else tui.previousIndex(next, count);
        if (modelDisplayMatches(self, next, filter)) {
            self.pickers.models.model_selection = next;
            return;
        }
    }
}

pub fn selectedModelSource(self: *const App) ?ModelSource {
    if (self.pickers.models.model_selection >= self.pickers.models.len()) return null;
    const active_storage_idx = self.pickers.models.activeStorageIdx(activeModelId(
        self,
    ));
    const idx = model_picker.displayToStorage(active_storage_idx, self.pickers.models.model_selection);
    if (idx >= self.pickers.models.len()) return null;
    return self.pickers.models.entries.items[idx].source;
}

pub fn codexModelsClear(self: *App) void {
    self.pickers.models.clearEntries(self.gpa);
}

pub fn connectCodexClient(
    self: *App,
    credentials: codex.Credentials,
    model: []const u8,
    effort: ai.ReasoningEffort,
) !void {
    // The naming client is about to be replaced; no job may still borrow it.
    self.cancelLaneNaming(self.thread);
    const runtime = self.liveRuntime().?;
    // Actually connect MCP servers before collecting tool schemas.
    self.mcp_manager.syncFromConfigEx(self.io, &self.cached_config);
    const mcp_schemas = try self.mcp_manager.buildMcpToolSchemas(self.gpa);
    defer self.gpa.free(mcp_schemas);
    runtime.mcp_tools = mcp_schemas;
    runtime.strict_outputs = self.cached_config.strict_outputs orelse false;
    try runtime.connectCodexClient(credentials, model, effort);
    self.thread.agent.?.client = runtime.client;
    injectPluginTools(self);
    // The plugin tools just landed in the registry; the AI client's
    // `tools_json` was serialized at attach time (with only the
    // builtin slice) and does NOT know about them yet. Push the merged
    // list to the client so the next prompt includes plugin tools.
    injectAllTools(self);
}

pub fn attachOpenAiCompatibleClient(
    self: *App,
    base_url: []const u8,
    api_key: []const u8,
    model_id: []const u8,
    effort: ai.ReasoningEffort,
) !void {
    // The naming client is about to be replaced; no job may still borrow it.
    self.cancelLaneNaming(self.thread);
    const runtime = self.liveRuntime().?;
    // Actually connect MCP servers before collecting tool schemas.
    self.mcp_manager.syncFromConfigEx(self.io, &self.cached_config);
    const mcp_schemas = try self.mcp_manager.buildMcpToolSchemas(self.gpa);
    defer self.gpa.free(mcp_schemas);
    runtime.mcp_tools = mcp_schemas;
    runtime.strict_outputs = self.cached_config.strict_outputs orelse false;
    try runtime.attachOpenAiCompatibleClient(base_url, api_key, model_id, effort);
    self.thread.agent.?.client = runtime.client;
    injectPluginTools(self);
    // See connectCodexClient — without this, plugin tools sit in the
    // registry but never reach the AI client until the next MCP-tick.
    injectAllTools(self);
}

/// Rebuild the MCP tool schemas from the currently connected servers and inject
/// them into the live AI client. Does not connect or disconnect anything — call
/// after the MCP client set changes (toggle, reconnect, disconnect) so the
/// model's tool list stays in sync. Best-effort: a failure leaves the previous
/// tool set in place.
pub fn injectMcpTools(self: *App) void {
    injectAllTools(self);
}

/// Build Lua plugin tool schemas and inject them into the live AI client.
/// Plugin tools use the naming convention `lua__<plugin>__<tool>` to avoid
/// collisions with builtin and MCP tools. Best-effort: a failure leaves the
/// previous tool set in place.
pub fn injectPluginTools(self: *App) void {
    injectAllTools(self);
}

/// Merge MCP and plugin tool schemas into a single slice and inject them into
/// the live AI client in one call. `updateMcpTools` replaces the entire
/// `tools_json`, so calling it separately for MCP and plugin tools would cause
/// the second call to overwrite the first.
///
/// As of the plugin-via-`ToolRegistry` refactor, plugin tools live in
/// `self.tool_registry` and are surfaced through `registerPluginTools` →
/// `updateMcpTools` via the registry's `all` slice. This function only
/// handles the MCP transport — the rest of the tool list comes from
/// `self.tool_registry.all(...)` on the next `updateMcpTools` call.
fn injectAllTools(self: *App) void {
    const runtime = self.liveRuntime() orelse {
        std.log.warn("injectAllTools: no live runtime, skipping tool injection", .{});
        return;
    };
    const mcp_schemas = self.mcp_manager.buildMcpToolSchemas(self.gpa) catch |err| {
        std.log.warn("injectAllTools: buildMcpToolSchemas failed: {s}", .{@errorName(err)});
        return;
    };
    defer self.gpa.free(mcp_schemas);
    std.log.debug("injectAllTools: mcp={} (plugin tools come from ToolRegistry)", .{mcp_schemas.len});
    // Pass an empty builtin_override so we don't double-emit bash: the
    // registry's builtin already contains it, and most OpenAI-compatible
    // APIs reject duplicate tool names with HTTP 400, dropping the
    // entire tool list (including the plugin tools we want exposed).
    runtime.client.updateMcpTools(mcp_schemas, self.tool_registry, &.{}) catch |err| {
        std.log.warn("injectAllTools: updateMcpTools failed: {s}", .{@errorName(err)});
    };
}

/// Walk every loaded Lua plugin, materialize a `Tool` for each registered
/// handler, and append them to `self.tool_registry`. Called from
/// `initRuntime` after `plugin_manager.loadAll` and again whenever a
/// plugin is (re)loaded at runtime. The AI client picks them up on its
/// next `updateMcpTools` call (driven by `attachXxxClient` or
/// `refreshMcpTools`).
pub fn registerPluginTools(self: *App) void {
    const lua_mod = @import("../lua/root.zig");
    const descriptors = lua_mod.registry_bridge.buildPluginToolDescriptors(self.gpa, &self.plugin_manager) catch |err| {
        std.log.warn("registerPluginTools: buildPluginToolDescriptors failed: {s}", .{@errorName(err)});
        return;
    };
    defer {
        // The descriptor struct is fully consumed by `addPluginTool`:
        // - `name` and `description` are `gpa.dupe` slices that the
        //   registry's `plugin` ArrayList now owns (its `deinit` frees
        //   them).
        // - `userdata` is a `*PluginToolKey` that the registry now owns
        //   (its `deinit` calls `userdata_free`).
        // Freeing any of these here would dangle the registry's tool
        // records and crash the next `injectAllTools` or
        // `tool_registry.deinit`. We only free the outer slice — the
        // backing array of `[]Tool` — which is the one allocation
        // whose ownership stays with the caller.
        self.gpa.free(descriptors);
    }
    for (descriptors) |t| {
        self.tool_registry.addPluginTool(self.gpa, t) catch |err| {
            std.log.warn("registerPluginTools: addPluginTool failed: {s}", .{@errorName(err)});
            if (t.userdata_free) |free_fn| free_fn(self.gpa, t.userdata);
            self.gpa.free(t.name);
            self.gpa.free(t.description);
        };
    }
    // The dispatcher no longer reads `*PluginManager` from `PluginToolKey`;
    // it reads it from a thread-local slot that the executor writes
    // before each call. There is therefore nothing to rebind here — the
    // slot is always repopulated on the next dispatch.
    std.log.debug("registerPluginTools: registered {} plugin tools", .{descriptors.len});
}

/// Connect MCP servers per config, then inject their tool schemas into the live
/// AI client so the model sees `mcp__<server>__<tool>` definitions. The client
/// serializes its tool list at attach time, so MCP servers that connect
/// afterwards must push their schemas in explicitly.
pub fn refreshMcpTools(self: *App) void {
    if (self.liveRuntime() == null) return;
    self.mcp_manager.syncFromConfigEx(self.io, &self.cached_config);
    injectMcpTools(self);
    injectPluginTools(self);
}

/// Poll each connected MCP client for a pending `tools/list_changed` flag set
/// by a server-initiated notification mid-request. When any client has it,
/// re-run `tools/list` for that client and re-inject schemas into the live AI
/// client. Called from the TUI tick (`lifecycle.handleTick`). Idempotent —
/// returns false (no-op) when no client has a pending flag.
pub fn drainMcpNotifications(self: *App) bool {
    var any_pending = false;
    for (self.mcp_manager.clients.items) |*c| {
        if (c.status() != .connected) continue;
        if (c.pollToolsRefresh()) {
            any_pending = true;
            c.listTools(self.io) catch {
                c.setError("list_changed re-discovery failed", .{});
            };
        }
    }
    if (any_pending) injectAllTools(self);
    return any_pending;
}

/// Add a remote (Streamable HTTP) MCP server from a URL typed in the overlay's
/// add-form. The server is appended to the live `cached_config` and connected
/// immediately via `refreshMcpTools`. Runtime-only: it is NOT written to
/// config.json (persistence is a follow-up). Best-effort — a failure leaves the
/// config unchanged.
pub fn addMcpServerByUrl(self: *App, raw_url: []const u8) !void {
    _ = self.liveRuntime() orelse return;
    const name = try deriveMcpServerName(self.gpa, raw_url);
    defer self.gpa.free(name);
    const server = try config_mod.mcpServerFromUrl(self.gpa, name, raw_url);
    const new_len = self.cached_config.mcp_servers.len + 1;
    const new_servers = self.gpa.realloc(self.cached_config.mcp_servers, new_len) catch |err| {
        var owned = server;
        owned.deinit(self.gpa);
        return err;
    };
    new_servers[new_len - 1] = server;
    self.cached_config.mcp_servers = new_servers;
    refreshMcpTools(self);
}

/// Derive a server name from a URL's host (the part between "://" and the next
/// "/"). Manual host extraction avoids full URI parsing, which rejects
/// `{env:VAR}` placeholders in the query string. Falls back to "remote".
fn deriveMcpServerName(gpa: std.mem.Allocator, url: []const u8) ![]u8 {
    const after_scheme = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else url;
    const host_end = std.mem.indexOfScalar(u8, after_scheme, '/') orelse after_scheme.len;
    const host = after_scheme[0..host_end];
    if (host.len == 0) return try gpa.dupe(u8, "remote");
    return try gpa.dupe(u8, host);
}

test "deriveMcpServerName extracts the URL host" {
    const gpa = std.testing.allocator;
    // {env:VAR} in the query must not break host extraction (no full URI parse).
    {
        const name = try deriveMcpServerName(gpa, "https://mcp.tavily.com/mcp/?tavilyApiKey={env:TAVILY_API_KEY}");
        defer gpa.free(name);
        try std.testing.expectEqualStrings("mcp.tavily.com", name);
    }
    // Host with an explicit port.
    {
        const name = try deriveMcpServerName(gpa, "http://localhost:8080/sse");
        defer gpa.free(name);
        try std.testing.expectEqualStrings("localhost:8080", name);
    }
    // No path — the whole authority is the host.
    {
        const name = try deriveMcpServerName(gpa, "https://example.org");
        defer gpa.free(name);
        try std.testing.expectEqualStrings("example.org", name);
    }
}
