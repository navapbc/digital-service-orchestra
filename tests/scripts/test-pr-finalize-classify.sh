#!/usr/bin/env bash
# tests/scripts/test-pr-finalize-classify.sh
# Behavioral tests for plugins/dso/scripts/pr-finalize-classify.sh
#
# Tests the 8 status codes (MERGED, CONFLICTING, CHECKS_FAILED, THREADS_UNRESOLVED,
# CHECKS_PENDING, READY_TO_MERGE, BLOCKED_BY_REVIEW, UNKNOWN), plus input validation
# and graceful-degradation edge cases.
#
# Strategy: mock `gh` as a shell function in a temp dir that is prepended to PATH.
# The script is invoked with PR_FINALIZE_SKIP_BRANCH_CHECK=1 to bypass the branch
# precondition (tests run detached from any PR branch).
#
# Usage: bash tests/scripts/test-pr-finalize-classify.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
CLASSIFIER="$REPO_ROOT/plugins/dso/scripts/pr-finalize-classify.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# run_classifier <pr_arg> [extra env vars...]
# Returns: sets _OUT (stdout), _RC (exit code)
run_classifier() {
    local pr_arg="$1"; shift
    local extra_env=("$@")
    _OUT=$(PR_FINALIZE_SKIP_BRANCH_CHECK=1 "${extra_env[@]}" bash "$CLASSIFIER" "$pr_arg" 2>/dev/null)
    _RC=$?
}

# json_field <field> <json>  — extracts a top-level string field from JSON via python3
json_field() {
    local field="$1" json="$2"
    python3 -c "import json,sys; print(json.loads('''$json''').get('$field',''))" 2>/dev/null
}

# json_payload_field <field> <json>
json_payload_field() {
    local field="$1" json="$2"
    python3 -c "import json,sys; d=json.loads('''$json'''); print(d.get('payload',{}).get('$field',''))" 2>/dev/null
}

# setup_mock_dir — creates a temp dir with a mock `gh` binary, returns path in _MOCK_DIR
setup_mock_dir() {
    _MOCK_DIR=$(mktemp -d)
}

# write_gh_mock <mock_dir> <repo_view_json> <pr_view_json> <checks_json> <graphql_json>
write_gh_mock() {
    local mock_dir="$1"
    local repo_view="$2"
    local pr_view="$3"
    local checks="$4"
    local graphql="$5"

    cat > "$mock_dir/gh" <<MOCK
#!/usr/bin/env bash
# Mock gh CLI
case "\$1 \$2 \$3" in
  "repo view --json")
    echo '$repo_view'
    ;;
  "pr view $6"*)
    echo '$pr_view'
    ;;
  "pr checks $6"*)
    echo '$checks'
    ;;
  "api graphql"*)
    echo '$graphql'
    ;;
  *)
    exit 1
    ;;
esac
MOCK
    chmod +x "$mock_dir/gh"
}

# Standard canned data helpers
REPO_JSON='{"owner":{"login":"testorg"},"name":"testrepo"}'
EMPTY_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
NO_CHECKS='[]'

pr_view_json() {
    # Args: state mergeable mergeStateStatus reviewDecision
    python3 -c "import json; print(json.dumps({'state':'$1','mergeable':'$2','mergeStateStatus':'$3','reviewDecision':'$4','url':'https://github.com/testorg/testrepo/pull/42','headRefOid':'abc123','headRefName':'feature-branch'}))"
}

# ---------------------------------------------------------------------------
# Test: input validation — missing argument
# ---------------------------------------------------------------------------
_OUT=$(PR_FINALIZE_SKIP_BRANCH_CHECK=1 bash "$CLASSIFIER" 2>/dev/null)
_RC=$?
_STATUS=$(json_field status "$_OUT")
assert_eq "missing_arg_exits_2" "2" "$_RC"
assert_eq "missing_arg_status_unknown" "UNKNOWN" "$_STATUS"

# ---------------------------------------------------------------------------
# Test: input validation — non-numeric PR number
# ---------------------------------------------------------------------------
# Need a mock gh for repo view before the numeric check fires
_MOCK_DIR=$(mktemp -d)
cat > "$_MOCK_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
echo '{"owner":{"login":"testorg"},"name":"testrepo"}'
MOCK
chmod +x "$_MOCK_DIR/gh"

