const std = @import("std");

const codex = @import("../auth/codex.zig");
const config_mod = @import("../config/config.zig");

pub fn detectCodexSignIn(gpa: std.mem.Allocator, io: std.Io, home_dir: []const u8) bool {
    if (home_dir.len == 0) return false;
    var credentials = (codex.load(gpa, io, home_dir) catch null) orelse return false;
    credentials.deinit(gpa);
    return true;
}

pub fn compatibleProviderFromBaseUrl(base_url: []const u8) config_mod.Provider {
    std.debug.assert(base_url.len > 0);
    if (std.mem.indexOf(u8, base_url, "localhost:11434") != null) return .ollama;
    if (std.mem.indexOf(u8, base_url, "127.0.0.1:11434") != null) return .ollama;
    if (std.mem.indexOf(u8, base_url, "localhost:8080") != null) return .llama_cpp;
    if (std.mem.indexOf(u8, base_url, "127.0.0.1:8080") != null) return .llama_cpp;
    return .openai_compatible;
}

/// Whether enough is known to load a configured OpenAI-compatible catalog.
///
/// Dynamic/custom providers keep their API key in `auth.json` (never
/// serialized to config.json), so `config.api_key` is a runtime-only stash
/// that is null after every restart. Gating purely on it made the disk cache
/// restore (`/models`) skip the dynamic provider on restart. The typed
/// `model_selection` (with a non-empty `base_url`) is the durable signal: when
/// it is present, the real key is resolved from `auth.json` at fetch time by
/// `collectConfiguredProviders` block 2. The legacy `base_url`+`api_key` stash
/// path stays as a fallback for catalogue providers that have no
/// `model_selection` yet.
pub fn hasOpenAICompatibleCredentials(config: config_mod.Config) bool {
    // Typed selection is the durable, serialized path — true when it carries a
    // non-empty base_url.
    if (config.model_selection) |ms| {
        if (ms.baseUrl()) |url| {
            if (url.len > 0) return true;
        }
    }
    // Legacy runtime stash (key never persists across restart).
    const base_url = config.base_url orelse return false;
    const api_key = config.api_key orelse return false;
    if (base_url.len == 0) return false;
    if (api_key.len == 0) return false;
    return true;
}

test "compatible provider is inferred from base url" {
    try std.testing.expectEqual(config_mod.Provider.ollama, compatibleProviderFromBaseUrl("http://localhost:11434/v1"));
    try std.testing.expectEqual(config_mod.Provider.ollama, compatibleProviderFromBaseUrl("http://127.0.0.1:11434/v1"));
    try std.testing.expectEqual(config_mod.Provider.llama_cpp, compatibleProviderFromBaseUrl("http://localhost:8080/v1"));
    try std.testing.expectEqual(config_mod.Provider.openai_compatible, compatibleProviderFromBaseUrl("https://example.com/v1"));
}

test "hasOpenAICompatibleCredentials: false with nothing set" {
    var config: config_mod.Config = .{};
    defer config.deinit(std.testing.allocator);
    try std.testing.expect(!hasOpenAICompatibleCredentials(config));
}

test "hasOpenAICompatibleCredentials: typed selection with base_url satisfies gate even when api_key is null" {
    // Restart scenario: api_key is never serialized, so after a fresh load it
    // is null. The dynamic provider's real key lives in auth.json. A typed
    // model_selection carrying a non-empty base_url is the durable signal.
    var config: config_mod.Config = .{};
    defer config.deinit(std.testing.allocator);
    config.model_selection = .{
        .custom = .{
            .provider_name = try std.testing.allocator.dupe(u8, "stepfun-ai"),
            .base_url = try std.testing.allocator.dupe(u8, "https://api.stepfun.com/v1"),
            // api_key empty by design (serialize skips it; resolved from auth.json).
            .api_key = try std.testing.allocator.dupe(u8, ""),
            .model = .{ .id = try std.testing.allocator.dupe(u8, "step-2-16k") },
        },
    };
    try std.testing.expect(hasOpenAICompatibleCredentials(config));
}

test "hasOpenAICompatibleCredentials: typed selection with empty base_url still requires the legacy stash" {
    var config: config_mod.Config = .{};
    defer config.deinit(std.testing.allocator);
    config.model_selection = .{ .custom = .{
        .provider_name = try std.testing.allocator.dupe(u8, "stepfun-ai"),
        .base_url = try std.testing.allocator.dupe(u8, ""),
        .api_key = try std.testing.allocator.dupe(u8, ""),
        .model = .{ .id = try std.testing.allocator.dupe(u8, "step-2-16k") },
    } };
    // No base_url in selection and no legacy stash → false.
    try std.testing.expect(!hasOpenAICompatibleCredentials(config));
}
