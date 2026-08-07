# Nova Guidelines

This project uses Zig 0.16. Consult the tigerstyle skill before writing code.

## Setup

- Vendor `fff` (build into `vendor/fff/libfff_c.so`) and the ModernBERT ONNX model (`vendor/local-models/ModernBERT-bash-classifier`) after cloning. Both are gitignored.
- Set `OMP_WAIT_POLICY=passive` at runtime to avoid MKL/CPU spin in the embedding worker.
- `zig build install -Doptimize=ReleaseFast --prefix $HOME/.local` installs to `~/.local/bin/`.

## Patterns & Engineering Notes

The codebase patterns (TUI architecture, MCP, Lua plugins, AI tool schema, type system, models.dev, config layering, reasoning, compaction, session resume, toast notifications) and the vxfw build gotchas live in `docs/PATTERNS.md`. Read the relevant section when working on a subsystem — they are intentionally not ingested into the system prompt.

- **Parallel lanes orientation.** Design spec: `_plan/plan-model-driven-lanes-2026-08-03.md` (labels S/F/M/H/L; review-pass limitations live there too). Key files: `src/tools/lane.zig` (tool side, workspace borrow), `src/tools/lane_bridge.zig` (request/response bridge), `src/tui/lane_lifecycle.zig` (all lane ops + tests), `src/tui/lifecycle.zig` (`handleTick` order: `drainAgentEvents` → `serviceLaneBridge` → `drainLaneNaming` → `deliverPendingLaneCompletions`; `createParallelLane` user flow). Limits: max 4 threads (driver + 3 lanes); worktrees at `~/.config/nova/worktrees/<id>`, branch `nova/<id>`; `worker_stall_ms = 180s`. The `defer root.app.thread = active` inside `drainAgentEvents`'s loop is per-iteration and correct — it looks wrong but isn't.

## Zig Development

Use `zigdoc` to discover APIs before coding.

```bash
zigdoc std.fs
zigdoc std.posix.getuid
zigdoc vaxis.Window
```

## Current Zig Patterns

**ArrayList:**

```zig
var list: std.ArrayList(u32) = .empty;
defer list.deinit(allocator);
try list.append(allocator, 42);
```

**HashMap/StringHashMap:**

```zig
var map: std.StringHashMapUnmanaged(u32) = .empty;
defer map.deinit(allocator);
try map.put(allocator, "key", 42);
```

**stdout/stderr writer:**

```zig
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
defer writer.interface.flush() catch {};
try writer.interface.print("hello {s}\n", .{"world"});
```

**build.zig executable:**

```zig
b.addExecutable(.{
    .name = "foo",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

**JSON writing:**

```zig
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
defer writer.interface.flush() catch {};

var jw: std.json.Stringify = .{
    .writer = &writer.interface,
    .options = .{ .whitespace = .indent_2 },
};
try jw.write(my_struct);
```

**Allocating writer:**

```zig
var writer: std.Io.Writer.Allocating = .init(allocator);
defer writer.deinit();
try writer.writer.print("hello {s}", .{"world"});
const output = try writer.toOwnedSlice();
```

## Zig Style

- `camelCase` for functions and methods
- lower-case `snake_case` for variables, parameters, and constants
- `PascalCase` for types, structs, and enums
- prefer `const foo: Type = .{ .field = value };` over `const foo = Type{ .field = value };`
- preferred file order: `//!` module doc comment, `const Self = @This();`, imports, `const log = std.log.scoped(...)`
- pass allocators explicitly; use `errdefer` for cleanup on error
- keep tests inline with the code they cover; a new file's tests only run once the file is reachable from the `src/root.zig` test root (its `refAllDecls`) — see **Test runner quirks**

## Safety

