//! Runtime models.dev provider registry.
//!
//! Merges two sources into a single provider list:
//!   1. Builtin providers (OpenAI Codex OAuth, OpenRouter, Cerebras, etc.)
//!      defined as a comptime constant in this file.
//!   2. `https://models.dev/api.json` — fetched on demand, cached to
//!      `~/.config/nova/cache/models.dev/api.json` with a 24-hour TTL.
//!
//! Builtin providers always take precedence: when a models.dev provider
//! shares an id with a builtin, the builtin wins (its base_url, adapter,
//! and metadata are authoritative). The models.dev registry fills in
//! every other provider that exposes an `api` base URL — this is the
//! ground-truth signal that the endpoint can be driven by Nova's
//! `openai_compatible` adapter, regardless of npm package.
//!
//! Callers get a flat `[]Provider` slice. The first entry is always the
//! OpenAI Codex OAuth provider (id == "openai").

const std = @import("std");
const log = std.log.scoped(.models);

const cache_subdir = "models.dev";
const cache_filename = "api.json";
const api_url = "https://models.dev/api.json";

/// 24 hours in milliseconds.
const cache_ttl_ms: i64 = 24 * 60 * 60 * 1000;

/// HTTP fetch buffers. models.dev sits behind Cloudflare, which serves the
/// registry gzip-compressed — the body must be decompressed before parsing.
const redirect_buffer_bytes: u32 = 8192;
const transfer_buffer_bytes: u32 = 4096;
const response_bytes_max: u32 = 4 * 1024 * 1024;

pub const Adapter = enum {
    codex_responses,
    openai_compatible,
};

/// A single provider entry — either from builtins or models.dev.
/// All string fields are borrowed from the registry's backing store;
/// callers must not free them individually.
pub const Provider = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    base_url: []const u8,
    adapter: Adapter,
    requires_api_key: bool,
    /// OAuth flow (OpenAI Codex) instead of an API-key form.
    oauth: bool = false,
    /// Anonymous free-tier sentinel key (e.g. OpenCode Zen "public").
    anonymous_key: ?[]const u8 = null,
};

/// Per-model capability data extracted from the models.dev `api.json`.
/// All string fields are borrowed from the registry's backing store.
pub const ModelInfo = struct {
    id: []const u8,
    reasoning: bool,
    context_window: u32,
};

/// The merged, deduplicated provider list. Owns all string memory.
pub const Registry = struct {
    providers: []Provider,
    /// Flat list of all models across all providers, from `api.json`.
    /// Empty when only builtins are available (no remote fetch).
    models: []ModelInfo = &.{},
    /// Backing store for all string fields. Freed in deinit.
    strings: std.ArrayList(u8),

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        gpa.free(self.providers);
        if (self.models.len > 0) gpa.free(self.models);
        self.strings.deinit(gpa);
        self.* = undefined;
    }

    /// Find a provider by id. Returns null when not found.
    pub fn lookup(self: *const Registry, id: []const u8) ?Provider {
        for (self.providers) |p| {
            if (std.mem.eql(u8, p.id, id)) return p;
        }
        return null;
    }

    /// Look up per-model capability data by model id. Strips any provider
    /// prefix (`openai/gpt-4o` → `gpt-4o`), then tries exact match, then
    /// longest-prefix match across a segment boundary (so `gpt-5-2025-08-07`
    /// resolves to `gpt-5`). Returns null when no match is found.
    pub fn lookupModel(self: *const Registry, raw_model_id: []const u8) ?ModelInfo {
        var model_id = raw_model_id;
        while (std.mem.indexOfScalar(u8, model_id, '/')) |slash| {
            model_id = model_id[slash + 1 ..];
        }

        // Exact match first.
        for (self.models) |m| {
            if (std.mem.eql(u8, m.id, model_id)) return m;
        }

        // Longest-prefix match across a segment boundary.
        var best: ?ModelInfo = null;
        for (self.models) |m| {
            if (m.id.len > model_id.len) continue;
            if (!std.mem.startsWith(u8, model_id, m.id)) continue;
            if (!segmentBoundary(model_id, m.id.len)) continue;
            if (best == null or m.id.len > best.?.id.len) best = m;
        }
        return best;
    }
};

/// True when `prefix_len` is the whole model id, or the character right after
/// the prefix is a segment separator (`-`, `.`, `_`, `:`). Guards family-prefix
/// matching against longer ids of a different family (e.g. `gpt-4` must not
/// match `gpt-4o`).
fn segmentBoundary(model_id: []const u8, prefix_len: usize) bool {
    if (model_id.len == prefix_len) return true;
    return switch (model_id[prefix_len]) {
        '-', '.', '_', ':' => true,
        else => false,
    };
}

