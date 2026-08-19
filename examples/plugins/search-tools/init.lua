-- init.lua — Search Tools
-- Registers `grep` (content search) and `glob` (filename search). Both return
-- grouped, bounded output with truncation markers. `grep` has two backends:
-- substring search (the default) uses Nova's built-in search_files — self-
-- contained, no external binary; regex search (regex=true) shells out to
-- ripgrep, because search_files is substring-only and Lua patterns are not
-- PCRE (no alternation). Scope differs by backend: ripgrep honors .gitignore;
-- the native walker skips dotfiles but scans gitignored dirs (vendor/,
-- zig-cache/).

local is_windows = false
if type(package) == "table" and type(package.config) == "string" then
  is_windows = (package.config:sub(1, 1) == "\\")
elseif type(nova) == "table" and type(nova.get_env) == "function" then
  is_windows = (nova.get_env("OS") == "Windows_NT")
end

-- Shell single-quote escaping:
-- On Windows (PowerShell): wrap in '...' and escape embedded ' as ''
-- On POSIX (Bash): wrap in '...' and escape embedded ' as '\''
local function shell_quote(s)
  local str = tostring(s)
  if is_windows then
    return "'" .. str:gsub("'", "''") .. "'"
  else
    return "'" .. str:gsub("'", "'\\''") .. "'"
  end
end

-- Build the rg invocation as a single shell command string with every dynamic
-- value quoted (regex mode only). rg exit codes the handler relies on:
-- 0 = matches, 1 = no matches, 2 = error (e.g. bad regex); shell returns 127
-- when rg itself is missing.
local function build_rg_command(pattern, root, include, case_sensitive)
  local argv = { "rg", "--line-number", "--no-heading", "--color", "never" }
  if not case_sensitive then
    table.insert(argv, "-i")
  end
  if include and include ~= "" then
    table.insert(argv, "--glob")
    table.insert(argv, shell_quote(include))
  end
  table.insert(argv, "-e")
  table.insert(argv, shell_quote(pattern))
  table.insert(argv, shell_quote(root))
  return table.concat(argv, " ")
end

