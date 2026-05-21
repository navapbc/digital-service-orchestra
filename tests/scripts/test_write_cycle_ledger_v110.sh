#!/usr/bin/env bash
# RED test: write-cycle-ledger.sh emits v1.1.0 schema with findings + commit_sha
#
# Verifies the v1.1.0 contract changes:
#   - schema_version bumped 1.0.0 -> 1.1.0
#   - cycle entries carry `findings` (array of [file, line_range, category] tuples)
#   - cycle entries carry `commit_sha` (40-char HEAD SHA, defaults to git HEAD)
#   - --findings defaults to []
#
# The Python-reader interop test (Test 4) is skipped when dso_ci_review.cycle_ledger
# is not yet available — that module is the deliverable of a sibling T1 task in the
# same story. Skipping it here keeps this test executable in isolation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Isolate artifacts dir
TEST_DIR=$(mktemp -d /tmp/test-write-cycle-ledger.XXXXXX)
export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$TEST_DIR"
LEDGER_PATH="$TEST_DIR/cycle-ledger.json"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

run_test() {
    local name="$1" status="$2"
    case "$status" in
        PASS) echo "PASS: $name"; ((PASS_COUNT++)) ;;
        SKIP*) echo "SKIP: $name — ${status#SKIP: }"; ((SKIP_COUNT++)) ;;
        *)    echo "FAIL: $name — $status"; ((FAIL_COUNT++)) ;;
    esac
}

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Test 1-3: emits schema_version 1.1.0 with findings + commit_sha fields
bash "$REPO_ROOT/plugins/dso/scripts/write-cycle-ledger.sh" \
    --epic-id test-epic \
    --cycle-num 1 \
    --findings-hash dummyhash \
    --commit-sha "abc1234567890abcdef1234567890abcdef12345" \
    --findings '[["src/foo.py","10-20","correctness"]]' >/dev/null 2>&1

if [[ ! -f "$LEDGER_PATH" ]]; then
    run_test "ledger file created" "FAIL: $LEDGER_PATH does not exist"
else
    schema=$(python3 -c "import json; print(json.load(open('$LEDGER_PATH'))['schema_version'])" 2>/dev/null)
    if [[ "$schema" == "1.2.0" ]]; then
        run_test "schema_version == 1.2.0" "PASS"
    else
        run_test "schema_version == 1.2.0" "got $schema"
    fi

    # Test 2: cycle has findings array (and the value we passed in)
    has_findings=$(python3 -c "import json; c=json.load(open('$LEDGER_PATH'))['cycles'][-1]; print('yes' if 'findings' in c else 'no')")
    if [[ "$has_findings" == "yes" ]]; then
        # Also confirm the array was stored as a JSON array, not a string
        findings_val=$(python3 -c "
import json
c = json.load(open('$LEDGER_PATH'))['cycles'][-1]
print(json.dumps(c['findings']))
")
        if [[ "$findings_val" == '[["src/foo.py", "10-20", "correctness"]]' ]]; then
            run_test "cycle has findings field (round-trips correctly)" "PASS"
        else
            run_test "cycle has findings field (round-trips correctly)" "got $findings_val"
        fi
    else
        run_test "cycle has findings field" "missing"
    fi

    # Test 3: cycle has commit_sha (and matches what we passed in)
    sha_val=$(python3 -c "import json; c=json.load(open('$LEDGER_PATH'))['cycles'][-1]; print(c.get('commit_sha',''))")
    if [[ "$sha_val" == "abc1234567890abcdef1234567890abcdef12345" ]]; then
        run_test "cycle has commit_sha field (round-trips correctly)" "PASS"
    else
        run_test "cycle has commit_sha field (round-trips correctly)" "got '$sha_val'"
    fi

    # Test 4: Python reader consumes it (skip if cycle_ledger.py not yet present)
    if python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/plugins/dso/scripts')
import dso_ci_review.cycle_ledger  # noqa: F401
" 2>/dev/null; then
        if python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/plugins/dso/scripts')
from dso_ci_review.cycle_ledger import read_ledger
ledger = read_ledger('$LEDGER_PATH')
assert ledger['schema_version'] == '1.2.0', f'expected 1.2.0, got {ledger[\"schema_version\"]}'
assert len(ledger['cycles']) >= 1, 'no cycles'
got_findings = ledger['cycles'][-1].get('findings')
assert got_findings == [['src/foo.py','10-20','correctness']], f'findings mismatch: {got_findings!r}'
" 2>&1; then
            run_test "Python reader consumes v1.1.0 ledger" "PASS"
        else
            run_test "Python reader consumes v1.1.0 ledger" "Python reader failed"
        fi
    else
        run_test "Python reader consumes v1.1.0 ledger" "SKIP: dso_ci_review.cycle_ledger not yet importable (sibling T1 task)"
    fi
fi

# Test 5: default --commit-sha to git HEAD when not specified
TEST_DIR2=$(mktemp -d /tmp/test-write-cycle-ledger-default.XXXXXX)
WORKFLOW_PLUGIN_ARTIFACTS_DIR="$TEST_DIR2" bash "$REPO_ROOT/plugins/dso/scripts/write-cycle-ledger.sh" \
    --epic-id test-epic-default \
    --cycle-num 1 \
    --findings-hash dummy2 >/dev/null 2>&1
LEDGER2="$TEST_DIR2/cycle-ledger.json"
if [[ -f "$LEDGER2" ]]; then
    sha=$(python3 -c "import json; print(json.load(open('$LEDGER2'))['cycles'][-1].get('commit_sha',''))" 2>/dev/null)
    if [[ -n "$sha" && ${#sha} -eq 40 ]]; then
        run_test "commit_sha defaults to git HEAD (40 chars)" "PASS"
    else
        run_test "commit_sha defaults to git HEAD" "got '$sha' (len=${#sha})"
    fi
else
    run_test "commit_sha defaults to git HEAD" "ledger file not created"
fi
rm -rf "$TEST_DIR2"

# Test 6: --findings defaults to []
TEST_DIR3=$(mktemp -d /tmp/test-write-cycle-ledger-empty.XXXXXX)
WORKFLOW_PLUGIN_ARTIFACTS_DIR="$TEST_DIR3" bash "$REPO_ROOT/plugins/dso/scripts/write-cycle-ledger.sh" \
    --epic-id test-empty \
    --cycle-num 1 \
    --findings-hash dummy3 >/dev/null 2>&1
LEDGER3="$TEST_DIR3/cycle-ledger.json"
if [[ -f "$LEDGER3" ]]; then
    findings=$(python3 -c "import json; print(json.dumps(json.load(open('$LEDGER3'))['cycles'][-1].get('findings')))" 2>/dev/null)
    if [[ "$findings" == "[]" ]]; then
        run_test "findings defaults to []" "PASS"
    else
        run_test "findings defaults to []" "got $findings"
    fi
else
    run_test "findings defaults to []" "ledger file not created"
fi
rm -rf "$TEST_DIR3"

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped"
[[ $FAIL_COUNT -eq 0 ]]