_OUT=$(PR_FINALIZE_SKIP_BRANCH_CHECK=1 PATH="$_MOCK_DIR:$PATH" bash "$CLASSIFIER" "abc" 2>/dev/null)
_RC=$?
_STATUS=$(json_field status "$_OUT")
assert_eq "non_numeric_exits_2" "2" "$_RC"
assert_eq "non_numeric_status_unknown" "UNKNOWN" "$_STATUS"
rm -rf "$_MOCK_DIR"

# ---------------------------------------------------------------------------
# Simpler direct-write mock helper
# ---------------------------------------------------------------------------
write_scenario_mock() {
    local mock_dir="$1"
    local pr_json="$2"
    local checks_json="$3"
    local graphql_json="$4"

    # Write each canned response to a file; the mock script reads them.
    printf '%s' "$pr_json"      > "$mock_dir/pr_view.json"
    printf '%s' "$checks_json"  > "$mock_dir/checks.json"
    printf '%s' "$graphql_json" > "$mock_dir/graphql.json"
    printf '%s' "$REPO_JSON"    > "$mock_dir/repo.json"

    cat > "$mock_dir/gh" <<'MOCKSCRIPT'
#!/usr/bin/env bash
MOCK_DIR="$(cd "$(dirname "$0")" && pwd)"
case "$1 $2" in
  "repo view")
    cat "$MOCK_DIR/repo.json"
    ;;
  "pr view")
    cat "$MOCK_DIR/pr_view.json"
    ;;
  "pr checks")
    cat "$MOCK_DIR/checks.json"
    ;;
  "api graphql")
    cat "$MOCK_DIR/graphql.json"
    ;;
  *)
    exit 1
    ;;
esac
MOCKSCRIPT
    chmod +x "$mock_dir/gh"
}

# ---------------------------------------------------------------------------
# Test: MERGED — PR state is MERGED
# ---------------------------------------------------------------------------
_MD=$(mktemp -d)
_PV=$(pr_view_json "MERGED" "MERGED" "CLEAN" "APPROVED")
write_scenario_mock "$_MD" "$_PV" "$NO_CHECKS" "$EMPTY_THREADS"

_OUT=$(PR_FINALIZE_SKIP_BRANCH_CHECK=1 PATH="$_MD:$PATH" bash "$CLASSIFIER" "42" 2>/dev/null)
_RC=$?
assert_eq "merged_exit_0" "0" "$_RC"
assert_eq "merged_status" "MERGED" "$(json_field status "$_OUT")"
assert_ne "merged_pr_url_nonempty" "" "$(json_field pr_url "$_OUT")"
assert_ne "merged_head_sha_nonempty" "" "$(json_field head_sha "$_OUT")"
rm -rf "$_MD"

# ---------------------------------------------------------------------------
# Test: CONFLICTING — mergeable=CONFLICTING
# ---------------------------------------------------------------------------
_MD=$(mktemp -d)
_PV=$(pr_view_json "OPEN" "CONFLICTING" "DIRTY" "NONE")
write_scenario_mock "$_MD" "$_PV" "$NO_CHECKS" "$EMPTY_THREADS"

_OUT=$(PR_FINALIZE_SKIP_BRANCH_CHECK=1 PATH="$_MD:$PATH" bash "$CLASSIFIER" "42" 2>/dev/null)
_RC=$?
assert_eq "conflicting_exit_0" "0" "$_RC"
assert_eq "conflicting_status" "CONFLICTING" "$(json_field status "$_OUT")"
rm -rf "$_MD"

# ---------------------------------------------------------------------------
# Test: CHECKS_FAILED — one check with bucket=fail
# ---------------------------------------------------------------------------
_MD=$(mktemp -d)
_PV=$(pr_view_json "OPEN" "MERGEABLE" "BLOCKED" "NONE")
_CHECKS='[{"name":"ci/build","state":"FAILURE","bucket":"fail","link":"https://ci.example.com/1"}]'
write_scenario_mock "$_MD" "$_PV" "$_CHECKS" "$EMPTY_THREADS"

_OUT=$(PR_FINALIZE_SKIP_BRANCH_CHECK=1 PATH="$_MD:$PATH" bash "$CLASSIFIER" "42" 2>/dev/null)
_RC=$?
assert_eq "checks_failed_exit_0" "0" "$_RC"
assert_eq "checks_failed_status" "CHECKS_FAILED" "$(json_field status "$_OUT")"
# payload.failing_checks must be present and non-empty
_PAYLOAD_RAW=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps(d.get('payload',{})))" <<< "$_OUT" 2>/dev/null)
assert_contains "checks_failed_payload_has_failing" "ci/build" "$_PAYLOAD_RAW"
rm -rf "$_MD"

