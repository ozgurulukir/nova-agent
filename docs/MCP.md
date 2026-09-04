# Model Context Protocol (MCP) Integration Guide

Nova Agent features production-grade support for the **Model Context Protocol (MCP)**,
allowing your LLM models to dynamically discover and invoke external tools, databases,
APIs, and file services.

---

## 1. Overview & Transports

Nova Agent supports two standard MCP transports:

1. **Stdio (`stdio`)**: Child processes launched locally by Nova Agent (e.g. via `npx`,
   `python`, `uv`, or precompiled binaries).
2. **Streamable HTTP (`sse`)**: Remote MCP servers reached over HTTP. Each JSON-RPC
   request is a `POST` with `Accept: application/json, text/event-stream`; the response
   is either a single `application/json` body or a `text/event-stream` searched for the
   matching response id. Sessions are tracked via the `Mcp-Session-Id` header
   (Streamable HTTP, protocol `2025-03-26`). The config key is still named `sse` for
   backward compatibility, but the wire protocol is the modern Streamable HTTP transport.

A server carries **exactly one** transport: a `command` makes it stdio, a `url` makes it
remote. Providing both (or neither) is rejected at parse time.

---

## 2. Configuration (`config.json` / `mcpServers` or `mcp_servers`)

MCP servers are configured inside global `~/.config/nova/config.json` or project-local
`<cwd>/.nova/config.json` under the `"mcpServers"` (Claude Desktop / Cursor format) or
`"mcp_servers"` key.

### Example Configuration

```json
{
  "version": "2.0.0",
  "mcpServers": {
    "codebase-memory-mcp": {
      "command": "/path/to/codebase-memory-mcp",
      "args": []
    },
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "enabled": true
    },
    "tavily": {
      "url": "https://mcp.tavily.com/mcp/?tavilyApiKey={env:TAVILY_API_KEY}",
      "enabled": true
    },
    "context7": {
      "type": "remote",
      "url": "https://mcp.context7.com/mcp",
      "headers": {
        "CONTEXT7_API_KEY": "{env:CONTEXT7_API_KEY}"
      }
    }
  }
}
```

### Server Configuration Options

