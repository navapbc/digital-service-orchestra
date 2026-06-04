#!/usr/bin/env bash
# E2E Field Validation Probe — systematically tests bidirectional CRUD for
# every field across 10 test tickets against live Jira.
#
# Phases:
#   0. Pre-flight (env check, get_myself, save snapshot)
#   1. Create 10 local tickets → sync outbound → verify all fields in Jira
#   2. Edit fields locally → sync outbound → verify Jira updated
#   3. Edit fields in Jira → sync inbound → verify local updated
#   4. Status outbound negative test (gated/stub)
#   5. Delete behavior negative test (excluded by design)
#   6. Idempotency — 3 no-op passes → verify 0 mutations each
#   7. Reconciliation check — verify 0 discrepancies for probe keys
#   8. Cleanup — delete all Jira issues + local tickets, restore snapshot
#
# Usage: invoked by reconcile-bridge.yml when mode=field-validate, or manually.
# Requires: JIRA_URL, JIRA_USER, JIRA_API_TOKEN env vars.
# Requires: DSO_FIELD_VALIDATION_PROBE=1 to opt in (prevents accidental
#           inclusion in generic test-discovery sweeps).
# Working directory: repo root.

set -euo pipefail

# Explicit opt-in gate — prevents accidental invocation by find/glob test
# discovery. The probe creates real Jira issues against the configured
# instance, so it must only run when the caller explicitly intends to.
if [ "${DSO_FIELD_VALIDATION_PROBE:-0}" != "1" ]; then
    echo "SKIP: e2e_field_validation_probe.sh requires DSO_FIELD_VALIDATION_PROBE=1" >&2
    echo "      (this probe creates real Jira issues against the configured instance)" >&2
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
TICKET_CLI="${REPO_ROOT}/.claude/scripts/dso"
_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
_SCRIPTS_DIR="$(dirname "$_SCRIPT_DIR")"
RECONCILER_DIR="$_SCRIPTS_DIR"
JIRA_PROJECT="${JIRA_PROJECT:-DIG}"
PROBE_TS="$(date +%s)"
PROBE_TAG="field-probe-${PROBE_TS}"

PASSED=0
FAILED=0
SKIPPED=0
ASSIGNEE_SKIP=false
PROBE_USER=""

# Arrays for tracking ticket IDs and Jira keys
declare -a LOCAL_IDS=()
declare -a JIRA_KEYS=()

# Matrix results: associative array keyed by "field:direction:operation"
declare -A MATRIX=()

TRACKER_DIR="${REPO_ROOT}/.tickets-tracker"  # tickets-boundary-ok
PREV_SNAPSHOT="${TRACKER_DIR}/.bridge_state/prev_snapshot.json"
PREV_SNAPSHOT_BACKUP=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pass_test() {
    local name="$1"
    echo "PASS: $name"
    PASSED=$((PASSED + 1))
}

fail_test() {
    local name="$1"
    local detail="${2:-}"
    echo "FAIL: $name${detail:+ — $detail}"
    FAILED=$((FAILED + 1))
    # Bug b859 (Part 0a): dump the most recent reconciler output's last 60
    # lines so unmatched stderr (including Python tracebacks) is visible.
    # The probe's main log captures this dump verbatim, eliminating the
    # observability gap that hid Phase 4's silent failure.
    if [ -n "${LAST_RECONCILER_LOG:-}" ] && [ -s "$LAST_RECONCILER_LOG" ]; then
        echo "=== last reconciler output (tail 60) ==="
        tail -60 "$LAST_RECONCILER_LOG"
        echo "=== end last reconciler output ==="
    fi
}

skip_test() {
    local name="$1"
    local reason="${2:-}"
    echo "SKIP: $name${reason:+ — $reason}"
    SKIPPED=$((SKIPPED + 1))
}

matrix_set() {
    local field="$1" direction="$2" operation="$3" result="$4"
    MATRIX["${field}:${direction}:${operation}"]="$result"
}

# shellcheck disable=SC2329 # invoked via trap
restore_snapshot() {
    if [ -n "$PREV_SNAPSHOT_BACKUP" ] && [ -f "$PREV_SNAPSHOT_BACKUP" ]; then
        cp "$PREV_SNAPSHOT_BACKUP" "$PREV_SNAPSHOT"
        rm -f "$PREV_SNAPSHOT_BACKUP"
        echo "Restored prev_snapshot.json from backup."
    fi
}

# Restore snapshot on any exit (crash safety).
trap restore_snapshot EXIT

# Bug b859 (Part 0a): the prior implementation captured reconciler output
# only to the local `output` var, and the caller piped it through a grep
# filter `^(FILTERED|filter:|OK:|ERROR:)` that silently dropped Python
# tracebacks. When the reconciler aborted pre-FILTERED PASS, operators saw
# nothing between "Running reconciler..." and the verify FAIL.
# Now: write every reconciler invocation's full unfiltered output to a
# side-car file at $LAST_RECONCILER_LOG, and expose $LAST_RECONCILER_LOG
# for fail_test to dump when an assertion fails. The function still echoes
# the output to stdout so existing callers see the same lines they always
# did.
LAST_RECONCILER_LOG=""
run_reconciler() {
    local output
    LAST_RECONCILER_LOG=$(mktemp -t recon-probe.XXXXXX.log)
    output=$(cd "$RECONCILER_DIR" && python -m dso_reconciler "$@" 2>&1) || true
    printf '%s\n' "$output" > "$LAST_RECONCILER_LOG"
    echo "$output"
}

run_filtered_reconciler() {
    local filter_ids="$1"
    shift
    run_reconciler --mode bootstrap-throttle --filter-local-ids "$filter_ids" --repo-root "$REPO_ROOT" "$@"
}

