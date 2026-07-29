const std = @import("std");

const agent_mod = @import("agent.zig");
const ai = @import("ai.zig");
const auth_mod = @import("auth/store.zig");
const codex_mod = @import("auth/codex.zig");
const compaction = @import("context/compaction.zig");
const config_mod = @import("config/config.zig");
const context_assembly = @import("context/assembly.zig");
const os = @import("os.zig");
const plugin_prompt = @import("plugin_prompt.zig");
const session_mod = @import("session.zig");
const skill_mod = @import("skill.zig");
const tools_mod = @import("tools.zig");

const assert = std.debug.assert;

const codex_refresh_margin_ms: i64 = 5 * std.time.ms_per_min;

pub const codex_connection_expired_message = "Codex connection expired. Run /connect to reconnect.";

pub const AgentRuntime = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    home_dir: []const u8,
    client: ai.LanguageModel,
    base_system_prompt: []const u8,
    system_prompt: []const u8,
    skills: []skill_mod.Skill,
    /// Per-plugin `prompt.md` bodies, injected into the system prompt at
    /// assembly time so the model learns how to use each plugin's tools.
    /// Cloned from the primary lane for sub-lanes (same project, same plugins).
    plugin_prompts: []plugin_prompt.PluginPrompt,
    session_writer: session_mod.SessionWriter,
    agent: agent_mod.Agent,
    diagnostics: []config_mod.Diagnostic,
    codex_connection_expired: bool = false,
    owned_client: ?OwnedClient = null,
    /// Second client, same config as `owned_client`, used only by the agent's
    /// background summarizer so the two never share a connection.
    owned_compaction_client: ?OwnedClient = null,
    /// Third client, same config as `owned_client` (no tools), used only by
    /// the TUI's background branch-naming request so it never shares a
    /// connection with the live turn or the summarizer. The App cancels any
    /// in-flight naming job before this runtime is torn down or reconnected.
    owned_naming_client: ?OwnedClient = null,
    naming_client: ai.LanguageModel = .none,
    /// MCP tool schemas to inject into the AI config at connection time.
    /// Set by the App before calling connectXxxClient.
    mcp_tools: []const ai.McpToolSchema = &.{},
    /// Whether to send OpenAI strict structured-outputs mode in tool
    /// definitions. Forwarded to every attached client's `ai.Config`.
    /// Default `false` — strict is OpenAI-only and breaks function-calling
    /// on gateways. Set from `config.strict_outputs` at session init.
    strict_outputs: bool = false,
    /// Context window and compaction settings from config. Stored so
    /// the attach/connect functions can pass the override to
    /// `compaction.contextWindowTokens` and the agent can use the
    /// compaction policy.
    context_settings: config_mod.ContextSettings = .{},
    /// True once `initSession` has brought up `session_writer` (background
    /// thread + sqlite handle). Some TUI test harnesses construct a partial
    /// runtime with `session_writer = undefined`; gates session-DB writes so
    /// those harnesses can still exercise the picker without touching sqlite.
    session_writer_started: bool = false,

    pub const ClientState = union(enum) {
        disconnected,
        connected: ai.LanguageModel,
    };

    const OwnedClient = union(enum) {
        codex_responses: *ai.codex_responses.Client,
        openai_compatible: *ai.openai_compatible.Client,
        openai_responses: *ai.openai_responses.Client,

        fn deinit(self: OwnedClient, gpa: std.mem.Allocator) void {
            switch (self) {
                .codex_responses => |client| {
                    client.deinit();
                    gpa.destroy(client);
                },
                .openai_compatible => |client| {
                    client.deinit();
                    gpa.destroy(client);
                },
                .openai_responses => |client| {
                    client.deinit();
                    gpa.destroy(client);
                },
            }
        }

        fn languageModel(self: OwnedClient) ai.LanguageModel {
            return switch (self) {
                .codex_responses => |client| .{ .codex_responses = client },
                .openai_compatible => |client| .{ .openai_compatible = client },
                .openai_responses => |client| .{ .openai_responses = client },
            };
        }

        /// Rebuild the client's serialized tool list from the registry
        /// (builtin + plugin tools) and the MCP schemas. Every concrete
        /// client exposes `updateMcpTools` with the same signature; this
        /// helper dispatches through the union so `replaceClient` can push
        /// the current tool set into the freshly-attached client without
        /// the attach functions each repeating the call.
        ///
        /// Without this, a newly-attached client keeps the `tools_json`
        /// it built at `init` time (builtin only) and never learns about
        /// `lua__<plugin>__<tool>` entries — so the model can't see plugin
        /// tools and tries to invoke them as shell commands
        /// (`bash: lua__write-tool__edit: command not found`).
        fn updateMcpTools(
            self: OwnedClient,
            mcp_tools: []const ai.McpToolSchema,
            registry: ?*tools_mod.ToolRegistry,
            builtin_override: []const tools_mod.Tool,
        ) !void {
            switch (self) {
                .codex_responses => |client| try client.updateMcpTools(mcp_tools, registry, builtin_override),
                .openai_compatible => |client| try client.updateMcpTools(mcp_tools, registry, builtin_override),
                .openai_responses => |client| try client.updateMcpTools(mcp_tools, registry, builtin_override),
            }
        }
    };

    pub fn initNew(
        target: *AgentRuntime,
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        session_dir: []const u8,
        home_dir: []const u8,
        base_system_prompt: []const u8,
        config: config_mod.Config,
        diagnostics: []config_mod.Diagnostic,
        template: ?*const AgentRuntime,
    ) !void {
        try target.initSession(gpa, io, cwd, session_dir, home_dir, base_system_prompt, config, diagnostics, null, template);
    }

    pub fn initResume(
        target: *AgentRuntime,
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        session_dir: []const u8,
        home_dir: []const u8,
        base_system_prompt: []const u8,
        config: config_mod.Config,
        diagnostics: []config_mod.Diagnostic,
        session_id: []const u8,
        template: ?*const AgentRuntime,
    ) !void {
        assert(session_id.len > 0);
        try target.initSession(gpa, io, cwd, session_dir, home_dir, base_system_prompt, config, diagnostics, session_id, template);
    }

    /// `cwd` is where the agent runs tools and loads skills (a lane's workspace);
    /// `session_dir` is where the session DB lives and what the session records
    /// as its cwd — the repo root, so all lanes share one DB and group together.
    fn initSession(
        target: *AgentRuntime,
        gpa: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        session_dir: []const u8,
        home_dir: []const u8,
        base_system_prompt: []const u8,
        config: config_mod.Config,
        diagnostics: []config_mod.Diagnostic,
        session_id: ?[]const u8,
        template: ?*const AgentRuntime,
    ) !void {
        assert(cwd.len > 0);
        assert(base_system_prompt.len > 0);
        if (session_id) |id| assert(id.len > 0);

        const owned_base_system_prompt = try gpa.dupe(u8, base_system_prompt);
        errdefer gpa.free(owned_base_system_prompt);
        // A `template` (the primary lane) shares the same project, so clone its
        // already-loaded skills + plugin prompts + assembled system prompt
        // instead of re-scanning the workspace (which is a checkout of the same repo).
        const skills = if (template) |t| try skill_mod.cloneAll(gpa, t.skills) else try skill_mod.loadProject(gpa, io, cwd);
        errdefer skill_mod.deinitAll(gpa, skills);
        const plugin_prompts = if (template) |t| try plugin_prompt.cloneAll(gpa, t.plugin_prompts) else try plugin_prompt.loadAll(gpa, io, home_dir, cwd);
        errdefer plugin_prompt.deinitAll(gpa, plugin_prompts);
        const owned_system_prompt = if (template) |t| try gpa.dupe(u8, t.system_prompt) else try context_assembly.assembleSystemPrompt(gpa, io, owned_base_system_prompt, cwd, skills, plugin_prompts);
        errdefer gpa.free(owned_system_prompt);

        target.* = .{
            .gpa = gpa,
            .io = io,
            .cwd = cwd,
            .home_dir = home_dir,
            .client = .none,
            .base_system_prompt = owned_base_system_prompt,
            .system_prompt = owned_system_prompt,
            .skills = skills,
            .plugin_prompts = plugin_prompts,
            .session_writer = undefined,
            .agent = undefined,
            .diagnostics = diagnostics,
            .codex_connection_expired = false,
            .strict_outputs = config.strict_outputs orelse false,
            .context_settings = config.context,
        };

        if (session_id) |id| {
            try target.session_writer.initResumeDefault(gpa, io, home_dir, id);
        } else {
            try target.session_writer.initDefault(gpa, io, home_dir, session_dir);
        }
        target.session_writer_started = true;
        errdefer target.session_writer.deinit();

        target.agent = agent_mod.Agent.init(gpa, io, cwd, .none);
        errdefer target.agent.deinit();
        target.agent.skills = target.skills;
        target.agent.compaction_settings = config.context.compaction;
        if (config.model_selection) |ms| {
            if (ms.bashClassifierUrl()) |url| {
                target.agent.bash_classifier_url = try gpa.dupe(u8, url);
            }
        }
        target.agent.attachSessionWriter(&target.session_writer);
        try target.agent.addSystem(owned_system_prompt);

        if (session_id != null) {
            const messages = try target.session_writer.session.messages(gpa);
            defer gpa.free(messages);
            for (messages) |message| try target.agent.takeMessage(message);
        }

        // When resuming a session, try to restore the model used in that session
        if (session_id) |id| {
            _ = id;
            var summary = try target.session_writer.session.summary(gpa);
            defer summary.deinit(gpa);
            if (summary.model_provider) |mp| {
                // Resolve the provider: try builtin enum first, then the
                // providers[] config map (custom providers like "qwen-cloud").
                const provider_enum = std.meta.stringToEnum(config_mod.Provider, mp) orelse blk: {
                    for (config.providers) |pc| {
                        if (std.mem.eql(u8, pc.name, mp)) break :blk pc.provider;
                    }
                    std.log.warn("session.resume.unknown_provider: {s}, using config default", .{mp});
                    try target.applyFromConfig(config);
                    return;
                };

                // Resolve base_url from the providers[] map when the provider
                // is custom (defaultBaseUrl() is null for .openai_compatible).
                var resolved_base_url: []const u8 = provider_enum.defaultBaseUrl() orelse "";
                for (config.providers) |pc| {
                    if (!std.mem.eql(u8, pc.name, mp)) continue;
                    switch (pc.base_url) {
                        .custom => |url| resolved_base_url = url,
                        .default => {},
                    }
                    break;
                }

                var session_config = config;
                if (session_config.model_selection) |*ms| {
                    switch (ms.*) {
                        .builtin => |*b| {
                            b.provider = provider_enum;
                            b.provider_name = @constCast(mp);
                            if (summary.model_id) |mid| {
                                // mid is borrowed from summary — dupe into owned memory.
                                b.model.id = try gpa.dupe(u8, mid);
                            }
                        },
                        .custom => |*c| {
                            c.provider_name = @constCast(mp);
                            if (summary.model_id) |mid| {
                                // mid is borrowed from summary — dupe into owned memory.
                                c.model.id = try gpa.dupe(u8, mid);
                            }
                            if (c.base_url.len == 0 and resolved_base_url.len > 0) {
                                c.base_url = @constCast(resolved_base_url);
                            }
                        },
                    }
                    try target.applyFromConfig(session_config);
                    // Free the dupe'd model_id — applyFromConfig dupe'd it again
                    // into the client, so the session_config copy is no longer needed.
                    if (summary.model_id) |_| {
                        const mid_to_free = switch (ms.*) {
                            .builtin => |b| b.model.id,
                            .custom => |c| c.model.id,
                        };
                        gpa.free(mid_to_free);
                    }
                } else {
                    const is_builtin = std.meta.stringToEnum(config_mod.Provider, mp) != null;
                    if (summary.model_id) |mid| {
                        // mid is borrowed from summary's internal allocation.
                        // Dupe it into owned memory so it survives summary.deinit.
                        const owned_mid = try gpa.dupe(u8, mid);
                        errdefer gpa.free(owned_mid);
                        if (is_builtin) {
                            session_config.model_selection = .{
                                .builtin = .{
                                    .provider = provider_enum,
                                    .provider_name = @constCast(mp),
                                    .model = .{
                                        .id = owned_mid,
                                        .reasoning = .unset,
                                    },
                                    .use_responses_endpoint = false,
                                    .bash_classifier_url = null,
                                },
                            };
                        } else {
                            session_config.model_selection = .{
                                .custom = .{
                                    .provider_name = @constCast(mp),
                                    .base_url = @constCast(resolved_base_url),
                                    .api_key = "",
                                    .model = .{
                                        .id = owned_mid,
                                        .reasoning = .unset,
                                    },
                                    .use_responses_endpoint = false,
                                    .bash_classifier_url = null,
                                },
                            };
                        }
                        try target.applyFromConfig(session_config);
                        // Free the dupe'd model_id — applyFromConfig dupe'd it
                        // again into the client.
                        gpa.free(owned_mid);
                    } else {
                        // No model_id saved in session — fall back to config's
                        // default model rather than synthesizing an empty one.
                        try target.applyFromConfig(config);
                    }
                }
            } else {
                // No model saved in session, use config as-is
                try target.applyFromConfig(config);
            }
        } else {
            // New session - will save model info after applyFromConfig
            try target.applyFromConfig(config);
        }
    }

    /// Rehydrate the agent's conversation from the session's current leaf.
    /// Call after `session_writer.navigate(...)` switches branches: clears the
    /// in-memory messages (keeping the system prompt) and reloads the new
    /// active path. Must not be called mid-turn.
    pub fn reloadMessages(self: *AgentRuntime) !void {
        self.agent.clearNonSystemMessages();
        const messages = try self.session_writer.messages(self.gpa);
        defer self.gpa.free(messages);
        for (messages) |message| try self.agent.takeMessage(message);
        // The conversation is now a different branch; the usage anchor no
        // longer refers to these messages.
        self.agent.resetContextUsage();
    }

    pub fn clientState(self: *const AgentRuntime) ClientState {
        if (self.client == .none) return .disconnected;
        return .{ .connected = self.client };
    }

    pub fn assertClientInvariant(self: *const AgentRuntime) void {
        if (self.owned_client) |owned| {
            assert(self.client != .none);
            assert(self.agent.client != .none);
            assert(languageModelMatchesOwned(self.client, owned));
            assert(languageModelMatches(self.agent.client, self.client));
        } else {
            assert(self.client == .none);
            assert(self.agent.client == .none);
        }
    }

    pub fn deinit(self: *AgentRuntime) void {
        self.assertClientInvariant();
        self.agent.deinit();
        self.session_writer.deinit();
        self.gpa.free(self.base_system_prompt);
        self.gpa.free(self.system_prompt);
        skill_mod.deinitAll(self.gpa, self.skills);
        plugin_prompt.deinitAll(self.gpa, self.plugin_prompts);
        // `agent.deinit` above joined the summarizer thread, so its client is
        // no longer in use and is safe to free. The naming client's borrower
        // (the App's branch-naming job) is cancelled before runtime teardown.
        if (self.owned_naming_client) |client| client.deinit(self.gpa);
        if (self.owned_compaction_client) |client| client.deinit(self.gpa);
        if (self.owned_client) |client| client.deinit(self.gpa);
        for (self.diagnostics) |*d| d.deinit(self.gpa);
        self.gpa.free(self.diagnostics);
        self.* = undefined;
    }

    /// Pick and wire the LanguageModel adapter specified in `config`.
    /// Also handles providers that require sign-in (codex).
    pub fn applyFromConfig(self: *AgentRuntime, config: config_mod.Config) !void {
        const selection = config.activeModelSelection() orelse return;
        const model_id = selection.model().id;
        if (model_id.len == 0) {
            std.log.warn("runtime.applyFromConfig: empty model_id for provider {s}, skipping model attachment", .{selection.providerName()});
            return;
        }
        const adapter = adapterForConfig(selection.provider(), config) orelse return;
        switch (adapter) {
            .codex_responses => try self.tryConnectCodexFromAuth(config),
            .openai_compatible => try self.tryAttachOpenAiCompatibleFromConfig(selection.provider(), config),
            .openai_responses => try self.tryAttachOpenAiResponsesFromConfig(selection.provider(), config),
        }
        // Save the model selection to the session so it can be restored on resume.
        // Use provider_name (the config key) so custom providers round-trip.
        try self.session_writer.session.updateModel(selection.providerName(), model_id);
    }

    fn adapterForConfig(provider: config_mod.Provider, config: config_mod.Config) ?config_mod.AdapterKind {
        const adapter = provider.adapter() orelse return null;
        if (adapter == .openai_compatible) {
            if (config.model_selection) |ms| {
                if (ms.useResponsesEndpoint()) return .openai_responses;
            }
        }
        return adapter;
    }

    fn tryConnectCodexFromAuth(self: *AgentRuntime, config: config_mod.Config) !void {
        if (self.home_dir.len == 0) return;
        var creds = (codex_mod.load(self.gpa, self.io, self.home_dir) catch null) orelse return;
        defer creds.deinit(self.gpa);
        try self.refreshCodexCredentialsIfNeeded(&creds);
        if (self.codex_connection_expired) return;
        const ms = config.model_selection orelse return;
        const model_id = ms.model().id;
        const effort = ms.model().reasoning.resolve();
        try self.connectCodexClient(creds, model_id, effort);
    }

    fn refreshCodexCredentialsIfNeeded(self: *AgentRuntime, creds: *codex_mod.Credentials) !void {
        const now_ms = std.Io.Clock.now(.real, self.io).toMilliseconds();
        if (!codexRefreshNeeded(creds.expires, now_ms)) {
            self.codex_connection_expired = false;
            return;
        }
        const refresh_token = try self.gpa.dupe(u8, creds.refresh);
        defer self.gpa.free(refresh_token);
        var refreshed = codex_mod.refresh(self.gpa, self.io, self.home_dir, refresh_token) catch |err| {
            std.log.warn("codex.refresh.failed err={s}", .{@errorName(err)});
            self.codex_connection_expired = true;
            return;
        };
        creds.deinit(self.gpa);
        creds.* = refreshed;
        refreshed = undefined;
        self.codex_connection_expired = false;
    }

    fn tryAttachOpenAiCompatibleFromConfig(
        self: *AgentRuntime,
        provider: config_mod.Provider,
        config: config_mod.Config,
    ) !void {
        const ms = config.model_selection orelse {
            // No typed selection — fall back to legacy fields. For builtin
            // providers defaultBaseUrl() suffices; for .openai_compatible
            // the base_url was hydrated from the providers[] map by
            // hydrateActiveModel during config merge.
            const base_url = config.base_url orelse provider.defaultBaseUrl() orelse return;
            const model_id = if (config.model) |m| m.id else "default";
            const effort = if (config.model) |m| m.reasoning.resolve() else ai.ReasoningEffort.medium;
            var loaded_key: ?[]u8 = null;
            defer if (loaded_key) |k| self.gpa.free(k);
            const api_key = blk: {
                const name = config.provider_name orelse provider.label();
                if (self.home_dir.len > 0) {
                    loaded_key = auth_mod.loadProviderApiKey(self.gpa, self.io, self.home_dir, name) catch null;
                    if (loaded_key) |k| break :blk k;
                }
                break :blk provider.anonymousApiKey() orelse "";
            };
            try self.attachOpenAiCompatibleClient(base_url, api_key, model_id, effort);
            return;
        };
        const base_url = blk: {
            if (ms.baseUrl()) |url| {
                if (url.len > 0) break :blk url;
            }
            break :blk provider.defaultBaseUrl() orelse return;
        };
        const effort = ms.model().reasoning.resolve();
        // Per-model context_window from providers map acts as a fallback
        // when the global overrideContextWindow is not set.
        if (self.context_settings.override_context_window == null) {
            self.context_settings.override_context_window = ms.model().context_window;
        }
        // Per-model max_output_tokens from providers map acts as a fallback
        // when the global context.maxOutputTokens is not set.
        if (self.context_settings.max_output_tokens == null) {
            self.context_settings.max_output_tokens = ms.model().max_output_tokens;
        }
        var loaded_key: ?[]u8 = null;
        defer if (loaded_key) |k| self.gpa.free(k);
        const api_key = blk: {
            if (ms.apiKey()) |key| {
                if (key.len > 0) break :blk key;
            }
            // Auth lookup uses provider_name (the config map key / defaultModel
            // prefix) so custom providers like "qwen-cloud" resolve their own
            // stored key from auth.json.
            if (self.home_dir.len > 0) {
                loaded_key = auth_mod.loadProviderApiKey(self.gpa, self.io, self.home_dir, ms.providerName()) catch null;
                if (loaded_key) |k| break :blk k;
            }
            // No stored key — log for diagnostics when the provider requires
            // one, so a 402/401 on the first turn is traceable.
            if (provider.requiresApiKey()) {
                std.log.warn("auth.missing_key provider={s} — requests will likely fail with 402", .{ms.providerName()});
            }
            break :blk provider.anonymousApiKey() orelse "";
        };
        const model_id_to_attach = switch (ms) {
            .builtin => |b| b.model.id,
            .custom => |c| c.model.id,
        };
        try self.attachOpenAiCompatibleClient(base_url, api_key, model_id_to_attach, effort);
    }

    fn tryAttachOpenAiResponsesFromConfig(
        self: *AgentRuntime,
        provider: config_mod.Provider,
        config: config_mod.Config,
    ) !void {
        const ms = config.model_selection orelse return;
        const base_url = if (ms.baseUrl()) |url| if (url.len > 0) url else provider.defaultBaseUrl() orelse return else provider.defaultBaseUrl() orelse return;
        const reasoning: ai.Reasoning = .{
            .effort = ms.model().reasoning.resolve(),
            .summary = .auto,
        };
        try self.attachOpenAiResponsesClient(base_url, ms.apiKey() orelse "", ms.model().id, reasoning);
    }

    /// Establish a Codex session — uses OAuth credentials to identify
    /// against `/backend-api/codex/responses`. Replaces any previously
    /// connected codex client.
    pub fn connectCodexClient(
        self: *AgentRuntime,
        credentials: codex_mod.Credentials,
        model_id: []const u8,
        effort: ai.ReasoningEffort,
    ) !void {
        const client = try self.gpa.create(ai.codex_responses.Client);
        errdefer self.gpa.destroy(client);
        try client.init(self.gpa, self.io, .{
            .base_url = "https://chatgpt.com/backend-api",
            .api_key = credentials.access,
            .model = model_id,
            .tools = tools_mod.builtinRegistry(),
            .mcp_tools = self.mcp_tools,
            .reasoning = .{ .effort = effort, .summary = .auto },
            .strict = self.strict_outputs,
            .account_id = credentials.account_id,
            .session_id = self.session_writer.session.id.slice(),
            .system_prompt = self.system_prompt,
        });
        errdefer client.deinit();
        self.replaceClient(.{ .codex_responses = client });
        self.agent.context_window_tokens = compaction.contextWindowTokens(model_id, self.context_settings.override_context_window);
        self.agent.resetContextUsage();

        attach_compaction: {
            const compaction_client = self.gpa.create(ai.codex_responses.Client) catch break :attach_compaction;
            compaction_client.init(self.gpa, self.io, .{
                .base_url = "https://chatgpt.com/backend-api",
                .api_key = credentials.access,
                .model = model_id,
                .tools = &.{},
                .reasoning = .{ .effort = effort, .summary = .auto },
                .account_id = credentials.account_id,
                .session_id = self.session_writer.session.id.slice(),
                .system_prompt = self.system_prompt,
            }) catch {
                self.gpa.destroy(compaction_client);
                break :attach_compaction;
            };
            self.setCompactionClient(.{ .codex_responses = compaction_client });
        }
        attach_naming: {
            const naming_client = self.gpa.create(ai.codex_responses.Client) catch break :attach_naming;
            naming_client.init(self.gpa, self.io, .{
                .base_url = "https://chatgpt.com/backend-api",
                .api_key = credentials.access,
                .model = model_id,
                .tools = &.{},
                .reasoning = .{ .effort = effort, .summary = .auto },
                .account_id = credentials.account_id,
                .session_id = self.session_writer.session.id.slice(),
                .system_prompt = self.system_prompt,
            }) catch {
                self.gpa.destroy(naming_client);
                break :attach_naming;
            };
            self.setNamingClient(.{ .codex_responses = naming_client });
        }
        self.codex_connection_expired = false;
    }

    pub fn disconnectCodexClient(self: *AgentRuntime) void {
        const owned_client = self.owned_client orelse return;
        if (owned_client != .codex_responses) return;
        self.clearCompactionClient();
        self.clearNamingClient();
        owned_client.deinit(self.gpa);
        self.owned_client = null;
        self.client = .none;
        self.agent.client = .none;
        self.assertClientInvariant();
    }

    pub fn hasCodexClient(self: *const AgentRuntime) bool {
        const owned_client = self.owned_client orelse return false;
        return owned_client == .codex_responses;
    }

    pub fn disconnectClient(self: *AgentRuntime) void {
        const owned_client = self.owned_client orelse return;
        self.clearCompactionClient();
        self.clearNamingClient();
        owned_client.deinit(self.gpa);
        self.owned_client = null;
        self.client = .none;
        self.agent.client = .none;
        self.assertClientInvariant();
    }

    pub fn attachOpenAiCompatibleClient(
        self: *AgentRuntime,
        base_url: []const u8,
        api_key: []const u8,
        model_id: []const u8,
        effort: ai.ReasoningEffort,
    ) !void {
        const client = try self.gpa.create(ai.openai_compatible.Client);
        errdefer self.gpa.destroy(client);
        try client.init(self.gpa, self.io, .{
            .base_url = base_url,
            .api_key = api_key,
            .model = model_id,
            .tools = tools_mod.builtinRegistry(),
            .mcp_tools = self.mcp_tools,
            .reasoning = .{ .effort = effort },
            .strict = self.strict_outputs,
            .max_output_tokens = self.context_settings.max_output_tokens,
            .max_parallel_tool_calls = self.context_settings.max_parallel_tool_calls orelse 16,
            .request_timeout_seconds = self.context_settings.request_timeout_seconds orelse 300,
            .session_id = self.session_writer.session.id.slice(),
        });
        errdefer client.deinit();
        self.replaceClient(.{ .openai_compatible = client });
        self.agent.context_window_tokens = compaction.contextWindowTokens(model_id, self.context_settings.override_context_window);
        self.agent.resetContextUsage();

        attach_compaction: {
            const compaction_client = self.gpa.create(ai.openai_compatible.Client) catch break :attach_compaction;
            compaction_client.init(self.gpa, self.io, .{
                .base_url = base_url,
                .api_key = api_key,
                .model = model_id,
                .tools = &.{},
                .reasoning = .{ .effort = effort },
            }) catch {
                self.gpa.destroy(compaction_client);
                break :attach_compaction;
            };
            self.setCompactionClient(.{ .openai_compatible = compaction_client });
        }
        attach_naming: {
            const naming_client = self.gpa.create(ai.openai_compatible.Client) catch break :attach_naming;
            naming_client.init(self.gpa, self.io, .{
                .base_url = base_url,
                .api_key = api_key,
                .model = model_id,
                .tools = &.{},
                .reasoning = .{ .effort = effort },
            }) catch {
                self.gpa.destroy(naming_client);
                break :attach_naming;
            };
            self.setNamingClient(.{ .openai_compatible = naming_client });
        }
    }

    pub fn attachOpenAiResponsesClient(
        self: *AgentRuntime,
        base_url: []const u8,
        api_key: []const u8,
        model_id: []const u8,
        reasoning: ai.Reasoning,
    ) !void {
        const client = try self.gpa.create(ai.openai_responses.Client);
        errdefer self.gpa.destroy(client);
        try client.init(self.gpa, self.io, .{
            .base_url = base_url,
            .api_key = api_key,
            .model = model_id,
            .tools = tools_mod.builtinRegistry(),
            .mcp_tools = self.mcp_tools,
            .reasoning = reasoning,
            .strict = self.strict_outputs,
            .session_id = self.session_writer.session.id.slice(),
            .system_prompt = self.system_prompt,
        });
        errdefer client.deinit();
        self.replaceClient(.{ .openai_responses = client });
        self.agent.context_window_tokens = compaction.contextWindowTokens(model_id, self.context_settings.override_context_window);
        self.agent.resetContextUsage();

        attach_compaction: {
            const compaction_client = self.gpa.create(ai.openai_responses.Client) catch break :attach_compaction;
            compaction_client.init(self.gpa, self.io, .{
                .base_url = base_url,
                .api_key = api_key,
                .model = model_id,
                .tools = &.{},
                .reasoning = reasoning,
                .session_id = self.session_writer.session.id.slice(),
                .system_prompt = self.system_prompt,
            }) catch {
                self.gpa.destroy(compaction_client);
                break :attach_compaction;
            };
            self.setCompactionClient(.{ .openai_responses = compaction_client });
        }
        attach_naming: {
            const naming_client = self.gpa.create(ai.openai_responses.Client) catch break :attach_naming;
            naming_client.init(self.gpa, self.io, .{
                .base_url = base_url,
                .api_key = api_key,
                .model = model_id,
                .tools = &.{},
                .reasoning = reasoning,
                .session_id = self.session_writer.session.id.slice(),
                .system_prompt = self.system_prompt,
            }) catch {
                self.gpa.destroy(naming_client);
                break :attach_naming;
            };
            self.setNamingClient(.{ .openai_responses = naming_client });
        }
    }

    fn languageModelMatches(a: ai.LanguageModel, b: ai.LanguageModel) bool {
        return switch (a) {
            .none => b == .none,
            .codex_responses => |client| b == .codex_responses and b.codex_responses == client,
            .openai_compatible => |client| b == .openai_compatible and b.openai_compatible == client,
            .openai_responses => |client| b == .openai_responses and b.openai_responses == client,
        };
    }

    fn languageModelMatchesOwned(model: ai.LanguageModel, owned: OwnedClient) bool {
        return switch (owned) {
            .codex_responses => |client| model == .codex_responses and model.codex_responses == client,
            .openai_compatible => |client| model == .openai_compatible and model.openai_compatible == client,
            .openai_responses => |client| model == .openai_responses and model.openai_responses == client,
        };
    }

    fn replaceClient(self: *AgentRuntime, next: OwnedClient) void {
        self.codex_connection_expired = false;
        if (self.owned_client) |old| old.deinit(self.gpa);
        self.owned_client = next;
        self.client = next.languageModel();
        self.agent.client = self.client;
        self.assertClientInvariant();
        // The client built its `tools_json` from builtin + mcp_tools only.
        // Rebuild it now from the live registry so plugin tools
        // (`lua__<plugin>__<tool>`) are visible to the model on the next
        // prompt. Best-effort: a failure leaves the builtin-only set and is
        // logged — the attach itself already succeeded.
        next.updateMcpTools(self.mcp_tools, self.agent.tool_registry, &.{}) catch |err| {
            std.log.warn("replaceClient: updateMcpTools failed: {s}", .{@errorName(err)});
        };
    }

    /// Install the dedicated background-summarizer client, replacing any
    /// previous one. Connecting happens between turns, so no summarizer is in
    /// flight against the old client when it is freed.
    fn setCompactionClient(self: *AgentRuntime, next: OwnedClient) void {
        self.agent.drainBackgroundCompaction();
        if (self.owned_compaction_client) |old| old.deinit(self.gpa);
        self.owned_compaction_client = next;
        self.agent.compaction_client = next.languageModel();
    }

    /// Tear down the background-summarizer client (after draining any in-flight
    /// summary), disabling compaction until the next connect.
    fn clearCompactionClient(self: *AgentRuntime) void {
        self.agent.drainBackgroundCompaction();
        if (self.owned_compaction_client) |old| old.deinit(self.gpa);
        self.owned_compaction_client = null;
        self.agent.compaction_client = .none;
    }

    /// Install the dedicated branch-naming client, replacing any previous one.
    /// The caller (App) guarantees no naming job is in flight against the old
    /// client — it cancels naming before connecting/reconnecting.
    fn setNamingClient(self: *AgentRuntime, next: OwnedClient) void {
        if (self.owned_naming_client) |old| old.deinit(self.gpa);
        self.owned_naming_client = next;
        self.naming_client = next.languageModel();
    }

    /// Tear down the branch-naming client, disabling naming until the next
    /// connect. Same caller contract as `setNamingClient`.
    fn clearNamingClient(self: *AgentRuntime) void {
        if (self.owned_naming_client) |old| old.deinit(self.gpa);
        self.owned_naming_client = null;
        self.naming_client = .none;
    }
};
fn codexRefreshNeeded(expires_ms: i64, now_ms: i64) bool {
    return expires_ms <= now_ms + codex_refresh_margin_ms;
}

