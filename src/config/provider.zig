//! Provider catalogue, model types, and selection primitives.
//!
//! Pure data types with no dependency on the Config struct or the
//! parse/serialize pipeline. Imported by `config.zig` (which re-exports
//! everything) and directly by modules that only need the type surface.

const std = @import("std");
const log = std.log.scoped(.config);
const ai = @import("../ai.zig");
const mcp = @import("mcp.zig");

pub const Provider = enum {
    openai,
    openai_compatible,
    ollama,
    llama_cpp,
    openrouter,
    cerebras,
    ollama_cloud,
    huggingface,
    nvidia_nim,
    opencode_zen,
    deepseek,
    google,
    mistral,
    xai,
    perplexity,
    cohere,
    alibaba,
    anthropic,

    pub fn label(self: Provider) []const u8 {
        return providerSpec(self).id;
    }

    pub fn displayName(self: Provider) []const u8 {
        return providerSpec(self).name;
    }

    /// Default base_url for this Provider. `null` means the user MUST
    /// supply one (e.g. raw `openai_compatible` and `anthropic`).
    pub fn defaultBaseUrl(self: Provider) ?[]const u8 {
        return providerSpec(self).defaultBaseUrl();
    }

    pub fn adapter(self: Provider) ?AdapterKind {
        return providerSpec(self).adapter;
    }

    pub fn isCatalogue(self: Provider) bool {
        return providerSpec(self).catalogue;
    }

    pub fn requiresApiKey(self: Provider) bool {
        return providerSpec(self).requires_api_key;
    }

    pub fn anonymousApiKey(self: Provider) ?[]const u8 {
        return providerSpec(self).anonymous_key;
    }

    pub fn description(self: Provider) []const u8 {
        return providerSpec(self).description;
    }
};

pub fn catalogueProviders() []const Provider {
    const list = comptime blk: {
        var buf: [builtin_providers.len]Provider = undefined;
        var n: usize = 0;
        for (builtin_providers) |spec| {
            if (spec.catalogue) {
                buf[n] = spec.provider;
                n += 1;
            }
        }
        const final = buf[0..n].*;
        break :blk final;
    };
    return &list;
}

pub const AdapterKind = enum {
    codex_responses,
    openai_responses,
    openai_compatible,
};

pub const ProviderDef = struct {
    provider: Provider = .openai_compatible,
    id: []const u8,
    name: []const u8,
    description: []const u8,
    base_url: []const u8,
    adapter: ?AdapterKind = .openai_compatible,
    requires_api_key: bool = true,
    oauth: bool = false,
    anonymous_key: ?[]const u8 = null,
    catalogue: bool = false,

    pub fn label(self: ProviderDef) []const u8 {
        return self.id;
    }

    pub fn displayName(self: ProviderDef) []const u8 {
        return self.name;
    }

    pub fn defaultBaseUrl(self: ProviderDef) ?[]const u8 {
        return if (self.base_url.len > 0) self.base_url else null;
    }
};

pub const ProviderSpec = ProviderDef;

