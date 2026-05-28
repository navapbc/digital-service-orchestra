#!/usr/bin/env bash
# tests/scripts/test-cross-epic-scan-prep.sh
# Behavioral tests for plugins/dso/scripts/cross-epic-scan-prep.sh — the
# Step 2.25 setup-pipeline extraction that prevents the brainstorm
# orchestrator from absorbing every candidate epic's content (e253-f62a).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PREP="$REPO_ROOT/plugins/dso/scripts/cross-epic-scan-prep.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

TMPDIR_T=$(mktemp -d "${TMPDIR:-/tmp}/test-cross-epic-prep.XXXXXX")
trap 'rm -rf "$TMPDIR_T"' EXIT

# --- Stub ticket CLI: emits canned ticket list / ticket show responses ---
mkdir -p "$TMPDIR_T/stub-bin"
cat > "$TMPDIR_T/stub-bin/ticket" <<EOF
#!/usr/bin/env bash
# Stub ticket CLI. Supports:
#   list --type=epic --status=open,in_progress --format=llm  → emit fixture
#   show <id>                                                → emit fixture
case "\$1" in
    list)
        cat "$TMPDIR_T/list-fixture.ndjson" 2>/dev/null
        ;;
    show)
        cat "$TMPDIR_T/show-\$2.json" 2>/dev/null
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$TMPDIR_T/stub-bin/ticket"
export DSO_TICKET_CMD="$TMPDIR_T/stub-bin/ticket"

# Helper: write a new_epic payload file
_make_new_epic() {
    local path="$1" id="$2"
    cat > "$path" <<JSONEOF
{"id":"$id","title":"new epic title","approach_summary":"build a thing","success_criteria":["sc1","sc2"]}
JSONEOF
}

# Helper: write a ticket show fixture
_make_epic_fixture() {
    local id="$1" approach="$2" sc_lines="$3"
    cat > "$TMPDIR_T/show-$id.json" <<JSONEOF
{"id":"$id","title":"Epic $id","description":"## Approach\n$approach\n\n## Success Criteria\n$sc_lines"}
JSONEOF
}

# --- Test 1: zero candidates → STATUS=skipped:no_candidates ---
: > "$TMPDIR_T/list-fixture.ndjson"
NEW_EPIC="$TMPDIR_T/new-epic.json"
_make_new_epic "$NEW_EPIC" "new-001-aaaa-bbbb"
OUT1="$TMPDIR_T/out1"
RESULT=$(bash "$PREP" --epic-id new-001-aaaa-bbbb --new-epic-payload "$NEW_EPIC" --out-dir "$OUT1" 2>&1)
assert_contains "zero_candidates_status" "STATUS=skipped:no_candidates" "$RESULT"
assert_contains "zero_candidates_count" "CANDIDATE_COUNT=0" "$RESULT"
assert_contains "zero_candidates_batches" "BATCH_COUNT=0" "$RESULT"

# --- Test 2: filters out the current epic ---
cat > "$TMPDIR_T/list-fixture.ndjson" <<EOF
{"id":"new-001-aaaa-bbbb","t":"epic","ttl":"current","st":"open"}
{"id":"other-002-cccc-dddd","t":"epic","ttl":"other","st":"open"}
EOF
_make_epic_fixture "other-002-cccc-dddd" "other approach text" "- crit one\n- crit two"
OUT2="$TMPDIR_T/out2"
RESULT=$(bash "$PREP" --epic-id new-001-aaaa-bbbb --new-epic-payload "$NEW_EPIC" --out-dir "$OUT2" 2>&1)
assert_contains "filters_self_status" "STATUS=ok" "$RESULT"
assert_contains "filters_self_count_1" "CANDIDATE_COUNT=1" "$RESULT"
assert_contains "filters_self_batches_1" "BATCH_COUNT=1" "$RESULT"

# --- Test 3: batching honors --batch-size ---
{
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        printf '{"id":"epic-%03d-xxxx-yyyy","t":"epic","ttl":"e%d","st":"open"}\n' "$i" "$i"
    done
} > "$TMPDIR_T/list-fixture.ndjson"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    id=$(printf 'epic-%03d-xxxx-yyyy' "$i")
    _make_epic_fixture "$id" "approach $i" "- sc one\n- sc two"
