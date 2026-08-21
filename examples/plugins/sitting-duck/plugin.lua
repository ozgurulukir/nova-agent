-- plugin.lua — sitting-duck manifest
--
-- Wraps the duckdb CLI + the sitting_duck community extension (tree-sitter
-- ASTs as SQL tables). First example plugin consuming plugin.get_config()
-- and nova.shell_quote.
return {
  name = "sitting-duck",
  version = "1.0.1",
  author = "Nova",
  description = "Query tree-sitter ASTs with SQL via the duckdb CLI and the sitting_duck extension",
  license = "MIT",
  permissions = {
    -- No nova.require of other plugins.
    require_others = false,
    -- Wall-clock per-dispatch deadline, checked by the instruction hook when
    -- Lua resumes after run_bash returns: one dispatch can chain
    -- --version (10s) + bootstrap INSTALL (300s cap) + query (60s cap)
    -- ≈ 370s worst case; 600s leaves shaping margin.
    timeout_ms = 600000,
    -- C-side bridges (json_decode/run_bash/shell_quote) burn no VM
    -- instructions; 1M covers shaping loops over a 512KB stdout.
    instruction_limit = 1000000,
    -- 512KB stdout cap bounds json_decode input; Lua table materialization
    -- ≈ 5-15x → ~8MB worst case; 64MB is ~8x headroom.
    memory_limit_mb = 64,
  },
}
