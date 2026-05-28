#!/usr/bin/env bash
# tests/scripts/test-promote-ruleset-required.sh
# Behavioral tests for plugins/dso/scripts/promote-ruleset-required.sh
#
# Tests:
#   1. test_script_exists              — script present and executable
#   2. test_all_three_subcommands      — all 3 subcommands appear in script body
#   3. test_shellcheck_clean           — shellcheck exits 0
#   4. test_no_subcommand_exits_1      — missing subcommand → exit 1
#   5. test_unknown_arg_exits_1        — unknown flag → exit 1
#   6. test_dry_run_stage_outputs      — --dry-run shows staged checks + no API calls
#   7. test_dry_run_promote_outputs    — --dry-run promote shows PATCH payload marker
#   8. test_idempotent_note_present    — idempotency language in staged-checks loop
#
# Usage: bash tests/scripts/test-promote-ruleset-required.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/promote-ruleset-required.sh"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-promote-ruleset-required.sh ==="

# ── Shared temp dir management ────────────────────────────────────────────────
_TMP_DIRS=()
_make_tmpdir() {
    local d
    d="$(mktemp -d)"
    _TMP_DIRS+=("$d")
    echo "$d"
}
trap 'rm -rf "${_TMP_DIRS[@]+"${_TMP_DIRS[@]}"}"' EXIT

# ── test_script_exists ────────────────────────────────────────────────────────
_snapshot_fail
assert_eq "test_script_exists: file present" \
    "exists" "$([[ -f "$SCRIPT" ]] && echo exists || echo missing)"
assert_eq "test_script_exists: executable bit set" \
    "executable" "$([[ -x "$SCRIPT" ]] && echo executable || echo not-executable)"
assert_pass_if_clean "test_script_exists"

# ── test_all_three_subcommands ────────────────────────────────────────────────
# All 3 subcommands must appear in the script body (AC verbatim check).
_snapshot_fail
_count="$(grep -cE 'stage-as-non-required|promote-to-required|list-status' "$SCRIPT" 2>/dev/null || echo 0)"
if [[ "$_count" -ge 3 ]]; then
    _sub_result="present"
else
    _sub_result="missing"
fi
assert_eq "test_all_three_subcommands: grep count>=3" "present" "$_sub_result"
assert_pass_if_clean "test_all_three_subcommands"

# ── test_shellcheck_clean ─────────────────────────────────────────────────────
_snapshot_fail
_sc_exit=0
shellcheck "$SCRIPT" 2>/dev/null || _sc_exit=$?
assert_eq "test_shellcheck_clean: shellcheck exits 0" "0" "$_sc_exit"
assert_pass_if_clean "test_shellcheck_clean"

# ── test_no_subcommand_exits_1 ────────────────────────────────────────────────
# Running the script without any subcommand must exit non-zero and emit an error.
_snapshot_fail
_no_sub_exit=0
_no_sub_out=""
_no_sub_out="$(DSO_DRY_RUN=1 bash "$SCRIPT" 2>&1 || true)"
bash "$SCRIPT" >/dev/null 2>&1 || _no_sub_exit=$?
assert_ne "test_no_subcommand_exits_1: exit code non-zero" "0" "$_no_sub_exit"
assert_contains "test_no_subcommand_exits_1: error mentions subcommand" \
    "subcommand" "$_no_sub_out"
assert_pass_if_clean "test_no_subcommand_exits_1"

# ── test_unknown_arg_exits_1 ──────────────────────────────────────────────────
_snapshot_fail
_unk_exit=0
bash "$SCRIPT" --unknown-flag-xyz >/dev/null 2>&1 || _unk_exit=$?
assert_ne "test_unknown_arg_exits_1: exit code non-zero" "0" "$_unk_exit"
assert_pass_if_clean "test_unknown_arg_exits_1"

# ── test_dry_run_stage_outputs ────────────────────────────────────────────────
# In dry-run mode, --stage-as-non-required must print the observation-window
# payload (enforcement=evaluate) and confirm no API calls are executed.
# No gh stub is needed because dry-run for stage-as-non-required exits before
# any API call (it only builds a local payload and prints it).
_snapshot_fail
_dr_tmpdir="$(_make_tmpdir)"
mkdir -p "$_dr_tmpdir/.github"
printf 'review-sub-pr\nmerge-pipeline-checks\n' > "$_dr_tmpdir/.github/required-checks.txt"

# Minimal gh stub (only repo view for auto-detect; not used when --repo is explicit)
_gh_stub="$_dr_tmpdir/gh"
cat > "$_gh_stub" <<'STUB'
#!/usr/bin/env bash
echo '{"nameWithOwner":"test-owner/test-repo"}'
exit 0
STUB
chmod +x "$_gh_stub"

_dr_out=""
_dr_exit=0
_dr_out="$(DSO_DRY_RUN=1 PATH="$_dr_tmpdir:$PATH" bash "$SCRIPT" \
    --stage-as-non-required \
    --non-interactive \
    --checks-file "$_dr_tmpdir/.github/required-checks.txt" \
    --repo "test-owner/test-repo" \
    2>&1)" || _dr_exit=$?

