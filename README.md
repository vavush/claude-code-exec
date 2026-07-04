# claude-code-exec — Managed Execution & Phase Orchestration for Claude Code

**claude-code-exec** solves the reliability gap in Claude Code's print mode: long-running builds time out silently, max turns are hit with partial output, and there's no way to recover or monitor progress.

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
git clone https://github.com/vavush/claude-code-exec.git
cd claude-code-exec

# Install to /usr/local/bin (or set PREFIX)
sudo make install

# Or add bin/ to your PATH manually
export PATH="$PATH:/path/to/claude-code-exec/bin"
```

---

## Quick Start — Single Task

```bash
# Basic usage: prompt, max_turns, timeout, model, workdir, profile, reading_heavy
cc-executor.sh \
  "Add error handling to all API calls in src/" \
  50 600 glm-5.2:cloud \
  /path/to/your/project \
  exact 0

# Using profile-based model routing (fast → cheap model, exact → flagship):
cc-executor.sh \
  "Add error handling to all API calls in src/" \
  50 600 "" /path/to/your/project \
  exact 0

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
Usage: cc-executor.sh <prompt> [max_turns] [timeout_secs] [model] [workdir] [profile] [reading_heavy]

Args:
  prompt         Required. The task prompt (single-line, escaped quotes)
  max_turns      Max agentic loops (default: 50)
  timeout        Max seconds before SIGTERM (default: 1800)
  model          Ollama model name (default: glm-5.2:cloud, overridden by profile)
  workdir        Working directory (default: current directory)
  profile        Model profile: 'fast' or 'exact'. Overrides model arg.
  reading_heavy  1 if task reads a spec + 5+ source files first (default: 0)

Profiles:
  fast         → Uses $CC_FAST_MODEL (default: gemma4:cloud) — cheaper, faster
  exact        → Uses $CC_EXACT_MODEL (default: glm-5.2:cloud) — flagship model

Environment:
  CC_LOG_DIR      Log directory (default: ~/.claude-code-exec/logs)
  CC_FAST_MODEL   Model for 'fast' profile (default: gemma4:cloud)
  CC_EXACT_MODEL  Model for 'exact' profile (default: glm-5.2:cloud)

Exit codes:
  0   Completed successfully
  1   Hit max turns or error (partial work may exist on disk)
  124 Timed out (SIGTERM, partial output captured in log)
  2   Internal error (tmux missing, workdir invalid, unknown profile)
  3   BACKGROUND_NEEDED — estimated duration >600s. Re-issue with background=true.
      Stderr contains: {"warning":"BACKGROUND_NEEDED","estimated_seconds":N,...}
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
timeout: N                 # Max seconds (default: 600)
verify: shell_command      # Optional verify command (runs in workdir)
skip: true|false           # Skip this phase (default: false)
---
Instruction block for Claude Code. This is passed verbatim as the prompt.
```

The instruction block (after `---`) is passed as the Claude Code prompt. Each phase runs in isolation — subsequent phases that depend on prior output must reference file paths explicitly in their instructions.

---

## Log Structure

Each session creates a directory under `$CC_LOG_DIR` (default: `~/.claude-code-exec/logs/`):

```
~/.claude-code-exec/logs/
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

| Task Type | Turns | Timeout | Mode | Profile |
|-----------|-------|---------|------|---------|
| Single-file read + one change | 10 | 120s | foreground | fast |
| Multi-file investigation (3-5 files) | 40 | 300s | foreground | exact |
| Multi-file build (8+ files, 2000+ lines) | 50 | 400s | foreground | exact |
| Complex refactor with verification | 60 | 500s | foreground | exact |
| Boilerplate / scaffolding | 15 | 150s | foreground | fast |
| **Large / reading-heavy build** | **80** | **1800s** | **background** | **exact** |

**Reading-heavy penalty:** If the prompt instructs Claude Code to read a large spec document (100+ lines) AND 5+ source files before writing, double the estimated timeout. Formula: `timeout = max_turns × 5 × (1 + 1.0 × file_count_factor)`.

