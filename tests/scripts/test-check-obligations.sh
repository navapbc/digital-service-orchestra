#!/usr/bin/env bash
# tests/scripts/test-check-obligations.sh
#
# Behavior tests for plugins/dso/scripts/dso_reconciler/check-obligations.sh.
# Uses a stub ticket CLI on PATH so no real tracker is touched.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MONITOR="$REPO_ROOT/plugins/dso/scripts/dso_reconciler/check-obligations.sh"

PASS=0
FAIL=0

_assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        printf "FAIL: %s\n  expected: %s\n  actual:   %s\n" "$name" "$expected" "$actual" >&2
    fi
}

_setup_fixture() {
    local tmp="$1" deadline="$2"
    mkdir -p "$tmp"
    # Stub ticket CLI: records `create bug` calls in $tmp/create-calls.log
    cat > "$tmp/dso" <<EOF
#!/usr/bin/env bash
# stub ticket CLI for check-obligations test
set -uo pipefail
if [[ "\$1" == "ticket" && "\$2" == "list" ]]; then
    printf '%s' '[{"ticket_id":"obl-0001"}]'
    exit 0
fi
if [[ "\$1" == "ticket" && "\$2" == "show" ]]; then
    cat <<JSON
{
  "ticket_id": "obl-0001",
  "parent_id": "story-83ac",
  "description": "## Obligation\nParent story: story-83ac\nDeadline: $deadline\nOwner: operator\nValidation command: curl -sf https://example/health\n"
}
JSON
    exit 0
fi
if [[ "\$1" == "ticket" && "\$2" == "create" ]]; then
    printf '%s\n' "CREATE \$*" >> "$tmp/create-calls.log"
    exit 0
fi
exit 0
EOF
    chmod +x "$tmp/dso"
}

test_past_deadline_files_one_bug() {
    local tmp; tmp=$(mktemp -d /tmp/check-obl-past.XXXXXX)
    _setup_fixture "$tmp" "2020-01-01"
    DSO_TICKET_CLI="$tmp/dso" DSO_TODAY="2026-05-26" bash "$MONITOR" 2>/dev/null
    local count
    count=$(grep -c '^CREATE ' "$tmp/create-calls.log" 2>/dev/null || echo 0)
    _assert_eq "past-deadline obligation produces exactly 1 bug ticket" "1" "$count"
    # The bug must be parented to the obligation's parent story.
    if grep -q -- '--parent story-83ac' "$tmp/create-calls.log"; then
        _assert_eq "bug is parented to obligation's parent story" "yes" "yes"
    else
        _assert_eq "bug is parented to obligation's parent story" "yes" "no"
    fi
    rm -rf "$tmp"
}

test_future_deadline_files_no_bug() {
    local tmp; tmp=$(mktemp -d /tmp/check-obl-future.XXXXXX)
    _setup_fixture "$tmp" "2099-12-31"
    DSO_TICKET_CLI="$tmp/dso" DSO_TODAY="2026-05-26" bash "$MONITOR" 2>/dev/null
    local count
    count=$(grep -c '^CREATE ' "$tmp/create-calls.log" 2>/dev/null || echo 0)
    _assert_eq "future-deadline obligation produces no bug ticket" "0" "$count"
    rm -rf "$tmp"
}

test_monitor_always_exits_zero() {
    local tmp; tmp=$(mktemp -d /tmp/check-obl-exit.XXXXXX)
    _setup_fixture "$tmp" "2020-01-01"
    DSO_TICKET_CLI="$tmp/dso" DSO_TODAY="2026-05-26" bash "$MONITOR" 2>/dev/null
    _assert_eq "monitor exits 0 on past-deadline path" "0" "$?"
    rm -rf "$tmp"
}

test_past_deadline_files_one_bug
test_future_deadline_files_no_bug
test_monitor_always_exits_zero

printf "check-obligations: PASS=%d FAIL=%d\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
