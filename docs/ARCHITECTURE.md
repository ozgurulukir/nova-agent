# Nova Architecture

High-level architecture of Nova. For implementation patterns, engineering gotchas, and the type-system discipline, see [Patterns](PATTERNS.md). For configuration details, see [Configuration](CONFIG.md). For MCP internals, see [MCP](MCP.md). For plugin development, see [Plugins](plugins/README.md).

## Platform Abstraction

`lib/platform.zig` centralizes OS-adaptive behavior so the rest of the codebase stays clean of `builtin.os.tag` switches. It provides portable helpers for the operations that differ between POSIX and Windows:

- `writeToFd` — raw file-descriptor writes (replaces `std.c.write`)
- `realtimeNowNs` / `monotonicNowNs` — clock reads (replace `std.c.clock_gettime`)
- `getEnvMap` — environment access (replaces raw `std.c.environ` reads)

POSIX-only syscalls (`std.posix.kill`, `std.posix.poll`, `setsockopt`, `std.c.realpath`) are guarded behind `if (!os.is_windows)` at their call sites. This is what lets the app compile on Windows while leaving Linux behavior unchanged.

This is distinct from `src/os.zig`, which is pure comptime OS identification (`builtin.os.tag`); `lib/platform.zig` is the runtime behavior layer built on top of that identification.

## LLM Gateway

Nova accepts any OpenAI-compatible endpoint (either `/completions` or `/responses`).

We try to normalise the request to a shape that is most compatible with the target provider.

## Agent Tools

Nova exposes the following tools:

- `bash` (on Linux/macOS) / `pwsh` (on Windows)
- `lane`

