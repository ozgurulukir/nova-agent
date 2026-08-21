const std = @import("std");
const log = std.log.scoped(.tui);

const codex = @import("../auth/codex.zig");
const config_mod = @import("../config/config.zig");
const openai_compatible_mod = @import("../ai/openai_compatible.zig");
const symbols = @import("../symbols.zig");

/// Bir modelin provenance'ı + bağlantı bilgisi. Entry ile birlikte dolaşır;
/// `applySelectedModel` cached_config'in global tek değerine bakmadan bunu
/// kullanır. Önceki `openai_compatible: Provider` armı dynamic/config
/// provider'larını `.openai_compatible` enum'ına çöktürdüğü için çoklu
/// provider kataloğunda yanlış provider'a bağlanmaya yol açıyordu —
/// `base_url` + `auth_key_id` artık modelle birlikte taşındığından
/// uyuşmazlık temsil edilemez.
pub const ModelSource = union(enum) {
    openai_codex,
    openai_compatible: Compatible,

    pub fn deinit(self: ModelSource, gpa: std.mem.Allocator) void {
        switch (self) {
            .openai_codex => {},
            .openai_compatible => |conn| {
                gpa.free(conn.base_url);
                gpa.free(conn.auth_key_id);
            },
        }
    }
};

/// Bir OpenAI-uyumlu provider'a bağlanmak için gereken üç bilgi: provider enum
/// (display/default-URL fallback için), tam `base_url` (bağlantı için), ve
/// auth.json anahtar kimliği (API key çözümlemesi için). Bir modelden
/// ayrılamazlar — entry ile construction sırasında bağlanırlar.
pub const Compatible = struct {
    provider: config_mod.Provider,
    base_url: []const u8,
    auth_key_id: []const u8,
};

pub const Catalog = enum {
    connected_provider,
    openai_codex,
    single_provider,
};

/// Per-provider connectivity verdict, derived from the same fetch that builds
/// the catalogue: `ok` is true when the provider's `/models` returned at least
/// one usable model. Lets the picker's [CONNECTED] badge read off the model
/// load instead of a separate probe, so the two can never disagree.
pub const ProviderOutcome = struct {
    provider: config_mod.Provider,
    ok: bool,
};

pub const Result = struct {
    gpa: std.mem.Allocator = undefined,
    models: std.ArrayList(codex.Model) = .empty,
    sources: std.ArrayList(ModelSource) = .empty,
    outcomes: std.ArrayList(ProviderOutcome) = .empty,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        for (self.models.items) |*model| model.deinit(gpa);
        self.models.deinit(gpa);
        for (self.sources.items) |*source| source.deinit(gpa);
        self.sources.deinit(gpa);
        self.outcomes.deinit(gpa);
        self.* = undefined;
    }
};

/// Outcome of a load task. `failed.message` is gpa-owned. `Outcome.deinit`
/// frees whichever branch is set, so the consumer only needs to call deinit
/// regardless of which way the task went.
pub const Outcome = union(enum) {
    ready: Result,
    failed: []u8,

    pub fn deinit(self: *Outcome, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .ready => |*r| r.deinit(gpa),
            .failed => |msg| gpa.free(msg),
        }
        self.* = undefined;
    }
};

pub const Configured = struct {
    provider: config_mod.Provider,
    base_url: []u8, // gpa-owned
    api_key: []u8, // gpa-owned
    display_name: ?[]u8 = null, // gpa-owned
    /// auth.json anahtar kimliği. Katalog provider'ları için `provider.label()`,
    /// dynamic/config provider'ları için provider id'si (ör. "stepfun-ai").
    /// null → `provider.label()`'a düşer (katalog provider'ları için).
    auth_key_id: ?[]u8 = null, // gpa-owned
};

/// Snapshot of everything the worker needs. Owned by the job and freed when
/// the task exits, so the App layer can mutate `cached_config` etc. without
/// racing the worker.
pub const Job = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    catalog: Catalog,
    configured: []Configured,
    include_locals: bool,
    codex_signed_in: bool,
    /// Set to `true` immediately before the worker returns, so the main
    /// thread can non-blockingly poll for completion without awaiting.
    done: *std.atomic.Value(bool),

    fn deinit(self: *Job) void {
        for (self.configured) |c| {
            self.gpa.free(c.base_url);
            self.gpa.free(c.api_key);
            if (c.display_name) |d| self.gpa.free(d);
            if (c.auth_key_id) |id| self.gpa.free(id);
        }
        if (self.configured.len > 0) self.gpa.free(self.configured);
        self.* = undefined;
    }
};