pub const builtin_providers = [_]ProviderDef{
    .{ .provider = .openai, .id = "openai", .name = "OpenAI Codex", .description = "OpenAI ChatGPT & Codex authentication", .base_url = "https://chatgpt.com/backend-api", .adapter = .codex_responses, .requires_api_key = false, .oauth = true },
    .{ .provider = .openai_compatible, .id = "openai_compatible", .name = "OpenAI Compatible", .description = "Custom OpenAI-compatible REST server", .base_url = "", .adapter = .openai_compatible, .requires_api_key = true },
    .{ .provider = .ollama, .id = "ollama", .name = "Ollama", .description = "Local Ollama server instance (localhost:11434)", .base_url = "http://localhost:11434", .adapter = .openai_compatible, .requires_api_key = true },
    .{ .provider = .llama_cpp, .id = "llama.cpp", .name = "llama.cpp", .description = "Local llama.cpp HTTP server (localhost:8080)", .base_url = "http://localhost:8080", .adapter = .openai_compatible, .requires_api_key = true },
    .{ .provider = .openrouter, .id = "openrouter", .name = "OpenRouter", .description = "Unified router for 200+ AI models", .base_url = "https://openrouter.ai/api/v1", .adapter = .openai_compatible, .catalogue = true },
    .{ .provider = .cerebras, .id = "cerebras", .name = "Cerebras", .description = "Ultra-fast Cerebras WSE-3 wafer inference", .base_url = "https://api.cerebras.ai/v1", .adapter = .openai_compatible, .catalogue = true },
    .{ .provider = .ollama_cloud, .id = "ollama_cloud", .name = "Ollama Cloud", .description = "Hosted Ollama cloud model infrastructure", .base_url = "https://ollama.com/v1", .adapter = .openai_compatible, .catalogue = true },
    .{ .provider = .huggingface, .id = "huggingface", .name = "HuggingFace", .description = "HuggingFace Serverless Inference API", .base_url = "https://router.huggingface.co/v1", .adapter = .openai_compatible, .catalogue = true },
    .{ .provider = .nvidia_nim, .id = "nvidia_nim", .name = "Nvidia Nim", .description = "NVIDIA NIM microservices & GPU platform", .base_url = "https://integrate.api.nvidia.com/v1", .adapter = .openai_compatible, .catalogue = true },
    .{ .provider = .opencode_zen, .id = "opencode_zen", .name = "OpenCode Zen", .description = "Free public OpenCode Zen endpoint", .base_url = "https://opencode.ai/zen/v1", .adapter = .openai_compatible, .catalogue = true, .requires_api_key = false, .anonymous_key = "public" },
    .{ .provider = .deepseek, .id = "deepseek", .name = "DeepSeek", .description = "DeepSeek AI models (DeepSeek-V3, DeepSeek-R1)", .base_url = "https://api.deepseek.com", .adapter = .openai_compatible, .catalogue = true },
    .{ .provider = .google, .id = "google", .name = "Google Gemini", .description = "Google Gemini models via OpenAI-compatible endpoint", .base_url = "https://generativelanguage.googleapis.com/v1beta/openai", .adapter = .openai_compatible, .catalogue = true },
    .{ .provider = .mistral, .id = "mistral", .name = "Mistral AI", .description = "Mistral AI models (Mistral Large, Codestral, Pixtral)", .base_url = "https://api.mistral.ai/v1", .adapter = .openai_compatible, .catalogue = true },
    .{ .provider = .xai, .id = "xai", .name = "xAI Grok", .description = "xAI Grok models (Grok-4, Grok-4.3)", .base_url = "https://api.x.ai/v1", .adapter = .openai_compatible, .catalogue = true },
    .{ .provider = .perplexity, .id = "perplexity", .name = "Perplexity", .description = "Perplexity AI models (Sonar, Sonar Pro)", .base_url = "https://api.perplexity.ai", .adapter = .openai_compatible, .catalogue = true },
    .{ .provider = .cohere, .id = "cohere", .name = "Cohere", .description = "Cohere Command models (Command R+, Command R7B)", .base_url = "https://api.cohere.com/v1", .adapter = .openai_compatible, .catalogue = true },
    .{ .provider = .alibaba, .id = "alibaba", .name = "Alibaba Qwen", .description = "Alibaba Cloud Qwen models (Qwen3, Qwen2.5)", .base_url = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", .adapter = .openai_compatible, .catalogue = true },
    .{ .provider = .anthropic, .id = "anthropic", .name = "Anthropic", .description = "Direct Anthropic API (Claude 3.5 Sonnet)", .base_url = "", .adapter = null, .requires_api_key = true },
};

pub const provider_specs = builtin_providers;

pub const providers_by_name = std.StaticStringMap(Provider).initComptime(.{
    .{ "openai", .openai },
    .{ "openai_compatible", .openai_compatible },
    .{ "ollama", .ollama },
    .{ "llama.cpp", .llama_cpp },
    .{ "openrouter", .openrouter },
    .{ "cerebras", .cerebras },
    .{ "ollama_cloud", .ollama_cloud },
    .{ "huggingface", .huggingface },
    .{ "nvidia_nim", .nvidia_nim },
    .{ "opencode_zen", .opencode_zen },
    .{ "deepseek", .deepseek },
    .{ "google", .google },
    .{ "mistral", .mistral },
    .{ "xai", .xai },
    .{ "perplexity", .perplexity },
    .{ "cohere", .cohere },
    .{ "alibaba", .alibaba },
    .{ "anthropic", .anthropic },
});

/// All builtin provider labels, for auth.json integrity checks.
/// Builtin keys are never pruned — they're always valid.
pub fn allBuiltinLabels() []const []const u8 {
    const list = comptime blk: {
        var buf: [builtin_providers.len][]const u8 = undefined;
        for (builtin_providers, 0..) |p, i| {
            buf[i] = p.id;
        }
        const final = buf;
        break :blk final;
    };
    return &list;
}

comptime {
    std.debug.assert(builtin_providers.len == @typeInfo(Provider).@"enum".fields.len);
    for (builtin_providers, 0..) |p, i| {
        std.debug.assert(@intFromEnum(p.provider) == i);
    }
}

fn providerSpec(provider: Provider) ProviderDef {
    const index: usize = @intFromEnum(provider);
    return builtin_providers[index];
}

pub const Model = struct {
    id: []u8,
    reasoning: ReasoningSetting = .unset,
    /// Explicit context window override for this model (tokens).
    /// When set, overrides the model catalogue lookup.
    context_window: ?u32 = null,
    /// Maximum output tokens per generation turn for this model.
    max_output_tokens: ?u32 = null,
    /// Reasoning efforts this model supports. Empty = all efforts
    /// available (backward compatible). The TUI model picker filters
    /// its reasoning cycle to this list.
    reasoning_options: []const ai.ReasoningEffort = &.{},

    pub fn deinit(self: *Model, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        if (self.reasoning_options.len > 0) gpa.free(self.reasoning_options);
        self.* = undefined;
    }

    pub fn clone(self: Model, gpa: std.mem.Allocator) !Model {
        var out: Model = .{
            .id = try gpa.dupe(u8, self.id),
            .reasoning = self.reasoning,
            .context_window = self.context_window,
            .max_output_tokens = self.max_output_tokens,
        };
        if (self.reasoning_options.len > 0) {
            out.reasoning_options = try gpa.dupe(ai.ReasoningEffort, self.reasoning_options);
        }
        return out;
    }
};

/// Per-provider base URL: either the provider's built-in default or an
/// explicit URL supplied by the user. Replaces `?[]u8` where `null` was
/// ambiguous between "use default" and "not specified in this layer".
/// In overlay merges, `.default` means "don't override"; at final
/// resolution, `.default` falls through to `Provider.defaultBaseUrl()`.
pub const BaseUrl = union(enum) {
    default,
    custom: []u8,
};

/// Per-model reasoning effort setting. Follows the same overlay-merge
/// pattern as `BaseUrl`: `.unset` means "not specified in this layer,
/// don't override"; `.effort` carries an explicit level (including
/// `.default` which tells the request builder to omit the parameter).
pub const ReasoningSetting = union(enum) {
    /// Not specified in this config layer — inherit from lower layer.
    unset,
    /// Explicit effort level.
    effort: ai.ReasoningEffort,

    /// Resolve to a concrete effort for the AI client. `.unset` falls
    /// back to `.medium` (the runtime default).
    pub fn resolve(self: ReasoningSetting) ai.ReasoningEffort {
        return switch (self) {
            .unset => .medium,
            .effort => |e| e,
        };
    }
};

/// Per-provider model entry. Identical in shape to `Model` — kept as a
/// type alias so callers that conceptually deal with "a model entry
/// declared inside a ProviderConfig" can name it explicitly. The two
/// were line-for-line duplicates before; the alias removes the drift
/// risk for good.
pub const ProviderModel = Model;

/// An extra HTTP header sent on every outbound AI request to this provider
/// (e.g. a gateway auth token). Same shape and `{env:VAR}` semantics as the
/// MCP header type, aliased so the two stay one concept: raw placeholders on
/// disk, expansion at use time (AI-client attach for providers, connect for
/// MCP servers).
pub const ProviderHeader = mcp.McpHeader;

/// Parse-time cap on `providers.<name>.headers` entries. Kept in lockstep
/// with the wire-side budget (`provider_headers.max_user_headers`) so a
/// full user list always fits every send-site buffer.
pub const max_provider_headers: usize = ai.provider_headers.max_user_headers;

/// Expand `{env:VAR}` in raw provider headers into owned wire specs
/// (`.literal` values). Caller frees with `provider_headers.freeHeaders`;
/// empty input yields the empty static slice. Shared by the runtime's
/// client-attach path and the picker's model probe — the two places raw
/// config headers become wire headers.
pub fn expandProviderHeaders(gpa: std.mem.Allocator, raw: []const ProviderHeader) ![]ai.provider_headers.Header {
    if (raw.len == 0) return &.{};
    var out: std.ArrayList(ai.provider_headers.Header) = .empty;
    errdefer {
        ai.provider_headers.freeHeaderValues(gpa, out.items);
        out.deinit(gpa);
    }
    for (raw) |header| {
        const value = try mcp.expandEnvValue(gpa, header.value);
        // Validate AFTER expansion: parse-time validation sees only the raw
        // `{env:VAR}` placeholder, so an env var carrying CR/LF (trailing
        // newline from `$(cat token)`, PEMs) would otherwise inject onto the
        // wire. (HeaderSet.append re-checks at send time as backstop.)
        if (!ai.provider_headers.isValidHeaderValue(value)) {
            log.warn("provider header '{s}' expanded to a value with invalid bytes; skipping", .{header.name});
            gpa.free(value);
            continue;
        }
        errdefer gpa.free(value);
        const name = try gpa.dupe(u8, header.name);
        errdefer gpa.free(name);
        try out.append(gpa, .{ .name = name, .value = .{ .literal = value } });
    }
    return out.toOwnedSlice(gpa);
}

pub const ProviderConfig = struct {
    /// The JSON map key. For builtins this equals `provider.label()`;
    /// for custom providers it's the user-chosen name (e.g. "qwen-cloud").
    name: []u8,
    provider: Provider,
    base_url: BaseUrl = .default,
    /// Extra outbound HTTP headers, `{ "Name": "value {env:VAR}" }`. Owned;
    /// raw placeholders are preserved through serialize so resolved secrets
    /// never reach disk.
    headers: []ProviderHeader = &.{},
    models: []ProviderModel = &.{},

    pub fn deinit(self: *ProviderConfig, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        switch (self.base_url) {
            .custom => |s| gpa.free(s),
            .default => {},
        }
        mcp.freeHeaders(gpa, self.headers);
        for (self.models) |*model| model.deinit(gpa);
        if (self.models.len > 0) gpa.free(self.models);
        self.* = undefined;
    }

    pub fn clone(self: ProviderConfig, gpa: std.mem.Allocator) !ProviderConfig {
        var out: ProviderConfig = .{
            .name = try gpa.dupe(u8, self.name),
            .provider = self.provider,
        };
        errdefer out.deinit(gpa);
        switch (self.base_url) {
            .custom => |s| out.base_url = .{ .custom = try gpa.dupe(u8, s) },
            .default => {},
        }
        out.headers = try mcp.cloneHeaders(gpa, self.headers);
        out.models = try gpa.alloc(ProviderModel, self.models.len);
        for (self.models, 0..) |model, index| out.models[index] = try model.clone(gpa);
        return out;
    }
};

pub const ModelSelectionRef = union(enum) {
    builtin: BuiltinSelectionRef,
    custom: CustomSelectionRef,

    pub fn provider(self: ModelSelectionRef) Provider {
        return switch (self) {
            .builtin => |b| b.provider,
            .custom => .openai_compatible,
        };
    }

    pub fn providerName(self: ModelSelectionRef) []const u8 {
        return switch (self) {
            .builtin => |b| b.provider_name,
            .custom => |c| c.provider_name,
        };
    }

    pub fn model(self: ModelSelectionRef) *const Model {
        return switch (self) {
            .builtin => |b| b.model,
            .custom => |c| c.model,
        };
    }

    pub fn baseUrl(self: ModelSelectionRef) ?[]const u8 {
        return switch (self) {
            .builtin => null,
            .custom => |c| c.base_url,
        };
    }

    pub fn apiKey(self: ModelSelectionRef) ?[]const u8 {
        return switch (self) {
            .builtin => null,
            .custom => |c| c.api_key,
        };
    }
};

const BuiltinSelectionRef = struct {
    provider: Provider,
    provider_name: []const u8,
    model: *const Model,
};

const CustomSelectionRef = struct {
    provider_name: []const u8,
    base_url: []const u8,
    api_key: []const u8,
    model: *const Model,
};

/// A complete, ready-to-use model selection. The fields that were
/// previously optional on `Config` and runtime-asserted to be all-set
/// (provider, base_url, api_key, model) live here as non-optional.
/// Optional settings stay optional. `Config.model_selection: ?ModelSelection`
/// is the typed view; legacy callers that read the loose `Config`
/// fields keep working until the migration PRs land.
pub const ModelSelection = union(enum) {
    builtin: BuiltinSelection,
    custom: CustomSelection,

    pub fn deinit(self: *ModelSelection, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .builtin => |*b| b.deinit(gpa),
            .custom => |*c| c.deinit(gpa),
        }
        self.* = undefined;
    }

    pub fn clone(self: ModelSelection, gpa: std.mem.Allocator) !ModelSelection {
        return switch (self) {
            .builtin => |b| ModelSelection{ .builtin = try b.clone(gpa) },
            .custom => |c| ModelSelection{ .custom = try c.clone(gpa) },
        };
    }

    // NOTE: every accessor below takes `self: *const ModelSelection` (pointer
    // receiver), NOT a value receiver. Returning `&b.model` / `b.provider_name`
    // from a *value* receiver would point into this function's popped stack
    // frame — a dangling ref that reads garbage once the caller makes any
    // further call (the same bug class as Config.activeModelSelection, which
    // crashed ReasoningSetting.resolve with "switch on corrupt value"). With a
    // pointer receiver the returned pointers/slices resolve into the caller's
    // own ModelSelection storage, which outlives the read. Method-call syntax
    // auto-references value receivers, so no call site changes.
    pub fn provider(self: *const ModelSelection) Provider {
        return switch (self.*) {
            .builtin => |*b| b.provider,
            .custom => .openai_compatible,
        };
    }

    pub fn providerName(self: *const ModelSelection) []const u8 {
        return switch (self.*) {
            .builtin => |*b| b.provider_name,
            .custom => |*c| c.provider_name,
        };
    }

    pub fn model(self: *const ModelSelection) *const Model {
        return switch (self.*) {
            .builtin => |*b| &b.model,
            .custom => |*c| &c.model,
        };
    }

    pub fn baseUrl(self: *const ModelSelection) ?[]const u8 {
        return switch (self.*) {
            .builtin => null,
            .custom => |*c| c.base_url,
        };
    }

    pub fn apiKey(self: *const ModelSelection) ?[]const u8 {
        return switch (self.*) {
            .builtin => null,
            .custom => |*c| c.api_key,
        };
    }

    pub fn useResponsesEndpoint(self: *const ModelSelection) bool {
        return switch (self.*) {
            .builtin => |*b| b.use_responses_endpoint,
            .custom => |*c| c.use_responses_endpoint,
        };
    }

    pub fn systemPrompt(self: *const ModelSelection) ?[]const u8 {
        return switch (self.*) {
            .builtin => |*b| b.system_prompt,
            .custom => |*c| c.system_prompt,
        };
    }

    pub fn bashClassifierUrl(self: *const ModelSelection) ?[]const u8 {
        return switch (self.*) {
            .builtin => |*b| b.bash_classifier_url,
            .custom => |*c| c.bash_classifier_url,
        };
    }
};

