#!/usr/bin/env bash
# Tests for check-acceptance-criteria.sh
# Verifies that the script correctly parses v3 JSON ticket output
# to find acceptance criteria in ticket description and comment bodies.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"

SUT="$REPO_ROOT/plugins/dso/scripts/check-acceptance-criteria.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

_make_ticket_json() {
    # Build v3 JSON ticket output with optional AC in description or comments
    local description="${1:-}"
    local comment_body="${2:-}"
    python3 -c "
import json, sys
t = {
    'ticket_id': 'test-0001',
    'ticket_type': 'task',
    'title': 'Test ticket',
    'status': 'open',
    'description': sys.argv[1],
    'comments': []
}
if sys.argv[2]:
    t['comments'].append({'body': sys.argv[2], 'author': 'test', 'timestamp': 0})
print(json.dumps(t))
" "$description" "$comment_body"
}

_run_sut_with_json() {
    # Run SUT with a mock TICKET_CMD that returns the given JSON
    local json_output="$1"
    local tmpscript
    tmpscript=$(mktemp /tmp/mock-ticket-XXXXXX.sh)
    # Write mock script — use heredoc to avoid quoting issues with JSON
    trap "rm -f '$tmpscript'" RETURN
    cat > "$tmpscript" <<'MOCKEOF'
#!/usr/bin/env bash
MOCKEOF
    # Append the echo with proper quoting
    printf 'echo %q\n' "$json_output" >> "$tmpscript"
    chmod +x "$tmpscript"
    local output exit_code=0
    output=$(TICKET_CMD="$tmpscript" "$SUT" "test-0001" 2>/dev/null) || exit_code=$?
    echo "$output"
    return $exit_code
}

# ── Tests ─────────────────────────────────────────────────────────────────────

# test_pass_with_ac_in_description: AC section in description should be found
test_pass_with_ac_in_description() {
    _snapshot_fail
    local desc=$'## Acceptance Criteria\n- [ ] First criterion\n- [ ] Second criterion'
    local json
    json=$(_make_ticket_json "$desc" "")
    local output exit_code=0
    output=$(_run_sut_with_json "$json") || exit_code=$?
    assert_eq "test_pass_with_ac_in_description: exit 0" "0" "$exit_code"
    assert_contains "test_pass_with_ac_in_description: AC_CHECK pass" "AC_CHECK: pass" "$output"
    assert_pass_if_clean "test_pass_with_ac_in_description"
}

# test_pass_with_ac_in_comment: AC section in comment body should be found
test_pass_with_ac_in_comment() {
    _snapshot_fail
    local comment_body=$'## Acceptance Criteria\n- [ ] Criterion from comment'
    local json
    json=$(_make_ticket_json "" "$comment_body")
    local output exit_code=0
    output=$(_run_sut_with_json "$json") || exit_code=$?
    assert_eq "test_pass_with_ac_in_comment: exit 0" "0" "$exit_code"
    assert_contains "test_pass_with_ac_in_comment: AC_CHECK pass" "AC_CHECK: pass" "$output"
    assert_pass_if_clean "test_pass_with_ac_in_comment"
}

# test_fail_with_no_ac: no AC section should fail
test_fail_with_no_ac() {
    _snapshot_fail
    local json
    json=$(_make_ticket_json "Just a plain description" "A comment without criteria")
    local output exit_code=0
    output=$(_run_sut_with_json "$json") || exit_code=$?
    assert_eq "test_fail_with_no_ac: exit 1" "1" "$exit_code"
    assert_contains "test_fail_with_no_ac: AC_CHECK fail" "AC_CHECK: fail" "$output"
    assert_pass_if_clean "test_fail_with_no_ac"
}

# test_pass_with_json_v3_format: core regression — v3 JSON must be parsed, not treated as markdown
test_pass_with_json_v3_format() {
    _snapshot_fail
    local desc=$'## Acceptance Criteria\n- [ ] The script parses v3 JSON correctly'
    local json
    json=$(_make_ticket_json "$desc" "")
    local output exit_code=0
    output=$(_run_sut_with_json "$json") || exit_code=$?
    assert_eq "test_pass_with_json_v3_format: exit 0" "0" "$exit_code"
    assert_contains "test_pass_with_json_v3_format: 1 criterion" "1 criteria" "$output"
    assert_pass_if_clean "test_pass_with_json_v3_format"
}

# ── Runner ────────────────────────────────────────────────────────────────────

test_pass_with_ac_in_description
test_pass_with_ac_in_comment
test_fail_with_no_ac
test_pass_with_json_v3_format

print_summary