The `mcpServers` entry fields (`command`, `args`, `url`, `headers`, `type`, `enabled`) are part of the config schema — the authoritative field table lives in the [Configuration Guide](CONFIG.md#mcp-server-configuration). The two auth shapes and the `{env:VAR}` expansion behavior are specific to MCP and covered below.

### Environment variable expansion (`{env:VAR}`)

`command`, `args`, `url`, and `headers` values support `{env:VAR}` placeholders, expanded
against the process environment. This keeps secrets (API keys, tokens) out of
`config.json` — store them in the environment instead. A placeholder whose variable is
unset expands to an empty string and logs a warning, so a missing secret surfaces rather
than silently producing a broken command or URL.

> [!IMPORTANT]
> **Secrets stay out of config.json.** Placeholders are stored verbatim in the parsed
> config and expanded only at connect time, into an in-memory copy held by the MCP
> client. When Nova rewrites `config.json` (e.g. on a settings save) it writes the
> `{env:VAR}` placeholder back — never the resolved value — so a secret is never
> persisted to disk.

The same `{env:VAR}` mechanism (raw placeholders on disk, expansion at use time,
secrets never written back) also covers AI provider headers
(`providers.<name>.headers`), expanded once per client attach — see
[Configuration Guide — Provider Configuration](CONFIG.md#provider-configuration).

Two common auth shapes for remote servers:

```json
// API key in the URL query string (e.g. Tavily)
"tavily": {
  "url": "https://mcp.tavily.com/mcp/?tavilyApiKey={env:TAVILY_API_KEY}"
}

// API key in a request header (e.g. Context7)
"context7": {
  "url": "https://mcp.context7.com/mcp",
  "headers": { "CONTEXT7_API_KEY": "{env:CONTEXT7_API_KEY}" }
}
```

---

## 3. Connection Lifecycle

MCP server connections follow a multi-phase lifecycle:

### Phase A — Registration (app startup, no I/O)

`McpManager.syncFromConfig()` creates `McpClient` objects from config. No subprocess is
spawned and no network call is made — the client is marked as `[CONNECTING]`. This phase
is instant and never blocks the TUI.

### Phase B — Connection (async; startup, provider connect, or `/mcp` open)

Connects are **asynchronous** — they never block the TUI. `McpManager.syncFromConfigEx()`
(and `reconnectClient`) launch one `io.concurrent` worker per enabled server instead of
doing I/O inline: a `ConnectJob` (kept in `pending_connects`) whose worker spawns,
handshakes, and discovers tools on a **private transport clone**
(`McpClient.cloneForConnect`) — the live client list is only ever mutated on the main
thread. Each TUI tick, `McpManager.drainConnects` polls the worker's `done` flag, awaits
the finished future (instant), and installs the completed client into the list by name
(`installConnectResult`); `provider_model.drainMcpConnects` then re-injects the freshly
discovered tool schemas. A slow or unreachable server stays `[CONNECTING]` without
freezing the UI, and a disconnect during the handshake discards the outcome instead of
resurrecting the server.

Per server:

- **Stdio**: subprocess launched via `command` + `args` with stdin/stdout pipes.
- **Streamable HTTP**: connectionless — nothing is spawned; each JSON-RPC call is a fresh
  `POST`.

Then, for both transports:

1. **Handshake**: JSON-RPC `initialize` request → server responds with protocol version
   and capabilities → client sends `notifications/initialized`.
2. **Discovery**: JSON-RPC `tools/list` request → server returns tool schemas → parsed
   into `tools_common.Schema` format.

**Timeouts** — a server that doesn't respond in time is marked `[FAILED]` with an error
message:

- Stdio reads use a **30-second timeout** (`read_timeout_ms`) via `std.posix.poll`.
- Remote requests apply a socket-level send/recv timeout (`applyHttpTimeout`,
  SO_RCVTIMEO/SO_SNDTIMEO = `read_timeout_ms`) so a server that accepts the connection but
  stalls fails the handshake instead of hanging the worker. The connect phase itself is
  bounded only by kernel TCP/DNS timeouts — `std.http.Client` exposes no connect timeout in
  Zig 0.16 — but because connects run off-thread, that cannot block the UI either.

**Testing the async path** — `src/mcp/manager.zig`'s async tests mock a stdio MCP server
with a `bash -c` script that `read`s each request line and `echo`s a canned JSON-RPC
response (initialize → initialized notification → tools/list), then poll `drainConnects`
the way the TUI tick does (`drainUntilConnected` helper). Coverage: successful
discovery+install, handshake failure against a dead server, malformed `tools/list`
response, disconnect-mid-flight (the outcome is discarded, never resurrecting the
client), and the single-pending-job launch guard.

### Phase C — Tool injection (startup and on every MCP change)

The AI client serializes its tool list (`tools_json`) once, at attach time. Because the
client is attached during session init — before the MCP manager exists — Nova rebuilds
and re-injects the serialized tools whenever the MCP tool set changes:

- **On startup** (`run()`), after configured servers connect.
- **On `/mcp` open** and after **toggle / reconnect / disconnect** in the overlay.
- **On provider connect** (the interactive `/connect` flow).
- **On session switch / resume / lane spawn** (`createRuntime`): after wiring the
  App's `tool_registry` onto the new runtime, `provider_model.injectToolsInto`
  pushes the merged builtin + plugin + MCP list so the new session's first turn
  carries every tool definition.

`buildMcpToolSchemas()` collects all discovered tools from `.connected` servers and
`updateMcpTools()` rebuilds the client's serialized tool list in place, alongside the
built-in tools. The model sees them as regular function-calling tools with namespaced
names (`mcp__<server>__<tool>`).

### Phase D — Execution (agent turn)

When the model calls an MCP tool:

1. Executor parses `mcp__<server>__<tool>` to extract server and tool name.
2. Finds the connected `McpClient` by server name.
3. Sends `tools/call` JSON-RPC request with the tool name and arguments.
4. Parses the response `content` array (text blocks) and returns the result to the model.

---

## 4. Dynamic Tool Discovery & Namespacing

- On startup and whenever the MCP overlay is opened, `McpManager` connects each enabled
  server (spawning stdio subprocesses or POSTing to remote endpoints), performs the MCP
  `initialize` handshake, and queries `tools/list` via JSON-RPC.
- Exposed MCP tools are automatically namespaced as:
  `mcp__<server_name>__<tool_name>`
  _(Example: `mcp__tavily__tavily_search`)_
- Tool schemas (`inputSchema`) are parsed from JSON Schema into Nova's internal
  `tools_common.Schema` format, preserving property types, descriptions, and required
  fields.
- Discovered tools are injected into the AI provider's `tools` array alongside built-in
  tools (bash), so the model can call them directly.
- **`notifications/tools/list_changed`**: Handled for servers that advertise
  `capabilities.tools.listChanged`. The notification sets `pending_tools_refresh` on the
  client; the TUI tick's `drainMcpNotifications` polls it, re-runs `tools/list`, and
  re-injects the refreshed schemas automatically. (The notification is captured when it
  arrives during a request read; reopen `/mcp` or press `r` to force a re-sync any time.)

---

## 5. Real-Time TUI Monitoring (`/mcp` Command)

Nova Agent includes a dedicated TUI monitoring screen:

- Run `/mcp` in chat to bring up the MCP Status Overlay.
- View connection badges: `[CONNECTED]`, `[CONNECTING]`, `[FAILED]`, `[DISABLED]`.
- View the **transport** per server: `(stdio)` or `(remote)`.
- View **tool count** per server (number of tools discovered via `tools/list`).
- View **ping latency** in milliseconds (from the `initialize` handshake round-trip).
- View **error messages** for failed servers (e.g. "Handshake failed: Timeout").
- Controls:
  - **Space**: Toggle enable / disable status. On a failed server, toggling triggers a
    reconnect attempt.
  - **a**: Add a remote server by URL (opens a single-line input form; paste is
    supported). See below.
  - **Ctrl+R** / **r**: Reconnect the selected server (stop + restart + re-discover).
  - **d**: Disconnect the selected server.
  - **Esc** / **q**: Close overlay.

### Adding a remote server by URL (`a`)

Press `a` in the overlay to open a URL input form. Type or paste a remote MCP endpoint
(`{env:VAR}` placeholders are expanded), then press **Enter** to connect it immediately
or **Esc** to cancel. The server name is derived from the URL host.

> [!NOTE]
> **Runtime-only**: servers added through the overlay live in the running session's
> config only — they are **not** written to `config.json` and disappear on restart. To
> make a server permanent, add it to `mcpServers` in `~/.config/nova/config.json` (or the
> project `.nova/config.json`) by hand.

---

## 6. Crash Isolation & Security

> [!IMPORTANT]
> **Fault Isolation**: If a local stdio MCP child process crashes or terminates
> unexpectedly, Nova Agent catches the signal, flags the server as `[FAILED]`, and
> isolates the fault. The Nova Agent TUI and agent reasoning loop continue running
> without interruption. A remote server that errors or drops its session is likewise
> flagged `[FAILED]` (a `404` is treated as an expired session) without affecting the
> rest of the app.

---

## 7. Known Limitations

- **`notifications/tools/list_changed`**: Handled via `drainMcpNotifications` (see §4);
  the catalog refreshes automatically for servers that advertise `listChanged`.
- **Server-push requests**: Nova does not act on server-initiated Streamable HTTP GET
  streams (sampling/roots). The POST path (tool discovery + tool calls) is fully
  supported, which covers normal tool use.
- **Overlay-added servers are runtime-only**: not persisted to `config.json` (see §5).
- **Server names with underscores**: The `mcp__server__tool` namespace uses `__` as the
  separator. Server names containing `_` will be incorrectly parsed. Use hyphens instead.
- **OAuth 2.1**: Remote servers requiring OAuth (`401` + `WWW-Authenticate`) are not yet
  supported. Use a server that accepts an API key in the URL or headers via `{env:VAR}`.
- **JSON Schema composition in tool `inputSchema`**: `oneOf`/`anyOf` collapse to a single
  property kind only when every branch is the same primitive
  (`integer`/`number`/`boolean`/`string`); a nullable `{"type":"null"}` branch is ignored,
  so `anyOf:[{integer},{null}]` resolves to `integer`. Mixed-type or object/array unions,
  `$ref`, and the array-of-types nullable form (`"type":["string","null"]`) are not resolved
  and fall back to `string`.