test "OwnedClient.updateMcpTools pushes plugin tools into a freshly-attached client" {
    // Regression for the user-reported "lua__write-tool__edit: command not
    // found" bug: a newly-attached client built `tools_json` from builtin +
    // mcp_tools only, so plugin tools never reached the model and it tried
    // to invoke them as shell commands. `replaceClient` now calls
    // `OwnedClient.updateMcpTools` with the live registry right after the
    // client is attached — this test pins that dispatch in place by driving
    // the helper directly with an openai_compatible client + a registry
    // carrying one plugin tool.
    const gpa = std.testing.allocator;

    var client = try gpa.create(ai.openai_compatible.Client);
    try client.init(gpa, std.testing.io, .{
        .base_url = "https://example.invalid",
        .api_key = "test-key",
        .model = "test-model",
        .tools = tools_mod.builtinRegistry(),
        .mcp_tools = &.{},
        .session_id = "test",
        .system_prompt = "",
    });
    defer {
        client.deinit();
        gpa.destroy(client);
    }

    // Plugin tools are absent from the initial tools_json (builtin only).
    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, "lua__p__t") == null);

    const reg = try gpa.create(tools_mod.ToolRegistry);
    defer {
        reg.deinit(gpa);
        gpa.destroy(reg);
    }
    reg.* = tools_mod.ToolRegistry.init(tools_mod.builtinRegistry());
    const owned_name = try gpa.dupe(u8, "lua__p__t");
    const owned_desc = try gpa.dupe(u8, "test");
    try reg.addPluginTool(gpa, .{
        .name = owned_name,
        .description = owned_desc,
        .schema = .{ .properties = &.{} },
        .run = undefined,
        .display = undefined,
    });

    // The exact dispatch path `replaceClient` now uses.
    const owned: AgentRuntime.OwnedClient = .{ .openai_compatible = client };
    try owned.updateMcpTools(&.{}, reg, &.{});

    try std.testing.expect(std.mem.indexOf(u8, client.tools_json, "lua__p__t") != null);
}