/// Worker entry point for `io.concurrent`. Owns `job` — frees it (and the
/// strings it carries) on exit. Flips `job.done` to `true` immediately
/// before returning so the main loop knows it can `await` without blocking.
pub fn run(job: *Job) Outcome {
    const gpa = job.gpa;
    const done = job.done;
    defer {
        job.deinit();
        gpa.destroy(job);
        done.store(true, .release);
    }

    var result: Result = .{ .gpa = gpa };
    buildCatalog(job, &result) catch |err| {
        result.deinit(gpa);
        const message = std.fmt.allocPrint(gpa, "Could not load models: {s}", .{@errorName(err)}) catch return .{ .failed = &.{} };
        return .{ .failed = message };
    };
    return .{ .ready = result };
}

fn buildCatalog(job: *Job, result: *Result) !void {
    switch (job.catalog) {
        .connected_provider => {
            // One provider failing (expired key, unreachable host) must not abort
            // the others — but don't swallow the reason silently: log it, and
            // record a per-provider outcome so the picker's [CONNECTED] badge can
            // tell a provider that contributes no models (e.g. Ollama Cloud) from
            // one that d
            try loadConnectedParallel(job, result);
        },
        .single_provider => {
            for (job.configured) |configured| try loadAndRecord(job, configured, result);
        },
        .openai_codex => try loadStatic(job.gpa, result),
    }
}

/// Context handed to a single-provider worker spawned via `io.concurrent`.
const LoadCtx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    configured: Configured,
};

/// Worker entry point for one provider. Isolated so a slow/unreachable host
/// cannot block the others; the parent `run` joins all futures with
/// `await` and merges their partial results.
fn loadOneProvider(ctx: *LoadCtx) Result {
    const gpa = ctx.gpa;
    var partial: Result = .{ .gpa = gpa };
    loadAndRecordCtx(gpa, ctx.io, ctx.configured, &partial) catch |err| {
        log.warn("model load {s}: failed: {s}", .{ ctx.configured.provider.label(), @errorName(err) });
        partial.outcomes.append(gpa, .{ .provider = ctx.configured.provider, .ok = false }) catch {};
    };
    return partial;
}

/// Fetch every configured provider concurrently (one worker each) and merge
/// the partial results. Total latency is bounded by the slowest provider, not
/// the sum — a single unreachable host no longer stalls the whole catalogue.
/// Each worker's `listModels` carries its own 10s timeout internally, so a
/// hung endpoint is cancelled and recorded as failed while the others load.
/// Providers are processed in batches of 16 (concurrency cap) so any number of
/// configured providers loads without silent truncation.
fn loadConnectedParallel(job: *Job, result: *Result) !void {
    if (job.configured.len == 0) return;
    var futures: [16]?std.Io.Future(Result) = .{null} ** 16;
    var ctxs: [16]LoadCtx = undefined;
    var start: usize = 0;
    while (start < job.configured.len) : (start += futures.len) {
        const end = @min(start + futures.len, job.configured.len);
        for (job.configured[start..end], start..) |configured, i| {
            ctxs[i] = .{
                .gpa = job.gpa,
                .io = job.io,
                .configured = configured,
            };
            futures[i] = job.io.concurrent(loadOneProvider, .{&ctxs[i]}) catch |err| blk: {
                log.warn("model load {s}: spawn failed: {s}", .{ configured.provider.label(), @errorName(err) });
                break :blk @as(?std.Io.Future(Result), null);
            };
        }
        for (start..end) |i| {
            if (futures[i - start]) |*f| {
                var partial = f.await(job.io);
                mergeResult(result, &partial);
                partial.deinit(job.gpa);
            } else {
                // Spawn failed: record the outcome so the badge reflects it.
                try result.outcomes.append(job.gpa, .{ .provider = job.configured[i].provider, .ok = false });
            }
        }
    }
    // Locals (Ollama/llama.cpp) and Codex are shared across all providers and
    // must be loaded exactly once — not N times (once per worker above).
    loadSharedExtras(job.gpa, job.io, job.include_locals, job.codex_signed_in, result);
}

