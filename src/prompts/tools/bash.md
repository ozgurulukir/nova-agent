Run a shell command.

- Set the working directory with the `cwd` parameter (fresh shell per call). `cwd` must be within the project root.
- Pass multiline or complex values via `env: { NAME: "..." }`. Reference them as `"$NAME"`.
- Provide a `description` for every command explaining what it does.
- Quote every expansion: `"$var"`, `"$(cmd)"`, `"${arr[@]}"`.
- Default timeout is 30 seconds. Raise with `timeout` when a command needs longer; a timed-out result explains how to retry.
- Prefer targeted commands (`rg`, `find`, `git diff --stat`, `head`, `tail`) over dumping large files or full build logs.
- Command outputs exceeding 50 KB or 2000 lines are truncated with a `[Showing last N of M lines (X of Y bytes). Full output: /path]` footer. Inspect that path or use a narrower command; never re-run the entire command just to see the tail. When no truncation notice is present, the output is complete.

## Reading files (sliding window)

Never dump a whole file into the transcript. Locate, read a bounded window, then slide:

- Locate first: `rg -n "pattern" path` gives exact line numbers.
- Read a bounded window: `sed -n 'START,ENDp' path`, or `rg -C 5 "pattern"` for context.
- Slide as needed: `sed -n 'END,NEW_ENDp' path` continues below; `sed -n 'NEW_START,STARTp' path` looks above.
- Full read only when necessary: `cat -n path` (line numbers keep later windows addressable). Use `head`/`tail` for boundary checks.

## Long-running commands

- For commands taking >10s or processes that run continuously (builds, dev servers, watchers), set `run_in_background: true`. The call returns immediately with a job id, pid, and log path.
- Background process completion is delivered automatically as a message; do not poll in a busy loop.
- Query status, read recent logs, or cancel running jobs using the `background` tool (`{"command":"status","id":<id>}`, `{"command":"tail","id":<id>}`, `{"command":"cancel","id":<id>}`).

## Error handling

- Non-zero exit codes are returned in the result. For multi-step commands, chain with `&&` or start scripts with `set -euo pipefail`.
- Use non-interactive flags (`-y`, `--no-input`, `< /dev/null`) so commands never hang waiting for input.
- Commands that may legitimately fail should end with `|| true` if later steps should still run.
