#!/usr/bin/env bash
# tests/scripts/test-emit-protocol-review-result.sh
# RED tests for plugins/dso/scripts/emit-protocol-review-result.sh (does NOT exist yet).
#
# Covers: full-field JSONL output, brainstorm-fidelity review type, missing
# review-protocol-output.json, finding count extraction, and graceful failure
# when emit-review-event.sh itself fails.
#
# Usage: bash tests/scripts/test-emit-protocol-review-result.sh

# NOTE: -e is intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
EMIT_SCRIPT="$REPO_ROOT/plugins/dso/scripts/emit-protocol-review-result.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

_CLEANUP_DIRS=()

cleanup() {
    for d in "${_CLEANUP_DIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap cleanup EXIT

echo "=== test-emit-protocol-review-result.sh ==="

# ── Helper: create a fixture review-protocol-output.json ──────────────────────
# Writes a minimal but valid review protocol output to the given path.
# Args: $1 = target file path, $2 = critical count (default 0), $3 = minor count (default 0)
_write_review_protocol_fixture() {
    local target="$1"
    local critical="${2:-0}"
    local minor="${3:-0}"
    python3 -c "
import json, sys

critical = int(sys.argv[1])
minor = int(sys.argv[2])

findings = []
for i in range(critical):
    findings.append({
        'perspective': 'correctness',
        'severity': 'critical',
        'description': f'Critical finding {i+1}',
        'recommendation': 'Fix it'
    })
for i in range(minor):
    findings.append({
        'perspective': 'maintainability',
        'severity': 'minor',
        'description': f'Minor finding {i+1}',
        'recommendation': 'Consider improving'
    })

data = {
    'schema_version': 1,
    'perspectives': ['correctness', 'feasibility', 'maintainability'],
    'dimensions': {
        'correctness': {'score': 8, 'rationale': 'Looks good'},
        'feasibility': {'score': 7, 'rationale': 'Achievable'},
        'maintainability': {'score': 6, 'rationale': 'Acceptable'}
    },
    'findings': findings,
    'overall_score': 7,
    'pass': True,
    'revision_count': 0
}
with open(sys.argv[3], 'w') as f:
    json.dump(data, f)
" "$critical" "$minor" "$target"
}

# ── Test 1: emit with all fields ──────────────────────────────────────────────
echo "Test 1: emit-protocol-review-result.sh writes valid JSONL with all fields"
test_emit_protocol_review_all_fields() {
    if [ ! -f "$EMIT_SCRIPT" ]; then
        assert_eq "emit-protocol-review-result.sh exists" "exists" "missing"
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$tmpdir"

    # Write fixture review-protocol-output.json
    _write_review_protocol_fixture "$tmpdir/review-protocol-output.json" 0 0

    # Call the wrapper with CLI args
    local exit_code=0
    local output
    output=$(bash "$EMIT_SCRIPT" \
        --review-type=implementation-plan \
        --pass-fail=passed \
        --revision-cycles=1 2>&1) || exit_code=$?

    assert_eq "emit exits zero" "0" "$exit_code"

    # Parse JSONL output and verify all expected fields
    local check_result
    check_result=$(python3 -c "
import json, sys
line = sys.argv[1].strip()
if not line:
    print('no-output')
    sys.exit(0)
data = json.loads(line)
required = ['event_type', 'review_type', 'pass_fail', 'revision_cycles',
            'overall_score', 'finding_counts_by_severity', 'timestamp']
missing = [k for k in required if k not in data]
if missing:
    print('missing:' + ','.join(missing))
else:
    print('all-present')
" "$output" 2>/dev/null || echo "parse-error")

    assert_eq "all required fields present" "all-present" "$check_result"

    # Verify review_type value
    local review_type
    review_type=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1].strip())
print(data.get('review_type', 'missing'))
" "$output" 2>/dev/null || echo "parse-error")

    assert_eq "review_type is implementation-plan" "implementation-plan" "$review_type"
}
test_emit_protocol_review_all_fields

# ── Test 2: brainstorm-fidelity review type ───────────────────────────────────
echo "Test 2: emit-protocol-review-result.sh sets review_type=brainstorm-fidelity"
test_emit_protocol_review_brainstorm_fidelity() {
    if [ ! -f "$EMIT_SCRIPT" ]; then
        assert_eq "emit-protocol-review-result.sh exists for brainstorm-fidelity test" "exists" "missing"
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$tmpdir"

    _write_review_protocol_fixture "$tmpdir/review-protocol-output.json" 0 0

    local exit_code=0
    local output
    output=$(bash "$EMIT_SCRIPT" \
        --review-type=brainstorm-fidelity \
        --pass-fail=passed \
        --revision-cycles=0 2>&1) || exit_code=$?

    assert_eq "emit exits zero for brainstorm-fidelity" "0" "$exit_code"

    local review_type
    review_type=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1].strip())
