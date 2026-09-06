<div align="center">

# Nova

**The fast, single-binary, native terminal AI agent for shipping code.**

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

Nova is a **terminal-native AI agent** designed for speed, focus, and low latency. No Electron, no browser tabs, no Node runtime. Just a single, compiled Zig binary that connects to OpenAI Codex (via ChatGPT OAuth) or any OpenAI-compatible provider, orchestrates parallel work across isolated git worktree lanes, and logs every turn to local SQLite.

---

## 🛡️ Execution & Safety Model

Nova operates without granular per-action permission prompts (YOLO mode), relying instead on layered safety guardrails:

- **Built-in Deterministic Safety Matcher (Default):** Zero-dependency lexical token analysis in Zig (`bash_safety.zig`) that automatically intercepts high-risk destructive commands (`rm -rf /`, drive wipes, `mkfs`, fork bombs) and gates them behind confirmation prompts.
- **Git Worktree Isolation:** Risky or wide refactors can be spawned into isolated **Parallel Lanes** (`/parallel` or `lane spawn`), physically contained in dedicated worktrees to keep your main branch clean.
- **Sandboxed Lua Plugins:** Embedded runtime with stripped unsafe libraries (`io`, `os.execute`), strict workspace path confinement, and instruction budgets.
- **Optional AI Safety Classifier:** Deep contextual command evaluation via a local ModernBERT service (`tools/classifier/`).

> [!CAUTION]
> Because Nova executes commands directly in your workspace without per-action confirmation prompts, run it in repositories you trust or confine broad changes to parallel git lanes.

---

## ✨ Key Highlights

- **Native TUI with VXFW:** Instant startup, fluid scrolling, custom color themes, and zero web stack overhead.
- **Any LLM Provider:** Native ChatGPT & Codex OAuth (login without API keys), plus OpenRouter, Ollama, DeepSeek, Gemini, Mistral, Cerebras, and custom OpenAI-compatible endpoints.
- **Parallel Git Lanes:** Run multiple agent threads concurrently in isolated git worktrees; inspect progress and merge back cleanly.
- **Background Jobs:** Asynchronous test runs, builds, or dev servers with real-time log tailing (`Ctrl+O`).
- **Context Compaction:** Dynamic, token-calibrated retention budgets that preserve critical history below model limits.
- **Extensible via Lua & MCP:** Custom tools and event hooks via sandboxed Lua plugins or Model Context Protocol (MCP) servers.
- **Offline & Local-First:** Full SQLite timeline persistence, branch switching (`/timeline`), and single-keystroke rewind (`/undo`).

---

## 📋 Prerequisites

| Component | Requirement | Purpose |
|:---|:---|:---|
| **[Zig](https://ziglang.org/download/)** | `0.16.0` | Native compilation and build toolchain |
| **[Git](https://git-scm.com/)** | 2.20+ | Version control & parallel worktree lanes |
| **Shell** | Bash / PowerShell 7+ | Command execution (`/bin/bash` on Linux/macOS, `pwsh` on Windows) |
| **[ripgrep](https://github.com/BurntSushi/ripgrep)** *(Optional)* | Any recent | High-speed regex code search for plugins (substring search is built-in) |
| **[uv](https://github.com/astral-sh/uv)** *(Optional)* | Python 3.10+ | Needed only when running the optional ModernBERT safety classifier |

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

### 2. Build from Source

```bash
git clone https://github.com/ozgurulukir/nova-agent.git
cd nova-agent
zig build install -Doptimize=ReleaseFast --prefix $HOME/.local
nova --version
```

---

## 🛡️ Optional Safety Classifier Setup

To enable Tier 2 contextual risk analysis with the ModernBERT classifier:

```bash
# Run standalone safety classifier service (port 8765):
uv run -m tools.classifier.server --model modernbert --port 8765

# Configure in Nova (via ~/.config/nova/config.json or env):
export NOVA_BASH_CLASSIFIER_URL="http://127.0.0.1:8765/classify"
```

See the **[Safety & Classifier Guide](docs/wiki/SAFETY_CLASSIFIER.md)** for Docker deployment and API details.

---

## ⌨️ Essential Shortcuts

| Shortcut | Action |
|:---|:---|
| `/` | Command palette (`/connect`, `/model`, `/parallel`, `/diff`, `/timeline`, `/undo`, `/help`) |
| `@file` | Attach file contents directly into prompt |
| `$skill` | Invoke a specialized agent skill |
| `Ctrl+O` | Background Jobs & Log Viewer |
| `Shift+Tab` | Cycle between active parallel lanes |
| `Ctrl+L` | Toggle fullscreen / split lane view |
| `Ctrl+F` | Search transcript |
| `Ctrl+↑ / Ctrl+↓` | Navigate prompt history |
| `Esc` | Cancel turn / dismiss modal |

---

## 📚 Documentation

- 🏛️ **[System Architecture](docs/ARCHITECTURE.md):** Event pipeline, client layers, and memory model.
- 🛡️ **[Safety & Classifier Guide](docs/wiki/SAFETY_CLASSIFIER.md):** Multi-tier safety architecture and model presets.
- ⚙️ **[Configuration Reference](docs/CONFIG.md):** Providers, API keys, compaction, and themes.
- 🧠 **[Engineering Patterns](docs/PATTERNS.md):** Invariants, background slots, and thread safety.
- 🔌 **[MCP Guide](docs/MCP.md):** stdio and Streamable HTTP MCP integration.
- 🧩 **[Lua Plugins](docs/plugins/):** Building tools and hooks.
- 🛠️ **[Contributor Guidelines](AGENTS.md):** TigerStyle rules, Zig 0.16 idioms, and testing.

---

## 💻 Platform Support

- **Linux / macOS:** Fully supported and tested daily.
- **Windows:** Compiles natively (`zig-out/bin/nova.exe`). Core features, TUI, and SQLite persistence are active; cross-platform runtime parity is tracked in [#26](https://github.com/ozgurulukir/nova-agent/issues/26)–[#29](https://github.com/ozgurulukir/nova-agent/issues/29).

---

## ⚠️ Disclaimer

Nova executes shell commands and modifies files directly in your environment. Always run Nova within Git-tracked repositories so changes can be inspected (`git diff`) and reverted (`git restore`). Distributed under the [MIT License](LICENSE) "AS IS", without warranty of any kind.

---

## 📄 License

Nova is open source under the [MIT License](LICENSE). Third-party components and licenses are listed in [attribution.md](attribution.md).