const BuiltinSelection = struct {
    provider: Provider,
    /// The provider name as written in config (map key or defaultModel prefix).
    /// For builtins this equals `provider.label()`.
    provider_name: []u8,
    model: Model,
    use_responses_endpoint: bool = false,
    system_prompt: ?[]u8 = null,
    bash_classifier_url: ?[]u8 = null,

    pub fn deinit(self: *BuiltinSelection, gpa: std.mem.Allocator) void {
        gpa.free(self.provider_name);
        self.model.deinit(gpa);
        if (self.system_prompt) |s| gpa.free(s);
        if (self.bash_classifier_url) |s| gpa.free(s);
        self.* = undefined;
    }

    pub fn clone(self: BuiltinSelection, gpa: std.mem.Allocator) !BuiltinSelection {
        return .{
            .provider = self.provider,
            .provider_name = try gpa.dupe(u8, self.provider_name),
            .model = try self.model.clone(gpa),
            .use_responses_endpoint = self.use_responses_endpoint,
            .system_prompt = if (self.system_prompt) |s| try gpa.dupe(u8, s) else null,
            .bash_classifier_url = if (self.bash_classifier_url) |s| try gpa.dupe(u8, s) else null,
        };
    }
};

const CustomSelection = struct {
    provider_name: []u8,
    base_url: []u8,
    api_key: []u8,
    model: Model,
    use_responses_endpoint: bool = false,
    system_prompt: ?[]u8 = null,
    bash_classifier_url: ?[]u8 = null,

    pub fn deinit(self: *CustomSelection, gpa: std.mem.Allocator) void {
        gpa.free(self.provider_name);
        gpa.free(self.base_url);
        gpa.free(self.api_key);
        self.model.deinit(gpa);
        if (self.system_prompt) |s| gpa.free(s);
        if (self.bash_classifier_url) |s| gpa.free(s);
        self.* = undefined;
    }

    pub fn clone(self: CustomSelection, gpa: std.mem.Allocator) !CustomSelection {
        return .{
            .provider_name = try gpa.dupe(u8, self.provider_name),
            .base_url = try gpa.dupe(u8, self.base_url),
            .api_key = try gpa.dupe(u8, self.api_key),
            .model = try self.model.clone(gpa),
            .use_responses_endpoint = self.use_responses_endpoint,
            .system_prompt = if (self.system_prompt) |s| try gpa.dupe(u8, s) else null,
            .bash_classifier_url = if (self.bash_classifier_url) |s| try gpa.dupe(u8, s) else null,
        };
    }
};

