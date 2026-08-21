# Nova Plugin Development Guide

Nova supports extending its capabilities through Lua plugins. Plugins can register
custom tools, subscribe to lifecycle events, access the filesystem, run shell commands,
interact with git, and store persistent state.

## Quick Start

Create a plugin directory with two files:

```
~/.config/nova/plugins/my-plugin/
  plugin.lua    -- manifest (required)
  init.lua      -- entry point (required)
```

### plugin.lua (manifest)

```lua
return {
  name = "my-plugin",
  version = "1.0.0",
  author = "Your Name",
  description = "Does something useful",
  license = "MIT",
  permissions = {
    file_access = false,
    network_access = false,
    require_others = false,
  },
}
```

### init.lua (entry point)

```lua
nova.register_tool({
  name = "hello",
  description = "A friendly greeting",
  parameters = {
    name = { type = "string", description = "Who to greet" },
  },
  handler = function(params)
    -- params is a Lua table (JSON parsed automatically)
    return "Hello, " .. (params.name or "World") .. "!"
  end,
})
```

**Tool naming:** Tools are exposed to the AI model as `lua__<plugin>__<tool>`
(e.g. `lua__my-plugin__hello`). The prefix is added automatically.

**Parameters:** JSON arguments from the AI model are automatically parsed into
a Lua table before the handler is called. Access `params.param_name` directly.

### prompt.md (optional model instructions)

A plugin MAY include a `prompt.md` next to `plugin.lua`. Its body is injected
into the AI model's system prompt, so the model learns how to call the
plugin's tools correctly before it ever invokes one.

```
my-plugin/
├── plugin.lua
├── init.lua
└── prompt.md      ← optional, plain markdown (frontmatter optional)
```

`prompt.md` is plain markdown. An optional YAML frontmatter block is stripped
before injection (same format as `SKILL.md`):

```markdown
---
description: Short summary of what these tools do.
---

Always confirm with the user before overwriting an existing file.
Prefer the `edit` tool for small changes over `write`.

When the user asks to create a new file, use `write` with the full path.
```

**How it works:** Nova scans `<home>/.config/nova/plugins/*/prompt.md` and
`.nova/plugins/*/prompt.md` at session start (a pure text scan — no Lua state
is created). Each non-empty body is wrapped in a `<plugin_prompts>` block in
the system prompt:

```
<plugin_prompts>
  <plugin name="my-plugin">
    Always confirm with the user before overwriting an existing file.
    ...
  </plugin>
</plugin_prompts>
```

Notes:
- A plugin with no `prompt.md` contributes nothing — only tools registered via
  `nova.register_tool` are visible to the model.
- A plugin with `prompt.md` but no `plugin.lua` still contributes prompt text.
- A project plugin overrides a global plugin with the same directory name
  (including its `prompt.md`).
- Changes to `prompt.md` take effect on the next session or lane.

## Plugin Discovery

Nova discovers plugins from two directories:

| Directory | Scope |
|-----------|-------|
| `~/.config/nova/plugins/` | Global — available in all projects |
| `.nova/plugins/` | Project — overrides global plugins with the same name |

Each subdirectory containing a `plugin.lua` file is treated as a plugin.

## Plugin API — `nova` Bridge Functions

