#!/bin/bash
# cc-orchestrate.sh — Phase-based task orchestrator for Claude Code
#
# Reads a phased spec and runs each phase as a separate Claude Code
# invocation via cc-executor.sh. Phases run sequentially. If a phase
# fails (verify command fails or Claude Code errors out), orchestration
# stops and a failure report is produced. Completed phases' work is
# preserved on disk.
#
# Usage:
#   cc-orchestrate.sh <spec_file> [workdir]
#
#   spec_file  — Required. Path to the phase spec (see Spec Format below)
#   workdir    — Working directory (default: current directory)
#
# Exit codes:
#   0 — all phases completed successfully
#   1 — one or more phases failed (see summary output)
#
# ── Spec Format ─────────────────────────────────────────────────────
#
# The spec file uses ## Phase N: headings with metadata lines
# followed by --- and the instruction block:
#
#   # Build Spec: My Feature
#
#   ## Phase 1: Backend Schemas
#   model: fast
#   max_turns: 15
#   timeout: 200
#   verify: python3 -c "from mymodule import MyClass; print('OK')"
#   ---
#   Create the MyClass model with fields...
#
#   ## Phase 2: Service Layer
#   model: exact
#   max_turns: 25
#   timeout: 400
#   verify: python3 -c "from services import Service; print('OK')"
#   ---
#   Implement the Service class...
#
# Metadata fields (before '---' in each phase):
#   model:      Model profile: 'fast' or 'exact' (default: exact)
#   max_turns:  Max agentic loops (default: 25)
#   timeout:    Max seconds (default: 300)
#   verify:     Shell command to verify phase output (default: none)
#   skip:       Set to 'true' to skip this phase (default: false)
#
# The instruction block (after '---') is passed verbatim as the
# Claude Code prompt for that phase. Each phase runs in isolation.
#
# ── Environment ─────────────────────────────────────────────────────
#
#   CC_LOG_DIR  — Log directory (default: ~/.cc-phaser/logs)
#
#   All CC_EXECUTOR_* and CC_* env vars are passed through to
#   cc-executor.sh automatically.
#
# ── Example ─────────────────────────────────────────────────────────
#
#   cc-orchestrate.sh /path/to/SPEC.md /path/to/project
#
# License: MIT (https://opensource.org/licenses/MIT)

set -euo pipefail

# ── Paths ───────────────────────────────────────────────────────────
SPEC_FILE="${1:?Usage: $0 <spec_file> [workdir]}"
WORKDIR="${2:-$(pwd)}"
CC_LOG_DIR="${CC_LOG_DIR:-$HOME/.cc-phaser/logs}"

# Resolve executor path: same directory as this script, or in PATH
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${SCRIPT_DIR}/cc-executor.sh" ]; then
  EXECUTOR="${SCRIPT_DIR}/cc-executor.sh"
else
  EXECUTOR="$(command -v cc-executor.sh 2>/dev/null || echo '')"
fi
MONITOR="${SCRIPT_DIR}/cc-monitor.sh"
[ -f "$MONITOR" ] || MONITOR="$(command -v cc-monitor.sh 2>/dev/null || echo '')"

SESSION_EPOCH=$(date +%s)
SESSION_ID="orchestrate-${SESSION_EPOCH}"
ORCH_LOG_DIR="${CC_LOG_DIR}/${SESSION_ID}"
SUMMARY_FILE="${ORCH_LOG_DIR}/phase-summary.json"

# ── Preflight ───────────────────────────────────────────────────────
if [ ! -f "$SPEC_FILE" ]; then
  echo "Error: spec file not found: $SPEC_FILE" >&2
  exit 1
fi

if [ ! -x "$EXECUTOR" ]; then
  # Fall back: try to find it in PATH
  EXECUTOR="$(command -v cc-executor.sh 2>/dev/null || true)"
  if [ -z "$EXECUTOR" ]; then
    echo "Error: cc-executor.sh not found in same directory or PATH" >&2
    exit 1
  fi
fi

if [ ! -d "$WORKDIR" ]; then
  echo "Error: workdir not found: $WORKDIR" >&2
  exit 1
fi

mkdir -p "$ORCH_LOG_DIR"

# ── Phase extraction ────────────────────────────────────────────────
PHASES_TMP=$(mktemp)
PHASE_RESULTS_FILE=$(mktemp)

python3 - "$SPEC_FILE" "$PHASES_TMP" << 'PYEOF'
import json, os, re, sys

spec_path = sys.argv[1]
output_path = sys.argv[2]

with open(spec_path, 'r') as f:
    lines = f.readlines()

# Split on "## Phase" headings
phase_blocks = []
current_block_start = None

for i, line in enumerate(lines):
    if re.match(r'^##\s+Phase\s+\d+', line):
        if current_block_start is not None:
            phase_blocks.append((current_block_start, i))
        current_block_start = i

if current_block_start is not None:
    phase_blocks.append((current_block_start, len(lines)))

defaults = {
    'model': 'exact',
    'max_turns': '25',
    'timeout': '300',
    'verify': '',
    'skip': 'false',
    'instructions': ''
}