assert_eq "test_dry_run_stage_outputs: exits 0" "0" "$_dr_exit"
assert_contains "test_dry_run_stage_outputs: mentions review-sub-pr" \
    "review-sub-pr" "$_dr_out"
assert_contains "test_dry_run_stage_outputs: mentions evaluate enforcement" \
    "evaluate" "$_dr_out"
assert_contains "test_dry_run_stage_outputs: no API call note" \
    "not executed" "$_dr_out"
assert_pass_if_clean "test_dry_run_stage_outputs"

# ── test_dry_run_promote_outputs ──────────────────────────────────────────────
# --promote-to-required in dry-run should print the PATCH payload marker.
# The script calls gh api to fetch the existing ruleset; we write stub files
# with literal JSON content to avoid shell expansion issues.
_snapshot_fail
_dp_tmpdir="$(_make_tmpdir)"
mkdir -p "$_dp_tmpdir/.github"
printf 'review-sub-pr\nmerge-pipeline-checks\n' > "$_dp_tmpdir/.github/required-checks.txt"

# Write ruleset JSON fixtures to files (avoids heredoc variable-expansion issues)
_ruleset_list_file="$_dp_tmpdir/ruleset-list.json"
_ruleset_detail_file="$_dp_tmpdir/ruleset-detail.json"

cat > "$_ruleset_list_file" <<'RLJSON'
[{"id":42,"name":"DSO CI Enforcement"}]
RLJSON

cat > "$_ruleset_detail_file" <<'RDJSON'
{
  "id": 42,
  "name": "DSO CI Enforcement",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "bypass_actors": [],
  "rules": [
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [{"context": "ShellCheck"}]
      }
    }
  ]
}
RDJSON

# Write the gh stub referencing fixture files; use a quoted heredoc so that
# shell variables in the stub body (${1:-}, ${2:-}) are written literally.
_gh_promote_stub="$_dp_tmpdir/gh"
cat > "$_gh_promote_stub" <<STUB
#!/usr/bin/env bash
# Stub gh for promote-to-required dry-run
if [[ "\${1:-}" == "api" && "\${2:-}" == "/repos/test-owner/test-repo/rulesets" ]]; then
    cat "${_ruleset_list_file}"
elif [[ "\${1:-}" == "api" ]] && [[ "\${2:-}" =~ /rulesets/42 ]]; then
    cat "${_ruleset_detail_file}"
else
    echo "STUB_OTHER: \$*"
fi
exit 0
STUB
chmod +x "$_gh_promote_stub"

_dp_out=""
_dp_exit=0
_dp_out="$(DSO_DRY_RUN=1 PATH="$_dp_tmpdir:$PATH" bash "$SCRIPT" \
    --promote-to-required \
    --non-interactive \
    --checks-file "$_dp_tmpdir/.github/required-checks.txt" \
    --repo "test-owner/test-repo" \
    2>&1)" || _dp_exit=$?

assert_eq "test_dry_run_promote_outputs: exits 0" "0" "$_dp_exit"
assert_contains "test_dry_run_promote_outputs: mentions promote-to-required" \
    "promote-to-required" "$_dp_out"
assert_contains "test_dry_run_promote_outputs: no API call note" \
    "not executed" "$_dp_out"
assert_pass_if_clean "test_dry_run_promote_outputs"

# ── test_idempotent_note_present ──────────────────────────────────────────────
# The script must include idempotency logic (unique_by or no-op guard).
_snapshot_fail
_idem_result="present"
if ! grep -qE 'unique_by|idempotent|no.op' "$SCRIPT" 2>/dev/null; then
    _idem_result="absent"
fi
assert_eq "test_idempotent_note_present: idempotency mechanism" "present" "$_idem_result"
assert_pass_if_clean "test_idempotent_note_present"

# ── test_ruleset_names_includes_sub_pr (F1) ─────────────────────────────────
# RULESET_NAMES array must include both the main-branch and session-branch rulesets.
_snapshot_fail
_has_main="absent"
_has_sub_pr="absent"
if grep -qF 'DSO CI Enforcement' "$SCRIPT" 2>/dev/null; then _has_main="present"; fi
if grep -qF 'DSO Sub-PR Review Enforcement' "$SCRIPT" 2>/dev/null; then _has_sub_pr="present"; fi
assert_eq "test_ruleset_names_includes_sub_pr: main ruleset in RULESET_NAMES" "present" "$_has_main"
assert_eq "test_ruleset_names_includes_sub_pr: sub-PR ruleset in RULESET_NAMES" "present" "$_has_sub_pr"
assert_pass_if_clean "test_ruleset_names_includes_sub_pr"

# ── test_find_ruleset_id_accepts_name_param (F1) ────────────────────────────
# _find_ruleset_id must accept a second parameter for the ruleset name so
# the promote loop can look up each ruleset independently.
_snapshot_fail
_find_accepts_name="no"
if grep -qE '_find_ruleset_id' "$SCRIPT" 2>/dev/null && grep -qE '\$\{2:-' "$SCRIPT" 2>/dev/null; then _find_accepts_name="yes"; fi
assert_eq "test_find_ruleset_id_accepts_name_param: _find_ruleset_id accepts name param" "yes" "$_find_accepts_name"
assert_pass_if_clean "test_find_ruleset_id_accepts_name_param"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
