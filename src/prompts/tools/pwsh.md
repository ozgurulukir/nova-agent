Run a PowerShell command on Windows.

- Set the working directory with the `cwd` parameter (fresh shell per call). `cwd` must be within the project root.
- Pass multiline or complex values via `env: { NAME: "..." }`. Reference them as `"$env:NAME"`.
- Provide a `description` for every command explaining what it does.
- Quote every expansion: `"$env:var"`, `"$(cmd)"`. Bare `$env:var` splits on spaces and special characters.
- Default timeout is 30 seconds. Raise with `timeout` when a command needs longer; a timed-out result explains how to retry.
- Prefer targeted commands (`rg`, `Select-String`, `git diff --stat`, `Get-Content`) over dumping large files or full build logs.
- Command outputs exceeding 50 KB or 2000 lines are truncated with a `[Showing last N of M lines (X of Y bytes). Full output: /path]` footer. Inspect that path with `Get-Content` or use a narrower command; never re-run the entire command just to see the tail. When no truncation notice is present, the output is complete.

## Reading files (sliding window)

Never dump a whole file into the transcript. Locate, read a bounded window, then slide:

- Locate first: `Select-String -Path path -Pattern "pattern"` gives exact line numbers.
- Read a bounded window: `Get-Content path | Select-Object -First 80` for the head, `Get-Content path | Select-Object -Last 80` for the tail.
- Slide as needed: `Get-Content path | Select-Object -Skip 80 -First 80` continues below; use `-Skip` to look above.
- Full read only when necessary: `Get-Content path`. Use `Select-Object -First`/`-Last` for boundary checks.

## Long-running commands

- For commands taking >10s or processes that run continuously (builds, dev servers, watchers), set `run_in_background: true`. The call returns immediately with a job id, pid, and log path.
- Background process completion is delivered automatically as a message; do not poll in a busy loop.
- Query status, read recent logs, or cancel running jobs using the `background` tool (`{"command":"status","id":<id>}`, `{"command":"tail","id":<id>}`, `{"command":"cancel","id":<id>}`).

## PowerShell idioms & error handling

- Non-zero exit codes are returned in the result. For multi-step commands, chain with `; if ($?) { ... }` or `&&` in pwsh 7.
- Start multi-statement scripts with `$ErrorActionPreference = 'Stop'` so cmdlet failures halt execution immediately.
- Use full-word flags (`-Force`, `-Recurse`). Grouped single-dash flags (`-la`, `-rf`) do not exist.
- Always pass `-Encoding utf8` when writing text with `Set-Content`.
- Use non-interactive flags (`-NoProfile`, redirecting `Read-Host`) so commands never hang waiting for input.