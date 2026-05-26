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
    local tmp="$1" deadline="$2" val_cmd="${3:-curl -sf https://example/health}"
    mkdir -p "$tmp"
    # Pass val_cmd into the stub via env to avoid heredoc-quoting hazards.
    export STUB_VAL_CMD="$val_cmd"
    export STUB_DEADLINE="$deadline"
    # Stub ticket CLI: records `create bug` calls in $tmp/create-calls.log
    cat > "$tmp/dso" <<'EOF'
#!/usr/bin/env bash
# stub ticket CLI for check-obligations test
set -uo pipefail
TMP_DIR_SELF="$(dirname "$0")"
if [[ "$1" == "ticket" && "$2" == "list" ]]; then
    printf '%s' '[{"ticket_id":"obl-0001"}]'
    exit 0
fi
if [[ "$1" == "ticket" && "$2" == "show" ]]; then
    python3 - "$STUB_DEADLINE" "$STUB_VAL_CMD" <<'PY'
import json, sys
deadline = sys.argv[1]
val_cmd = sys.argv[2]
desc_lines = ["## Obligation", "Parent story: story-83ac"]
if deadline:
    desc_lines.append(f"Deadline: {deadline}")
desc_lines += ["Owner: operator", f"Validation command: {val_cmd}", ""]
print(json.dumps({
    "ticket_id": "obl-0001",
    "parent_id": "story-83ac",
    "description": "\n".join(desc_lines),
}))
PY
    exit 0
fi
if [[ "$1" == "ticket" && "$2" == "create" ]]; then
    # Stash the exit code in a side-channel file (default 0).
    rc=0
    if [[ -f "$TMP_DIR_SELF/create-rc" ]]; then
        rc=$(cat "$TMP_DIR_SELF/create-rc")
    fi
    # Record full argv on one line (space-separated for back-compat with
    # `--parent story-83ac` greps) AND a NUL-delimited record next to it so
    # tests that need exact bytes (multi-line / metachar bug bodies) can
    # parse the raw arg vector reliably.
    printf 'CREATE %s\n' "$*" >> "$TMP_DIR_SELF/create-calls.log"
    {
        printf 'BEGIN\0'
        for a in "$@"; do printf '%s\0' "$a"; done
        printf 'END\0'
    } >> "$TMP_DIR_SELF/create-calls.bin"
    exit "$rc"
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

test_missing_deadline_skips_silently() {
    # Finding 5 edge case: malformed description (no Deadline: line) must not
    # crash the monitor and must not file a bug.
    local tmp; tmp=$(mktemp -d /tmp/check-obl-nodate.XXXXXX)
    _setup_fixture "$tmp" "" "curl -sf https://example/health"
    DSO_TICKET_CLI="$tmp/dso" DSO_TODAY="2026-05-26" bash "$MONITOR" 2>/dev/null
    local exit_code=$?
    _assert_eq "monitor exits 0 on missing-Deadline description" "0" "$exit_code"
    local count
    count=$(grep -c '^CREATE ' "$tmp/create-calls.log" 2>/dev/null || echo 0)
    _assert_eq "missing-Deadline description produces no bug ticket" "0" "$count"
    rm -rf "$tmp"
}

test_validation_command_with_metachars_is_sanitized() {
    # Finding 3: validation command extracted from a ticket description must
    # not be able to corrupt the bug body even if it contains shell
    # metacharacters or embedded newlines. The parser bounds the field at
    # the first newline AND JSON-encodes during extraction; the bug body
    # therefore stays on a single line and the metacharacters survive
    # verbatim inside the --description argument.
    local tmp; tmp=$(mktemp -d /tmp/check-obl-meta.XXXXXX)
    # Validation command containing $(...) and backticks — must NOT execute.
    # shellcheck disable=SC2016
    _setup_fixture "$tmp" "2020-01-01" 'echo $(rm -rf /) `whoami` "quoted"'
    DSO_TICKET_CLI="$tmp/dso" DSO_TODAY="2026-05-26" bash "$MONITOR" 2>/dev/null
    local count
    count=$(grep -c '^CREATE ' "$tmp/create-calls.log" 2>/dev/null || echo 0)
    _assert_eq "metachar validation command still files exactly 1 bug" "1" "$count"
    # Body must contain the metachars literally — not the expansion.
    if grep -q -F -- 'rm -rf' "$tmp/create-calls.log" && \
       grep -q -F -- 'whoami' "$tmp/create-calls.log"; then
        _assert_eq "bug body preserves metachars literally" "yes" "yes"
    else
        _assert_eq "bug body preserves metachars literally" "yes" "no"
    fi
    # And the create-calls log must be a single CREATE line (no body-induced
    # extra lines from embedded newlines).
    local lines
    lines=$(wc -l < "$tmp/create-calls.log" | tr -d ' ')
    _assert_eq "metachar bug body did not inject extra log lines" "1" "$lines"
    rm -rf "$tmp"
}