### Filesystem

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `nova.read_file(path, opts?)` | `path`, `opts.start_line`, `opts.end_line`, `opts.max_size` | `{path, content, size, lines, language, mime_type}` | Read file with metadata |
| `nova.write_file(path, content)` | `path`, `content` | `true` or `nil` | Atomic file write |
| `nova.edit_file(path, old, new)` | `path`, `old_string`, `new_string` | `true` or `nil` | Find-and-replace (first occurrence) |
| `nova.search_files(root, pattern, opts?)` | `root`, `pattern`, `opts.file_pattern`, `opts.case_sensitive`, `opts.max_results` | `{query, total_matches, results, truncated}` | Recursive content grep (substring) |
| `nova.find_files(root, pattern, opts?)` | `root`, `pattern` (glob), `opts.max_results` | `{root, total_matches, truncated, results}` | Recursive filename glob match |
| `nova.list_dir(path)` | `path` | `{path, files, directories, total_items}` | Directory listing (single level) |
| `nova.file_info(path)` | `path` | `{size, type, extension, language, mime_type}` | File metadata |
| `nova.mkdir(path)` | `path` | `true` or `nil` | Create directory (recursive, with parents) |
| `nova.copy_path(src, dst)` | `source_path`, `destination_path` | `true` or `nil` | Copy a single file |
| `nova.move_path(src, dst)` | `source_path`, `destination_path` | `true` or `nil` | Move/rename a file or directory |
| `nova.delete_path(path, opts?)` | `path`, `opts.recursive` | `true` or `nil` | Delete file or directory (recursive opt-in) |

All filesystem functions validate paths through `sanitizePath`: paths are
resolved against the project root and **rejected if they escape it**. This
makes the dedicated path ops (`mkdir`/`copy_path`/`move_path`/`delete_path`)
safer and more precise than shell-outs: `nova.run_bash` commands pass through
the shell safety classifier (destructive forms are hard-blocked with
`UnsafeShellBlocked` — see the API reference), but the dedicated tools carry
no shell-quoting or classification burden at all. Prefer them for file
operations.

`nova.find_files` supports glob patterns: `**` (spans directories), `*`
(within a segment), `?` (single char). Example: `find_files(".", "**/*.zig")`
matches every `.zig` file at any depth. gitignore is NOT honored.

### Shell & Environment

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `nova.run_bash(cmd, opts?)` | `cmd`, `opts.cwd`, `opts.timeout`, `opts.stdin` | `{stdout, stderr, code}` | Bash command execution, gated by the shell safety classifier |
| `nova.run_shell(cmd, opts?)` | `cmd`, `opts.cwd`, `opts.timeout`, `opts.stdin` | `{stdout, stderr, code}` | Platform-native shell (pwsh on Windows, bash on POSIX), same gate |
| `nova.shell_quote(s, dialect?)` | `s`, `dialect` (`"posix"` default, `"native"`) | `string` or `nil, err` | Quote one argument for a shell command line — use it for every interpolated value |
| `nova.get_env(name)` | `name` | `string` or `nil` | Environment variable |
| `nova.get_cwd()` | — | `string` | Current working directory |
| `nova.get_project_root()` | — | `string` | Git repo root or cwd |

### Git

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `nova.git_status()` | — | `string` | Git status (porcelain) |
| `nova.git_diff(path?)` | `path` (optional) | `string` | Git diff |
| `nova.git_log(n)` | `n` (default 10) | `string` | Recent commits |
| `nova.git_branch()` | — | `string` | Current branch name |
| `nova.git_commit(msg)` | `msg` | `{success, output}` | Create commit |

### Plugin System

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `nova.register_tool(spec)` | `spec.name`, `spec.description`, `spec.parameters`, `spec.handler` | `true` | Register a tool |
| `nova.on(event, callback)` | `event`, `callback` | `true` | Subscribe to a lifecycle event |
| `nova.think(prompt)` | `prompt` | _(stub)_ | Recursive LLM call (not yet implemented) |

### JSON

| Function | Parameters | Returns | Description |
|----------|-----------|---------|-------------|
| `nova.json_decode(str)` | JSON `string` | Lua value (table/string/number/boolean/nil) or `nil, err` | Parse JSON into a native Lua value. Objects → tables, arrays → 1-indexed tables. |
| `nova.json_encode(value, opts?)` | any Lua value, `opts.pretty` (bool) | JSON `string` or `nil, err` | Serialize a Lua value to JSON. Tables with contiguous 1..N integer keys become arrays `[...]`; others become objects `{...}`. Empty tables serialize as `[]`. Set `opts.pretty = true` for indent_2 output (human-editable files). Functions/userdata/threads (no JSON form) emit `null`. |

