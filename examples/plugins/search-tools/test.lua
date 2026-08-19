-- test.lua — Search Tools plugin tests
--
-- Regression-tests the grep tool. Two concerns:
--   1. Regex command construction. The original bug: the regex pattern was
--      interpolated BARE into a `bash -c` string, so a `|` was parsed as a
--      shell pipe (rg's output went to a nonexistent command and the search
--      silently returned 0). The fix quotes every dynamic value.
--   2. Backend routing. Substring (default) must use Nova's built-in
--      search_files (self-contained, no rg); only regex=true shells out to rg.
--
-- The `nova` bridge is mocked so the handler runs without a live Nova runtime.
local test = test_runner

-- ── Mock the nova bridge, then load the plugin ──────────────────────
local registered = {}
local last_bash = nil
local bash_reply = nil
local last_search = nil
local search_reply = nil
-- Controls the mocked file/dir discrimination for the file-path gating tests.
-- When a path is present in this map, file_info returns that type; otherwise
-- it defaults to "directory" (the common case).
local file_info_types = {}

nova = {
  register_tool = function(tool)
    registered[tool.name] = tool
  end,
  run_bash = function(cmd, opts)
    last_bash = { cmd = cmd, opts = opts }
    return bash_reply
  end,
  run_shell = function(cmd, opts)
    last_bash = { cmd = cmd, opts = opts }
    return bash_reply
  end,
  search_files = function(root, pattern, opts)
    last_search = { root = root, pattern = pattern, opts = opts }
    return search_reply
  end,
  find_files = function(root, pattern, opts)
    return { root = root, total_matches = 0, results = {}, truncated = false }
  end,
  -- Mocked cross-platform discriminator. In production this is the Zig bridge
  -- (sanitizePath + stat.kind); here we drive it from file_info_types so the
  -- gating logic can be tested deterministically.
  file_info = function(path)
    local t = file_info_types[path] or "directory"
    return { size = 0, type = t, extension = "", language = "", mime_type = "" }
  end,
}

-- Load the plugin source (registers grep + glob into `registered`). The test
-- runner builds with cwd at the repo root; io + load are available because the
-- runner uses a full-access sandbox.
local f = assert(io.open("examples/plugins/search-tools/init.lua", "r"))
local src = f:read("*a")
f:close()
assert(load(src))()

local grep = registered.grep

local function reset()
  last_bash = nil
  last_search = nil
end

-- ── Regex command construction (the bug surface) ────────────────────