# ---------------------------------------------------------------------------
# Test: THREADS_UNRESOLVED — unresolved thread exists, checks pass
# ---------------------------------------------------------------------------
_MD=$(mktemp -d)
_PV=$(pr_view_json "OPEN" "MERGEABLE" "BLOCKED" "CHANGES_REQUESTED")
_GQL='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"T_1","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"body":"Fix this please","path":"src/foo.py","line":10,"author":{"login":"reviewer1"}}]}}]}}}}}'
write_scenario_mock "$_MD" "$_PV" "$NO_CHECKS" "$_GQL"

_OUT=$(PR_FINALIZE_SKIP_BRANCH_CHECK=1 PATH="$_MD:$PATH" bash "$CLASSIFIER" "42" 2>/dev/null)
_RC=$?
assert_eq "threads_unresolved_exit_0" "0" "$_RC"
assert_eq "threads_unresolved_status" "THREADS_UNRESOLVED" "$(json_field status "$_OUT")"
_PAYLOAD_RAW=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps(d.get('payload',{})))" <<< "$_OUT" 2>/dev/null)
assert_contains "threads_unresolved_payload_has_thread" "Fix this please" "$_PAYLOAD_RAW"
rm -rf "$_MD"

# ---------------------------------------------------------------------------
# Test: THREADS_UNRESOLVED skips resolved threads (only unresolved counted)
# ---------------------------------------------------------------------------
_MD=$(mktemp -d)
_PV=$(pr_view_json "OPEN" "MERGEABLE" "CLEAN" "APPROVED")
_GQL_RESOLVED='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"T_2","isResolved":true,"isOutdated":false,"comments":{"nodes":[{"body":"Already resolved","path":"src/bar.py","line":5,"author":{"login":"reviewer1"}}]}}]}}}}}'
write_scenario_mock "$_MD" "$_PV" "$NO_CHECKS" "$_GQL_RESOLVED"

_OUT=$(PR_FINALIZE_SKIP_BRANCH_CHECK=1 PATH="$_MD:$PATH" bash "$CLASSIFIER" "42" 2>/dev/null)
_RC=$?
# With resolved thread only, should fall through to READY_TO_MERGE
assert_eq "resolved_threads_not_blocked_exit_0" "0" "$_RC"
assert_ne "resolved_threads_not_unresolved" "THREADS_UNRESOLVED" "$(json_field status "$_OUT")"
rm -rf "$_MD"

# ---------------------------------------------------------------------------
# Test: CHECKS_PENDING — check with bucket=pending
# ---------------------------------------------------------------------------
_MD=$(mktemp -d)
_PV=$(pr_view_json "OPEN" "MERGEABLE" "BLOCKED" "NONE")
_CHECKS_PENDING='[{"name":"ci/test","state":"IN_PROGRESS","bucket":"pending","link":"https://ci.example.com/2"}]'
write_scenario_mock "$_MD" "$_PV" "$_CHECKS_PENDING" "$EMPTY_THREADS"

_OUT=$(PR_FINALIZE_SKIP_BRANCH_CHECK=1 PATH="$_MD:$PATH" bash "$CLASSIFIER" "42" 2>/dev/null)
_RC=$?
assert_eq "checks_pending_exit_0" "0" "$_RC"
assert_eq "checks_pending_status" "CHECKS_PENDING" "$(json_field status "$_OUT")"
_PENDING_COUNT=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('payload',{}).get('pending_count',0))" <<< "$_OUT" 2>/dev/null)
assert_eq "checks_pending_count_1" "1" "$_PENDING_COUNT"
rm -rf "$_MD"

# ---------------------------------------------------------------------------
# Test: READY_TO_MERGE — MERGEABLE + CLEAN + no checks + no threads
# ---------------------------------------------------------------------------
_MD=$(mktemp -d)
_PV=$(pr_view_json "OPEN" "MERGEABLE" "CLEAN" "APPROVED")
write_scenario_mock "$_MD" "$_PV" "$NO_CHECKS" "$EMPTY_THREADS"

