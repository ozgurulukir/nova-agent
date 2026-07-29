# Nova Guidelines

This project uses Zig 0.16. Consult the tigerstyle skill before writing code.

## Setup

- Vendor `fff` (build into `vendor/fff/libfff_c.so`) and the ModernBERT ONNX model (`vendor/local-models/ModernBERT-bash-classifier`) after cloning. Both are gitignored.
- Set `OMP_WAIT_POLICY=passive` at runtime to avoid MKL/CPU spin in the embedding worker.
- `zig build install -Doptimize=ReleaseFast --prefix $HOME/.local` installs to `~/.local/bin/`.

## Building the TUI

TUI built with libvaxis vxfw (source in zig-pkg). Prefer framework primitives.

**vxfw gotcha:** `TextField.widget()` is _mutating_ — it takes `*Self`, not `*const Self`. Accessors returning `*TextField` must be declared on `*App`, not `*const App`, or the call site fails to type-check.

**Zig 0.16 field rule:** `pub` cannot precede a field declaration — only functions/variables. Cross-module field access goes through `pub fn` accessors (`getX()` form, never `X()`, because of the field-vs-method name collision).

**TUI module split.** `src/tui.zig` holds `App` lifecycle and `RootWidget`; `src/tui/` is split by concern. See `README.md` Architecture for the current module list.

**App state grouping pattern.** `App` struct fields are grouped into focused sub-structs defined in `src/tui/app_state.zig`: `InputState` (text fields), `PickerStates` (per-picker state), `NavState` (cursors + quit state machine), `ListWidgets` (scrollable list views), `ProviderState` (API keys + registry + connectivity), `InputBuffers` (inline edit buffers), `AtSearchState` (`@`-mention search), `BackgroundModalState` (Ctrl+O modal), `MetricsState` (spinner + diff cache). Each sub-struct owns one concern; accessors on `*App` expose inner fields. When adding new App state, prefer extending an existing sub-struct or adding a new one rather than growing the flat struct.

**Domain extraction pattern.** Isolated domain clusters (lane lifecycle, diff lifecycle, session switching, at-search, transcript navigation, permission, event callbacks, queue, settings lifecycle, clipboard helper) live under `src/tui/` as free-function modules. Each module imports `const tui = @import("../tui.zig")` and defines `pub fn` taking `*App` as the first parameter. The original App method stays as a 1-line delegate (Strangler Fig) so inline tests in `tui.zig` resolve via the struct. When a private App method is needed, promote it to `pub` — not `pub const` (that is for module-level re-exports of nested types).

**Widget extraction pattern.** Isolated widgets live under `src/tui/widgets/`. A new widget file declares the outer border widget as:

```zig
pub const NameWidget = struct { app: *App, pub fn widget(...) vxfw.Widget { ... } }
```

with a private `Inner` struct built inside `draw()` from a `vxfw.DrawContext`. The file imports `const tui = @import("../../tui.zig");`, `const tui_style = @import("../style.zig");`, `const panel = @import("panel.zig");` and re-aliases `const App = tui.App;`. Nested types from other modules are re-exported through `pub const` in `tui.zig` so widget files reach them as `tui.<module>.<Type>`.

**Per-mode command routing.** `src/tui/command_router.zig` holds one struct per `App.Mode` variant, each owning a `handle` method migrated from `App`. The dispatcher is a free function delegating to the right struct. Add new per-mode logic here — don't reintroduce private methods on `App` for key handling.

**Viewport scrolling pattern.** Standardize overlay list viewports using `panel.ViewportWindow.compute(selection, total_count, surface.size.height)` in `src/tui/widgets/panel.zig`. Use `viewport.screenRow(i)` for row rendering calculations.

**Provider polymorphism pattern.** Unify static builtin `config_mod.Provider`, dynamic `modelsdev.Provider`, and user-defined `config_mod.ProviderConfig` handles using `ProviderHandle = union(enum) { builtin, dynamic, config }` in `src/tui/widgets/provider_picker.zig`. All three share the same accessor surface (`id()`, `displayName()`, `description()`, `defaultBaseUrl()`, `requiresApiKey()`, `catalogueIndex()`). The `/connect` picker builds a single merged list via `buildMergedProviderList` in `src/tui/provider_model.zig`: builtin catalogue → models.dev registry (overrides builtins with same id) → config providers (overrides everything with same name, **except** entries already covered by the models.dev registry — a `reg.lookup(cp.name)` guard prevents the persisted `ProviderConfig` entry from shadowing the `.dynamic` handle and converting the provider to a "custom" entry in the picker).

**System clipboard pattern.** `src/clipboard.zig` handles OS clipboard reading/writing via terminal OSC 52 sequences (`\x1b]52;c;<base64>\x07`) with OS-native execution fallback (`wl-copy`/`xclip`/`pbcopy`/`powershell` via `bash.zig`). `clipboard_helper.zig` routes clipboard data dynamically to focused input fields and transcript message blocks.