`bash` has some middleware written for it that makes it friendlier for agent use. For example, large outputs from a `cat` command are written to a temp file and the agent is told the full is in that file if needed. See [Shell Safety & Auto-Review](#shell-safety--auto-review) below.

`lane` gives the model first-class access to Nova's parallel-lane substrate: isolated git worktrees the TUI tiles side-by-side. It is a *bridge* tool — the tool runs on the lane's worker thread, so every action is posted across a `LaneBridge` (`src/tools/lane_bridge.zig`) and resolved by the UI on its tick. The model-facing surface is orchestration-only: `list`, `spawn`, `read`, `await`, `steer`, `cancel`, `merge`, and `delete`.

The primary driver remains rooted in the repository and supervises independent
worker agents. Workers run concurrently on their own threads; completion is
delivered back to the driver (`deliverPendingLaneCompletions`) and finished
workers are auto-parked (runtime freed, transcript kept). Internal workspace
state (`Agent.workspace` and executor `effectiveCwd` re-rooting) remains for
compatibility with lifecycle code and tests, but model commands cannot reach it.

Only the primary driver may supervise workers or integrate their branches; a
worker gets `list`/`read` only. The 4-lane cap applies; `validateCwd`'s
containment guarantees are unchanged (lane roots are valid only because Nova
owns them).

See [Parallel](#parallel) for the user-facing lane model.

### Tool schema strict mode

Builtin and MCP tool schemas are serialized with OpenAI strict-mode semantics (opt-in via `ai.Config.strict`):

- `strict: true`
- Top-level `parameters` uses `additionalProperties: false`
- Optional fields carry `nullable: true` and emit `["<type>", "null"]` union arrays
- Nested free-form objects like `env` keep `additionalProperties: true`

The full strict-mode design, its gateway-incompatibility caveats, and its persistence rules live in the [Tool schema strict-mode pattern](PATTERNS.md#tool-schema-strict-mode-pattern) in Patterns.

## Steering

Steering is done by enqueuing messages into a bounded queue. By default, the front of the queue is popped and appended to the conversation after the agent's turn is finished. You can also choose to _steer_ instead and send the queued message after the next tool call is done. If the agent stops and there are still messages in the queue we flush all the messages and append them into the conversation.

## Timeline

User's can branch off at any point in their conversation to pursue different paths and try different approaches. These are saved into the session and are resumable. When a branch occurs, we actually revert the entire project state to that point in time, not just the conversation. This is achieved via git shadow snapshots. User messages, assistant messages and even tool calls are all valid branching points. Once you're happy with a certain branch, you can `/save` it to commit to the working tree.

## Session Persistence

The session store (`sessions.sqlite`) records the active `model_provider`, `model_id`, and `reasoning_effort` on every turn and on every mid-session model switch, and resumes correctly across restarts — including cross-project resumes. The full lifecycle (schema, resume paths, custom-provider round-tripping, dynamic-provider auth resolution, restart catalog restore) is documented in the [Mid-session model persistence pattern](PATTERNS.md#mid-session-model-persistence-pattern), the [Cross-project session resume pattern](PATTERNS.md#cross-project-session-resume-pattern), and the related provider patterns in Patterns.

## Parallel

Subagent workflows are achieved by the `/parallel` command which creates a
separate git worktree and live runtime for a user-selected agent. The TUI
supports tiling so multiple agents can be on the screen at any time. We call
each tile a `lane`. In `grid` or `tab` mode the selected lane receives user
prompts; `dual` keeps the primary as the input target. `/close` parks the
selected lane, while the user can open the UI merge flow from an idle lane or
the primary driver can merge/delete it by lane id. The maximum number of lanes
that can be active is currently 4, because that is the empirical limit for the
mental load required to manage all agents effectively.

A lane starts on a random `nova/<hex>` branch. On its first prompt, the session's own model is asked (in parallel with the turn) for a descriptive branch name based on that prompt and the last few messages of the parent lane. When the answer lands, the branch is renamed in place (`nova/<name>`) and becomes the lane's label. If the request fails or the name is unusable, the hex branch simply stays.

## Shell Safety & Auto-Review

Nova employs a two-tier defense-in-depth safety architecture to evaluate shell tool invocations (`bash` on Linux/macOS, `pwsh` on Windows) before execution:

1. **Tier 1: Built-in Deterministic Safety Matcher (Always Active):**
   A zero-dependency pattern and AST analyzer in `src/tools/bash_safety.zig` intercepts destructive operations with microsecond latency:
   - `rm -rf /`, `rm -rf /*`, `rm -rf --no-preserve-root /`
   - Fork bombs (`:(){ :|:& };:` and PowerShell unbounded job loops)
   - Destructive `dd` to block devices (`of=/dev/sda`, `of=/boot/`, etc.)
   - `mkfs` targeting `/dev/`
   - PowerShell drive root wipes (`Remove-Item -Recurse -Force C:\`, `Clear-RecycleBin -Force`)
   - Redirects into critical system paths (`/etc/`, `/boot/`, `C:\Windows\`, etc.)

2. **Tier 2: External AI Safety Classifier (Optional & Pluggable):**
   Nova can query a standalone REST safety service (`POST /classify`) powered by a fine-tuned Transformer model (ModernBERT) or an LLM safety proxy located in `tools/classifier/`. When marked unsafe, an interactive approval prompt is presented to the user.

For setup details, see [Wiki: Command Safety & Classifier Guide](wiki/SAFETY_CLASSIFIER.md).

### Working directory validation

The `cwd` parameter in bash tool calls is validated against the project root in `src/tools/bash.zig` (`validateCwd`). The resolved path is normalized (resolving `..` and `.` segments) and checked to stay within the project root. This prevents the model from escaping the project via absolute paths like `/etc` or relative paths like `../../sensitive`.

### Temp file safety

Temporary log files use hex-only filenames (`nova-bash-<hex>.log` via `bytesToHex`), making path traversal impossible. The `namedTempPath` public API asserts that the provided name contains no path separators.

## Lua Plugin System

Nova supports extending its capabilities through Lua 5.4 plugins. The plugin system lives in `src/lua/` and provides a sandboxed runtime, plugin lifecycle, event bus, tool registration, config integration, bytecode caching, and TUI integration.

The full plugin development guide, API reference, and example walkthroughs live in [Plugins](plugins/README.md). The internal wiring patterns (tool dispatch, event wiring, bridge functions, two-store state) live in [Patterns](PATTERNS.md).

## Type System Discipline

Nova uses `union(enum)` instead of flat structs with optional fields wherever a value can be in one of several mutually-exclusive states. This makes illegal combinations unrepresentable at compile time.

The complete, current list of `union(enum)` types and the construction patterns live in the [Type System Discipline pattern](PATTERNS.md#type-system-discipline-pattern) in Patterns.