_OUT=$(PR_FINALIZE_SKIP_BRANCH_CHECK=1 PATH="$_MD:$PATH" bash "$CLASSIFIER" "42" 2>/dev/null)
_RC=$?
assert_eq "ready_to_merge_exit_0" "0" "$_RC"
assert_eq "ready_to_merge_status" "READY_TO_MERGE" "$(json_field status "$_OUT")"
rm -rf "$_MD"

# ---------------------------------------------------------------------------
# Test: READY_TO_MERGE — MERGEABLE + UNSTABLE (also maps to ready)
# ---------------------------------------------------------------------------
_MD=$(mktemp -d)
_PV=$(pr_view_json "OPEN" "MERGEABLE" "UNSTABLE" "APPROVED")
write_scenario_mock "$_MD" "$_PV" "$NO_CHECKS" "$EMPTY_THREADS"

_OUT=$(PR_FINALIZE_SKIP_BRANCH_CHECK=1 PATH="$_MD:$PATH" bash "$CLASSIFIER" "42" 2>/dev/null)
_RC=$?
assert_eq "ready_to_merge_unstable_exit_0" "0" "$_RC"
assert_eq "ready_to_merge_unstable_status" "READY_TO_MERGE" "$(json_field status "$_OUT")"
rm -rf "$_MD"

# ---------------------------------------------------------------------------
# Test: BLOCKED_BY_REVIEW — MERGEABLE + BLOCKED
# ---------------------------------------------------------------------------
_MD=$(mktemp -d)
_PV=$(pr_view_json "OPEN" "MERGEABLE" "BLOCKED" "REVIEW_REQUIRED")
write_scenario_mock "$_MD" "$_PV" "$NO_CHECKS" "$EMPTY_THREADS"

_OUT=$(PR_FINALIZE_SKIP_BRANCH_CHECK=1 PATH="$_MD:$PATH" bash "$CLASSIFIER" "42" 2>/dev/null)
_RC=$?
assert_eq "blocked_by_review_exit_0" "0" "$_RC"
assert_eq "blocked_by_review_status" "BLOCKED_BY_REVIEW" "$(json_field status "$_OUT")"
rm -rf "$_MD"

# ---------------------------------------------------------------------------
# Test: UNKNOWN — classifier fallthrough (MERGEABLE=UNKNOWN, odd state)
# ---------------------------------------------------------------------------
_MD=$(mktemp -d)
_PV=$(pr_view_json "OPEN" "UNKNOWN" "UNKNOWN" "NONE")
write_scenario_mock "$_MD" "$_PV" "$NO_CHECKS" "$EMPTY_THREADS"

_OUT=$(PR_FINALIZE_SKIP_BRANCH_CHECK=1 PATH="$_MD:$PATH" bash "$CLASSIFIER" "42" 2>/dev/null)
_RC=$?
assert_eq "unknown_status" "UNKNOWN" "$(json_field status "$_OUT")"
rm -rf "$_MD"

# ---------------------------------------------------------------------------
# Test: output JSON is always valid JSON (even for UNKNOWN/error paths)
# ---------------------------------------------------------------------------
_OUT=$(PR_FINALIZE_SKIP_BRANCH_CHECK=1 bash "$CLASSIFIER" 2>/dev/null)
_JSON_VALID=$(python3 -c "import json,sys; json.loads('''$_OUT'''); print('ok')" 2>/dev/null || echo "fail")
assert_eq "missing_arg_output_is_valid_json" "ok" "$_JSON_VALID"

# ---------------------------------------------------------------------------
# Test: graceful degradation — GraphQL returns errors object → UNKNOWN
# ---------------------------------------------------------------------------
_MD=$(mktemp -d)
_PV=$(pr_view_json "OPEN" "MERGEABLE" "CLEAN" "APPROVED")
_GQL_ERR='{"errors":[{"message":"Not Found","type":"NOT_FOUND"}]}'
write_scenario_mock "$_MD" "$_PV" "$NO_CHECKS" "$_GQL_ERR"

_OUT=$(PR_FINALIZE_SKIP_BRANCH_CHECK=1 PATH="$_MD:$PATH" bash "$CLASSIFIER" "42" 2>/dev/null)
_RC=$?
# GraphQL error must surface as UNKNOWN (not silently treated as no threads)
assert_eq "graphql_error_exits_2" "2" "$_RC"
assert_eq "graphql_error_status_unknown" "UNKNOWN" "$(json_field status "$_OUT")"
rm -rf "$_MD"