done
OUT3="$TMPDIR_T/out3"
RESULT=$(bash "$PREP" --epic-id new-001-aaaa-bbbb --new-epic-payload "$NEW_EPIC" --out-dir "$OUT3" --batch-size 5 2>&1)
assert_contains "batches_12_into_3" "BATCH_COUNT=3" "$RESULT"
# Verify the batch files exist
BATCH_FILES=$(grep "^BATCH_FILES=" <<<"$RESULT" | sed 's/^BATCH_FILES=//')
IFS=',' read -r -a _arr <<<"$BATCH_FILES"
if [[ ${#_arr[@]} -eq 3 ]]; then (( ++PASS )); else (( ++FAIL )); echo "FAIL: expected 3 batch files, got ${#_arr[@]}" >&2; fi

# Guard array access — `set -u` would crash on indexed access into an empty
# array. Skip downstream shape checks if the prior assertion failed.
if [[ ${#_arr[@]} -lt 3 ]]; then
    (( ++FAIL ))
    echo "FAIL: insufficient batch files for shape checks (got ${#_arr[@]})" >&2
    print_summary
fi

if [[ -f "${_arr[0]}" ]]; then (( ++PASS )); else (( ++FAIL )); echo "FAIL: first batch file does not exist: ${_arr[0]}" >&2; fi

# Verify a batch file has the expected shape
FIRST_BATCH=$(cat "${_arr[0]}")
COUNT=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(len(d.get('open_epics',[])))" "$FIRST_BATCH")
assert_eq "batch1_has_5_open_epics" "5" "$COUNT"

LAST_BATCH=$(cat "${_arr[2]}")
COUNT=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(len(d.get('open_epics',[])))" "$LAST_BATCH")
assert_eq "batch3_has_2_open_epics" "2" "$COUNT"

NEW_EPIC_IN_BATCH=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('new_epic',{}).get('id',''))" "$FIRST_BATCH")
assert_eq "batch1_carries_new_epic" "new-001-aaaa-bbbb" "$NEW_EPIC_IN_BATCH"

# --- Test 4: parses approach_summary + success_criteria correctly ---
EPIC_IN_BATCH=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); e=d['open_epics'][0]; print(e['approach_summary']+'|'+'/'.join(e['success_criteria']))" "$FIRST_BATCH")
if [[ "$EPIC_IN_BATCH" == *"approach"* ]]; then (( ++PASS )); else (( ++FAIL )); echo "FAIL: approach_summary not parsed: '$EPIC_IN_BATCH'" >&2; fi
if [[ "$EPIC_IN_BATCH" == *"sc one"* && "$EPIC_IN_BATCH" == *"sc two"* ]]; then (( ++PASS )); else (( ++FAIL )); echo "FAIL: success_criteria not parsed: '$EPIC_IN_BATCH'" >&2; fi

# --- Test 4b: usage-paused path (MAX_AGENTS=0 from injected lifecycle stub) ---
# Reuses the 12-epic list fixture from Test 3. Stubs agent-batch-lifecycle.sh
# via DSO_AGENT_BATCH_LIFECYCLE to emit MAX_AGENTS: 0 — the prep script must
# return STATUS=skipped:usage_paused and BATCH_COUNT=0 without writing
# batch files.
cat > "$TMPDIR_T/stub-bin/usage-paused.sh" <<'EOF'
#!/usr/bin/env bash
echo "MAX_AGENTS: 0"
EOF
chmod +x "$TMPDIR_T/stub-bin/usage-paused.sh"
OUT_PAUSED="$TMPDIR_T/out-paused"
RESULT=$(DSO_AGENT_BATCH_LIFECYCLE="$TMPDIR_T/stub-bin/usage-paused.sh" \
    bash "$PREP" --epic-id new-001-aaaa-bbbb --new-epic-payload "$NEW_EPIC" --out-dir "$OUT_PAUSED" 2>&1)
assert_contains "usage_paused_status" "STATUS=skipped:usage_paused" "$RESULT"
assert_contains "usage_paused_max_agents" "MAX_AGENTS=0" "$RESULT"
assert_contains "usage_paused_batches_0" "BATCH_COUNT=0" "$RESULT"
# No batch files should have been written
if [[ -z "$(find "$OUT_PAUSED" -name 'batch_*.json' 2>/dev/null)" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: batch files written despite usage-paused: $(find "$OUT_PAUSED" -name 'batch_*.json')" >&2
fi

# --- Test 5: usage error paths ---
EXIT=0
bash "$PREP" 2>/dev/null || EXIT=$?
assert_eq "no_args_exits_2" "2" "$EXIT"

EXIT=0
bash "$PREP" --epic-id foo 2>/dev/null || EXIT=$?
assert_eq "missing_new_epic_payload_exits_2" "2" "$EXIT"

EXIT=0
bash "$PREP" --epic-id foo --new-epic-payload /nonexistent --out-dir "$TMPDIR_T/out5" 2>/dev/null || EXIT=$?
assert_eq "missing_payload_file_exits_2" "2" "$EXIT"

# --- Test 6: timeout on one candidate → skip it, return STATUS=ok ---
# Reproduces bug 3c02-08d5: when `ticket show` hangs past the deadline on
# a single bloated-event-log ticket, the previous code raised
# subprocess.TimeoutExpired uncaught and crashed the whole scan. With the
# fix, the timed-out ticket is skipped (returns None, same as JSONDecodeError
# / non-zero exit) and the remaining candidates appear in the batch.
#
# Uses DSO_TICKET_SHOW_TIMEOUT_SECS=1 so the test takes ~2s, not ~30s.
# The stub sleeps 2s for ID "slow-001-aaaa-bbbb" and returns immediately
# for all other IDs.
{
    REPO_TIMEOUT_DIR="$TMPDIR_T/timeout-stub-bin"
    mkdir -p "$REPO_TIMEOUT_DIR"
    cat > "$REPO_TIMEOUT_DIR/ticket" <<EOF
#!/usr/bin/env bash
case "\$1" in
    list)
        cat "$TMPDIR_T/list-fixture.ndjson" 2>/dev/null
        ;;
    show)
        if [[ "\$2" == "slow-001-aaaa-bbbb" ]]; then
            sleep 2
            exit 0
        fi
        cat "$TMPDIR_T/show-\$2.json" 2>/dev/null
        ;;
    *)
        exit 1
        ;;
esac
EOF
    chmod +x "$REPO_TIMEOUT_DIR/ticket"

    # List fixture: one slow ticket + one fast ticket.
    cat > "$TMPDIR_T/list-fixture.ndjson" <<EOF
{"id":"slow-001-aaaa-bbbb","t":"epic","ttl":"slow","st":"open"}
{"id":"fast-002-cccc-dddd","t":"epic","ttl":"fast","st":"open"}
EOF
    _make_epic_fixture "fast-002-cccc-dddd" "fast approach" "- sc fast"
    # Note: no show-slow-001*.json — the stub sleeps instead, triggering
    # subprocess.TimeoutExpired in the parent.

    OUT_TIMEOUT="$TMPDIR_T/out-timeout"
    RESULT=$(DSO_TICKET_CMD="$REPO_TIMEOUT_DIR/ticket" \
        DSO_TICKET_SHOW_TIMEOUT_SECS=1 \
        bash "$PREP" --epic-id new-001-aaaa-bbbb --new-epic-payload "$NEW_EPIC" --out-dir "$OUT_TIMEOUT" 2>&1)

    # Bug 3c02 regression check:
    # Status must be ok (scan did NOT crash on the timeout — that was the bug).
    assert_contains "timeout_skipped_status_ok" "STATUS=ok" "$RESULT"

    # Verify only the FAST ticket appears in the batch output — the slow
    # one timed out and was correctly dropped to None. CANDIDATE_COUNT is
    # the pre-filter list size (still 2); the evidence of skipping lives
    # in the batch's open_epics array.
    BATCH_FILES=$(grep "^BATCH_FILES=" <<<"$RESULT" | sed 's/^BATCH_FILES=//')
    if [[ -n "$BATCH_FILES" ]]; then
        FIRST_BATCH=$(cat "${BATCH_FILES%%,*}")
        OPEN_EPICS_COUNT=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(len(d.get('open_epics',[])))" "$FIRST_BATCH")
        SURVIVING_IDS=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(','.join(e.get('id','') for e in d.get('open_epics',[])))" "$FIRST_BATCH")
        assert_eq "timeout_skipped_batch_contains_one_epic" "1" "$OPEN_EPICS_COUNT"
        assert_eq "timeout_skipped_surviving_is_fast" "fast-002-cccc-dddd" "$SURVIVING_IDS"
    else
        (( ++FAIL ))
        echo "FAIL: no BATCH_FILES emitted for timeout-recovery scenario" >&2
    fi
}

print_summary