for block_start, block_end in phase_blocks:
    block_lines = lines[block_start:block_end]
    phase_name = block_lines[0].strip().lstrip('#').strip()
    meta = dict(defaults)
    meta['name'] = phase_name
    meta['line_start'] = block_start + 1

    instr_start = None
    for j, line in enumerate(block_lines):
        stripped = line.strip()
        if stripped == '---':
            instr_start = j + 1
            break
        m = re.match(r'^(\w+):\s*(.*)$', stripped)
        if m:
            key = m.group(1).strip()
            val = m.group(2).strip()
            if key in ('model', 'max_turns', 'timeout', 'verify', 'skip'):
                meta[key] = val

    if instr_start is not None:
        instr_lines = block_lines[instr_start:]
        while instr_lines and not instr_lines[-1].strip():
            instr_lines.pop()
        meta['instructions'] = ''.join(instr_lines).strip()

    phases.append(meta)

with open(output_path, 'w') as f:
    for p in phases:
        f.write(json.dumps(p) + '\n')

print(f"Parsed {len(phases)} phases from {os.path.basename(spec_path)}")
PYEOF

NUM_PHASES=$(wc -l < "$PHASES_TMP")
if [ "$NUM_PHASES" -eq 0 ]; then
  echo "Error: no phases found in spec file. Use '## Phase N: Title' headings." >&2
  rm -f "$PHASES_TMP"
  exit 1
fi

echo "Orchestrating ${NUM_PHASES} phases from $(basename "$SPEC_FILE")"
echo "Workdir: ${WORKDIR}"
echo ""

# ── Phase Execution ──────────────────────────────────────────────────
PHASE_RESULTS=()
ALL_PASSED=true