# ---------------------------------------------------------------------------
# Test: graceful degradation — malformed JSON from gh pr checks → still classifies
# ---------------------------------------------------------------------------
_MD=$(mktemp -d)
_PV=$(pr_view_json "OPEN" "MERGEABLE" "CLEAN" "APPROVED")
_MALFORMED_CHECKS='not-json-at-all'
write_scenario_mock "$_MD" "$_PV" "$_MALFORMED_CHECKS" "$EMPTY_THREADS"

_OUT=$(PR_FINALIZE_SKIP_BRANCH_CHECK=1 PATH="$_MD:$PATH" bash "$CLASSIFIER" "42" 2>/dev/null)
_RC=$?
_STATUS=$(json_field status "$_OUT")
# Must not crash; must produce valid JSON with a status
assert_eq "malformed_checks_produces_valid_status" "0" "$_RC"
assert_ne "malformed_checks_status_nonempty" "" "$_STATUS"
rm -rf "$_MD"

# ---------------------------------------------------------------------------
# Test: graceful degradation — gh pr view fails → UNKNOWN exit 2
# ---------------------------------------------------------------------------
_MD=$(mktemp -d)
cat > "$_MD/gh" <<'MOCKSCRIPT'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view")
    echo '{"owner":{"login":"testorg"},"name":"testrepo"}'
    ;;
  "pr view")
    exit 1  # simulate gh failure
    ;;
  *)
    exit 1
    ;;
esac
MOCKSCRIPT
chmod +x "$_MD/gh"

_OUT=$(PR_FINALIZE_SKIP_BRANCH_CHECK=1 PATH="$_MD:$PATH" bash "$CLASSIFIER" "42" 2>/dev/null)
_RC=$?
assert_eq "gh_pr_view_fails_exits_2" "2" "$_RC"
assert_eq "gh_pr_view_fails_status_unknown" "UNKNOWN" "$(json_field status "$_OUT")"
rm -rf "$_MD"

# ---------------------------------------------------------------------------
# Test: JSON output always contains required fields
# ---------------------------------------------------------------------------
_MD=$(mktemp -d)
_PV=$(pr_view_json "MERGED" "MERGED" "CLEAN" "APPROVED")
write_scenario_mock "$_MD" "$_PV" "$NO_CHECKS" "$EMPTY_THREADS"

_OUT=$(PR_FINALIZE_SKIP_BRANCH_CHECK=1 PATH="$_MD:$PATH" bash "$CLASSIFIER" "42" 2>/dev/null)
_STATUS=$(json_field status "$_OUT")
_NEXT=$(json_field next_action "$_OUT")
assert_ne "output_has_status" "" "$_STATUS"
assert_ne "output_has_next_action" "" "$_NEXT"
# payload must be an object (not missing)
_HAS_PAYLOAD=$(python3 -c "import json,sys; d=json.loads('''$_OUT'''); print('ok' if isinstance(d.get('payload'),dict) else 'fail')" 2>/dev/null)
assert_eq "output_has_payload_object" "ok" "$_HAS_PAYLOAD"
rm -rf "$_MD"

# ---------------------------------------------------------------------------
# Test: CHECKS_FAILED takes priority over THREADS_UNRESOLVED
# ---------------------------------------------------------------------------
_MD=$(mktemp -d)
_PV=$(pr_view_json "OPEN" "MERGEABLE" "BLOCKED" "CHANGES_REQUESTED")
_CHECKS_FAIL='[{"name":"ci/lint","state":"FAILURE","bucket":"fail","link":"https://ci.example.com/3"}]'
_GQL_THREAD='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"T_3","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"body":"Review comment","path":"src/a.py","line":1,"author":{"login":"rev"}}]}}]}}}}}'
write_scenario_mock "$_MD" "$_PV" "$_CHECKS_FAIL" "$_GQL_THREAD"

_OUT=$(PR_FINALIZE_SKIP_BRANCH_CHECK=1 PATH="$_MD:$PATH" bash "$CLASSIFIER" "42" 2>/dev/null)
_RC=$?
assert_eq "checks_failed_before_threads_exit_0" "0" "$_RC"
assert_eq "checks_failed_before_threads_status" "CHECKS_FAILED" "$(json_field status "$_OUT")"
rm -rf "$_MD"

# ---------------------------------------------------------------------------
print_summary