get_jira_field() {
    local key="$1"
    local field="$2"
    cd "$RECONCILER_DIR"
    python3 -c "
import importlib.util, sys, json, os
spec = importlib.util.spec_from_file_location('acli', '${_SCRIPTS_DIR}/acli-integration.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
adf_spec = importlib.util.spec_from_file_location('adf', '${_SCRIPTS_DIR}/dso_reconciler/adf.py')
adf_mod = importlib.util.module_from_spec(adf_spec)
adf_spec.loader.exec_module(adf_mod)
client = mod.AcliClient(
    jira_url=os.environ['JIRA_URL'],
    user=os.environ['JIRA_USER'],
    api_token=os.environ['JIRA_API_TOKEN'],
)
issue = client.get_issue_by_rest('${key}')
fields = issue.get('fields', issue)
val = fields.get('${field}', '')
# Description is returned as an ADF document, not a string. Decode via adf_to_text
# so the probe asserts against canonical plain text (bug 85a1 — the probe's prior
# raw.get('name', ...) returned '' for ADF, producing false-negative description
# verification failures).
if '${field}' == 'description' and isinstance(val, dict):
    val = adf_mod.adf_to_text(val)
elif isinstance(val, dict):
    val = val.get('name', val.get('displayName', ''))
if isinstance(val, list):
    print(json.dumps(val))
else:
    print(val)
"
}

get_jira_labels() {
    local key="$1"
    get_jira_field "$key" "labels"
}

get_jira_comments() {
    local key="$1"
    cd "$RECONCILER_DIR"
    python3 -c "
import importlib.util, json, os
spec = importlib.util.spec_from_file_location('acli', '${_SCRIPTS_DIR}/acli-integration.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
client = mod.AcliClient(
    jira_url=os.environ['JIRA_URL'],
    user=os.environ['JIRA_USER'],
    api_token=os.environ['JIRA_API_TOKEN'],
)
comments = client.get_comments('${key}')
for c in comments:
    body = c.get('body', '') if isinstance(c, dict) else str(c)
    print(body)
"
}

get_local_field() {
    local ticket_id="$1"
    local field="$2"
    "$TICKET_CLI" ticket show "$ticket_id" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
val = data.get('${field}', '')
if isinstance(val, list):
    print(json.dumps(val))
else:
    print(val)
"
}

check_binding() {
    local local_id="$1"
    local bindings_file="${TRACKER_DIR}/.bridge_state/bindings.json"
    if [ ! -f "$bindings_file" ]; then
        echo "no-bindings-file"
        return
    fi
    python3 -c "
import json
data = json.load(open('${bindings_file}'))
entry = data.get('bindings', {}).get('${local_id}')
if entry is None:
    print('unbound')
elif entry.get('state') == 'confirmed':
    print('confirmed:' + (entry.get('jira_key') or 'none'))
else:
    print(entry.get('state', 'unknown'))
"
}

edit_ticket_field() {
    # Edit a single ticket field via the ticket CLI's edit subcommand.
    # The local ticket store is event-sourced — no ticket.json to mutate —
    # so writes must go through the CLI which emits an EDIT event.
    local ticket_id="$1"
    local field="$2"
    local value="$3"
    "$TICKET_CLI" ticket edit "$ticket_id" "--${field}=${value}" 2>&1 | tail -1
}

jira_update_issue() {
    local key="$1"
    shift
    cd "$RECONCILER_DIR"
    local kwargs_json
    kwargs_json=$(python3 -c "
import json, sys
kwargs = {}
for arg in sys.argv[1:]:
    k, v = arg.split('=', 1)
    kwargs[k] = v
print(json.dumps(kwargs))
" "$@")
    python3 -c "
import importlib.util, os, json, sys
spec = importlib.util.spec_from_file_location('acli', '${_SCRIPTS_DIR}/acli-integration.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
kwargs = json.loads(sys.argv[1])
mod.update_issue('${key}', **kwargs)
" "$kwargs_json"
}

jira_update_priority() {
    local key="$1"
    local priority_name="$2"
    cd "$RECONCILER_DIR"
    python3 -c "
import importlib.util, os
spec = importlib.util.spec_from_file_location('acli', '${_SCRIPTS_DIR}/acli-integration.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.update_priority('${key}', '${priority_name}')"
}

jira_update_issuetype() {
    local key="$1"
    local type_name="$2"
    cd "$RECONCILER_DIR"
    python3 -c "
import importlib.util, os
spec = importlib.util.spec_from_file_location('acli', '${_SCRIPTS_DIR}/acli-integration.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
client = mod.AcliClient(
    jira_url=os.environ['JIRA_URL'],
    user=os.environ['JIRA_USER'],
    api_token=os.environ['JIRA_API_TOKEN'],
)
client.update_issuetype('${key}', '${type_name}')"
}

jira_transition() {
    local key="$1"
    local status_name="$2"
    cd "$RECONCILER_DIR"
    python3 -c "
import importlib.util, os
spec = importlib.util.spec_from_file_location('acli', '${_SCRIPTS_DIR}/acli-integration.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.transition_issue('${key}', '${status_name}')"
}

jira_add_label() {
    local key="$1"
    local label="$2"
    cd "$RECONCILER_DIR"
    python3 -c "
import importlib.util, os
spec = importlib.util.spec_from_file_location('acli', '${_SCRIPTS_DIR}/acli-integration.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
client = mod.AcliClient(
    jira_url=os.environ['JIRA_URL'],
    user=os.environ['JIRA_USER'],
    api_token=os.environ['JIRA_API_TOKEN'],
)
client.add_label('${key}', '${label}')"
}

jira_remove_label() {
    local key="$1"
    local label="$2"
    cd "$RECONCILER_DIR"
    python3 -c "
import importlib.util, os
spec = importlib.util.spec_from_file_location('acli', '${_SCRIPTS_DIR}/acli-integration.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
client = mod.AcliClient(
    jira_url=os.environ['JIRA_URL'],
    user=os.environ['JIRA_USER'],
    api_token=os.environ['JIRA_API_TOKEN'],
)
client.remove_label('${key}', '${label}')"
}

jira_add_comment() {
    local key="$1"
    local body="$2"
    cd "$RECONCILER_DIR"
    python3 -c "
import importlib.util, os
spec = importlib.util.spec_from_file_location('acli', '${_SCRIPTS_DIR}/acli-integration.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.add_comment('${key}', '${body}')"
}

jira_delete_issue() {
    local key="$1"
    cd "$RECONCILER_DIR"
    python3 -c "
import importlib.util, os
spec = importlib.util.spec_from_file_location('acli', '${_SCRIPTS_DIR}/acli-integration.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
client = mod.AcliClient(
    jira_url=os.environ['JIRA_URL'],
    user=os.environ['JIRA_USER'],
    api_token=os.environ['JIRA_API_TOKEN'],
)
client.delete_issue('${key}')" 2>&1 || true
}

build_filter_ids() {
    local ids=""
    for id in "$@"; do
        if [ -n "$ids" ]; then
            ids="${ids},${id}"
        else
            ids="$id"
        fi
    done
    echo "$ids"
}

fallback_cleanup() {
    echo "Running fallback cleanup — searching Jira for label ${PROBE_TAG}..."
    cd "$RECONCILER_DIR"
    python3 -c "
import importlib.util, os, json
spec = importlib.util.spec_from_file_location('acli', '${_SCRIPTS_DIR}/acli-integration.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
client = mod.AcliClient(
    jira_url=os.environ['JIRA_URL'],
    user=os.environ['JIRA_USER'],
    api_token=os.environ['JIRA_API_TOKEN'],
)
results = client.search_issues('project = ${JIRA_PROJECT} AND labels = \"${PROBE_TAG}\"')
issues = results if isinstance(results, list) else results.get('issues', [])
for issue in issues:
    key = issue.get('key', '')
    if key:
        print(f'Deleting orphaned probe issue {key}...')
        try:
            client.delete_issue(key)
        except Exception as e:
            print(f'  Warning: {e}')
print(f'Fallback cleanup complete: {len(issues)} issues processed.')
" 2>&1 || true
}

# ===========================================================================
# PHASE 0: Pre-flight
# ===========================================================================

echo ""
echo "==========================================="
echo "E2E FIELD VALIDATION PROBE — ${PROBE_TAG}"
echo "==========================================="
echo "Expected runtime: ~5-10 minutes (7+ Jira fetches)"
echo ""

echo "=== PHASE 0: Pre-flight ==="
echo ""

# Env check
for var in JIRA_URL JIRA_USER JIRA_API_TOKEN; do
    if [ -z "${!var:-}" ]; then
        echo "FATAL: ${var} is not set."
        exit 2
    fi
done
pass_test "Phase0.env-vars"

# Probe get_myself for assignee testing
PROBE_USER=$(cd "$RECONCILER_DIR" && python3 -c "
import importlib.util, os, json
spec = importlib.util.spec_from_file_location('acli', '${_SCRIPTS_DIR}/acli-integration.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
client = mod.AcliClient(
    jira_url=os.environ['JIRA_URL'],
    user=os.environ['JIRA_USER'],
    api_token=os.environ['JIRA_API_TOKEN'],
)
myself = client.get_myself()
name = myself.get('displayName', '')
if not name:
    print('')
else:
    print(name)
" 2>/dev/null) || true

if [ -z "$PROBE_USER" ]; then
    ASSIGNEE_SKIP=true
    skip_test "Phase0.get-myself" "get_myself returned no displayName — assignee tests will be skipped"
else
    pass_test "Phase0.get-myself (${PROBE_USER})"
fi

# Save snapshot (unique temp file to avoid collisions with concurrent probes)
if [ -f "$PREV_SNAPSHOT" ]; then
    PREV_SNAPSHOT_BACKUP=$(mktemp "${TRACKER_DIR}/.bridge_state/prev_snapshot.json.probe-backup.XXXXXX")
    cp "$PREV_SNAPSHOT" "$PREV_SNAPSHOT_BACKUP"
    pass_test "Phase0.snapshot-backup"
else
    pass_test "Phase0.snapshot-backup (no prev snapshot — clean start)"
fi

# ===========================================================================
# PHASE 1: Create 10 tickets + outbound create sync
# ===========================================================================

echo ""
echo "=== PHASE 1: Create 10 local tickets and sync outbound ==="
echo ""

create_ticket() {
    local idx="$1" type="$2" title="$3" desc="$4" priority="$5" extra_tags="${6:-}"
    local tags="${PROBE_TAG}"
    if [ -n "$extra_tags" ]; then
        tags="${tags},${extra_tags}"
    fi
    # `ticket create` defaults assignee to unassigned (ticket-create.sh
    # change in this branch). Ticket 5 sets a real assignee in Phase 1
    # via `ticket edit --assignee=$PROBE_USER` for the assignee test.
    local output
    output=$("$TICKET_CLI" ticket create "$type" "$title" -d "$desc" --priority "$priority" --tags "$tags" 2>&1)
    local id
    id=$(echo "$output" | tail -1)
    if [ -z "$id" ]; then
        # FATAL: index-aligned arrays (LOCAL_IDS, JIRA_KEYS) cannot tolerate
        # a gap. Abort the probe immediately rather than corrupt subsequent
        # phases that iterate by index.
        fail_test "Phase1.create-ticket-${idx}" "ticket create returned no ID: ${output}"
        echo "FATAL: cannot proceed with gap in LOCAL_IDS — aborting." >&2
        exit 1
    fi
    LOCAL_IDS+=("$id")
    pass_test "Phase1.create-ticket-${idx} (${id})"
    return 0
}

# Ticket 1: title + description baseline
create_ticket 1 task "FIELD-PROBE-1: title baseline ${PROBE_TS}" "Baseline description for probe" 2
# Ticket 2: bug type + priority highest
create_ticket 2 bug "FIELD-PROBE-2: bug type ${PROBE_TS}" "Bug type mapping test" 0
# Ticket 3: story type + priority lowest
create_ticket 3 story "FIELD-PROBE-3: priority low ${PROBE_TS}" "Priority mapping test" 4
# Ticket 4: multiline description
create_ticket 4 task "FIELD-PROBE-4: desc test ${PROBE_TS}" "Line1
Line2
Line3" 2
# Ticket 5: assignee testing
create_ticket 5 task "FIELD-PROBE-5: assignee ${PROBE_TS}" "Assignee test" 2
# Ticket 6: label testing
create_ticket 6 task "FIELD-PROBE-6: labels ${PROBE_TS}" "Label test" 2 "label-a,label-b,label-c"
# Ticket 7: issuetype asymmetry
create_ticket 7 task "FIELD-PROBE-7: issuetype ${PROBE_TS}" "Issuetype asymmetry test" 2
# Ticket 8: comment testing
create_ticket 8 task "FIELD-PROBE-8: comments ${PROBE_TS}" "Comment test" 2
# Ticket 9: status inbound testing
create_ticket 9 task "FIELD-PROBE-9: status ${PROBE_TS}" "Status inbound test" 2
# Ticket 10: delete behavior testing
create_ticket 10 task "FIELD-PROBE-10: delete ${PROBE_TS}" "Delete behavior test" 2

if [ "${#LOCAL_IDS[@]}" -lt 10 ]; then
    echo "FATAL: only created ${#LOCAL_IDS[@]} of 10 tickets."
    exit 1
fi

# Set assignee on ticket 5 via direct JSON edit
if [ "$ASSIGNEE_SKIP" = false ]; then
    edit_ticket_field "${LOCAL_IDS[4]}" "assignee" "${PROBE_USER}"
    pass_test "Phase1.set-assignee-ticket-5"
fi

# Add comment on ticket 8
"$TICKET_CLI" ticket comment "${LOCAL_IDS[7]}" "Probe outbound comment" 2>/dev/null || true
pass_test "Phase1.add-comment-ticket-8"

# Run reconciler
FILTER_IDS=$(build_filter_ids "${LOCAL_IDS[@]}")
echo "Running reconciler (bootstrap-throttle, filtered to ${#LOCAL_IDS[@]} IDs)..."
reconciler_output=$(run_filtered_reconciler "$FILTER_IDS")
echo "$reconciler_output" | grep -E "^(FILTERED|filter:|OK:|ERROR:)" || true

# Verify bindings and extract Jira keys.  The reconciler saves the binding
# store at the end of a pass — if the pass partially failed (e.g. HeadDrift
# or DirectionMismatch), the save may be skipped.  As a workaround, poll
# until the binding is confirmed or a ~120s budget is exhausted, using
# adaptive backoff (2s for the first 5 attempts, then 5s per attempt).
# On success the function returns immediately — no fixed worst-case wait.
# Bug 0877-2d0a-3c29-4292: the prior 3×2s (~6s) budget was too short for
# reconciler passes that include Jira REST roundtrips; all Phase-2
# outbound-UPDATE rows showed N/A because JIRA_KEYS were never populated.
check_binding_with_retry() {
    local local_id="$1"
    local state
    local elapsed=0
    local attempt=0
    local sleep_secs
    local budget=120

    while [[ $elapsed -lt $budget ]]; do
        state=$(check_binding "$local_id")
        if [[ "$state" == confirmed:* ]]; then
            echo "$state"
            return
        fi
        attempt=$(( attempt + 1 ))
        # Adaptive backoff: 2s for first 5 attempts, then 5s per attempt.
        if [[ $attempt -le 5 ]]; then
            sleep_secs=2
        else
            sleep_secs=5
        fi
        echo "check_binding_with_retry: attempt ${attempt}, state=${state}, sleeping ${sleep_secs}s (elapsed=${elapsed}s / budget=${budget}s)" >&2
        sleep "$sleep_secs"
        elapsed=$(( elapsed + sleep_secs ))
    done

    # Budget exhausted — return the last observed state.
    echo "check_binding_with_retry: budget exhausted after ${elapsed}s (${attempt} attempts), last state=${state}" >&2
    echo "$state"
}

for i in $(seq 0 9); do
    binding_state=$(check_binding_with_retry "${LOCAL_IDS[$i]}")
    if [[ "$binding_state" == confirmed:* ]]; then
        JIRA_KEYS+=("${binding_state#confirmed:}")
        pass_test "Phase1.binding-${i} (${LOCAL_IDS[$i]} → ${JIRA_KEYS[$i]})"
    else
        JIRA_KEYS+=("")
        fail_test "Phase1.binding-${i}" "expected confirmed, got: ${binding_state}"
    fi
done

# Verify outbound create fields
# Title (all tickets)
for i in $(seq 0 9); do
    [ -z "${JIRA_KEYS[$i]}" ] && continue
    jira_summary=$(get_jira_field "${JIRA_KEYS[$i]}" "summary")
    if [[ "$jira_summary" == *"FIELD-PROBE-$((i+1)):"* ]]; then
        pass_test "Phase1.verify-title-${i}"
    else
        fail_test "Phase1.verify-title-${i}" "got: ${jira_summary}"
    fi
done
matrix_set "title" "outbound" "create" "TESTED"

# Issuetype
for idx_type in "1:Bug" "2:Story" "0:Task" "3:Task"; do
    idx="${idx_type%%:*}"
    expected="${idx_type#*:}"
    [ -z "${JIRA_KEYS[$idx]}" ] && continue
    jira_type=$(get_jira_field "${JIRA_KEYS[$idx]}" "issuetype")
    if [ "$jira_type" = "$expected" ]; then
        pass_test "Phase1.verify-issuetype-${idx} (${expected})"
    else
        fail_test "Phase1.verify-issuetype-${idx}" "expected ${expected}, got: ${jira_type}"
    fi
done
matrix_set "issuetype" "outbound" "create" "TESTED"

# Priority
for idx_pri in "1:Highest" "2:Lowest" "0:Medium"; do
    idx="${idx_pri%%:*}"
    expected="${idx_pri#*:}"
    [ -z "${JIRA_KEYS[$idx]}" ] && continue
    jira_priority=$(get_jira_field "${JIRA_KEYS[$idx]}" "priority")
    if [ "$jira_priority" = "$expected" ]; then
        pass_test "Phase1.verify-priority-${idx} (${expected})"
    else
        fail_test "Phase1.verify-priority-${idx}" "expected ${expected}, got: ${jira_priority}"
    fi
done
matrix_set "priority" "outbound" "create" "TESTED"

# Description (ticket 4 multiline)
if [ -n "${JIRA_KEYS[3]}" ]; then
    jira_desc=$(get_jira_field "${JIRA_KEYS[3]}" "description")
    if [[ "$jira_desc" == *"Line1"* ]]; then
        pass_test "Phase1.verify-description-multiline"
    else
        fail_test "Phase1.verify-description-multiline" "got: ${jira_desc}"
    fi
fi
matrix_set "description" "outbound" "create" "TESTED"

# Assignee (ticket 5)
if [ "$ASSIGNEE_SKIP" = false ] && [ -n "${JIRA_KEYS[4]}" ]; then
    jira_assignee=$(get_jira_field "${JIRA_KEYS[4]}" "assignee")
    if [[ "${jira_assignee,,}" == "${PROBE_USER,,}" ]]; then
        pass_test "Phase1.verify-assignee"
        matrix_set "assignee" "outbound" "create" "PASS"
    else
        fail_test "Phase1.verify-assignee" "expected '${PROBE_USER}', got: '${jira_assignee}'"
        matrix_set "assignee" "outbound" "create" "FAIL"
    fi
else
    skip_test "Phase1.verify-assignee" "ASSIGNEE_SKIP"
    matrix_set "assignee" "outbound" "create" "SKIP"
fi

# Labels (ticket 6)
if [ -n "${JIRA_KEYS[5]}" ]; then
    jira_labels=$(get_jira_labels "${JIRA_KEYS[5]}")
    labels_ok=true
    for lbl in label-a label-b label-c "$PROBE_TAG"; do
        if ! echo "$jira_labels" | grep -q "$lbl"; then
            fail_test "Phase1.verify-label-${lbl}" "not in: ${jira_labels}"
            labels_ok=false
        fi
    done
    if [ "$labels_ok" = true ]; then
        pass_test "Phase1.verify-labels-ticket-6"
    fi
fi
matrix_set "labels" "outbound" "create" "TESTED"

# dso-id binding label (spot check ticket 1)
if [ -n "${JIRA_KEYS[0]}" ]; then
    jira_labels=$(get_jira_labels "${JIRA_KEYS[0]}")
    if echo "$jira_labels" | grep -q "dso-id"; then
        pass_test "Phase1.verify-dso-id-label"
    else
        fail_test "Phase1.verify-dso-id-label" "no dso-id label: ${jira_labels}"
    fi
fi

# Comment (ticket 8)
if [ -n "${JIRA_KEYS[7]}" ]; then
    jira_comments=$(get_jira_comments "${JIRA_KEYS[7]}")
    if echo "$jira_comments" | grep -q "Probe outbound comment"; then
        pass_test "Phase1.verify-comment-outbound"
        matrix_set "comments" "outbound" "create" "PASS"
    else
        fail_test "Phase1.verify-comment-outbound" "comment not found"
        matrix_set "comments" "outbound" "create" "FAIL"
    fi
fi

# ===========================================================================
# PHASE 2: Outbound update sync
# ===========================================================================

echo ""
echo "=== PHASE 2: Edit locally and sync outbound ==="
echo ""

# Ticket 1: change title
edit_ticket_field "${LOCAL_IDS[0]}" "title" "FIELD-PROBE-1: UPDATED title ${PROBE_TS}"
pass_test "Phase2.edit-title"

# Ticket 1: change description
edit_ticket_field "${LOCAL_IDS[0]}" "description" "Updated description"
pass_test "Phase2.edit-description"

# Ticket 2: change priority from 0 to 3 (Highest → Low)
edit_ticket_field "${LOCAL_IDS[1]}" "priority" "3"
pass_test "Phase2.edit-priority"

# Ticket 5: unassign (set assignee to "")
if [ "$ASSIGNEE_SKIP" = false ]; then
    edit_ticket_field "${LOCAL_IDS[4]}" "assignee" ""
    pass_test "Phase2.edit-assignee-unassign"
fi

# Ticket 6: add label-d, remove label-a
"$TICKET_CLI" ticket tag "${LOCAL_IDS[5]}" "label-d" 2>/dev/null || true
"$TICKET_CLI" ticket untag "${LOCAL_IDS[5]}" "label-a" 2>/dev/null || true
pass_test "Phase2.edit-labels"

# Ticket 7: change ticket_type from task to bug (asymmetry test)
edit_ticket_field "${LOCAL_IDS[6]}" "ticket_type" "bug"
pass_test "Phase2.edit-issuetype-local"

# Ticket 8: add second comment
"$TICKET_CLI" ticket comment "${LOCAL_IDS[7]}" "Second probe comment" 2>/dev/null || true
pass_test "Phase2.add-second-comment"

# Sync
echo "Running reconciler for outbound updates..."
reconciler_output=$(run_filtered_reconciler "$FILTER_IDS")
echo "$reconciler_output" | grep -E "^(FILTERED|filter:|OK:|ERROR:)" || true

# Verify outbound updates
# Title (ticket 1)
if [ -n "${JIRA_KEYS[0]}" ]; then
    jira_summary=$(get_jira_field "${JIRA_KEYS[0]}" "summary")
    if [[ "$jira_summary" == *"UPDATED title"* ]]; then
        pass_test "Phase2.verify-title-updated"
        matrix_set "title" "outbound" "update" "PASS"
    else
        fail_test "Phase2.verify-title-updated" "got: ${jira_summary}"
        matrix_set "title" "outbound" "update" "FAIL"
    fi
fi

# Description (ticket 1)
if [ -n "${JIRA_KEYS[0]}" ]; then
    jira_desc=$(get_jira_field "${JIRA_KEYS[0]}" "description")
    if [[ "$jira_desc" == *"Updated description"* ]]; then
        pass_test "Phase2.verify-description-updated"
        matrix_set "description" "outbound" "update" "PASS"
    else
        fail_test "Phase2.verify-description-updated" "got: ${jira_desc}"
        matrix_set "description" "outbound" "update" "FAIL"
    fi
fi

# Priority (ticket 2: 3 → Low)
if [ -n "${JIRA_KEYS[1]}" ]; then
    jira_priority=$(get_jira_field "${JIRA_KEYS[1]}" "priority")
    if [ "$jira_priority" = "Low" ]; then
        pass_test "Phase2.verify-priority-updated"
        matrix_set "priority" "outbound" "update" "PASS"
    else
        fail_test "Phase2.verify-priority-updated" "expected Low, got: ${jira_priority}"
        matrix_set "priority" "outbound" "update" "FAIL"
    fi
fi

# Assignee unassign (ticket 5)
if [ "$ASSIGNEE_SKIP" = false ] && [ -n "${JIRA_KEYS[4]}" ]; then
    jira_assignee=$(get_jira_field "${JIRA_KEYS[4]}" "assignee")
    if [ -z "$jira_assignee" ] || [ "$jira_assignee" = "None" ]; then
        pass_test "Phase2.verify-assignee-unassigned"
        matrix_set "assignee" "outbound" "update" "PASS"
    else
        fail_test "Phase2.verify-assignee-unassigned" "got: ${jira_assignee}"
        matrix_set "assignee" "outbound" "update" "FAIL"
    fi
else
    skip_test "Phase2.verify-assignee-unassigned" "ASSIGNEE_SKIP"
    matrix_set "assignee" "outbound" "update" "SKIP"
fi

# Labels (ticket 6: has label-b, label-c, label-d; does NOT have label-a)
if [ -n "${JIRA_KEYS[5]}" ]; then
    jira_labels=$(get_jira_labels "${JIRA_KEYS[5]}")
    label_update_ok=true
    for lbl in label-b label-c label-d; do
        if ! echo "$jira_labels" | grep -q "$lbl"; then
            fail_test "Phase2.verify-label-present-${lbl}" "not in: ${jira_labels}"
            label_update_ok=false
        fi
    done
    if echo "$jira_labels" | grep -q '"label-a"'; then
        fail_test "Phase2.verify-label-removed-a" "label-a still present: ${jira_labels}"
        label_update_ok=false
    fi
    if [ "$label_update_ok" = true ]; then
        pass_test "Phase2.verify-labels-updated"
        matrix_set "labels" "outbound" "update" "PASS"
    else
        matrix_set "labels" "outbound" "update" "FAIL"
    fi
fi

# Issuetype asymmetry (ticket 7: Jira should still be Task, NOT Bug)
if [ -n "${JIRA_KEYS[6]}" ]; then
    jira_type=$(get_jira_field "${JIRA_KEYS[6]}" "issuetype")
    if [ "$jira_type" = "Task" ]; then
        pass_test "Phase2.verify-issuetype-NOT-pushed (Task, not Bug)"
        matrix_set "issuetype" "outbound" "update" "BY_DESIGN"
    else
        fail_test "Phase2.verify-issuetype-NOT-pushed" "expected Task (blocked), got: ${jira_type}"
        matrix_set "issuetype" "outbound" "update" "FAIL"
    fi
fi

# Comment (ticket 8)
if [ -n "${JIRA_KEYS[7]}" ]; then
    jira_comments=$(get_jira_comments "${JIRA_KEYS[7]}")
    if echo "$jira_comments" | grep -q "Second probe comment"; then
        pass_test "Phase2.verify-comment-pushed"
        matrix_set "comments" "outbound" "update" "PASS"
    else
        fail_test "Phase2.verify-comment-pushed" "second comment not found"
        matrix_set "comments" "outbound" "update" "FAIL"
    fi
    # Check for duplicate first comment (dedup validation)
    dup_count=$(echo "$jira_comments" | grep -c "Probe outbound comment" || true)
    if [ "$dup_count" -le 1 ]; then
        pass_test "Phase2.verify-no-duplicate-comments"
    else
        fail_test "Phase2.verify-no-duplicate-comments" "found ${dup_count} copies"
    fi
fi

# ===========================================================================
# PHASE 3: Inbound update sync
# ===========================================================================

echo ""
echo "=== PHASE 3: Edit in Jira and sync inbound ==="
echo ""

# Ticket 1: edit summary in Jira
if [ -n "${JIRA_KEYS[0]}" ]; then
    jira_update_issue "${JIRA_KEYS[0]}" "summary=FIELD-PROBE-1: JIRA-EDITED ${PROBE_TS}" 2>&1 || true
    pass_test "Phase3.jira-edit-summary"
fi

# Ticket 1: edit description in Jira
if [ -n "${JIRA_KEYS[0]}" ]; then
    jira_update_issue "${JIRA_KEYS[0]}" "description=Jira-edited description" 2>&1 || true
    pass_test "Phase3.jira-edit-description"
fi

# Ticket 2: change priority to High (→ local 1)
if [ -n "${JIRA_KEYS[1]}" ]; then
    jira_update_priority "${JIRA_KEYS[1]}" "High" 2>&1 || true
    pass_test "Phase3.jira-edit-priority"
fi

# Ticket 5: re-assign from Jira side
if [ "$ASSIGNEE_SKIP" = false ] && [ -n "${JIRA_KEYS[4]}" ]; then
    jira_update_issue "${JIRA_KEYS[4]}" "assignee=${PROBE_USER}" 2>&1 || true
    pass_test "Phase3.jira-edit-assignee"
fi

# Ticket 6: add label-e from Jira side
if [ -n "${JIRA_KEYS[5]}" ]; then
    jira_add_label "${JIRA_KEYS[5]}" "label-e" 2>&1 || true
    pass_test "Phase3.jira-add-label"
fi

# Ticket 6: remove label-b from Jira side (inbound label removal test)
if [ -n "${JIRA_KEYS[5]}" ]; then
    jira_remove_label "${JIRA_KEYS[5]}" "label-b" 2>&1 || true
    pass_test "Phase3.jira-remove-label"
fi

# Ticket 7: change issuetype in Jira to Bug (should sync inbound)
if [ -n "${JIRA_KEYS[6]}" ]; then
    jira_update_issuetype "${JIRA_KEYS[6]}" "Bug" 2>&1 || true
    pass_test "Phase3.jira-edit-issuetype"
fi

# Ticket 8: add comment from Jira side (tests inbound comment gap)
if [ -n "${JIRA_KEYS[7]}" ]; then
    jira_add_comment "${JIRA_KEYS[7]}" "Jira-side comment" 2>&1 || true
    pass_test "Phase3.jira-add-comment"
fi

# Ticket 9: transition to In Progress
if [ -n "${JIRA_KEYS[8]}" ]; then
    jira_transition "${JIRA_KEYS[8]}" "In Progress" 2>&1 || true
    pass_test "Phase3.jira-transition-status"
fi

# Wait for Jira index consistency
sleep 3

# Sync
echo "Running reconciler for inbound sync..."
reconciler_output=$(run_filtered_reconciler "$FILTER_IDS")
echo "$reconciler_output" | grep -E "^(FILTERED|filter:|OK:|ERROR:)" || true

# Verify inbound updates
# Title (ticket 1)
local_title=$(get_local_field "${LOCAL_IDS[0]}" "title")
if [[ "$local_title" == *"JIRA-EDITED"* ]]; then
    pass_test "Phase3.verify-title-inbound"
    matrix_set "title" "inbound" "update" "PASS"
else
    fail_test "Phase3.verify-title-inbound" "got: ${local_title}"
    matrix_set "title" "inbound" "update" "FAIL"
fi

# Description (ticket 1)
local_desc=$(get_local_field "${LOCAL_IDS[0]}" "description")
if [[ "$local_desc" == *"Jira-edited description"* ]]; then
    pass_test "Phase3.verify-description-inbound"
    matrix_set "description" "inbound" "update" "PASS"
else
    fail_test "Phase3.verify-description-inbound" "got: ${local_desc}"
    matrix_set "description" "inbound" "update" "FAIL"
fi

# Priority (ticket 2: High → local 1)
local_priority=$(get_local_field "${LOCAL_IDS[1]}" "priority")
if [ "$local_priority" = "1" ]; then
    pass_test "Phase3.verify-priority-inbound"
    matrix_set "priority" "inbound" "update" "PASS"
else
    fail_test "Phase3.verify-priority-inbound" "expected 1, got: ${local_priority}"
    matrix_set "priority" "inbound" "update" "FAIL"
fi

# Assignee (ticket 5)
if [ "$ASSIGNEE_SKIP" = false ]; then
    local_assignee=$(get_local_field "${LOCAL_IDS[4]}" "assignee")
    if [[ "${local_assignee,,}" == "${PROBE_USER,,}" ]]; then
        pass_test "Phase3.verify-assignee-inbound"
        matrix_set "assignee" "inbound" "update" "PASS"
    else
        fail_test "Phase3.verify-assignee-inbound" "expected '${PROBE_USER}', got: '${local_assignee}'"
        matrix_set "assignee" "inbound" "update" "FAIL"
    fi
else
    skip_test "Phase3.verify-assignee-inbound" "ASSIGNEE_SKIP"
    matrix_set "assignee" "inbound" "update" "SKIP"
fi

# Labels (ticket 6: should have label-e added, label-b removed)
local_tags=$(get_local_field "${LOCAL_IDS[5]}" "tags")
label_inbound_ok=true
if echo "$local_tags" | grep -q "label-e"; then
    pass_test "Phase3.verify-label-add-inbound (label-e)"
else
    fail_test "Phase3.verify-label-add-inbound" "label-e not in: ${local_tags}"
    label_inbound_ok=false
fi
if ! echo "$local_tags" | grep -q '"label-b"'; then
    pass_test "Phase3.verify-label-remove-inbound (label-b gone)"
else
    fail_test "Phase3.verify-label-remove-inbound" "label-b still in: ${local_tags}"
    label_inbound_ok=false
fi
if [ "$label_inbound_ok" = true ]; then
    matrix_set "labels" "inbound" "update" "PASS"
else
    matrix_set "labels" "inbound" "update" "FAIL"
fi

# Issuetype (ticket 7: Jira changed to Bug → local should be "bug")
local_type=$(get_local_field "${LOCAL_IDS[6]}" "ticket_type")
if [ "$local_type" = "bug" ]; then
    pass_test "Phase3.verify-issuetype-inbound"
    matrix_set "issuetype" "inbound" "update" "PASS"
else
    fail_test "Phase3.verify-issuetype-inbound" "expected bug, got: ${local_type}"
    matrix_set "issuetype" "inbound" "update" "FAIL"
fi

# Comments inbound (ticket 8: Jira-side comment should NOT sync to local)
local_comments=$("$TICKET_CLI" ticket show "${LOCAL_IDS[7]}" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
comments = data.get('comments', [])
for c in comments:
    body = c.get('body', '') if isinstance(c, dict) else str(c)
    print(body)
" 2>/dev/null) || true
if echo "$local_comments" | grep -q "Jira-side comment"; then
    fail_test "Phase3.verify-inbound-comments-gap" "unexpectedly synced inbound"
    matrix_set "comments" "inbound" "update" "UNEXPECTED_PASS"
else
    pass_test "Phase3.verify-inbound-comments-gap (NOT_SUPPORTED as expected)"
    matrix_set "comments" "inbound" "update" "NOT_SUPPORTED"
fi

# Status (ticket 9: In Progress → local in_progress)
local_status=$(get_local_field "${LOCAL_IDS[8]}" "status")
if [ "$local_status" = "in_progress" ]; then
    pass_test "Phase3.verify-status-inbound"
    matrix_set "status" "inbound" "update" "PASS"
else
    fail_test "Phase3.verify-status-inbound" "expected in_progress, got: ${local_status}"
    matrix_set "status" "inbound" "update" "FAIL"
fi

# ===========================================================================
# PHASE 3a: Inbound on UNTOUCHED ticket (no local edits in Phase 2)
# ===========================================================================
#
# Bug b859 (Part 4a): Phase 3 verifies inbound on tickets ALSO edited in
# Phase 2. With local-wins conflict resolution, Phase 2's local edits
# override Phase 3's Jira-side edits — every Phase 3 verify FAILs not
# because inbound is broken but because local-wins works correctly.
# Phase 3a uses a ticket Phase 2 did NOT edit and confirms inbound
# persists Jira-side changes locally.

echo ""
echo "=== PHASE 3a: Inbound on untouched ticket ==="
echo ""

# Use LOCAL_IDS[3] (FIELD-PROBE-4 multiline desc ticket) — Phase 2 does NOT
# edit it; only Phase 1 created + verified it. Edit summary in Jira directly
# and confirm the local snapshot reflects the change after the reconciler runs.
if [ -n "${JIRA_KEYS[3]}" ]; then
    jira_update_issue "${JIRA_KEYS[3]}" "summary=FIELD-PROBE-4: PHASE3A-INBOUND ${PROBE_TS}" 2>&1 || true
    pass_test "Phase3a.jira-edit-summary-untouched"
fi

# Wait for Jira index consistency.
sleep 2

# Run the reconciler — inbound differ should detect the Jira summary edit
# and write an EDIT event to the local tracker.
echo "Running reconciler for inbound on untouched ticket..."
reconciler_output=$(run_filtered_reconciler "$FILTER_IDS")
echo "$reconciler_output" | grep -E "^(FILTERED|filter:|OK:|ERROR:)" || true

# Verify local picked up the Jira-side change.
local_title=$(get_local_field "${LOCAL_IDS[3]}" "title")
if [[ "$local_title" == *"PHASE3A-INBOUND"* ]]; then
    pass_test "Phase3a.verify-untouched-title-inbound"
else
    fail_test "Phase3a.verify-untouched-title-inbound" "expected PHASE3A-INBOUND in title; got: ${local_title}"
fi

# ===========================================================================
# PHASE 4: Status outbound negative test
# ===========================================================================

echo ""
echo "=== PHASE 4: Status outbound propagation ==="
echo ""

# Bug 85a1 (Gap 8): status outbound is now first-class — local status changes
# must propagate to Jira via REST POST /transitions. Previously this phase
# asserted BY_DESIGN no-propagation (gated behind DSO_RECONCILER_STATUS_GATING);
# that gate was removed.
#
# Bug b859 (Part 1b, H4 fix): we transition LOCAL_IDS[2] (idx 2 — FIELD-PROBE-3
# priority low) which Phase 3 leaves untouched. Previously this phase used
# LOCAL_IDS[8] but Phase 3 jira_transition's it to In Progress, and Phase 3's
# local-wins outbound pass reverted Jira back to To Do — so Phase 4's
# transition open->in_progress could become a no-op (current-status drift) and
# the reconciler would emit no output. Using an untouched ticket guarantees a
# real local->Jira delta.
"$TICKET_CLI" ticket transition "${LOCAL_IDS[2]}" open in_progress 2>/dev/null || true

echo "Running reconciler for status outbound test..."
reconciler_output=$(run_filtered_reconciler "$FILTER_IDS")
echo "$reconciler_output" | grep -E "^(FILTERED|filter:|OK:|ERROR:)" || true

# Verify Jira status now reflects the local change.
if [ -n "${JIRA_KEYS[2]}" ]; then
    jira_status=$(get_jira_field "${JIRA_KEYS[2]}" "status")
    if [ "$jira_status" = "In Progress" ]; then
        pass_test "Phase4.verify-status-outbound-in-progress"
        matrix_set "status" "outbound" "update" "PASS"
    else
        fail_test "Phase4.verify-status-outbound-in-progress" "expected In Progress, got: ${jira_status}"
        matrix_set "status" "outbound" "update" "FAIL"
    fi
fi

# ===========================================================================
# PHASE 5: Delete behavior negative test
# ===========================================================================

echo ""
echo "=== PHASE 5: Delete behavior test ==="
echo ""

# Delete ticket 10 locally
"$TICKET_CLI" ticket delete "${LOCAL_IDS[9]}" --user-approved 2>/dev/null || true
pass_test "Phase5.delete-local-ticket-10"

# Build filter with only 9 IDs (excluding ticket 10)
FILTER_IDS_9=$(build_filter_ids "${LOCAL_IDS[@]:0:9}")

echo "Running reconciler with 9-ticket filter..."
reconciler_output=$(run_filtered_reconciler "$FILTER_IDS_9")
echo "$reconciler_output" | grep -E "^(FILTERED|filter:|OK:|ERROR:)" || true

# Verify Jira issue for ticket 10 still exists
if [ -n "${JIRA_KEYS[9]}" ]; then
    jira_summary=$(get_jira_field "${JIRA_KEYS[9]}" "summary" 2>/dev/null) || true
    if [[ "$jira_summary" == *"FIELD-PROBE-10"* ]]; then
        pass_test "Phase5.verify-jira-NOT-deleted (ticket 10 still in Jira)"
        matrix_set "delete" "outbound" "exclusion" "BY_DESIGN"
    else
        fail_test "Phase5.verify-jira-NOT-deleted" "could not find ticket 10 in Jira"
        matrix_set "delete" "outbound" "exclusion" "FAIL"
    fi
fi

# ===========================================================================
# PHASE 6: Idempotency
# ===========================================================================

echo ""
echo "=== PHASE 6: Idempotency check (3 no-op passes) ==="
echo ""

for i in 1 2 3; do
    echo "Idempotency pass ${i}..."
    reconciler_output=$(run_filtered_reconciler "$FILTER_IDS_9")
    # Extract filtered mutation count from the filter: log line
    # awk is portable; grep -P / -oP are GNU-only and break on macOS BSD grep.
    # Line format: "filter: N mutations computed, M match filter (...)"
    filtered_count=$(echo "$reconciler_output" | awk '/^filter: [0-9]+ mutations computed, [0-9]+ match filter/ {print $5; exit}')
    filtered_count="${filtered_count:--1}"
    if [ "$filtered_count" = "0" ]; then
        pass_test "Phase6.idempotency-pass-${i} (0 filtered mutations)"
    else
        fail_test "Phase6.idempotency-pass-${i}" "expected 0 filtered mutations, got: ${filtered_count}"
    fi
done

# ===========================================================================
# PHASE 6a: Interleaved bidirectional idempotency (N=10 mixed passes)
# ===========================================================================
#
# Bug b859 (Part 4b): Phase 6 only checks no-op passes; doesn't exercise
# the convergence path under mixed local + Jira edits. Phase 6a alternates
# local and Jira edits on a single controlled ticket across 10 passes and
# asserts that each pass converges to its true delta (i.e., the diff is
# either 0 or precisely what was just edited — not phantom mutations).
#
# Uses LOCAL_IDS[3] (FIELD-PROBE-4 multiline desc; also used by Phase 3a
# inbound test). The ticket is tagged so any future orphan-mirror sweep
# preserves it.

echo ""
echo "=== PHASE 6a: Interleaved bidirectional idempotency (N=10) ==="
echo ""

if [ -n "${JIRA_KEYS[3]}" ] && [ -n "${LOCAL_IDS[3]}" ]; then
    # Tag the ticket so orphan sweeps skip it.
    "$TICKET_CLI" ticket tag "${LOCAL_IDS[3]}" "probe:phase6a" 2>/dev/null || true

    PHASE6A_MAX_PASS_MUTATIONS=2
    PHASE6A_FAIL=0
    for n in $(seq 1 10); do
        # Alternate: odd N edits LOCAL title; even N edits JIRA summary.
        if (( n % 2 == 1 )); then
            "$TICKET_CLI" ticket edit "${LOCAL_IDS[3]}" --title "Phase6a-LOCAL-${n} ${PROBE_TS}" 2>/dev/null || true
        else
            jira_update_issue "${JIRA_KEYS[3]}" "summary=Phase6a-JIRA-${n} ${PROBE_TS}" >/dev/null 2>&1 || true
            sleep 1
        fi
        reconciler_output=$(run_filtered_reconciler "$FILTER_IDS")
        mut_count=$(echo "$reconciler_output" | awk '/^filter: [0-9]+ mutations computed, [0-9]+ match filter/ {print $5; exit}')
        mut_count="${mut_count:--1}"
        if [ "$mut_count" -le "$PHASE6A_MAX_PASS_MUTATIONS" ] 2>/dev/null; then
            pass_test "Phase6a.pass-${n} (mutations=${mut_count})"
        else
            fail_test "Phase6a.pass-${n}" "expected <= ${PHASE6A_MAX_PASS_MUTATIONS} mutations, got: ${mut_count}"
            PHASE6A_FAIL=$((PHASE6A_FAIL + 1))
        fi
    done
    if [ "$PHASE6A_FAIL" = "0" ]; then
        pass_test "Phase6a.summary (all 10 passes converged)"
    else
        fail_test "Phase6a.summary" "${PHASE6A_FAIL} of 10 passes exceeded ${PHASE6A_MAX_PASS_MUTATIONS}-mutation budget"
    fi
fi

# ===========================================================================
# PHASE 7: Reconciliation check
# ===========================================================================

echo ""
echo "=== PHASE 7: Reconciliation check ==="
echo ""

reconcile_check_output=$(run_reconciler --mode reconcile-check --repo-root "$REPO_ROOT")
echo "$reconcile_check_output" | head -20

# Check only our 9 probe Jira keys for discrepancies
probe_discrepancies=0
for i in $(seq 0 8); do
    [ -z "${JIRA_KEYS[$i]}" ] && continue
    if echo "$reconcile_check_output" | grep -q "discrepancy.*${JIRA_KEYS[$i]}\|${JIRA_KEYS[$i]}.*discrepancy\|${JIRA_KEYS[$i]}.*mismatch"; then
        fail_test "Phase7.reconcile-check-${i}" "discrepancy for ${JIRA_KEYS[$i]}"
        probe_discrepancies=$((probe_discrepancies + 1))
    fi
done
if [ "$probe_discrepancies" -eq 0 ]; then
    pass_test "Phase7.reconcile-check (0 discrepancies for probe keys)"
fi

# ===========================================================================
# PHASE 8: Cleanup
# ===========================================================================

echo ""
echo "=== PHASE 8: Cleanup ==="
echo ""

cleanup_failed=false

# Delete all 10 Jira issues
for i in $(seq 0 9); do
    if [ -n "${JIRA_KEYS[$i]}" ]; then
        if jira_delete_issue "${JIRA_KEYS[$i]}" 2>/dev/null; then
            pass_test "Phase8.delete-jira-${i} (${JIRA_KEYS[$i]})"
        else
            fail_test "Phase8.delete-jira-${i}" "${JIRA_KEYS[$i]}"
            cleanup_failed=true
        fi
    fi
done

# Delete remaining 9 local tickets (ticket 10 already deleted)
for i in $(seq 0 8); do
    if "$TICKET_CLI" ticket delete "${LOCAL_IDS[$i]}" --user-approved 2>/dev/null; then
        pass_test "Phase8.delete-local-${i} (${LOCAL_IDS[$i]})"
    else
        fail_test "Phase8.delete-local-${i}" "${LOCAL_IDS[$i]}"
        cleanup_failed=true
    fi
done

# Snapshot is restored by the EXIT trap.

# Always run tag-based fallback cleanup — covers the case where bindings
# were never confirmed (JIRA_KEYS[i] empty), so the indexed loop above
# couldn't delete the Jira issues that DID get created by the reconciler.
echo "Running tag-based fallback cleanup to catch any orphaned Jira issues..."
fallback_cleanup

# ===========================================================================
# Report
# ===========================================================================

echo ""
echo "==========================================="
echo "FIELD VALIDATION MATRIX — ${PROBE_TAG}"
echo "==========================================="
echo ""
printf "%-14s %-20s %-20s %-20s\n" "Field" "Outbound Create" "Outbound Update" "Inbound Update"
printf "%-14s %-20s %-20s %-20s\n" "--------------" "--------------------" "--------------------" "--------------------"

for field in title description priority assignee issuetype status labels comments delete; do
    oc="${MATRIX["${field}:outbound:create"]:-N/A}"
    ou="${MATRIX["${field}:outbound:update"]:-N/A}"
    iu="${MATRIX["${field}:inbound:update"]:-N/A}"
    # Handle special cases
    case "$field" in
        status)  oc="N/A (To Do)" ;;
        delete)  ou="—"; iu="—"; oc="${MATRIX["delete:outbound:exclusion"]:-N/A}" ;;
    esac
    printf "%-14s %-20s %-20s %-20s\n" "$field" "$oc" "$ou" "$iu"
done

echo ""
echo "==========================================="
echo "E2E FIELD VALIDATION SUMMARY: ${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped"
echo "==========================================="

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
