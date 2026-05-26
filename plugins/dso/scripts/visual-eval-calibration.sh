#!/usr/bin/env bash
# Visual Evaluator Calibration Script
#
# INVOCATION POLICY: On-demand only. Not wired to per-PR CI.
# Run from the repo root: bash ${CLAUDE_PLUGIN_ROOT}/scripts/visual-eval-calibration.sh [--corpus-dir <path>]
#
# Enforces 4 gates per epic SC-3:
#   - Variance gate: per-fixture score variance <= 0.5
#   - Accuracy gate: weighted attribution accuracy >= 0.7
#   - Class-skew gate: each class within [10%, 60%] of agent decisions
#   - Hallucination gate: dom_xpath_visually_consistent=false rate < 20%
#
# Exits 0 only when ALL gates pass.

set -euo pipefail

CORPUS_DIR="$(dirname "$0")/../data/visual-eval-corpus"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --corpus-dir)
            CORPUS_DIR="$2"
            shift 2
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

REPO_ROOT="$(git rev-parse --show-toplevel)"
PYTHONPATH="$(dirname "$0"):${PYTHONPATH:-}" \
    python3 "$(dirname "$0")/visual_eval_gates.py" "$CORPUS_DIR"
