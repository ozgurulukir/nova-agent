---
name: write-lua-plugin
description: Guide to writing Nova Lua plugins for the Nova Agent. Learn how to create tools, access filesystem/shell/git, handle permissions, debug, and structure Lua plugin projects.
---

# Write Nova Lua Plugin

Write a Lua plugin that extends Nova's capabilities. Plugins run in a sandboxed Lua 5.4 environment and can register tools, subscribe to events, access the filesystem, run shell commands, and interact with git.

## Plugin Structure

```
~/.config/nova/plugins/<plugin-name>/
  plugin.lua    -- manifest (required)
  init.lua      -- entry point (required)
```

## Manifest (`plugin.lua`)

```lua
return {
  name = "my-plugin",           -- required, unique identifier
  version = "1.0.0",            -- required, semver
  author = "Your Name",         -- optional
  description = "What it does", -- optional
  license = "MIT",              -- optional
  permissions = {                -- optional, defaults shown
    file_access = false,
    network_access = false,
    require_others = true,
    allow_os_execute = false,
    allow_os_exit = false,
    allow_os_remove = false,
    instruction_limit = 100000,
    memory_limit_mb = 16,
    timeout_ms = 5000,
  },
}
```

## Entry Point (`init.lua`)

Register tools using `nova.register_tool()`:

```lua
nova.register_tool({
  name = "my_tool",                    -- lowercase, underscores
  description = "What the tool does", -- for the AI model
  parameters = {                       -- JSON Schema-like
    param_name = {
      type = "string",                 -- "string", "number", "boolean"
      description = "Description",
      optional = true,                 -- default: false (required)
    },
  },
  handler = function(params)
    -- params is a Lua table with parameter values (JSON parsed automatically)
    -- Must return a string
    return "result"
  end,
})
```

**Tool naming:** Tools are exposed to the AI model as `lua__<plugin>__<tool>` (e.g.
`lua__my-plugin__my_tool`). The prefix is added automatically — use short,
descriptive names in `register_tool`.

**Parameters:** The JSON arguments from the AI model are automatically parsed
into a Lua table before the handler is called. You can access `params.param_name`
directly — no manual JSON parsing needed.

## Available Bridge Functions (28 total)

### Filesystem (no permission needed)
- `nova.read_file(path, opts?)` → `{path, content, size, lines, language, mime_type}`
  - opts: `start_line`, `end_line`, `max_size` (default 1MB)
- `nova.write_file(path, content)` → `true` or `nil`
  - Atomic write (temp file + rename)
- `nova.edit_file(path, old_string, new_string)` → `true` or `nil`
  - Find-and-replace first occurrence
- `nova.search_files(root, pattern, opts?)` → `{query, total_matches, results, truncated}`
  - opts: `file_pattern`, `case_sensitive`, `max_results` (max 200)
- `nova.find_files(root, pattern, opts?)` → `{root, total_matches, truncated, results}`
  - Recursive filename glob: `**` (spans dirs), `*` (within segment), `?` (one char)
  - opts: `max_results` (default 100, max 200). gitignore NOT honored.
- `nova.list_dir(path)` → `{path, files[], directories[], total_items}`
- `nova.file_info(path)` → `{size, type, extension, language, mime_type}`
- `nova.mkdir(path)` → `true` or `nil` — create directory recursively
- `nova.copy_path(src, dst)` → `true` or `nil` — copy a single file
- `nova.move_path(src, dst)` → `true` or `nil` — move/rename file or directory
- `nova.delete_path(path, opts?)` → `true` or `nil` — delete file/dir (`opts.recursive`)

Prefer these dedicated path ops over `nova.run_bash("rm -rf ...")`: they go
through `sanitizePath` (cwd-confinement guard) and are strictly safer.

