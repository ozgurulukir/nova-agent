# GitNexus Engineering Plan

> Task: Refactor `src/tui/root_layout.zig` (drawRoot, 300 lines), `src/tui/mode_lifecycle.zig` (submitMode, 276 lines), and `src/tui/lane_lifecycle.zig` (spawnLane, 259 lines) — split oversized functions, improve readability and maintainability, without touching `plugin_api.zig` or `agent.zig`.
> Evidence verified at commit 7163ab3435ab352ddf18c1908bc5522b189ced56; GitNexus index refreshed this session (`analyze --index-only --pdg`).
> Evidence provenance schema 2; global dirty digest (clean working tree, no unstaged changes); cited-path manifest 3 entries sorted; exact generated plan path excluded.

## 1. Objective

Split three oversized TUI functions — `drawRoot` (339 lines, file 339 lines), `submitMode` (276 lines), `spawnLane` (259 lines) — into well-scoped helpers so each function fits in one screenful (~100 lines or fewer). Preserve all existing behaviour, tests, and signatures. No changes to `src/lua/plugin_api.zig` or `src/agent.zig`.

## 2. Current Behaviour

**`src/tui/root_layout.zig` — `drawRoot(app, root_widget, ctx)` [file: L39-L339, 300 lines]**
Single function that decides per-frame screen layout: diff-viewer short-circuit, loading spinner, split-mode grid (dual/4-col), transcript column, plus stacked overlays (mode overlay, permission prompt, background-jobs modal, at-search popup, toast). Owns all `SizedBox`/`FlexRow`/`FlexColumn`/`Center` construction and `SubSurface` assembly. The overlay-z-index ordering (0..4) and the `children` arena allocation are all inline.

**`src/tui/mode_lifecycle.zig` — `submitMode(app)` [file: L200-L476, 276 lines]**
Dispatches Enter key by `app.mode`: search, settings, provider_picker, model_picker, session_picker, tree_picker, theme_picker, save_message, lanes, command. Each branch calls into `provider_model`, `session_switcher`, `theme_lifecycle`, `diff_lifecycle`, `compaction_lifecycle`, `clipboard_helper`. Guards `refuseOnIdleLane(app)` for branches that deref `app.liveRuntime().?`. Ends with `return false` (unhandled) — caller (`beginSubmit`) starts the turn.

**`src/tui/lane_lifecycle.zig` — `spawnLane(app, req, requester_lane)` [file: L1190-L~1380+, 259 lines visible]**
Two paths: (a) `req.lane` targets an existing idle lane → `wakeIdleLane` + `startTurnForLane`; (b) fresh-worktree path → `WorktreeJob.start`, `createRuntime`, wire agent subsystems, `startTurnForLane`. Both paths share error handling, context-free-on-failure, and generation-tracking (`spawned_by_generation`). The fresh-worktree path handles the async worktree job, the 4-lane cap, branch naming, and rollback on failure.

## 3. Relevant Architecture

- **INV-WIDGET-1**: leaf widgets (`TranscriptWidget`, `LoadingWidget`, `InputWidget`, `OverlayWidget`, `PermissionWidget`, `BackgroundJobsWidget`, `AtSearchWidget`, `ToastWidget`) take scalars computed per frame. `drawRoot` currently assembles them inline — a natural decomposition into per-widget build functions.
- **R6.2 / R5.2b**: `root_layout.zig` was pulled out of `tui.zig` precisely to own the draw callback; the extracted file is now the bottleneck.
- **Delegate pattern**: `App.submitMode` is a delegate to `mode_lifecycle.submitMode`; tests reach it via `app.submitMode()`.
- **Idle-lane guards**: `refuseOnIdleLane(app)` (L134) and `closeRuntimeBoundOverlays(app, lane_id)` (L159) are shared safety gates in `mode_lifecycle.zig`. `submitMode` calls both.
- **Lane engine states**: `Thread.Engine = union(enum) { idle: vcs.Lane, live: Live }`. `spawnLane` operates on `idle` lanes only; `parkFinishedWorker` downgrades `.live` → `.idle`.
- **`App.thread` swap**: `spawnLane` swaps `app.thread` to `spawner` for `captureLaneContext`, then restores — a pattern that must stay intact.

