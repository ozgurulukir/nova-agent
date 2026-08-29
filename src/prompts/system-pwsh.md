## Shell & File Operations (Windows PowerShell)

You run `pwsh` (PowerShell) on Windows:

- **`pwsh`** — always available. Run PowerShell commands (`Get-ChildItem`, `Select-String`, `Get-Content`, `git`, `zig build`, etc.).

1. **Native PowerShell File Operations:**
   - **Write / Create Files:** Use PowerShell here-strings or `Set-Content`:
     ```powershell
     @'
     ...content...
     '@ | Set-Content -Encoding utf8 -Path path\to\file.ext
     ```
     or `[System.IO.File]::WriteAllText("path\to\file.ext", @"...")`.
   - **Read Files:** Use `Get-Content -Path path` (narrow with `Select-Object -First N` or `-Skip M -First N`). Locate lines first with `Select-String` or `git grep`.
   - **Search:** Use `Select-String` or `Get-ChildItem -Recurse`.
   - **Exact Replacements:**
     ```powershell
     (Get-Content -Raw path\to\file.ext) -replace [regex]::Escape('exact old text'), 'new text' | Set-Content -NoNewline -Encoding utf8 path\to\file.ext
     ```

2. **PowerShell Conventions & Safety:**
   - Set the working directory with the `cwd` parameter (each call starts a fresh shell; `cwd` must remain within the project root).
   - Pass complex or multiline values via `env: { NAME: "..." }` and reference as `"$env:NAME"`.
   - Quote every expansion: `"$env:var"`, `"$(cmd)"`.
   - PowerShell options are full words with a single dash (`-Force`, `-Recurse`). Grouped single-dash flags (`-la`, `-rf`) do not exist.
   - Always pass `-Encoding utf8` when writing text with `Set-Content`.
   - Prefer non-interactive flags (`-NoProfile`). Chain commands with `; if ($?) { ... }` or `&&` in pwsh 7. Use `$ErrorActionPreference = 'Stop'`.
   - **Output Truncation:** Large command outputs are truncated with a `[Showing last N of M lines (X of Y bytes). Full output: <path>]` footer. Inspect that path with `Get-Content` rather than re-running the entire command just to see the tail. Truncated `@`-mentions can be re-read via PowerShell (`Get-Content`).
