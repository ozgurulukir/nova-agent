-- init.lua — sitting-duck
--
-- Wraps the duckdb CLI + the sitting_duck community extension so the model
-- can query tree-sitter ASTs with SQL. First example plugin consuming the
-- post-repair SDK surface:
--   * plugin.get_config() — binary resolution, called per tool call (nil
--     when unconfigured; never raises — see docs/plugins/api-reference.md).
--   * nova.shell_quote() — POSIX dialect (the default) for every run_bash
--     command line; quoting is what keeps the classified command equal to
--     the executed command.
--
-- Architecture: SQL travels in a FILE, never on the shell command line —
-- `.nova/sitting-duck/query.sql` is staged via nova.write_file (atomic) and
-- fed to duckdb with `<` redirection. The file doubles as a debug artifact:
-- every query error message points at it. The extension bootstraps lazily
-- on the first tool call (INSTALL before LOAD — a cold machine has nothing
-- to LOAD yet); success is cached in `.nova/sitting-duck/state.json` and
-- re-verified against `duckdb --version` once per session so a duckdb
-- upgrade triggers a re-install. Zero I/O happens at load time: any
-- init.lua error disables the whole plugin.
--
-- Handlers never raise; every failure path returns an "Error: ..." string
-- so the model can self-correct on the next call.

-- ── constants ───────────────────────────────────────────────────────

local WORK_DIR    = ".nova/sitting-duck"
local QUERY_PATH  = WORK_DIR .. "/query.sql"
local MARKER_PATH = WORK_DIR .. "/state.json"
local DEFAULT_BIN = "duckdb"
local ENV_BIN     = "NOVA_SITTING_DUCK_BIN"
local DEFAULT_LIMIT = 50
local MAX_LIMIT   = 200
local VERSION_TIMEOUT_S   = 10
local BOOTSTRAP_TIMEOUT_S = 300
local QUERY_TIMEOUT_S     = 60

-- Queries assume the extension is installed. The bootstrap script has its
-- own prelude (INSTALL before LOAD).
local PRELUDE = ".mode json\nLOAD sitting_duck;\n"
-- Single edit point for read_ast schema drift. Verified against the
-- sitting_duck community extension (duckdb v1.5.5): the node-kind column
-- is `type` (NOT node_type) — full rows also carry semantic_type (an enum:
-- cast to VARCHAR to compare), language, parent_id, depth, peek, ...
local COLS = "node_id, type, file_path, name, start_line, end_line"

-- Session cache: false until the marker+version check (or a bootstrap)
-- succeeds in this Lua state.
local sd_ready = false

-- ── small helpers ───────────────────────────────────────────────────

local function q(s)
  return nova.shell_quote(s)
end

-- SQL single-quoted literal. DuckDB standard literals do not process
-- backslash escapes, so globs like `**/*.zig` pass through untouched.
local function sql_str(s)
  return "'" .. tostring(s):gsub("'", "''") .. "'"
end

-- The SQL side has no sanitizePath — duckdb resolves read_ast/ast_match
-- paths itself, so the plugin mirrors the confinement lexically: relative
-- paths only, no `..` components, no URL schemes, no `~`, no drive
-- prefixes. Residual (documented in prompt.md): symlinks inside the
-- project can still point reads outside it — globs cannot be realpath'd
-- from Lua; the ast_get_source file half IS realpath-checked by the
-- bridge's own sanitizePath.
local function safe_rel_path(s)
  if type(s) ~= "string" or s == "" then return false end
  if s:sub(1, 1) == "/" or s:sub(1, 1) == "\\" then return false end
  if s:sub(1, 1) == "~" then return false end
  if s:match("^%a:") then return false end
  if s:find("://", 1, true) then return false end
  for part in s:gmatch("[^/\\]+") do
    -- Win32 strips trailing dots/spaces from components, so `.. `, `.. .`,
    -- etc. are parent hops too: two leading dots followed only by
    -- dots/whitespace.
    if part:match("^%.%.[%s%.]*$") ~= nil then return false end
  end
  return true
end

