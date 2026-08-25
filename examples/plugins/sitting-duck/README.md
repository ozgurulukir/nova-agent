# sitting-duck

Query tree-sitter ASTs with SQL, straight from Nova. The plugin wraps the
`duckdb` CLI and its `sitting_duck` community extension, which exposes parsed
syntax trees as SQL tables — so structural questions ("where are all the
`defer` calls?", "which functions exceed 200 lines?") become plain `SELECT`s.

## Tools

| Tool | What it does |
|------|--------------|
| `ast_outline` | glob → symbol list with `node_id` handles |
| `ast_find_pattern` | structural search: code-skeleton patterns with `__NAME__` wildcards (zig: `fn __FN__(__) void {}`, python: `def __F__(__):`, ruby: `def __FN__(__)`) |
| `ast_get_source` | `node_id` → numbered source snippet |
| `ast_query` | read-only SQL over `read_ast()` (single `SELECT`/`WITH`) |

They are exposed to the model as `lua__sitting-duck__<tool>`.

## Requirements

- **Nova 0.5.0+** — uses the `plugin.get_config()` / `nova.shell_quote()`
  bridge surface.
- **duckdb CLI** — the plugin never installs this itself; pick one:

  ```bash
  curl https://install.duckdb.org | sh   # official script (Linux/macOS)
  brew install duckdb                    # Homebrew
  ```

  or download the single binary from <https://duckdb.org/install/>. The
  plugin finds it via `plugins.sitting-duck.settings.duckdb_path` →
  `NOVA_SITTING_DUCK_BIN` env var → `duckdb` on `PATH`, in that order.
- **Internet on first use** — the `sitting_duck` community extension is
  `INSTALL`ed automatically by the plugin on the first tool call, through
  duckdb's own community-extension mechanism — no manual step (and no reason
  to pre-install: `INSTALL` is idempotent, so doing it yourself only skips
  the one-time download). Success is cached in
  `.nova/sitting-duck/state.json` and re-verified once per session, so a
  duckdb upgrade triggers a re-install (the extension is built per DuckDB
  release).
- **Linux-first.** Windows runs the plugin through git-bash and is untested.

## Install

1. Copy the plugin into Nova's plugin directory (from your Nova checkout):

   ```bash
   cp -r examples/plugins/sitting-duck ~/.config/nova/plugins/
   ```

   Project-local alternative: `.nova/plugins/sitting-duck/` inside a repo
   (overrides a global plugin with the same name). On Windows the global
   directory is `%APPDATA%\nova\plugins\`.

2. Make sure duckdb is reachable. If it is not on `PATH`, point Nova at it —
   either in `~/.config/nova/config.json`:

   ```json
   {
     "plugins": {
       "sitting-duck": {
         "settings": { "duckdb_path": "/usr/local/bin/duckdb" }
       }
     }
   }
   ```

   (an escaped-JSON-string `settings` form also works — see
   `docs/CONFIG.md`), or via the environment:

   ```bash
   export NOVA_SITTING_DUCK_BIN=/usr/local/bin/duckdb
   ```

3. Restart Nova — plugins and their settings are read once at startup.

## Verify

Run `/plugins` in Nova and check that `sitting-duck` is enabled, then ask the
model something like *"outline the symbols in `src/**/*.zig` with
ast_outline"*. The first call bootstraps the extension; later calls are fast.

## Notes

- All plugin state lives under `.nova/sitting-duck/` in the project: the
  bootstrap marker (`state.json`) and the `query.sql` debug artifact (every
  query error message points at it). Deleting the directory is safe — the
  plugin re-bootstraps on the next call.
- `ast_query` accepts a single read-only statement; chained statements and
  dot-commands are rejected.
- Paths are confined to the project (relative paths only, no `..`, no `~`,
  no absolute paths); see `prompt.md` for the full tool contracts.
