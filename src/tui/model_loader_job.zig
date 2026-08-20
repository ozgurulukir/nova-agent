//! Async model loading jobs, outcome installation, and disk cache persistence.

const std = @import("std");
const log = std.log.scoped(.tui);
const config_mod = @import("../config/config.zig");
const model_cache = @import("model_cache.zig");
const model_loader = @import("model_loader.zig");
const provider_model = @import("provider_model.zig");
const tui = @import("../tui.zig");

const App = tui.App;

pub fn cancelModelLoad(self: *App) void {
    if (self.pickers.models.load == .loading) {
        var future = self.pickers.models.load.loading.future;
        var outcome = future.cancel(self.io);
        outcome.deinit(self.gpa);
        self.pickers.models.load = .idle;
    }
}

/// Install the concurrent future for a freshly-armed `.loading` state,
/// guaranteeing the union never stays `.loading` with an `undefined` future
/// when the spawn fails: the state first moves to `.failed` (picker error
/// row) or `.idle` (message alloc failed), then the error re-raises so the
/// caller's errdefers free the job + configured snapshot. Without this,
/// `cancelModelLoad` would copy the undefined future (UB) and
/// `drainModelLoad` would poll `done` forever, spinning the tick.
pub fn spawnLoadFuture(app: *App, job: *model_loader.Job) !void {
    app.pickers.models.load.loading.future = app.io.concurrent(model_loader.run, .{job}) catch |err| {
        markLoadSpawnFailed(app, err);
        return err;
    };
}

/// Move an armed-but-unspawned `.loading` state out of `.loading` so the
/// cancel/drain paths never touch the never-installed future. The `.failed`
/// message is owned by the catalogue and freed by its existing sites.
pub fn markLoadSpawnFailed(app: *App, err: anyerror) void {
    var buffer: [96]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "Model load could not start: {s}", .{@errorName(err)}) catch
        "Model load could not start.";
    if (app.gpa.dupe(u8, message)) |owned| {
        app.pickers.models.load = .{ .failed = .{ .message = owned } };
    } else |_| {
        app.pickers.models.load = .idle;
    }
}

/// Called from the tick handler. Polls the non-blocking `done` flag, and
/// only `await`s once the worker has signalled completion. Returns true
/// if a redraw is needed.
pub fn drainModelLoad(self: *App) !bool {
    if (self.pickers.models.load != .loading) return false;
    if (!self.pickers.models.load.loading.done.load(.acquire)) return false;

    var outcome = self.pickers.models.load.loading.future.await(self.io);
    self.pickers.models.load = .idle;
    defer outcome.deinit(self.gpa);

    switch (outcome) {
        .ready => |*result| try installModelLoadResult(self, result),
        .failed => |message| {
            self.pickers.models.load = .{ .failed = .{ .message = try self.gpa.dupe(u8, message) } };
        },
    }
    return true;
}

pub fn installModelLoadResult(self: *App, result: *model_loader.Result) !void {
    if (self.pickers.models.load == .loading and self.pickers.models.load.loading.merge) {
        // Incremental load: replace only the freshly-fetched providers'
        // models, leaving previously-cached providers untouched. Conn-bazlı
        // dedup: çoklu `.openai_compatible` provider'lar aynı enum değerini
        // paylaştığından `EnumSet` onları birleştirirdi — `auth_key_id` her
        // bağlantıyı benzersiz tanımlar.
        var refreshed = std.StringHashMap(void).init(self.gpa);
        defer refreshed.deinit();
        for (result.sources.items) |source| switch (source) {
            .openai_compatible => |conn| {
                if (refreshed.contains(conn.auth_key_id)) continue;
                try refreshed.put(conn.auth_key_id, {});
                dropModelsForConn(self, conn);
            },
            .openai_codex => {},
        };
    } else {
        provider_model.codexModelsClear(self);
    }
    // Move models in (the struct copies own their id/label); clearing the
    // result without freeing avoids a double-free. `models` and `sources`
    // are built in lockstep, so they zip into one entry each.
    std.debug.assert(result.models.items.len == result.sources.items.len);
    for (result.models.items, result.sources.items) |*model, source| {
        try self.pickers.models.append(self.gpa, model.*, source);
    }
    result.models.clearRetainingCapacity();
    result.sources.clearRetainingCapacity();
    // load was set to .idle by drainModelLoad before calling us; nothing
    // else to reset.
    // Same fetch that built the catalogue also tells us which providers are
    // reachable — drive the picker badges from it.
    provider_model.applyProviderOutcomes(self, result.outcomes.items);
    try provider_model.finishModelCatalogReload(self);
    try provider_model.snapshotModelPickerState(self);
    self.pickers.models.models_cached = true;
    saveModelCache(self) catch |err| log.warn("models.cache.save.failed err={s}", .{@errorName(err)});
}

