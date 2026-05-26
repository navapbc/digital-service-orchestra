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

CORPUS_DIR=""  # set in main below
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

# Resolve CORPUS_DIR if not provided via --corpus-dir
if [[ -z "$CORPUS_DIR" ]]; then
    _REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
    if [[ -z "$_REPO_ROOT" ]]; then echo "ERROR: must run from within a git repo" >&2; exit 1; fi
    # shellcheck disable=SC2016
    _PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"  # CLAUDE_PLUGIN_ROOT fallback
    CORPUS_DIR="${_PLUGIN_ROOT}/data/visual-eval-corpus"
fi

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

PYTHONPATH="$(cd "$(dirname "$0")" && pwd):${PYTHONPATH:-}" \
    python3 "$(cd "$(dirname "$0")" && pwd)/visual_eval_gates.py" "$CORPUS_DIR"
