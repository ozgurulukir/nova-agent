# Nova Architecture

## LLM Gateway

Nova accepts any OpenAI-compatible endpoint (either `/completions` or `/responses`).

We try to normalise the request to a shape that is most compatible with the target provider.

## Agent Tools

Nova exposes the following tools:

- `bash`

`bash` has some middleware written for it that makes it friendlier for agent use. For example, large outputs from a `cat` command are written to a temp file and the agent is told the full is in that file if needed.

### Tool schema strict mode

Builtin and MCP tool schemas are serialized with OpenAI strict-mode semantics:

- `strict: true`
- Top-level `parameters` uses `additionalProperties: false`
- Optional fields carry `nullable: true` and emit `["<type>", "null"]` union arrays
- Nested free-form objects like `env` keep `additionalProperties: true`

The registry accessor `tools.registry()` is runtime-extensible; both the executor and the AI client adapters consume it to build the `tools` JSON payload sent on every request.

## Steering

Steering is done by enqueuing messages into a bounded queue. By default, the front of the queue is popped and appended to the conversation after the agent's turn is finished. You can also choose to _steer_ instead and send the queued message after the next tool call is done. If the agent stops and there are still messages in the queue we flush all the messages and append them into the conversation.

## Timeline

User's can branch off at any point in their conversation to pursue different paths and try different approaches. These are saved into the session and are resumable. When a branch occurs, we actually revert the entire project state to that point in time, not just the conversation. This is achieved via git shadow snapshots. User messages, assistant messages and even tool calls are all valid branching points. Once you're happy with a certain branch, you can `/save` it to commit to the working tree.

## Session Persistence

The session store (`sessions.sqlite`) records the active `model_provider` and `model_id` on every turn, **and on every mid-session model switch**. The picker (`tui.applySelectedModel`) calls `session_writer.updateModel(provider_name, model_id)` after attaching the new client, mirroring what `runtime.applyFromConfig` writes at session start. Without the picker write, `initResume` restored the stale creation-time model on restart instead of the last-used one. The write is best-effort (logged, never rolls back the applied switch) and gated by `AgentRuntime.session_writer_started` so TUI test harnesses that build a partial runtime with `session_writer = undefined` can still exercise the picker. On resume, Nova resolves the provider through two paths:

1. **Builtin providers**: resolved by enum label (`openai`, `openrouter`, etc.)
2. **Custom providers**: resolved by name from the `providers[]` config map, with `baseURL` pulled from the same entry

This means custom providers (e.g., `"qwen-cloud"` pointing to a DashScope endpoint) round-trip correctly across restarts: `defaultModel: "<provider-name>/<model-id>"` carries the user-chosen provider name as its prefix (there is no separate `provider` field in `config.json`), and the `providers[]` map supplies the `baseURL` for that name.

### Empty `base_url` resolution

When `model_selection` is synthesized from session metadata or legacy fields, its `base_url` may be an empty string. Two guards prevent this from crashing the model catalogue loader:

1. `collectConfiguredProviders` resolves an empty `base_url` through `provider.defaultBaseUrl()` before appending to the catalog job.
2. `loadConfigured` falls back to `provider.defaultBaseUrl()` if `configured.base_url` is empty, skipping the provider entirely if no default exists.

This ensures `listModels` never receives an empty URL, avoiding the `assert(base_url.len > 0)` panic on startup.

### Dynamic provider auth key resolution

Dynamic providers selected from models.dev store their API key in `auth.json` under the provider ID (e.g., `"stepfun-ai"`), not the enum label (`"openai_compatible"`). Two fields track the identity at runtime:

- `dynamic_provider_name`: human-readable display name (e.g., `"StepFun AI"`), used by the status bar
- `dynamic_provider_id`: the auth.json key (e.g., `"stepfun-ai"`), used for session resume and API key lookup

`updateCachedModelSelection` rebuilds `model_selection` as the `.custom` variant with `provider_name` set to `dynamic_provider_id` on selection, so `tryAttachOpenAiCompatibleFromConfig` looks up the correct auth.json entry on resume. `compatibleApiKey` also uses `dynamic_provider_id` directly for the lookup, avoiding the fragile stash fallback.

### Restart catalog restore

Because `api_key` is never serialized (it lives in `auth.json`), the runtime stash is null after every restart. Two gates were relaxed so the dynamic provider's disk cache restores on the next `/models` open:

1. **`hasOpenAICompatibleCredentials`** treats a typed `model_selection` carrying a non-empty `baseUrl()` as a sufficient credential signal (the real key is resolved from `auth.json` at fetch time). The legacy `base_url`+`api_key` stash path stays as a fallback for catalogue providers that have no `model_selection` yet.
2. **`shouldLoadConfiguredCompatibleCatalog`** resolves `base_url` from `model_selection.baseUrl()` when the legacy stash is null.