/// Remove every cached model that came from `provider`. Builtin katalog
/// provider'ları için uygundur (her biri ayrı bir enum değeridir).
pub fn dropModelsForProvider(self: *App, provider: config_mod.Provider) void {
    self.pickers.models.dropProvider(self.gpa, provider);
}

/// Remove every cached model sourced from `conn`. Çoklu `.openai_compatible`
/// provider'lar aynı enum değerini paylaştığından, bunlar için enum-bazlı
/// `dropModelsForProvider` tüm provider'ları birleştirir — conn-bazlı bu
/// versiyon yalnızca verilen bağlantıya ait entry'leri düşürür.
pub fn dropModelsForConn(self: *App, conn: model_loader.Compatible) void {
    self.pickers.models.dropConn(self.gpa, conn);
}

pub fn restoreModelCache(self: *App) !bool {
    const runtime = self.liveRuntime() orelse return false;
    if (runtime.home_dir.len == 0) return false;

    var configured = try collectModelCacheConfigured(self);
    defer configured.deinit(self.gpa);

    var cached = model_cache.load(self.gpa, self.io, runtime.home_dir, configured.items) catch return false;
    defer cached.deinit(self.gpa);

    provider_model.codexModelsClear(self);
    for (cached.items.items) |*record| {
        try self.pickers.models.append(self.gpa, record.model, record.source);
        // Model ve source artık entry'ye taşındı (struct field'ları alias
        // ediyor); sahipliği devret ve cached.deinit'in onları tekrar free
        // etmesini önle.
        record.model = .{ .id = &.{}, .label = &.{} };
        record.source = .openai_codex;
    }
    if (self.isCodexSignedIn()) try provider_model.loadCodexStaticCatalog(self);
    if (self.pickers.models.len() == 0) return false;

    try provider_model.finishModelCatalogReload(self);
    try provider_model.snapshotModelPickerState(self);
    self.pickers.models.models_cached = true;
    return true;
}

pub fn saveModelCache(self: *App) !void {
    const runtime = self.liveRuntime() orelse return;
    if (runtime.home_dir.len == 0) return;

    var configured = try collectModelCacheConfigured(self);
    defer configured.deinit(self.gpa);
    if (configured.items.len == 0) return;

    const records = try self.gpa.alloc(model_cache.Record, self.pickers.models.entries.items.len);
    defer self.gpa.free(records);
    for (self.pickers.models.entries.items, 0..) |entry, index| {
        records[index] = .{ .model = entry.model, .source = entry.source };
    }
    try model_cache.save(self.gpa, self.io, runtime.home_dir, records, configured.items);
}