**Settings lifecycle pattern.** `src/tui/settings_lifecycle.zig` manages pending tabbed form edits, syncs values to `app.cached_config` in real-time, and serializes user settings on `Ctrl+S`. `saveSettings` writes only settings-managed fields (`enable_thinking`, `use_responses_endpoint`, `system_prompt`, `bash_classifier_url`) — never provider/model. If a project config exists (`.nova/config.json`), settings are written to both global and project configs; otherwise global only. This prevents project-level provider/model overrides from leaking into global config.

**MCP Server & Tool Discovery pattern.** `src/mcp/manager.zig` merges `mcp_servers` configuration across global/project layers (supporting `mcp_servers`, `mcpServers`, and `mcp` JSON aliases). `McpServerConfig.transport` is `union(enum) { stdio, sse }` — stdio (command+args) or remote Streamable HTTP (url + optional `headers: []McpHeader` for header-auth servers like Context7). **`{env:VAR}` security model:** placeholders in command/args/url/header-values are stored **raw** at parse and expanded only at connect time (`config.expandMcpServer`, called in `manager.syncFromConfig` before building each `McpClient`); `expandEnvVars`/`loadEnvMap` (config.zig) are the SSOT for expansion. Because the config keeps the raw placeholder, `serialize` writes `{env:VAR}` back to config.json — never the resolved secret. The Streamable HTTP client (`mcp/client.zig` `sendRequestHttp`) POSTs JSON-RPC with `Accept: application/json, text/event-stream` plus any configured custom headers (`buildExtraHeaders` allocates per-request: Accept + `Mcp-Session-Id` + custom), reads a JSON body or an SSE stream (`transport.zig` `readSseResponse`), tracks `Mcp-Session-Id`, maps `404`→`McpSessionExpired`, and negotiates protocol `2025-03-26` (stdio keeps `2024-11-05`). **Tool injection:** the AI client serializes its tool list once at attach time, but the client is attached before the MCP manager exists — so `updateMcpTools` (on each client + the `LanguageModel` dispatcher) rebuilds `tools_json` in place, and the App's `refreshMcpTools`/`injectMcpTools` (provider_model.zig) push schemas on startup (`run()`), `/mcp` open, and toggle/reconnect/disconnect. Without this the model never sees `mcp__<server>__<tool>` definitions. `McpMode.handle` in `command_router.zig` routes `Up`/`Down`/`j`/`k` navigation, `Space`/`Enter` toggling, `Ctrl+R`/`r` re-syncing, `d` disconnect, `a` add-remote-by-URL (a `State.adding` sub-state with the `input_buffers.mcp_url` buffer; **runtime-only** — appended to `cached_config.mcp_servers`, NOT persisted to config.json; URL-only, no headers — header servers are added via config.json), and `Esc`/`q` closing.

**Lua Plugin System pattern.** `src/lua/` implements a full Lua 5.4 plugin SDK. `PluginManager` (manager.zig) discovers plugins from `~/.config/nova/plugins/` (global) and `.nova/plugins/` (project), loads manifests (`plugin.lua`), and creates sandboxed Lua states. Each plugin runs in a restricted environment — `io`, `debug`, `package`, `os.execute` are blocked; instead plugins use 23 `nova.*` bridge functions: Filesystem (read_file, write_file, edit_file, search_files, find_files, list_dir, file_info, mkdir, copy_path, move_path, delete_path), Shell & Env (run_bash, get_env, get_cwd, get_project_root), Git (git_status, git_diff, git_log, git_branch, git_commit), Plugin System (register_tool, on, think). All file ops go through `sanitizePath` (cwd-confinement guard); path ops (mkdir/copy/move/delete) close the safety gap that `run_bash` leaves unclassified in the plugin sandbox. The `App` struct holds `plugin_manager: lua_mod.PluginManager` and `tool_registry: *tools.ToolRegistry`, both initialized in `init`. The `/plugins` TUI overlay shows loaded plugins with active/inactive status. See `docs/plugins/` for the full plugin development guide and API reference.

**Plugin event wiring pattern.** `nova.on(event, callback)` subscribes to lifecycle events by storing callback refs in each plugin's `"nova_events"` Lua registry table. Events are emitted by `Agent.ExecutorBridge` at tool-call boundaries — `onStarted`/`onFinished` (agent.zig) call `plugin_manager.emitEvent(.{ .tool_call_started = ... })` / `.tool_call_finished`. `PluginManager.emitEvent` (manager.zig) iterates every active plugin and drains its `"nova_events"` sub-table for the event name, pcalling each stored callback ref with the payload pushed as a Lua table via `events.pushEventData`. This multi-state dispatch (one Lua state per plugin) replaced the old single-state `EventBus` struct, which was dead code. Event types: `turn_started`, `turn_ended`, `tool_call_started` (`{name, call_id}`), `tool_call_finished` (`{name, call_id, success}`), `response_received`, `plugin_loaded`, `plugin_unloaded`. Reentrancy is safe because the agent worker is single-threaded and emits at tool-call boundaries (after the plugin's own handler has returned).