### Shell & Environment (no permission needed)
- `nova.run_shell(cmd, opts?)` → `{stdout, stderr, code}`
  - Platform-native shell execution: uses `pwsh.exe` on Windows and `/bin/bash` on POSIX.
  - opts: `cwd` (default: cwd), `timeout` (default: 30s), `stdin` (string written to the child's stdin, then closed)
- `nova.run_bash(cmd, opts?)` → `{stdout, stderr, code}` — same opts as run_shell
  - Every command passes the shell safety classifier first: destructive
    forms return `nil, "UnsafeShellBlocked: ..."` (no approval flow at the
    bridge — destructive work belongs to the built-in bash tool). Empty
    commands return `nil, "command argument must not be empty"`. A missing
    shell binary returns `nil, "ShellUnavailable: bash not found (install Git Bash on Windows, or ensure bash is on PATH); consider nova.run_shell"`
    (or the pwsh variant for `run_shell` on Windows).
- `nova.shell_quote(s, dialect?)` → quoted `string` or `nil, err`
  - Quote one argument so interpolated values cannot break out of the command.
    `"posix"` (default) for run_bash on both platforms; `"native"` for
    run_shell (PowerShell `''` rule on Windows). ALWAYS quote user input.
- `nova.get_env(name)` → `string` or `nil`
- `nova.get_cwd()` → `string`
- `nova.get_project_root()` → `string` (git repo root or cwd)

### Git (no permission needed)
- `nova.git_status()` → `string` (porcelain format)
- `nova.git_diff(path?)` → `string`
- `nova.git_log(n)` → `string` (default n=10)
- `nova.git_branch()` → `string`
- `nova.git_add(files)` → `{success, output}` (stage specific files or patterns)
- `nova.git_commit(msg, opts?)` → `{success, output}`
  - opts: `files` (selective staging), `staged_only` (only staged changes), `stage_all` (all changes)

### Plugin System & Modular Code
- `nova.require(mod_path)` → `any`
  - Loads a relative Lua module within the plugin directory (e.g. `nova.require("./utils")` or `nova.require("helpers/math")`).
  - Confined strictly to plugin directory; cached in `nova_loaded_modules`.
- `nova.register_tool(spec)` → `true` — register a tool for the AI model
- `nova.on(event, callback)` → `true` — subscribe to lifecycle event
  - Events: `tool_call_started`, `tool_call_finished` (emitted in production);
    `turn_started`, `turn_ended`, `response_received`, `plugin_loaded`,
    `plugin_unloaded` (subscribable but not currently emitted)
- `nova.think(prompt)` → _(stub, not yet implemented)_

### JSON (no permission needed)
- `nova.json_decode(str)` → Lua value or `nil, err`
  - Parse JSON into a native Lua value (objects → tables, arrays → 1-indexed tables)
- `nova.json_encode(value, opts?)` → JSON `string` or `nil, err`
  - Serialize a Lua value to JSON. Contiguous 1..N integer keys → array `[...]`;
    otherwise object `{...}`. Empty tables → `[]`.
  - opts: `pretty` (bool) — indent_2 output for human-editable files
  - Functions/userdata/threads (no JSON form) emit `null`

Use these instead of hand-rolling a JSON parser or shelling out to `jq`. They
round-trip cleanly for data tables: `json_decode(json_encode(t))` recovers `t`.

### Plugin Config & State
- `plugin.get_config()` → fresh table per call, or `nil` when unconfigured
  (from `config.json` `plugins.<name>.settings`; inline-object or escaped-string
  form; read at App start — `enabled: false` skips loading the plugin).
  Malformed/non-object settings return `nil, "get_config: settings must be a JSON object"`.
  `plugin` is a reserved global name.
- State across reloads uses **top-level Lua globals** `get_state()`/`set_state(state)`
  (in-memory only, lost on restart). For durable state, write a file sidecar
  (`.nova/<plugin>/state.json`) — the `todo` example plugin's pattern.

## Parameter Schema

```lua
parameters = {
  name = {
    type = "string",       -- "string" | "number" | "boolean"
    description = "...",   -- for the AI model
    optional = true,       -- if true, model may omit
  },
}
```

## Best Practices

1. **Use `nova.*` bridge functions** instead of blocked Lua libraries (`io`, `os.execute`, etc.)
2. **Declare only needed permissions** — least privilege principle
3. **Return descriptive strings** from handlers — the AI model reads the return value
4. **Handle errors gracefully** — return error strings, don't crash
5. **Keep event handlers fast** — events are dispatched synchronously
6. **Name tools with underscores** — `my_tool`, not `myTool`
7. **Use `plugin.get_config()`** for user-configurable settings
8. **Test with `test_runner`** — create `test.lua` in your plugin directory
9. **Prefer dedicated tools over bash** — `delete_path` over `run_bash("rm")`,
   `find_files` over `run_bash("find")`. Dedicated tools are cwd-confined via
   `sanitizePath`; `run_bash` passes the shell-safety classifier (hard-block on
   unsafe, no approval flow at the bridge).
10. **Use `nova.json_encode`/`json_decode` for structured persistence.** When a
    plugin needs to store structured data (checklists, configs, records), write
    it as JSON via `nova.write_file(path, nova.json_encode(data, {pretty=true}))`
    and read it back with `nova.json_decode`. The `pretty` flag makes the file
    human-editable. A corrupt file should yield `{}` from your loader (guard
    `json_decode` returning `nil`) so a bad sidecar never blocks the plugin.
    The todo plugin's `.nova/todos/plans.json` sidecar is the reference pattern.

## Example: Read + Git Status Tool

```lua
nova.register_tool({
  name = "read",
  description = "Read file contents with line range and language detection",
  parameters = {
    path = { type = "string", description = "File path" },
    start_line = { type = "number", description = "Starting line", optional = true },
    end_line = { type = "number", description = "Ending line", optional = true },
  },
  handler = function(params)
    local result = nova.read_file(params.path, {
      start_line = params.start_line,
      end_line = params.end_line,
    })
    if result == nil then
      return "Error: could not read " .. params.path
    end
    return string.format("File: %s\nSize: %d\nLanguage: %s\n\n%s",
      result.path, result.size, result.language, result.content)
  end,
})

nova.register_tool({
  name = "git_status",
  description = "Get git status for the current repository",
  parameters = {},
  handler = function()
    local status = nova.git_status()
    local branch = nova.git_branch()
    return string.format("Branch: %s\n\n%s", branch or "unknown", status)
  end,
})
```

## Example: Bash + Write Tool

```lua
nova.register_tool({
  name = "build",
  description = "Run a build command and return the result",
  parameters = {
    command = { type = "string", description = "Build command to run" },
  },
  handler = function(params)
    local result, err = nova.run_bash(params.command, { timeout = 60 })
    -- nil means the safety classifier blocked the command, the command was
    -- empty, or the shell binary is missing — err carries the reason.
    if result == nil then
      return "Error: " .. (err or "command failed")
    end
    if result.code == 0 then
      return "Build succeeded:\n" .. result.stdout
    else
      return "Build failed (code " .. result.code .. "):\n" .. result.stderr
    end
  end,
})

nova.register_tool({
  name = "write_and_stage",
  description = "Write content to a file and stage it with git",
  parameters = {
    path = { type = "string", description = "File path" },
    content = { type = "string", description = "Content to write" },
  },
  handler = function(params)
    local ok = nova.write_file(params.path, params.content)
    if not ok then return "Error: could not write" end
    -- Quote the interpolated path. (nova.git_add(params.path) avoids the
    -- shell entirely — prefer a dedicated bridge when one covers the case.)
    local quoted = nova.shell_quote(params.path)
    local result, err = nova.run_bash("git add " .. quoted, {})
    if result == nil then
      return string.format("Wrote %s but git add failed: %s", params.path, err or "blocked")
    end
    if result.code == 0 then
      return string.format("Wrote and staged %s", params.path)
    end
    return string.format("Wrote %s but git add failed: %s", params.path, result.stderr)
  end,
})
```

## Testing

Create `test.lua` in your plugin directory:

```lua
local test = test_runner

test.describe("my plugin", function()
  test.it("works correctly", function()
    test.assert.equal(4, 2 + 2)
  end)
end)

test.run()
```

Run: `zig build test-plugin`

## See Also

- `docs/plugins/README.md` — full plugin development guide
- `docs/plugins/api-reference.md` — complete API reference
- `docs/plugins/examples.md` — example walkthroughs
- `examples/plugins/` — example plugin source code
