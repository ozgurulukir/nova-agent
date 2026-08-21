# Example Plugins Walkthrough

This guide walks through the three example plugins included with Nova.
Each demonstrates a different aspect of the plugin API.

## 1. Hello World — Minimal Tool Plugin

**Location:** `examples/plugins/hello-world/`

The simplest possible plugin. Registers two tools that the AI model can call.

### plugin.lua

```lua
return {
  name = "hello-world",
  version = "1.0.0",
  author = "Nova",
  description = "A minimal example plugin that registers a greeting tool",
  license = "MIT",
  permissions = {
    require_others = false,
  },
}
```

The manifest declares the plugin's identity and permissions. Since this plugin
doesn't access the filesystem or network, all permissions are at their defaults.

### init.lua

```lua
nova.register_tool({
  name = "greet",
  description = "Returns a friendly greeting",
  parameters = {
    name = {
      type = "string",
      description = "The name to greet",
    },
  },
  handler = function(params)
    local person = params.name or "World"
    return "Hello, " .. person .. "!"
  end,
})
```

Key points:
- `nova.register_tool()` is the primary API for exposing functionality to the AI model
- The `name` must be unique within the plugin (the system prefixes it as `lua__<plugin>__<name>`)
- `parameters` follows JSON Schema conventions — each key is a parameter name
- The `handler` receives a Lua table of parameter values (JSON parsed automatically) and returns a string
- Parameters declared without `optional = true` are required

### test.lua

```lua
local test = test_runner

test.describe("hello-world plugin", function()
  test.it("greets by name", function()
    test.assert.equal("Hello, Alice!", "Hello, Alice!")
  end)
  -- ... more tests ...
end)
```

Run with: `zig build test-plugin`

## 2. File Watcher — Event-Driven Plugin

**Location:** `examples/plugins/file-watcher/`

Demonstrates subscribing to lifecycle events using `nova.on()`.

### plugin.lua

```lua
permissions = {
  file_access = true,
  require_others = false,
}
```

This plugin requests `file_access` because it tracks file operations.

### init.lua

```lua
local file_ops = {}

nova.on("tool_call_started", function(data)
  if data.name == "bash" then
    -- A bash command started — we'll check the result when it finishes
  end
end)

nova.on("tool_call_finished", function(data)
  if data.name == "bash" and data.success then
    -- A bash command completed successfully
  end
end)
```

Key points:
- `nova.on()` subscribes to lifecycle events
- The callback receives a `data` table with event-specific fields
- Multiple callbacks can subscribe to the same event
- Events are dispatched synchronously — keep handlers fast

Available events (only `tool_call_started` and `tool_call_finished` are
currently emitted in production; the others are subscribable but not
currently emitted):

| Event | data fields | When it fires |
|-------|-------------|---------------|
| `turn_started` | `{}` | Agent turn begins *(not currently emitted)* |
| `turn_ended` | `{}` | Agent turn ends *(not currently emitted)* |
| `tool_call_started` | `{name, call_id}` | Tool execution starts |
| `tool_call_finished` | `{name, call_id, success}` | Tool execution completes |
| `response_received` | `{}` | LLM response received *(not currently emitted)* |
| `plugin_loaded` | `{name}` | Plugin loaded *(not currently emitted)* |
| `plugin_unloaded` | `{name}` | Plugin unloaded *(not currently emitted)* |

## 3. Configurable Tool — authoring pattern

This is an **authoring pattern**, not a shipped example directory. It shows
how a plugin reads its configuration and applies defaults at runtime.

### plugin.lua

```lua
permissions = {
  file_access = true,
  require_others = false,
}
```

### init.lua

```lua
local config = plugin.get_config() or {}

local settings = {
  max_results = config.max_results or 10,
  case_sensitive = config.case_sensitive or false,
  default_pattern = config.default_pattern or "*.lua",
}
```

Key points:
- `plugin.get_config()` returns the plugin's settings as a fresh table
- Both config forms work: an inline JSON object or an escaped JSON string
- `plugin.get_config()` returns `nil` when unconfigured — apply defaults
- Settings are read once at App start (restart to apply changes)

### Configuring the plugin

In `~/.config/nova/config.json` or `.nova/config.json` (inline-object form
shown; the escaped-string form also works):

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

Plugin configuration stays opaque to the config system — the plugin's Lua
code is responsible for validating its own settings and applying defaults.

## 4. Read Tool — File Reading with Git Integration

**Location:** `examples/plugins/read-tool/`

Demonstrates file reading with line range support, language detection, and
git status integration.

### init.lua

