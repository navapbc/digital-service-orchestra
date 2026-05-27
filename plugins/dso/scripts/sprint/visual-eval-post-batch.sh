#!/usr/bin/env bash
# Integration B: Post-batch visual evaluation.
# Called by sprint orchestrator at Phase F Step 12a after each batch completes.
# Checks if batch modified UI files, runs precondition gates, captures screenshots,
# evaluates each route via VLM, and feeds results to the 5th committee reviewer.
#
# Exit 0 on success or graceful degradation (never blocks the sprint).
# Emits annotations to stderr for observability.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
PLUGIN_SCRIPTS="$PLUGIN_ROOT/scripts"

CAPTURE_DIR=""
RESULTS_DIR=""
KEEP_RESULTS=false
trap '
  [[ -d "${CAPTURE_DIR:-}" ]] && rm -rf "$CAPTURE_DIR"
  [[ "$KEEP_RESULTS" != "true" && -d "${RESULTS_DIR:-}" ]] && rm -rf "$RESULTS_DIR"
' EXIT

# Accept file list as arguments or on stdin
files=()
if [[ $# -gt 0 ]]; then
  files=("$@")
else
  while IFS= read -r line; do
    [[ -n "$line" ]] && files+=("$line")
  done
fi

# Step 1: Check if batch modified UI files
if [[ ${#files[@]} -eq 0 ]]; then
  exit 0
fi

if ! printf '%s\n' "${files[@]}" | bash "$PLUGIN_SCRIPTS/detect-ui-files.sh"; then
  exit 0
fi

# Step 2: Precondition gates (shared)
REASON=$(bash "$PLUGIN_SCRIPTS/sprint/visual-eval-preconditions.sh" --route-map-required 2>/dev/null) || {
  echo "visual_eval_inapplicable:$REASON" >&2
  exit 0
}

# Step 3: Capture screenshots
CAPTURE_DIR=$(bash "$PLUGIN_SCRIPTS/capture-screenshots.sh" --skip-preconditions 2>/dev/null) || {
  echo "visual_eval_inapplicable:capture_failed" >&2
  exit 0
}

# Step 4: Token budget gate (post-capture, actual sizes)
TOKEN_BUDGET=$(bash "$PLUGIN_SCRIPTS/read-config.sh" visual_evaluator.post_batch_token_budget 2>/dev/null || echo "50000")
HARD_STOP_MULT=$(bash "$PLUGIN_SCRIPTS/read-config.sh" visual_evaluator.post_batch_token_hard_stop_multiplier 2>/dev/null || echo "3")
[[ -z "$TOKEN_BUDGET" ]] && TOKEN_BUDGET=50000
[[ -z "$HARD_STOP_MULT" ]] && HARD_STOP_MULT=3

ACTUAL_BYTES=0
for f in "$CAPTURE_DIR"/*.png; do
  [[ -f "$f" ]] || continue
  ACTUAL_BYTES=$((ACTUAL_BYTES + $(wc -c < "$f")))
done
PROJECTED_TOKENS=$(( (ACTUAL_BYTES * 4 / 3 / 3) + 4000 + 2000 ))
HARD_STOP=$(( TOKEN_BUDGET * HARD_STOP_MULT ))

if [[ $PROJECTED_TOKENS -gt $HARD_STOP ]]; then
  echo "visual_eval_post_batch_skipped_budget_exceeded (projected=$PROJECTED_TOKENS, hard_stop=$HARD_STOP)" >&2
  exit 0
fi

if [[ $PROJECTED_TOKENS -gt $TOKEN_BUDGET ]]; then
  echo "visual_eval_post_batch_budget_warning (projected=$PROJECTED_TOKENS, budget=$TOKEN_BUDGET)" >&2
fi

# Step 5: Evaluate each screenshot
RESULTS_DIR=$(mktemp -d /tmp/visual-eval-results.XXXXXX)
DESIGN_MANIFEST=".ui-discovery-cache/design-manifest.json"
eval_count=0

MANIFEST_ARGS=()
if [[ -f "$DESIGN_MANIFEST" ]]; then
  MANIFEST_ARGS=(--manifest "$DESIGN_MANIFEST")
fi

for png in "$CAPTURE_DIR"/*.png; do
  [[ -f "$png" ]] || continue
  route_name=$(basename "$png" .png)
  result_file="$RESULTS_DIR/${route_name}.json"

  python3 "$PLUGIN_SCRIPTS/visual-eval-run.py" \
    --screenshot "$png" \
    "${MANIFEST_ARGS[@]}" \
    > "$result_file" 2>/dev/null && eval_count=$((eval_count + 1)) || true
done

if [[ $eval_count -eq 0 ]]; then
  echo "visual_eval_post_batch_no_results" >&2
  exit 0
fi

# Step 6: Observability — annotate story ticket
if [[ -n "${STORY_ID:-}" ]]; then
  SUMMARY=$(python3 "$PLUGIN_SCRIPTS/visual-eval-run.py" --summarize "$RESULTS_DIR" 2>/dev/null || echo "")
  if [[ -n "$SUMMARY" ]]; then
    ROUTES=$(echo "$SUMMARY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('routes',0))" 2>/dev/null || echo "0")
    FINDINGS=$(echo "$SUMMARY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('findings',0))" 2>/dev/null || echo "0")
    MEAN_IM=$(echo "$SUMMARY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('mean_intent_match',0))" 2>/dev/null || echo "0")
    .claude/scripts/dso ticket tag "$STORY_ID" "visual_eval:routes=${ROUTES},findings=${FINDINGS},mean_intent_match=${MEAN_IM}" 2>/dev/null || true
  fi
fi

# Output results directory for the 5th committee reviewer
KEEP_RESULTS=true
echo "$RESULTS_DIR"
