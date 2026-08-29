Drive Nova's background worker lanes: isolated git worktrees that the TUI
tiles side-by-side. A worker lane has its own branch and runtime; the primary
driver stays in the repository root and supervises workers through this tool.

## Calling the tool

Every call takes `command` (always required). Which other arguments a command
needs:

| command | required args | what it does |
|---|---|---|
| `list` | — | every open lane (lane id, title, branch, status, activity), your workspace root, and parked lanes |
| `spawn` | `task`, optionally `lane` | start an independent worker in a fresh lane, or reuse an existing idle lane |
| `read` | `lane` | snapshot a worker lane's conversation tail and live activity |
| `await` | `lane` | wait for a worker to finish or report a bounded stall |
| `steer` | `lane`, `steer` | inject a short instruction into a running worker |
| `cancel` | `lane` | stop a running worker |
| `merge` | `lane` | integrate a finished worker branch and clean up its lane |
| `delete` | `lane` | discard an idle or parked worker branch and worktree |

The lane id always goes in the `lane` field. `lane list` prints the hex id
(for example, `e1e94861c257`). This tool has no `id` parameter. `[0]` is the
primary driver lane and cannot be passed to worker operations.

## Worker Workflow

1. Call `lane list` to check existing lanes and available capacity.
2. Call `lane spawn` with a self-contained task. Include exact paths, the
   expected implementation, tests, and any constraints; the worker starts with
   fresh context.
3. Continue independent work while the worker runs. Use `lane read` for
   progress and `lane steer` when its task needs clarification.
4. Call `lane await` when the next step needs the worker's result.
5. After the worker is idle and its worktree is clean, call `lane merge` to
   integrate it. Call `lane delete` when the work should be discarded.

`spawn` can reuse an existing idle lane when `lane` is provided. The lane keeps
its transcript and branch; the new task becomes the next worker turn. Every
task must be self-contained because the worker cannot see this conversation.

## Actors

- The primary driver uses this tool for worker orchestration and remains rooted
  in the primary repository.
- A worker agent may use normal coding tools in its own worktree. A worker may
  observe lanes with `list` and `read`, but cannot supervise other workers.
- A user-selected lane created with `/parallel` may run its own agent and
  accept normal prompts in `grid` or `tab` mode. That is a TUI workflow, not a
  request for the primary driver to change its workspace.
- The user can commit work in a selected lane, then use the UI merge flow while
  that lane is idle. The driver can also merge or delete it by explicit lane id.

## Safety Rules

- Only the primary driver may spawn, supervise, merge, or delete workers.
- A worker lane must be idle before it is merged or deleted.
- Commit lane work before merging. Nova never fabricates a placeholder commit.
- The primary tree and source lane must be clean before a merge; conflicts leave
  the lane available for resolution.
- Clean up every spawned lane with `merge` or `delete`; do not leave finished
  lanes parked unnecessarily.
- There are at most four lanes total: the primary plus three workers.
- Never run `git worktree add`; Nova owns lane creation and cleanup.

## Choosing the Right Worker Task

Use one worker per independent unit of work. Good tasks are a focused review,
candidate implementation, test investigation, or bounded documentation update.
Use staged tasks when one worker's result is required before starting the next.
Do not duplicate a delegated task in the primary lane; supervise it instead.
