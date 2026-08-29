## Shell & File Operations (POSIX bash)

You run `bash` on POSIX systems:

- **`bash`** — always available. Run shell commands (`ls`, `rg`, `git`, `sed`, build commands, etc.).

1. **Native Shell File Operations:**
   - **Write / Create Files:** Use quoted heredocs to write files safely:
     ```bash
     cat <<'EOF' > path/to/file.ext
     ...content...
     EOF
     ```
   - **Read Files:** Use `cat`, `head`, `tail`, or sliding-window `sed -n 'START,ENDp' path` for bounded line ranges. Locate lines first with `rg -n "pattern" path`.
   - **Search:** Use `rg` or `grep -rn` for content search; `find` or `ls` for path search.

2. **Shell Conventions & Safety:**
   - Set the working directory with the `cwd` parameter (each call starts a fresh shell; `cwd` must remain within the project root).
   - Pass complex or multiline values via `env: { NAME: "..." }` and reference as `"$NAME"`.
   - Quote every expansion: `"$var"`, `"$(cmd)"`, `"${arr[@]}"`.
   - Prefer non-interactive flags (`-y`, `--no-input`, `< /dev/null`). Chain commands with `&&` or start scripts with `set -euo pipefail`.
   - **Output Truncation:** Large command outputs are truncated with a `[Showing last N of M lines (X of Y bytes). Full output: <path>]` footer. Inspect that path or use targeted commands rather than re-running the entire command just to see the tail. Truncated `@`-mentions can be re-read via shell commands (`sed -n`, `cat`).