-- Enforce ONE statement with no dot-command lines. The CLI executes
-- everything in the staged file — dot commands included — so a chained
-- `COPY ... TO` after a `;`, or a `.shell`/`.output` line, would run even
-- when the first word is SELECT. The scan tracks string literals,
-- quoted identifiers, dollar-quoted strings, and comments so a `;`
-- inside quoted text does not split statements; anything the scan
-- misreads as quoted text that DuckDB treats as code fails later as a
-- DuckDB parse error (never as an executed second statement).
local function single_statement_no_dot_commands(sql)
  local i, n = 1, #sql
  local statements = 0
  local seen_content = false
  while i <= n do
    local c = sql:sub(i, i)
    if c == "'" then
      i = i + 1
      while i <= n do
        if sql:sub(i, i) == "'" then
          if sql:sub(i + 1, i + 1) == "'" then
            i = i + 2
          else
            i = i + 1
            break
          end
        else
          i = i + 1
        end
      end
      seen_content = true
    elseif c == '"' then
      i = i + 1
      while i <= n and sql:sub(i, i) ~= '"' do i = i + 1 end
      i = i + 1
      seen_content = true
    elseif c == "$" and sql:sub(i + 1, i + 1) == "$" then
      local close = sql:find("$$", i + 2, true)
      i = (close == nil) and (n + 1) or (close + 2)
      seen_content = true
    elseif c == "-" and sql:sub(i + 1, i + 1) == "-" then
      while i <= n and sql:sub(i, i) ~= "\n" do i = i + 1 end
    elseif c == "/" and sql:sub(i + 1, i + 1) == "*" then
      local close = sql:find("*/", i + 2, true)
      i = (close == nil) and (n + 1) or (close + 2)
    elseif c == ";" then
      if seen_content then statements = statements + 1 end
      if statements > 1 then return false end
      seen_content = false
      i = i + 1
    elseif c == "\n" then
      local j = i + 1
      while j <= n and (sql:sub(j, j) == " " or sql:sub(j, j) == "\t") do j = j + 1 end
      if sql:sub(j, j) == "." then return false end
      i = i + 1
    else
      if c ~= " " and c ~= "\t" and c ~= "\r" then seen_content = true end
      i = i + 1
    end
  end
  -- A single trailing `;` is fine; content after a completed statement is
  -- a second (possibly unterminated) statement.
  if statements >= 1 and seen_content then return false end
  return true
end

local function path_error(what)
  return "Error: " .. what .. " must be a relative path inside the project"
    .. " (absolute paths and '..' components are not allowed)."
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function clamp_limit(v)
  local n = math.floor(tonumber(v) or DEFAULT_LIMIT)
  return math.max(1, math.min(n, MAX_LIMIT))
end

