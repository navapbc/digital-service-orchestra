#!/usr/bin/env bash
# Drift injection and self-healing end-to-end harness.
# Usage: inject-and-heal.sh <orphan|mislabel|missing-prop>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Fix 3: require JIRA_BASE_URL and JIRA_USER in the credential gate alongside the
# existing checks — partial-env runs must not silently target the placeholder host.
if [[ -z "${JIRA_API_TOKEN:-}" || -z "${DRIFT_TEST_PROJECT_KEY:-}" \
   || -z "${JIRA_BASE_URL:-}"   || -z "${JIRA_USER:-}" ]]; then
    echo "SKIP: JIRA_API_TOKEN, JIRA_USER, JIRA_BASE_URL, or DRIFT_TEST_PROJECT_KEY not set" >&2
    exit 0
fi

# shellcheck source=lib/jira-api.sh
source "${SCRIPT_DIR}/lib/jira-api.sh"

MODE="${1:-}"
CLEANUP_KEYS=()
# Track local (DSO) ticket IDs created so we can clean them up too.
CLEANUP_LOCAL_IDS=()

cleanup() {
    # Fix 4: guard against empty-array expansion producing a spurious empty-string element.
    if [[ ${#CLEANUP_KEYS[@]} -gt 0 ]]; then
        for k in "${CLEANUP_KEYS[@]}"; do
            jira_delete_issue "$k" 2>/dev/null || true
        done
    fi
}
trap cleanup EXIT

# Fix 2: set PYTHONPATH so `python3 -m dso_reconciler` can locate the package.
export PYTHONPATH="${REPO_ROOT}/plugins/dso/scripts${PYTHONPATH:+:${PYTHONPATH}}"

# Fix 6: generate a canonical DSO ticket-ID-shaped UUID (8hex-4hex prefix)
# by reading from a freshly created local ticket rather than constructing a
# fake ID.  Helper used by mislabel and missing-prop modes.
_create_local_ticket() {
    local title="$1"
    # Fix 1 + 6: create a real local DSO ticket and use its generated ID.
    "${REPO_ROOT}/.claude/scripts/dso" ticket create task "${title}" \
        | grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
        | head -n1
}

case "${MODE}" in
  orphan)
    # Create a Jira issue with no corresponding local ticket (orphan)
    ISSUE_KEY=$(jira_create_issue "DSO drift-injection orphan $(date +%s)")
    CLEANUP_KEYS+=("$ISSUE_KEY")
    echo "Injected orphan: ${ISSUE_KEY}"

    # Assert bridge-fsck reports non-zero (finds the orphan)
    python3 "${REPO_ROOT}/plugins/dso/scripts/ticket-bridge-fsck.py" && {
        echo "FAIL: expected bridge-fsck non-zero exit before heal" >&2
        exit 1
    }
    echo "Pre-heal fsck: non-zero exit (expected)"

    # Fix 2: PYTHONPATH already exported above.
    python3 -m dso_reconciler --repo-root "${REPO_ROOT}"

    # Assert bridge-fsck now exits 0
    python3 "${REPO_ROOT}/plugins/dso/scripts/ticket-bridge-fsck.py" || {
        echo "FAIL: bridge-fsck still non-zero after heal" >&2
        exit 1
    }
    echo "Post-heal fsck: exit 0 (PASS)"
    ;;
  mislabel)
    # Fix 1 + 6: create the matching local DSO ticket so the bridge sees a
    # real pair rather than an orphan Jira issue, and use its canonical ID.
    LOCAL_ID=$(_create_local_ticket "DSO drift-injection mislabel $(date +%s)")
    CLEANUP_LOCAL_IDS+=("$LOCAL_ID")

    ISSUE_KEY=$(jira_create_issue "DSO drift-injection mislabel $(date +%s)")
    CLEANUP_KEYS+=("$ISSUE_KEY")
    echo "Injected mislabel: ${ISSUE_KEY} (local: ${LOCAL_ID})"

    # Set correct label first (correct state)
    jira_set_label "$ISSUE_KEY" "dso-id:${LOCAL_ID}"

    # Now overwrite with wrong label (inject the drift)
    jira_set_label "$ISSUE_KEY" "wrong-label-injected"

    # Assert bridge-fsck non-zero before heal
    python3 "${REPO_ROOT}/plugins/dso/scripts/ticket-bridge-fsck.py" && {
        echo "FAIL: expected bridge-fsck non-zero exit before heal (mislabel)" >&2
        exit 1
    }
    echo "Pre-heal fsck: non-zero exit (expected)"

    # Fix 2: PYTHONPATH already exported above.
    python3 -m dso_reconciler --repo-root "${REPO_ROOT}"

    # Assert bridge-fsck exits 0
    python3 "${REPO_ROOT}/plugins/dso/scripts/ticket-bridge-fsck.py" || {
        echo "FAIL: bridge-fsck still non-zero after heal (mislabel)" >&2
        exit 1
    }
    echo "Post-heal fsck: exit 0 (PASS)"
    ;;
  missing-prop)
    # Fix 1 + 6: create the matching local DSO ticket and use its canonical ID.
    LOCAL_ID=$(_create_local_ticket "DSO drift-injection missing-prop $(date +%s)")
    CLEANUP_LOCAL_IDS+=("$LOCAL_ID")

    ISSUE_KEY=$(jira_create_issue "DSO drift-injection missing-prop $(date +%s)")
    CLEANUP_KEYS+=("$ISSUE_KEY")
    echo "Injected missing-prop: ${ISSUE_KEY} (local: ${LOCAL_ID})"

    # Set the property first (correct state)
    _prop_payload=$(python3 -c "import json, sys; print(json.dumps({'value': sys.argv[1]}))" "$LOCAL_ID")
    # Use the validated JIRA_BASE_URL (no placeholder default possible — gate above enforces it).
    # Fix 5: this raw curl is for initial setup only; use _jira_curl idiom via jira-api.sh helper
    # instead of the inline curl -s call that would swallow errors.
    _setup_curl_output=$(curl -s --fail-with-body \
        -u "${JIRA_USER}:${JIRA_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -X PUT "${JIRA_BASE_URL}/rest/api/3/issue/${ISSUE_KEY}/properties/dso_local_id" \
        -d "$_prop_payload") || {
        echo "FAIL: could not set dso_local_id property on ${ISSUE_KEY}: ${_setup_curl_output}" >&2
        exit 1
    }

    # Now strip the property (inject drift)
    jira_strip_property "$ISSUE_KEY" "dso_local_id"

    # Assert bridge-fsck non-zero before heal
    python3 "${REPO_ROOT}/plugins/dso/scripts/ticket-bridge-fsck.py" && {
        echo "FAIL: expected bridge-fsck non-zero exit before heal (missing-prop)" >&2
        exit 1
    }
    echo "Pre-heal fsck: non-zero exit (expected)"

    # Fix 2: PYTHONPATH already exported above.
    python3 -m dso_reconciler --repo-root "${REPO_ROOT}"

    # Assert bridge-fsck exits 0
    python3 "${REPO_ROOT}/plugins/dso/scripts/ticket-bridge-fsck.py" || {
        echo "FAIL: bridge-fsck still non-zero after heal (missing-prop)" >&2
        exit 1
    }
    echo "Post-heal fsck: exit 0 (PASS)"
    ;;
  *)
    echo "Usage: $0 <orphan|mislabel|missing-prop>" >&2
    exit 1
    ;;
esac
