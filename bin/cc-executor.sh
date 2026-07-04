#!/bin/bash
# cc-executor.sh — Managed Claude Code execution with monitoring
#
# Runs ollama launch claude inside a tmux session with:
#   - Heartbeat monitoring (30s interval)
#   - Periodic output capture to log file (every 30s)
#   - Graceful timeout handling (exit 124 with partial output preserved)
#   - Structured JSON summary on completion
#   - Profile-based model routing (fast / exact)
#
# Usage:
#   cc-executor.sh <prompt> [max_turns] [timeout_secs] [model] [workdir] [profile] [reading_heavy]
#
#   <prompt>       — Required. The task prompt (single-line with escaped quotes)
#   max_turns      — Max agentic loops (default: 50)
#   timeout        — Max seconds before SIGTERM (default: 1800)
#   model          — Ollama model name (default: glm-5.2:cloud, overridden by profile)
#   workdir        — Working directory for Claude Code (default: current directory)
#   profile        — Named model profile: 'fast' or 'exact'. See CC_FAST_MODEL / CC_EXACT_MODEL env vars.
#                    Overrides 'model' arg when set. Omit for manual model selection.
#   reading_heavy  — 1 if task requires reading spec + 5+ source files first (default: 0)
#                    Applies 2x duration penalty for more accurate estimation.
#
# Environment variables:
#   CC_LOG_DIR      — Log directory (default: ~/.claude-code-exec/logs)
#   CC_FAST_MODEL   — Model for 'fast' profile (default: gemma4:cloud)
#   CC_EXACT_MODEL  — Model for 'exact' profile (default: glm-5.2:cloud)
#
# Output: JSON summary to stdout. Exit codes:
#   0   — completed successfully
#   1   — Claude Code hit max turns or error (partial work may exist on disk)
#   124 — timed out (SIGTERM, partial output captured in log)
#   2   — internal error (tmux missing, workdir invalid, unknown profile)
#   3   — BACKGROUND_NEEDED: estimated duration >600s. Re-issue with background=true.
#         Stderr contains: {"warning":"BACKGROUND_NEEDED","estimated_seconds":N,"max_turns":N}
#
# Monitor mid-flight with: cc-monitor.sh status <session_id>
#
# License: MIT — see https://github.com/vavush/claude-code-exec

set -euo pipefail

# ── Configuration ───────────────────────────────────────────────────
CC_LOG_DIR="${CC_LOG_DIR:-$HOME/.claude-code-exec/logs}"
CC_FAST_MODEL="${CC_FAST_MODEL:-gemma4:cloud}"
CC_EXACT_MODEL="${CC_EXACT_MODEL:-glm-5.2:cloud}"

# ── Inputs ──────────────────────────────────────────────────────────
PROMPT="${1:?Usage: $0 <prompt> [max_turns] [timeout_secs] [model] [workdir] [profile] [reading_heavy]}"
MAX_TURNS="${2:-50}"
TIMEOUT="${3:-1800}"
MODEL="${4:-glm-5.2:cloud}"
WORKDIR="${5:-$(pwd)}"
PROFILE="${6:-}"
READING_HEAVY="${7:-0}"

# ── Profile-based model routing (overrides MODEL when set) ──────────
if [ -n "$PROFILE" ]; then
  case "$PROFILE" in
    fast)  MODEL="$CC_FAST_MODEL" ;;
    exact) MODEL="$CC_EXACT_MODEL" ;;
    *)
      echo "{\"session_id\":\"\",\"exit_code\":2,\"status\":\"error\",\"error\":\"unknown profile: ${PROFILE}\",\"log_path\":\"\",\"duration_seconds\":0}"
      exit 2
      ;;
  esac
fi

# ── Pre-flight duration estimation ──────────────────────────────────
# Estimates whether the task will exceed the 600s foreground cap.
# If so, prints a structured warning to stderr and exits 3 so the
# caller can re-issue with background=true.
#
# Per-turn estimates (real-world data from glm-5.2:cloud via ollama launch):
#   fast  (gemma4:cloud): ~2.5s/turn
#   exact (glm-5.2:cloud): ~4.5s/turn
#
# Formula: estimated = max_turns × secs_per_turn × (1 + file_count_factor)
#   file_count_factor = 1.0 if reading_heavy, 0.5 otherwise
FOREGROUND_CAP=600
case "$MODEL" in
  gemma4:cloud|gemma4*)  SECS_PER_TURN=2.5 ;;
  *)                     SECS_PER_TURN=4.5 ;;
esac

if [ "$READING_HEAVY" = "1" ]; then
  FILE_FACTOR=1.0
else
  FILE_FACTOR=0.5
fi

ESTIMATED=$(echo "$MAX_TURNS * $SECS_PER_TURN * (1 + $FILE_FACTOR)" | bc -l | cut -d. -f1)

if [ "$ESTIMATED" -gt "$FOREGROUND_CAP" ] 2>/dev/null; then
  WARNING="{\"warning\":\"BACKGROUND_NEEDED\",\"estimated_seconds\":${ESTIMATED},\"max_turns\":${MAX_TURNS},\"model\":\"${MODEL}\",\"reading_heavy\":${READING_HEAVY}}"
  echo "$WARNING" >&2
  exit 3
fi