/// Builtin providers shipped with the binary. These always take precedence
/// over models.dev entries with the same id.
const builtin_defs = [_]struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    base_url: []const u8,
    adapter: Adapter,
    requires_api_key: bool,
    oauth: bool = false,
    anonymous_key: ?[]const u8 = null,
}{
    .{
        .id = "openai",
        .name = "OpenAI Codex",
        .description = "OpenAI ChatGPT & Codex OAuth authentication",
        .base_url = "https://chatgpt.com/backend-api",
        .adapter = .codex_responses,
        .requires_api_key = false,
        .oauth = true,
    },
    .{
        .id = "openrouter",
        .name = "OpenRouter",
        .description = "Unified router for 200+ AI models",
        .base_url = "https://openrouter.ai/api/v1",
        .adapter = .openai_compatible,
        .requires_api_key = true,
    },
    .{
        .id = "cerebras",
        .name = "Cerebras",
        .description = "Ultra-fast Cerebras WSE-3 wafer inference",
        .base_url = "https://api.cerebras.ai/v1",
        .adapter = .openai_compatible,
        .requires_api_key = true,
    },
    .{
        .id = "ollama_cloud",
        .name = "Ollama Cloud",
        .description = "Hosted Ollama cloud model infrastructure",
        .base_url = "https://ollama.com/v1",
        .adapter = .openai_compatible,
        .requires_api_key = true,
    },
    .{
        .id = "huggingface",
        .name = "HuggingFace",
        .description = "HuggingFace Serverless Inference API",
        .base_url = "https://router.huggingface.co/v1",
        .adapter = .openai_compatible,
        .requires_api_key = true,
    },
    .{
        .id = "nvidia_nim",
        .name = "Nvidia Nim",
        .description = "NVIDIA NIM microservices & GPU platform",
        .base_url = "https://integrate.api.nvidia.com/v1",
        .adapter = .openai_compatible,
        .requires_api_key = true,
    },
    .{
        .id = "opencode_zen",
        .name = "OpenCode Zen",
        .description = "Free public OpenCode Zen endpoint",
        .base_url = "https://opencode.ai/zen/v1",
        .adapter = .openai_compatible,
        .requires_api_key = false,
        .anonymous_key = "public",
    },
    .{
        .id = "deepseek",
        .name = "DeepSeek",
        .description = "DeepSeek AI models (DeepSeek-V3, DeepSeek-R1)",
        .base_url = "https://api.deepseek.com",
        .adapter = .openai_compatible,
        .requires_api_key = true,
    },
    .{
        .id = "google",
        .name = "Google Gemini",
        .description = "Google Gemini models via OpenAI-compatible endpoint",
        .base_url = "https://generativelanguage.googleapis.com/v1beta/openai",
        .adapter = .openai_compatible,
        .requires_api_key = true,
    },
    .{
        .id = "mistral",
        .name = "Mistral AI",
        .description = "Mistral AI models (Mistral Large, Codestral, Pixtral)",
        .base_url = "https://api.mistral.ai/v1",
        .adapter = .openai_compatible,
        .requires_api_key = true,
    },
    .{
        .id = "xai",
        .name = "xAI Grok",
        .description = "xAI Grok models (Grok-4, Grok-4.3)",
        .base_url = "https://api.x.ai/v1",
        .adapter = .openai_compatible,
        .requires_api_key = true,
    },
    .{
        .id = "perplexity",
        .name = "Perplexity",
        .description = "Perplexity AI models (Sonar, Sonar Pro)",
        .base_url = "https://api.perplexity.ai",
        .adapter = .openai_compatible,
        .requires_api_key = true,
    },
    .{
        .id = "cohere",
        .name = "Cohere",
        .description = "Cohere Command models (Command R+, Command R7B)",
        .base_url = "https://api.cohere.com/v1",
        .adapter = .openai_compatible,
        .requires_api_key = true,
    },
    .{
        .id = "alibaba",
        .name = "Alibaba Qwen",
        .description = "Alibaba Cloud Qwen models (Qwen3, Qwen2.5)",
        .base_url = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        .adapter = .openai_compatible,
        .requires_api_key = true,
    },
};

/// Load the builtin providers. The returned slice borrows from a comptime
/// constant — no allocation, no deinit needed.
pub fn loadBuiltins() []const Provider {
    const out = comptime blk: {
        var buf: [builtin_defs.len]Provider = undefined;
        for (&builtin_defs, 0..) |def, i| {
            buf[i] = .{
                .id = def.id,
                .name = def.name,
                .description = def.description,
                .base_url = def.base_url,
                .adapter = def.adapter,
                .requires_api_key = def.requires_api_key,
                .oauth = def.oauth,
                .anonymous_key = def.anonymous_key,
            };
        }
        break :blk buf;
    };
    return &out;
}

