#!/usr/bin/env bash
# ci-review-corpus-delta.sh — Per-fixture grounded-finding delta report.
#
# Compares pre-loop vs post-loop reviewer findings across a corpus directory,
# counting grounded findings (cited_lines with valid path:line format) and
# reporting per-fixture shift. Asserts that >=60% of fixtures improved from
# 0 grounded findings to >0. Also reports speculation marker reduction for
# the curated subset.
#
# Usage:
#   ci-review-corpus-delta.sh [--corpus-dir=<dir>] [--baseline-dir=<dir>] [--output=<file>]
#
# Options:
#   --corpus-dir=<dir>     Directory containing fixture subdirectories, each with
#                          post-loop-findings.json (and optionally pre-loop-findings.json).
#                          Defaults to tests/fixtures/ci-review-corpus relative to repo root.
#   --baseline-dir=<dir>   Directory containing pre-loop findings; defaults to looking for
#                          pre-loop-findings.json inside each fixture subdirectory.
#   --output=<file>        Write JSON summary to this file in addition to stdout.
#                          If omitted, output goes to stdout only.
#
# Exit codes:
#   0  >=60% of fixtures show grounded-finding improvement
#   1  <60% of fixtures show improvement (assertion failure)
#   2  Usage / environment error

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve repo root and plugin root
# ---------------------------------------------------------------------------
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$_SCRIPT_DIR/.." && pwd)}"
_REPO_ROOT="$(cd "$_PLUGIN_ROOT/../.." && pwd)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
_CORPUS_DIR="$_REPO_ROOT/tests/fixtures/ci-review-corpus"
_BASELINE_DIR=""
_OUTPUT_FILE=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --corpus-dir=*)   _CORPUS_DIR="${arg#--corpus-dir=}" ;;
        --baseline-dir=*) _BASELINE_DIR="${arg#--baseline-dir=}" ;;
        --output=*)       _OUTPUT_FILE="${arg#--output=}" ;;
        *)
            echo "ERROR: Unknown argument: $arg" >&2
            echo "Usage: $0 [--corpus-dir=<dir>] [--baseline-dir=<dir>] [--output=<file>]" >&2
            exit 2
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if [[ ! -d "$_CORPUS_DIR" ]]; then
    echo "ERROR: corpus-dir does not exist: $_CORPUS_DIR" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Python helpers — inline to avoid extra files
# ---------------------------------------------------------------------------

# count_grounded FINDINGS_JSON → integer printed to stdout
# A grounded finding has a cited_lines entry matching <path>:<integer>
_count_grounded() {
    local findings_file="$1"
    python3 - "$findings_file" <<'PYEOF'
import json, sys, re

PATH_LINE_RE = re.compile(r'^.+:\d+$')

def count_grounded(findings):
    total = 0
    for f in findings:
        for cl in (f.get("cited_lines") or []):
            if PATH_LINE_RE.match(str(cl).strip()):
                total += 1
                break  # one match per finding is enough to count it as grounded
    return total

data = json.loads(open(sys.argv[1]).read())
findings = data if isinstance(data, list) else data.get("findings", [])
print(count_grounded(findings))
PYEOF
}

# count_speculation FINDINGS_JSON → integer printed to stdout
_count_speculation() {
    local findings_file="$1"
    python3 - "$findings_file" <<'PYEOF'
import json, sys

MARKERS = [
    "may ", "might ", "could be", "possibly", "unclear if",
    "hard to tell", "without more context", "assuming",
    "it seems", "appears to", "probably", "perhaps",
]

def has_marker(desc):
    d = (desc or "").lower()
    return any(m in d for m in MARKERS)

data = json.loads(open(sys.argv[1]).read())
findings = data if isinstance(data, list) else data.get("findings", [])
print(sum(1 for f in findings if has_marker(f.get("description", ""))))
PYEOF
}

