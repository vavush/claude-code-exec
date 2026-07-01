# cc-phaser — Managed Execution & Phase Orchestration for Claude Code

**cc-phaser** solves the reliability gap in Claude Code's print mode: long-running builds time out silently, max turns are hit with partial output, and there's no way to recover or monitor progress.

It provides three tools that wrap `ollama launch claude -p` with timeout safety, progress visibility, and phased orchestration:

- **`cc-executor.sh`** — Managed single-shot executor with heartbeat monitoring, periodic output capture, graceful timeout handling, and JSON-summary output.
- **`cc-orchestrate.sh`** — Phase-chunked task orchestrator. Breaks a spec into sequential phases, runs each as its own executor invocation, runs verify commands, and stops on first failure while preserving completed phases' work.
- **`cc-monitor.sh`** — Session inspector and controller. Check status, read output logs, list active sessions, or kill stuck ones.

All scripts produce structured JSON output consumable by shell pipelines, CI systems, or agent frameworks.

---

## Problem

Claude Code's `-p` (print mode) runs a task and exits. It has two failure modes that lose your work:

1. **Timeout (exit 124):** Shell `terminal()` typically caps foreground execution at 600s. If your task needs more time, the entire run is killed — zero output preserved.
2. **Max turns (exit 1):** Claude Code stops at `--max-turns` but files may exist on disk. You can't tell what happened without checking every file.

For complex builds spanning 8+ files and 50+ turns, these failure modes make every run a binary gamble.

## Solution

**cc-executor.sh** wraps Claude Code in a tmux session with:
- A background heartbeat that proves the process is alive
- Output snapshots captured every 30s (not just at exit)
- Separate handling of timeout (124), max turns (1), and success (0)
- A JSON summary with session_id, exit_code, status, duration, and log path

**cc-orchestrate.sh** extends this further by splitting complex builds into phases:
- Each phase is small enough (15-25 turns) to finish comfortably
- Per-phase verify commands catch failures early
- If phase 3 fails, phases 1-2 are preserved on disk
- Structured output shows exactly what passed and what failed

---

## Prerequisites

- **tmux** — session management (most systems have it pre-installed)
- **ollama** — for running Claude Code via `ollama launch claude`
- **Claude Code** — `npm install -g @anthropic-ai/claude-code`
- **Python 3** — for JSON processing in orchestrate.sh (stdlib only)

---

## Install

```bash
# Clone the repo
git clone https://github.com/<your-username>/cc-phaser.git
cd cc-phaser

# Install to /usr/local/bin (or set PREFIX)
sudo make install

# Or add bin/ to your PATH manually
export PATH="$PATH:/path/to/cc-phaser/bin"
```

---

## Quick Start — Single Task

```bash
# Basic usage: prompt, max_turns, timeout, model, workdir, profile
cc-executor.sh \
  "Add error handling to all API calls in src/" \
  50 600 glm-5.2:cloud \
  /path/to/your/project \
  exact

# Using profile-based model routing (fast → cheap model, exact → flagship):
cc-executor.sh \
  "Add error handling to all API calls in src/" \
  50 600 "" /path/to/your/project \
  exact

# The executor prints a JSON summary on stdout:
# {"session_id":"cc-1719360000","exit_code":0,"status":"completed","duration_seconds":312,...}
```

## Quick Start — Multi-Phase Build

Write a spec file:

```markdown
# Build Spec: My Feature

## Phase 1: Data Models
model: fast
max_turns: 15
timeout: 200
verify: python3 -c "from myapp.models import User; print('OK')"
---
Create the User and Profile Pydantic models with fields: id, name, email, avatar_url, created_at. Export both from models module.

## Phase 2: Service Layer
model: exact
max_turns: 25
timeout: 400
verify: python3 -c "from myapp.services import UserService; print('OK')"
---
Implement UserService class with CRUD operations, email validation, password hashing. Use async methods throughout.
```

Run it:

```bash
cc-orchestrate.sh /path/to/SPEC.md /path/to/your/project
```

The orchestrator runs Phase 1 (gemma4:cloud, 15 turns, verifies), then Phase 2 (glm-5.2:cloud, 25 turns, verifies). If either phase fails or its verify command fails, it stops and reports. Completed work is preserved on disk.

---

## Scripts Reference

### cc-executor.sh

```
Usage: cc-executor.sh <prompt> [max_turns] [timeout_secs] [model] [workdir] [profile]

Args:
  prompt       Required. The task prompt (single-line, escaped quotes)
  max_turns    Max agentic loops (default: 50)
  timeout      Max seconds before SIGTERM (default: 600)
  model        Ollama model name (default: glm-5.2:cloud, overridden by profile)
  workdir      Working directory (default: current directory)
  profile      Model profile: 'fast' or 'exact'. Overrides model arg.

Profiles:
  fast         → Uses $CC_FAST_MODEL (default: gemma4:cloud) — cheaper, faster
  exact        → Uses $CC_EXACT_MODEL (default: glm-5.2:cloud) — flagship model

Environment:
  CC_LOG_DIR      Log directory (default: ~/.cc-phaser/logs)
  CC_FAST_MODEL   Model for 'fast' profile (default: gemma4:cloud)
  CC_EXACT_MODEL  Model for 'exact' profile (default: glm-5.2:cloud)

Exit codes:
  0   Completed successfully
  1   Hit max turns or error (partial work may exist on disk)
  124 Timed out (SIGTERM, partial output captured in log)
  2   Internal error (tmux missing, workdir invalid, unknown profile)
```

