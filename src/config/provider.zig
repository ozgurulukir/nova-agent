//! Provider catalogue, model types, and selection primitives.
//!
//! Pure data types with no dependency on the Config struct or the
//! parse/serialize pipeline. Imported by `config.zig` (which re-exports
//! everything) and directly by modules that only need the type surface.

const std = @import("std");
const ai = @import("../ai.zig");

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
    anthropic,

    pub fn label(self: Provider) []const u8 {
        return providerSpec(self).label;
    }

    pub fn displayName(self: Provider) []const u8 {
        return providerSpec(self).display_name;
    }

    /// Default base_url for this Provider. `null` means the user MUST
    /// supply one (e.g. raw `openai_compatible` and `anthropic`).
    pub fn defaultBaseUrl(self: Provider) ?[]const u8 {
        return providerSpec(self).base_url_default;
    }

    pub fn adapter(self: Provider) ?AdapterKind {
        return providerSpec(self).adapter_kind;
    }

    pub fn isCatalogue(self: Provider) bool {
        return providerSpec(self).catalogue;
    }

    pub fn requiresApiKey(self: Provider) bool {
        return providerSpec(self).requires_api_key;
    }

    pub fn anonymousApiKey(self: Provider) ?[]const u8 {
        return switch (self) {
            .opencode_zen => "public",
            else => null,
        };
    }

    pub fn description(self: Provider) []const u8 {
        return switch (self) {
            .openai => "OpenAI ChatGPT & Codex authentication",
            .openai_compatible => "Custom OpenAI-compatible REST server",
            .ollama => "Local Ollama server instance (localhost:11434)",
            .llama_cpp => "Local llama.cpp HTTP server (localhost:8080)",
            .openrouter => "Unified router for 200+ AI models",
            .cerebras => "Ultra-fast Cerebras WSE-3 wafer inference",
            .ollama_cloud => "Hosted Ollama cloud model infrastructure",
            .huggingface => "HuggingFace Serverless Inference API",
            .nvidia_nim => "NVIDIA NIM microservices & GPU platform",
            .opencode_zen => "Free public OpenCode Zen endpoint",
            .anthropic => "Direct Anthropic API (Claude 3.5 Sonnet)",
        };
    }
};

