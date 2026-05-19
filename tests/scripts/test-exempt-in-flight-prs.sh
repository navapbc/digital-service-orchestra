#!/usr/bin/env bash
# tests/scripts/test-exempt-in-flight-prs.sh
# RED-phase behavioral tests for plugins/dso/scripts/exempt-in-flight-prs.sh
#
# Script under test: lists open PRs via gh, applies migration-grace label to
# each, and writes an exemption log to docs/migration-exemptions/sub-pr-cutover.jsonl.
#
# Behaviors under test:
#   1. test_labels_all_in_flight_prs — given 3 open PRs from mocked gh,
#      script invokes gh pr edit --add-label migration-grace for each PR number.
#   2. test_exemption_log_created — after running, the exemption log exists
#      at docs/migration-exemptions/sub-pr-cutover.jsonl and contains an entry
#      for each PR number with timestamp and exempting-rule fields.
#   3. test_idempotent_no_double_label — re-running when all PRs already carry
#      the migration-grace label does NOT issue another gh pr edit call for any PR.
#
# Usage: bash tests/scripts/test-exempt-in-flight-prs.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# RED MARKER: test_labels_all_in_flight_prs
# (script does not exist yet — all tests fail RED until T7 IMPL task is complete)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/exempt-in-flight-prs.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-exempt-in-flight-prs.sh ==="

# ── Temp dir pool ─────────────────────────────────────────────────────────────
_TMP_DIRS=()
_cleanup() { rm -rf "${_TMP_DIRS[@]+"${_TMP_DIRS[@]}"}"; }
trap _cleanup EXIT

new_tmpdir() {
    local d
    d="$(mktemp -d)"
    _TMP_DIRS+=("$d")
    echo "$d"
}

# ── Helper: build a mock bin dir with a controllable gh stub ─────────────────
# make_mock_bin BINDIR PR_JSON LABELS_JSON
#   BINDIR      — directory to write the mock gh binary into
#   PR_JSON     — JSON array returned by "gh pr list --state open --json ..."
#   LABELS_JSON — JSON array returned by "gh pr view <num> --json labels"
#                 (used to check whether migration-grace is already present)
make_mock_bin() {
    local bindir="$1"
    local pr_json="$2"
    local labels_json="${3:-[]}"
    local call_log="$bindir/gh-calls.log"

    mkdir -p "$bindir"
    cat > "$bindir/gh" <<GH_STUB
#!/usr/bin/env bash
echo "\$*" >> "$call_log"
if [[ "\$*" == *"pr list"* ]]; then
    echo '$pr_json'
    exit 0
fi
if [[ "\$*" == *"pr view"* && "\$*" == *"labels"* ]]; then
    echo '$labels_json'
    exit 0
fi
# gh pr edit --add-label: no-op, exit 0
exit 0
GH_STUB
    chmod +x "$bindir/gh"
    echo "$call_log"
}

# ── Helper: run the script in an isolated repo-like temp dir ─────────────────
# run_script MOCK_BINDIR REPO_DIR [extra env vars...]
# Executes exempt-in-flight-prs.sh with CWD=REPO_DIR and PATH prepended with MOCK_BINDIR.
# Returns combined stdout+stderr; caller checks exit code via `|| rc=$?`.
run_script() {
    local mock_bindir="$1"
    local repo_dir="$2"
    shift 2
    (cd "$repo_dir" && PATH="$mock_bindir:$PATH" bash "$SCRIPT" "$@" 2>&1)
}

# ── 1: test_labels_all_in_flight_prs ─────────────────────────────────────────
# Given 3 open PRs, the script must invoke `gh pr edit --add-label migration-grace`
# for each PR number (101, 102, 103).
echo ""
echo "--- test_labels_all_in_flight_prs ---"
_snapshot_fail

_t1_dir="$(new_tmpdir)"
_t1_pr_json='[{"number":101,"headRefName":"feature/a","headRefOid":"aaa111"},{"number":102,"headRefName":"feature/b","headRefOid":"bbb222"},{"number":103,"headRefName":"feature/c","headRefOid":"ccc333"}]'
_t1_call_log="$(make_mock_bin "$_t1_dir/bin" "$_t1_pr_json" '[]')"

_t1_rc=0
_t1_out="$(run_script "$_t1_dir/bin" "$_t1_dir")" || _t1_rc=$?

assert_eq "test_labels_all_in_flight_prs: exit 0" "0" "$_t1_rc"

_t1_calls=""
[[ -f "$_t1_call_log" ]] && _t1_calls="$(cat "$_t1_call_log")"

# Verify gh pr edit was called with --add-label migration-grace for each PR
_t1_labeled_101=0; [[ "$_t1_calls" == *"pr edit 101"*"--add-label migration-grace"* || "$_t1_calls" == *"pr edit"*"101"*"migration-grace"* ]] && _t1_labeled_101=1
_t1_labeled_102=0; [[ "$_t1_calls" == *"pr edit 102"*"--add-label migration-grace"* || "$_t1_calls" == *"pr edit"*"102"*"migration-grace"* ]] && _t1_labeled_102=1
_t1_labeled_103=0; [[ "$_t1_calls" == *"pr edit 103"*"--add-label migration-grace"* || "$_t1_calls" == *"pr edit"*"103"*"migration-grace"* ]] && _t1_labeled_103=1

