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
  "theme": "cappuccino",
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
| `bashClassifierUrl`    | `string`  | External classifier endpoint for shell command safety check (e.g. `http://127.0.0.1:8765/classify`). When omitted or null, Nova uses its built-in safety rules. Legacy key `bash_classifier_url` is parsed for backward compatibility but is not schema-valid; new configs must use `bashClassifierUrl`. |
| `theme`                | `string`  | Name of the color theme for the TUI. `default` preserves the classic look; the other builtin themes are `cappuccino` (Catppuccin Mocha), `tokyo_night` (Tokyo Night), `dracula` (Dracula), `nord` (Nord), and `gruvbox_dark` (Gruvbox Dark). Custom theme slugs loaded from the themes directory are also valid. Unknown or empty names fall back to `default` at resolve time; absent = `default`. The builtin themes are compiled in — a new builtin theme is added to `src/tui/style.zig`. No legacy snake_case key or environment variable exists for this field. |
| `tui`                  | `object`  | TUI appearance, live preview, picker, multi-lane split layout, and status-bar telemetry settings. See [TUI Theme & Search Ergonomics](#tui-theme--search-ergonomics) and [TUI Layout & Telemetry](#tui-layout--telemetry).                                                                                                                                                                                                        |
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
| `context.toolCallLimitPerTurn`        | `integer` | `100`    | Upper bound on LLM→tool iterations (one assistant batch of tool calls = one iteration) within a single turn — the runaway-loop guard. Accepted range 1–1000; out-of-range values are dropped and the default is used. Raise for deep refactors or long migration loops that legitimately need more batches. The legacy snake_case spelling `tool_call_limit_per_turn` is parsed for compat but not schema-valid. |
| `context.softStopOnToolCallLimit`     | `boolean` | `true`   | When `true`, reaching `toolCallLimitPerTurn` does NOT fail the turn: the loop exits cleanly, queued user messages are delivered into history (a queued "continue" is never swallowed), a `[nova]` continuation hint is left as a trailing user message so the next prompt resumes seamlessly, and the TUI renders a budget notice row. When `false`, behavior matches previous releases: the turn ends with a `ToolCallLimit` failure. Scripted/headless users who grep for that failure should pin `false`. |
| `context.compaction.auto`             | `boolean` | `true`   | Enable automatic context compaction before reaching limits.                                                                                                  |
| `context.compaction.threshold`        | `number`  | `0.75`   | Fraction of context window (0.1–0.9) that triggers background summarization. The swap watermark is derived as `threshold + 0.20` (capped at 0.95); values above 0.9 are clamped at parse time so the swap watermark never falls below the start watermark. |
| `context.compaction.keepRecentTokens` | `integer` | `8000`   | Recent conversation tokens retained verbatim alongside the generated summary. Scaled down proportionally for small-context models (35% of window, min 1000). When real provider usage outruns the chars/4 estimate (CJK text), the budget is shrunk by the measured ratio so compaction still lands below the swap watermark. |
| `context.compaction.keepRecentToolTurns` | `integer` | `4`   | Number of most recent tool-result turns kept in full when assembling each prompt. Older tool results are pruned to `historicalToolCapBytes` with a `[... N of M bytes elided to save context ...]` notice. Raise this when an agentic turn needs earlier tool outputs in full (e.g. multi-phase skills like `tci-bfg` that fire dozens of commands). Minimum 1 — a value of 0 would prune every tool result and break tool-calling. |
| `context.compaction.historicalToolCapBytes` | `integer` | `1024` | Byte cap applied to tool results older than `keepRecentToolTurns` — a head+tail sandwich (first half + last half of the budget, joined by `common.elideMiddle`) keeps both the start and the load-bearing conclusion (errors, results, status) of a command output. Raise for large command outputs the model must re-read later in the same turn. |

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

### TUI Theme

The `theme` field selects a runtime color theme for the TUI at startup. The builtin themes are compiled into the binary (`src/tui/style.zig`):

| Field   | Type     | Description                                                                                           |
| ------- | -------- | ----------------------------------------------------------------------------------------------------- |
| `theme` | `string` | `default` (classic look), `cappuccino` (Catppuccin Mocha), `tokyo_night` (Tokyo Night), `dracula` (Dracula), `nord` (Nord), `gruvbox_dark` (Gruvbox Dark). Unknown or empty names fall back to `default` at resolve time; absent = `default`. |

When changing themes dynamically in the TUI via `/theme <name>` or the interactive `/theme` picker:
- If the active project configuration (`<cwd>/.nova/config.json`) defines a `theme`, the new choice persists to the project configuration via `mergeAndWriteProject`.
- Otherwise, the theme persists to the user's global configuration (`~/.config/nova/config.json`) via `mergeAndWriteGlobal`.
- Unknown, empty, or typoed theme names fall back to `default` and display a notice in the transcript (`Theme '<name>' not found; using default`). If writing configuration to disk fails, the live session still switches theme and a `(not saved)` notice is appended.

### TUI Theme & Search Ergonomics

The `tui` object controls live theme preview, custom-theme discovery, and fuzzy-match highlighting in the search pickers:

| Field                     | Type      | Default    | Description                                                                                                                                                                                                                                                        |
| ------------------------- | --------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `tui.themeLivePreview`    | `boolean` | `true`     | Recolor the UI live while browsing themes in the `/theme` picker. `Esc` reverts to the pre-open theme; `Enter` commits and persists.                                                                                                                               |
| `tui.customThemesDir`     | `string`  | _(none)_   | Optional directory containing user theme JSON files. When set, it **replaces** the default scan of `~/.config/nova/themes/` and `.nova/themes/` — only this directory is scanned.                                                                                  |
| `tui.fuzzyHighlight`      | `boolean` | `true`     | Highlight matching characters in the search pickers (`@` mention, `/model`, `/resume`, `/theme`, `/command`).                                                                                                                                                      |
| `tui.fuzzyHighlightStyle` | `string`  | `accent`   | Style of matched runes: `accent` (the theme's accent orange), `bold`, or `underline`.                                                                                                                                                                              |
| `theme`                   | `string`  | `default`  | Active theme name. Any custom theme slug loaded from the themes directory resolves at startup and in the `/theme` picker. See [TUI Theme](#tui-theme).                                                                                                              |

### TUI Layout & Telemetry

The `tui` object also controls the multi-lane split layout and the status-bar token-velocity / context-meter telemetry:

| Field                        | Type      | Default | Description                                                                                                                                                                                                                                                           |
| ---------------------------- | --------- | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tui.splitMode`              | `string`  | `dual`  | Split layout mode when multiple lanes are open: `"dual"` (1:1 full-height driver + focused worker), `"grid"` (2x2 tile of all lanes), `"tab"` (single active-lane pane).                                                                                              |
| `tui.minSplitWidth`          | `integer` | `140`   | Minimum terminal column width required to trigger a split layout. Below this, the layout collapses to a single pane. Clamped to `[80, 500]` at parse.                                                                                                                 |
| `tui.highlightFocusedBorder` | `boolean` | `true`  | Render a high-contrast accent border around the focused split column.                                                                                                                                                                                                 |
| `tui.showTokenVelocity`      | `boolean` | `true`  | Show the real-time streaming token velocity gauge (`⚡ 58.4 tok/s`) in the status bar. **This is a `chars/4` byte estimate**, not an exact token count — it undercounts CJK (~1.5 chars/token) and overcounts punctuation.                                              |
| `tui.showContextMeter`       | `boolean` | `true`  | Display the visual context-window capacity meter (`[███████░░░] 75% (96.0k/128k)`) in the status bar, colored green/amber/red by usage.                                                                                                                                |
| `tui.velocitySmoothingAlpha` | `number`  | `0.35`  | Exponential-moving-average smoothing coefficient for the token velocity gauge. Clamped to `[0.05, 1.0]` at parse.                                                                                                                                                     |
| `tui.contextThresholdWarn`   | `number`  | `0.70`  | Context usage fraction that transitions the meter to amber warning. Clamped to `[0.1, 0.9]` at parse.                                                                                                                                                                |
| `tui.contextThresholdAlert`  | `number`  | `0.85`  | Context usage fraction that transitions the meter to red alert. Clamped to `[0.2, 0.99]` at parse.                                                                                                                                                                   |

**Keybindings:**

| Keybinding            | Scope            | Action                                                                                                    |
| --------------------- | ---------------- | --------------------------------------------------------------------------------------------------------- |
| `Ctrl+W`              | Global (normal)  | Cycle split layout: `dual` → `grid` → `tab` → `dual`.                                                     |
| `Ctrl+L`              | Split Mode       | Cycle which worker lane occupies the right pane in `dual`; falls back to the mode cycle in `grid`/`tab`.   |
| `Alt+Right` / `Alt+Left` | Split Mode (`dual`) | Cycle which worker lane occupies the right pane: `Alt+Right` = next, `Alt+Left` = previous (wrapping within the worker lanes). The driver is always the left pane; input routing stays with it. |
| Mouse click on a pane | Split Mode (`dual`) | Focus the clicked worker column (sets the focused worker in `dual`).                                        |

> [!NOTE]
> `Alt+Tab` is **not** a Nova binding — terminals never deliver the OS-level window-switch key. Per-pane `PageUp`/`PageDown` transcript scrolling is **deferred** (per-lane scroll state does not exist yet). The velocity gauge is a `chars/4` **estimate** (the compaction SSOT heuristic), not an exact token count.

**Custom theme JSON format.** Drop a `*.json` file into `~/.config/nova/themes/` (or `.nova/themes/`, or the directory named by `tui.customThemesDir`). Each file is a flat object with a `name` plus the 18 `Rgb` `[r,g,b]` arrays matching the builtin theme slots (`thinking_blue`, `user_yellow`, `success_green`, `failure_red`, `accent_orange`, `skill_purple`, `lane_pink`, `muted_gray`, `selection_bg`, `amber_yellow`, `white`, `code_blue`, `faint_add_bg`, `faint_del_bg`, `body`, `background`, `blackhole_orange`, `markdown_heading`):

```json
{
  "name": "my_theme",
  "thinking_blue": [96, 165, 250],
  "user_yellow": [212, 175, 55],
  "success_green": [34, 197, 94],
  "failure_red": [239, 68, 68],
  "accent_orange": [249, 115, 22],
  "skill_purple": [168, 85, 247],
  "lane_pink": [244, 114, 182],
  "muted_gray": [138, 138, 138],
  "selection_bg": [38, 38, 38],
  "amber_yellow": [245, 158, 11],
  "white": [255, 255, 255],
  "code_blue": [147, 197, 253],
  "faint_add_bg": [22, 43, 30],
  "faint_del_bg": [52, 27, 27],
  "body": [255, 255, 255],
  "background": [17, 17, 20],
  "blackhole_orange": [255, 106, 61],
  "markdown_heading": [252, 211, 77]
}
```

A theme is rejected (and skipped) if it fails validation parity with the builtin suite: body/background WCAG contrast below 4.5:1, or a `selection_bg`/`background` channel delta below 20 (a selected picker row must stay visible against a coincident card). Missing themes directories are a no-op, not an error.

> [!NOTE]
> **`tui.customThemesDir` replaces the default scan.** When set, only that directory is scanned for custom themes; `~/.config/nova/themes/` and `.nova/themes/` are ignored. An explicitly-set path means "use this location", not "also scan the defaults".


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

`command`, `args`, `url`, and `headers` values support `{env:VAR}` placeholders, expanded against the process environment at connect time. Because an unset variable expands to an empty string (with a warning), this is how you keep API keys and tokens out of `config.json`. The expansion mechanics and the secrets invariant are the authoritative subject of the [MCP Integration Guide](MCP.md#environment-variable-expansion-envvar).

> [!NOTE]
> **Adding servers from the TUI**: the `/mcp` overlay's `a` (add) key connects a remote server by URL for the current session only. Such servers are **runtime-only** — they are not written to `config.json` and do not survive a restart. Add them here by hand to make them permanent. See [MCP Integration](MCP.md) for details.

> [!IMPORTANT]
> **API Keys Security Invariant**: API keys (`api_key`) are **NEVER** serialized into `config.json`. API keys are stored separately in `~/.config/nova/auth.json` with strict file permissions (`0o600`).

### Plugin Configuration

Each entry in `plugins` is keyed by plugin name (matching the plugin's manifest `name` field):

| Field      | Type                | Description                                                                                              |
| ---------- | ------------------- | -------------------------------------------------------------------------------------------------------- |
| `enabled`  | `boolean`           | Whether this plugin is loaded (default `true`). Applied at App start — restart Nova to change it.        |
| `settings` | `string` or `object`| Plugin-specific settings as a JSON object — either an escaped JSON string or an inline JSON object. The plugin's Lua code reads it via `plugin.get_config()`. |

**Example — inline-object form (preferred for readability):**

```json
{
  "plugins": {
    "my-search": {
      "enabled": true,
      "settings": { "max_results": 20, "case_sensitive": true, "default_pattern": "*.zig" }
    }
  }
}
```

**Example — escaped-string form (equivalent):**

```json
{
  "plugins": {
    "my-search": {
      "enabled": true,
      "settings": "{\"max_results\":20,\"case_sensitive\":true,\"default_pattern\":\"*.zig\"}"
    }
  }
}
```

Both forms reach the plugin identically. Settings are opaque to the config
system — the plugin's Lua code is responsible for validating its own settings
via `plugin.get_config()`, which returns a fresh table per call (or `nil`
when unconfigured). `enabled: false` skips loading the plugin entirely.
Plugin config is read once at App start; there is no hot reload — restart
Nova to apply changes. See `docs/plugins/` for the full plugin development guide.

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
| `NOVA_BASH_CLASSIFIER_URL`    | Sets external safety classifier URL   | `http://localhost:8765/classify`         |
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
