<div align="center">

# Nova

**The fast, keyboard-first, native terminal AI agent for shipping code.**

[![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d?style=flat-square&logo=zig&logoColor=white)](https://ziglang.org)
[![Version](https://img.shields.io/github/v/release/ozgurulukir/nova-agent?style=flat-square)](https://github.com/ozgurulukir/nova-agent/releases)
[![License](https://img.shields.io/github/license/ozgurulukir/nova-agent?style=flat-square)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/ozgurulukir/nova-agent?style=flat-square)](https://github.com/ozgurulukir/nova-agent/stargazers)

</div>

---

## ⚡ Nova in action

<p align="center">
  <a href="assets/demo.gif">
    <img src="assets/demo-teaser.gif" alt="Nova Agent Demo in Terminal" width="800" />
  </a>
  <br />
  <sub>⚡ <em>Preview snippet. <a href="assets/demo.gif">Click to watch the full demo (18 MB)</a></em></sub>
</p>

Nova is an **oldschool, terminal-native AI agent** designed for pure speed and focus. No Electron, no browser tab, no heavy Node runtime. Just a single, compiled Zig binary that interfaces directly with your shell, connects to OpenAI Codex (via ChatGPT OAuth) or any OpenAI-compatible provider, orchestrates parallel work across isolated git worktree lanes, and logs every turn to local SQLite.

> [!NOTE]
> **Fast, Stable, & Daily-Driven:** Nova is built for production workflows with native performance, zero-friction execution, and strict safety guardrails.

---

## 🏎️ Philosophy & Execution Model: Autonomous by Default ("YOLO Mode")

Unlike IDE plugins that interrupt you with modal dialogues for every file read or harmless directory scan, Nova operates under an **autonomous execution model** (similar to popular "YOLO" or "dangerously skip permissions" workflows):

- **No tedious click-prompts:** Reads, edits, builds, and standard commands run immediately without micro-confirmations.
- **Two-Tier Command Safety Net:**
  - **Tier 1 — Built-in Deterministic Safety Matcher (Active by default):** Zero-dependency, sub-microsecond pattern engine in Zig (`bash_safety.zig`). Automatically intercepts high-risk destructive commands (e.g. `rm -rf /`, drive root wipes, `mkfs`, `dd`, fork bombs) and gates them behind explicit approval prompts.
  - **Tier 2 — External AI Safety Classifier (Optional):** Plug in the standalone REST safety service (`tools/classifier/`) powered by Transformer models (ModernBERT) or an LLM safety proxy for deep contextual risk evaluation.
  - *Runtime Check:* You can inspect your active safety tier at any time by running `/status`.
- **Git Worktree Isolation:** When exploring risky changes or broad refactors, fork your workspace into isolated **Parallel Lanes** (`/parallel` or `lane spawn`). Workers are physically contained inside their worktree, keeping your main branch clean.
- **Plugin Sandboxing & Execution Layer:**
  Nova's Lua plugin environment is an **embedded execution layer** rather than a heavyweight OS container (such as Docker or chroot). Unsafe standard libraries (`io`, `os.execute`, `package.loadlib`) are stripped. All filesystem operations route through Zig bridge functions with strict workspace path confinement (`sanitizePath`), per-dispatch instruction budgets prevent runaway loops, and module loading (`nova.require`) is strictly confined to the plugin's own directory.

> [!CAUTION]
> **Security Notice:** Because Nova executes shell commands directly without granular per-action permission prompts, run it only in workspaces you trust, or confine experimental workflows to parallel git worktree lanes.

---

## ✨ Key Highlights

- **Native TUI with VXFW:** Instant startup, fluid scrolling, custom color themes, and zero web stack bloat.
- **Any LLM Provider:** Native OpenAI ChatGPT & Codex OAuth integration (sign in without an API key), plus first-class support for OpenRouter, Ollama, llama.cpp, Cerebras, DeepSeek, Google Gemini, Mistral, xAI Grok, and any custom OpenAI-compatible endpoint (Claude models supported via OpenRouter or compatible gateways).
- **Parallel Git Lanes:** Run multiple agent threads simultaneously in isolated git worktrees; monitor progress and merge results back when ready.
- **Background Jobs:** Launch long-running builds, test suites, or dev servers asynchronously (`run_in_background: true`). Inspect live logs (`tail`), check progress (`status`), or cancel processes (`cancel`) via the native `background` tool or the `Ctrl+O` dashboard.
- **Context Compaction:** Dynamic, token-calibrated retention budgets that automatically summarize long sessions below model watermark limits.
- **Extensible via Lua & MCP:** Add custom tools and hooks with sandboxed Lua plugins (workspace-confined execution layer with instruction limits) or standard Model Context Protocol (MCP) servers (stdio or Streamable HTTP).
- **Offline & Local-First:** Complete conversation trees persisted in SQLite; full timeline branching (`/timeline`), single-keystroke turn rewind (`/undo`), session resume, and Markdown export.

---

## 📋 Prerequisites & Tooling

### Core Requirements
| Tool | Purpose | Installation |
|:---|:---|:---|
| **[Zig 0.16.0](https://ziglang.org/download/)** | Native compilation and build toolchain | `scoop install zig` / `brew install zig` / [Release](https://ziglang.org/download/) |
| **[Git](https://git-scm.com/)** | Version control & parallel git worktree lanes | Pre-installed or package manager |
| **Shell** | Command execution & worker dispatch | **Windows:** PowerShell 7+ (`pwsh`)<br/>**Linux/macOS:** Bash (`/bin/bash`) |

### Optional Tooling for Plugins & ML
| Tool | Purpose | When Needed |
|:---|:---|:---|
| **[ripgrep (`rg`)](https://github.com/BurntSushi/ripgrep)** | High-speed regex code search | Used by `search-tools` plugin when `regex: true` (`scoop install ripgrep` / `brew install ripgrep` / `apt install ripgrep`). Substring search uses built-in walker with 0 dependencies. |
| **[uv](https://github.com/astral-sh/uv) & Python** | Neural safety classifier service | Only when running or serving the optional ModernBERT safety classifier. |

---

## 🚀 Quick Start

### 1. One-Line Install (Recommended)

**Linux / macOS:**
```bash
curl -fsSL https://raw.githubusercontent.com/ozgurulukir/nova-agent/main/install.sh | bash
```

**Windows (PowerShell):**
```powershell
irm https://raw.githubusercontent.com/ozgurulukir/nova-agent/main/install.ps1 | iex
```

---

### 2. Build and Run from Source (Zig 0.16)

```bash
git clone https://github.com/ozgurulukir/nova-agent.git
cd nova-agent

# Build and run directly
zig build run

# Or install to PATH
zig build install -Doptimize=ReleaseFast --prefix $HOME/.local
nova --version
```

---

## 🛡️ Command Safety & External Classifier (Optional)

Nova provides multi-tier safety guards for shell command execution (`bash` on Linux/macOS, `pwsh` on Windows):

1. **Built-in Deterministic Safety Matcher (Default):** Zero-dependency lexical token and pattern analysis built directly into the native Zig binary. Intercepts destructive commands (`rm -rf /`, drive root wipes, fork bombs, critical system redirects) with zero latency.
2. **AI-Powered Safety Classifier (Optional):** Plug in a standalone REST safety service powered by fine-tuned Transformer models (ModernBERT) or an LLM safety proxy:

```bash
# Run standalone safety classifier via uv (port 8765):
uv run -m tools.classifier.server --model modernbert --port 8765

# Configure in Nova (via env or ~/.config/nova/config.json):
export NOVA_BASH_CLASSIFIER_URL="http://127.0.0.1:8765/classify"
```

👉 **[Read the Full Command Safety & Classifier Guide](docs/wiki/SAFETY_CLASSIFIER.md)** for Docker deployment, custom model presets, and REST API specifications.

---

## ⌨️ Essential Keyboard Shortcuts & Commands

| Shortcut | Action |
|:---|:---|
| `/` | Open command palette (`/connect`, `/model`, `/parallel`, `/diff`, `/timeline`, `/undo`, `/help`) |
| `@file` | Attach file contents directly into the prompt |
| `$skill` | Invoke a specialized agent skill |
| `Ctrl+O` | Open Background Jobs & Log Viewer modal |
| `Shift+Tab` | Cycle between active parallel lane conversations |
| `Ctrl+L` | Toggle fullscreen / split lane view |
| `Ctrl+F` | Search within the current transcript |
| `Ctrl+↑ / Ctrl+↓` | Navigate prompt history |
| `Tab` | Expand / collapse active message blocks |
| `Esc` | Cancel current turn / dismiss modal |

---

## 📚 Documentation & Wiki Index

For in-depth guides, architecture specifications, and configuration references:

- 🏛️ **[System Architecture](docs/ARCHITECTURE.md):** TUI event pipeline, LLM client layers, safety architecture, and memory models.
- 🛡️ **[Safety & Classifier Guide](docs/wiki/SAFETY_CLASSIFIER.md):** Defense-in-depth safety, external classifier REST setup, and model presets.
- ⚙️ **[Configuration Reference](docs/CONFIG.md):** Providers, API keys, context compaction, reasoning effort, and custom theme schemas.
- 🧠 **[Engineering Patterns & Invariants](docs/PATTERNS.md):** Strict-mode tool calling, background slots, zero-copy pruning, and thread-safety invariants.
- 🔌 **[Model Context Protocol (MCP)](docs/MCP.md):** Connecting stdio and Streamable HTTP MCP servers.
- 🧩 **[Lua Plugin System](docs/plugins/):** Building custom tools, event hooks, and system prompt extenders.
- 🔒 **[Security Policy](SECURITY.md):** Vulnerability disclosure procedures and safety architecture.
- 🎯 **[Design Philosophy](docs/PHILOSOPHY.md):** Core principles guiding Nova's evolution.
- 🛠️ **[Agent & Contributor Guidelines](AGENTS.md):** TigerStyle rules, Zig 0.16 idioms, and testing instructions.
- 📦 **[Releasing & Distribution](docs/RELEASING.md):** Version tagging and release workflow.

---

## 💻 Platform Support

- **Linux / macOS:** Fully supported and tested daily.
- **Windows:** Compiles natively (`zig-out/bin/nova.exe`). Core features, TUI, and SQLite persistence are active; full cross-platform runtime parity is tracked in [#26](https://github.com/ozgurulukir/nova-agent/issues/26)–[#29](https://github.com/ozgurulukir/nova-agent/issues/29).

---

## ⚠️ Disclaimer & Safety Guidelines

> **IMPORTANT:** Nova Agent is an autonomous AI coding assistant capable of executing shell commands (`bash` / `pwsh`) and modifying files directly on your operating system.

### Recommended Safety Practices:
1. **Always Use Version Control (Git):** Run Nova inside Git-tracked repositories. This ensures all modifications can be reviewed via `git diff` and reverted via `git restore` if needed.
2. **Avoid Elevated Privileges:** Do not run Nova as `root` (Linux/macOS) or `Administrator` (Windows) unless strictly necessary.
3. **Isolate Risky Workflows with Parallel Lanes:** Use Nova's built-in `/parallel` (Git worktree lanes) to run experimental refactors in an isolated worktree without affecting your main working tree.
4. **Enable Safety Classifier for Sensitive Environments:** When working in critical environments, consider connecting the standalone safety classifier (`tools/classifier/`) to inspect and intercept commands before execution.
5. **No Warranty:** As stated in the [MIT License](LICENSE), Nova is provided "AS IS", without warranty of any kind. You are solely responsible for reviewing and verifying changes made to your machine and codebase.

---

## 📄 License

Nova is open source under the [MIT License](LICENSE). Third-party components and licenses are listed in [attribution.md](attribution.md).