Use these instead of hand-rolling a JSON parser or shelling out to `jq`. They
round-trip cleanly: `json_decode(json_encode(t))` recovers `t` for data tables.
Note: Lua tables have no array/map distinction, so the encoder infers it from the
key shape — a table with non-integer or sparse keys serializes as an object.

### Events

`nova.on(event_name, callback)` subscribes to a lifecycle event. The callback
receives a `data` table whose shape depends on the event. Events are emitted by
the agent loop at tool-call boundaries and delivered to every active plugin.
Only `tool_call_started` and `tool_call_finished` are currently emitted in
production; the other five are subscribable but not currently emitted (kept
for forward compatibility).

| Event | `data` shape | When it fires |
|-------|--------------|---------------|
| `turn_started` | `{}` | A new agent turn starts *(not currently emitted)* |
| `turn_ended` | `{}` | An agent turn ends *(not currently emitted)* |
| `tool_call_started` | `{ name, call_id }` | A tool call begins |
| `tool_call_finished` | `{ name, call_id, success }` | A tool call completes |
| `response_received` | `{}` | A response was received from the LLM *(not currently emitted)* |
| `plugin_loaded` | `{ name }` | A plugin was loaded *(not currently emitted)* |
| `plugin_unloaded` | `{ name }` | A plugin was unloaded *(not currently emitted)* |

```lua
nova.on("tool_call_finished", function(data)
  if data.name == "lua__file-tools__write" and data.success then
    -- track that a file was written this turn
  end
end)
```