/// Move a partial result's models/sources/outcomes into the aggregate.
fn mergeResult(agg: *Result, partial: *Result) void {
    agg.models.appendSlice(agg.gpa, partial.models.items) catch {};
    agg.sources.appendSlice(agg.gpa, partial.sources.items) catch {};
    agg.outcomes.appendSlice(agg.gpa, partial.outcomes.items) catch {};
}

/// Load one provider and record its connectivity outcome. A fetch failure is
/// logged and recorded as `ok = false` (not propagated), so one dead provider
/// neither aborts the others nor vanishes without explanation. Only an
/// allocation failure recording the outcome propagates.
fn loadAndRecord(job: *Job, configured: Configured, result: *Result) !void {
    try loadAndRecordCtx(job.gpa, job.io, configured, result);
}

/// Context-parameterized variant used by both the sequential `single_provider`
/// path and the concurrent `loadOneProvider` worker (which has no `Job`).
fn loadAndRecordCtx(
    gpa: std.mem.Allocator,
    io: std.Io,
    configured: Configured,
    result: *Result,
) !void {
    const before = result.models.items.len;
    if (loadConfiguredCtx(gpa, io, configured, result)) |_| {
        const added = result.models.items.len - before;
        try result.outcomes.append(gpa, .{ .provider = configured.provider, .ok = added > 0 });
    } else |err| {
        log.warn("model load {s}: failed: {s}", .{ configured.provider.label(), @errorName(err) });
        try result.outcomes.append(gpa, .{ .provider = configured.provider, .ok = false });
    }
}

fn loadConfigured(job: *Job, configured: Configured, result: *Result) !void {
    try loadConfiguredCtx(job.gpa, job.io, configured, result);
}

fn loadConfiguredCtx(
    gpa: std.mem.Allocator,
    io: std.Io,
    configured: Configured,
    result: *Result,
) !void {
    // base_url may be "" when synthesized from session metadata or legacy
    // fields; resolve through the provider's default before hitting the wire.
    const base_url = if (configured.base_url.len > 0)
        configured.base_url
    else
        configured.provider.defaultBaseUrl() orelse return;
    const fetched = try openai_compatible_mod.listModelsWithTimeout(gpa, io, base_url, configured.api_key, 10_000);
    defer {
        for (fetched) |*entry| entry.deinit(gpa);
        gpa.free(fetched);
    }
    for (fetched) |entry| {
        if (!includeLocalModel(configured.provider, entry.id)) continue;
        if (!includeAnonymousModel(configured.provider, configured.api_key, entry.id)) continue;
        const id = try gpa.dupe(u8, entry.id);
        errdefer gpa.free(id);
        const prefix_name = if (configured.display_name) |d| d else providerModelLabel(configured.provider);
        const label = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ prefix_name, symbols.separator_dot_padded, entry.id });
        errdefer gpa.free(label);
        try result.models.append(gpa, .{ .id = id, .label = label });
        try result.sources.append(gpa, .{ .openai_compatible = try compatibleSource(
            gpa,
            configured.provider,
            base_url,
            configured.auth_key_id,
        ) });
    }
}

/// Load the shared local (Ollama / llama.cpp) and Codex providers exactly
/// once for the whole catalogue, not per-configured-provider. In the parallel
/// `connected_provider` path each provider runs in its own worker, so calling
/// these inside `loadConfiguredCtx` would fetch + duplicate them N times.
fn loadSharedExtras(gpa: std.mem.Allocator, io: std.Io, include_locals: bool, codex_signed_in: bool, result: *Result) void {
    if (include_locals) {
        loadLocalCtx(gpa, io, .ollama, result) catch {};
        loadLocalCtx(gpa, io, .llama_cpp, result) catch {};
    }
    if (codex_signed_in) loadStatic(gpa, result) catch {};
}

fn loadLocal(job: *Job, provider: config_mod.Provider, result: *Result) !void {
    try loadLocalCtx(job.gpa, job.io, provider, result);
}