- Add assertions at API boundaries and state transitions; avoid trivial assertions.
- Keep functions small; push pure computation into helpers.
- Comments should explain why, not what.
- **POSIX Environment Access:** Never index `std.c.environ` directly in loops. In Zig 0.16 on POSIX, `std.c.environ` is `[*:null]?[*:0]u8`. Use `const env_slice = std.mem.span(std.c.environ);` and pass to `std.process.Environ.createMap(.{ .block = .{ .slice = env_slice } }, gpa)` to prevent null-pointer segfaults in multi-threaded contexts.
- **Models.dev Registry Allocations:** `modelsdev.Registry` string storage uses an `ArrayList(u8)`. To prevent dangling slice pointers when building or merging providers, accumulate string offsets via `StringRef` (`start`, `len`) and resolve slice pointers only after all string appends complete.
- **Dynamic Context Compaction:** Never hardcode fixed context retention budgets (e.g. 20,000 tokens) when compacting history. Use `compaction.keepRecentTokens(context_window)` so small-context models (8K/16K/32K) keep a scaled history window (35% of window, capped at the config `keepRecentTokens` default 8,000) and can always compact below their swap watermark. When a real usage anchor is available, `compaction.calibrateKeepBudget(base, real, estimated)` shrinks the budget by the measured ratio so chars/4 undercounts (CJK ≈ 1.5 chars/token) still land the cut below swap; it never grows the budget.
- **Streaming SSE Tool Call Deduplication & Parallel Remap:** In `src/ai/openai_compatible.zig`, tool call names and IDs are atomic in streaming — first complete value wins; subsequent deltas are ignored. This deduplicates repeated names (the `bashbash` fix) and prevents cross-tool concatenation. Some providers reuse `index: 0` for all parallel tool calls; `ToolCallStream` detects this by comparing tool-call IDs (always unique). When a new ID arrives at an occupied logical index, the call is forked into a new physical builder slot. Argument continuation deltas (no ID) route through the remap to the correct slot. Limitation: if the provider omits IDs entirely, collision detection is impossible and the second call is lost (first writer wins for the name). The over-cap reject (`index >= max_parallel_tool_calls`) logs the offending model id alongside the index/cap (L3) — `readStream` takes a borrowed `model` param used only for that log; the Responses-API client (`responses_core.zig`) has its own local `readStream` with no `max_calls` path, so L3 is inapplicable there.
- **Prompt-cache field suppression (C1/C2).** Some OpenRouter `:free` / gateway-fronted models (kimi, inclusionai/ling) reject `cache_control` and/or `prompt_cache_key` with HTTP 400, killing the whole turn. Two defenses: (a) a user-facing `context.disablePromptCache` flag (`disablePromptCache`/`disable_prompt_cache` in config; `ai.Config.disable_prompt_cache` on the wire) suppresses BOTH fields in BOTH wire clients (chat-completions `writeMessage`/`writeRequestPayload` AND Responses-API `responses_core.writeRequestPayload`), regardless of dialect — the Responses-API site is NOT dialect-gated today, so the flag is its sole gate; (b) a one-shot C2 downgrade in `Client.prompt` — on a 400 whose error body mentions "cache" (case-insensitive, `errorDetailMentionsCache`), rebuild the payload with cache fields stripped and retry the FULL 429/5xx budget once (`downgrade_done` gates it to a single rebuild; the outer `while (true)` loop runs at most twice). The downgrade is decoupled from the `attempt` counter because Zig's `while … : (step) { continue }` runs the step expr on `continue` — riding the counter would burn a user-facing retry slot. `disable_cache` is a `prompt`-local var seeded from `self.config.disable_prompt_cache` so C2 never fights the user's explicit flag.
- **Bash tool safety:** `validateCwd` (`src/tools/bash.zig`) keeps the cwd inside the project root, comparing against a **normalized** root (trailing slash can't defeat it) plus a best-effort realpath re-check so a symlink escaping the root is caught (realpath failure → lexical verdict). The destructive-command gate is **always armed**: `bash_safety.classify` takes an optional URL and runs the local matcher when none is configured. Temp files use hex-only names; stale `nova-bash-*` / `nova-bg_*` files older than 24h are pruned at startup; spills cap at 10MB.
- **Lua C-stack manipulation:** When building a Lua table of results from Zig (e.g. `walkAndSearch` in `plugin_api.zig`), the results table must stay on top of the stack across every entry. The correct idiom is `newTable()` (push table) → push entry fields + `lua_setfield(L, -2, ...)` → `lua_rawseti(L, -2, n)` (pops the entry, leaving the table on top). A stray extra push before `lua_rawseti` with the wrong table index (`-3` instead of `-2`) writes the bare integer into `results[n]` instead of the entry table and **leaks one table per match** onto the stack. Annotate the expected stack layout (`[ ... | results_table ]`, `[ ... | results_table | entry ]`) at each push/pop site so the balance is auditable.
- **Glob/pattern slicing:** Never unconditionally slice byte 0 off a user-supplied pattern (`fp[1..]`). When the pattern is empty, `fp[1..0]` is an out-of-bounds slice → Zig panic → `SIGABRT`. Lua treats `""` as truthy, so a plugin forwarding `file_pattern = ""` (e.g. `project-info`'s `list_project_files({ pattern = "" })`) reaches this path directly. Extract suffix logic into a pure `fileNameMatches(name, pattern)` helper that handles empty (match-all), `"*x"` (strip leading star), and bare-suffix cases, and unit-test the empty case explicitly.
- **Skill buffers freed on every path.** `loadOne` and `appendSkillBlock` (`src/skill.zig`) both use a plain `defer gpa.free(raw)` registered immediately after the alloc — never `errdefer` (which leaks on the success path). The buffer is read from disk (up to 256KB per skill) and only the frontmatter values are duped into the returned `Skill`/written into the prompt; without the defer, loading N skills leaks N×256KB per runtime creation and each `$skill` invocation leaks per turn. Registered *before* the `try readSliceAll`, the defer also covers a failed read.
- **Skill invocation dedup must match `find`'s case sensitivity.** `find` is case-insensitive (`eqlIgnoreCase`), so `collectInvocations`'s `contains` helper must also be case-insensitive. If `contains` uses exact `mem.eql`, a prompt like `$Tiger and $tiger` passes both tokens through (they look distinct to `contains`), and `promptPrefix` injects the same skill body twice — wasting tokens and confusing the model. Keep `contains` and `find` in lockstep.
- **Skill name validation rejects XML-special chars.** `isValidSkillName` rejects `"`, `'`, `&`, `<`, `>` in addition to whitespace and `$`. This is not just cosmetic: `appendSkillBlock` escapes these via `writeXmlEscaped`, but `collectInjectedSkillNames` (resume path) parses `<skill name="…">` without unescaping. If a name contained `"`, the escaped `&quot;` would be returned verbatim on resume, showing the wrong skill name in the `[SKILL]` transcript row. Rejecting XML-special chars at load makes the "no unescaping needed" invariant (TD-14) hold.
- **`McpClient.stop()` must free a `.failed` reason.** `stop` clobbers `lifecycle` to `.disabled`; if the client carries an owned failure reason (set via `setError` — e.g. the async connect worker's `runConnect` catch sets one on its clone before tearing it down), free `lifecycle.failed.reason` **before** overwriting the lifecycle, or the reason leaks silently (`deinit` calls `stop` before its `failed`-arm switch, so the switch can never see it). Caught by the async-connect tests.
- **Historical tool-result pruning must never prune everything when no turn exceeds budget.** `computeCutoff` (assembly.zig) counts a contiguous `.tool` run as **one turn** (increments only at run end), so a parallel batch of 8 tools counts as 1 turn. When `cutoff_index == messages.len` (no turn exceeds the keep budget), the old code pruned the entire history; guard with `pruning_active = cutoff_index < messages.len` in `pruneHistoricalToolResultsViews`. Keep `estimatePrunedTokensRange` in lockstep by reusing `computeCutoff` over the full slice.
- **Persist before caching — the tree is the source of truth.** `appendPersisted` (manager.zig) writes to the DB first, then updates the cache. Cache-behind is healable on restart; cache-ahead is not. The session serializer maps OOM to `error.WriteFailed` (not `error.OutOfMemory`), so tests must expect that.
- **`readSliceShort` vs `readSliceAll`.** `readSliceShort` returns the actual byte count and never `error.EndOfStream`; `readSliceAll` returns `error.EndOfStream` when the buffer can't fill. Use `readSliceShort` when truncating oversized inputs (e.g. project rule files capped at 64KB) and shrink the slice on a short read. Also: a `return null` inside a `catch` block does **not** fire an `errdefer` — free the buffer explicitly before returning.
- **Mention/image ingestion caps.** `at_mention.zig` caps a single file mention at 64KB (`per_file_mention_max_bytes`), an aggregate of 256KB per turn (`turn_mention_aggregate_max_bytes`), and 4 images per message (`max_images_per_message`). Oversized files are head-truncated with a visible `[file truncated: {n} bytes, first {cap} inlined]` notice; over-cap images are skipped, not truncated.
- **Epoch date math for `todayUtc`.** `std.Io.Timestamp.now(io, .real)` → `EpochSeconds.getEpochDay()` → `EpochDay.calculateYearDay()` → `YearAndDay.calculateMonthDay()` → `MonthAndDay`. `month.numeric()` is 1-based; `day_index` is 0-based (add 1).
- **Lua sandbox instruction budget is per-dispatch, not per-session.** `resetInstructionBudget(L)` (`src/lua/sandbox.zig`) zeroes the instruction count and re-arms the timeout deadline before each tool call / event dispatch (`callToolHandler` in `plugin_api.zig`, `drainEventCallbacks` in `manager.zig`). Without it the count is a session accumulator and a busy plugin eventually fails every call with "instruction limit exceeded" for the rest of the session. The hook reads its state via `lua_getextraspace` hook data; the timeout check runs every 1000 instructions (coarse granularity, by design).
- **Bridge integer-clamp idiom.** When a Lua-supplied integer flows into a `u32` field, clamp on the `i64` *before* the `@intCast` so a negative value (a model-supplied `-1` or a manifest typo) can't wrap to ~4e9: `@intCast(@max(v, 1))` for positive-only params, `@intCast(@max(v, 0))` for "0 = unlimited" params. For capped params, wrap the clamp in `@min(..., cap)`. See `searchFiles`/`findFiles`/`runBash` (`plugin_api.zig`) and `parsePermissions` (`manifest.zig`).
- **`sanitizePath` realpath re-check mirrors `validateCwd`.** `sanitizePath` (`plugin_api.zig`) does a lexical `startsWith(cwd)` check, then a best-effort `std.c.realpath` re-check so a symlink escaping the project root is caught. `realpath` returns null on ENOENT (a new file being written), so fall back to the lexical verdict on null — never reject a legitimately-new path. This mirrors the bash tool's `validateCwd` (AGENTS.md §Safety).
- **Lane re-rooting takes effect from the next tool call, not the next batch.** `ExecutorService.cwd` starts as a per-batch snapshot from `agent.effectiveCwd()` (`runToolBatch`, agent.zig), but `runAll` calls `rerootFromRequester()` after every `lane` call (executor.zig) — so a `lane enter`/`leave` mid-batch re-roots the *remaining* calls in the same batch, matching what the `enter` response already claims ("working root is now X"). `rerootFromRequester` re-reads `effectiveCwd()` off the `lane_requester` (`*Agent`); it is a no-op when no requester is attached (headless/tests) or the workspace didn't change. Contained workers never change workspace (`enter` is driver-only), so the refresh is inert there. The `executor → agent` import is safe — the cycle already exists via `executor → tools → lane → agent`.
- **`Agent.workspace` is cross-thread, mutex-guarded (fixed 2026-08-05).** Worker threads write it (`lane enter`/`leave` via `setWorkspace` in tools/lane.zig); the UI thread reads it (`driverWorkspace`, `listLanes`, `clearWorkspaceBorrowForPath`, `lane_column`). A 16-byte slice store can tear, so the field is guarded by `workspace_mutex` and accessed only through `setWorkspace`/`workspaceBorrow`/`effectiveCwd` — never directly. The lock is never held across tool dispatch. The precondition (no by-value copies of a live `Agent` after init) was verified before adding the mutex; `AgentRuntime.agent` is the single owner, and `Agent` already held a `message_queue_mutex`.
- **Lane bridge `service` holds its mutex across the handler.** `spawnLane` runs `git worktree add` + `createRuntime` on the UI thread under the bridge lock (visible UI freeze per spawn). Two-phase service (snapshot under lock, process unlocked) is unsafe: `Request` lives on the worker's stack and the worker may cancel after `service` returns — the handler must not outlive the lock.
- **Lane engine states: idle vs live.** `Thread.Engine` is `union(enum) { idle: vcs.Lane, live: Live }` where `Live = { lane: vcs.Lane, runtime: *AgentRuntime, owns: bool }`. Idle lanes — created via `lane create` (`lane_lifecycle.zig:791`) or rested via `parkFinishedWorker` (`lane_lifecycle.zig:1200`, which nulls `worker_context`/`agent` and downgrades `engine` to `.idle`) — have `worker_context = null`, `agent = null`, `liveRuntime() == null`; they cannot run a turn until a runtime is attached. `cycleLane` (`lane_lifecycle.zig:342`) sets `app.thread` to any lane including idle ones — no guard. `createRuntime` (`session_switcher.zig:323`) uses `templateRuntime()` (the first live lane's runtime) as a template and wires the agent fully (background_manager, mcp_manager, tool_registry, plugin_manager, lane_bridge, request_limiter). Any code that dereferences `worker_context` or `agent` off `app.thread` must guard for the idle case.

## Verifying

Run:

- `zig fmt`
- `zig build test`
- `zig build test-plugin` — runs the example Lua plugins' `test.lua` suites (via `src/lua/test_runner.zig` + `src/lua/test_runner.lua`). Its exit code is the gate: it must be 0 (green). `test_runner.run()` is idempotent — it caches the first verdict (`_has_run`/`_last_result`) so the explicit `test.run()` call and the Zig auto-run both return the same pass/fail. `test_runner.zig` logs at `warn` (not `err`) so the intentional syntax-error test doesn't fail the build. Add a new plugin's `test.lua` to the `test-plugin` arg list in `build.zig`. The Zig runner auto-runs `return test_runner.run()` after loading each file and **fails on 0 tests** — a test file with no `it` blocks is a failure, so a file that forgets `describe` entirely is caught.

### Test runner quirks (read before debugging a failure)

The authoritative signal for a test run is `zig build test`'s **exit code**, not its printed output:

- **`--listen=-` false failures.** `zig build test` drives the build-server protocol and intermittently prints `failed command: /usr/lib/zig/... zig test ...` with a red Build Summary even when every test passes (pre-existing environmental flakiness, reproducible on a clean baseline). If `EXIT=0` the run passed — ignore that line. Filter it out: `zig build test 2>&1 | grep -v '^failed command'`.
- **Test output is on stderr.** Both the `zig build test` step and the standalone `test` binary write their results to STDERR, so `2>/dev/null` hides everything and `2>&1 >/dev/null` reveals it. The standalone binary is authoritative when you need a real count: `ls -t .zig-cache/o/*/test | head -1 | xargs -I{} sh -c '{} 2>&1 >/dev/null | tail -3'` (expect `All N tests passed.`).
- **Stale cache with `-Dtest-filter`.** The `addTest` cache key does not distinguish `-Dtest-filter` filters, and `ls -t .zig-cache/o/*/test` can surface an older binary. After changing filters or code, trust `zig build test`'s exit code or the freshly built standalone binary — never a cached artifact's count.
- **Silent test discovery.** The test root is `src/root.zig`, which ends with `std.testing.refAllDecls(@This())` — only `test` blocks in files reachable through its `pub const` imports are compiled. A new file that nothing imports compiles fine but its tests **silently never run** (the count doesn't move, no error). Wire the file into the module graph — add a `pub const` in `root.zig`, or import it from a module already in the graph (e.g. the executor importing `tools/schema.zig` pulls its tests in) — to make its tests appear.
- **A lazy `pub const tests = @import("tui/tests.zig")` on `tui.zig` is NOT enough.** `refAllDecls` only takes the address of the *referencing* module's own decls; nothing takes the address of `tui.tests`, so `tests.zig` is never analyzed and its test blocks silently vanish (reproduced: the standalone binary dropped 690 → 601 after the §3.1 move with zero errors). The TUI tests are wired with `_ = @import("tui/tests.zig")` **inside `root.zig`'s `test` block** — reference the moved file's address directly, don't re-export it lazily. Verify any moved test file by strings-scanning the fresh binary for its test names, not by the suite exit code (which stays 0 on a silent drop).
- **Test-fixture lifetime pitfalls** (crash modes surfaced by running the tests, both caught by `std.testing.allocator`):
  - A helper that dupes its inputs leaks the temp: `appendViolation` dupes `got`/`expected`, so a caller passing `valueShortRepr(...)` / `toOwnedSlice(...)` results must `defer gpa.free` those temps, or DebugAllocator reports a leak at teardown.
  - A `&.{…}` compound literal with runtime elements lives on the **current frame's stack**. If later teardown (e.g. `McpManager.deinit` → `McpTool.deinit`) dereferences the schema after the helper returned, the free hits garbage → "General protection exception" at `gpa.free`. Test fixtures that outlive the helper must `gpa.alloc` the backing array; empty `&.{}` literals are fine because they live in read-only memory.
  - **`FailingAllocator` with an explicit `fail_index` beats `checkAllAllocationFailures` for OOM tests.** `checkAllAllocationFailures` requires the test fn to take the allocator as its first arg and fails when the *input construction* also allocates with the failing allocator. When building inputs with the real allocator and failing only inside the code-under-test, use `FailingAllocator` and set `fail_index` directly, then assert the expected error path and that no partial copies leak.

## Gotchas

- **`std.atomic.Mutex` is a spinlock.** In Zig 0.16, `std.atomic.Mutex` busy-waits and pegs the CPU on multi-core (80% at idle). Always use `std.Io.Mutex` / `std.Io.Condition` (paired via `static_thread_pool` or similar). All existing sites have been migrated — do not reintroduce `std.atomic.Mutex`.

- **`std.Io.Mutex` is not recursive — a function-scoped `defer unlock` plus a later re-lock deadlocks.** `BackgroundManager.start` hit this; fixed by unlocking immediately after `next_id += 1` (background.zig:135) — it guards only the id/job list. Lock only around the minimal critical section; never pair a function-scoped deferred unlock with a second `lock`. Related: `MultiReader.fill(timeout)` is an **idle** timeout, never a total cap; `bash_exec` converts once to an absolute deadline (`Io.Timeout.toDeadline`).

- **`postAgentEvent` owns the event.** It frees the event's data internally on error. Callers must NOT free `message_text` or `event_ptr` in catch blocks or before `return error.TurnCancelled` — doing so causes a double-free (errdefer repeats the cleanup).

- **Zig 0.16 std API gaps.** Several APIs from earlier Zig versions do not exist in 0.16.0 — use the C shims or `std.Io` equivalents instead: no `std.fs.realpathAlloc` → `std.c.realpath` (returns null on ENOENT); no `std.posix.symlink` → `std.c.symlink`; no `std.fs.makeDirAbsolute` → `std.Io.Dir.cwd().createDirPath`; no `std.time.nanoTimestamp` → `std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts)` (the instruction hook has no `Io` handle, so it reads the OS clock directly; fall back to 0 = no timeout on failure).

- **codebase-memory-mcp project id is `home-aristo-Projects-nova-agent`** (path-derived). Plain `nova-agent` does not resolve.

- **Stale `zig build install` artifact can silently ship old code.** `zig build install` copies the cached executable to the prefix; a stale `.zig-cache` artifact is copied verbatim, so the installed binary may keep running pre-fix code even after the source is changed — `zig build install` exits 0 and the file timestamp does not move. This bit us when a compaction fix built fine in Debug but the ReleaseFast install kept failing with the same `400 invalid message format`. If a fix appears to have no effect on the installed binary, verify the binary actually contains it (`nm ~/.local/bin/nova | grep <symbol>`) and its mtime advanced; when in doubt, `rm -rf .zig-cache && rm -f <prefix>/bin/nova` then rebuild and install.

## Known Issues

- **Session resume segfault (null `model_id`).** Crash at `src/ai/openai_compatible.zig:59` (`gpa.dupe(u8, config.model)`) when a null `summary.model_id` flows into `ModelSelection.custom.model.id` (non-optional `[]u8`). Guarded at three entry points: `runtime.applyFromConfig` skips attachment on empty `model_id`; `tui.applySelectedModel` returns `error.EmptyModelId`; `writeRequestPayload` returns `error.EmptyModelId` (H1). Always use a real early return, never `std.debug.assert` — `unreachable` is UB in ReleaseFast and would not protect that build. Previous fix: `da7c761`.

- **Debug prints masking segfaults.** Adding `std.debug.print` can change a segfault into a downstream error (e.g. `session.resume.failed err=Sqlite`), suggesting heap corruption. Suspect use-after-free or double-free between the crash site and the new error.

- **ReleaseFast debugging.** Use `std.debug.print` not `std.log.debug` — ReleaseFast strips log levels, so `std.log.debug` is a no-op.

- **Session config copy semantics.** `session_config` is a value-copy of `config`; union fields are shallow-copied, so mutating a union field on the copy doesn't affect the original.

- **vxfw FocusHandler crash on empty `path_to_focused` (LOCAL VENDOR PATCH REQUIRED).** Resume/session-switch crashes (SIGSEGV in ReleaseFast, assert in Debug) at `vxfw/App.zig:590`. Cause: `installRuntime` (transcript_lifecycle.zig) deinits the old runtime while vxfw's `focused_widget` still points at a TextField in that destroyed runtime; the next frame leaves the focus path empty and the next key event dereferences it. Upstream bug (HEAD `cca454be`), so a vaxis bump does NOT fix it. **Two guards applied manually** to `zig-pkg/vaxis-<hash>/src/vxfw/App.zig` (search `NOVA-LOCAL-PATCH`): (1) `update()` falls back to `self.root`; (2) `handleEvent()` returns early instead of `assert(path.len > 0)`. **Re-apply after every `zig build --fetch` / vaxis bump** (vendor dir is gitignored). Remove both once the upstream PR lands past the pinned commit.

  To re-apply on a freshly-fetched vendor:
  1. In `FocusHandler.update`, guard `if (self.path_to_focused.items.len == 0)` → append `self.root`, else fall through to the original `else if`.
  2. In `FocusHandler.handleEvent`, replace `assert(path.len > 0);` with `if (path.len == 0) return;`.
  Verify: build ReleaseFast, run the PTY repro (open `/resume`, select a session, type a prompt, press keys) — must NOT signal 11.

- **`installRuntime` (session switch) checks only the active lane's turn — by design.** Other lanes keep running against their own runtimes; each lane owns its runtime, so a switch must not tear down lanes still in use. Completion routing is generation-safe across the switch (M1). Documented in `transcript_lifecycle.zig` and `_plan/plan-lane-worker-hardening-2026-08-05.md` (I4).

## Logging
- **Sinks:** In Debug mode, logs go to both `nova.log` and stderr. In Release builds, logs go to stderr only (`warn` level and above by default). The file-writer thread is Debug-only (`logger.enabled_file`); the stderr sink is compiled in all builds, so the shipped ReleaseFast binary keeps an operational trail. Every line carries an ISO-8601 UTC timestamp prefix (`lib/logger.zig` `formatTimestamp`, via `clock_gettime(REALTIME)` — no `Io` handle available in the writer thread / pre-init path).
- **Toast routing (warn+):** `logger.Options.toast_sink` is an opaque `?*const fn (level, msg) void` installed by `root.run`. With the TUI up, `warn`+ messages route to the global toast bus (`src/tui/toast.zig`) **instead of stderr** — stderr bytes land in the alternate screen and tear the rendered frame, so the toast overlay is the intended surface. The routing decision in `dispatch` keys off `stderr_explicit`: when `NOVA_LOG_STDERR_LEVEL` is **not** set and a sink is installed, `warn`+ goes to the toast only; when it **is** set, `warn`+ goes to **both** stderr and the toast (the operational channel is restored). With no sink (headless/tests), stderr keeps the default `warn`/`err` gate. The sink is TUI-agnostic — logger just calls the function pointer, no `lib → src` dependency.
- **Knobs:**
    - `NOVA_LOG_FILE`: Path to the log file (path max 1024 bytes).
    - `NOVA_LOG_STDERR_LEVEL`: Min level for stderr (default: `warn` in release, `err` in debug). One of `err|warn|info|debug`, case-insensitive. An explicit value is treated as "user wants stderr" and overrides the toast-only default.
    - `NOVA_LOG_MAX_BYTES`: Max size before rotation (default: 10MB). On launch, if the existing log exceeds this, `nova.log` is renamed to `nova.log.1` (one generation) and a fresh file starts.
- **Diagnostics:** To see all logs in release: `NOVA_LOG_STDERR_LEVEL=debug nova 2> err.log`.
- **Use `warn`, not `err`, for logged failures.** Zig 0.16's test runner hard-wires `log_err_count == 0` as a success gate (`Build/Step.zig` `isSuccess`): any `log.err(...)` from a passing test marks it failed. Many tests deliberately exercise error paths (HTTP 5xx retry, dead MCP server, compaction failure), so those messages must be `warn`. The stderr sink (B1) surfaces `warn` in **all** builds including ReleaseFast, so operational visibility is preserved without tripping the test gate. Reserve `err` for nothing in this codebase today — the gate makes it unusable. The pre-init escape hatch (`dispatch` when `stderr_ready == false`) writes raw to fd 2 via `std.c.write` (no `io`, no lock).
