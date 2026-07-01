#!/bin/bash
# cc-monitor.sh — Monitor Claude Code execution sessions
#
# Commands:
#   status <session_id>  — Check if session is alive, read heartbeat, report
#   log    <session_id> [lines] — Read last N lines from output log (default: 50)
#   kill   <session_id>  — Capture remaining output, kill tmux, write final summary
#   list                 — List all active cc-* tmux sessions
#
# Session IDs are of the form: cc-<epoch> (new format)
# Legacy: claude-code-<epoch> (converted automatically)
#
# Environment:
#   CC_LOG_DIR  — Log directory (default: ~/.claude-code-exec/logs)
#
# License: MIT — see https://github.com/vavush/claude-code-exec

set -euo pipefail

CC_LOG_DIR="${CC_LOG_DIR:-$HOME/.claude-code-exec/logs}"
CMD="${1:-help}"

# ── Help ────────────────────────────────────────────────────────────
if [ "$CMD" = "help" ] || [ "$CMD" = "--help" ] || [ "$CMD" = "-h" ]; then
  echo "Usage: cc-monitor.sh <command> [args]"
  echo ""
  echo "Commands:"
  echo "  status <session_id>  — Check if session is alive, read heartbeat, report"
  echo "  log    <session_id> [lines] — Read last N lines from output log (default: 50)"
  echo "  kill   <session_id>  — Capture remaining output, kill tmux, write final summary"
  echo "  list                 — List all active cc-run-* tmux sessions"
  echo ""
  echo "Session ID examples: cc-1719360000  or  claude-code-1719360000"
  echo ""
  echo "Environment:"
  echo "  CC_LOG_DIR  — Log directory (default: ~/.claude-code-exec/logs)"
  exit 0
fi

# ── List ────────────────────────────────────────────────────────────
if [ "$CMD" = "list" ]; then
  echo "Active Claude Code tmux sessions:"
  tmux list-sessions 2>/dev/null | grep "cc-run-" || echo "  (none)"
  echo ""
  echo "Recent log directories:"
  ls -1t "$CC_LOG_DIR" 2>/dev/null | head -10 || echo "  (none)"
  exit 0
fi

# ── Remaining commands need a session ID ────────────────────────────
SESSION_ID="${2:-}"
if [ -z "$SESSION_ID" ]; then
  echo "Error: session_id required for '$CMD' command"
  echo "Usage: cc-monitor.sh $CMD <session_id> [args]"
  exit 1
fi

# Normalize session ID to TMUX session name and log directory
if [[ "$SESSION_ID" == claude-code-* ]]; then
  # Legacy format (pre-v2)
  TMUX_SESSION="cc-run-${SESSION_ID#claude-code-}"
  LOG_DIR="${CC_LOG_DIR}/cc-${SESSION_ID#claude-code-}"
elif [[ "$SESSION_ID" == cc-* ]]; then
  TMUX_SESSION="cc-run-${SESSION_ID#cc-}"
  LOG_DIR="${CC_LOG_DIR}/${SESSION_ID}"
elif [[ "$SESSION_ID" == orchestrate-* ]]; then
  TMUX_SESSION=""
  LOG_DIR="${CC_LOG_DIR}/${SESSION_ID}"
else
  # Bare epoch
  TMUX_SESSION="cc-run-${SESSION_ID}"
  LOG_DIR="${CC_LOG_DIR}/cc-${SESSION_ID}"
fi

# ── Status ──────────────────────────────────────────────────────────
if [ "$CMD" = "status" ]; then
  TMUX_ALIVE=false
  if [ -n "$TMUX_SESSION" ] && tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    TMUX_ALIVE=true
  fi

  HEARTBEAT_FILE="${LOG_DIR}/heartbeat"
  HEARTBEAT_AGE=""
  HB_AGE_SECS=""
  if [ -f "$HEARTBEAT_FILE" ]; then
    LAST_HB=$(tail -1 "$HEARTBEAT_FILE" 2>/dev/null || echo "unknown")
    NOW_EPOCH=$(date +%s)
    HB_EPOCH=$(date -d "$LAST_HB" +%s 2>/dev/null || echo "0")
    if [ "$HB_EPOCH" != "0" ]; then
      AGE=$((NOW_EPOCH - HB_EPOCH))
      HEARTBEAT_AGE="${AGE}s ago"
      HB_AGE_SECS=$AGE
    fi
  fi

  EXIT_FILE="${LOG_DIR}/exit_code"
  SUMMARY_FILE="${LOG_DIR}/summary.json"
  FINISHED=false
  CC_EXIT=""
  if [ -f "$EXIT_FILE" ]; then
    FINISHED=true
    CC_EXIT=$(cat "$EXIT_FILE" | tr -d '[:space:]')
  elif [ -f "$SUMMARY_FILE" ]; then
    FINISHED=true
    CC_EXIT=$(python3 -c "import json; print(json.load(open('${SUMMARY_FILE}'))['exit_code'])" 2>/dev/null || echo "-1")
  fi

  if [ "$FINISHED" = true ]; then
    echo "status=finished"
    echo "exit_code=${CC_EXIT}"
  elif [ "$TMUX_ALIVE" = true ]; then
    echo "status=running"
    echo "heartbeat_age=${HEARTBEAT_AGE:-unknown}"
  elif [ -n "$HB_AGE_SECS" ] && [ "$HB_AGE_SECS" -lt 60 ] 2>/dev/null; then
    echo "status=completing"
    echo "heartbeat_age=${HEARTBEAT_AGE}"
  else
    echo "status=orphaned"
    echo "heartbeat_age=${HEARTBEAT_AGE:-unknown}"
  fi

  echo "session_id=${SESSION_ID}"
  echo "tmux_session=${TMUX_SESSION}"
  echo "log_dir=${LOG_DIR}"
  echo "log_exists=$([ -f "${LOG_DIR}/output.log" ] && echo true || echo false)"

  exit 0
fi

# ── Log ─────────────────────────────────────────────────────────────
if [ "$CMD" = "log" ]; then
  LINES="${3:-50}"
  LOG_FILE="${LOG_DIR}/output.log"

  if [ ! -f "$LOG_FILE" ]; then
    echo "Error: no output log found at ${LOG_FILE}"
    exit 1
  fi

  tail -n "$LINES" "$LOG_FILE"
  exit 0
fi

# ── Kill ────────────────────────────────────────────────────────────
if [ "$CMD" = "kill" ]; then
  if [ -n "$TMUX_SESSION" ] && tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    tmux capture-pane -t "$TMUX_SESSION" -p -S -2000 > "${LOG_DIR}/output.log" 2>/dev/null || true
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  fi

  if [ ! -f "${LOG_DIR}/summary.json" ]; then
    cat > "${LOG_DIR}/summary.json" << EOF
{
  "session_id": "${SESSION_ID}",
  "exit_code": -1,
  "status": "killed",
  "duration_seconds": 0,
  "log_path": "${LOG_DIR}",
  "note": "Killed by cc-monitor.sh kill"
}
EOF
  fi

  echo "Killed session ${SESSION_ID}"
  exit 0
fi

# ── Unknown command ─────────────────────────────────────────────────
echo "Error: unknown command '$CMD'"
echo "Valid commands: status, log, kill, list, help"
exit 1