**Plugin glob matcher pattern.** `nova.find_files(root, pattern, opts?)` walks `root` recursively and matches each file's relative path against a glob pattern via `matchGlob` (plugin_api.zig). Supports `**` (spans directories), `*` (within a segment, does not cross `/`), `?` (one char). The matcher is segment-aware: `src/*.ts` does not match `src/nested/a.ts` (only `*` not `**`), but `**/*.ts` matches at any depth. max_results cap (200, default 100); gitignore is NOT honored (use `run_bash` with `rg --files` if needed). `matchGlob` is public for unit testing; the 8-test suite covers empty/literal/star/double-star/question-mark cases.

**Plugin prompt injection pattern (`prompt.md`).** Each plugin directory MAY ship an optional `prompt.md` describing how the model should use that plugin's tools. `src/plugin_prompt.zig` scans `<home>/.config/nova/plugins/*/prompt.md` and `<cwd>/.nova/plugins/*/prompt.md` (project overrides global on directory-name collision) and strips YAML frontmatter via `skill_mod.stripFrontmatter` (reused from `src/skill.zig`). The markdown bodies are injected into the system prompt as a `<plugin_prompts>` block by `plugin_prompt.formatForPrompt`, appended in `context/assembly.zig` `assembleSystemPrompt` step 5 — parallel to the `SKILL.md` → `<available_skills>` flow. This is a **pure text scan, no Lua state** — it runs early in `runtime.zig` `initSession` (alongside skill loading), before `PluginManager`/`App.initRuntime` create any Lua states. Because `assembleSystemPrompt` bakes the prompt once, plugin prompts reach the model via `system_prompt` only; a freshly-added `prompt.md` takes effect on the next session/lane. The scan mirrors `PluginManager`'s directory conventions (same `global_dir`/`project_dir` roots) but is intentionally decoupled — a plugin with `prompt.md` but no `plugin.lua` still contributes prompt text, and a plugin with `plugin.lua` but no `prompt.md` contributes none. Plugins whose body is empty after frontmatter stripping are skipped (uniform `error.FileNotFound` path).

**Plugin tool dispatch via ToolRegistry pattern.** Plugin tools registered through `nova.register_tool` are materialized as `tools.Tool` records in `src/lua/registry_bridge.zig` and inserted into the `ToolRegistry` via `provider_model.registerPluginTools(self)`. Each `Tool` carries a `*PluginToolKey` in its `userdata` field; the shared `runPluginTool`/`displayPluginTool` dispatchers decode the key and route the call to the correct `(plugin_name, tool_name)` handler through `PluginManager.callTool`. The `*const fn` signature on `Tool.run`/`display` is preserved by passing `userdata: *anyopaque` as the last argument — the dispatcher `@ptrCast`s back to a `*PluginToolKey`. `Tool.userdata_free: ?*const fn (gpa, *anyopaque) void` lets the registry release each tool's heap-allocated state. The App's `initRuntime` calls `registerPluginTools` right after `plugin_manager.loadAll()`, which puts the tools in the registry. Plugin tools still use the `lua__<plugin>__<tool>` naming convention so the model can disambiguate them. `executor.runOne` dispatches every non-`mcp__` call through `tool_registry.all(...)` + `tools.runWith` — no `lua__` prefix branch. **Tool visibility to the model:** a client only advertises tools that are in its serialized `tools_json`. The client is built at `attach` time, but the registry (which carries plugin tools) is set on the agent afterwards — so the freshly-attached client would otherwise keep its builtin-only `tools_json` and never learn about `lua__<plugin>__*` / `mcp__<server>__*` entries. `runtime.replaceClient` closes this gap: after installing each new client it immediately calls `OwnedClient.updateMcpTools(self.mcp_tools, self.agent.tool_registry, &.{})` (best-effort, error logged) to rebuild `tools_json` from the live registry. The `OwnedClient.updateMcpTools` union helper dispatches to all three concrete clients (`codex_responses`/`openai_compatible`/`openai_responses`). `injectAllTools`/`refreshMcpTools` (provider_model.zig) push MCP+plugin schemas again on `/mcp` and `/plugins` open, toggle, and reconnect. Without the `replaceClient` push, plugin tools sat in the registry but never reached the model until the user opened `/plugins` — and the model then tried to invoke them as shell commands (`bash: lua__write-tool__edit: command not found`).

**Plugin tool parameter parsing.** `callToolHandler()` in `plugin_api.zig` parses the JSON arguments string into a Lua table before calling the handler, using `pushJsonToLua()` / `pushJsonValue()` which recursively convert `std.json.Value` to Lua values (objects → tables, arrays → 1-indexed tables, strings/numbers/booleans → corresponding Lua types). Plugin handlers receive `params` as a proper Lua table — `params.depth`, `params.pattern`, etc. work directly without manual JSON parsing.