-- Last few non-empty stderr lines, flattened for an error message.
local function stderr_tail(stderr, n)
  local lines = {}
  for line in tostring(stderr or ""):gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end
  if #lines == 0 then return "" end
  local take = math.min(n or 3, #lines)
  local out = {}
  for i = #lines - take + 1, #lines do
    table.insert(out, lines[i])
  end
  return table.concat(out, " | ")
end

-- `.mode json` emits a top-level array; accept a bare object too so a mode
-- drift degrades to a parsed row instead of a spurious E5.
local function first_row(decoded)
  if type(decoded) ~= "table" then return nil end
  if type(decoded[1]) == "table" then return decoded[1] end
  if decoded.status ~= nil then return decoded end
  return nil
end

local function mentions_version_issue(stderr)
  local s = tostring(stderr or ""):lower()
  return s:find("version", 1, true) ~= nil
    or s:find("compatible", 1, true) ~= nil
    or s:find("abi", 1, true) ~= nil
end

local function extension_lost(stderr)
  local s = tostring(stderr or ""):lower()
  if s:find("catalog error", 1, true) == nil then return false end
  -- Catalog errors name the missing FUNCTION, not the extension — match
  -- every extension surface so a drift that unregisters only read_ast
  -- still self-heals instead of wedging on generic E5 forever.
  return s:find("sitting_duck", 1, true) ~= nil
    or s:find("read_ast", 1, true) ~= nil
    or s:find("ast_match", 1, true) ~= nil
end

local function truncate_cell(s, n)
  s = tostring(s or "")
  if #s <= n then return s end
  return s:sub(1, n) .. "…"
end

-- ── binary resolution & durable state ───────────────────────────────

-- plugin.get_config() has no raise path: unconfigured → nil, malformed
-- settings → nil+err (which falls through to the env var — a bad config
-- blob must not disable env/default resolution). Resolved per call so
-- tests can swap the config against one loaded instance.
local function resolve_bin()
  local cfg = plugin and plugin.get_config and plugin.get_config()
  if type(cfg) == "table" and type(cfg.duckdb_path) == "string" then
    local p = trim(cfg.duckdb_path)
    if p ~= "" then return p end
  end
  local env = nova.get_env(ENV_BIN)
  if type(env) == "string" and trim(env) ~= "" then
    return trim(env)
  end
  return DEFAULT_BIN
end

-- todo-plugin sidecar pattern: missing or corrupt marker → nil, never a
-- crash; the plugin just re-bootstraps.
local function read_marker()
  local result = nova.read_file(MARKER_PATH, {})
  if result == nil then return nil end
  local decoded = nova.json_decode(result.content)
  if type(decoded) ~= "table" then return nil end
  return decoded
end

local function write_marker(version)
  nova.mkdir(WORK_DIR)
  local json = nova.json_encode({
    bootstrapped = true,
    duckdb_version = version,
    verified_at = os.time(),
  }, { pretty = true })
  if json == nil then return nil, "could not encode marker" end
  if nova.write_file(MARKER_PATH, json) == nil then
    return nil, "could not write marker"
  end
  return true
end

local function clear_marker()
  nova.delete_path(MARKER_PATH)
end

-- ── error messages (E1 split: bash missing ≠ duckdb missing) ─────────

local function e1_duckdb()
  return "Error: duckdb CLI not found (exit 127). Install DuckDB"
    .. " (https://duckdb.org/docs/install/), or set"
    .. " plugins.sitting-duck.settings.duckdb_path in config.json, or set"
    .. " " .. ENV_BIN .. " to the binary path."
end

local function e1_bash()
  return "Error: a POSIX shell is required to run duckdb (input redirection)"
    .. " but is not available. On Windows install Git Bash or use WSL; on"
    .. " POSIX check that bash is installed."
end

-- ── SQL builders (pure; single edit points for schema drift) ────────
-- Defined before the runner: ensure_ready calls bootstrap_sql, and a Lua
-- local is only visible as an upvalue to closures defined AFTER it.

local function bootstrap_sql()
  return ".mode json\n"
    .. "INSTALL sitting_duck FROM community;\n"
    .. "LOAD sitting_duck;\n"
    .. "SELECT 'ready' AS status;\n"
end

-- LIKE-family matching survives grammar naming differences
-- (function_definition vs function_declaration) across the 27 grammars.
local function outline_sql(glob, kinds, limit)
  local filters = {}
  for k in tostring(kinds or "function,class"):gmatch("[^,%s]+") do
    table.insert(filters, "type LIKE " .. sql_str("%" .. k .. "%"))
  end
  if #filters == 0 then
    table.insert(filters, "type LIKE " .. sql_str("%function%"))
  end
  return PRELUDE
    .. "SELECT " .. COLS .. "\n"
    .. "FROM read_ast(" .. sql_str(glob) .. ")\n"
    .. "WHERE (" .. table.concat(filters, "\n    OR ") .. ")\n"
    .. "ORDER BY file_path, start_line\n"
    .. "LIMIT " .. string.format("%d", limit) .. ";\n"
end

-- ast_match's language parameter has no auto-detect (macro default is
-- 'python'), so infer it from the glob's extension when the caller omits
-- it. Only extensions whose sitting_duck language name is short and
-- unambiguous are mapped; everything else must pass `language` explicitly.
local LANG_BY_EXT = {
  zig = "zig", py = "python", js = "javascript", mjs = "javascript",
  ts = "typescript", tsx = "typescript", go = "go", rs = "rust",
  c = "c", h = "c", cpp = "cpp", cc = "cpp", cxx = "cpp", hpp = "cpp",
  java = "java", rb = "ruby", lua = "lua",
}

local function infer_language(glob)
  local ext = glob:match("%.([%w]+)%s*$")
  -- A glob's tail may carry pattern runes inside the "extension" ('*.z*');
  -- only a clean extension maps.
  if ext == nil or ext:find("[%*%?]") then return nil end
  return LANG_BY_EXT[ext:lower()]
end