/// Load the cached models.dev api.json if it exists and is younger than
/// `cache_ttl_ms`. Returns null when the cache is missing or stale.
/// Caller owns the returned Registry.
pub fn loadCache(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) !?Registry {
    return loadCacheWithOptions(gpa, io, home_dir, false);
}

pub fn loadCacheWithOptions(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, ignore_ttl: bool) !?Registry {
    if (home_dir.len == 0) return null;

    const path = cachePath(gpa, home_dir) catch return null;
    defer gpa.free(path);

    const file = std.Io.Dir.openFile(.cwd(), io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer file.close(io);

    if (!ignore_ttl) {
        const stat = try file.stat(io);
        const now_ms = std.Io.Clock.now(.real, io).toMilliseconds();
        const age_ms = now_ms - stat.mtime.toMilliseconds();
        if (age_ms > cache_ttl_ms) return null;
    }

    var reader = file.reader(io, &.{});
    const bytes = try reader.interface.allocRemaining(gpa, .limited(4 * 1024 * 1024));
    defer gpa.free(bytes);

    return try parseModelsDevJson(gpa, bytes);
}

/// Fetch api.json from models.dev, cache it, and return the parsed providers.
/// Caller owns the returned Registry.
pub fn fetchAndCache(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) !Registry {
    if (home_dir.len == 0) return error.HomeNotSet;

    const bytes = try fetchApiJson(gpa, io);
    defer gpa.free(bytes);

    cacheApiJson(gpa, io, home_dir, bytes) catch |err| {
        log.warn("modelsdev.cache.write.failed err={s}", .{@errorName(err)});
    };

    return parseModelsDevJson(gpa, bytes);
}

/// Retrieve the merged provider registry. Prefers a fresh network fetch so
/// newly added providers are visible immediately; falls back to cache, the
/// vendored snapshot, or builtins when offline.
pub fn loadOrFetchRegistry(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) Registry {
    return loadRegistryImpl(gpa, io, home_dir, true);
}

/// Like `loadOrFetchRegistry` but skips the network fetch — uses only cache,
/// vendored snapshot, or builtins. Suitable for runtime paths where blocking
/// on network I/O is undesirable (e.g. model capability lookup at attach time).
/// The TUI's lazy `loadOrFetchRegistry` call refreshes the cache for next time.
pub fn loadRegistryCached(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) Registry {
    return loadRegistryImpl(gpa, io, home_dir, false);
}

fn loadRegistryImpl(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, allow_network: bool) Registry {
    const builtins = loadBuiltins();

    // Try network first so the picker always shows the latest providers.
    if (allow_network) {
        if (fetchAndCache(gpa, io, home_dir)) |fetched| {
            var f = fetched;
            defer f.deinit(gpa);
            log.info("modelsdev.fetch.ok remote_providers={d}", .{f.providers.len});
            if (buildRegistry(gpa, builtins, &f)) |merged| {
                log.info("modelsdev.registry.merged total={d} builtins={d} remote={d}", .{ merged.providers.len, builtins.len, f.providers.len });
                return merged;
            } else |err| {
                log.warn("modelsdev.build.failed err={s}", .{@errorName(err)});
            }
        } else |err| {
            log.warn("modelsdev.fetch.failed err={s}", .{@errorName(err)});
        }
    }

    if (loadCache(gpa, io, home_dir) catch null) |cached| {
        var c = cached;
        defer c.deinit(gpa);
        log.info("modelsdev.cache.fresh remote_providers={d}", .{c.providers.len});
        if (buildRegistry(gpa, builtins, &c)) |merged| {
            log.info("modelsdev.registry.merged total={d}", .{merged.providers.len});
            return merged;
        } else |err| {
            log.warn("modelsdev.build.failed err={s}", .{@errorName(err)});
        }
    }

    if (loadCacheWithOptions(gpa, io, home_dir, true) catch null) |stale| {
        var s = stale;
        defer s.deinit(gpa);
        log.warn("modelsdev.cache.stale remote_providers={d}", .{s.providers.len});
        if (buildRegistry(gpa, builtins, &s)) |merged| {
            log.info("modelsdev.registry.merged total={d}", .{merged.providers.len});
            return merged;
        } else |err| {
            log.warn("modelsdev.build.failed err={s}", .{@errorName(err)});
        }
    }

    // All network and cache sources failed — try the vendored snapshot
    // installed alongside the binary at <prefix>/share/nova/api.json.
    // Skip when home_dir is empty (test environments without a real io).
    if (home_dir.len > 0) {
        if (loadVendored(gpa, io)) |vendored| {
            var v = vendored;
            defer v.deinit(gpa);
            log.warn("modelsdev.vendored remote_providers={d}", .{v.registry.providers.len});
            // Seed the cache so subsequent starts can skip this step.
            cacheApiJson(gpa, io, home_dir, v.raw_json) catch |err| {
                log.warn("modelsdev.vendored.cache.seed.failed err={s}", .{@errorName(err)});
            };
            if (buildRegistry(gpa, builtins, &v.registry)) |merged| {
                log.info("modelsdev.registry.merged total={d}", .{merged.providers.len});
                return merged;
            } else |err| {
                log.warn("modelsdev.build.failed err={s}", .{@errorName(err)});
            }
        } else |err| {
            log.warn("modelsdev.vendored.failed err={s}", .{@errorName(err)});
        }
    }

    log.warn("modelsdev.registry.fallback builtins_only={d}", .{builtins.len});
    var empty_remote: Registry = .{ .providers = &.{}, .strings = .empty };
    return buildRegistry(gpa, builtins, &empty_remote) catch .{
        .providers = &.{},
        .strings = .empty,
    };
}

const StringRef = struct {
    start: usize,
    len: usize,

    fn slice(self: StringRef, buf: []const u8) []const u8 {
        return buf[self.start .. self.start + self.len];
    }
};

fn appendString(gpa: std.mem.Allocator, strings: *std.ArrayList(u8), s: []const u8) !StringRef {
    const start = strings.items.len;
    try strings.appendSlice(gpa, s);
    return .{ .start = start, .len = s.len };
}

const UnresolvedProvider = struct {
    id: StringRef,
    name: StringRef,
    description: StringRef,
    base_url: StringRef,
    adapter: Adapter,
    requires_api_key: bool,
    oauth: bool = false,
    anonymous_key: ?StringRef = null,

    fn resolve(self: UnresolvedProvider, buf: []const u8) Provider {
        return .{
            .id = self.id.slice(buf),
            .name = self.name.slice(buf),
            .description = self.description.slice(buf),
            .base_url = self.base_url.slice(buf),
            .adapter = self.adapter,
            .requires_api_key = self.requires_api_key,
            .oauth = self.oauth,
            .anonymous_key = if (self.anonymous_key) |k| k.slice(buf) else null,
        };
    }
};

const UnresolvedModel = struct {
    id: StringRef,
    reasoning: bool,
    context_window: u32,

    fn resolve(self: UnresolvedModel, buf: []const u8) ModelInfo {
        return .{
            .id = self.id.slice(buf),
            .reasoning = self.reasoning,
            .context_window = self.context_window,
        };
    }
};

/// Build the full merged registry: builtins first, then models.dev providers
/// that don't shadow a builtin id. Caller owns the returned Registry.
pub fn buildRegistry(gpa: std.mem.Allocator, builtins: []const Provider, remote_registry: *const Registry) !Registry {
    var strings: std.ArrayList(u8) = .empty;
    errdefer strings.deinit(gpa);

    var unresolved: std.ArrayList(UnresolvedProvider) = .empty;
    defer unresolved.deinit(gpa);

    // Builtins always come first and take precedence.
    for (builtins) |p| {
        try unresolved.append(gpa, .{
            .id = try appendString(gpa, &strings, p.id),
            .name = try appendString(gpa, &strings, p.name),
            .description = try appendString(gpa, &strings, p.description),
            .base_url = try appendString(gpa, &strings, p.base_url),
            .adapter = p.adapter,
            .requires_api_key = p.requires_api_key,
            .oauth = p.oauth,
            .anonymous_key = if (p.anonymous_key) |k| try appendString(gpa, &strings, k) else null,
        });
    }

    // Remote providers: skip any whose id already exists in builtins.
    for (remote_registry.providers) |p| {
        if (lookupBuiltin(builtins, p.id) != null) continue;
        try unresolved.append(gpa, .{
            .id = try appendString(gpa, &strings, p.id),
            .name = try appendString(gpa, &strings, p.name),
            .description = try appendString(gpa, &strings, p.description),
            .base_url = try appendString(gpa, &strings, p.base_url),
            .adapter = p.adapter,
            .requires_api_key = p.requires_api_key,
            .oauth = p.oauth,
            .anonymous_key = if (p.anonymous_key) |k| try appendString(gpa, &strings, k) else null,
        });
    }

    // Carry over model-level data from the remote registry. Builtin providers
    // don't carry model data; it all comes from api.json.
    var unresolved_models: std.ArrayList(UnresolvedModel) = .empty;
    defer unresolved_models.deinit(gpa);
    for (remote_registry.models) |m| {
        try unresolved_models.append(gpa, .{
            .id = try appendString(gpa, &strings, m.id),
            .reasoning = m.reasoning,
            .context_window = m.context_window,
        });
    }

    // Resolve every slice pointer only after ALL string appends complete.
    // Resolving `providers` before the model appends below would leave its
    // `id`/`name`/... slices dangling when `strings` reallocs to fit the
    // model ids (api.json carries hundreds of models, so a realloc is
    // guaranteed) — the picker then reads freed memory and SIGABRTs.
    const providers = try gpa.alloc(Provider, unresolved.items.len);
    errdefer gpa.free(providers);

    for (unresolved.items, 0..) |item, i| {
        providers[i] = item.resolve(strings.items);
    }

    const models: []ModelInfo = if (unresolved_models.items.len > 0) blk: {
        const m = try gpa.alloc(ModelInfo, unresolved_models.items.len);
        errdefer gpa.free(m);
        for (unresolved_models.items, 0..) |item, i| {
            m[i] = item.resolve(strings.items);
        }
        break :blk m;
    } else &.{};

    return .{
        .providers = providers,
        .models = models,
        .strings = strings,
    };
}

fn lookupBuiltin(builtins: []const Provider, id: []const u8) ?Provider {
    for (builtins) |p| {
        if (std.mem.eql(u8, p.id, id)) return p;
    }
    return null;
}

// ── HTTP fetch ──

const fetch_user_agent = "nova-agent/1.0 (models.dev registry fetcher)";

fn fetchApiJson(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(api_url);
    var request = try client.request(.GET, uri, .{
        .headers = .{ .user_agent = .{ .override = fetch_user_agent } },
    });
    defer request.deinit();
    try request.sendBodiless();

    var redirect_buffer: [redirect_buffer_bytes]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    const status: u16 = @intFromEnum(response.head.status);
    if (status < 200 or status >= 300) return error.HttpError;

    // Cloudflare serves the registry gzip-compressed; honour the response's
    // content-encoding instead of reading raw (compressed) bytes. Without
    // this the cache is seeded with gzip data that parseModelsDevJson rejects.
    var empty_decompress_buffer: [0]u8 = .{};
    var decompress_buffer: []u8 = &empty_decompress_buffer;
    var decompress_buffer_owned = false;
    switch (response.head.content_encoding) {
        .identity => {},
        .zstd => {
            decompress_buffer = try gpa.alloc(u8, std.compress.zstd.default_window_len);
            decompress_buffer_owned = true;
        },
        .deflate, .gzip => {
            decompress_buffer = try gpa.alloc(u8, std.compress.flate.max_window_len);
            decompress_buffer_owned = true;
        },
        .compress => return error.UnsupportedCompressionMethod,
    }
    defer if (decompress_buffer_owned) gpa.free(decompress_buffer);

    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    return reader.allocRemaining(gpa, .limited(response_bytes_max)) catch |err| switch (err) {
        error.StreamTooLong => error.ResponseTooLarge,
        else => |e| e,
    };
}

fn cacheApiJson(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8, bytes: []const u8) !void {
    const dir = try cacheDir(gpa, home_dir);
    defer gpa.free(dir);
    try std.Io.Dir.createDirPath(.cwd(), io, dir);

    const path = try cachePath(gpa, home_dir);
    defer gpa.free(path);

    const file = try std.Io.Dir.createFile(.cwd(), io, path, .{ .truncate = true });
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn cacheDir(gpa: std.mem.Allocator, home_dir: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ home_dir, ".config", "nova", "cache", cache_subdir });
}