**Plugin bridge function pattern.** All `nova.*` bridge functions are C-callable `lua_CFunction` registered in the `nova` global table by `registerPluginApi()` in `sandbox.zig`. Each function receives `?*c.lua_State`, extracts arguments via `bridge.pullValue()`, performs the operation through Nova's safe Zig APIs (path validation via `sanitizePath()`, bash execution via `bash_exec.runWithOptions()`), and returns results as Lua values. The `std.Io` instance is stored in the Lua registry (`nova_io`) for filesystem access. Currently 18 bridge functions across 5 categories: Filesystem (6), Shell & Env (4), Git (5), Plugin System (3).

**Tool schema strict-mode pattern.** OpenAI strict structured-outputs mode (`"strict":true`, `additionalProperties:false`, `required:[all properties]` with optionals made nullable) is **opt-in via `ai.Config.strict` (default `false`)** — it only works against the OpenAI API and silently breaks function-calling on gateways (OpenRouter/Ollama/vLLM/Together), which causes the model to emit tool calls as plain text (`<function=...><parameter=...>`) instead of `tool_calls` deltas. `buildAllToolsJson`/`writeToolDefinition` in both `src/ai/openai_compatible.zig` and `src/ai/responses_core.zig` thread a `strict: bool` parameter end-to-end; the `Client.strict` field captures it at `init` so `updateMcpTools` rebuilds `tools_json` consistently. When `strict` is off: the `"strict"` key is omitted (the leading comma before `"parameters"` is still written so the JSON stays valid), and `required` lists only genuinely-required properties. The setting flows `config.strict_outputs: ?bool` → `AgentRuntime.strict_outputs` (set at session init and re-synced from `cached_config` at every connect) → `.strict = self.strict_outputs` on the three `client.init` call sites (codex/openai_compatible/openai_responses) in `runtime.zig`. Enable it with `"strictOutputs": true` in config.json or `NOVA_STRICT_OUTPUTS=1`. There is **no provider auto-detection** — defaulting strict off keeps tool-calling working everywhere; OpenAI direct users opt in explicitly.

**Type System Discipline pattern.** Use `union(enum)` instead of flat structs with optional fields whenever a value can be in one of several mutually-exclusive states. This makes illegal combinations unrepresentable at compile time. Current types following this pattern:

- `ai.ChatMessage` — `union(enum) { system, user, assistant, tool }`. The `tool` variant carries non-optional `call_id`; other variants cannot. `role()` and `text()` are cross-variant accessors.
- `transcript.Message` — `union(enum)` with 10 variants (`user`/`agent`/`skill`/`logo`/`thinking`/`status`/`notice`/`success`/`info`/`tool`). `Basic` and `ToolView` payload structs group fields by category. `kind()` bridges the loose `MessageKind` enum; `mirror()` is test-only flat view.
- `tools.Output.display` — `Display` union with `none`/`text`/`diff` variants, replacing the old `?[]u8 + DisplayKind` pair that allowed `null` with `.diff`.
- `config.McpServerConfig.transport` — `union(enum) { stdio, sse }`. A server is either stdio (command+args) or sse (url), never both or neither.
- `mcp.McpClient` — `transport: union(enum) { stdio, sse }` (static config) + `lifecycle: union(enum) { disabled, stdio, sse, failed }` (runtime state). `status()` maps lifecycle to the legacy `ServerStatus` enum.
- `config.Config.model_selection: ?ModelSelection` — typed view replacing 9 loose optional fields. `ModelSelection` is `union(enum) { builtin, custom }`: builtin carries `provider: Provider` + `provider_name`; custom carries `provider_name`, `base_url`, `api_key`. Optional settings (`use_responses_endpoint`, `enable_thinking`, `system_prompt`, `bash_classifier_url`) live on both variants. Callers use accessors (`provider()`, `providerName()`, `model()`, `baseUrl()`, `apiKey()`, `useResponsesEndpoint()`, `enableThinking()`, `systemPrompt()`, `bashClassifierUrl()`) so builtin/custom differences are hidden. `applyConfigOverlay` treats `model_selection` as canonical and propagates `provider_name` to the target's legacy field; `syncModelSelectionFromLegacy` mirrors legacy changes back into it. `parseObject` only populates `model_selection` when all required fields are present — since `api_key` is never serialized (lives in `auth.json`), disk-loaded configs **never** have `model_selection`. Callers that need `model_selection` after a fresh load must fall back to legacy fields (`config.provider`, `config.model`, `config.base_url`, `config.provider_name`), which ARE populated from `defaultModel` and `hydrateActiveModel`.
- `tui.AtSearchState` — `union(enum) { closed, indexing, open }` with `IndexingPayload` and `OpenPayload` structs. `kind()`/`results()`/`close()` helpers bridge callers.
- `tui.NavState.quit` — `QuitState = union(enum) { none, pending, confirmed }` replacing `?Timestamp + bool`.
- `tui.ModelCatalogue.load` — `LoadState = union(enum) { idle, loading, failed }`.
- `search.Backend.state` — `State = union(enum) { idle, loading, ready, failed }`. `handle: *anyopaque` stays opaque (fff C FFI standard).
- `tui.MetricsState.diff` — `DiffState = union(enum) { idle, loading, ready, refreshing }`. The `refreshing` arm keeps the old cache while a new fetch is in flight. Backward-compat accessors (`diff_refresh_future`, `diff_refresh_done`, `diff_loading`, `diff_refresh_again`, `diff_cache`) preserve existing call sites after the flat-to-union migration.
- `config.ProviderModel = Model` — type alias removing duplicate struct drift.
- `config.BaseUrl` — `union(enum) { default, custom: []u8 }`. In overlay merges, `.default` means "don't override"; at final resolution it falls through to `Provider.defaultBaseUrl()`.
- `config.ReasoningSetting` — `union(enum) { unset, effort: ai.ReasoningEffort }`. Follows `BaseUrl`'s overlay-merge pattern: `.unset` means "not specified in this layer, don't override"; `.effort` carries an explicit level (including `.default` which omits the `reasoning_effort` request parameter). `resolve()` falls back to `.medium` for `.unset`.
- `session.SessionSummary.leaf_entry_id: ?EntryId` — branded `EntryId` (fixed-size `[entry_id_len]u8`) instead of loose `[]u8`.
- `model_loader.ModelSource` — `union(enum) { openai_codex, openai_compatible: Compatible }`. The `.openai_compatible` arm is a `Compatible` struct `{ provider, base_url, auth_key_id }` (all gpa-owned; `source.deinit(gpa)` frees the strings) rather than a bare `Provider` enum. A bare enum collapsed every dynamic/config provider (StepFun, Kimi, …) to `.openai_compatible`, so a multi-provider catalogue couldn't tell them apart and `applySelectedModel` connected to whichever URL was stashed in `cached_config`. Carrying the full connection per row makes the mismatch unrepresentable: `applySelectedModel` reads the selected entry's `conn` directly and never consults `cached_config.base_url`. The disk cache (`model_cache.Record`) serializes `authKeyId` (cache version 2; v1 is read back compatibly, resolving `auth_key_id` from the configured provider label).
- `tools.Schema.Property` — `nullable: bool` flag supporting OpenAI strict-mode union types (`["string","null"]`); `enum_values: ?[]const u8` for OpenAI enum schemas; `default_value: ?[]const u8` for JSON fragment defaults. The schema writer emits nullable union arrays only when `nullable` is set, while keeping nested object `additionalProperties: true` for free-form fields like `env`. Strict-mode emission (`"strict":true`, `additionalProperties:false`, and `required:[all properties]`) is gated by the `strict: bool` parameter (see the Tool schema strict-mode pattern below); when strict is off, `required` lists only genuinely-required properties and the `"strict"` key is omitted. `deinit(gpa)` frees owned `enum_values` and `default_value` slices.

**Models.dev provider filtering pattern.** `parseModelsDevJson` in `src/models/registry.zig` includes any provider with a non-empty `api` field and ≥1 model — npm package identity is irrelevant. The `api` field is the ground-truth signal for Nova's `openai_compatible` adapter. `@ai-sdk/anthropic` providers with custom `api` endpoints (kimi-for-coding, minimax, etc.) are included; `@ai-sdk/openai` providers without `api` (openai, perplexity-agent) are excluded because `Provider.base_url` is non-optional. Providers without an `api` field (`@ai-sdk/google`, `@ai-sdk/azure`, etc.) are correctly excluded.

**Models.dev network-first loading pattern.** `loadOrFetchRegistry` tries sources in order: (1) network fetch from `https://models.dev/api.json` with User-Agent `nova-agent/1.0`, (2) fresh cache (within 24h TTL), (3) stale cache (ignoring TTL), (4) vendored snapshot at `<exe_dir>/../share/nova/api.json` (installed by `zig build install`), (5) builtins-only fallback. The vendored snapshot seeds the cache directory (`~/.config/nova/cache/models.dev/api.json`) so subsequent starts skip the file read, ensuring 145+ dynamic providers are always available offline. `openProviderPicker` in `src/tui/provider_model.zig` deinits and reloads `provider_state.modelsdev_registry` every time the picker opens. Diagnostic logging at each stage (`modelsdev.fetch.ok`, `modelsdev.fetch.failed`, `modelsdev.cache.fresh`, `modelsdev.cache.stale`, `modelsdev.vendored`, `modelsdev.registry.fallback`) helps diagnose empty provider lists.

**HTTP fetch decompression pattern.** `fetchApiJson` in `src/models/registry.zig` must honor `response.head.content_encoding`: gzip/deflate/zstd responses from Cloudflare-backed hosts (models.dev) are decompressed via `response.readerDecompressing` before caching; identity responses pass through unchanged. Using a plain `response.reader` stores compressed bytes in the cache, which `parseModelsDevJson` rejects, silently falling back to builtins-only (14 providers). `listModels` in `src/ai/openai_compatible_models.zig` already follows this pattern; `fetchApiJson` must match it.