## 4. GitNexus Findings

- Index refreshed with `--pdg`: 984 nodes, 1,405 edges, 6 clusters, 3 flows. PDG layer now persisted for statement-level analysis.
- `drawRoot` is referenced by `tui.zig`'s `RootWidget` draw callback (via `root_layout.drawRoot`). No other callers — safe to restructure the body.
- `submitMode` is exposed as `pub fn` on `App` (delegate); `mode_lifecycle.refuseOnIdleLane` and `closeRuntimeBoundOverlays` are called from `submitMode` and `event_router`. The command cases in `submitMode` dispatch to `provider_model`, `session_switcher`, `theme_lifecycle`, `diff_lifecycle`, `compaction_lifecycle`, `clipboard_helper`, `tui.openMcp/Plugins/Settings/ThemePicker`, `app.createParallelLane`, `app.beginSave`, `app.openSearch`, `app.closeActiveLane`, `app.createMergePicker`, `app.openLanesPicker`, `app.clearConversation`, `app.undoLastTurn`.
- `spawnLane` is called from `lane_lifecycle`'s public `laneSpawn` wrapper and `command_router`. It calls `wakeIdleLane`, `startTurnForLane`, `parkFinishedWorker`, `createRuntime`, `rollbackLaneWorktree`, `freeLaneContext`, `lanes_util.idleLaneId`.
- Test files: `src/tui/mode_lifecycle.zig` has 13 inline tests (L549-L915) exercising `submitMode` branches, `closeRuntimeBoundOverlays`, `syncModeWithInput`, `cancelMode`. These must all continue passing.

## 5. Statement-Level PDG Findings

**`drawRoot`** (control/data dependencies — intra-procedural, since the PDG layer is freshly built):
- Control dependencies: `app.mode == .diff_viewer` (early return, guards all subsequent allocations); `split` (selects dual vs 4-col grid vs single transcript); `overlay_visible`, `permission_visible`, `background_visible`, `at_visible`, `toast_visible` (each guards a `SubSurface` child).
- Data dependencies: `app.split_rects` is written and later read by `routeMouse` — the stash must stay. `app.split_rect_count`, `app.input_surface_row`, `app.nav.lanes_chip_rect` are written here and read elsewhere.
- State mutations: writes to `app.split_rect_count`, `app.input_surface_row`, `app.nav.lanes_chip_rect`, `app.split_rects`. All happen before the draw calls — safe to move into a helper, but must remain ordered before `main_surface` draw.
- Planning implication: Extract `drawRoot` body into `drawRootImpl` or per-overlay helpers (`drawOverlays`, `drawTopArea`, `drawMainFlex`). The early-return diff-viewer path and the `split` decision can be a separate `buildTopWidget` helper.

**`submitMode`**:
- Control dependencies: `app.mode` switch drives which branch fires; `refuseOnIdleLane` guards 4 branches (provider_picker, model_picker, session_picker, and the `.new/.resume_session/.timeline/.undo/.connect` command cases).
- Data dependencies: `app.pickers.provider.stage`, `app.nav.session_action`, `app.nav.command_selection`, `app.theme_preview_original`. All are read-only or set immediately before return.
- State mutations: `app.mode = .normal/command/help/theme_picker/save_message`, `app.nav.command_selection = 0`, `app.clearInput()`, `app.clearPaletteInput()`. These are the observable side effects.
- Error branches: every `catch |err| try app.report*` path; `InFlightTurn` branch keeps picker open.
- Planning implication: Extract per-mode dispatches into `submitModeSearch`, `submitModeSettings`, `submitModeProviderPicker`, `submitModeModelPicker`, `submitModeSessionPicker`, `submitModeTreePicker`, `submitModeThemePicker`, `submitModeSaveMessage`, `submitModeLanes`, `submitModeCommand`. `refuseOnIdleLane` stays in `mode_lifecycle` (shared). The `crashes_on_idle` switch can be a lookup table or extracted to `commandCrashesOnIdle`.