fn cachePath(gpa: std.mem.Allocator, home_dir: []const u8) ![]u8 {
    const dir = try cacheDir(gpa, home_dir);
    defer gpa.free(dir);
    return std.fs.path.join(gpa, &.{ dir, cache_filename });
}

/// Result of loading the vendored snapshot — owns both the raw bytes and the
/// parsed registry so the caller can seed the cache from `raw_json`.
const VendoredResult = struct {
    registry: Registry,
    raw_json: []const u8,

    fn deinit(self: *VendoredResult, gpa: std.mem.Allocator) void {
        self.registry.deinit(gpa);
        gpa.free(self.raw_json);
    }
};

/// Load the vendored api.json installed alongside the binary at
/// `<prefix_dir>/share/nova/api.json` (where prefix_dir is the parent of exe_dir). Returns an error when the file is
/// missing or the executable path cannot be resolved.
fn loadVendored(gpa: std.mem.Allocator, io: std.Io) !VendoredResult {
    const exe_path = std.process.executablePathAlloc(io, gpa) catch
        return error.FileNotFound;
    defer gpa.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse return error.FileNotFound;
    const prefix_dir = std.fs.path.dirname(exe_dir) orelse return error.FileNotFound;
    const vendored_path = try std.fs.path.join(gpa, &.{ prefix_dir, "share", "nova", "api.json" });
    defer gpa.free(vendored_path);

    const file = std.Io.Dir.openFile(.cwd(), io, vendored_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => |e| return e,
    };
    defer file.close(io);

    var reader = file.reader(io, &.{});
    const bytes = try reader.interface.allocRemaining(gpa, .limited(4 * 1024 * 1024));
    errdefer gpa.free(bytes);

    const registry = try parseModelsDevJson(gpa, bytes);
    return .{ .registry = registry, .raw_json = bytes };
}