-- The ast_match call shape is centralized here: if the extension's
-- signature drifts, this one block is the fix (plus its pinned test).
-- Real signature (sitting_duck SQL macro, verified against duckdb v1.5.5):
--   ast_match(source_glob, pattern_str, language)
-- ast_match feeds `source` straight to read_ast(source, language) and the
-- language macro-defaults to 'python' — with no explicit language, every
-- non-python file under the glob is elided and the call dies with
-- "read_ast needs at least one file to read". So the plugin ALWAYS passes
-- the language, inferring it from the glob's extension when omitted.
-- Output: one row per match — match_id, root_node_id (resolvable as a
-- read_ast node_id; verified stable across invocations for the same file),
-- file_path, start_line, end_line, peek, and a captures map
-- (name → LIST of {capture, node_id, type, name, peek, start_line,
-- end_line}).
local function pattern_sql(pattern, glob, language, limit)
  return PRELUDE
    .. "SELECT root_node_id AS node_id, file_path, start_line, end_line, peek, captures\n"
    .. "FROM ast_match(" .. sql_str(glob or "**/*") .. ", " .. sql_str(pattern)
    .. ", " .. sql_str(language) .. ")\n"
    .. "ORDER BY file_path, start_line\n"
    .. "LIMIT " .. string.format("%d", limit) .. ";\n"
end

-- Resolve one node's line span; the source text itself comes from
-- nova.read_file, not from SQL — one fewer extension surface to trust.
local function span_sql(file, node_id)
  return PRELUDE
    .. "SELECT node_id, type, name, start_line, end_line\n"
    .. "FROM read_ast(" .. sql_str(file) .. ")\n"
    .. "WHERE node_id = " .. sql_str(tostring(node_id)) .. "\n"
    .. "LIMIT 1;\n"
end

-- ── runner ──────────────────────────────────────────────────────────

-- Stage `sql` into the query file and run it. The command line is a fixed
-- template: only the quoted binary path varies, and the SQL never touches
-- the shell — glob metacharacters and model-supplied SQL stay inert inside
-- the file duckdb itself parses.
local function run_script(bin, sql, timeout_s)
  nova.mkdir(WORK_DIR)
  local ok, werr = nova.write_file(QUERY_PATH, sql)
  if ok == nil then
    return nil, "could not stage query.sql: " .. tostring(werr or "?")
  end
  local cmd = q(bin) .. " -json -init /dev/null < " .. q(QUERY_PATH)
  return nova.run_bash(cmd, { timeout = timeout_s })
end

-- Cold → checking → ready. Returns nil when ready, else an error string.
local function ensure_ready()
  if sd_ready then return nil end

  local bin = resolve_bin()

  -- One cheap dispatch per session: detect missing duckdb/bash early and
  -- capture the version string for the drift check.
  local res, rerr = nova.run_bash(q(bin) .. " --version", { timeout = VERSION_TIMEOUT_S })
  if res == nil then
    local e = tostring(rerr)
    if e:find("ShellUnavailable", 1, true) then return e1_bash() end
    if e:find("UnsafeShellBlocked", 1, true) then return "Error: " .. e end
    return "Error: could not run duckdb --version: " .. e
  end
  if res.code == 127 then return e1_duckdb() end
  if res.code ~= 0 then
    return "Error: duckdb --version failed (code " .. res.code .. "): "
      .. stderr_tail(res.stderr, 2)
  end
  local version = trim(res.stdout)
  if version == "" then version = "unknown" end

  local marker = read_marker()
  if marker ~= nil and type(marker.duckdb_version) == "string"
    and marker.duckdb_version == version then
    sd_ready = true
    return nil
  end

  -- Bootstrap: INSTALL before LOAD (a cold machine has no extension yet).
  -- INSTALL is idempotent and only this script ever touches the network.
  local bres, berr = run_script(bin, bootstrap_sql(), BOOTSTRAP_TIMEOUT_S)
  if bres == nil then
    local e = tostring(berr)
    if e:find("ShellUnavailable", 1, true) then return e1_bash() end
    if e:find("UnsafeShellBlocked", 1, true) then return "Error: " .. e end
    return "Error: bootstrap failed: " .. e
  end
  if bres.code == 127 then return e1_duckdb() end
  if bres.code ~= 0 then
    if mentions_version_issue(bres.stderr) then
      return "Error: version mismatch — the sitting_duck community extension"
        .. " is built for a specific DuckDB release. Running: " .. version
        .. ". Install a matching duckdb (or point"
        .. " plugins.sitting-duck.settings.duckdb_path / " .. ENV_BIN
        .. " at one) and retry. Detail: " .. stderr_tail(bres.stderr, 3)
    end
    return "Error: sitting_duck extension install failed: "
      .. stderr_tail(bres.stderr, 3)
      .. " — the one-time INSTALL downloads from"
      .. " community-extensions.duckdb.org; check network access and retry."
  end
  local row = first_row(nova.json_decode(bres.stdout or ""))
  if row == nil or row.status ~= "ready" then
    return "Error: bootstrap completed but did not report ready."
      .. " stdout: " .. truncate_cell(bres.stdout, 200)
      .. " stderr: " .. stderr_tail(bres.stderr, 3)
      .. " — the exact script sent is at " .. QUERY_PATH
  end

  -- Best-effort: a failed marker write only costs a re-bootstrap next
  -- session; the in-memory flag is set regardless.
  write_marker(version)
  sd_ready = true
  return nil
