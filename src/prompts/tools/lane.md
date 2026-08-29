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
(for example, `e1e94861c257`). `[0]` is the primary driver lane and cannot be
passed to worker operations.

## Worker Workflow

1. Call `lane list` to check existing lanes and available capacity.
2. Call `lane spawn` with a self-contained task. Include exact paths, the
   expected implementation, tests, and constraints; the worker starts with
   fresh context.
3. Continue independent work while the worker runs. Use `lane read` for
   progress and `lane steer` when its task needs clarification.
4. Call `lane await` when the next step needs the worker's result.
5. After the worker is idle and its worktree is clean, call `lane merge` to
   integrate it. Call `lane delete` when the work should be discarded.

## Safety Rules

- Only the primary driver may spawn, supervise, merge, or delete workers.
- A worker lane must be idle before it is merged or deleted.
- Commit lane work before merging. Nova never fabricates a placeholder commit.
- The primary tree and source lane must be clean before a merge.
- Clean up every spawned lane with `merge` or `delete`; do not leave finished
  lanes parked unnecessarily.
- There are at most four lanes total: the primary plus three workers.
- Never run `git worktree add`; Nova owns worktree provisioning and lane cleanup.