pub fn catalogueProviders() []const Provider {
    const list = comptime blk: {
        var buf: [provider_specs.len]Provider = undefined;
        var n: usize = 0;
        for (provider_specs) |spec| {
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

const ProviderSpec = struct {
    provider: Provider,
    label: []const u8,
    display_name: []const u8,
    base_url_default: ?[]const u8,
    adapter_kind: ?AdapterKind,
    catalogue: bool = false,
    requires_api_key: bool = true,
};

const provider_specs = [_]ProviderSpec{
    .{ .provider = .openai, .label = "openai", .display_name = "OpenAI Codex", .base_url_default = "https://chatgpt.com/backend-api", .adapter_kind = .codex_responses },
    .{ .provider = .openai_compatible, .label = "openai_compatible", .display_name = "OpenAI Compatible", .base_url_default = null, .adapter_kind = .openai_compatible },
    .{ .provider = .ollama, .label = "ollama", .display_name = "Ollama", .base_url_default = "http://localhost:11434", .adapter_kind = .openai_compatible },
    .{ .provider = .llama_cpp, .label = "llama.cpp", .display_name = "llama.cpp", .base_url_default = "http://localhost:8080", .adapter_kind = .openai_compatible },
    .{ .provider = .openrouter, .label = "openrouter", .display_name = "OpenRouter", .base_url_default = "https://openrouter.ai/api", .adapter_kind = .openai_compatible, .catalogue = true },
    .{ .provider = .cerebras, .label = "cerebras", .display_name = "Cerebras", .base_url_default = "https://api.cerebras.ai/v1", .adapter_kind = .openai_compatible, .catalogue = true },
    .{ .provider = .ollama_cloud, .label = "ollama_cloud", .display_name = "Ollama Cloud", .base_url_default = "https://ollama.com/v1", .adapter_kind = .openai_compatible, .catalogue = true },
    .{ .provider = .huggingface, .label = "huggingface", .display_name = "HuggingFace", .base_url_default = "https://router.huggingface.co/v1", .adapter_kind = .openai_compatible, .catalogue = true },
    .{ .provider = .nvidia_nim, .label = "nvidia_nim", .display_name = "Nvidia Nim", .base_url_default = "https://integrate.api.nvidia.com/v1", .adapter_kind = .openai_compatible, .catalogue = true },
    .{ .provider = .opencode_zen, .label = "opencode_zen", .display_name = "OpenCode Zen", .base_url_default = "https://opencode.ai/zen/v1", .adapter_kind = .openai_compatible, .catalogue = true, .requires_api_key = false },
    .{ .provider = .anthropic, .label = "anthropic", .display_name = "Anthropic", .base_url_default = null, .adapter_kind = null },
};

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
    .{ "anthropic", .anthropic },
});

/// All builtin provider labels, for auth.json integrity checks.
/// Builtin keys are never pruned — they're always valid.
pub fn allBuiltinLabels() []const []const u8 {
    return &.{ "openai", "openai_compatible", "ollama", "llama.cpp", "openrouter", "cerebras", "ollama_cloud", "huggingface", "nvidia_nim", "opencode_zen", "anthropic" };
}

fn providerSpec(provider: Provider) ProviderSpec {
    const index: usize = @intFromEnum(provider);
    comptime std.debug.assert(provider_specs.len == @typeInfo(Provider).@"enum".fields.len);
    std.debug.assert(provider_specs[index].provider == provider);
    return provider_specs[index];
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

pub const ProviderConfig = struct {
    /// The JSON map key. For builtins this equals `provider.label()`;
    /// for custom providers it's the user-chosen name (e.g. "qwen-cloud").
    name: []u8,
    provider: Provider,
    base_url: BaseUrl = .default,
    models: []ProviderModel = &.{},

    pub fn deinit(self: *ProviderConfig, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        switch (self.base_url) {
            .custom => |s| gpa.free(s),
            .default => {},
        }
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

test "returnsExpectedProperties_whenProviderMethodsCalled" {
    // All providers return non-empty label, displayName, and description
    inline for (@typeInfo(Provider).@"enum".fields) |field| {
        const p: Provider = @enumFromInt(field.value);
        try std.testing.expect(p.label().len > 0);
        try std.testing.expect(p.displayName().len > 0);
        try std.testing.expect(p.description().len > 0);
    }

    // Specific provider property checks
    try std.testing.expectEqualStrings("openai", Provider.openai.label());
    try std.testing.expectEqualStrings("OpenAI Codex", Provider.openai.displayName());
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api", Provider.openai.defaultBaseUrl().?);
    try std.testing.expectEqual(AdapterKind.codex_responses, Provider.openai.adapter().?);
    try std.testing.expect(!Provider.openai.isCatalogue());
    try std.testing.expect(Provider.openai.requiresApiKey());
    try std.testing.expectEqual(@as(?[]const u8, null), Provider.openai.anonymousApiKey());

    // OpenCode Zen (anonymous API key and custom requirements)
    try std.testing.expectEqualStrings("public", Provider.opencode_zen.anonymousApiKey().?);
    try std.testing.expect(!Provider.opencode_zen.requiresApiKey());
    try std.testing.expect(Provider.opencode_zen.isCatalogue());

    // Anthropic (null defaultBaseUrl and null adapter)
    try std.testing.expectEqual(@as(?[]const u8, null), Provider.anthropic.defaultBaseUrl());
    try std.testing.expectEqual(@as(?AdapterKind, null), Provider.anthropic.adapter());
}

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

test "returnsCorrectAccessors_whenModelSelectionRefQueried" {
    const gpa = std.testing.allocator;

    var dummy_model: Model = .{
        .id = try gpa.dupe(u8, "ollama-model"),
    };
    defer dummy_model.deinit(gpa);

    const builtin_ref: ModelSelectionRef = .{
        .builtin = .{
            .provider = .ollama,
            .provider_name = "ollama",
            .model = &dummy_model,
        },
    };

    try std.testing.expectEqual(Provider.ollama, builtin_ref.provider());
    try std.testing.expectEqualStrings("ollama", builtin_ref.providerName());
    try std.testing.expectEqualStrings("ollama-model", builtin_ref.model().id);
    try std.testing.expectEqual(@as(?[]const u8, null), builtin_ref.baseUrl());
    try std.testing.expectEqual(@as(?[]const u8, null), builtin_ref.apiKey());

    const custom_ref: ModelSelectionRef = .{
        .custom = .{
            .provider_name = "my-custom-provider",
            .base_url = "http://localhost:8000",
            .api_key = "secret",
            .model = &dummy_model,
        },
    };

    try std.testing.expectEqual(Provider.openai_compatible, custom_ref.provider());
    try std.testing.expectEqualStrings("my-custom-provider", custom_ref.providerName());
    try std.testing.expectEqualStrings("http://localhost:8000", custom_ref.baseUrl().?);
    try std.testing.expectEqualStrings("secret", custom_ref.apiKey().?);
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
