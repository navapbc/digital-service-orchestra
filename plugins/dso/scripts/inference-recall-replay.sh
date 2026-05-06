#!/usr/bin/env bash
# inference-recall-replay.sh — Recall/precision replay harness for inference incidents
# Emits RECALL_RESULT signal with recall_all, recall_holdout, and precision metrics.
# Story: 1c7b-74a6
# Tasks: 3b75-4262, bf54-67cb, e7dc-e592
set -euo pipefail

_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
INCIDENTS_FILE="${INCIDENTS_FILE:-tests/fixtures/inference-incidents/incidents.jsonl}"
HOLDOUT_FILE="${HOLDOUT_FILE:-tests/fixtures/inference-incidents/holdout.txt}"
CLASSIFIER_CMD="${CLASSIFIER_CMD:-}"
TICKET_EXISTS_CMD="${TICKET_EXISTS_CMD:-}"
OUTPUT_FORMAT="json"
DRY_RUN=0
MINIMUM_CORPUS=10

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --corpus=*)      INCIDENTS_FILE="${arg#--corpus=}" ;;
    --holdout=*)     HOLDOUT_FILE="${arg#--holdout=}" ;;
    --classifier-cmd=*) CLASSIFIER_CMD="${arg#--classifier-cmd=}" ;;
    --output=*)      OUTPUT_FORMAT="${arg#--output=}" ;;
    --dry-run)       DRY_RUN=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Step 1: Load incidents — parse line by line, skip comment/blank lines
# ---------------------------------------------------------------------------
_tmpdir=$(mktemp -d /tmp/inference-recall.XXXXXX)
trap 'rm -rf "$_tmpdir"' EXIT

_incidents_raw="$_tmpdir/incidents_raw.jsonl"
grep -v '^\s*#' "$INCIDENTS_FILE" | grep -v '^\s*$' > "$_incidents_raw" || true

_raw_count=0
while IFS= read -r _line; do
  [[ -z "$_line" ]] && continue
  (( _raw_count++ )) || true
done < "$_incidents_raw"

# ---------------------------------------------------------------------------
# Step 2: Corpus size check (before quality filter)
# Only applies when no CLASSIFIER_CMD is provided (dry-run / default path).
# When a classifier is provided, the corpus gate is checked post-quality-filter.
# ---------------------------------------------------------------------------
if [[ -z "$CLASSIFIER_CMD" ]] && [[ "$DRY_RUN" -eq 0 ]]; then
  if [[ "$_raw_count" -lt "$MINIMUM_CORPUS" ]]; then
    printf '{"signal":"CORPUS_INSUFFICIENT","corpus_size":%d,"minimum_required":%d}\n' \
      "$_raw_count" "$MINIMUM_CORPUS"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Step 3: Corpus quality check — validate ticket_ids if TICKET_EXISTS_CMD set
# ---------------------------------------------------------------------------
_incidents_valid="$_tmpdir/incidents_valid.jsonl"
_excluded_count=0

touch "$_incidents_valid"
if [[ -n "$TICKET_EXISTS_CMD" ]]; then
  while IFS= read -r _line; do
    [[ -z "$_line" ]] && continue
    _tid=$(printf '%s' "$_line" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('ticket_id',''))" 2>/dev/null || true)
    if [[ -n "$_tid" ]] && "$TICKET_EXISTS_CMD" "$_tid" >/dev/null 2>&1; then
      printf '%s\n' "$_line" >> "$_incidents_valid"
    else
      (( _excluded_count++ )) || true
    fi
  done < "$_incidents_raw"
else
  # No ticket existence check available — accept all incidents
  cp "$_incidents_raw" "$_incidents_valid"
fi

if [[ "$_excluded_count" -gt 0 ]]; then
  printf 'CORPUS_QUALITY_WARNING: excluded %d incidents with non-existent ticket_ids\n' \
    "$_excluded_count" >&2
fi

# Recount after quality filter
_valid_count=0
while IFS= read -r _line; do
  [[ -z "$_line" ]] && continue
  (( _valid_count++ )) || true
done < "$_incidents_valid"

# Post-quality-filter corpus check: applies when TICKET_EXISTS_CMD is set
if [[ -n "$TICKET_EXISTS_CMD" ]] && [[ "$_valid_count" -lt "$MINIMUM_CORPUS" ]]; then
  printf '{"signal":"CORPUS_INSUFFICIENT","corpus_size":%d,"minimum_required":%d}\n' \
    "$_valid_count" "$MINIMUM_CORPUS"
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 4: Load holdout ticket_ids
# ---------------------------------------------------------------------------
_holdout_ids="$_tmpdir/holdout_ids.txt"
grep -v '^\s*#' "$HOLDOUT_FILE" | grep -v '^\s*$' > "$_holdout_ids" || true

# ---------------------------------------------------------------------------
# Step 5: Classify each incident and collect results
# ---------------------------------------------------------------------------
# Results file: one line per incident: <ticket_id> <outcome> <challenged>
# outcome: user_corrected | other
# challenged: 1 | 0
_results="$_tmpdir/results.tsv"

