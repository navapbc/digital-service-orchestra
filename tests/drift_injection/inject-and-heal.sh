#!/usr/bin/env bash
# Drift injection and self-healing end-to-end harness.
# Usage: inject-and-heal.sh <orphan|mislabel|missing-prop>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Skip if credentials absent (CI skip-not-fail)
if [[ -z "${JIRA_API_TOKEN:-}" || -z "${DRIFT_TEST_PROJECT_KEY:-}" ]]; then
    echo "SKIP: JIRA_API_TOKEN or DRIFT_TEST_PROJECT_KEY not set" >&2
    exit 0
fi

# shellcheck source=lib/jira-api.sh
source "${SCRIPT_DIR}/lib/jira-api.sh"

MODE="${1:-}"
CLEANUP_KEYS=()

cleanup() {
    for k in "${CLEANUP_KEYS[@]:-}"; do
        jira_delete_issue "$k" 2>/dev/null || true
    done
}
trap cleanup EXIT

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

    # Run one reconciler pass to heal
    python3 -m dso_reconciler --repo-root "${REPO_ROOT}"

    # Assert bridge-fsck now exits 0
    python3 "${REPO_ROOT}/plugins/dso/scripts/ticket-bridge-fsck.py" || {
        echo "FAIL: bridge-fsck still non-zero after heal" >&2
        exit 1
    }
    echo "Post-heal fsck: exit 0 (PASS)"
    ;;
  mislabel)
    # Create a Jira issue + local ticket pair, then overwrite the Jira label
    # with a wrong value (not matching dso-id:<uuid>)
    LOCAL_ID="drift-mislabel-$(date +%s)"
    ISSUE_KEY=$(jira_create_issue "DSO drift-injection mislabel $(date +%s)")
    CLEANUP_KEYS+=("$ISSUE_KEY")
    echo "Injected mislabel: ${ISSUE_KEY} (local: ${LOCAL_ID})"

    # Set correct label first
    jira_set_label "$ISSUE_KEY" "dso-id:${LOCAL_ID}"

    # Now overwrite with wrong label (inject the drift)
    jira_set_label "$ISSUE_KEY" "wrong-label-injected"

    # Assert bridge-fsck non-zero before heal
    python3 "${REPO_ROOT}/plugins/dso/scripts/ticket-bridge-fsck.py" && {
        echo "FAIL: expected bridge-fsck non-zero exit before heal (mislabel)" >&2
        exit 1
    }
    echo "Pre-heal fsck: non-zero exit (expected)"

    # Run reconciler to heal
    python3 -m dso_reconciler --repo-root "${REPO_ROOT}"

    # Assert bridge-fsck exits 0
    python3 "${REPO_ROOT}/plugins/dso/scripts/ticket-bridge-fsck.py" || {
        echo "FAIL: bridge-fsck still non-zero after heal (mislabel)" >&2
        exit 1
    }
    echo "Post-heal fsck: exit 0 (PASS)"
    ;;
  missing-prop)
    echo "not yet implemented" >&2
    exit 2
    ;;
  *)
    echo "Usage: $0 <orphan|mislabel|missing-prop>" >&2
    exit 1
    ;;
esac