test "returnsCatalogueProvidersList_whenCatalogueProvidersCalled" {
    const list = catalogueProviders();
    try std.testing.expect(list.len > 0);

    for (list) |p| {
        try std.testing.expect(p.isCatalogue());
    }

    // Known catalogue providers check
    var found_openrouter = false;
    for (list) |p| {
        if (p == .openrouter) found_openrouter = true;
    }
    try std.testing.expect(found_openrouter);
}

test "returnsAllBuiltinLabels_whenAllBuiltinLabelsCalled" {
    const labels = allBuiltinLabels();
    try std.testing.expectEqual(@typeInfo(Provider).@"enum".fields.len, labels.len);

    for (labels) |lbl| {
        try std.testing.expect(providers_by_name.get(lbl) != null);
    }
}

test "lookupProvider_whenProvidersByNameQueried" {
    try std.testing.expectEqual(Provider.openai, providers_by_name.get("openai").?);
    try std.testing.expectEqual(Provider.anthropic, providers_by_name.get("anthropic").?);
    try std.testing.expectEqual(Provider.nvidia_nim, providers_by_name.get("nvidia_nim").?);
    try std.testing.expectEqual(@as(?Provider, null), providers_by_name.get("unknown_provider"));
}

test "builtin_providers parity and metadata completeness" {
    try std.testing.expectEqual(@as(usize, 18), builtin_providers.len);
    for (builtin_providers) |def| {
        try std.testing.expect(def.id.len > 0);
        try std.testing.expect(def.name.len > 0);
        try std.testing.expect(def.description.len > 0);
        // Each builtin must resolve via providers_by_name
        try std.testing.expectEqual(def.provider, providers_by_name.get(def.id).?);
        // Method delegations on Provider enum must match ProviderDef
        try std.testing.expectEqualStrings(def.id, def.provider.label());
        try std.testing.expectEqualStrings(def.name, def.provider.displayName());
        try std.testing.expectEqualStrings(def.description, def.provider.description());
        try std.testing.expectEqual(def.adapter, def.provider.adapter());
        try std.testing.expectEqual(def.requires_api_key, def.provider.requiresApiKey());
        try std.testing.expectEqual(def.catalogue, def.provider.isCatalogue());
    }
}