_classify_incident() {
  local _ticket_id="$1"
  local _affects_fields="$2"

  if [[ "$DRY_RUN" -eq 1 ]] || [[ -z "$CLASSIFIER_CMD" ]]; then
    # Dry-run: use affects_fields to determine challenge
    case "$_affects_fields" in
      gate_verdicts|workflow_completion_checklist)
        echo "challenge"
        return
        ;;
    esac
    # SHA-256 of ticket_id, last 8 hex chars as int, mod 5 == 0 → challenge
    local _hash _last8 _val
    _hash=$(printf '%s' "$_ticket_id" | sha256sum | awk '{print $1}')
    _last8="${_hash: -8}"
    _val=$(printf '%d\n' "0x${_last8}" 2>/dev/null || python3 -c "print(int('$_last8', 16))")
    if (( _val % 5 == 0 )); then
      echo "challenge"
    else
      echo "skip"
    fi
  else
    "$CLASSIFIER_CMD" "$_ticket_id" 2>/dev/null || echo "skip"
  fi
}

while IFS= read -r _line; do
  [[ -z "$_line" ]] && continue
  _ticket_id=$(printf '%s' "$_line" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('ticket_id',''))" 2>/dev/null || true)
  _outcome=$(printf '%s' "$_line" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('outcome',''))" 2>/dev/null || true)
  _affects_fields=$(printf '%s' "$_line" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('affects_fields',''))" 2>/dev/null || true)

  _decision=$(_classify_incident "$_ticket_id" "$_affects_fields")
  if [[ "$_decision" == "challenge" ]]; then
    _challenged=1
  else
    _challenged=0
  fi

  printf '%s\t%s\t%d\n' "$_ticket_id" "$_outcome" "$_challenged" >> "$_results"
done < "$_incidents_valid"

# ---------------------------------------------------------------------------
# Step 6: Compute metrics via Python3
# ---------------------------------------------------------------------------
_py=$(mktemp /tmp/recall-metrics.XXXXXX.py)
cat > "$_py" << 'PYEOF'
import sys, json

holdout_file = sys.argv[1]
results_file = sys.argv[2]

# Load holdout set
holdout_ids = set()
with open(holdout_file) as f:
    for line in f:
        line = line.strip()
        if line and not line.startswith('#'):
            holdout_ids.add(line)

# Parse results
incidents = []
with open(results_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        parts = line.split('\t')
        if len(parts) < 3:
            continue
        ticket_id, outcome, challenged = parts[0], parts[1], int(parts[2])
        incidents.append({
            'ticket_id': ticket_id,
            'outcome': outcome,
            'challenged': challenged,
            'is_holdout': ticket_id in holdout_ids,
        })

total = len(incidents)
total_holdout = sum(1 for i in incidents if i['is_holdout'])

# recall_all: of all incidents where outcome==user_corrected, fraction challenged
true_incidents = [i for i in incidents if i['outcome'] == 'user_corrected']
challenged_true = [i for i in true_incidents if i['challenged']]
recall_all = len(challenged_true) / len(true_incidents) if true_incidents else 0.0

# recall_holdout: same but restricted to holdout subset
holdout_true = [i for i in incidents if i['is_holdout'] and i['outcome'] == 'user_corrected']
holdout_true_challenged = [i for i in holdout_true if i['challenged']]
recall_holdout = len(holdout_true_challenged) / len(holdout_true) if holdout_true else 1.0

# precision: of all challenged, fraction where outcome==user_corrected
all_challenged = [i for i in incidents if i['challenged']]
challenged_true_count = sum(1 for i in all_challenged if i['outcome'] == 'user_corrected')
precision = challenged_true_count / len(all_challenged) if all_challenged else 0.0

result = {
    'recall_all': recall_all,
    'recall_holdout': recall_holdout,
    'precision': precision,
    'total': total,
    'total_holdout': total_holdout,
    'thresholds': {
        'recall_all': 0.5,
        'recall_holdout': 0.7,
        'precision': 0.5,
    },
    'pass': recall_all >= 0.5 and recall_holdout >= 0.7 and precision >= 0.5,
}
print(json.dumps(result))
PYEOF

_metrics_json=$(python3 "$_py" "$_holdout_ids" "$_results")
rm -f "$_py"

# ---------------------------------------------------------------------------
# Step 7: Emit RECALL_RESULT
# ---------------------------------------------------------------------------
# Format: RECALL_RESULT recall_all=X.X recall_holdout=X.X precision=X.X ...
_recall_all=$(printf '%s' "$_metrics_json" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(round(d['recall_all'],1))")
_recall_holdout=$(printf '%s' "$_metrics_json" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(round(d['recall_holdout'],1))")
_precision=$(printf '%s' "$_metrics_json" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(round(d['precision'],1))")
_pass=$(printf '%s' "$_metrics_json" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print('PASS' if d['pass'] else 'FAIL')")

printf 'RECALL_RESULT recall_all=%s recall_holdout=%s precision=%s status=%s\n' \
  "$_recall_all" "$_recall_holdout" "$_precision" "$_pass"

# ---------------------------------------------------------------------------
# Step 8: Exit code
# ---------------------------------------------------------------------------
if [[ "$_pass" == "PASS" ]]; then
  exit 0
else
  exit 2
fi