pub fn collectModelCacheConfigured(self: *App) !std.ArrayList(model_cache.Configured) {
    var list: std.ArrayList(model_cache.Configured) = .empty;
    errdefer list.deinit(self.gpa);

    // The disk cache is keyed by provider identity. For `.openai_compatible`
    // providers that means `auth_key_id`; builtin catalogue providers are
    // already unique-by-enum. Cross-block dedup prevents one provider from
    // shadowing another during save/load.
    var seen = std.StringHashMap(void).init(self.gpa);
    defer seen.deinit();

    // BLOCK 1: builtin catalogue providers that have a reachable endpoint +
    // auth mode. `auth_key_id` is the catalogue label.
    for (config_mod.catalogueProviders()) |provider| {
        const base_url = provider.defaultBaseUrl() orelse continue;
        const auth_mode: model_cache.AuthMode = if (self.provider_state.api_keys.get(provider.label())) |_|
            .keyed
        else if (provider.anonymousApiKey() != null)
            .anonymous
        else
            continue;
        const key = provider.label();
        if (seen.contains(key)) continue;
        try seen.put(key, {});
        try list.append(self.gpa, .{
            .provider = provider,
            .base_url = base_url,
            .auth_mode = auth_mode,
            .auth_key_id = key,
        });
    }

    // BLOCK 2: dynamic/config OpenAI-compatible providers from the runtime
    // configured set. This preserves models.dev registry + config providers[]
    // entries like the online load path; without it, restart would restore
    // only the active `model_selection` provider and drop the others.
    if (self.provider_state.modelsdev_registry) |*reg| {
        var it = self.provider_state.api_keys.iterator();
        while (it.next()) |entry| {
            const id = entry.key_ptr.*;
            // Skip ids already emitted as builtin catalogue providers.
            if (provider_model.catalogueIndexById(id) != null) continue;
            if (reg.lookup(id)) |dyn_p| {
                if (seen.contains(id)) continue;
                try seen.put(id, {});
                try list.append(self.gpa, .{
                    .provider = .openai_compatible,
                    .base_url = dyn_p.base_url,
                    .auth_mode = .keyed,
                    .auth_key_id = id,
                });
            }
        }
    }

    // BLOCK 3: config-defined custom OpenAI-compatible endpoints that are not
    // represented in models.dev and not in catalogue providers.
    for (self.cached_config.providers) |pc| {
        if (pc.provider != .openai_compatible) continue;
        if (pc.provider.isCatalogue()) continue;
        const base_url = switch (pc.base_url) {
            .custom => |url| url,
            .default => continue,
        };
        if (self.provider_state.api_keys.get(pc.name) == null) continue;
        if (seen.contains(pc.name)) continue;
        try seen.put(pc.name, {});
        try list.append(self.gpa, .{
            .provider = .openai_compatible,
            .base_url = base_url,
            .auth_mode = .keyed,
            .auth_key_id = pc.name,
        });
    }

    if (config_mod.Provider.ollama.defaultBaseUrl()) |base_url| {
        if (!seen.contains("ollama")) {
            try list.append(self.gpa, .{
                .provider = .ollama,
                .base_url = base_url,
                .auth_mode = .anonymous,
                .auth_key_id = "ollama",
            });
        }
    }

    return list;
}

test "markLoadSpawnFailed moves an armed loading state to failed and keeps cancelModelLoad safe" {
    const agent_mod = @import("../agent.zig");
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // Arm exactly like startModelLoad does right before the spawn: future is
    // undefined until io.concurrent succeeds.
    app.pickers.models.load = .{ .loading = .{
        .future = undefined,
        .done = .init(false),
        .merge = true,
    } };
    markLoadSpawnFailed(&app, error.SystemResources);

    try std.testing.expect(app.pickers.models.load == .failed);
    try std.testing.expect(std.mem.indexOf(u8, app.pickers.models.load.failed.message, "SystemResources") != null);

    // Cancel/drain on the failed state must be no-ops — they must never touch
    // the never-installed (undefined) future.
    cancelModelLoad(&app);
    try std.testing.expect(app.pickers.models.load == .failed);
    try std.testing.expect(!try drainModelLoad(&app));
}