**Dynamic provider connection pattern.** When a models.dev dynamic provider is selected, `submitDynamicProviderSetup` stashes the provider's `base_url` and the user's API key into `cached_config` before entering the model picker, and stores two identity fields: `dynamic_provider_name` (human-readable, e.g. "StepFun AI", used by the status bar) and `dynamic_provider_id` (the auth.json key, e.g. "stepfun-ai"). Both are **runtime-only** — never serialized to config.json. **Selection-time resolution no longer reads `cached_config`:** `applySelectedModel` resolves the connection URL and key **directly from the selected entry's own `ModelSource`** — `ModelSource.openai_compatible` is a `Compatible` struct (`{ provider, base_url, auth_key_id }`), so each catalogue row carries its own full connection. `applySelectedModel` calls `compatibleApiKeyForConn(conn)` (auth.json lookup by `conn.auth_key_id`, fallback to anonymous/local) and `attachOpenAiCompatibleClient(conn.base_url, ...)`. The `cached_config.base_url`/`dynamic_provider_id` stash is now only for **session resume** (`tryAttachOpenAiCompatibleFromConfig`) and `hasOpenAICompatibleCredentials`; `updateCachedModelSelection` mirrors the entry's `conn` into the stash so resume stays consistent. This closed a class of multi-provider bugs where `cached_config.base_url` held a single global value and selecting a model from a different provider (in a `connected_provider` sweep) connected to the wrong endpoint or returned `NotConnected`. `compatibleBaseUrl`/`compatibleApiKey` (the provider-enum variants) are now test-only; do not reintroduce them on the selection path — use `compatibleApiKeyForConn` and the entry's `conn.base_url` instead.

**Dynamic provider persistence pattern.** `serialize` writes `defaultModel: "provider_name/model_id"` as the single source of truth for provider identity — there is no separate `"provider"` field. `parseModelSelection` splits on the first `/` to recover `provider_name` and `model_id`. After restart, `model_selection` is usually null (because `api_key` is never serialized), so all rehydration paths fall back to legacy fields: `tryAttachOpenAiCompatibleFromConfig` resolves `base_url` from `config.base_url` (hydrated from the `providers[]` map by `hydrateActiveModel`), `model_id` from `config.model`, and the API key from `auth.json` via `config.provider_name`. `hydrateActiveModel` includes a recovery fallback: when `provider_name` is the generic enum label (`"openai_compatible"`) — e.g. from configs written before the `provider_name` serialization fix — it matches `.openai_compatible` entries in the `providers[]` map by enum and repairs `provider_name` to the actual id. `providerDisplayName` and `providerLabel` in `status.zig` fall back to `config.provider_name` / `config.provider` when `model_selection` is null. `buildMergedProviderList` Layer 3 skips config entries covered by the models.dev registry (`reg.lookup(cp.name)`) to prevent the persisted `ProviderConfig` from shadowing the `.dynamic` handle. `collectConfiguredProviders` block 3 uses a `covered_by_registry` guard (with `ms.provider_name` fallback for resume) and resolves the API key from `provider_state.api_keys` instead of the always-empty `ms.api_key`.

**Mid-session model persistence pattern.** The picker must mirror a model switch into the session DB, not only `config.json`. `applySelectedModel` resolves a `provider_name` (`Provider.openai.label()` for codex, `conn.auth_key_id` for compatible) and, after a successful client attach, calls `session_writer.updateModel(provider_name, model_id)` — the same call `runtime.applyFromConfig` makes. Without it the picker bypassed the session write, so `initResume` restored the stale creation-time model on restart. The write is **best-effort** (logged on error, never rolls back the applied client switch) and gated by `AgentRuntime.session_writer_started` (default `false`, set `true` in `initSession` after the writer thread is up). The gate exists because TUI test harnesses construct a partial runtime with `session_writer = undefined`; the flag lets them exercise the picker without touching sqlite. `hasOpenAICompatibleCredentials` was relaxed to match: since `api_key` never serializes, gating purely on the runtime stash made the disk-cache restore (`/models`) skip the dynamic provider on restart. The typed `model_selection` with a non-empty `baseUrl()` is now the durable signal (real key resolved from `auth.json` at fetch time); `shouldLoadConfiguredCompatibleCatalog` resolves `base_url` from `model_selection.baseUrl()` when the legacy stash is null. `model.id.len == 0` is guarded by `return error.EmptyModelId` before constructing the non-optional `ModelSelection.custom.model.id` — use a real early return, never `std.debug.assert`, because `unreachable` is UB in ReleaseFast (the install target) and would not protect that build.

**Typed callback pattern.** `agent.Listener(Ctx)` and `executor.ToolCallObserver(Ctx)` are generic over the consumer's context type. The `*anyopaque` + `@ptrCast` vtable is replaced by `*Ctx` + typed callback functions. `StreamContext(L)` and `ExecutorBridge(L)` are generic over the listener type. The sole remaining `@ptrCast` is `BashApproval` (1 site, deferred because making it generic would require `Agent` itself to be generic).

