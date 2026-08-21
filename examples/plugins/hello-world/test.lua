-- test.lua — Hello World plugin tests
--
-- Loads the real plugin source with a mocked `nova` bridge and exercises the
-- actual handlers (greet, current_time) rather than stdlib tautologies. The
-- `nova` bridge is mocked so the handlers run without a live Nova runtime.
local test = test_runner

-- ── Bridge surface (must stay ABOVE the nova mock) ──────────────────
-- These assertions run against the REAL bridge tables the Zig test runner
-- registers: `plugin` unconditionally, `nova` because the runner provides an
-- Io. The `nova = { ... }` mock below replaces the real bridge for the
-- handler tests, so anything asserting on real bridge state belongs here —
-- capture values before the mock, assert inside the it blocks.
local bridge_shell_quote = nova and nova.shell_quote

test.describe("bridge surface", function()
  test.it("exposes the plugin table with get_config", function()
    test.assert.is_true(type(plugin) == "table")
    test.assert.is_true(type(plugin.get_config) == "function")
  end)

  test.it("plugin.get_config returns nil without settings", function()
    test.assert.is_true(plugin.get_config() == nil)
  end)

  test.it("nova.shell_quote quotes for posix by default", function()
    test.assert.is_true(bridge_shell_quote ~= nil)
    test.assert.equal("'a'\\''b'", bridge_shell_quote("a'b"))
    test.assert.equal("''", bridge_shell_quote(""))
  end)

  test.it("nova.shell_quote rejects an unknown dialect", function()
    local v, err = bridge_shell_quote("x", "bogus")
    test.assert.is_true(v == nil)
    test.assert.is_true(string.find(err, "dialect", 1, true) ~= nil)
  end)
end)

-- ── Mock the nova bridge, then load the plugin ──────────────────────
local registered = {}
nova = {
  register_tool = function(tool)
    registered[tool.name] = tool
  end,
}

local f = assert(io.open("examples/plugins/hello-world/init.lua", "r"))
local src = f:read("*a")
f:close()
assert(load(src, "@hello-world/init.lua"))()

test.describe("hello-world plugin", function()
  test.it("registers greet and current_time tools", function()
    test.assert.is_true(registered.greet ~= nil)
    test.assert.is_true(registered.current_time ~= nil)
  end)

  test.it("greets by name", function()
    test.assert.equal("Hello, Alice!", registered.greet.handler({ name = "Alice" }))
  end)

  test.it("greets World when name is missing", function()
    test.assert.equal("Hello, World!", registered.greet.handler({}))
  end)

  test.it("current_time matches HH:MM:SS", function()
    local out = registered.current_time.handler({})
    test.assert.matches("%d%d:%d%d:%d%d", out)
  end)
end)

test.run()