```lua
nova.register_tool({
  name = "read",
  description = "Read file contents with optional line range and language detection",
  parameters = {
    path = { type = "string", description = "File path to read" },
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
    return string.format("File: %s\nSize: %d bytes\nLines: %d\nLanguage: %s\n\n%s",
      result.path, result.size, result.lines, result.language, result.content)
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

Key points:
- `nova.read_file()` returns rich metadata (size, lines, language, mime_type)
- `nova.git_status()` and `nova.git_branch()` use Nova's safe bash execution
- No `file_access` permission needed — bridge functions are always available

## 5. Write Tool — File Writing with Git-Aware Operations

**Location:** `examples/plugins/write-tool/`

Demonstrates atomic file writing, find-and-replace editing, and git-aware
write+stage workflow.

### init.lua

```lua
nova.register_tool({
  name = "write",
  description = "Write content to a file (atomic write, path traversal protected)",
  parameters = {
    path = { type = "string", description = "File path to write" },
    content = { type = "string", description = "Content to write" },
  },
  handler = function(params)
    local ok = nova.write_file(params.path, params.content)
    if ok then
      return string.format("Wrote %d bytes to %s", #params.content, params.path)
    end
    return "Error: could not write to " .. params.path
  end,
})

nova.register_tool({
  name = "edit",
  description = "Replace first occurrence of a string in a file",
  parameters = {
    path = { type = "string", description = "File path to edit" },
    old_string = { type = "string", description = "Text to replace" },
    new_string = { type = "string", description = "Replacement text" },
  },
  handler = function(params)
    local ok = nova.edit_file(params.path, params.old_string, params.new_string)
    if ok then return "Edited " .. params.path
    else return "Error: could not edit " .. params.path end
  end,
})

nova.register_tool({
  name = "write_and_stage",
  description = "Write content to a file and stage it with git",
  parameters = {
    path = { type = "string", description = "File path to write" },
    content = { type = "string", description = "Content to write" },
  },
  handler = function(params)
    local ok = nova.write_file(params.path, params.content)
    if not ok then return "Error: could not write to " .. params.path end
    local result = nova.run_bash("git add " .. params.path, {})
    if result.code == 0 then
      return string.format("Wrote and staged %s", params.path)
    end
    return string.format("Wrote %s but git add failed: %s", params.path, result.stderr)
  end,
})
```

Key points:
- `nova.write_file()` uses atomic write (temp file + rename) — no partial writes
- `nova.edit_file()` does safe find-and-replace with atomic write
- `nova.run_bash()` enables git integration without `os.execute()`

## 6. Search Tool — Recursive Grep with Ripgrep Fallback

**Location:** `examples/plugins/search-tool/`

Demonstrates recursive file content search with pattern matching and
ripgrep fallback via `nova.run_bash()`.

### init.lua

```lua
nova.register_tool({
  name = "search",
  description = "Search file contents recursively with pattern matching",
  parameters = {
    root = { type = "string", description = "Root directory to search" },
    pattern = { type = "string", description = "Text pattern to search for" },
    file_pattern = { type = "string", description = "File glob filter", optional = true },
    case_sensitive = { type = "boolean", description = "Case-sensitive", optional = true },
    max_results = { type = "number", description = "Maximum results", optional = true },
  },
  handler = function(params)
    local result = nova.search_files(params.root, params.pattern, {
      file_pattern = params.file_pattern,
      case_sensitive = params.case_sensitive,
      max_results = params.max_results,
    })
    if result == nil then return "Error: could not search " .. params.root end
    local lines = {}
    table.insert(lines, string.format("Query: %s", result.query))
    table.insert(lines, string.format("Total matches: %d", result.total_matches))
    if result.truncated then table.insert(lines, "(results truncated)") end
    table.insert(lines, "")
    for _, r in ipairs(result.results or {}) do
      table.insert(lines, string.format("%s:%d: %s", r.file, r.line, r.content))
    end
    return table.concat(lines, "\n")
  end,
})

nova.register_tool({
  name = "rg_search",
  description = "Fast search using ripgrep (falls back to grep if rg not available)",
  parameters = {
    pattern = { type = "string", description = "Pattern to search for" },
    path = { type = "string", description = "Directory to search in", optional = true },
  },
  handler = function(params)
    local root = params.path or nova.get_project_root()
    local cmd = string.format("rg --line-number --no-heading %s %s 2>/dev/null || grep -rn %s %s",
      params.pattern, root, params.pattern, root)
    local result = nova.run_bash(cmd, { cwd = root })
    if result.code == 0 then return result.stdout end
    return "No matches or search failed: " .. result.stderr
  end,
})
```

Key points:
- `nova.search_files()` is a pure Zig implementation — no shell needed
- `nova.run_bash()` enables ripgrep fallback for faster searches
- `nova.get_project_root()` resolves the project root automatically

## Testing Your Plugin

1. Create a `test.lua` file in your plugin directory
2. Use the `test_runner` global (pre-loaded by the test runner)
3. Run with: `zig build test-plugin -- path/to/your/test.lua`

```lua
local test = test_runner

test.describe("my plugin", function()
  test.it("works correctly", function()
    test.assert.equal(42, 42)
  end)
end)
```

## Next Steps

- Read the full [API Reference](api-reference.md) for all available functions
- See the [Plugin Development Guide](README.md) for setup and permissions
- Check `docs/plugins/` for the complete documentation set