test "codex refresh starts before token expiry" {
    const now_ms: i64 = 10_000;
    try std.testing.expect(codexRefreshNeeded(now_ms - 1, now_ms));
    try std.testing.expect(codexRefreshNeeded(now_ms + codex_refresh_margin_ms, now_ms));
    try std.testing.expect(!codexRefreshNeeded(now_ms + codex_refresh_margin_ms + 1, now_ms));
}

test "runtime selects responses adapter when requested" {
    const config: config_mod.Config = .{
        .model_selection = .{
            .custom = .{
                .provider_name = @constCast("openai_compatible"),
                .base_url = @constCast(""),
                .api_key = @constCast(""),
                .model = .{ .id = @constCast("test") },
                .use_responses_endpoint = true,
            },
        },
    };
    try std.testing.expectEqual(
        config_mod.AdapterKind.openai_responses,
        AgentRuntime.adapterForConfig(.openai_compatible, config).?,
    );
}

test "runtime keeps codex adapter for openai provider" {
    const config: config_mod.Config = .{ .use_responses_endpoint = true };
    try std.testing.expectEqual(
        config_mod.AdapterKind.codex_responses,
        AgentRuntime.adapterForConfig(.openai, config).?,
    );
}

test "createSystemPrompt substitutes ${CWD} with the working directory" {
    const gpa = std.testing.allocator;
    const rendered = try context_assembly.substituteBaseTemplate(gpa, "header\nYou are in ${CWD}.\n", "C:\\repos\\nova");
    defer gpa.free(rendered);
    try std.testing.expectEqualStrings("header\nYou are in C:\\repos\\nova.\n", rendered);
}