-- Turn raw `rg --line-number` output into grouped format. Each rg line is
-- `path:line:content`; split on the first two colons so content that itself
-- contains colons is not mangled. Counts every match but only keeps the first
-- `max_results`, so output stays bounded (the tool's contract) even when rg
-- returns thousands of hits.
local function group_rg_output(raw, pattern, max_results)
  local by_file = {}
  local file_order = {}
  local total = 0
  local shown = 0
  for line in raw:gmatch("[^\n]+") do
    local first = line:find(":")
    if first then
      local second = line:find(":", first + 1)
      if second then
        total = total + 1
        if shown < max_results then
          shown = shown + 1
          local file = line:sub(1, first - 1)
          local lno = line:sub(first + 1, second - 1)
          local content = line:sub(second + 1)
          if not by_file[file] then
            by_file[file] = {}
            table.insert(file_order, file)
          end
          table.insert(by_file[file], { line = lno, content = content })
        end
      end
    end
  end

  if total == 0 then
    return "No matches found for: " .. pattern
  end

  local out = {}
  if shown < total then
    table.insert(out, string.format("Found %d matches (showing first %d, more available):", total, shown))
  else
    table.insert(out, string.format("Found %d matches:", total))
  end
  table.insert(out, "")
  for _, file in ipairs(file_order) do
    table.insert(out, file .. ":")
    for _, m in ipairs(by_file[file]) do
      table.insert(out, string.format("  Line %s: %s", m.line, m.content))
    end
    table.insert(out, "")
  end
  return table.concat(out, "\n"):gsub("\n$", "")
end

-- Local, separator-agnostic path splitters. The plugin sandbox does not
-- expose `std`, and these only ever run AFTER `nova.file_info` has confirmed
-- the path is a file — so the file/dir decision stays on the Zig side
-- (cross-platform). Splitting on either '/' or '\' mirrors Nova's own
-- separator-agnostic path handling and is safe on Windows and POSIX alike.
local function dirname_of(p)
  local last = 0
  for i = 1, #p do
    local c = p:sub(i, i)
    if c == "/" or c == "\\" then last = i end
  end
  if last == 0 then return "." end
  return p:sub(1, last - 1)
end

local function basename_of(p)
  local last = 0
  for i = 1, #p do
    local c = p:sub(i, i)
    if c == "/" or c == "\\" then last = i end
  end
  return p:sub(last + 1)
end

-- Resolve a user-supplied `path` into a (root_dir, restriction) pair.
-- Cross-platform file/dir discrimination is delegated to `nova.file_info`
-- (Zig: sanitizePath + stat.kind — identical on Windows and Linux). We never
-- guess file-vs-directory from the path string, which would diverge across
-- platforms (no realpath on Windows, different separators).
-- Returns:
--   dir, nil            when path is a directory (or discrimination failed)
--   dir, basename       when path is a single file: search its parent dir and
--                       restrict results to that one file by name.
local function resolve_search_root(path)
  local root = path or "."
  local ok, info = pcall(function() return nova.file_info(root) end)
  if ok and info and info.type == "file" then
    return dirname_of(root), basename_of(root)
  end
  return root, nil
end

-- Substring search via Nova's native walker — the primary substring path.
-- Self-contained (no external binary). Scope: skips dotfiles but NOT
-- gitignored dirs, so vendor/ and zig-cache/ are searched; for a
-- gitignore-aware search use regex=true (ripgrep) or bash with rg.
-- `file_restriction` (optional) restricts the walk to a single file by name
-- (used when `path` pointed at a file); it is merged with any `params.include`.
local function native_substring_search(params, root, case_sensitive, max_results, file_restriction)
  local file_pattern = params.include
  if file_restriction and file_restriction ~= "" then
    file_pattern = file_restriction
  end
  local result = nova.search_files(root, params.pattern, {
    file_pattern = file_pattern,
    case_sensitive = case_sensitive,
    max_results = max_results,
  })
  if result == nil then
    return "Error: could not search " .. root
  end
  if result.total_matches == 0 then
    return "No matches found for: " .. params.pattern
  end

  local by_file = {}
  local file_order = {}
  for _, m in ipairs(result.results or {}) do
    if not by_file[m.file] then
      by_file[m.file] = {}
      table.insert(file_order, m.file)
    end
    table.insert(by_file[m.file], m)
  end

  local out = {}
  local shown = #(result.results or {})
  if result.truncated then
    table.insert(out, string.format("Found %d matches (showing first %d, more available):", result.total_matches, shown))
  else
    table.insert(out, string.format("Found %d matches:", result.total_matches))
  end
  table.insert(out, "")
  for _, file in ipairs(file_order) do
    table.insert(out, file .. ":")
    for _, m in ipairs(by_file[file]) do
      table.insert(out, string.format("  Line %d: %s", m.line, m.content))
    end
    table.insert(out, "")
  end
  return table.concat(out, "\n"):gsub("\n$", "")
end

-- ── grep ────────────────────────────────────────────────────────────

nova.register_tool({
  name = "grep",
  description = "Search file contents recursively. Returns matches grouped by file as `path:` headers with indented `Line N: <content>` entries. By default does a literal substring search with Nova's built-in search (no external tools; skips dotfiles but scans gitignored dirs like vendor/). Set regex=true for full regular expressions (alternation `a|b`, `.*`, character classes) via ripgrep, which respects .gitignore and requires `rg` installed. Supports an `include` glob filter (e.g. '*.zig'). To count matches within files, use bash with rg directly instead of this tool.",
  parameters = {
    pattern = {
      type = "string",
      description = "Text pattern to search for",
    },
    path = {
      type = "string",
      description = "Root directory to search in (default: project root)",
      optional = true,
    },
    include = {
      type = "string",
      description = "File glob filter (e.g. '*.zig', '*.lua')",
      optional = true,
    },
    regex = {
      type = "boolean",
      description = "Treat pattern as a regex via ripgrep (default false = literal substring via built-in search)",
      optional = true,
    },
    case_sensitive = {
      type = "boolean",
      description = "Case-sensitive search (default false)",
      optional = true,
    },
    max_results = {
      type = "integer",
      description = "Maximum matches to return (default 50, max 200)",
      optional = true,
    },
  },
  handler = function(params)
    local root, file_restriction = resolve_search_root(params.path)
    local case_sensitive = params.case_sensitive or false
    -- Clamp to a positive integer (defense in depth with the Zig-side clamp):
    -- a fractional/negative max_results would otherwise reach the bridge and
    -- (before the Zig clamp) panic on the u32 cast.
    local max_results = math.max(1, math.min(math.floor(params.max_results or 50), 200))

    -- Substring (default): Nova's native search. Self-contained, no external
    -- binary, identical behavior in every environment.
    if not params.regex then
      return native_substring_search(params, root, case_sensitive, max_results, file_restriction)
    end

    -- Regex: ripgrep via bash (search_files is substring-only; Lua patterns
    -- are not PCRE). Quoting in build_rg_command keeps `|`, spaces, etc. from
    -- being parsed by the shell.
    local cmd = build_rg_command(params.pattern, root, params.include, case_sensitive)
    -- rg over large repos can exceed the 30 s default; give it a 60 s budget.
    local shell_runner = nova.run_shell or nova.run_bash
    local bash_result = shell_runner(cmd, { cwd = root, timeout = 60 })

    if bash_result == nil then
      return "Error: regex search failed"
    end
    if bash_result.code == 127 then
      return "Error: regex search needs ripgrep (rg), which is not installed"
    end
    if bash_result.code == 2 then
      return "Error: invalid regex pattern: " .. (bash_result.stderr or "")
    end
    if bash_result.code == 1 or bash_result.stdout == "" then
      return "No matches found for: " .. params.pattern
    end
    return group_rg_output(bash_result.stdout, params.pattern, max_results)
  end,
})

-- ── glob ────────────────────────────────────────────────────────────

nova.register_tool({
  name = "glob",
  description = "Find files by name using a glob pattern (e.g. '**/*.zig', 'src/**/*.ts'). Returns matching file paths, one per line. Skips dotfiles. Fast and works on any codebase size. When searching, you can call this tool multiple times in a single response with different patterns to find files efficiently.",
  parameters = {
    pattern = {
      type = "string",
      description = "Glob pattern (supports **, *, ? — e.g. '**/*.zig', 'src/**/*.ts')",
    },
    path = {
      type = "string",
      description = "Root directory to search in (default: project root)",
      optional = true,
    },
    max_results = {
      type = "integer",
      description = "Maximum results (default 100)",
      optional = true,
    },
  },
  handler = function(params)
    local root, file_restriction = resolve_search_root(params.path)
    local max_results = math.max(1, math.min(math.floor(params.max_results or 100), 200))
    local opts = { max_results = max_results }

    local result = nova.find_files(root, params.pattern, opts)
    if result == nil then
      return "Error: glob failed for " .. params.pattern
    end

    -- When `path` pointed at a single file, keep only that file (the walk
    -- happened in its parent dir). Restriction is by basename, so it works
    -- regardless of the user's glob pattern.
    local matches = result.results or {}
    if file_restriction and file_restriction ~= "" then
      local filtered = {}
      for _, f in ipairs(matches) do
        if basename_of(f.path) == file_restriction then
          table.insert(filtered, f)
        end
      end
      matches = filtered
    end

    if #matches == 0 then
      return "No files found matching: " .. params.pattern
    end

    local lines = {}
    table.insert(lines, string.format("Found %d files:", #matches))
    if result.truncated then
      table.insert(lines, "(results truncated — narrow your pattern or pass max_results)")
    end
    table.insert(lines, "")
    for _, f in ipairs(matches) do
      table.insert(lines, f.path)
    end
    return table.concat(lines, "\n")
  end,
})
