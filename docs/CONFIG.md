# Nova Agent Configuration Architecture & Guide

Nova Agent employs a layered, type-safe, XDG-compliant configuration system written in Zig 0.16. Configuration is stored as human-readable JSON files and supports field-level merging across four priority layers.

---

## Configuration Layer Hierarchy

Configuration values are resolved by merging four layers in order of increasing specificity (later layers override earlier layers):

```text
┌─────────────────────────────────────────────────────────────┐
│ 1. Built-in Defaults                                        │
└──────────────────────────────┬──────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Global Configuration                                     │
│    • ~/.config/nova/config.json  (XDG Standard)            │
└──────────────────────────────┬──────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Project-Local Configuration                              │
│    • <cwd>/.nova/config.json                                │
└──────────────────────────────┬──────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. Environment Variables                                    │
│    • OPENAI_MODEL, OPENAI_BASE_URL, OPENAI_API_KEY, etc.    │
└─────────────────────────────────────────────────────────────┘
```

1. **Built-in Defaults**: Fallback defaults compiled into the binary.
2. **Global Config**: User-wide preferences at `~/.config/nova/config.json` (or `$XDG_CONFIG_HOME/nova/config.json`).
3. **Project Config**: `<cwd>/.nova/config.json` for repository-specific overrides (e.g. project system prompt or local Ollama endpoints).
4. **Environment Variables**: Runtime overrides (e.g. `OPENAI_MODEL`, `OPENAI_API_KEY`).

---

## File Format & JSON Schema

All `config.json` files use formatted, 2-space indented JSON with semver version tagging. A machine-readable JSON Schema (Draft 2020-12) for editor autocompletion lives at [`schema/config.schema.json`](../schema/config.schema.json).

### Schema v2 (current)

JSON keys are **camelCase**. Legacy snake_case keys from schema v1 are still accepted at parse time for backward compatibility; `serialize` always writes camelCase.

```json
{
  "version": "2.0.0",
  "defaultModel": "ollama/llama3.1:8b",
  "baseURL": "http://localhost:11434",
  "useResponsesEndpoint": false,
  "strictOutputs": false,
  "systemPrompt": "Custom system prompt for this project...",
  "bashClassifierUrl": "http://localhost:8000/classify",
  "context": {
    "overrideContextWindow": 32000,
    "maxOutputTokens": 4096,
    "compaction": {
      "auto": true,
      "threshold": 0.75,
      "keepRecentTokens": 8000,
      "keepRecentToolTurns": 4,
      "historicalToolCapBytes": 1024
    }
  },
  "toast": {
    "enabled": true,
    "durationMs": 4000,
    "maxVisible": 3
  },
  "providers": {
    "openai": {
      "baseURL": "https://api.openai.com/v1",
      "models": {
        "gpt-4o": { "reasoningEffort": "high" }
      }
    },
    "ollama": {
      "baseURL": "http://localhost:11434",
      "models": {
        "llama3.1:8b": {}
      }
    }
  },
  "mcpServers": {
    "memory": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-memory"],
      "enabled": true
    }
  }
}
```

### Supported Fields