# ---------------------------------------------------------------------------
# Discover fixture entries
# Fixture entries are either:
#   a) Subdirectories of _CORPUS_DIR that contain post-loop-findings.json, OR
#   b) The corpus dir itself if it contains post-loop-findings.json (single fixture)
# ---------------------------------------------------------------------------
_discover_fixtures() {
    local corpus="$1"
    local -a entries=()

    # Check if the corpus dir itself is a single fixture
    if [[ -f "$corpus/post-loop-findings.json" ]]; then
        entries+=("$corpus")
    fi

    # Check subdirectories
    while IFS= read -r -d '' subdir; do
        if [[ -f "$subdir/post-loop-findings.json" ]]; then
            entries+=("$subdir")
        fi
    done < <(find "$corpus" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

    printf '%s\n' "${entries[@]}"
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
_total_fixtures=0
_improved_fixtures=0
_curated_improved=0
_curated_pre_speculation=0
_curated_post_speculation=0
_curated_count=0

declare -a _per_fixture_lines=()

while IFS= read -r fixture_dir; do
    [[ -z "$fixture_dir" ]] && continue

    fixture_name="$(basename "$fixture_dir")"
    post_file="$fixture_dir/post-loop-findings.json"

    # Resolve pre-loop file
    if [[ -n "$_BASELINE_DIR" ]]; then
        pre_file="$_BASELINE_DIR/${fixture_name}/pre-loop-findings.json"
    else
        pre_file="$fixture_dir/pre-loop-findings.json"
    fi

    # Pre-loop count (0 if file absent — loop didn't exist before)
    if [[ -f "$pre_file" ]]; then
        pre_count="$(_count_grounded "$pre_file")"
    else
        pre_count=0
    fi

    post_count="$(_count_grounded "$post_file")"

    delta=$(( post_count - pre_count ))
    improved=0
    if (( pre_count == 0 && post_count > 0 )); then
        improved=1
        _improved_fixtures=$(( _improved_fixtures + 1 ))
    fi

    _total_fixtures=$(( _total_fixtures + 1 ))

    # Curated subset: check fixture-manifest.json
    is_curated=false
    manifest="$fixture_dir/fixture-manifest.json"
    if [[ -f "$manifest" ]]; then
        curated_val="$(python3 -c "import json; d=json.load(open('$manifest')); print(str(d.get('curated', False)).lower())")"
        if [[ "$curated_val" == "true" ]]; then
            is_curated=true
            _curated_count=$(( _curated_count + 1 ))
            if (( improved == 1 )); then
                _curated_improved=$(( _curated_improved + 1 ))
            fi

            # Count speculation markers pre/post for curated fixtures
            if [[ -f "$pre_file" ]]; then
                _pre_spec="$(_count_speculation "$pre_file")"
            else
                _pre_spec=0
            fi
            _post_spec="$(_count_speculation "$post_file")"
            _curated_pre_speculation=$(( _curated_pre_speculation + _pre_spec ))
            _curated_post_speculation=$(( _curated_post_speculation + _post_spec ))
        fi
    fi

    _per_fixture_lines+=("$(printf '  %-40s pre=%d post=%d delta=%+d improved=%d curated=%s' \
        "$fixture_name" "$pre_count" "$post_count" "$delta" "$improved" "$is_curated")")

done < <(_discover_fixtures "$_CORPUS_DIR")

# ---------------------------------------------------------------------------
# Compute summary metrics
# ---------------------------------------------------------------------------
if (( _total_fixtures == 0 )); then
    echo "ERROR: No fixtures found in $_CORPUS_DIR" >&2
    exit 2
fi

_pct_improved=$(( (_improved_fixtures * 100) / _total_fixtures ))
_threshold=60

# Speculation reduction for curated subset
_spec_reduction_pct=0
if (( _curated_pre_speculation > 0 )); then
    _spec_reduction_pct=$(( ((_curated_pre_speculation - _curated_post_speculation) * 100) / _curated_pre_speculation ))
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
echo "=== ci-review-corpus-delta ==="
echo ""
echo "Corpus dir : $_CORPUS_DIR"
echo "Fixtures   : $_total_fixtures"
echo "Improved   : $_improved_fixtures / $_total_fixtures  (${_pct_improved}%)"
echo "Threshold  : ${_threshold}%"
echo ""
echo "Per-fixture breakdown:"
for line in "${_per_fixture_lines[@]}"; do
    echo "$line"
done

echo ""
echo "Curated subset ($_curated_count fixtures):"
echo "  Speculation markers pre-loop : $_curated_pre_speculation"
echo "  Speculation markers post-loop: $_curated_post_speculation"
if (( _curated_pre_speculation > 0 )); then
    echo "  Reduction                    : ${_spec_reduction_pct}%"
else
    echo "  Reduction                    : N/A (pre-loop baseline was 0)"
fi

# ---------------------------------------------------------------------------
# Curated quality assertion
# ---------------------------------------------------------------------------
echo ""
_quality_pass=true
if (( _curated_count > 0 )); then
    # Require either overlap >= 1 grounded finding OR speculation reduction >= 25%
    if (( _curated_post_speculation == 0 && _curated_improved >= 1 )); then
        echo "QUALITY CHECK: PASS (curated grounded findings present and no speculation)"
    elif (( _spec_reduction_pct >= 25 )); then
        echo "QUALITY CHECK: PASS (speculation reduction ${_spec_reduction_pct}% >= 25%)"
    elif (( _curated_improved >= 1 )); then
        echo "QUALITY CHECK: PASS (grounded findings present in curated fixtures)"
    else
        echo "QUALITY CHECK: FAIL (curated subset has no grounded findings AND speculation reduction ${_spec_reduction_pct}% < 25%)"
        _quality_pass=false
    fi
fi

# ---------------------------------------------------------------------------
# Presence assertion
# ---------------------------------------------------------------------------
echo ""
_exit_code=0
if (( _pct_improved >= _threshold )); then
    echo "PRESENCE CHECK: PASS (${_pct_improved}% >= ${_threshold}%)"
else
    echo "PRESENCE CHECK: FAIL (${_pct_improved}% < ${_threshold}% threshold)"
    _exit_code=1
fi

[[ "$_quality_pass" == "false" ]] && _exit_code=1

# ---------------------------------------------------------------------------
# Optional JSON output
# ---------------------------------------------------------------------------
if [[ -n "$_OUTPUT_FILE" ]]; then
    python3 - "$_OUTPUT_FILE" \
        "$_total_fixtures" "$_improved_fixtures" "$_pct_improved" "$_threshold" \
        "$_curated_count" "$_curated_pre_speculation" "$_curated_post_speculation" \
        "$_spec_reduction_pct" "$_exit_code" <<'PYEOF'
import json, sys

out_file = sys.argv[1]
total, improved, pct, threshold, curated, pre_spec, post_spec, spec_red, exit_code = (
    int(x) for x in sys.argv[2:]
)
summary = {
    "total_fixtures": total,
    "improved_fixtures": improved,
    "pct_improved": pct,
    "threshold_pct": threshold,
    "pass": exit_code == 0,
    "curated": {
        "count": curated,
        "pre_loop_speculation": pre_spec,
        "post_loop_speculation": post_spec,
        "speculation_reduction_pct": spec_red,
    },
}
with open(out_file, "w") as f:
    json.dump(summary, f, indent=2)
    f.write("\n")
print(f"Summary written to: {out_file}")
PYEOF
fi

exit "$_exit_code"