**Foreground cap:** If total timeout exceeds 600s, use background mode or reduce phase size.

---

## Pre-Flight Duration Estimation

The executor has a built-in estimator that runs before launching Claude Code. It calculates:

```
estimated = max_turns × secs_per_turn × (1 + file_count_factor)
```

- `secs_per_turn`: 2.5s for `gemma4:cloud`, 4.5s for all other models
- `file_count_factor`: 1.0 if `reading_heavy=1`, 0.5 otherwise

If the estimate exceeds 600s, the executor **exits immediately with code 3** and prints a JSON warning to stderr:

```json
{"warning":"BACKGROUND_NEEDED","estimated_seconds":720,"max_turns":80,"model":"glm-5.2:cloud","reading_heavy":1}
```

The calling framework should catch exit code 3 and re-issue the same command with `background=true` + `notify_on_complete=true`. See the integration sections below for framework-specific handling.

---

## Tips & Pitfalls

**Each phase is a clean environment.** Claude Code starts fresh each phase. If Phase 2 depends on files from Phase 1, say so in Phase 2's instructions: "The file `models.py` was created in Phase 1. Read it before modifying."

**Keep instructions self-contained.** Don't assume Claude Code has context from previous phases. Include file paths, existing code structure, and constraints in every phase's instruction block.

**Verify commands run in the workdir.** Simple Python import checks are best: `python3 -c "from mymodule import MyClass"`. If you need a virtualenv, activate it in the verify command.

**Monitor mid-flight.** While cc-executor.sh runs, open another terminal and use `cc-monitor.sh status cc-1719360000` or `cc-monitor.sh log cc-1719360000 30` to check progress.

**Setting up your Ollama provider.** The first time you run `ollama launch claude`, you may need to authenticate or configure the provider. Run `ollama launch claude -- --version` once to verify the setup before using these scripts.

---

## Integration with Agent Frameworks

claude-code-exec is agent-framework agnostic. The scripts communicate via a simple contract:

| Channel | Format | When |
|---------|--------|------|
| **stdout** | JSON summary (single line) | On completion |
| **stderr** | JSON warning (single line) | On pre-flight failure (exit 3) |
| **exit code** | Integer | On exit |
| **log directory** | Filesystem | During execution |

Any framework that can run a shell command, read stdout/stderr, and check exit codes can integrate these scripts.

### Hermes Agent

Hermes Agent is the original environment where these scripts were developed. Integration is done via the `claude-code-integration` skill.

**Setup:**

```bash
# Set log dir for Hermes compatibility
export CC_LOG_DIR="$HOME/.hermes/logs/claude-code"
```

**Calling from Hermes (foreground — tasks under 600s):**

```python
# Hermes terminal() call
result = terminal(
    command="bash cc-executor.sh \
        \"Add error handling to all API calls in src/\" \
        50 600 glm-5.2:cloud \
        /path/to/project \
        exact 0",
    timeout=600
)
# Parse result.stdout as JSON summary
```

**Auto-background detection (tasks over 600s):**

The executor exits code 3 when its pre-flight estimate exceeds 600s. Hermes should catch this and re-issue in background mode:

```python
result = terminal(
    command="bash cc-executor.sh \
        \"Large refactor across 12 files\" \
        80 1800 glm-5.2:cloud \
        /path/to/project \
        exact 1",
    timeout=600
)

if result.exit_code == 3:
    # Parse stderr for the BACKGROUND_NEEDED warning
    # Re-issue in background mode
    terminal(
        command="bash cc-executor.sh \
            \"Large refactor across 12 files\" \
            80 1800 glm-5.2:cloud \
            /path/to/project \
            exact 1",
        background=True,
        notify_on_complete=True
    )
```

**Using the orchestrator from Hermes:**

```python
terminal(
    command="bash cc-orchestrate.sh \
        /path/to/SPEC.md \
        /path/to/project",
    timeout=500  # Outer safety net; each phase has its own timeout
)
```