// ── JSON parsing ──

fn parseModelsDevJson(gpa: std.mem.Allocator, bytes: []const u8) !Registry {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidApiJson;

    var strings: std.ArrayList(u8) = .empty;
    errdefer strings.deinit(gpa);

    var unresolved: std.ArrayList(UnresolvedProvider) = .empty;
    defer unresolved.deinit(gpa);

    var unresolved_models: std.ArrayList(UnresolvedModel) = .empty;
    defer unresolved_models.deinit(gpa);

    var it = parsed.value.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* != .object) continue;

        // Include any provider that exposes an api base URL and at least
        // one model. The `api` field is the ground-truth signal that the
        // endpoint can be driven by Nova's openai_compatible adapter;
        // npm package identity is irrelevant for connectivity.
        const api_field = kv.value_ptr.object.get("api") orelse continue;
        if (api_field != .string) continue;
        if (api_field.string.len == 0) continue;

        const name_field = kv.value_ptr.object.get("name") orelse continue;
        if (name_field != .string) continue;

        const models_field = kv.value_ptr.object.get("models") orelse continue;
        if (models_field != .object) continue;
        if (models_field.object.count() == 0) continue;

        const desc_value = kv.value_ptr.object.get("description") orelse name_field;
        const desc: []const u8 = if (desc_value == .string) desc_value.string else name_field.string;

        try unresolved.append(gpa, .{
            .id = try appendString(gpa, &strings, kv.key_ptr.*),
            .name = try appendString(gpa, &strings, name_field.string),
            .description = try appendString(gpa, &strings, desc),
            .base_url = try appendString(gpa, &strings, api_field.string),
            .adapter = .openai_compatible,
            .requires_api_key = true,
        });

        // Extract per-model capability data (reasoning, context window).
        var model_it = models_field.object.iterator();
        while (model_it.next()) |mkv| {
            if (mkv.value_ptr.* != .object) continue;
            const reasoning = blk: {
                const r = mkv.value_ptr.object.get("reasoning") orelse break :blk false;
                if (r == .bool) break :blk r.bool;
                break :blk false;
            };
            const context_window = blk: {
                const limit_field = mkv.value_ptr.object.get("limit") orelse break :blk 0;
                if (limit_field != .object) break :blk 0;
                const ctx = limit_field.object.get("context") orelse break :blk 0;
                if (ctx != .integer) break :blk 0;
                if (ctx.integer < 0) break :blk 0;
                break :blk @as(u32, @intCast(ctx.integer));
            };
            try unresolved_models.append(gpa, .{
                .id = try appendString(gpa, &strings, mkv.key_ptr.*),
                .reasoning = reasoning,
                .context_window = context_window,
            });
        }
    }

    const providers = try gpa.alloc(Provider, unresolved.items.len);
    errdefer gpa.free(providers);

    for (unresolved.items, 0..) |item, i| {
        providers[i] = item.resolve(strings.items);
    }

    const models: []ModelInfo = if (unresolved_models.items.len > 0) blk: {
        const m = try gpa.alloc(ModelInfo, unresolved_models.items.len);
        errdefer gpa.free(m);
        for (unresolved_models.items, 0..) |item, i| {
            m[i] = item.resolve(strings.items);
        }
        break :blk m;
    } else &.{};

    return .{
        .providers = providers,
        .models = models,
        .strings = strings,
    };
}