**Manual compaction trigger pattern.** `Agent.forceCompact()` is a synchronous public method that runs the full compaction cycle (snapshot → summarize → swap) and returns `!Event.HistoryCompacted` with token counts before/after. Unlike the automatic path (which runs between turns inside `agent.run()`), this is callable from the TUI command handler. The caller is responsible for turn-safety: check `app.thread.turn.isActive()` before calling. Errors are surfaced to the user via transcript notices rather than swallowed in logs.

**Config layering pattern.** Nova merges global (`~/.config/nova/config.json`), project (`.nova/config.json`), and env-var overlays into `cached_config`. **Schema v2**: JSON keys are camelCase (`defaultModel`, `baseURL`, `mcpServers`, `useResponsesEndpoint`, `enableThinking`, `systemPrompt`, `bashClassifierUrl`); legacy snake_case keys are accepted at parse time for backward compatibility. `version` is a semver string (`"2.0.0"`); legacy integer `1` normalizes to `"1.0.0"`. `applyConfigOverlay` uses an if/else structure: `model_selection` is canonical; legacy fields are fallback. `syncModelSelectionFromLegacy` mirrors legacy changes back into `target.model_selection` via `|*ms|` pointer capture. `serialize` skips `api_key` (lives in `auth.json`) and writes camelCase keys. `saveSettings` writes only settings-managed fields — never provider/model. At connection time, `tryAttachOpenAiCompatibleFromConfig` and `tryAttachOpenAiResponsesFromConfig` resolve an empty `ms.base_url` through `provider.defaultBaseUrl()` so client `init` never sees an empty URL.

**Context & compaction config pattern.** `Config.context: ContextSettings` carries `overrideContextWindow`, `maxOutputTokens`, and `compaction: CompactionSettings` (auto, threshold, bufferTokens, keepRecentTokens). The runtime stores `context_settings` and passes `override_context_window` to `compaction.contextWindowTokens()` at client attach time. The agent stores `compaction_settings` and passes `threshold` to `shouldStartSummary`/`shouldSwap` and `keep_recent_tokens` to `keepRecentTokens`. When `auto` is false, `maybeCompact` returns immediately. The swap watermark is `threshold + 0.20` (capped at 0.95). JSON Schema for editor autocompletion lives at `schema/config.schema.json`.

## Zig Development

Use `zigdoc` to discover APIs before coding.

```bash
zigdoc std.fs
zigdoc std.posix.getuid
zigdoc vaxis.Window
```

## Current Zig Patterns

**ArrayList:**

```zig
var list: std.ArrayList(u32) = .empty;
defer list.deinit(allocator);
try list.append(allocator, 42);
```

**HashMap/StringHashMap:**

```zig
var map: std.StringHashMapUnmanaged(u32) = .empty;
defer map.deinit(allocator);
try map.put(allocator, "key", 42);
```

**stdout/stderr writer:**

```zig
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
defer writer.interface.flush() catch {};
try writer.interface.print("hello {s}\n", .{"world"});
```

**build.zig executable:**

```zig
b.addExecutable(.{
    .name = "foo",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

**JSON writing:**

```zig
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
defer writer.interface.flush() catch {};

var jw: std.json.Stringify = .{
    .writer = &writer.interface,
    .options = .{ .whitespace = .indent_2 },
};
try jw.write(my_struct);
```

**Allocating writer:**

```zig
var writer: std.Io.Writer.Allocating = .init(allocator);
defer writer.deinit();
try writer.writer.print("hello {s}", .{"world"});
const output = try writer.toOwnedSlice();
```

## Zig Style

- `camelCase` for functions and methods
- lower-case `snake_case` for variables, parameters, and constants
- `PascalCase` for types, structs, and enums
- prefer `const foo: Type = .{ .field = value };` over `const foo = Type{ .field = value };`
- preferred file order: `//!` module doc comment, `const Self = @This();`, imports, `const log = std.log.scoped(...)`
- pass allocators explicitly; use `errdefer` for cleanup on error
- keep tests inline with the code they cover; register them in `src/main.zig`

## Safety