**`spawnLane`**:
- Control dependencies: `req.lane` present/absent splits the two paths; `app.threads.len() >= max_threads` caps; `app.async_worktree_job` present/absent.
- Data dependencies: `context` (caller-owned, freed on failure), `wt_dest_owned`/`wt_branch_owned` (deferred), `job` (async worktree).
- State mutations: `app.thread = spawner` (swap), `app.async_worktree_job = job`, `target.spawned_by_generation`, `app.gpa.free` on rollback.
- Error branches: every `catch |err|` returns a `Resp`, never propagates. `errdefer` used for `branch`, `dest`, `parent`, `wt_branch`, `wt_dest`.
- Planning implication: Extract the fresh-worktree setup (branch/name/cap/job creation) into `startFreshWorktree(app, repo, home)` returning `?WorktreeJob`. Extract the shared "attach runtime + start turn" into `attachAndStartTurn(app, target, wt_dest, wt_branch, context, framed, task)`. Extract `wakeIdleLane` path setup into `resumeIdleLane(app, target, target_id, context)`.

## 6. Proposed Changes

### 6.1 `src/tui/root_layout.zig` — `drawRoot` (339 → ~100 lines)

| Step | Change |
|---|---|
| 6.1.1 | Extract diff-viewer early-return into `drawDiffViewerShortcut(app, root_widget, ctx) -> ?vxfw.Surface` — returns `null` if not diff mode. |
| 6.1.2 | Extract top-widget construction (split vs single transcript, `SizedBox`/`FlexRow`/`FlexColumn` assembly) into `buildTopWidget(app, ctx, layout, split_cols, max_width, max_height) -> vxfw.Widget`. |
| 6.1.3 | Extract `main_flex_buf` assembly (top_widget + loading + input) into `buildMainFlex(app, ctx, top_widget, loading_box, input_box, layout) -> vxfw.FlexColumn`. |
| 6.1.4 | Extract overlay children assembly (the `children` arena loop for overlay/permission/background/at/toast) into `buildOverlaySurfaces(app, ctx, layout, children_arena, child_count) -> []vxfw.SubSurface`. |
| 6.1.5 | `drawRoot` becomes: early-return check + `buildTopWidget` + `buildMainFlex` + `buildOverlaySurfaces` + return struct. |

Constraint: preserve z-index ordering (0..4). Preserve `app.split_rect_count`, `app.input_surface_row`, `app.nav.lanes_chip_rect` writes before draw. All `SizedBox`/`FlexRow`/`FlexColumn`/`Center` variables can be local to the helpers.

### 6.2 `src/tui/mode_lifecycle.zig` — `submitMode` (276 → ~80 lines)

| Step | Change |
|---|---|
| 6.2.1 | Extract `refuseOnIdleLane` guard into `trySubmitWithIdleGuard(app, mode, action: fn() anyerror!void) -> bool` — wraps the `refuseOnIdleLane` + `catch |err| try app.reportConnectionError(err)` pattern shared by provider/model/session cases. |
| 6.2.2 | Extract each `if (app.mode == .X) { ... return true; }` branch into `submitModeX(app) -> bool`. Target functions: `submitModeSearch`, `submitModeSettings`, `submitModeProviderPicker`, `submitModeModelPicker`, `submitModeSessionPicker`, `submitModeTreePicker`, `submitModeThemePicker`, `submitModeSaveMessage`, `submitModeLanes`, `submitModeCommand`. |
| 6.2.3 | `submitMode` becomes: a dispatch table of `mode -> fn(app) bool` or a chain of `if` calls, each delegating to the extracted helper. |
| 6.2.4 | Extract the command-case `crashes_on_idle` switch into `commandCrashesOnIdle(cmd) -> bool` (L375-378). |
| 6.2.5 | Extract the `/theme <name>` arg fast-path into `tryThemeArg(app, filter) -> bool` (L360-366). |

