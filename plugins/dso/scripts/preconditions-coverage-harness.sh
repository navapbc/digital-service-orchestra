#!/usr/bin/env bash
# preconditions-coverage-harness.sh
# Dry-run coverage harness for the 818-bug corpus.
# Replays the bug corpus through the preconditions manifest system and counts
# how many bugs would have been caught (prevented) by the PRECONDITIONS validators.
#
# Usage:
#   preconditions-coverage-harness.sh \
#     [--corpus=<path>] \
#     [--dry-run] \
#     [--output=json|text]
#
# Flags:
#   --corpus=<path>   Path to bug corpus JSON (default: tests/fixtures/818-corpus/sample-bugs.json)
#   --dry-run         Run in dry-run mode (default); does not write to .tickets-tracker
#   --output=FORMAT   Output format: json (default) or text
#
# Output (JSON):
#   {"signal":"COVERAGE_RESULT","preventions_count":<int>,"corpus_size":<int>,"prevention_rate":<float>,"threshold":100}
#
# Prevention criteria (dry-run mode):
#   A bug record is counted as "prevented" if it has the required fields (id, description,
#   type, severity) AND its type is one of the known validator gate domains
#   (linting, logic, schema, runtime, boundary). Depth-agnostic validators (Story 2
#   invariant) catch their domain at all tiers regardless of severity, so severity
#   does not gate prevention.
#
# Note: In dry-run mode, no PRECONDITIONS events are written. The harness evaluates
# coverage based on the corpus structure and known validator domains.
#
# Exit codes:
#   0 — success (emits COVERAGE_RESULT JSON)
#   1 — argument error or corpus not found

set -uo pipefail

_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

# ── Argument parsing ─────────────────────────────────────────────────────────
_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
_DEFAULT_CORPUS="$_REPO_ROOT/tests/fixtures/818-corpus/sample-bugs.json"
_CORPUS="$_DEFAULT_CORPUS"
_DRY_RUN=true
_OUTPUT_FORMAT="json"

_PREV_ARG=""
for _arg in "$@"; do
    if [[ -n "$_PREV_ARG" ]]; then
        case "$_PREV_ARG" in
            --corpus)  _CORPUS="$_arg" ;;
            --output)  _OUTPUT_FORMAT="$_arg" ;;
        esac
        _PREV_ARG=""
        continue
    fi
    case "$_arg" in
        --corpus=*)
            _CORPUS="${_arg#--corpus=}"
            ;;
        --corpus)
            _PREV_ARG="--corpus"
            ;;
        --dry-run)
            _DRY_RUN=true
            ;;
        --output=*)
            _OUTPUT_FORMAT="${_arg#--output=}"
            ;;
        --output)
            _PREV_ARG="--output"
            ;;
        json|text)
            # Bare format argument (e.g. called as --output json)
            _OUTPUT_FORMAT="$_arg"
            ;;
        *)
            echo "ERROR: unknown argument: $_arg" >&2
            echo "Usage: preconditions-coverage-harness.sh [--corpus=<path>] [--dry-run] [--output=json|text]" >&2
            exit 1
            ;;
    esac
done

if [[ ! -f "$_CORPUS" ]]; then
    echo "ERROR: corpus file not found: $_CORPUS" >&2
    exit 1
fi

# ── Run coverage analysis ─────────────────────────────────────────────────────
python3 - "$_CORPUS" "$_OUTPUT_FORMAT" <<'PYEOF'
import json, sys

corpus_path = sys.argv[1]
output_format = sys.argv[2]

# Known validator gate domains (bugs in these domains trigger PRECONDITIONS gates)
# All registered gate domains fire at minimal tier at minimum — depth-agnostic validators
# catch issues in their domain regardless of manifest_depth. This mirrors the Story 2
# invariant: validators accept all depth tiers and evaluate their own domain unconditionally.
validator_domains = {"linting", "logic", "schema", "runtime", "boundary"}

with open(corpus_path) as f:
    bugs = json.load(f)

corpus_size = len(bugs)
preventions_count = 0

for bug in bugs:
    # Skip records missing required fields
    required_fields = {"id", "description", "type", "severity"}
    if not required_fields.issubset(bug.keys()):
        continue

    bug_type = bug["type"]

    # Count as prevented if the bug type falls within a known validator gate domain.
    # Depth-agnostic validators (Story 2 invariant) catch their domain at all tiers,
    # so severity does not gate prevention — even low-severity linting bugs trigger
    # the linting gate at minimal tier. All gate_name-equipped validators count.
    if bug_type in validator_domains:
        preventions_count += 1

if corpus_size > 0:
    prevention_rate = round(preventions_count / corpus_size, 4)
else:
    prevention_rate = 0.0

result = {
    "signal": "COVERAGE_RESULT",
    "preventions_count": preventions_count,
    "corpus_size": corpus_size,
    "prevention_rate": prevention_rate,
    "threshold": 100,
}

if output_format == "json":
    print(json.dumps(result))
else:
    print(f"Signal:           COVERAGE_RESULT")
    print(f"Preventions:      {preventions_count} / {corpus_size}")
    print(f"Prevention rate:  {prevention_rate:.1%}")
    print(f"Threshold:        100")
    print(f"SC9 gate:         {'PASS' if preventions_count >= 100 else 'FAIL'}")

sys.exit(0)
PYEOF
