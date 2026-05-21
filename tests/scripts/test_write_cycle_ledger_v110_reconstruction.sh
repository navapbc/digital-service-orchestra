#!/usr/bin/env bash
# Manual verification of v1.1.0 reconstruction-marker parsing in
# write-cycle-ledger.sh. Confirms:
#   - extended v1.1.0 marker yields commit_sha + findings populated
#   - legacy v1.0.0 marker yields commit_sha="" + findings=[] + gap=true
#   - current cycle entry is appended with the args we passed in
#
# Kept separate from test_write_cycle_ledger_v110.sh because it requires a
# fake `gh` binary on PATH.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-wcl-recon-v110-XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/fake-gh"
cat > "$TEST_DIR/fake-gh/gh" <<'GHEOF'
#!/usr/bin/env bash
echo "PR body line 1"
echo ""
echo 'DSO-Review-Cycle: 2 commit_sha=abc1234567890abc1234567890abc12345678901 findings_hash=h2 tuples=[["src/x.py","10","correctness"]]'
echo 'DSO-Review-Cycle: 1 findings-hash=h1'
GHEOF
chmod +x "$TEST_DIR/fake-gh/gh"

export PATH="$TEST_DIR/fake-gh:$PATH"
export DSO_CI_REVIEW_PR=42
export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$TEST_DIR/artifacts"
mkdir -p "$WORKFLOW_PLUGIN_ARTIFACTS_DIR"

bash "$REPO_ROOT/plugins/dso/scripts/write-cycle-ledger.sh" \
    --epic-id epic-foo --cycle-num 3 --findings-hash h3 \
    --commit-sha bbb2345678901bbb2345678901bbb234567890bb \
    --findings '[["src/y.py","20-22","security"]]' \
    --reconstruct-from-pr >/dev/null 2>&1

LEDGER="$WORKFLOW_PLUGIN_ARTIFACTS_DIR/cycle-ledger.json"

PASS=0
FAIL=0
check() {
    if eval "$2"; then
        echo "PASS: $1"; ((PASS++))
    else
        echo "FAIL: $1"; ((FAIL++))
    fi
}

[[ -f "$LEDGER" ]] || { echo "FAIL: ledger not written"; exit 1; }

check "schema_version is 1.2.0" \
    "[[ \$(python3 -c \"import json; print(json.load(open('$LEDGER'))['schema_version'])\") == '1.2.0' ]]"

check "reconstruction_gaps is true (v1.0.0 marker triggered gap)" \
    "[[ \$(python3 -c \"import json; d=json.load(open('$LEDGER')); print(d.get('reconstruction_gaps'))\") == 'True' ]]"

check "cycles array has 3 entries (2 recovered + 1 appended)" \
    "[[ \$(python3 -c \"import json; print(len(json.load(open('$LEDGER'))['cycles']))\") == '3' ]]"

check "v1.1.0 marker round-trip: commit_sha for cycle 2 is populated" \
    "[[ \$(python3 -c \"import json; d=json.load(open('$LEDGER')); c=[x for x in d['cycles'] if x['cycle_num']==2][0]; print(c.get('commit_sha',''))\") == 'abc1234567890abc1234567890abc12345678901' ]]"

check "v1.1.0 marker round-trip: tuples for cycle 2 are populated" \
    "[[ \$(python3 -c \"import json; d=json.load(open('$LEDGER')); c=[x for x in d['cycles'] if x['cycle_num']==2][0]; print(json.dumps(c.get('findings')))\") == '[[\"src/x.py\", \"10\", \"correctness\"]]' ]]"

check "legacy v1.0.0 marker: commit_sha empty for cycle 1" \
    "[[ \$(python3 -c \"import json; d=json.load(open('$LEDGER')); c=[x for x in d['cycles'] if x['cycle_num']==1][0]; print(repr(c.get('commit_sha','')))\") == \"''\" ]]"

check "legacy v1.0.0 marker: findings empty for cycle 1" \
    "[[ \$(python3 -c \"import json; d=json.load(open('$LEDGER')); c=[x for x in d['cycles'] if x['cycle_num']==1][0]; print(json.dumps(c.get('findings')))\") == '[]' ]]"

check "appended cycle 3 carries our --commit-sha" \
    "[[ \$(python3 -c \"import json; d=json.load(open('$LEDGER')); c=[x for x in d['cycles'] if x['cycle_num']==3][0]; print(c['commit_sha'])\") == 'bbb2345678901bbb2345678901bbb234567890bb' ]]"

check "appended cycle 3 carries our --findings" \
    "[[ \$(python3 -c \"import json; d=json.load(open('$LEDGER')); c=[x for x in d['cycles'] if x['cycle_num']==3][0]; print(json.dumps(c['findings']))\") == '[[\"src/y.py\", \"20-22\", \"security\"]]' ]]"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