Constraint: preserve all `return true` / `return false` semantics. Preserve `defer app.gpa.free(filter)` pattern for `peekPaletteInput`. All 13 inline tests must pass unchanged.

### 6.3 `src/tui/lane_lifecycle.zig` — `spawnLane` (259 → ~100 lines)

| Step | Change |
|---|---|
| 6.3.1 | Extract the fresh-worktree setup (branch naming, `WorktreeJob.start`, `async_worktree_job` check, cap check) into `startFreshWorktree(app, repo) -> ?WorktreeJob` — returns `null` to keep pending, or the job. |
| 6.3.2 | Extract the idle-lane wake path (req.lane → resolve → wakeIdleLane → startTurnForLane) into `resumeIdleLane(app, target, target_id, context) -> Resp`. |
| 6.3.3 | Extract `createRuntime` + wire agent subsystems + `startTurnForLane` into `attachRuntimeAndStartTurn(app, target, wt_dest, wt_branch, framed, task) -> Resp`. |
| 6.3.4 | Extract `buildSpawnFramedMessage` (the `std.fmt.allocPrint` of the worker prompt) into a helper. |
| 6.3.5 | `spawnLane` becomes: validate → `req.lane` branch (`resumeIdleLane`) or fresh path (`startFreshWorktree` → `attachRuntimeAndStartTurn`). |

Constraint: preserve `app.thread` swap + `context` ownership rules. Preserve `spawned_by_generation` rollback via `parkFinishedWorker`. Preserve `B2`/`TD-2b` re-spawn revert logic. Preserve `freeLaneContext` on every failure path.

## 7. Implementation Sequence

1. **`root_layout.zig` first** — pure rendering, no side effects, lowest risk. Tests: `zig build test` (visual regression via TUI tests).
2. **`mode_lifecycle.zig` second** — has 13 inline tests; highest test coverage to validate against. Run `zig build test` after each extracted function.
3. **`lane_lifecycle.zig` third** — most complex (worktree, runtime, async job). Requires `zig build test` and manual verification of `lane spawn` path.
4. **`zig fmt`** after each file.
5. **`zig build test`** full suite after all three files.

Step risks:
- `6.1.2` (buildTopWidget): the `SizedBox`/`FlexRow`/`FlexColumn` variables are currently stack-allocated and passed by reference into `.widget()` calls — ensure the helper returns the final widget, not references to locals.
- `6.2.2` (submitMode dispatch): the `defer app.gpa.free(filter)` pattern is fragile; each extracted helper must own its own `filter` lifetime.
- `6.3.3` (attachRuntimeAndStartTurn): the `runtime.agent.background_manager = app.background` etc. wiring must stay exactly ordered — `createRuntime` must succeed before any subsystem assignment.

## 8. Test Strategy

- **Existing tests**: all 13 inline tests in `mode_lifecycle.zig` must pass verbatim. The `drawRoot` function has no direct unit tests; the TUI integration tests in `src/tui/tests.zig` cover the render path.
- **New tests**: add a test per extracted helper where behaviour is testable in isolation:
  - `test "drawRoot returns diff viewer surface when mode is diff_viewer"` (root_layout.zig).
  - `test "commandCrashesOnIdle returns true for new/resume/timeline/undo/connect"` (mode_lifecycle.zig).
  - `test "startFreshWorktree respects max_threads cap"` (lane_lifecycle.zig) — may require a test harness.
- **Verification**: `zig fmt src/tui/root_layout.zig src/tui/mode_lifecycle.zig src/tui/lane_lifecycle.zig && zig build test`.

## 9. Source Read Verification