### cc-monitor.sh

```
Usage: cc-monitor.sh <command> [args]

Commands:
  status <session_id>    — Check if session is alive, read heartbeat, report
  log    <session_id> [N] — Read last N lines from output log (default: 50)
  kill   <session_id>    — Capture remaining output, kill tmux, write summary
  list                   — List all active cc-run-* tmux sessions

Session ID: Use the session_id from executor's JSON output (e.g., cc-1719360000)
```

### cc-orchestrate.sh

```
Usage: cc-orchestrate.sh <spec_file> [workdir]

  spec_file   Required. Path to the phase spec (## Phase N: headings)
  workdir     Working directory (default: current directory)

Exit codes:
  0 — all phases completed successfully
  1 — one or more phases failed
```

---

## Spec Format Reference

A spec file uses Markdown with `## Phase N:` headings. Each phase has:

```
## Phase N: Title
model: fast|exact          # Model profile (default: exact)
max_turns: N               # Max turns (default: 25)
timeout: N                 # Max seconds (default: 300)
verify: shell_command      # Optional verify command (runs in workdir)
skip: true|false           # Skip this phase (default: false)
---
Instruction block for Claude Code. This is passed verbatim as the prompt.
```

The instruction block (after `---`) is passed as the Claude Code prompt. Each phase runs in isolation — subsequent phases that depend on prior output must reference file paths explicitly in their instructions.

---

## Log Structure

Each session creates a directory under `$CC_LOG_DIR` (default: `~/.cc-phaser/logs/`):

```
~/.cc-phaser/logs/
  cc-1719360000/          # Single executor session
    heartbeat             # Timestamps (every 30s) proving process was alive
    output.log            # Periodic tmux pane captures
    exit_code             # Raw exit code from Claude Code
    summary.json          # Structured JSON summary
    execution.conf        # Input parameters for this run

  orchestrate-1719360000/ # Orchestrator session
    phase-summary.json    # Per-phase results and overall status
```

Status values in summary.json:

| Status | Meaning |
|--------|---------|
| `completed` | Claude Code exited 0 |
| `max_turns` | Exited 1, output log contains "max turns" |
| `timeout` | Killed by timeout (exit 124) |
| `error` | Exited 1 without matching max_turns |
| `verify_failed` | Phase ran OK but verify command failed |
| `killed` | Terminated by cc-monitor.sh kill |

---

## Timeout Calculator

For `glm-5.2:cloud` (exact profile) and similar-sized models:

| Task Type | Turns | Timeout | Profile |
|-----------|-------|---------|---------|
| Single-file read + one change | 10 | 120s | fast |
| Multi-file investigation (3-5 files) | 40 | 300s | exact |
| Multi-file build (8+ files, 2000+ lines) | 50 | 400s | exact |
| Complex refactor with verification | 60 | 500s | exact |
| Boilerplate / scaffolding | 15 | 150s | fast |

**Reading-heavy penalty:** If the prompt instructs Claude Code to read a large spec document (100+ lines) AND 5+ source files before writing, double the estimated timeout. Formula: `timeout = max_turns × 5 × (1 + 1.0 × file_count_factor)`.

**Foreground cap:** If total timeout exceeds 600s, wrap `cc-orchestrate.sh` in a background shell process or reduce phase size.

---

## Tips & Pitfalls

**Each phase is a clean environment.** Claude Code starts fresh each phase. If Phase 2 depends on files from Phase 1, say so in Phase 2's instructions: "The file `models.py` was created in Phase 1. Read it before modifying."

**Keep instructions self-contained.** Don't assume Claude Code has context from previous phases. Include file paths, existing code structure, and constraints in every phase's instruction block.

**Verify commands run in the workdir.** Simple Python import checks are best: `python3 -c "from mymodule import MyClass"`. If you need a virtualenv, activate it in the verify command.

**Monitor mid-flight.** While cc-executor.sh runs, open another terminal and use `cc-monitor.sh status cc-1719360000` or `cc-monitor.sh log cc-1719360000 30` to check progress.

**Setting up your Ollama provider.** The first time you run `ollama launch claude`, you may need to authenticate or configure the provider. Run `ollama launch claude -- --version` once to verify the setup before using these scripts.

---

## Integration with Agent Frameworks

cc-phaser is agent-framework agnostic. It works with:

- **Hermes Agent** — the original environment where these scripts were developed. Set `CC_LOG_DIR` to `~/.hermes/logs/claude-code/` for Hermes compatibility.
- **Any bash/Tmux host** — standalone with no agent framework required.
- **CI pipelines** — the JSON summary on stdout can be parsed by GitHub Actions, GitLab CI, or any job runner.

---

## License

MIT