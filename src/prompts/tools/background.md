Query and manage long-running background jobs started with `run_in_background: true` on the shell tool (`bash`/`pwsh`).

## Calling the tool

Every call takes `command` (always required) naming the operation.

| command | required args | optional args | what it does |
|---|---|---|---|
| `list` | — | — | List all currently active/running background jobs (id, label, elapsed duration, command, log path) |
| `status` | `id` | — | Query detailed status, elapsed duration, and recent log output of a currently running background job |
| `cancel` | `id` | — | Request process-tree termination of a running background job |
| `tail` | `id` | `lines` (default 50, max 200) | Read bounded tail lines from a running background job's log file |

The job id is an integer (e.g. `1` for job `bg_1`).

## Examples

- List active running jobs:
  `{"command":"list"}`
- Check status of job 1:
  `{"command":"status","id":1}`
- Inspect the last 100 lines of job 2's log:
  `{"command":"tail","id":2,"lines":100}`
- Request termination for job 3:
  `{"command":"cancel","id":3}`

## Rules & Best Practices

- **Active-Only Inspection:** `list`, `status`, and `tail` inspect active jobs currently managed by the runtime. Once a job completes, its exit notification is delivered to the lane transcript and it is cleared from active tracking.
- **Do not poll in a tight loop:** Background job completion is automatically delivered to you as a message when the process exits. Use `status` or `tail` only when you need an interim progress check before proceeding with other work.
- **Bounded Inspection:** The `tail` operation returns up to the requested number of lines (capped at 200 lines / 64 KB scan) to keep context concise.
- **Clean Termination:** When a background build, server, or watcher is no longer needed, request termination with `{"command":"cancel","id":<id>}` to free system resources. Cancelled jobs are logged to the transcript and do not start a model follow-up turn.