// ── Tests ──

test "loadBuiltins returns all providers" {
    const providers = loadBuiltins();
    try std.testing.expect(providers.len >= 14);
    try std.testing.expectEqualStrings("openai", providers[0].id);
    try std.testing.expectEqualStrings("OpenAI Codex", providers[0].name);
    try std.testing.expectEqual(Adapter.codex_responses, providers[0].adapter);
    try std.testing.expect(providers[0].oauth);
    try std.testing.expect(!providers[0].requires_api_key);
}

test "parseModelsDevJson includes any provider with api field and models" {
    const gpa = std.testing.allocator;
    const json =
        \\{
        \\  "deepseek": {
        \\    "npm": "@ai-sdk/openai-compatible",
        \\    "api": "https://api.deepseek.com",
        \\    "name": "DeepSeek",
        \\    "models": { "deepseek-chat": {} }
        \\  },
        \\  "meta": {
        \\    "npm": "@ai-sdk/openai",
        \\    "api": "https://api.meta.ai/v1",
        \\    "name": "Meta",
        \\    "models": { "llama-3-70b": {} }
        \\  },
        \\  "kimi-for-coding": {
        \\    "npm": "@ai-sdk/anthropic",
        \\    "api": "https://api.kimi.com/coding/v1",
        \\    "name": "Kimi for Coding",
        \\    "models": { "kimi-coding": {} }
        \\  },
        \\  "google": {
        \\    "npm": "@ai-sdk/google",
        \\    "name": "Google",
        \\    "models": { "gemini-2.5-flash": {} }
        \\  },
        \\  "no-api": {
        \\    "npm": "@ai-sdk/openai-compatible",
        \\    "name": "NoApi",
        \\    "models": { "m": {} }
        \\  },
        \\  "no-models": {
        \\    "npm": "@ai-sdk/openai-compatible",
        \\    "api": "https://example.com",
        \\    "name": "NoModels"
        \\  }
        \\}
    ;

    var registry = try parseModelsDevJson(gpa, json);
    defer registry.deinit(gpa);

    // deepseek + meta + kimi-for-coding pass (have api + models);
    // google (no api), no-api (no api), no-models (no models) fail.
    try std.testing.expectEqual(@as(usize, 3), registry.providers.len);
    try std.testing.expectEqualStrings("deepseek", registry.providers[0].id);
    try std.testing.expectEqualStrings("DeepSeek", registry.providers[0].name);
    try std.testing.expectEqualStrings("https://api.deepseek.com", registry.providers[0].base_url);
    try std.testing.expectEqualStrings("meta", registry.providers[1].id);
    try std.testing.expectEqualStrings("Meta", registry.providers[1].name);
    try std.testing.expectEqualStrings("https://api.meta.ai/v1", registry.providers[1].base_url);
    try std.testing.expectEqualStrings("kimi-for-coding", registry.providers[2].id);
    try std.testing.expectEqualStrings("Kimi for Coding", registry.providers[2].name);
    try std.testing.expectEqualStrings("https://api.kimi.com/coding/v1", registry.providers[2].base_url);
}