test "resolvesEffort_whenReasoningSettingResolved" {
    const unset_setting: ReasoningSetting = .unset;
    try std.testing.expectEqual(ai.ReasoningEffort.medium, unset_setting.resolve());

    const explicit_setting: ReasoningSetting = .{ .effort = .high };
    try std.testing.expectEqual(ai.ReasoningEffort.high, explicit_setting.resolve());
}

test "clonesAndDeinitsModel_whenModelLifecycleExecuted" {
    const gpa = std.testing.allocator;

    const reasoning_opts = try gpa.alloc(ai.ReasoningEffort, 2);
    reasoning_opts[0] = .low;
    reasoning_opts[1] = .high;

    var original: Model = .{
        .id = try gpa.dupe(u8, "gpt-4o"),
        .reasoning = .{ .effort = .high },
        .context_window = 128000,
        .max_output_tokens = 4096,
        .reasoning_options = reasoning_opts,
    };

    var cloned = try original.clone(gpa);
    defer cloned.deinit(gpa);
    original.deinit(gpa);

    try std.testing.expectEqualStrings("gpt-4o", cloned.id);
    try std.testing.expectEqual(ai.ReasoningEffort.high, cloned.reasoning.resolve());
    try std.testing.expectEqual(@as(?u32, 128000), cloned.context_window);
    try std.testing.expectEqual(@as(?u32, 4096), cloned.max_output_tokens);
    try std.testing.expectEqual(@as(usize, 2), cloned.reasoning_options.len);
    try std.testing.expectEqual(ai.ReasoningEffort.low, cloned.reasoning_options[0]);
    try std.testing.expectEqual(ai.ReasoningEffort.high, cloned.reasoning_options[1]);
}