test_ticket_create_failure_does_not_inflate_count() {
    # Finding 2 (analogue in this script): when `ticket create` fails, the
    # script must not increment its filed counter. This pins the same
    # invariant — failed creation is observable, not silently swallowed as
    # success — that the verifier spec mandates at agent dispatch time.
    local tmp; tmp=$(mktemp -d /tmp/check-obl-failrc.XXXXXX)
    _setup_fixture "$tmp" "2020-01-01"
    # Force the stub `ticket create` to fail.
    printf '7' > "$tmp/create-rc"
    local stderr_out
    stderr_out=$(DSO_TICKET_CLI="$tmp/dso" DSO_TODAY="2026-05-26" bash "$MONITOR" 2>&1)
    _assert_eq "monitor still exits 0 when ticket create fails" "0" "$?"
    # The stderr summary must show 0 filed, not 1, when create returned non-zero.
    if printf '%s' "$stderr_out" | grep -q 'filed 0 overdue'; then
        _assert_eq "failed ticket create not counted as filed" "yes" "yes"
    else
        _assert_eq "failed ticket create not counted as filed (saw: $stderr_out)" "yes" "no"
    fi
    rm -rf "$tmp"
}

test_validation_command_with_bare_double_quotes_is_literal() {
    # Findings 1 & 2: a validation command containing bare double-quotes
    # (e.g. `echo "hello world"`) must reach the bug --description argv
    # literally, NOT word-split, NOT shell-interpreted, NOT JSON-escaped.
    local tmp; tmp=$(mktemp -d /tmp/check-obl-dquote.XXXXXX)
    _setup_fixture "$tmp" "2020-01-01" 'echo "hello world"'
    DSO_TICKET_CLI="$tmp/dso" DSO_TODAY="2026-05-26" bash "$MONITOR" 2>/dev/null
    local count
    count=$(grep -c '^CREATE ' "$tmp/create-calls.log" 2>/dev/null || echo 0)
    _assert_eq "double-quoted validation command files exactly 1 bug" "1" "$count"
    # Parse the NUL-delimited record. The --description argument must equal
    # the body string with the literal validation command embedded — bare
    # double-quotes preserved, NOT escaped to \" or stripped.
    local expected_body='OBLIGATION OVERDUE: obl-0001, validation command: echo "hello world", days overdue: '
    # Walk the binary record. Each argv element is NUL-terminated.
    local found="no"
    if python3 - "$tmp/create-calls.bin" "$expected_body" <<'PY' >/dev/null 2>&1
import sys
path = sys.argv[1]
needle = sys.argv[2]
with open(path, 'rb') as f:
    data = f.read()
args = [a.decode('utf-8', errors='replace') for a in data.split(b'\0')]
# Find --description and its successor.
for i, a in enumerate(args):
    if a == '--description' and i+1 < len(args):
        if args[i+1].startswith(needle):
            sys.exit(0)
sys.exit(1)
PY
    then
        found="yes"
    fi
    _assert_eq "bug body contains literal echo \"hello world\"" "yes" "$found"
    rm -rf "$tmp"
}

test_parent_story_with_invalid_id_is_dropped() {
    # Finding 3 (defense-in-depth): even if parent_id reaches the script
    # with a value containing shell-unsafe characters, it must not be
    # passed as --parent. The regex gate drops malformed IDs.
    local tmp; tmp=$(mktemp -d /tmp/check-obl-badparent.XXXXXX)
    _setup_fixture "$tmp" "2020-01-01"
    # Override the stub to emit a malformed parent_id.
    cat > "$tmp/dso" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
TMP_DIR_SELF="$(dirname "$0")"
if [[ "$1" == "ticket" && "$2" == "list" ]]; then
    printf '%s' '[{"ticket_id":"obl-0001"}]'
    exit 0
fi
if [[ "$1" == "ticket" && "$2" == "show" ]]; then
    printf '%s' '{"ticket_id":"obl-0001","parent_id":"story-83ac; rm -rf /","description":"Deadline: 2020-01-01\nValidation command: ok\n"}'
    exit 0
fi
if [[ "$1" == "ticket" && "$2" == "create" ]]; then
    printf 'CREATE %s\n' "$*" >> "$TMP_DIR_SELF/create-calls.log"
    exit 0
fi
exit 0
EOF
    chmod +x "$tmp/dso"
    DSO_TICKET_CLI="$tmp/dso" DSO_TODAY="2026-05-26" bash "$MONITOR" 2>/dev/null
    if grep -q -- '--parent' "$tmp/create-calls.log"; then
        _assert_eq "malformed parent_id is NOT forwarded to --parent" "yes" "no"
    else
        _assert_eq "malformed parent_id is NOT forwarded to --parent" "yes" "yes"
    fi
    # And the bug must still be filed (without --parent).
    local count
    count=$(grep -c '^CREATE ' "$tmp/create-calls.log" 2>/dev/null || echo 0)
    _assert_eq "bug still filed when parent_id is dropped" "1" "$count"
    rm -rf "$tmp"
}

test_past_deadline_files_one_bug
test_future_deadline_files_no_bug
test_monitor_always_exits_zero
test_missing_deadline_skips_silently
test_validation_command_with_metachars_is_sanitized
test_validation_command_with_bare_double_quotes_is_literal
test_parent_story_with_invalid_id_is_dropped
test_ticket_create_failure_does_not_inflate_count

printf "check-obligations: PASS=%d FAIL=%d\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
