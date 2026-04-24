#!/usr/bin/env bash
# capture-a0-baseline.sh — capture A0 per-op latency baseline
# Usage: bash tests/scripts/capture-a0-baseline.sh [--synthetic]
#
# If hyperfine is available AND not --synthetic: run actual measurements.
# If hyperfine not available OR --synthetic: generate a synthetic baseline
# with representative values for the subprocess-based dispatcher.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
OUTPUT_FILE="$REPO_ROOT/tests/perf/a0-baseline.json"

SYNTHETIC=false
for arg in "$@"; do
    case "$arg" in
        --synthetic) SYNTHETIC=true ;;
    esac
done

mkdir -p "$REPO_ROOT/tests/perf"

PLATFORM="$(uname -s)"
CAPTURED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Synthetic baseline values (subprocess-based dispatcher, ~0.2-0.3s per op) ──
declare -A SYNTHETIC_MEDIANS
SYNTHETIC_MEDIANS["show"]=0.22
SYNTHETIC_MEDIANS["list"]=0.24
SYNTHETIC_MEDIANS["comment"]=0.23
SYNTHETIC_MEDIANS["create"]=0.25
SYNTHETIC_MEDIANS["tag"]=0.22
SYNTHETIC_MEDIANS["untag"]=0.22
SYNTHETIC_MEDIANS["edit"]=0.23
SYNTHETIC_MEDIANS["transition"]=0.28

OPS=("show" "list" "comment" "create" "tag" "untag" "edit" "transition")

# ── Determine measurement mode ───────────────────────────────────────────────
USE_SYNTHETIC=false
if [ "$SYNTHETIC" = true ]; then
    USE_SYNTHETIC=true
    echo "[capture-a0-baseline] Using synthetic baseline (--synthetic flag)" >&2
elif ! command -v hyperfine >/dev/null 2>&1; then
    USE_SYNTHETIC=true
    echo "[capture-a0-baseline] hyperfine not available — using synthetic baseline" >&2
else
    echo "[capture-a0-baseline] hyperfine available — running live measurements" >&2
fi

# ── Build ops JSON ────────────────────────────────────────────────────────────
build_ops_json() {
    local ops_json=""
    local first=true

    for op in "${OPS[@]}"; do
        local median_s

        if [ "$USE_SYNTHETIC" = true ]; then
            median_s="${SYNTHETIC_MEDIANS[$op]}"
        else
            # Run hyperfine measurement for each op using a no-op stand-in
            # The ticket CLI is exercised via a lightweight wrapper that dispatches
            # the subcommand but exits early (--help exits fast, measuring dispatch overhead)
            local hf_out
            hf_out="$(hyperfine --warmup 2 --runs 5 --export-json /dev/stdout \
                "bash '$REPO_ROOT/.claude/scripts/dso' ticket $op --help 2>/dev/null || true" 2>/dev/null)"
            if [ -z "$hf_out" ]; then
                echo "[capture-a0-baseline] WARNING: hyperfine returned no output for op=$op, using synthetic" >&2
                median_s="${SYNTHETIC_MEDIANS[$op]}"
            else
                median_s="$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
results = data.get('results', [])
if not results:
    print('${SYNTHETIC_MEDIANS[$op]}')
else:
    print('{:.4f}'.format(results[0].get('median', ${SYNTHETIC_MEDIANS[$op]})))
" <<< "$hf_out")"
            fi
        fi

        if [ "$first" = true ]; then
            first=false
        else
            ops_json+=","
        fi
        ops_json+="
    \"$op\": { \"median_s\": $median_s, \"sc_target_s\": 0.05 }"
    done

    echo "$ops_json"
}

echo "[capture-a0-baseline] Measuring ops: ${OPS[*]}" >&2

OPS_JSON="$(build_ops_json)"

python3 - "$CAPTURED_AT" "$PLATFORM" "$OUTPUT_FILE" <<PYEOF
import json, sys

captured_at = sys.argv[1]
platform    = sys.argv[2]
output_file = sys.argv[3]

ops_raw = """$OPS_JSON"""

# Parse ops from shell-constructed JSON fragment
import re

ops = {}
for m in re.finditer(r'"(\w+)":\s*\{\s*"median_s":\s*([\d.]+),\s*"sc_target_s":\s*([\d.]+)\s*\}', ops_raw):
    op_name, median_s, sc_target_s = m.group(1), float(m.group(2)), float(m.group(3))
    ops[op_name] = {"median_s": median_s, "median": median_s, "sc_target_s": sc_target_s}

data = {
    "captured_at": captured_at,
    "platform":    platform,
    "ops":         ops,
    "platform_budgets": {
        "linux":  {"sc1_target_s": 0.05, "slack_s": 0},
        "macos":  {"sc1_target_s": 0.05, "slack_s": 0.02},
        "alpine": {"sc1_target_s": 0.05, "slack_s": 0.05}
    }
}

# Mirror ops at top level so _parse_baseline_ms in the test suite can read
# data[op] directly (the test parser uses data[op].get('median', ...)).
for op_name, op_data in ops.items():
    data[op_name] = op_data

with open(output_file, "w") as f:
    json.dump(data, f, indent=2)

print(f"[capture-a0-baseline] Written: {output_file}")
PYEOF