All claims verified by direct source reads (not graph-only):
- `drawRoot` L39-L339 (339 lines) [verified]: `/home/aristo/Projects/nova-agent/src/tui/root_layout.zig`.
- `submitMode` L200-L476 (276 lines) [verified]: `/home/aristo/Projects/nova-agent/src/tui/mode_lifecycle.zig`.
- `spawnLane` L1190-L1380+ [verified]: `/home/aristo/Projects/nova-agent/src/tui/lane_lifecycle.zig`.
- Inline tests L549-L915 [verified]: `/home/aristo/Projects/nova-agent/src/tui/mode_lifecycle.zig`.
- `refuseOnIdleLane` L134 [verified], `closeRuntimeBoundOverlays` L159 [verified].
- `root_layout.zig` imports and INV-WIDGET-1 comment [verified]: L1-L38.

## 10. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| `drawRoot` extracted helpers capture local variables by reference after the helper returns | All `SizedBox`/`FlexRow`/`FlexColumn`/`Center` must be constructed and `.widget()` called inside the helper; return only the final `vxfw.Widget` or `vxfw.Surface`. |
| `submitMode` extracted helpers change `defer` lifetimes | Each helper takes ownership of its `filter` (duped if needed) and frees before return. The `defer` moves into the helper. |
| `spawnLane` refactor changes `app.thread` swap semantics | Keep `app.thread = spawner` / `app.thread = prev_thread` exactly where they are; the extracted helpers receive `spawner` and `context` as params. |
| TUI visual regression after `drawRoot` refactor | Run `zig build test` and visually verify the TUI renders the same layout. The `SubSurface` z-index ordering is preserved. |
| `mode_lifecycle.zig` tests fail after extraction | Re-run `zig build test` after each extraction; fix any `defer` or ownership bugs immediately. |

## 11. Implementation Context (mini-pack)

- **Files to modify**: `src/tui/root_layout.zig`, `src/tui/mode_lifecycle.zig`, `src/tui/lane_lifecycle.zig`.
- **Files to NOT modify**: `src/lua/plugin_api.zig`, `src/agent.zig` (per user constraint).
- **Key types**: `App`, `Thread`, `Thread.Engine`, `vxfw.Widget`, `vxfw.Surface`, `vxfw.SizedBox`, `vxfw.FlexRow`, `vxfw.FlexColumn`, `vxfw.Center`, `vxfw.SubSurface`, `vxfw.DrawContext`, `lane_bridge.Request`, `Resp`.
- **Key imports to preserve**: each file's existing `@import` chain. New helpers in the same file use the same imports.
- **Test files**: `src/tui/tests.zig`, inline tests in `mode_lifecycle.zig`.

## 12. Assumptions and Open Questions

- Assumption: `drawRoot`'s `SizedBox`/`FlexRow`/`FlexColumn` locals can be moved into helpers without lifetime issues — verified by the pattern that `.widget()` is called before the helper returns.
- Assumption: `submitMode`'s `defer app.gpa.free(filter)` can be moved into extracted helpers — each helper will `peekPaletteInput` its own copy or receive a `[]const u8` param.
- Open question: whether `submitMode` extraction should use a `fn(app) bool` dispatch table vs. a `switch(app.mode)` chain — the dispatch table is more extensible; the chain matches the current style. Prefer chain to match project style (see `drawRoot` pattern).
- Open question: `spawnLane`'s `WorktreeJob` struct definition — needs to be verified for visibility (pub vs internal). Check `WorktreeJob` definition before extracting `startFreshWorktree`.
- Assumption: no existing unit tests for `drawRoot` — confirmed by source read; only TUI integration tests exist.

## 13. Definition of Done

- `drawRoot` ≤ 100 lines (excluding the early-return diff-viewer check, which can be a 5-line guard).
- `submitMode` ≤ 100 lines (dispatch chain only).
- `spawnLane` ≤ 100 lines (dispatch + two path branches only).
- `zig fmt` passes on all three files.
- `zig build test` passes, including all 13 `mode_lifecycle.zig` inline tests.
- No changes to `src/lua/plugin_api.zig` or `src/agent.zig`.
- All extracted functions are `pub` or `fn` as appropriate (helpers stay `fn` unless needed externally).
- `git diff --stat` shows only the three target files modified.