test "clonesAndDeinitsProviderConfig_whenProviderConfigLifecycleExecuted" {
    const gpa = std.testing.allocator;

    var models = try gpa.alloc(ProviderModel, 1);
    models[0] = .{
        .id = try gpa.dupe(u8, "claude-3-5-sonnet"),
    };

    var original: ProviderConfig = .{
        .name = try gpa.dupe(u8, "custom-anthropic"),
        .provider = .anthropic,
        .base_url = .{ .custom = try gpa.dupe(u8, "https://api.anthropic.com") },
        .models = models,
    };

    var cloned = try original.clone(gpa);
    defer cloned.deinit(gpa);
    original.deinit(gpa);

    try std.testing.expectEqualStrings("custom-anthropic", cloned.name);
    try std.testing.expectEqual(Provider.anthropic, cloned.provider);
    switch (cloned.base_url) {
        .custom => |url| try std.testing.expectEqualStrings("https://api.anthropic.com", url),
        .default => try std.testing.expect(false),
    }
    try std.testing.expectEqual(@as(usize, 1), cloned.models.len);
    try std.testing.expectEqualStrings("claude-3-5-sonnet", cloned.models[0].id);
}

test "clonesAndAccessesModelSelection_whenBuiltinAndCustomVariantsUsed" {
    const gpa = std.testing.allocator;

    var original_builtin: ModelSelection = .{
        .builtin = .{
            .provider = .openrouter,
            .provider_name = try gpa.dupe(u8, "openrouter"),
            .model = .{
                .id = try gpa.dupe(u8, "anthropic/claude-3.5-sonnet"),
            },
            .use_responses_endpoint = true,
            .system_prompt = try gpa.dupe(u8, "system prompt"),
            .bash_classifier_url = try gpa.dupe(u8, "http://classifier"),
        },
    };

    var cloned_builtin = try original_builtin.clone(gpa);
    defer cloned_builtin.deinit(gpa);
    original_builtin.deinit(gpa);

    try std.testing.expectEqual(Provider.openrouter, cloned_builtin.provider());
    try std.testing.expectEqualStrings("openrouter", cloned_builtin.providerName());
    try std.testing.expectEqualStrings("anthropic/claude-3.5-sonnet", cloned_builtin.model().id);
    try std.testing.expectEqual(@as(?[]const u8, null), cloned_builtin.baseUrl());
    try std.testing.expectEqual(@as(?[]const u8, null), cloned_builtin.apiKey());
    try std.testing.expect(cloned_builtin.useResponsesEndpoint());
    try std.testing.expectEqualStrings("system prompt", cloned_builtin.systemPrompt().?);
    try std.testing.expectEqualStrings("http://classifier", cloned_builtin.bashClassifierUrl().?);

    var original_custom: ModelSelection = .{
        .custom = .{
            .provider_name = try gpa.dupe(u8, "my-llm"),
            .base_url = try gpa.dupe(u8, "https://my-llm.example.com/v1"),
            .api_key = try gpa.dupe(u8, "sk-test1234"),
            .model = .{
                .id = try gpa.dupe(u8, "llama-3"),
            },
        },
    };

    var cloned_custom = try original_custom.clone(gpa);
    defer cloned_custom.deinit(gpa);
    original_custom.deinit(gpa);

    try std.testing.expectEqual(Provider.openai_compatible, cloned_custom.provider());
    try std.testing.expectEqualStrings("my-llm", cloned_custom.providerName());
    try std.testing.expectEqualStrings("https://my-llm.example.com/v1", cloned_custom.baseUrl().?);
    try std.testing.expectEqualStrings("sk-test1234", cloned_custom.apiKey().?);
    try std.testing.expectEqualStrings("llama-3", cloned_custom.model().id);
    try std.testing.expect(!cloned_custom.useResponsesEndpoint());
    try std.testing.expectEqual(@as(?[]const u8, null), cloned_custom.systemPrompt());
    try std.testing.expectEqual(@as(?[]const u8, null), cloned_custom.bashClassifierUrl());
}

test "expandProviderHeaders deep-copies and owns expanded values" {
    const gpa = std.testing.allocator;
    const raw = [_]ProviderHeader{
        .{ .name = @constCast("x-a"), .value = @constCast("plain") },
        .{ .name = @constCast("x-b"), .value = @constCast("no {env: placeholder") },
    };
    const expanded = try expandProviderHeaders(gpa, &raw);
    defer ai.provider_headers.freeHeaders(gpa, expanded);

    try std.testing.expectEqual(@as(usize, 2), expanded.len);
    try std.testing.expectEqualStrings("x-a", expanded[0].name);
    try std.testing.expectEqualStrings("plain", expanded[0].value.literal);
    try std.testing.expectEqualStrings("no {env: placeholder", expanded[1].value.literal);

    const empty = try expandProviderHeaders(gpa, &.{});
    defer ai.provider_headers.freeHeaders(gpa, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}