Callbacks run synchronously on the agent worker thread, at the boundary
between tool calls (after the plugin's own handler has returned), so it is safe
to read/write the plugin's own Lua state.

### Plugin state persistence (reload)

State persistence across plugin reloads uses **global functions**, not a
`plugin.*` namespace. Define top-level `get_state()` and `set_state(state)`
functions in your `init.lua`. `PluginManager` calls them at reload time:

```lua
-- Return a string (JSON recommended) to be saved.
function get_state()
  return encode_state(my_state_table)
end

-- Receive the previously-saved string.
function set_state(state)
  my_state_table = decode_state(state)
end
```

This state is in-memory only and is lost on restart. For durable state, write
a file sidecar (`.nova/<plugin>/state.json` via `nova.write_file` +
`nova.json_encode`) — the pattern the `todo` example plugin uses.

### Plugin configuration

`plugin.get_config()` returns your plugin's `config.json` settings as a table
(or `nil` when unconfigured). `plugin` is a reserved global name. Settings are
read once at App start — set `"enabled": false` in config.json to skip loading
a plugin entirely; either way, restart Nova to apply config changes. See the
API reference for the full contract and `docs/CONFIG.md` for both settings
forms (escaped JSON string or inline object).

## Permissions

Plugins declare required permissions in their manifest. Permissions are granted
at load time and cannot be changed at runtime.

| Permission | Description | Default |
|------------|-------------|---------|
| `file_access` | Allow file read/write via `io.*` | `false` |
| `network_access` | Allow network access | `false` |
| `require_others` | Allow requiring other plugins | `true` |
| `allow_rawget_rawset` | Allow `rawget`/`rawset` (sandbox escape risk) | `false` |
| `allow_os_execute` | Allow `os.execute` | `false` |
| `allow_os_exit` | Allow `os.exit` | `false` |
| `allow_os_remove` | Allow `os.remove`/`os.rename` | `false` |

Embedded plugins (shipped with Nova) always get full access.

## Resource Limits

| Limit | Default | Description |
|-------|---------|-------------|
| `instruction_limit` | 100,000 | Max Lua instructions before abort |
| `memory_limit_mb` | 16 | Max memory in MB |
| `timeout_ms` | 5,000 | Approximate timeout in ms |

Set these in the manifest's `permissions` table:

```lua
permissions = {
  instruction_limit = 50000,
  memory_limit_mb = 32,
  timeout_ms = 10000,
}
```

## Sandbox

Plugins run in a restricted Lua environment. The following are available:

- **Safe functions**: `assert`, `error`, `getmetatable`, `ipairs`, `next`, `pairs`,
  `pcall`, `rawequal`, `rawlen`, `select`, `setmetatable`, `tonumber`, `tostring`,
  `type`, `xpcall`, `_VERSION`
- **Safe libraries**: `string`, `table`, `math`, `coroutine`, `utf8`
- **Safe os subset**: `os.clock()`, `os.date()`, `os.time()`, `os.difftime()`

The following are **blocked** by default: `io`, `debug`, `package`, `loadfile`,
`dofile`, `rawget`, `rawset`, `os.execute`, `os.exit`, `os.remove`, `os.rename`.

Instead of blocked functions, use `nova.*` bridge functions:
- Use `nova.read_file()` instead of `io.open()`
- Use `nova.run_bash()` instead of `os.execute()`
- Use `nova.get_env()` instead of `os.getenv()`

## Testing

Nova includes a Lua test framework. Create test files using `describe`/`it`:

```lua
local test = test_runner

test.describe("my plugin", function()
  test.it("adds numbers", function()
    test.assert.equal(4, 2 + 2)
  end)

  test.it("handles errors", function()
    test.assert.error(function()
      error("boom")
    end)
  end)
end)

test.run()
```

Run tests with:

```bash
zig build test-plugin
```

## Example Plugins

See `examples/plugins/` for complete, tested examples. These mirror the tool
shapes models already know from Claude Code / OpenCode / Zed agents:

- **file-tools** — `read` (numbered lines, binary guard, paging),
  `write`, `edit` (with `replace_all`), `list_directory` (folders/files split)
- **search-tools** — `grep` (grouped output, regex via ripgrep fallback),
  `glob` (recursive filename match via `nova.find_files`)
- **path-tools** — `create_directory`, `copy_path`, `move_path`, `delete_path`
  (sandboxed alternatives to bash cp/mv/rm/mkdir)
- **git-tools** — `git_status`, `git_diff`, `git_log`, `git_branch`,
  `git_commit` (with commit-discipline guidance in `prompt.md`)
- **todo** — todo.txt-format task tracker with detailed plans. List tools:
  `todo_list`, `todo_add`, `todo_done`, `todo_delete`, `todo_prioritize`,
  `todo_write`. Plan tools (lazy-loaded so the list stays compact):
  `todo_get_plan`, `todo_set_plan`, `todo_check_step`. The task list persists to
  `.nova/todos.txt` (todo.txt standard, editable in any editor); detailed
  per-task plans live in a sidecar `.nova/todos/plans.json` keyed by a stable
  `id:N` tag. `todo_list` shows only a `[plan:N steps]` marker — plan bodies are
  fetched on demand via `todo_get_plan` to keep context small. Refreshes on
  `turn_started` events.
- **file-watcher** — Event-driven plugin using `nova.on("tool_call_finished", ...)`
- **hello-world** — Minimal tool registration (demo)

Each plugin ships a `prompt.md` whose body is injected into the system prompt
(see the "prompt.md" section above), teaching the model when and how to use
the plugin's tools.

## Best Practices

1. **Use `nova.*` bridge functions** instead of blocked Lua libraries
2. **Prefer dedicated tools over bash** — `delete_path` over `run_bash("rm")`,
   `find_files` over `run_bash("find")`. The dedicated tools are sandboxed;
   `run_bash` runs unclassified.
3. **Handle errors gracefully** — return descriptive error strings
4. **Keep handlers fast** — events are dispatched synchronously
5. **Test with `test_runner`** — create `test.lua` in your plugin directory
6. **Ship a `prompt.md`** — teach the model when to use each tool
7. **Name tools with underscores** — `my_tool`, not `myTool`
8. **Return strings from handlers** — the model reads the return value
