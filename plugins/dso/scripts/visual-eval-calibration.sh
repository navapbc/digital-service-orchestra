#!/usr/bin/env bash
# Visual Evaluator Calibration Script
#
# INVOCATION POLICY: On-demand only. Not wired to per-PR CI.
# Run from the repo root: bash ${CLAUDE_PLUGIN_ROOT}/scripts/visual-eval-calibration.sh [--corpus-dir <path>] [--evaluate]
#
# --evaluate: Run the labeling pipeline 3 times per fixture at temperature=0 BEFORE gate checks.
# (Without --evaluate, the script only runs gates on pre-existing labels.)
#
# Enforces 4 gates per epic SC-3:
#   - Variance gate, Accuracy gate, Class-skew gate, Hallucination gate
#
# Exits 0 only when ALL gates pass.

set -euo pipefail

CORPUS_DIR="$(dirname "$0")/../data/visual-eval-corpus"
RUN_EVALUATE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --corpus-dir)
            CORPUS_DIR="$2"
            shift 2
            ;;
        --evaluate)
            RUN_EVALUATE=1
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ ! -d "$CORPUS_DIR" ]]; then
    echo "ERROR: corpus directory not found: $CORPUS_DIR" >&2
    exit 1
fi

if [[ "$RUN_EVALUATE" == "1" ]]; then
    echo "INFO: Running 3-run evaluator labeling at temperature=0..."
    SCRIPT_DIR="$(dirname "$0")"
    PYTHONPATH="${SCRIPT_DIR}:${PYTHONPATH:-}" \
        python3 -c "
import sys
sys.path.insert(0, '${SCRIPT_DIR}')
from label_visual_corpus import label_all
result = label_all('${CORPUS_DIR}', stub_mode=True, runs=3)
print(f'Labeled {result[\"fixture_count\"]} fixtures with {result[\"runs_per_fixture\"]} runs; kappa={result[\"cohens_kappa\"]:.4f}')
"
fi

PYTHONPATH="$(dirname "$0"):${PYTHONPATH:-}" \
    python3 "$(dirname "$0")/visual_eval_gates.py" "$CORPUS_DIR"