| Field                  | Type      | Description                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ---------------------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `version`              | `string`  | Semver schema version (currently `"2.0.0"`). Legacy integer `1` is normalized to `"1.0.0"` at parse time.                                                                                                                                                                                                                                                                                                                                              |
| `defaultModel`         | `string`  | Model selection in `<provider>/<model-id>` format (e.g., `"openai/gpt-5.5"`, `"ollama/llama3.1:8b"`, `"qwen-cloud/qwen3.7-plus"`). The provider part is split on the first `/`; model ids may contain further slashes (e.g., `"huggingface/meta-llama/Llama-3.1-8B"`). Both parts may contain `:`, `+`, `.`, `_`, and `-`. Custom provider names are supported. This is the **single source of truth** for provider identity — there is no separate `provider` field. Legacy key `model` is parsed for backward compatibility but is not schema-valid; new configs must use `defaultModel`. |
| `baseURL`              | `string`  | Custom API endpoint base URL. Must start with `http://` or `https://`. In memory, this may be `""` when synthesized from session metadata or legacy fields; it is resolved through the provider's default before any network request. Legacy key `base_url` is parsed for backward compatibility but is not schema-valid; new configs must use `baseURL`.                                                                                                                                                                          |
| `useResponsesEndpoint` | `boolean` | `true` to route via OpenAI Responses API instead of ChatCompletions. Legacy key `use_responses_endpoint` is parsed for backward compatibility but is not schema-valid; new configs must use `useResponsesEndpoint`.                                                                                                                                                                                                                                                                                                                             |
| ~~`enableThinking`~~   | ~~`boolean`~~ | **Removed.** Reasoning is controlled per-model via `providers.<name>.models.<id>.reasoningEffort` (see [Per-model settings](#per-model-settings)). The legacy key (`enableThinking` / `enable_thinking`) is still accepted at parse time but silently ignored, and dropped on the next save.                                                                                                                                                                                                                                   |
| `strictOutputs`        | `boolean` | `true` to send OpenAI strict structured-outputs mode (`"strict":true`, `additionalProperties:false`, all properties in `required`) in tool definitions. **Only works against the OpenAI API** — gateways (OpenRouter/Ollama/vLLM/Together) reject or silently break it, which disables function-calling (the model then emits tool calls as plain text). Defaults to `false` so tool-calling works everywhere. Enable only when talking directly to OpenAI. Legacy key `strict_outputs` is parsed for backward compatibility but is not schema-valid; new configs must use `strictOutputs`. |
| `systemPrompt`         | `string`  | Base system prompt template (max 10 000 chars). Legacy key `system_prompt` is parsed for backward compatibility but is not schema-valid; new configs must use `systemPrompt`.                                                                                                                                                                                                                                                                                                                                                           |
| `bashClassifierUrl`    | `string`  | ModernBERT classifier endpoint for shell command safety check. Legacy key `bash_classifier_url` is parsed for backward compatibility but is not schema-valid; new configs must use `bashClassifierUrl`.                                                                                                                                                                                                                                                                                                                                      |
| `toast`                | `object`  | Transient toast notifications (top-right TUI notices). See [Toast settings](#toast-settings).                                                                                                                                                                                                                                                                                                                                                          |
| `context`              | `object`  | Context window management and compaction policy. See [Context settings](#context-settings).                                                                                                                                                                                                                                                                                                                                                            |
| `mcpServers`           | `object`  | MCP server configurations (Claude Desktop format compatible). Legacy keys `mcp_servers` and `mcp` are parsed for backward compatibility but are not schema-valid; new configs must use `mcpServers`.                                                                                                                                                                                                                                                                                                                                   |
| `plugins`              | `object`  | Lua plugin configuration keyed by plugin name. Each entry controls whether the plugin is enabled and its custom settings (JSON string). Settings are passed to the plugin's Lua code via `plugin.get_config()`.                                                                                                                                                                                                                                        |
| `providers`            | `object`  | Per-provider configuration keyed by provider name. Accepts builtin labels and custom provider names (see below).                                                                                                                                                                                                                                                                                                                                       |

### Context & Compaction Settings

The `context` object controls context window management and automatic summarization:

| Field                                 | Type      | Default  | Description                                                                                                                                                  |
| ------------------------------------- | --------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `context.overrideContextWindow`       | `integer` | _(auto)_ | Explicit context window in tokens. Overrides the model catalogue lookup — useful for local Ollama/LMStudio models with non-standard windows. Minimum 1024.   |
| `context.maxOutputTokens`             | `integer` | _(auto)_ | Maximum tokens per single model generation turn.                                                                                                             |
| `context.maxConcurrentRequests`       | `integer` | `2`      | Cap on LLM requests in flight across ALL lanes at once. Each lane runs its own worker + HTTP client, so without this cap N active lanes fire N independent requests at the provider, which degrades or rate-limits the burst (every lane slows down together). Minimum 1 — a value of 0 would deadlock every request. Set `1` to serialize requests; raise it only if your provider handles more concurrent streams without degrading. |
| `context.disablePromptCache`          | `boolean` | `false`  | Disable provider prompt-caching fields entirely. When `true`, neither message-level `cache_control` (OpenRouter) nor top-level `prompt_cache_key` (OpenAI/OpenRouter) is emitted, in BOTH the chat-completions and Responses API clients, regardless of the resolved wire dialect. Use this for OpenRouter `:free` / gateway-fronted models (kimi, inclusionai/ling) that reject these fields with HTTP 400 — a 400 there kills the whole turn and surfaces as "the model can't call any tools." Nova also auto-recovers once via a cache-stripped retry (C2) when the 400 body mentions "cache", so setting this flag is the durable fix for a known-bad model. |
| `context.compaction.auto`             | `boolean` | `true`   | Enable automatic context compaction before reaching limits.                                                                                                  |
| `context.compaction.threshold`        | `number`  | `0.75`   | Fraction of context window (0.1–0.9) that triggers background summarization. The swap watermark is derived as `threshold + 0.20` (capped at 0.95); values above 0.9 are clamped at parse time so the swap watermark never falls below the start watermark. |
| `context.compaction.keepRecentTokens` | `integer` | `8000`   | Recent conversation tokens retained verbatim alongside the generated summary. Scaled down proportionally for small-context models (35% of window, min 1000). When real provider usage outruns the chars/4 estimate (CJK text), the budget is shrunk by the measured ratio so compaction still lands below the swap watermark. |
| `context.compaction.keepRecentToolTurns` | `integer` | `4`   | Number of most recent tool-result turns kept in full when assembling each prompt. Older tool results are pruned to `historicalToolCapBytes` with a `[... compacted to save context ...]` notice. Raise this when an agentic turn needs earlier tool outputs in full (e.g. multi-phase skills like `tci-bfg` that fire dozens of commands). Minimum 1 — a value of 0 would prune every tool result and break tool-calling. |
| `context.compaction.historicalToolCapBytes` | `integer` | `1024` | Byte cap applied to tool results older than `keepRecentToolTurns` — the head is kept followed by a `[... compacted to save context (was N bytes) ...]` notice. Raise for large command outputs the model must re-read later in the same turn. |

**Example — local Ollama with aggressive compaction and lenient tool-result pruning:**

```json
{
  "context": {
    "overrideContextWindow": 8192,
    "maxConcurrentRequests": 2,
    "compaction": {
      "threshold": 0.6,
      "keepRecentTokens": 3000,
      "keepRecentToolTurns": 12,
      "historicalToolCapBytes": 8192
    }
  }
}
```

### Toast Settings

The `toast` object controls transient notifications shown stacked in the top-right corner of the TUI. With the TUI running, `warn`+ log output routes to the toast bus **instead of stderr** — stderr writes land in the alternate screen and tear the rendered frame, so the toast overlay is the intended surface for operational warnings. The bus is generic: any subsystem (MCP, lanes, background jobs) can push a toast.

| Field                | Type      | Default     | Description                                                                                                                                                                                                                  |
| -------------------- | --------- | ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `toast.enabled`      | `boolean` | `true`      | Master switch. When `false`, no toasts are shown — `warn`+ output is dropped from the TUI. Set `NOVA_LOG_STDERR_LEVEL` to route it back to stderr. Also toggled live from the `/settings` General tab.                       |
| `toast.durationMs`   | `integer` | `4000`      | Auto-dismiss delay in milliseconds. Out-of-range values are **dropped** (left null) at parse time, not clamped — a typo can't produce a toast that never dismisses. Config-file only.                                         |
| `toast.maxVisible`   | `integer` | `3`         | Maximum toasts stacked at once. Out-of-range values are dropped at parse time. Config-file only.                                                                                                                             |
| `toast.position`     | `string`  | `top-right` | Corner position. **Reserved for future use** — only `top-right` is rendered today; other values are parsed and persisted but have no effect yet.                                                                            |

> [!NOTE]
> **Restoring the stderr channel.** When the TUI is up, `warn`+ logs go to the toast, not stderr. To keep full stderr output (e.g. for `nova 2> err.log` diagnostics), set `NOVA_LOG_STDERR_LEVEL` explicitly (`err`/`warn`/`info`/`debug`) — an explicit value sends output to **both** stderr and the toast, while leaving it unset sends `warn`+ to the toast only. Headless/test runs have no toast sink installed and keep stderr as before.

### Provider Configuration

Each entry in `providers` is keyed by provider name. Builtin labels (`openai`, `ollama`, `openrouter`, `cerebras`, `huggingface`, `nvidia_nim`, `opencode_zen`, `ollama_cloud`, `llama.cpp`, `anthropic`) are recognized and mapped to their typed enum. Any other key is treated as a **custom provider** using the OpenAI-compatible adapter — it appears in the `/connect` picker alongside builtins and models.dev providers.

| Field                          | Type       | Description                                                                                                                                                                                                                                                                                                                   |
| ------------------------------ | ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `baseURL`                      | `string`   | Custom base URL for this provider. Legacy key `base_url` is parsed for backward compatibility but is not schema-valid; new configs must use `baseURL`.                                                                                                                                                                                                                                                    |
| `models`                       | `object`   | Per-model overrides keyed by model id.                                                                                                                                                                                                                                                                                        |
| `models.<id>.reasoningEffort`  | `string`   | One of `default`, `minimal`, `low`, `none`, `medium`, `high`, `xhigh`. `default` sends no reasoning parameter (model decides); `none` disables thinking explicitly. Internally stored as a `ReasoningSetting` union: when unset in a config layer, the lower layer's value is preserved during merge; when set, it overrides. |
| `models.<id>.contextWindow`    | `integer`  | Context window size in tokens. Overrides the catalogue lookup; falls back to `context.overrideContextWindow`. Minimum 1024.                                                                                                                                                                                                   |
| `models.<id>.maxOutputTokens`  | `integer`  | Maximum tokens per generation turn. Sent as `max_tokens` in the request body; falls back to `context.maxOutputTokens`. Minimum 1.                                                                                                                                                                                             |
| `models.<id>.reasoningOptions` | `string[]` | Reasoning efforts this model supports (e.g. `["default", "low", "medium", "high", "xhigh"]`). The TUI model picker filters its reasoning cycle to this list. Empty or absent means all efforts are available.                                                                                                                 |

**Example — custom provider with per-model limits:**

```json
{
  "defaultModel": "qwen-cloud/qwen3.7-plus",
  "providers": {
    "qwen-cloud": {
      "baseURL": "https://dashscope.aliyuncs.com/compatible-mode/v1",
      "models": {
        "qwen3.7-plus": {
          "contextWindow": 131072,
          "maxOutputTokens": 16384
        }
      }
    }
  }
}
```

**Provider merge order in `/connect`:** builtin catalogue → models.dev registry (overrides builtins with same id) → config providers (overrides everything with same name, **except** entries already covered by the models.dev registry). All three sources share the same display surface.

> [!NOTE]
> **Custom provider session persistence**: Custom provider names (e.g., `"qwen-cloud"`) are preserved in `config.json` via the `defaultModel` field (e.g., `"qwen-cloud/qwen3.7-plus"`) and the `providers` map. On restart, Nova resolves the provider from `defaultModel`, hydrates `baseURL` from the `providers` map via `hydrateActiveModel`, and looks up the API key in `auth.json` using the provider name.
>
> **Dynamic providers (models.dev)** persist their identity through `defaultModel: "provider-id/model-id"` (e.g., `"stepfun-ai/step-3.7-flash"`). The `providers` map stores the `baseURL` and per-model metadata. Runtime-only fields (`dynamic_provider_id`, `dynamic_provider_name`) are never serialized; after restart, all rehydration paths fall back to the serialized `provider_name` from `defaultModel` and the `providers` map. `hydrateActiveModel` includes a recovery fallback for configs written before the `provider_name` serialization fix (where `provider_name` was the generic `"openai_compatible"` label).

### MCP Server Configuration

Each entry in `mcpServers` is keyed by server name:

| Field     | Type       | Description                                                                                                        |
| --------- | ---------- | ------------------------------------------------------------------------------------------------------------------ |
| `command` | `string`   | Executable for stdio transport.                                                                                    |
| `args`    | `string[]` | Command arguments for stdio transport.                                                                             |
| `url`     | `string`   | Endpoint URL for remote Streamable HTTP transport.                                                                 |
| `headers` | `object`   | Extra HTTP headers for remote servers (string values), e.g. API keys for header-auth servers like Context7.        |
| `type`    | `string`   | Optional transport discriminator (`"stdio"`/`"remote"`) for compatibility with other MCP clients; Nova ignores it. |
| `enabled` | `boolean`  | Whether this server is active (default `true`).                                                                    |

A server is either stdio (`command` + `args`) or remote (`url`), never both. Misconfigured entries are caught at parse time.

`command`, `args`, `url`, and `headers` values support `{env:VAR}` placeholders, expanded against the process environment when the server connects — keep secrets out of `config.json` (an unset variable expands to an empty string and logs a warning):

```json
"tavily": {
  "url": "https://mcp.tavily.com/mcp/?tavilyApiKey={env:TAVILY_API_KEY}"
},
"context7": {
  "url": "https://mcp.context7.com/mcp",
  "headers": { "CONTEXT7_API_KEY": "{env:CONTEXT7_API_KEY}" }
}
```

> [!IMPORTANT]
> **Secrets are never written to config.json.** Placeholders are kept verbatim in the parsed config and resolved only at connect time (into an in-memory copy held by the MCP client). When Nova rewrites `config.json` it writes the `{env:VAR}` placeholder back, never the resolved value.

> [!NOTE]
> **Adding servers from the TUI**: the `/mcp` overlay's `a` (add) key connects a remote server by URL for the current session only. Such servers are **runtime-only** — they are not written to `config.json` and do not survive a restart. Add them here by hand to make them permanent. See [MCP Integration](MCP.md) for details.

> [!IMPORTANT]
> **API Keys Security Invariant**: API keys (`api_key`) are **NEVER** serialized into `config.json`. API keys are stored separately in `~/.config/nova/auth.json` with strict file permissions (`0o600`).

### Plugin Configuration

Each entry in `plugins` is keyed by plugin name (matching the plugin's manifest `name` field):

| Field      | Type      | Description                                                                                             |
| ---------- | --------- | ------------------------------------------------------------------------------------------------------- |
| `enabled`  | `boolean` | Whether this plugin is active (default `true`).                                                         |
| `settings` | `string`  | Plugin-specific settings as a JSON object string (max 65536 chars). The plugin's Lua code parses this.   |

**Example — configuring the custom-search plugin:**

```json
{
  "plugins": {
    "custom-search": {
      "enabled": true,
      "settings": "{\"max_results\":20,\"case_sensitive\":true,\"default_pattern\":\"*.zig\"}"
    }
  }
}
```

Settings are opaque to the config system — the plugin's Lua code is responsible for parsing and validating its own settings via `plugin.get_config()`. See `docs/plugins/` for the full plugin development guide.

> [!NOTE]
> **Typed Model Selection**: The in-memory `Config` struct carries a `model_selection: ?ModelSelection` typed view. `ModelSelection` is `union(enum) { builtin, custom }` — builtin providers carry `provider: Provider` + `provider_name`; custom providers carry `provider_name`, `base_url`, `api_key`. Optional settings (`use_responses_endpoint`, `system_prompt`, `bash_classifier_url`) live on both variants. Callers use typed accessors (`provider()`, `providerName()`, `model()`, `baseUrl()`, `apiKey()`, `useResponsesEndpoint()`, `systemPrompt()`, `bashClassifierUrl()`) so builtin/custom differences are hidden. Reasoning effort is **not** a selection-level boolean — it lives on the model (`Model.reasoning: ReasoningSetting`), populated from `providers.<name>.models.<id>.reasoningEffort`. The `strict_outputs` setting is **not** model-scoped — it stays on `Config` (API-level) and is read directly where the client is attached. `parseObject` only populates `model_selection` when all required fields are present — since `api_key` is never serialized to config.json (it lives in `auth.json`), disk-loaded configs **never** have `model_selection`. All rehydration paths fall back to the legacy fields (`provider`, `model`, `base_url`, `provider_name`), which ARE populated from `defaultModel` and `hydrateActiveModel`.

---

## Backward Compatibility (Schema v1 → v2)

Configs written by older Nova versions (schema v1, snake_case keys, integer version) are fully readable:

| v1 key                     | v2 key                   | Status                                                                                                                     |
| -------------------------- | ------------------------ | -------------------------------------------------------------------------------------------------------------------------- |
| `"version": 1`             | `"version": "2.0.0"`     | Integer normalized to semver at parse                                                                                      |
| `"model"`                  | `"defaultModel"`         | Both accepted; v2 written on save                                                                                          |
| `"provider"`               | _(removed)_              | Was write-only and redundant with `defaultModel`; no longer serialized. Still accepted at parse time if present (ignored). |
| `"base_url"`               | `"baseURL"`              | Both accepted; v2 written on save                                                                                          |
| `"use_responses_endpoint"` | `"useResponsesEndpoint"` | Both accepted; v2 written on save                                                                                          |
| `"enable_thinking"`        | _(removed)_              | Accepted but ignored (reasoning is per-model `reasoningEffort`); dropped on next save                                       |
| `"strict_outputs"`         | `"strictOutputs"`        | Both accepted; v2 written on save                                                                                          |
| `"system_prompt"`          | `"systemPrompt"`         | Both accepted; v2 written on save                                                                                          |
| `"bash_classifier_url"`    | `"bashClassifierUrl"`    | Both accepted; v2 written on save                                                                                          |
| `"mcp_servers"` / `"mcp"`  | `"mcpServers"`           | All three accepted; v2 written on save                                                                                     |

When both camelCase and snake_case keys are present, **camelCase wins**.

> **Schema validity vs parse acceptance:** Nova parses these v1 snake_case keys for backward compatibility (the table above), but they are **not schema-valid** against [`schema/config.schema.json`](../schema/config.schema.json) (`additionalProperties: false`). A strict schema validator rejects them; Nova's own parser accepts them and rewrites them as camelCase on the next save. Write new configs in camelCase.

---

## Environment Variables

| Variable                      | Description                           | Example                                  |
| ----------------------------- | ------------------------------------- | ---------------------------------------- |
| `OPENAI_MODEL`                | Sets provider and model selection     | `openrouter/anthropic/claude-3.7-sonnet` |
| `OPENAI_BASE_URL`             | Overrides active provider base URL    | `https://openrouter.ai/api`              |
| `OPENAI_API_KEY`              | Sets runtime API key                  | `sk-or-v1-...`                           |
| `NOVA_USE_RESPONSES_ENDPOINT` | Sets Responses endpoint routing       | `true` or `1`                            |
| `NOVA_STRICT_OUTPUTS`         | Sets OpenAI strict structured-outputs mode (gateway-incompatible) | `true` or `1`                            |
| `NOVA_BASH_CLASSIFIER_URL`    | Sets ModernBERT safety classifier URL | `http://localhost:8000`                  |
| `NOVA_LOG_FILE`               | Path to the log file (path max 1024 bytes); defaults to `~/.config/nova/nova.log` | `/tmp/nova.log` |
| `NOVA_LOG_STDERR_LEVEL`       | Min level for the stderr sink (`err`\|`warn`\|`info`\|`debug`, case-insensitive). Default `warn` in release, `err` in debug. When the TUI is up, setting this **also** restores `warn`+ output to stderr (otherwise it goes to the toast). | `debug` |
| `NOVA_LOG_MAX_BYTES`          | Max log file size before rotation (default 10 MB). On launch, if the existing log exceeds this, `nova.log` is renamed to `nova.log.1` and a fresh file starts. | `5242880` |
| `XDG_CONFIG_HOME`             | Custom XDG configuration root         | `/home/user/.config`                     |

---

## Persistence & Atomic Writes

1. **Atomic File Writes**: Config updates are written to a temporary file (`config.json.tmp`) before atomic renaming (`rename`), preventing corrupt configurations if process termination occurs mid-write.
2. **Directory Auto-Creation**: Parent directories (`~/.config/nova` or `.nova`) are created automatically if missing.

---

## Managing Configuration in TUI

You can view and edit settings directly inside Nova TUI:

- Press **Ctrl+S** or run `/settings` to open the settings interface.
- Navigate tabs using `Left`/`Right` arrows.
- Save changes using **Ctrl+S** to persist to `~/.config/nova/config.json`.