# ── Paths ───────────────────────────────────────────────────────────
SESSION_EPOCH=$(date +%s)
SESSION_ID="cc-${SESSION_EPOCH}"
LOG_DIR="${CC_LOG_DIR}/${SESSION_ID}"
HEARTBEAT_FILE="${LOG_DIR}/heartbeat"
OUTPUT_LOG="${LOG_DIR}/output.log"
EXIT_CODE_FILE="${LOG_DIR}/exit_code"
SUMMARY_FILE="${LOG_DIR}/summary.json"
TMUX_SESSION="cc-run-${SESSION_EPOCH}"

# ── Preflight checks ───────────────────────────────────────────────
if ! command -v tmux &>/dev/null; then
  echo '{"session_id":"","exit_code":2,"status":"error","error":"tmux not installed","log_path":"","duration_seconds":0}'
  exit 2
fi

if [ ! -d "$WORKDIR" ]; then
  echo "{\"session_id\":\"\",\"exit_code\":2,\"status\":\"error\",\"error\":\"workdir not found: ${WORKDIR}\",\"log_path\":\"\",\"duration_seconds\":0}"
  exit 2
fi

if ! command -v ollama &>/dev/null; then
  echo '{"session_id":"","exit_code":2,"status":"error","error":"ollama not found in PATH","log_path":"","duration_seconds":0}'
  exit 2
fi

mkdir -p "$LOG_DIR"

# Save execution metadata
cat > "${LOG_DIR}/execution.conf" << EOF
max_turns=${MAX_TURNS}
timeout=${TIMEOUT}
model=${MODEL}
workdir=${WORKDIR}
profile=${PROFILE:-manual}
EOF

# ── Heartbeat loop (background) ─────────────────────────────────────
(
  while true; do
    date -u +"%Y-%m-%dT%H:%M:%SZ" >> "$HEARTBEAT_FILE"
    sleep 30
  done
) &
HEARTBEAT_PID=$!

# ── Cleanup trap ────────────────────────────────────────────────────
cleanup() {
  kill "$HEARTBEAT_PID" 2>/dev/null || true
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
}
trap cleanup EXIT

# ── Launch tmux session ─────────────────────────────────────────────
tmux new-session -d -s "$TMUX_SESSION" -x 140 -y 40

# Escape the prompt for safe shell embedding inside tmux
ESCAPED_PROMPT=$(printf '%s' "$PROMPT" | sed "s/'/'\\\\''/g")

# Build the command. The trailing '; echo EXIT_CODE=$? > file' captures
# Claude Code's actual exit code so we can distinguish max_turns (1)
# from a crash (also 1) from success (0).
CMD="cd '${WORKDIR}' && ollama launch claude --model '${MODEL}' --yes -- -p '${ESCAPED_PROMPT}' --max-turns ${MAX_TURNS} --dangerously-skip-permissions; echo \\$? > '${EXIT_CODE_FILE}'"

tmux send-keys -t "$TMUX_SESSION" "$CMD" Enter

# ── Monitor loop ────────────────────────────────────────────────────
START_TIME=$(date +%s)
LAST_CAPTURE=0
CC_EXIT=""

while true; do
  NOW=$(date +%s)

  # Periodic output capture (every 30s) for mid-flight monitoring
  if [ $((NOW - LAST_CAPTURE)) -ge 30 ]; then
    tmux capture-pane -t "$TMUX_SESSION" -p -S -2000 > "$OUTPUT_LOG" 2>/dev/null || true
    LAST_CAPTURE=$NOW
  fi

  # Check if Claude Code finished (exit code file written)
  if [ -f "$EXIT_CODE_FILE" ]; then
    CC_EXIT=$(cat "$EXIT_CODE_FILE")
    # Final capture
    tmux capture-pane -t "$TMUX_SESSION" -p -S -2000 > "$OUTPUT_LOG" 2>/dev/null || true
    break
  fi

  # Check timeout
  ELAPSED=$((NOW - START_TIME))
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    # Final capture before killing
    tmux capture-pane -t "$TMUX_SESSION" -p -S -2000 > "$OUTPUT_LOG" 2>/dev/null || true
    CC_EXIT=124
    break
  fi

  sleep 5
done

# ── Determine status string ─────────────────────────────────────────
DURATION=$(( $(date +%s) - START_TIME ))

# Parse exit code (strip any whitespace/newlines)
CC_EXIT=$(echo "$CC_EXIT" | tr -d '[:space:]')

if [ "$CC_EXIT" = "124" ]; then
  STATUS="timeout"
elif [ "$CC_EXIT" = "0" ]; then
  STATUS="completed"
elif grep -qi "max turns" "$OUTPUT_LOG" 2>/dev/null; then
  STATUS="max_turns"
else
  STATUS="error"
fi

# ── Write summary JSON ──────────────────────────────────────────────
cat > "$SUMMARY_FILE" << EOF
{
  "session_id": "${SESSION_ID}",
  "exit_code": ${CC_EXIT},
  "status": "${STATUS}",
  "duration_seconds": ${DURATION},
  "log_path": "${LOG_DIR}",
  "model": "${MODEL}",
  "profile": "${PROFILE:-manual}",
  "max_turns": ${MAX_TURNS},
  "timeout_setting": ${TIMEOUT}
}
EOF

# Print summary to stdout for the calling tool to read
cat "$SUMMARY_FILE"

exit "$CC_EXIT"