test "parseModelsDevJson extracts model-level reasoning and context window" {
    const gpa = std.testing.allocator;
    const json =
        \\{
        \\  "openai": {
        \\    "api": "https://api.openai.com/v1",
        \\    "name": "OpenAI",
        \\    "models": {
        \\      "gpt-4o": { "reasoning": false, "limit": { "context": 128000 } },
        \\      "gpt-5": { "reasoning": true, "limit": { "context": 400000 } },
        \\      "no-limit": { "reasoning": true }
        \\    }
        \\  }
        \\}
    ;

    var registry = try parseModelsDevJson(gpa, json);
    defer registry.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), registry.models.len);

    // Exact match.
    const gpt4o = registry.lookupModel("gpt-4o").?;
    try std.testing.expect(!gpt4o.reasoning);
    try std.testing.expectEqual(@as(u32, 128_000), gpt4o.context_window);

    const gpt5 = registry.lookupModel("gpt-5").?;
    try std.testing.expect(gpt5.reasoning);
    try std.testing.expectEqual(@as(u32, 400_000), gpt5.context_window);

    // Missing limit defaults to 0.
    const no_limit = registry.lookupModel("no-limit").?;
    try std.testing.expect(no_limit.reasoning);
    try std.testing.expectEqual(@as(u32, 0), no_limit.context_window);

    // Provider prefix is stripped.
    try std.testing.expectEqual(gpt5.id, registry.lookupModel("openai/gpt-5").?.id);

    // Longest-prefix match: dated variant resolves to base family.
    try std.testing.expectEqual(gpt5.id, registry.lookupModel("gpt-5-2025-08-07").?.id);

    // Unknown model returns null.
    try std.testing.expect(registry.lookupModel("unknown-model") == null);
}