assert_eq "test_labels_all_in_flight_prs: PR 101 labeled" "1" "$_t1_labeled_101"
assert_eq "test_labels_all_in_flight_prs: PR 102 labeled" "1" "$_t1_labeled_102"
assert_eq "test_labels_all_in_flight_prs: PR 103 labeled" "1" "$_t1_labeled_103"

assert_pass_if_clean "test_labels_all_in_flight_prs"

# ── 2: test_exemption_log_created ────────────────────────────────────────────
# After running, docs/migration-exemptions/sub-pr-cutover.jsonl must exist and
# contain one JSONL entry per PR with pr_number, sha, timestamp, and exempting_rule.
echo ""
echo "--- test_exemption_log_created ---"
_snapshot_fail

_t2_dir="$(new_tmpdir)"
_t2_pr_json='[{"number":201,"headRefName":"feat/x","headRefOid":"ddd444"},{"number":202,"headRefName":"feat/y","headRefOid":"eee555"},{"number":203,"headRefName":"feat/z","headRefOid":"fff666"}]'
make_mock_bin "$_t2_dir/bin" "$_t2_pr_json" '[]' >/dev/null

_t2_rc=0
run_script "$_t2_dir/bin" "$_t2_dir" >/dev/null 2>&1 || _t2_rc=$?

assert_eq "test_exemption_log_created: exit 0" "0" "$_t2_rc"

_t2_log="$_t2_dir/docs/migration-exemptions/sub-pr-cutover.jsonl"
_t2_log_exists=0
[[ -f "$_t2_log" ]] && _t2_log_exists=1
assert_eq "test_exemption_log_created: log file exists" "1" "$_t2_log_exists"

if [[ "$_t2_log_exists" -eq 1 ]]; then
    _t2_log_content="$(cat "$_t2_log")"

    # Each PR must appear in the log
    _t2_has_201=0; [[ "$_t2_log_content" == *"201"* ]] && _t2_has_201=1
    _t2_has_202=0; [[ "$_t2_log_content" == *"202"* ]] && _t2_has_202=1
    _t2_has_203=0; [[ "$_t2_log_content" == *"203"* ]] && _t2_has_203=1
    assert_eq "test_exemption_log_created: log contains PR 201" "1" "$_t2_has_201"
    assert_eq "test_exemption_log_created: log contains PR 202" "1" "$_t2_has_202"
    assert_eq "test_exemption_log_created: log contains PR 203" "1" "$_t2_has_203"

    # Each entry must carry a timestamp field
    _t2_has_timestamp=0; [[ "$_t2_log_content" == *"timestamp"* ]] && _t2_has_timestamp=1
    assert_eq "test_exemption_log_created: log has timestamp field" "1" "$_t2_has_timestamp"

    # Each entry must carry an exempting_rule field
    _t2_has_rule=0; [[ "$_t2_log_content" == *"exempting_rule"* ]] && _t2_has_rule=1
    assert_eq "test_exemption_log_created: log has exempting_rule field" "1" "$_t2_has_rule"

    # Each entry must carry a sha field
    _t2_has_sha=0; [[ "$_t2_log_content" == *"sha"* ]] && _t2_has_sha=1
    assert_eq "test_exemption_log_created: log has sha field" "1" "$_t2_has_sha"
fi

assert_pass_if_clean "test_exemption_log_created"

# ── 3: test_idempotent_no_double_label ───────────────────────────────────────
# When all PRs already carry the migration-grace label, re-running must NOT
# issue another `gh pr edit --add-label migration-grace` call for any of them.
echo ""
echo "--- test_idempotent_no_double_label ---"
_snapshot_fail

_t3_dir="$(new_tmpdir)"
_t3_pr_json='[{"number":301,"headRefName":"fix/p","headRefOid":"ggg777"},{"number":302,"headRefName":"fix/q","headRefOid":"hhh888"}]'
# Labels response includes migration-grace → script must skip gh pr edit calls
_t3_labels_json='[{"name":"migration-grace"}]'
_t3_call_log="$(make_mock_bin "$_t3_dir/bin" "$_t3_pr_json" "$_t3_labels_json")"

_t3_rc=0
run_script "$_t3_dir/bin" "$_t3_dir" >/dev/null 2>&1 || _t3_rc=$?

assert_eq "test_idempotent_no_double_label: exit 0" "0" "$_t3_rc"

_t3_calls=""
[[ -f "$_t3_call_log" ]] && _t3_calls="$(cat "$_t3_call_log")"

# Confirm no "pr edit ... --add-label migration-grace" calls were made
_t3_edit_called=0
if [[ "$_t3_calls" == *"pr edit"*"migration-grace"* ]]; then
    _t3_edit_called=1
fi
assert_eq "test_idempotent_no_double_label: no re-labeling when already labeled" "0" "$_t3_edit_called"

assert_pass_if_clean "test_idempotent_no_double_label"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
