#!/usr/bin/env bash
# tests/scripts/test-write-cycle-ledger.sh
# RED-phase tests for plugins/dso/scripts/write-cycle-ledger.sh
#
# Test set A (S0): current --artifacts-dir/--payload interface
# Test set B (S2): new --epic-id/--cycle-num/--findings-hash interface (RED until task 15dc)
#
# Behaviors under test:
#   A1. test_write_cycle_ledger_creates_file              — happy-path write: correct JSON schema
#   A2. test_write_cycle_ledger_concurrent_safe           — 3 parallel writes: non-corrupt JSON
#   A3. test_write_cycle_ledger_missing_artifacts_dir_fails — exits non-zero when dir invalid
#   A4. test_write_cycle_ledger_invalid_json_fails        — exits non-zero when --payload bad JSON
#   B1. test_write_cycle_ledger_normal_write              — creates ledger with epic_id, cycles[], timestamp_utc
#   B2. test_write_cycle_ledger_appends                   — second write appends (does not overwrite)
#   B3. test_write_cycle_ledger_concurrent                — concurrent writes produce non-corrupt JSON
#   B4. test_write_cycle_ledger_schema_version            — output JSON contains schema_version="1.0.0"
#   B5. test_write_cycle_ledger_ci_reconstruction         — --reconstruct-from-pr sets reconstruction_gaps:true
#   B6. test_write_cycle_ledger_missing_file_reconstruction_gaps — partial PR data sets reconstruction_gaps:true
#
# Usage: bash tests/scripts/test-write-cycle-ledger.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e is intentionally omitted — test functions return non-zero by design
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SCRIPT="$DSO_PLUGIN_DIR/scripts/write-cycle-ledger.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Global cleanup registry — each test appends its temp dir here.
declare -a CLEANUP_DIRS=()
trap 'rm -rf "${CLEANUP_DIRS[@]:-}"' EXIT

# ── Helpers ───────────────────────────────────────────────────────────────────

_make_artifacts_dir() {
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-wcl-XXXXXX")
    CLEANUP_DIRS+=("$tmp")
    echo "$tmp"
}

# Build a fake gh binary that prints a canned PR body.
# Prepend the containing directory to PATH so write-cycle-ledger.sh picks up
# the mock instead of the real gh CLI.
_make_fake_gh() {
    local fakedir comment_line
    fakedir=$(mktemp -d "${TMPDIR:-/tmp}/fake-gh-XXXXXX")
    CLEANUP_DIRS+=("$fakedir")
    comment_line="${1:-DSO-Review-Cycle: 2 findings-hash=aabbcc}"
    cat > "$fakedir/gh" <<GHEOF
#!/usr/bin/env bash
echo "PR body line 1"
echo ""
echo "$comment_line"
GHEOF
    chmod +x "$fakedir/gh"
    echo "$fakedir"
}

# ── Test set A: current --artifacts-dir/--payload interface ──────────────────

# ---------------------------------------------------------------------------
# A1: Happy-path write — file created with correct JSON schema fields
# ---------------------------------------------------------------------------