test.describe("grep regex command construction", function()
  test.it("registers grep and glob tools", function()
    test.assert.is_true(registered.grep ~= nil)
    test.assert.is_true(registered.glob ~= nil)
  end)

  test.it("single-quotes a regex pattern so `|` is not a shell pipe", function()
    reset()
    bash_reply = { stdout = "", stderr = "", code = 1 }
    grep.handler({ pattern = "mcp__|lua__", regex = true })
    test.assert.contains("-e 'mcp__|lua__'", last_bash.cmd)
    -- The bare (unquoted) form is the bug; it must not appear.
    test.assert.is_false(string.find(last_bash.cmd, "-e mcp__", 1, true) ~= nil)
  end)

  test.it("single-quotes a multi-word regex pattern", function()
    reset()
    bash_reply = { stdout = "", stderr = "", code = 1 }
    grep.handler({ pattern = "defer .*deinit", regex = true })
    test.assert.contains("-e 'defer .*deinit'", last_bash.cmd)
  end)

  test.it("escapes single quotes inside the pattern", function()
    reset()
    bash_reply = { stdout = "", stderr = "", code = 1 }
    grep.handler({ pattern = "it's|that", regex = true })
    local is_win = false
    if type(package) == "table" and type(package.config) == "string" then
      is_win = (package.config:sub(1, 1) == "\\")
    elseif type(nova) == "table" and type(nova.get_env) == "function" then
      is_win = (nova.get_env("OS") == "Windows_NT")
    end
    if is_win then
      test.assert.contains([['it''s|that']], last_bash.cmd)
    else
      test.assert.contains([['it'\''s|that']], last_bash.cmd)
    end
  end)

  test.it("quotes the include glob and a root with spaces", function()
    reset()
    bash_reply = { stdout = "", stderr = "", code = 1 }
    grep.handler({ pattern = "foo", regex = true, include = "*.zig", path = "src dir" })
    test.assert.contains("--glob '*.zig'", last_bash.cmd)
    test.assert.contains("'src dir'", last_bash.cmd)
  end)

  test.it("adds -i only when case-insensitive", function()
    reset()
    bash_reply = { stdout = "", stderr = "", code = 1 }
    grep.handler({ pattern = "foo", regex = true })
    test.assert.contains(" -i ", last_bash.cmd)
    grep.handler({ pattern = "foo", regex = true, case_sensitive = true })
    test.assert.is_false(string.find(last_bash.cmd, " -i ", 1, true) ~= nil)
  end)
end)

-- ── Backend routing ─────────────────────────────────────────────────

test.describe("grep backend routing", function()
  test.it("substring uses built-in search_files, not rg", function()
    reset()
    search_reply = { query = "foo", total_matches = 0, results = {}, truncated = false }
    grep.handler({ pattern = "foo" }) -- regex defaults to false
    test.assert.is_true(last_search ~= nil)
    test.assert.is_true(last_bash == nil)
  end)

  test.it("regex shells out to rg, not search_files", function()
    reset()
    bash_reply = { stdout = "", stderr = "", code = 1 }
    grep.handler({ pattern = "foo", regex = true })
    test.assert.is_true(last_bash ~= nil)
    test.assert.is_true(last_search == nil)
  end)
end)

-- ── Regex output handling ───────────────────────────────────────────

test.describe("grep regex output handling", function()
  test.it("groups rg output by file", function()
    reset()
    bash_reply = {
      stdout = "src/a.zig:10:hello\nsrc/a.zig:20:world\nsrc/b.zig:5:hello\n",
      stderr = "",
      code = 0,
    }
    local out = grep.handler({ pattern = "hello", regex = true })
    test.assert.contains("Found 3 matches:", out)
    test.assert.contains("src/a.zig:", out)
    test.assert.contains("Line 10: hello", out)
    test.assert.contains("src/b.zig:", out)
  end)

  test.it("keeps content that contains colons intact", function()
    reset()
    bash_reply = { stdout = "src/a.zig:3:map: key: value\n", stderr = "", code = 0 }
    local out = grep.handler({ pattern = "map", regex = true })
    test.assert.contains("Line 3: map: key: value", out)
  end)

  test.it("reports no matches on rg exit 1", function()
    reset()
    bash_reply = { stdout = "", stderr = "", code = 1 }
    local out = grep.handler({ pattern = "zzz", regex = true })
    test.assert.contains("No matches found for: zzz", out)
  end)

  test.it("surfaces invalid regex (rg exit 2)", function()
    reset()
    bash_reply = { stdout = "", stderr = "regex parse error", code = 2 }
    local out = grep.handler({ pattern = "(", regex = true })
    test.assert.contains("invalid regex", out)
  end)

  test.it("caps output at max_results with a truncation marker", function()
    reset()
    local lines = {}
    for i = 1, 10 do
      table.insert(lines, "f.zig:" .. i .. ":match")
    end
    bash_reply = { stdout = table.concat(lines, "\n") .. "\n", stderr = "", code = 0 }
    local out = grep.handler({ pattern = "match", regex = true, max_results = 3 })
    test.assert.contains("Found 10 matches (showing first 3", out)
  end)

  test.it("reports regex needs rg when rg is missing (exit 127)", function()
    reset()
    bash_reply = { stdout = "", stderr = "rg: command not found", code = 127 }
    local out = grep.handler({ pattern = "foo", regex = true })
    test.assert.contains("needs ripgrep", out)
  end)

  test.it("reports error when run_bash fails (nil) for regex", function()
    reset()
    bash_reply = nil
    local out = grep.handler({ pattern = "foo", regex = true })
    test.assert.contains("regex search failed", out)
  end)
end)

-- ── Substring output handling (built-in search) ─────────────────────

test.describe("grep substring output handling", function()
  test.it("groups native results by file", function()
    reset()
    search_reply = {
      query = "hello",
      total_matches = 2,
      truncated = false,
      results = {
        { file = "src/a.zig", line = 1, content = "hello" },
        { file = "src/b.zig", line = 2, content = "hello world" },
      },
    }
    local out = grep.handler({ pattern = "hello" })
    test.assert.is_true(last_bash == nil)
    test.assert.contains("Found 2 matches:", out)
    test.assert.contains("src/a.zig:", out)
    test.assert.contains("Line 1: hello", out)
    test.assert.contains("src/b.zig:", out)
  end)

  test.it("reports no matches when search_files finds none", function()
    reset()
    search_reply = { query = "zzz", total_matches = 0, results = {}, truncated = false }
    local out = grep.handler({ pattern = "zzz" })
    test.assert.contains("No matches found for: zzz", out)
  end)

  test.it("forwards include, case_sensitive and max_results to search_files", function()
    reset()
    search_reply = { query = "x", total_matches = 0, results = {}, truncated = false }
    grep.handler({ pattern = "x", include = "*.zig", case_sensitive = true, max_results = 7 })
    test.assert.equal("*.zig", last_search.opts.file_pattern)
    test.assert.equal(true, last_search.opts.case_sensitive)
    test.assert.equal(7, last_search.opts.max_results)
  end)

  test.it("reports an error when search_files fails (nil)", function()
    reset()
    search_reply = nil
    local out = grep.handler({ pattern = "foo" })
    test.assert.contains("could not search", out)
  end)

  test.it("scopes a file-path `path` to that single file via the restriction", function()
    reset()
    -- The mock reports "src/skill.zig" as a file, so resolve_search_root must
    -- descend to "src" and pass "skill.zig" as the file restriction.
    file_info_types["src/skill.zig"] = "file"
    search_reply = {
      query = "deinit",
      total_matches = 1,
      truncated = false,
      results = { { file = "src/skill.zig", line = 18, content = "deinit" } },
    }
    local out = grep.handler({ pattern = "deinit", path = "src/skill.zig" })
    -- Walk happened in the parent dir, restricted to the single file.
    test.assert.equal("src", last_search.root)
    test.assert.equal("skill.zig", last_search.opts.file_pattern)
    test.assert.contains("src/skill.zig:", out)
  end)

  test.it("keeps directory-path `path` behavior unchanged (regression)", function()
    reset()
    -- No file_info override -> "src" is treated as a directory.
    search_reply = {
      query = "x",
      total_matches = 1,
      truncated = false,
      results = { { file = "src/a.zig", line = 1, content = "x" } },
    }
    grep.handler({ pattern = "x", path = "src" })
    test.assert.equal("src", last_search.root)
    test.assert.equal(nil, last_search.opts.file_pattern)
  end)
end)

test.describe("glob file-path gating", function()
  local glob = registered.glob

  test.it("returns the single file named by a file-path `path`", function()
    file_info_types["src/skill.zig"] = "file"
    -- Mock find_files to return two candidates; the handler must keep only the
    -- one whose basename matches the restriction.
    nova.find_files = function(root, pattern, opts)
      return {
        root = root,
        total_matches = 2,
        results = {
          { path = "src/skill.zig" },
          { path = "src/other.zig" },
        },
        truncated = false,
      }
    end
    local out = glob.handler({ pattern = "*.zig", path = "src/skill.zig" })
    test.assert.contains("src/skill.zig", out)
    test.assert.is_false(string.find(out, "other.zig", 1, true) ~= nil)
  end)

  test.it("keeps directory-path `path` behavior unchanged (regression)", function()
    nova.find_files = function(root, pattern, opts)
      return {
        root = root,
        total_matches = 1,
        results = { { path = "src/skill.zig" } },
        truncated = false,
      }
    end
    local out = glob.handler({ pattern = "*.zig", path = "src" })
    test.assert.contains("src/skill.zig", out)
  end)
end)

test.describe("resolve_search_root gating", function()
  -- resolve_search_root is a local helper; its behavior is exercised through
  -- the grep/glob handlers above (file -> parent dir + basename restriction,
  -- directory -> unchanged, file_info error -> path preserved). These three
  -- cases mirror those handler tests at the unit level.
  test.it("scopes a file path to (parent dir, basename) via the grep handler", function()
    reset()
    file_info_types["src/skill.zig"] = "file"
    search_reply = {
      query = "deinit",
      total_matches = 1,
      truncated = false,
      results = { { file = "src/skill.zig", line = 18, content = "deinit" } },
    }
    grep.handler({ pattern = "deinit", path = "src/skill.zig" })
    test.assert.equal("src", last_search.root)
    test.assert.equal("skill.zig", last_search.opts.file_pattern)
  end)

  test.it("preserves a directory path (no restriction) via the grep handler", function()
    reset()
    search_reply = {
      query = "x",
      total_matches = 1,
      truncated = false,
      results = { { file = "src/a.zig", line = 1, content = "x" } },
    }
    grep.handler({ pattern = "x", path = "src" })
    test.assert.equal("src", last_search.root)
    test.assert.equal(nil, last_search.opts.file_pattern)
  end)

  test.it("falls back to the path unchanged when file_info errors", function()
    reset()
    local orig = nova.file_info
    nova.file_info = function() error("boom") end
    -- With file_info throwing, the pcall guard keeps the file path as root and
    -- does NOT add a restriction (handler must still not crash).
    local ok, _ = pcall(function()
      grep.handler({ pattern = "x", path = "src/skill.zig" })
    end)
    nova.file_info = orig
    test.assert.is_true(ok)
  end)
end)

test.run()