test "buildRegistry merges builtins and remote, builtins win" {
    const gpa = std.testing.allocator;

    const builtins = loadBuiltins();

    // Create a minimal remote registry with a conflicting deepseek and a new provider.
    var remote_registry = try parseModelsDevJson(gpa,
        \\{
        \\  "deepseek": {
        \\    "npm": "@ai-sdk/openai-compatible",
        \\    "api": "https://api.deepseek.com",
        \\    "name": "DeepSeek (remote)",
        \\    "models": { "deepseek-chat": {} }
        \\  },
        \\  "302ai": {
        \\    "npm": "@ai-sdk/openai-compatible",
        \\    "api": "https://api.302.ai/v1",
        \\    "name": "302.AI",
        \\    "models": { "m": {} }
        \\  }
        \\}
    );
    defer remote_registry.deinit(gpa);

    var merged = try buildRegistry(gpa, builtins, &remote_registry);
    defer merged.deinit(gpa);

    // openai (builtin first), deepseek (builtin wins), 302ai (remote only)
    try std.testing.expect(merged.providers.len >= builtins.len + 1);
    try std.testing.expectEqualStrings("openai", merged.providers[0].id);

    // Find deepseek — should be the builtin version
    const ds = merged.lookup("deepseek").?;
    try std.testing.expectEqualStrings("DeepSeek", ds.name);
    try std.testing.expectEqualStrings("https://api.deepseek.com", ds.base_url);

    // 302ai should be present from remote
    const ai302 = merged.lookup("302ai").?;
    try std.testing.expectEqualStrings("302.AI", ai302.name);
}

test "buildRegistry provider slices survive model-string realloc" {
    const gpa = std.testing.allocator;

    const builtins = loadBuiltins();

    // A remote registry with enough models that appending their ids to the
    // backing `strings` buffer forces a realloc. If `providers` were resolved
    // before the model appends, every provider's id/name/base_url slice would
    // dangle after the realloc and the assertions below would read freed
    // memory (SIGABRT under DebugAllocator).
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    try json.appendSlice(gpa, "{\"302ai\":{\"npm\":\"@ai-sdk/openai-compatible\",\"api\":\"https://api.302.ai/v1\",\"name\":\"302.AI\",\"models\":{");
    for (0..2000) |i| {
        if (i > 0) try json.appendSlice(gpa, ",");
        const entry = try std.fmt.allocPrint(gpa, "\"model-{d}\":{{\"context_length\":128000}}", .{i});
        defer gpa.free(entry);
        try json.appendSlice(gpa, entry);
    }
    try json.appendSlice(gpa, "}}}");

    var remote_registry = try parseModelsDevJson(gpa, json.items);
    defer remote_registry.deinit(gpa);

    var merged = try buildRegistry(gpa, builtins, &remote_registry);
    defer merged.deinit(gpa);

    const ai302 = merged.lookup("302ai").?;
    try std.testing.expectEqualStrings("302.AI", ai302.name);
    try std.testing.expectEqualStrings("https://api.302.ai/v1", ai302.base_url);
    try std.testing.expectEqual(@as(usize, 2000), merged.models.len);
    try std.testing.expectEqualStrings("model-1999", merged.models[1999].id);
}

test "loadOrFetchRegistry fallback to builtins when no cache or network" {
    const gpa = std.testing.allocator;
    const io: std.Io = undefined;
    var registry = loadOrFetchRegistry(gpa, io, "");
    defer registry.deinit(gpa);

    try std.testing.expect(registry.providers.len >= 14);
    const ds = registry.lookup("deepseek").?;
    try std.testing.expectEqualStrings("DeepSeek", ds.name);
}

test "parseModelsDevJson returns empty registry for empty object" {
    const gpa = std.testing.allocator;
    var registry = try parseModelsDevJson(gpa, "{}");
    defer registry.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), registry.providers.len);
}

test "parseModelsDevJson rejects malformed JSON" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.SyntaxError, parseModelsDevJson(gpa, "{invalid"));
}

test "parseModelsDevJson rejects non-object root" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidApiJson, parseModelsDevJson(gpa, "[]"));
}

test "fetchAndCache returns error.HomeNotSet when home_dir is empty" {
    try std.testing.expectError(error.HomeNotSet, fetchAndCache(std.testing.allocator, std.testing.io, ""));
}

test "loadCacheWithOptions returns null when home_dir is empty" {
    const result = try loadCacheWithOptions(std.testing.allocator, std.testing.io, "", false);
    try std.testing.expect(result == null);
}