test_write_cycle_ledger_creates_file() {
    local ARTIFACTS_DIR
    ARTIFACTS_DIR="$(_make_artifacts_dir)"

    local PAYLOAD='{"cycle":1,"findings_summary":{"critical":0,"important":1}}'

    local output exit_code=0
    output=$(WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_DIR" \
        bash "$SCRIPT" \
        --artifacts-dir "$ARTIFACTS_DIR" \
        --payload "$PAYLOAD" 2>&1) || exit_code=$?

    assert_eq "test_write_cycle_ledger_creates_file: exits 0" "0" "$exit_code"

    local ledger_file="$ARTIFACTS_DIR/cycle-ledger.json"

    if [[ -f "$ledger_file" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_write_cycle_ledger_creates_file: cycle-ledger.json not created\n  output: %s\n" "$output" >&2
    fi

    # Validate required top-level schema fields: schema_version, epic_id, cycles
    if [[ -f "$ledger_file" ]]; then
        local schema_ok
        schema_ok=$(python3 - "$ledger_file" <<'PYEOF'
import sys, json
data = json.load(open(sys.argv[1]))
required = {"schema_version", "epic_id", "cycles"}
missing = required - set(data.keys())
if missing:
    print("missing_fields:" + ",".join(sorted(missing)))
else:
    print("ok")
PYEOF
)
        assert_eq "test_write_cycle_ledger_creates_file: schema fields present" "ok" "$schema_ok"

        local cycles_type
        cycles_type=$(python3 - "$ledger_file" <<'PYEOF'
import sys, json
data = json.load(open(sys.argv[1]))
print("list" if isinstance(data.get("cycles"), list) else "not-list")
PYEOF
)
        assert_eq "test_write_cycle_ledger_creates_file: cycles is array" "list" "$cycles_type"
    fi
}

test_write_cycle_ledger_creates_file

# ---------------------------------------------------------------------------
# A2: Concurrent writes do not corrupt the ledger file
# ---------------------------------------------------------------------------

test_write_cycle_ledger_concurrent_safe() {
    local ARTIFACTS_DIR
    ARTIFACTS_DIR="$(_make_artifacts_dir)"

    # Spawn 3 parallel writes; each carries a distinct cycle number
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_DIR" \
        bash "$SCRIPT" --artifacts-dir "$ARTIFACTS_DIR" \
        --payload '{"cycle":1,"findings_summary":{"critical":0}}' 2>/dev/null &
    local pid1=$!

    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_DIR" \
        bash "$SCRIPT" --artifacts-dir "$ARTIFACTS_DIR" \
        --payload '{"cycle":2,"findings_summary":{"critical":1}}' 2>/dev/null &
    local pid2=$!

    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_DIR" \
        bash "$SCRIPT" --artifacts-dir "$ARTIFACTS_DIR" \
        --payload '{"cycle":3,"findings_summary":{"critical":0}}' 2>/dev/null &
    local pid3=$!

    wait $pid1 $pid2 $pid3 2>/dev/null || true

    local ledger_file="$ARTIFACTS_DIR/cycle-ledger.json"

    if [[ ! -f "$ledger_file" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_write_cycle_ledger_concurrent_safe: ledger file not created\n" >&2
        return
    fi

    local json_valid
    json_valid=$(python3 -c "
import sys, json
try:
    data = json.load(open('$ledger_file'))
    print('valid')
except Exception as e:
    print('invalid:' + str(e))
" 2>&1)

    assert_eq "test_write_cycle_ledger_concurrent_safe: file is valid JSON after concurrent writes" "valid" "$json_valid"
}

test_write_cycle_ledger_concurrent_safe

# ---------------------------------------------------------------------------
# A3: Missing / non-writable artifacts dir exits non-zero
# ---------------------------------------------------------------------------

test_write_cycle_ledger_missing_artifacts_dir_fails() {
    local BAD_DIR
    BAD_DIR="/nonexistent-root-$$-$(date +%s)/artifacts"

    local output exit_code=0
    output=$(WORKFLOW_PLUGIN_ARTIFACTS_DIR="$BAD_DIR" \
        bash "$SCRIPT" \
        --artifacts-dir "$BAD_DIR" \
        --payload '{"cycle":1,"findings_summary":{}}' 2>&1) || exit_code=$?

    assert_ne "test_write_cycle_ledger_missing_artifacts_dir_fails: exits non-zero" "0" "$exit_code"
    assert_contains "test_write_cycle_ledger_missing_artifacts_dir_fails: stderr mentions error" \
        "error" "$(echo "$output" | tr '[:upper:]' '[:lower:]')"
}

test_write_cycle_ledger_missing_artifacts_dir_fails

# ---------------------------------------------------------------------------
# A4: Invalid JSON payload exits non-zero
# ---------------------------------------------------------------------------

test_write_cycle_ledger_invalid_json_fails() {
    local ARTIFACTS_DIR
    ARTIFACTS_DIR="$(_make_artifacts_dir)"

    local output exit_code=0
    output=$(WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_DIR" \
        bash "$SCRIPT" \
        --artifacts-dir "$ARTIFACTS_DIR" \
        --payload 'not-valid-json' 2>&1) || exit_code=$?

    assert_ne "test_write_cycle_ledger_invalid_json_fails: exits non-zero" "0" "$exit_code"
}

test_write_cycle_ledger_invalid_json_fails

# ── Test set B: new --epic-id/--cycle-num/--findings-hash interface ───────────
# (RED until write-cycle-ledger.sh updated in S2 task 15dc)

# ---------------------------------------------------------------------------
# B1: Normal write creates ledger with epic_id, cycles[], timestamp_utc
# ---------------------------------------------------------------------------

test_write_cycle_ledger_normal_write() {
    if [ ! -f "$SCRIPT" ]; then
        assert_eq "write-cycle-ledger.sh exists" "exists" "missing"
        return
    fi

    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"

    local exit_code=0
    bash "$SCRIPT" \
        --epic-id=epic-123 \
        --cycle-num=1 \
        --findings-hash=abc123 || exit_code=$?

    assert_eq "normal write exits 0" "0" "$exit_code"

    local ledger_file="$artifacts_dir/cycle-ledger.json"
    if [ ! -f "$ledger_file" ]; then
        assert_eq "cycle-ledger.json created" "found" "missing"
        return
    fi

    local parse_exit=0
    python3 -c "import json; json.load(open('$ledger_file'))" 2>/dev/null || parse_exit=$?
    assert_eq "cycle-ledger.json is valid JSON" "0" "$parse_exit"

    local epic_id
    epic_id=$(python3 -c "import json; d=json.load(open('$ledger_file')); print(d.get('epic_id','missing'))" 2>/dev/null || echo "parse-error")
    assert_eq "epic_id is epic-123" "epic-123" "$epic_id"

    local cycle_count
    cycle_count=$(python3 -c "import json; d=json.load(open('$ledger_file')); print(len(d.get('cycles',[])))" 2>/dev/null || echo "0")
    assert_eq "cycles array has 1 entry" "1" "$cycle_count"

    local cycle_num
    cycle_num=$(python3 -c "import json; d=json.load(open('$ledger_file')); print(d['cycles'][0].get('cycle_num','missing'))" 2>/dev/null || echo "parse-error")
    assert_eq "cycle_num is 1" "1" "$cycle_num"

    local findings_hash
    findings_hash=$(python3 -c "import json; d=json.load(open('$ledger_file')); print(d['cycles'][0].get('findings_hash','missing'))" 2>/dev/null || echo "parse-error")
    assert_eq "findings_hash is abc123" "abc123" "$findings_hash"

    local ts
    ts=$(python3 -c "import json; d=json.load(open('$ledger_file')); print(d['cycles'][0].get('timestamp_utc',''))" 2>/dev/null || echo "")
    assert_ne "timestamp_utc is non-empty" "" "$ts"
}
test_write_cycle_ledger_normal_write

# ---------------------------------------------------------------------------
# B2: Second write appends (does not overwrite)
# ---------------------------------------------------------------------------

test_write_cycle_ledger_appends() {
    if [ ! -f "$SCRIPT" ]; then
        assert_eq "write-cycle-ledger.sh exists for append test" "exists" "missing"
        return
    fi

    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"

    bash "$SCRIPT" \
        --epic-id=epic-123 \
        --cycle-num=1 \
        --findings-hash=abc123 2>/dev/null || true

    local exit_code=0
    bash "$SCRIPT" \
        --epic-id=epic-123 \
        --cycle-num=2 \
        --findings-hash=def456 || exit_code=$?

    assert_eq "second write exits 0" "0" "$exit_code"

    local ledger_file="$artifacts_dir/cycle-ledger.json"
    if [ ! -f "$ledger_file" ]; then
        assert_eq "cycle-ledger.json exists after second write" "found" "missing"
        return
    fi

    local cycle_count
    cycle_count=$(python3 -c "import json; d=json.load(open('$ledger_file')); print(len(d.get('cycles',[])))" 2>/dev/null || echo "0")
    assert_eq "cycles array has 2 entries after append" "2" "$cycle_count"

    local cycle_nums
    cycle_nums=$(python3 -c "import json; d=json.load(open('$ledger_file')); print(','.join(str(c.get('cycle_num','?')) for c in d.get('cycles',[])))" 2>/dev/null || echo "")
    assert_eq "cycle_num sequence is 1,2" "1,2" "$cycle_nums"
}
test_write_cycle_ledger_appends

# ---------------------------------------------------------------------------
# B3: Concurrent writes produce no corruption
# ---------------------------------------------------------------------------

test_write_cycle_ledger_concurrent() {
    if [ ! -f "$SCRIPT" ]; then
        assert_eq "write-cycle-ledger.sh exists for concurrent test" "exists" "missing"
        return
    fi

    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"

    bash "$SCRIPT" --epic-id=epic-123 --cycle-num=1 --findings-hash=hash1 2>/dev/null &
    local pid1=$!
    bash "$SCRIPT" --epic-id=epic-123 --cycle-num=2 --findings-hash=hash2 2>/dev/null &
    local pid2=$!

    local e1=0 e2=0
    wait "$pid1" || e1=$?
    wait "$pid2" || e2=$?

    assert_eq "first concurrent write exits 0" "0" "$e1"
    assert_eq "second concurrent write exits 0" "0" "$e2"

    local ledger_file="$artifacts_dir/cycle-ledger.json"
    if [ ! -f "$ledger_file" ]; then
        assert_eq "cycle-ledger.json written after concurrent writes" "found" "missing"
        return
    fi

    local parse_exit=0
    python3 -c "import json; json.load(open('$ledger_file'))" 2>/dev/null || parse_exit=$?
    assert_eq "cycle-ledger.json is parseable after concurrent writes" "0" "$parse_exit"

    local cycle_count
    cycle_count=$(python3 -c "import json; d=json.load(open('$ledger_file')); print(len(d.get('cycles',[])))" 2>/dev/null || echo "0")
    assert_eq "concurrent writes produce 2 cycle entries" "2" "$cycle_count"

    local dup_count
    dup_count=$(python3 -c "
import json
d = json.load(open('$ledger_file'))
nums = [c.get('cycle_num') for c in d.get('cycles', [])]
print(len(nums) - len(set(nums)))
" 2>/dev/null || echo "error")
    assert_eq "no duplicate cycle_num values" "0" "$dup_count"
}
test_write_cycle_ledger_concurrent

# ---------------------------------------------------------------------------
# B4: schema_version field equals "1.0.0"
# ---------------------------------------------------------------------------

test_write_cycle_ledger_schema_version() {
    if [ ! -f "$SCRIPT" ]; then
        assert_eq "write-cycle-ledger.sh exists for schema_version test" "exists" "missing"
        return
    fi

    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"

    local exit_code=0
    bash "$SCRIPT" \
        --epic-id=epic-777 \
        --cycle-num=1 \
        --findings-hash=aaa111 || exit_code=$?

    assert_eq "write exits 0 for schema_version check" "0" "$exit_code"

    local ledger_file="$artifacts_dir/cycle-ledger.json"
    if [ ! -f "$ledger_file" ]; then
        assert_eq "cycle-ledger.json exists for schema_version check" "found" "missing"
        return
    fi

    local schema_version
    schema_version=$(python3 -c "import json; d=json.load(open('$ledger_file')); print(d.get('schema_version','missing'))" 2>/dev/null || echo "parse-error")
    assert_eq "schema_version is 1.0.0" "1.0.0" "$schema_version"
}
test_write_cycle_ledger_schema_version

# ---------------------------------------------------------------------------
# B5: CI reconstruction path sets reconstruction_gaps:true
# ---------------------------------------------------------------------------

test_write_cycle_ledger_ci_reconstruction() {
    if [ ! -f "$SCRIPT" ]; then
        assert_eq "write-cycle-ledger.sh exists for CI reconstruction test" "exists" "missing"
        return
    fi

    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"

    local fake_gh_dir
    fake_gh_dir=$(_make_fake_gh "DSO-Review-Cycle: 2 findings-hash=aabbcc")
    local orig_path="$PATH"
    PATH="$fake_gh_dir:$PATH"
    export DSO_CI_REVIEW_PR="42"

    local exit_code=0
    bash "$SCRIPT" \
        --epic-id=epic-999 \
        --cycle-num=1 \
        --findings-hash=aabbcc \
        --reconstruct-from-pr || exit_code=$?

    PATH="$orig_path"
    unset DSO_CI_REVIEW_PR

    assert_eq "CI reconstruction exits 0" "0" "$exit_code"

    local ledger_file="$artifacts_dir/cycle-ledger.json"
    if [ ! -f "$ledger_file" ]; then
        assert_eq "cycle-ledger.json written during CI reconstruction" "found" "missing"
        return
    fi

    local reconstruction_gaps
    reconstruction_gaps=$(python3 -c "
import json
d = json.load(open('$ledger_file'))
val = d.get('reconstruction_gaps')
print('true' if val is True else str(val))
" 2>/dev/null || echo "parse-error")
    assert_eq "reconstruction_gaps is true after PR reconstruction" "true" "$reconstruction_gaps"

    local cycle_count
    cycle_count=$(python3 -c "import json; d=json.load(open('$ledger_file')); print(len(d.get('cycles',[])))" 2>/dev/null || echo "0")
    assert_ne "cycles array is non-empty after reconstruction" "0" "$cycle_count"
}
test_write_cycle_ledger_ci_reconstruction

# ---------------------------------------------------------------------------
# B6: Partial reconstruction (missing findings_hash) also sets gaps
# ---------------------------------------------------------------------------

test_write_cycle_ledger_missing_file_reconstruction_gaps() {
    if [ ! -f "$SCRIPT" ]; then
        assert_eq "write-cycle-ledger.sh exists for partial reconstruction test" "exists" "missing"
        return
    fi

    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"

    local fake_gh_dir
    fake_gh_dir=$(_make_fake_gh "DSO-Review-Cycle: 1")
    local orig_path="$PATH"
    PATH="$fake_gh_dir:$PATH"
    export DSO_CI_REVIEW_PR="43"

    local exit_code=0
    bash "$SCRIPT" \
        --epic-id=epic-999 \
        --cycle-num=1 \
        --findings-hash=latest \
        --reconstruct-from-pr || exit_code=$?

    PATH="$orig_path"
    unset DSO_CI_REVIEW_PR

    assert_eq "partial reconstruction exits 0 (gaps non-blocking)" "0" "$exit_code"

    local ledger_file="$artifacts_dir/cycle-ledger.json"
    if [ ! -f "$ledger_file" ]; then
        assert_eq "cycle-ledger.json written during partial reconstruction" "found" "missing"
        return
    fi

    local reconstruction_gaps
    reconstruction_gaps=$(python3 -c "
import json
d = json.load(open('$ledger_file'))
val = d.get('reconstruction_gaps')
print('true' if val is True else str(val))
" 2>/dev/null || echo "parse-error")
    assert_eq "reconstruction_gaps is true for partial data" "true" "$reconstruction_gaps"
}
test_write_cycle_ledger_missing_file_reconstruction_gaps

print_summary