- Add assertions at API boundaries and state transitions; avoid trivial assertions.
- Keep functions small; push pure computation into helpers.
- Comments should explain why, not what.
- **POSIX Environment Access:** Never index `std.c.environ` directly in loops. In Zig 0.16 on POSIX, `std.c.environ` is `[*:null]?[*:0]u8`. Use `const env_slice = std.mem.span(std.c.environ);` and pass to `std.process.Environ.createMap(.{ .block = .{ .slice = env_slice } }, gpa)` to prevent null-pointer segfaults in multi-threaded contexts.
- **Models.dev Registry Allocations:** `modelsdev.Registry` string storage uses an `ArrayList(u8)`. To prevent dangling slice pointers when building or merging providers, accumulate string offsets via `StringRef` (`start`, `len`) and resolve slice pointers only after all string appends complete.
- **Dynamic Context Compaction:** Never hardcode fixed context retention budgets (e.g. 20,000 tokens) when compacting history. Use `compaction.keepRecentTokens(context_window)` so small-context models (8K/16K/32K) keep a scaled history window (%35 max 20,000) and can always compact below their swap watermark.
- **Streaming SSE Tool Call Deduplication & Parallel Remap:** In `src/ai/openai_compatible.zig`, tool call names and IDs are atomic in streaming — first complete value wins; subsequent deltas are ignored. This deduplicates repeated names (the `bashbash` fix) and prevents cross-tool concatenation. Some providers reuse `index: 0` for all parallel tool calls; `ToolCallStream` detects this by comparing tool-call IDs (always unique). When a new ID arrives at an occupied logical index, the call is forked into a new physical builder slot. Argument continuation deltas (no ID) route through the remap to the correct slot. Limitation: if the provider omits IDs entirely, collision detection is impossible and the second call is lost (first writer wins for the name).
- **Bash tool safety:** `validateCwd` in `src/tools/bash.zig` resolves the working directory with `std.fs.path.resolve` and asserts it stays within the project root, preventing absolute-path escape or `../` traversal. `namedTempPath` asserts no path separators; temp files use hex-only names. When the remote classifier is unreachable, `src/tools/bash_safety.zig` falls back to a local pattern matcher for obviously destructive commands.
- **Lua C-stack manipulation:** When building a Lua table of results from Zig (e.g. `walkAndSearch` in `plugin_api.zig`), the results table must stay on top of the stack across every entry. The correct idiom is `newTable()` (push table) → push entry fields + `lua_setfield(L, -2, ...)` → `lua_rawseti(L, -2, n)` (pops the entry, leaving the table on top). A stray extra push before `lua_rawseti` with the wrong table index (`-3` instead of `-2`) writes the bare integer into `results[n]` instead of the entry table and **leaks one table per match** onto the stack. Annotate the expected stack layout (`[ ... | results_table ]`, `[ ... | results_table | entry ]`) at each push/pop site so the balance is auditable.
- **Glob/pattern slicing:** Never unconditionally slice byte 0 off a user-supplied pattern (`fp[1..]`). When the pattern is empty, `fp[1..0]` is an out-of-bounds slice → Zig panic → `SIGABRT`. Lua treats `""` as truthy, so a plugin forwarding `file_pattern = ""` (e.g. `project-info`'s `list_project_files({ pattern = "" })`) reaches this path directly. Extract suffix logic into a pure `fileNameMatches(name, pattern)` helper that handles empty (match-all), `"*x"` (strip leading star), and bare-suffix cases, and unit-test the empty case explicitly.

## Verifying

Run:

- `zig fmt`
- `zig build test`

## Gotchas

- **`std.atomic.Mutex` is a spinlock.** In Zig 0.16, `std.atomic.Mutex` busy-waits and pegs the CPU on multi-core (80% at idle). Always use `std.Io.Mutex` / `std.Io.Condition` (paired via `static_thread_pool` or similar). All existing sites have been migrated — do not reintroduce `std.atomic.Mutex`.

- **`postAgentEvent` owns the event.** It frees the event's data internally on error. Callers must NOT free `message_text` or `event_ptr` in catch blocks or before `return error.TurnCancelled` — doing so causes a double-free (errdefer repeats the cleanup).

## Known Issues

- **Session resume segfault (null `model_id`).** Crash at `src/ai/openai_compatible.zig:59` (`gpa.dupe(u8, config.model)`) when `summary.model_id` is null and flows into `ModelSelection.custom.model.id` (non-optional `[]u8`). Resume chain: `root.run` → `initResume` → `initSession` → `applyFromConfig` → `tryAttachOpenAiCompatibleFromConfig` → `attachOpenAiCompatibleClient` → `Client.init`. Guarded at two entry points: `runtime.applyFromConfig` skips attachment when `model_id.len == 0`, and `tui.applySelectedModel` returns `error.EmptyModelId` before constructing the selection. Always use a real early return for these guards, never `std.debug.assert` — `unreachable` is UB in ReleaseFast (the install target) and would not protect that build. Previous fix: `da7c761` ("guard empty model_id on resume").

- **Debug prints masking segfaults.** Adding `std.debug.print` can change failure mode from segfault to a downstream error (e.g., `session.resume.failed err=Sqlite`), suggesting heap corruption or memory layout sensitivity. When this happens, suspect use-after-free or double-free in the path between the original crash site and the new error.

- **ReleaseFast debugging.** Use `std.debug.print` instead of `std.log.debug` — ReleaseFast strips log levels, so `std.log.debug` calls are no-ops.

- **Session config copy semantics.** `session_config` is a value-copy of `config`; union fields are shallow-copied. Mutating a union field on the copy does not affect the original.