test "createSystemPrompt leaves a template without the placeholder untouched" {
    const gpa = std.testing.allocator;
    const rendered = try context_assembly.substituteBaseTemplate(gpa, "no placeholder here", "/tmp/nova");
    defer gpa.free(rendered);
    try std.testing.expectEqualStrings("no placeholder here", rendered);
}

test "createSystemPrompt substitutes ${OS} with the host operating system" {
    const gpa = std.testing.allocator;
    const rendered = try context_assembly.substituteBaseTemplate(gpa, "OS: ${OS}", "/tmp/nova");
    defer gpa.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "${OS}") == null);
    try std.testing.expect(std.mem.startsWith(u8, rendered, "OS: "));
    try std.testing.expect(rendered.len > "OS: ".len);
}

test "readContextFile reads AGENTS.md when it exists" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var file = try tmp.dir.createFile(io, "AGENTS.md", .{ .truncate = true });
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try writer.interface.writeAll("# Guidelines\nThis is a test.");
        try writer.interface.flush();
    }

    const cwd = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(cwd);

    const agents_md = (try context_assembly.readProjectRuleFile(gpa, io, cwd, "AGENTS.md")) orelse return error.MissingContextFile;
    defer gpa.free(agents_md);
    try std.testing.expectEqualStrings("# Guidelines\nThis is a test.", agents_md);
}