## Parallel

Subagent workflows are achieved by the `/parallel` command which creates a separate git worktree for your agent to work in. The TUI supports tiling so you can have multiple agents on the screen at any time. We call each tile a `lane`. The maximum number of lanes that can be active is currently 4, because that is the empirical limit for the mental load required to manage all agents effectively.

A lane starts on a random `nova/<hex>` branch. On its first prompt, the session's own model is asked (in parallel with the turn) for a descriptive branch name based on that prompt and the last few messages of the parent lane. When the answer lands, the branch is renamed in place (`nova/<name>`) and becomes the lane's label. If the request fails or the name is unusable, the hex branch simply stays.

## Bash auto-review

We have fine-tuned a ModernBERT base model on a corpus of over 3000 bash commands and classified each command as either safe or unsafe. We run this model on every bash tool call the agent makes, and if it's marked unsafe, we show a permission prompt to either approve or reject the call. Thanks to the efficient architecture of ModernBERT (i.e. Alternating Attention) and its small size the performance overhead of making these inference calls is negligible.

### Local safety fallback

When the remote classifier is unavailable (network error, service down), a local pattern matcher in `src/tools/bash_safety.zig` provides defense-in-depth. It flags obviously destructive commands:

- `rm -rf /`, `rm -rf /*`, `rm -rf --no-preserve-root /`
- Fork bombs (`:(){ :|:& };:`)
- Destructive `dd` to block devices (`of=/dev/sda`, `of=/boot/`, etc.)
- `mkfs` targeting `/dev/`
- Redirects into critical system paths (`/etc/`, `/boot/`, `/sys/`, `/proc/`, `/dev/sd*`)

The local matcher is intentionally conservative — it only catches clearly destructive patterns. The remote model is the primary classifier.

### Working directory validation

The `cwd` parameter in bash tool calls is validated against the project root in `src/tools/bash.zig` (`validateCwd`). The resolved path is normalized (resolving `..` and `.` segments) and checked to stay within the project root. This prevents the model from escaping the project via absolute paths like `/etc` or relative paths like `../../sensitive`.

### Temp file safety

Temporary log files use hex-only filenames (`nova-bash-<hex>.log` via `bytesToHex`), making path traversal impossible. The `namedTempPath` public API asserts that the provided name contains no path separators.

## Type System Discipline

Nova uses `union(enum)` instead of flat structs with optional fields wherever a value can be in one of several mutually-exclusive states. This makes illegal combinations unrepresentable at compile time — the compiler tells the next developer where to add a case when a new variant is introduced.

Key types following this pattern:

- `ai.ChatMessage` — `union(enum) { system, user, assistant, tool }` (tool carries non-optional `call_id`)
- `transcript.Message` — `union(enum)` with 10 variants + `Basic`/`ToolView` payload structs
- `config.McpServerConfig.transport` — `union(enum) { stdio, sse }`
- `mcp.McpClient` — `transport` + `lifecycle` unions for static config and runtime state
- `config.Config.model_selection: ?ModelSelection` — `union(enum) { builtin, custom }` typed view replacing 9 loose optional fields; builtin carries `Provider` enum, custom carries `provider_name`/`base_url`/`api_key`
- `agent.Listener(Ctx)` / `executor.ToolCallObserver(Ctx)` — generic typed callbacks replacing `*anyopaque` vtables

See `AGENTS.md` "Type System Discipline pattern" for the full list and construction patterns.

## Lua Plugin System

Nova supports extending its capabilities through Lua 5.4 plugins. The plugin system lives in `src/lua/` and provides:

- **Sandboxed runtime**: Each plugin runs in a restricted Lua environment with configurable permissions (file access, network, os.execute, etc.) and resource limits (instruction count, memory, timeout).
- **Plugin lifecycle**: Plugins are discovered from `~/.config/nova/plugins/` (global) and `.nova/plugins/` (project). Each plugin has a `plugin.lua` manifest and an `init.lua` entry point.
- **Event bus**: Plugins can subscribe to lifecycle events (`turn_started`, `tool_call_started`, etc.) via `nova.on()`.
- **Tool registration**: Plugins register tools via `nova.register_tool()` that appear alongside builtin and MCP tools.
- **Config integration**: Plugin settings are stored in `config.json` under the `plugins` key, following the same layered merge pattern as MCP servers.
- **Bytecode caching**: `State.dump()` and `State.loadBuffer()` enable caching compiled Lua bytecode to avoid re-parsing on reload.
- **TUI integration**: The `/plugins` command opens an overlay listing loaded plugins with their active/inactive status.

See `docs/plugins/` for the full plugin development guide, API reference, and example plugins.
