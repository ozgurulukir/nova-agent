---
description: tree-sitter ASTs as SQL — outline files, structural search, and node_id source drill-down over the duckdb CLI.
---

Use the sitting-duck plugin when a question about code is **structural**, not
textual: "which functions exist in this file and where", "find all methods
shaped like X", "count definitions per file". A grep finds text; these tools
ask a real parser (tree-sitter, via the `sitting_duck` DuckDB extension) and
return one row per AST node.

## Prerequisites & configuration

- The `duckdb` CLI must be installed. Resolution order: `plugins.sitting-duck.settings.duckdb_path`
  in config.json → `NOVA_SITTING_DUCK_BIN` env var → `duckdb` on PATH.
- The `sitting_duck` extension auto-installs on the first tool call
  (`INSTALL sitting_duck FROM community`) — this is one-time, needs network,
  and may take minutes; subsequent calls are fast.
- Linux-first: the tools run duckdb through bash with `<` input redirection.
  On Windows install Git Bash or use WSL.

## Workflow

1. Start with `ast_outline` (glob in, symbol list out — kind, name, line
   range, and a `node_id` handle per symbol, grouped by file).
2. Drill into one symbol with `ast_get_source` — pass the file plus the
   `node_id`; you get the exact numbered lines (plus optional context).
3. Use `ast_find_pattern` for shape queries a name search can't express —
   a minimal code skeleton in the target language with `__NAME__` capture
   wildcards: zig `fn __FN__(__) void {}`, python `def __F__(__):`.
   Literals in the skeleton must match exactly; `__` is an anonymous
   wildcard; the skeleton must parse in that language (zig needs the
   return type). `language` is inferred from the glob's extension or
   passed explicitly.
4. Reserve `ast_query` for aggregates and joins (counts per file, GROUP BY,
   ast_match joins). It accepts ONE read-only statement that must start with
   SELECT or WITH — chained statements after a `;` and dot-command lines
   (`.shell`, `.output`, …) are rejected.

`node_id`s are stable only while the file is unchanged — after edits,
re-run `ast_outline` before another `ast_get_source`.

## Output contract

- Every tool bounds its output: `limit` defaults to 50 and clamps to 1-200;
  `ast_query` expects its own LIMIT in the SQL. Output above 512KB fails
  outright (StreamTooLong) — narrow the query and retry rather than re-reading
  a giant result.
- `ast_query` accepts one READ-ONLY statement per call — it must start with
  SELECT or WITH; write statements (COPY TO, INSTALL, ATTACH, EXPORT) and
  chained or dot-command statements are rejected. File paths and globs passed
  as TOOL PARAMETERS must be relative to the project (no absolute paths, no
  `..`, no URLs).
- Residual read surface, known and accepted: paths written inside `ast_query`'s
  SQL literals (e.g. `read_csv('/etc/passwd')`) are bounded only by DuckDB
  itself — pass explicit paths via the dedicated tools' parameters instead.
  A symlinked directory inside the project can likewise point glob reads
  outside it.
- Empty results are normal ("No AST symbols found…"), not errors — try a
  broader `kinds` filter or a wider glob.
- On a query error the exact SQL sent stays at `.nova/sitting-duck/query.sql`
  for inspection; the error message says so.