print(data.get('review_type', 'missing'))
" "$output" 2>/dev/null || echo "parse-error")

    assert_eq "review_type is brainstorm-fidelity" "brainstorm-fidelity" "$review_type"
}
test_emit_protocol_review_brainstorm_fidelity

# ── Test 3: missing review-protocol-output.json is a no-op (exit 0) ──────────
echo "Test 3: emit-protocol-review-result.sh exits 0 (no-op) when review-protocol-output.json missing"
test_emit_protocol_review_missing_output_noop() {
    if [ ! -f "$EMIT_SCRIPT" ]; then
        assert_eq "emit-protocol-review-result.sh exists for missing-output test" "exists" "missing"
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$tmpdir"

    # Do NOT write review-protocol-output.json

    local exit_code=0
    bash "$EMIT_SCRIPT" \
        --review-type=implementation-plan \
        --pass-fail=passed \
        --revision-cycles=0 2>/dev/null || exit_code=$?

    assert_eq "exits zero (no-op) without review-protocol-output.json" "0" "$exit_code"
}
test_emit_protocol_review_missing_output_noop

# ── Test 4: finding counts by severity ────────────────────────────────────────
echo "Test 4: emit-protocol-review-result.sh extracts finding_counts_by_severity"
test_emit_protocol_review_finding_counts() {
    if [ ! -f "$EMIT_SCRIPT" ]; then
        assert_eq "emit-protocol-review-result.sh exists for finding-counts test" "exists" "missing"
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$tmpdir"

    # Fixture with 2 critical + 1 minor findings
    _write_review_protocol_fixture "$tmpdir/review-protocol-output.json" 2 1

    local exit_code=0
    local output
    output=$(bash "$EMIT_SCRIPT" \
        --review-type=implementation-plan \
        --pass-fail=failed \
        --revision-cycles=2 2>&1) || exit_code=$?

    assert_eq "emit exits zero for finding-counts test" "0" "$exit_code"

    # Check critical=2
    local critical_count
    critical_count=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1].strip())
counts = data.get('finding_counts_by_severity', {})
print(counts.get('critical', 'missing'))
" "$output" 2>/dev/null || echo "parse-error")

    assert_eq "critical finding count is 2" "2" "$critical_count"

    # Check minor=1
    local minor_count
    minor_count=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1].strip())
counts = data.get('finding_counts_by_severity', {})
print(counts.get('minor', 'missing'))
" "$output" 2>/dev/null || echo "parse-error")

    assert_eq "minor finding count is 1" "1" "$minor_count"
}
test_emit_protocol_review_finding_counts

# ── Test 5: graceful failure when emit-review-event.sh fails ──────────────────
echo "Test 5: emit-protocol-review-result.sh handles emit-review-event.sh failure gracefully"
test_emit_protocol_review_emit_failure_graceful() {
    if [ ! -f "$EMIT_SCRIPT" ]; then
        assert_eq "emit-protocol-review-result.sh exists for emit-failure test" "exists" "missing"
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$tmpdir"

    _write_review_protocol_fixture "$tmpdir/review-protocol-output.json" 0 0

    # Create a stub emit-review-event.sh that always fails
    local stub_dir="$tmpdir/stub-bin"
    mkdir -p "$stub_dir"
    cat > "$stub_dir/emit-review-event.sh" <<'STUB'
#!/usr/bin/env bash
echo "STUB: emit-review-event.sh forced failure" >&2
exit 1
STUB
    chmod +x "$stub_dir/emit-review-event.sh"

    # Put stub dir first on PATH so the wrapper finds the failing stub
    local exit_code=0
    local stderr_out
    stderr_out=$(PATH="$stub_dir:$PATH" bash "$EMIT_SCRIPT" \
        --review-type=implementation-plan \
        --pass-fail=passed \
        --revision-cycles=0 2>&1 >/dev/null) || exit_code=$?

    # Script should log a warning but return 0 (graceful degradation)
    assert_eq "exits zero despite emit-review-event.sh failure" "0" "$exit_code"

    # Verify a warning was logged
    assert_contains "warning logged on emit failure" "warn" "$(echo "$stderr_out" | tr '[:upper:]' '[:lower:]')"
}
test_emit_protocol_review_emit_failure_graceful

print_summary