**Hermes skill reference:** The `claude-code-integration` skill (v5.0.0+) documents the full workflow: pre-flight checklist, timeout calculator, model profile routing (fast/exact), phased orchestration, and post-run verification. Install it via:

```bash
hermes skill install claude-code-integration
```

### OpenClaw / Generic Agent Frameworks

Any agent framework that can run shell commands and parse JSON can integrate claude-code-exec. The contract is:

**1. Parse the JSON summary from stdout:**

```python
import json, subprocess

result = subprocess.run([
    "cc-executor.sh",
    "Add error handling to all API calls in src/",
    "50", "600", "glm-5.2:cloud",
    "/path/to/project",
    "exact", "0"
], capture_output=True, text=True, timeout=610)

# Parse the last JSON line from stdout
for line in reversed(result.stdout.strip().split("\n")):
    if line.startswith("{"):
        summary = json.loads(line)
        break

print(f"Session: {summary['session_id']}")
print(f"Status: {summary['status']}")
print(f"Duration: {summary['duration_seconds']}s")
print(f"Log path: {summary['log_path']}")
```

**2. Handle exit code 3 (background needed):**

```python
if result.returncode == 3:
    # Parse the warning from stderr
    warning = json.loads(result.stderr.strip())
    print(f"Task too long for foreground ({warning['estimated_seconds']}s estimated)")
    print("Re-issue with background execution")
    # In a real agent, spawn a background process here
```

**3. Monitor mid-flight:**

```python
# In a separate thread/process:
status_result = subprocess.run(
    ["cc-monitor.sh", "status", summary["session_id"]],
    capture_output=True, text=True
)
print(status_result.stdout)
```

**4. Orchestrate multi-phase builds:**

```python
result = subprocess.run([
    "cc-orchestrate.sh",
    "/path/to/SPEC.md",
    "/path/to/project"
], capture_output=True, text=True)

# Parse the final JSON summary
for line in reversed(result.stdout.strip().split("\n")):
    if line.startswith("{"):
        summary = json.loads(line)
        break

if summary["all_passed"]:
    print(f"All {summary['phases_total']} phases passed")
else:
    for phase in summary["phases"]:
        if phase["status"] != "completed":
            print(f"Failed: {phase['name']} ({phase['status']})")
```

**5. Environment variables for configuration:**

```python
import os
os.environ["CC_LOG_DIR"] = "/var/log/claude-code"
os.environ["CC_FAST_MODEL"] = "gemma4:cloud"
os.environ["CC_EXACT_MODEL"] = "glm-5.2:cloud"
```

### CI Systems (GitHub Actions, GitLab CI)

The JSON summary on stdout is designed for CI pipeline consumption.

**GitHub Actions example:**

```yaml
- name: Run Claude Code build
  id: claude
  run: |
    cc-executor.sh \
      "Build the authentication module" \
      50 600 glm-5.2:cloud \
      ${{ github.workspace }} \
      exact 0 > /tmp/cc-output.json 2>&1
    echo "exit_code=$?" >> $GITHUB_OUTPUT

- name: Check result
  run: |
    SUMMARY=$(tail -1 /tmp/cc-output.json)
    STATUS=$(echo "$SUMMARY" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])")
    if [ "$STATUS" != "completed" ]; then
      echo "Build failed: $STATUS"
      exit 1
    fi
```

**GitLab CI example:**

```yaml
claude-code-build:
  script:
    - cc-executor.sh "Build the auth module" 50 600 glm-5.2:cloud . exact 0 > cc-output.json
    - python3 -c "
import json
with open('cc-output.json') as f:
    for line in reversed(f.read().splitlines()):
        if line.startswith('{'):
            s = json.loads(line)
            assert s['status'] == 'completed', f'Failed: {s[\"status\"]}'
            break
      "
  artifacts:
    paths:
      - cc-output.json
```

---

## License

MIT