for PHASE_IDX in $(seq 1 "$NUM_PHASES"); do
  PHASE_JSON=$(sed -n "${PHASE_IDX}p" "$PHASES_TMP")
  PHASE_NAME=$(echo "$PHASE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")
  PHASE_MODEL=$(echo "$PHASE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['model'])")
  PHASE_TURNS=$(echo "$PHASE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['max_turns'])")
  PHASE_TIMEOUT=$(echo "$PHASE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['timeout'])")
  PHASE_VERIFY=$(echo "$PHASE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['verify'])")
  PHASE_SKIP=$(echo "$PHASE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['skip'])")
  PHASE_INSTR=$(echo "$PHASE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['instructions'])")

  # Flatten instructions to single line for executor.sh args
  PHASE_INSTR_FLAT=$(echo "$PHASE_INSTR" | sed 's/"/\\"/g' | tr '\n' ' ' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')

  echo "─── Phase ${PHASE_IDX}/${NUM_PHASES}: ${PHASE_NAME} ───"
  echo "     model: ${PHASE_MODEL}  turns: ${PHASE_TURNS}  timeout: ${PHASE_TIMEOUT}s"

  if [ "$PHASE_SKIP" = "true" ]; then
    echo "     → SKIPPED"
    echo "{\"phase\":${PHASE_IDX},\"name\":\"${PHASE_NAME}\",\"status\":\"skipped\",\"duration_seconds\":0}" >> "$PHASE_RESULTS_FILE"
    continue
  fi

  if [ -z "$PHASE_INSTR" ]; then
    echo "     → FAILED (no instructions block)"
    echo "{\"phase\":${PHASE_IDX},\"name\":\"${PHASE_NAME}\",\"status\":\"skipped\",\"reason\":\"no instructions\",\"duration_seconds\":0}" >> "$PHASE_RESULTS_FILE"
    ALL_PASSED=false
    break
  fi

  # Run the phase via executor
  PHASE_START=$(date +%s)
  set +e
  PHASE_OUTPUT=$(bash "$EXECUTOR" \
    "$PHASE_INSTR_FLAT" \
    "$PHASE_TURNS" \
    "$PHASE_TIMEOUT" \
    "" \
    "$WORKDIR" \
    "$PHASE_MODEL" 2>&1)
  PHASE_EXIT=$?
  set -euo pipefail
  PHASE_END=$(date +%s)
  PHASE_DURATION=$((PHASE_END - PHASE_START))

  # Parse summary from execution output
  PHASE_STATUS="error"
  PHASE_SUMMARY_JSON=$(echo "$PHASE_OUTPUT" | python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if line.startswith('{'):
        try:
            print(line)
            break
        except: pass
" 2>/dev/null || echo "")

  if [ -n "$PHASE_SUMMARY_JSON" ]; then
    PHASE_CC_EXIT=$(echo "$PHASE_SUMMARY_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('exit_code','-1'))" 2>/dev/null || echo "-1")
    PHASE_LOG_PATH=$(echo "$PHASE_SUMMARY_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('log_path',''))" 2>/dev/null || echo "")
  else
    PHASE_CC_EXIT="$PHASE_EXIT"
    PHASE_LOG_PATH=""
  fi

  # Determine phase status
  if [ "$PHASE_EXIT" = "0" ] || [ "$PHASE_EXIT" = "1" ]; then
    PHASE_STATUS="completed"
  elif [ "$PHASE_EXIT" = "124" ]; then
    PHASE_STATUS="timeout"
  else
    PHASE_STATUS="error"
  fi

  # Run verify command if provided
  VERIFY_PASSED=true
  if [ -n "$PHASE_VERIFY" ] && [ "$PHASE_STATUS" != "timeout" ]; then
    echo "     verify: $PHASE_VERIFY"
    set +e
    VERIFY_OUTPUT=$(cd "$WORKDIR" && eval "$PHASE_VERIFY" 2>&1)
    VERIFY_EXIT=$?
    set -euo pipefail
    if [ "$VERIFY_EXIT" -ne 0 ]; then
      VERIFY_PASSED=false
      PHASE_STATUS="verify_failed"
      echo "     verify FAILED: $VERIFY_OUTPUT"
    else
      echo "     verify PASSED"
    fi
  fi

  echo "{\"phase\":${PHASE_IDX},\"name\":\"${PHASE_NAME}\",\"status\":\"${PHASE_STATUS}\",\"exit_code\":${PHASE_CC_EXIT},\"duration_seconds\":${PHASE_DURATION},\"log_path\":\"${PHASE_LOG_PATH}\",\"verify_passed\":${VERIFY_PASSED}}" >> "$PHASE_RESULTS_FILE"

  if [ "$PHASE_STATUS" = "timeout" ] || [ "$PHASE_STATUS" = "verify_failed" ] || [ "$PHASE_STATUS" = "error" ]; then
    ALL_PASSED=false
    echo "     → FAILED (${PHASE_STATUS})"
    break
  fi

  echo "     → PASSED (${PHASE_DURATION}s)"
  echo ""
done

rm -f "$PHASES_TMP"

# ── Final Summary ────────────────────────────────────────────────────
# Read phase results from temp file, parse with Python for robust JSON assembly
FINAL_SUMMARY=$(python3 -c "
import json, sys

results_file = '${PHASE_RESULTS_FILE}'
phases = []
with open(results_file) as f:
    for line in f:
        line = line.strip()
        if line:
            try:
                phases.append(json.loads(line))
            except json.JSONDecodeError:
                pass

passed = sum(1 for p in phases if p.get('status') == 'completed')
skipped = sum(1 for p in phases if p.get('status') == 'skipped')
failed = len(phases) - passed - skipped
all_passed = failed == 0

print(json.dumps({
    'phases_total': len(phases),
    'phases_passed': passed,
    'phases_failed': failed,
    'phases_skipped': skipped,
    'all_passed': all_passed,
    'phases': phases
}))
" 2>/dev/null || echo '{"phases_total":0,"phases_passed":0,"phases_failed":0,"phases_skipped":0,"all_passed":false,"phases":[]}')

rm -f "$PHASE_RESULTS_FILE"

TOTAL_END=$(date +%s)
TOTAL_DURATION=$((TOTAL_END - SESSION_EPOCH))

# Extract summary fields from FINAL_SUMMARY JSON
PASSED_COUNT=$(echo "$FINAL_SUMMARY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['phases_passed'])" 2>/dev/null || echo "0")
FAILED_COUNT=$(echo "$FINAL_SUMMARY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['phases_failed'])" 2>/dev/null || echo "0")
SKIPPED_COUNT=$(echo "$FINAL_SUMMARY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['phases_skipped'])" 2>/dev/null || echo "0")
ALL_PASSED_CHECK=$(echo "$FINAL_SUMMARY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(str(d['all_passed']).lower())" 2>/dev/null || echo "false")
PHASES_JSON=$(echo "$FINAL_SUMMARY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d['phases']))" 2>/dev/null || echo "[]")

cat > "$SUMMARY_FILE" << EOF
{
  "orchestration_id": "${SESSION_ID}",
  "spec_file": "${SPEC_FILE}",
  "workdir": "${WORKDIR}",
  "phases_total": $((PASSED_COUNT + FAILED_COUNT + SKIPPED_COUNT)),
  "phases_passed": ${PASSED_COUNT},
  "phases_failed": ${FAILED_COUNT},
  "phases_skipped": ${SKIPPED_COUNT},
  "all_passed": ${ALL_PASSED_CHECK},
  "total_duration_seconds": ${TOTAL_DURATION},
  "phases": ${PHASES_JSON}
}
EOF

# ── Report ───────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
echo "  Orchestration Complete"
echo "  Total phases: $((PASSED_COUNT + FAILED_COUNT + SKIPPED_COUNT))  Passed: ${PASSED_COUNT}  Failed: ${FAILED_COUNT}  Skipped: ${SKIPPED_COUNT}"
echo "  Duration: ${TOTAL_DURATION}s"
if [ "$ALL_PASSED_CHECK" = "true" ]; then
  echo "  Result: ALL PASSED"
else
  echo "  Result: FAILED — check phase logs above"
fi
echo "  Summary: ${SUMMARY_FILE}"
echo "═══════════════════════════════════════════════════"

cat "$SUMMARY_FILE"

if [ "$ALL_PASSED_CHECK" = "true" ]; then
  exit 0
else
  exit 1
fi