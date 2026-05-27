#!/usr/bin/env bash
# Integration A: Per-task inline visual evaluation (behind config flag).
# Called by sprint orchestrator at per-worktree Step 4a after commit, before harvest.
# Gated by visual_evaluator.integration_a_enabled (default: false).
#
# Arguments:
#   $1 — file list (newline-separated) of files modified by the task
#   $2 — (optional) story/task ID for annotation
#
# Exit codes:
#   0 — evaluation passed or gracefully degraded
#   1 — intent_match below threshold after iteration cap exhausted (FAIL task)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
PLUGIN_SCRIPTS="$PLUGIN_ROOT/scripts"

FILE_LIST="${1:-}"
TASK_ID="${2:-}"

CAPTURE_DIR=""
trap '[[ -d "${CAPTURE_DIR:-}" ]] && rm -rf "$CAPTURE_DIR"' EXIT

# Gate: integration_a_enabled must be true
ENABLED=$(bash "$PLUGIN_SCRIPTS/read-config.sh" visual_evaluator.integration_a_enabled 2>/dev/null || echo "false")
if [[ "$ENABLED" != "true" ]]; then
  exit 0
fi

# Gate: UI files present in task modifications
if [[ -z "$FILE_LIST" ]]; then
  exit 0
fi

if ! echo "$FILE_LIST" | bash "$PLUGIN_SCRIPTS/detect-ui-files.sh"; then
  exit 0
fi

# Precondition gates (shared — includes visual_evaluator.enabled check)
REASON=$(bash "$PLUGIN_SCRIPTS/sprint/visual-eval-preconditions.sh" --route-map-required 2>/dev/null) || {
  echo "visual_eval_inapplicable:$REASON" >&2
  exit 0
}

# Config
ITERATION_CAP=$(bash "$PLUGIN_SCRIPTS/read-config.sh" visual_evaluator.iteration_cap 2>/dev/null || echo "2")
INTENT_THRESHOLD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" visual_evaluator.iteration_threshold 2>/dev/null || echo "3")
[[ -z "$ITERATION_CAP" ]] && ITERATION_CAP=2
[[ -z "$INTENT_THRESHOLD" ]] && INTENT_THRESHOLD=3

DESIGN_MANIFEST=".ui-discovery-cache/design-manifest.json"
MANIFEST_ARGS=()
if [[ -f "$DESIGN_MANIFEST" ]]; then
  MANIFEST_ARGS=(--manifest "$DESIGN_MANIFEST")
fi

# Capture screenshots
CAPTURE_DIR=$(bash "$PLUGIN_SCRIPTS/capture-screenshots.sh" --skip-preconditions 2>/dev/null) || {
  echo "visual_eval_inapplicable:capture_failed" >&2
  exit 0
}

# Iteration loop
iteration=0
last_result=""
while [[ $iteration -lt $ITERATION_CAP ]]; do
  iteration=$((iteration + 1))

  # Evaluate first screenshot (primary route for the task)
  first_png=$(find "$CAPTURE_DIR" -maxdepth 1 -name '*.png' -print -quit 2>/dev/null)
  if [[ -z "$first_png" ]]; then
    echo "visual_eval_inapplicable:no_screenshots" >&2
    exit 0
  fi

  last_result=$(python3 "$PLUGIN_SCRIPTS/visual-eval-run.py" \
    --screenshot "$first_png" \
    "${MANIFEST_ARGS[@]}" 2>/dev/null) || {
    echo "visual_eval_inapplicable:eval_failed" >&2
    exit 0
  }

  # Check for graceful degradation
  if echo "$last_result" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'visual_eval_inapplicable' in d else 1)" 2>/dev/null; then
    echo "visual_eval_inapplicable:api_degradation" >&2
    exit 0
  fi

  # Extract intent_match score
  intent_match=$(echo "$last_result" | python3 -c "import sys,json; print(json.load(sys.stdin)['scores']['intent_match'])" 2>/dev/null || echo "0")

  if [[ $intent_match -ge $INTENT_THRESHOLD ]]; then
    # Passed — check for quality dimension shortfalls
    echo "$last_result" | python3 -c "
import sys, json
result = json.load(sys.stdin)
scores = result.get('scores', {})
for dim, score in scores.items():
    if dim != 'intent_match' and score < 3:
        print(f'visual_debt:{dim}', file=sys.stderr)
" || true

    # Observability annotation
    if [[ -n "$TASK_ID" ]]; then
      finding_count=$(echo "$last_result" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('findings',[])))" 2>/dev/null || echo "0")
      .claude/scripts/dso ticket tag "$TASK_ID" "visual_eval:routes=1,findings=${finding_count},mean_intent_match=${intent_match}" 2>/dev/null || true
    fi
    exit 0
  fi

  # Below threshold — extract attribution for routing
  attribution_class=$(echo "$last_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('attribution_class','uncertain'))" 2>/dev/null || echo "uncertain")
  attribution_confidence=$(echo "$last_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('attribution_confidence','low'))" 2>/dev/null || echo "low")

  echo "visual_eval_routing:${attribution_class}:${attribution_confidence}:iteration=${iteration}" >&2

  if [[ $iteration -lt $ITERATION_CAP ]]; then
    # Re-capture for next iteration
    rm -rf "$CAPTURE_DIR"
    CAPTURE_DIR=$(bash "$PLUGIN_SCRIPTS/capture-screenshots.sh" --skip-preconditions 2>/dev/null) || {
      echo "visual_eval_inapplicable:recapture_failed" >&2
      exit 0
    }
  fi
done

# Iteration cap exhausted — intent_match still below threshold
echo "visual_eval_failed:intent_match=${intent_match}:threshold=${INTENT_THRESHOLD}:iterations=${ITERATION_CAP}" >&2
exit 1