fn loadLocalCtx(gpa: std.mem.Allocator, io: std.Io, provider: config_mod.Provider, result: *Result) !void {
    const base_url = provider.defaultBaseUrl() orelse return;
    const api_key = providerLocalApiKey(provider);
    const fetched = try openai_compatible_mod.listModelsWithTimeout(gpa, io, base_url, api_key, 10_000);
    defer {
        for (fetched) |*entry| entry.deinit(gpa);
        gpa.free(fetched);
    }
    for (fetched) |entry| {
        if (!includeLocalModel(provider, entry.id)) continue;
        const id = try gpa.dupe(u8, entry.id);
        errdefer gpa.free(id);
        const label = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ providerModelLabel(provider), symbols.separator_dot_padded, entry.id });
        errdefer gpa.free(label);
        try result.models.append(gpa, .{ .id = id, .label = label });
        try result.sources.append(gpa, .{ .openai_compatible = try compatibleSource(
            gpa,
            provider,
            base_url,
            providerLocalApiKey(provider),
        ) });
    }
}

/// Bir `Compatible` source'u gpa-owned `base_url` + `auth_key_id` ile kurar.
/// `auth_key_id` null ise `provider.label()`'a düşer (katalog provider'ları
/// auth.json'a label'larıyla kaydolur). Caller (Entry/Record) `source.deinit`
/// ile string'leri serbest bırakır.
pub fn compatibleSource(
    gpa: std.mem.Allocator,
    provider: config_mod.Provider,
    base_url: []const u8,
    auth_key_id: ?[]const u8,
) !Compatible {
    const owned_url = try gpa.dupe(u8, base_url);
    errdefer gpa.free(owned_url);
    const owned_key = try gpa.dupe(u8, auth_key_id orelse provider.label());
    return .{ .provider = provider, .base_url = owned_url, .auth_key_id = owned_key };
}

fn loadStatic(gpa: std.mem.Allocator, result: *Result) !void {
    const models = try codex.loadStaticModels(gpa);
    defer gpa.free(models);
    for (models) |model| {
        const id = try gpa.dupe(u8, model.id);
        errdefer gpa.free(id);
        const label = try gpa.dupe(u8, model.label);
        errdefer gpa.free(label);
        try result.models.append(gpa, .{ .id = id, .label = label });
        try result.sources.append(gpa, .openai_codex);
    }
}

pub fn includeAnonymousModel(provider: config_mod.Provider, api_key: []const u8, id: []const u8) bool {
    const anon = provider.anonymousApiKey() orelse return true;
    if (!std.mem.eql(u8, api_key, anon)) return true;
    return std.mem.endsWith(u8, id, "-free");
}

pub fn includeLocalModel(provider: config_mod.Provider, id: []const u8) bool {
    if (provider == .ollama) {
        if (std.mem.endsWith(u8, id, "-cloud")) return false;
        if (std.mem.endsWith(u8, id, ":cloud")) return false;
    }
    return true;
}

fn providerLocalApiKey(provider: config_mod.Provider) []const u8 {
    return switch (provider) {
        .ollama => "ollama",
        .llama_cpp => "llama.cpp",
        else => "",
    };
}

fn providerModelLabel(provider: config_mod.Provider) []const u8 {
    return provider.displayName();
}

test "includeAnonymousModel keeps only -free models when anonymous on opencode zen" {
    // Anonymous (the "public" sentinel): only `-free` models pass.
    try std.testing.expect(includeAnonymousModel(.opencode_zen, "public", "deepseek-v4-flash-free"));
    try std.testing.expect(!includeAnonymousModel(.opencode_zen, "public", "claude-opus-4-8"));
    try std.testing.expect(!includeAnonymousModel(.opencode_zen, "public", "deepseek-v4-flash"));
    // A real key (not the sentinel) shows everything.
    try std.testing.expect(includeAnonymousModel(.opencode_zen, "sk-real", "claude-opus-4-8"));
    // Providers without an anonymous tier are never filtered.
    try std.testing.expect(includeAnonymousModel(.cerebras, "public", "anything"));
}

test "includeLocalModel drops cloud-suffixed models for local ollama only" {
    try std.testing.expect(!includeLocalModel(.ollama, "gpt-oss:120b-cloud"));
    try std.testing.expect(!includeLocalModel(.ollama, "qwen3-coder:480b-cloud"));
    try std.testing.expect(!includeLocalModel(.ollama, "deepseek-v3.1:671b:cloud"));
    try std.testing.expect(includeLocalModel(.ollama, "llama3.1:8b"));
    // Ollama Cloud and other providers keep every model the endpoint returns.
    try std.testing.expect(includeLocalModel(.ollama_cloud, "gpt-oss:120b-cloud"));
    try std.testing.expect(includeLocalModel(.cerebras, "anything:cloud"));
}