end

-- Shared pipeline for every tool: readiness → stage+run → classify the
-- failure → decode. Returns rows, or nil + error string.
local function run_query(sql)
  local rerr = ensure_ready()
  if rerr ~= nil then return nil, rerr end

  local res, err = run_script(resolve_bin(), sql, QUERY_TIMEOUT_S)
  if res == nil then
    local e = tostring(err)
    if e:find("StreamTooLong", 1, true) then
      return nil, "Error: query output exceeded the 512KB stream cap and was"
        .. " discarded. Rerun with a LIMIT (<= " .. MAX_LIMIT
        .. "), fewer columns, or a narrower glob."
    end
    if e:find("UnsafeShellBlocked", 1, true) then return nil, "Error: " .. e end
    if e:find("ShellUnavailable", 1, true) then return nil, e1_bash() end
    return nil, "Error: could not run duckdb: " .. e
  end
  if res.code == 127 then return nil, e1_duckdb() end
  if res.code ~= 0 then
    if extension_lost(res.stderr) then
      clear_marker()
      sd_ready = false
      return nil, "Error: the sitting_duck extension is no longer loaded"
        .. " (duckdb binary changed?). The bootstrap marker was cleared —"
        .. " call this tool again to re-install the extension."
    end
    return nil, "Error: duckdb query failed: " .. stderr_tail(res.stderr, 3)
      .. " — the exact script sent is at " .. QUERY_PATH
  end
  local rows = nova.json_decode(res.stdout or "")
  if type(rows) ~= "table" then
    return nil, "Error: could not parse duckdb output — the exact script"
      .. " sent is at " .. QUERY_PATH
  end
  return rows
end

-- ── shaping (compact markdown; never raw JSON — the display layer
--    pretty-prints JSON-parseable strings and balloons token cost) ────

local function shape_outline(rows, glob, limit)
  if #rows == 0 then
    return "No AST symbols found for " .. glob
      .. " (try a broader kinds filter or a wider glob)."
  end
  local out = {}
  table.insert(out, string.format("## AST outline — %s (%d shown)", glob, #rows))
  local current_file = nil
  for _, r in ipairs(rows) do
    if r.file_path ~= current_file then
      current_file = r.file_path
      table.insert(out, "")
      table.insert(out, tostring(current_file) .. ":")
    end
    table.insert(out, string.format("  L%d-%d %s %s (node_id: %s)",
      tonumber(r.start_line) or 0, tonumber(r.end_line) or 0,
      truncate_cell(r.type or "?", 30),
      truncate_cell(r.name or r.type or "?", 60),
      tostring(r.node_id or "?")))
  end
  if #rows >= limit then
    table.insert(out, "")
    table.insert(out, string.format(
      "(truncated at %d — pass a higher limit, up to %d, or narrow the glob)",
      limit, MAX_LIMIT))
  end
  return table.concat(out, "\n")
end

local function shape_pattern(rows, pattern)
  if #rows == 0 then
    return "No structural matches for the pattern."
  end
  local out = {}
  table.insert(out, string.format("## Structural matches — %s (%d shown)",
    truncate_cell(pattern, 60), #rows))
  for _, r in ipairs(rows) do
    -- captures is a map: name → LIST of {capture, node_id, type, name,
    -- peek, start_line, end_line}. Render the first entry per name,
    -- sorted — JSON object key order is not contractual.
    local caps = {}
    for cname, list in pairs(r.captures or {}) do
      local c = (type(list) == "table") and list[1] or nil
      if type(c) == "table" then
        table.insert(caps, string.format("%s=%s (%s)", cname,
          truncate_cell(tostring(c.name or "?"), 40),
          truncate_cell(tostring(c.type or "?"), 30)))
      end
    end
    table.sort(caps)
    local cap_str = (#caps > 0) and (" " .. table.concat(caps, " ")) or ""
    table.insert(out, string.format("%s:L%d-%d%s node_id: %s",
      tostring(r.file_path or "?"),
      tonumber(r.start_line) or 0, tonumber(r.end_line) or 0, cap_str,
      tostring(r.node_id or "?")))
  end
  return table.concat(out, "\n")
end

local function shape_span(node, file, content, first_line)
  local out = {}
  table.insert(out, string.format("%s %s — %s L%d-L%d",
    tostring(node.type or "node"),
    tostring(node.name or "(anonymous)"),
    file, tonumber(node.start_line) or 0, tonumber(node.end_line) or 0))
  table.insert(out, "")
  -- Split keeping EMPTY lines: the bridge's read_file keeps them (it slices
  -- by \n positions), and dropping one would shift every number after it.
  local body = (tostring(content):gsub("\r\n", "\n"))
  if body:sub(-1) == "\n" then body = body:sub(1, -2) end
  if #body > 0 then
    local lineno = first_line
    local start = 1
    while start <= #body + 1 do
      local nl = body:find("\n", start, true) or (#body + 1)
      table.insert(out, string.format("%5d| %s", lineno, body:sub(start, nl - 1)))
      lineno = lineno + 1
      if nl > #body then break end
      start = nl + 1
    end
  end
  return table.concat(out, "\n")
end

-- Generic renderer for raw SQL results: every present key as k=v cells.
-- Deterministic key order (sorted) because .mode json object key order is
-- not contractual. Nested values (LIST/STRUCT columns from aggregates)
-- render as their JSON form, not "table: 0x…".
local function shape_rows(rows, header)
  if #rows == 0 then
    return "Query returned 0 rows."
  end
  local keys = {}
  local seen = {}
  for _, r in ipairs(rows) do
    for k in pairs(r) do
      if not seen[k] then
        seen[k] = true
        table.insert(keys, k)
      end
    end
  end
  table.sort(keys)
  local out = {}
  table.insert(out, string.format("## %s (%d shown)", header, #rows))
  for _, r in ipairs(rows) do
    local cells = {}
    for _, k in ipairs(keys) do
      local v = r[k]
      if v ~= nil then
        if type(v) == "table" then
          local j = nova.json_encode(v)
          v = (j ~= nil) and j or "?"
        end
        table.insert(cells, k .. "=" .. truncate_cell(v, 120))
      end
    end
    table.insert(out, "- " .. (#cells > 0 and table.concat(cells, " ") or "(empty row)"))
  end
  return table.concat(out, "\n")
end

-- ── tool: ast_outline ───────────────────────────────────────────────

nova.register_tool({
  name = "ast_outline",
  description = "List code structure (functions, classes, methods) from"
    .. " tree-sitter ASTs queried with SQL. Pass a glob like 'src/**/*.zig'"
    .. " or a single file path. Returns one line per symbol: kind, name,"
    .. " line range, and a node_id handle. Requires the duckdb CLI —"
    .. " configure plugins.sitting-duck.settings.duckdb_path in config.json,"
    .. " or set NOVA_SITTING_DUCK_BIN, or have 'duckdb' on PATH; the"
    .. " sitting_duck extension auto-installs on first call (may take"
    .. " minutes). Output is bounded: LIMIT defaults to 50 (max 200) and"
    .. " tool output is hard-capped at 512KB. Use node_id with"
    .. " ast_get_source to read a symbol's source.",
  parameters = {
    glob = {
      type = "string",
      description = "File path or glob, e.g. 'src/**/*.zig' or 'src/main.zig'",
    },
    kinds = {
      type = "string",
      optional = true,
      default = "function,class",
      description = "Comma-separated symbol families: function, class,"
        .. " method, struct, interface",
    },
    limit = {
      type = "number",
      optional = true,
      default = 50,
      description = "Max rows to return (clamped to 1-200)",
    },
  },
  handler = function(params)
    local glob = params.glob
    if type(glob) ~= "string" or trim(glob) == "" then
      return "Error: glob is required (e.g. 'src/**/*.zig')."
    end
    if not safe_rel_path(glob) then return path_error("glob") end
    local limit = clamp_limit(params.limit)
    local rows, err = run_query(outline_sql(glob, params.kinds, limit))
    if rows == nil then return err end
    return shape_outline(rows, glob, limit)
  end,
})

-- ── tool: ast_find_pattern ──────────────────────────────────────────

nova.register_tool({
  name = "ast_find_pattern",
  description = "Structural code search with sitting_duck's text patterns:"
    .. " write a minimal code skeleton in the target language and mark the"
    .. " parts to capture with __NAME__ wildcards (uppercase names) or __"
    .. " (anonymous); every literal in the skeleton must match exactly."
    .. " Examples: zig 'fn __FN__(__) void {}' finds void-returning"
    .. " functions (zig skeletons need the return type to parse), python"
    .. " 'def __F__(__):'. language is inferred from the glob's extension"
    .. " (.zig → zig, .py → python, ...) or passed explicitly. Returns one"
    .. " row per match: file, line span, captures, and the matched root's"
    .. " node_id — usable with ast_get_source. Requires the duckdb CLI"
    .. " (plugins.sitting-duck.settings.duckdb_path / NOVA_SITTING_DUCK_BIN"
    .. " / PATH). LIMIT defaults to 50 (max 200); output hard-capped at"
    .. " 512KB.",
  parameters = {
    pattern = {
      type = "string",
      description = "Code skeleton in the target language with __NAME__"
        .. " wildcards, e.g. 'fn __FN__(__) void {}' (zig) or"
        .. " 'def __F__(__):' (python)",
    },
    glob = {
      type = "string",
      optional = true,
      default = "**/*",
      description = "File glob to search",
    },
    language = {
      type = "string",
      optional = true,
      description = "sitting_duck language name (zig, python, typescript,"
        .. " ...). Inferred from the glob's extension when omitted;"
        .. " required for extension-less globs like '**/*'",
    },
    limit = {
      type = "number",
      optional = true,
      default = 50,
      description = "Max matches to return (clamped to 1-200)",
    },
  },
  handler = function(params)
    local pattern = params.pattern
    if type(pattern) ~= "string" or trim(pattern) == "" then
      return "Error: pattern is required (a code skeleton with __NAME__"
        .. " wildcards, e.g. 'fn __FN__(__) void {}')."
    end
    local glob = params.glob or "**/*"
    if not safe_rel_path(glob) then return path_error("glob") end
    local language = trim(tostring(params.language or ""))
    if language == "" then
      language = infer_language(glob) or ""
    end
    if language == "" then
      return "Error: language is required for this glob (no recognizable"
        .. " file extension) — pass it explicitly, e.g. 'zig' or 'python'."
    end
    local limit = clamp_limit(params.limit)
    local rows, err = run_query(pattern_sql(pattern, glob, language, limit))
    if rows == nil then return err end
    return shape_pattern(rows, pattern)
  end,
})

-- ── tool: ast_get_source ────────────────────────────────────────────

nova.register_tool({
  name = "ast_get_source",
  description = "Fetch the source text of one AST node: pass a file plus"
    .. " the node_id reported by ast_outline or ast_find_pattern. Returns"
    .. " the exact lines with line numbers, plus optional surrounding"
    .. " context lines (0-20, default 0). node_ids are stable only while"
    .. " the file is unchanged — after edits, re-run ast_outline. Requires"
    .. " the duckdb CLI (plugins.sitting-duck.settings.duckdb_path /"
    .. " NOVA_SITTING_DUCK_BIN / PATH).",
  parameters = {
    file = {
      type = "string",
      description = "Path of the file containing the node",
    },
    node_id = {
      type = "string",
      description = "node_id from ast_outline or ast_find_pattern",
    },
    context_lines = {
      type = "number",
      optional = true,
      default = 0,
      description = "Extra lines of context around the node (clamped to 0-20)",
    },
  },
  handler = function(params)
    local file = params.file
    if type(file) ~= "string" or trim(file) == "" then
      return "Error: file is required."
    end
    if not safe_rel_path(file) then return path_error("file") end
    if params.node_id == nil or tostring(params.node_id) == "" then
      return "Error: node_id is required."
    end
    local ctx = math.max(0, math.min(math.floor(tonumber(params.context_lines) or 0), 20))

    local rows, err = run_query(span_sql(file, params.node_id))
    if rows == nil then return err end
    local node = rows[1]
    if node == nil then
      return "No node " .. tostring(params.node_id) .. " in " .. file
        .. " — the id may be stale after edits; re-run ast_outline."
    end

    -- Two-step drill-down: the row resolves the line span; the source is
    -- sliced by nova.read_file's own line options.
    local sl = tonumber(node.start_line) or 1
    local el = tonumber(node.end_line) or sl
    local first = math.max(1, sl - ctx)
    local last = el + ctx
    local read = nova.read_file(file, { start_line = first, end_line = last })
    if read == nil then
      return "Error: could not read " .. file
    end
    return shape_span(node, file, read.content, first)
  end,
})

-- ── tool: ast_query ─────────────────────────────────────────────────

-- Verbatim passthrough — no rewrite, no appended ';'. The staged file is
-- the debug artifact for whatever the model wrote.
local function wrap_query(user_sql)
  return PRELUDE .. user_sql
end

nova.register_tool({
  name = "ast_query",
  description = "Escape hatch: run raw DuckDB SQL against the sitting_duck"
    .. " read_ast() table — aggregates, joins, and counts the dedicated"
    .. " tools cannot express. Columns include node_id, type, name,"
    .. " file_path, language, start_line, end_line, semantic_type (an enum —"
    .. " cast to VARCHAR to compare), parent_id, depth, peek. Structural"
    .. " predicates via ast_match(glob, pattern, language) — the language is"
    .. " NOT auto-detected there (it defaults to 'python'). One READ-ONLY"
    .. " statement per call: it must start"
    .. " with SELECT or WITH; chained statements after a ';' and"
    .. " dot-command lines (.shell, .output, ...) are rejected —"
    .. " COPY/INSTALL/ATTACH/EXPORT cannot run. Reads inside the SQL are"
    .. " bounded only by DuckDB itself (e.g. read_csv can reach files"
    .. " outside the project) — prefer the dedicated tools' path"
    .. " parameters. Include a LIMIT (recommended <= 200); output above"
    .. " 512KB fails with StreamTooLong. On errors the exact script is"
    .. " kept at .nova/sitting-duck/query.sql for inspection. Requires the"
    .. " duckdb CLI (plugins.sitting-duck.settings.duckdb_path /"
    .. " NOVA_SITTING_DUCK_BIN / PATH).",
  parameters = {
    sql = {
      type = "string",
      description = "A single read-only DuckDB SQL statement starting with"
        .. " SELECT or WITH, over read_ast(...) or ast_match(...)."
        .. " Include a LIMIT.",
    },
  },
  handler = function(params)
    local sql = params.sql
    if type(sql) ~= "string" or trim(sql) == "" then
      return "Error: sql is required (a single statement over read_ast(...)"
        .. " with a LIMIT)."
    end
    -- The classifier only ever sees the fixed command template — the SQL
    -- itself is the plugin's own gate. Two layers: the first-word check
    -- (no COPY/INSTALL/ATTACH/EXPORT as the leading statement) and a
    -- quote-aware statement scan (no chained statements, no dot-command
    -- lines) — together they keep ast_query read-only even though the CLI
    -- would happily execute a whole script.
    local first_word = sql:match("^%s*(%a+)")
    if first_word == nil or (first_word ~= "SELECT" and first_word ~= "select"
      and first_word ~= "WITH" and first_word ~= "with") then
      return "Error: ast_query accepts a single read-only statement starting"
        .. " with SELECT or WITH (write statements such as COPY, INSTALL,"
        .. " ATTACH, or EXPORT are rejected)."
    end
    if not single_statement_no_dot_commands(sql) then
      return "Error: ast_query accepts ONE read-only statement: chained"
        .. " statements after a ';' and dot-command lines (e.g. .shell,"
        .. " .output) are rejected."
    end
    local rows, err = run_query(wrap_query(sql))
    if rows == nil then return err end
    local out = shape_rows(rows, "ast_query result")
    -- Soft advisory, not a rewrite: remind about the stream cap when the
    -- model forgot the LIMIT the hard backstop would otherwise enforce.
    if not sql:lower():find("limit", 1, true) then
      out = out .. "\n\n[note: no LIMIT clause in the SQL — output is"
        .. " capped at 512KB by Nova's stream cap]"
    end
    return out
  end,
})
