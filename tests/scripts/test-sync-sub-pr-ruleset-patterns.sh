#!/usr/bin/env bash
# tests/scripts/test-sync-sub-pr-ruleset-patterns.sh
# Behavioral tests for plugins/dso/scripts/sync-sub-pr-ruleset-patterns.sh.
#
# Coverage:
#   1. test_script_exists                    — script present and executable
#   2. test_shellcheck_clean                 — lint-clean (excluding style-only nits)
#   3. test_help_outputs_usage               — -h prints usage
#   4. test_unknown_flag_exits_nonzero       — invalid arg rejected
#   5. test_missing_patterns_file_errors     — bad --patterns-file path → exit 1
#   6. test_empty_patterns_file_errors       — comments-only file → exit 1 (fail-closed)
#   7. test_dry_run_drift_detected           — patterns file mismatches mocked ruleset → DECISION: DRY-RUN PATCH
#   8. test_dry_run_in_sync                  — patterns file matches mocked ruleset → DECISION: SKIP
#
# Usage: bash tests/scripts/test-sync-sub-pr-ruleset-patterns.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/sync-sub-pr-ruleset-patterns.sh"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-sync-sub-pr-ruleset-patterns.sh ==="

# ── test_script_exists ────────────────────────────────────────────────────────
_snapshot_fail
if [[ -f "$SCRIPT" && -x "$SCRIPT" ]]; then
    actual_exists="exists"
else
    actual_exists="missing"
fi
assert_eq "test_script_exists: file present and executable" "exists" "$actual_exists"
assert_pass_if_clean "test_script_exists"

# ── test_shellcheck_clean ─────────────────────────────────────────────────────
# Fail on errors only (exit code), not style warnings — matches sibling tests.
_snapshot_fail
sc_rc=0
shellcheck "$SCRIPT" >/dev/null 2>&1 || sc_rc=$?
assert_eq "test_shellcheck_clean: shellcheck exits 0" "0" "$sc_rc"
assert_pass_if_clean "test_shellcheck_clean"

# ── test_help_outputs_usage ───────────────────────────────────────────────────
_snapshot_fail
help_out="$(bash "$SCRIPT" -h 2>&1)"
help_rc=$?
assert_eq "test_help_outputs_usage: exit 0" "0" "$help_rc"
assert_contains "test_help_outputs_usage: includes 'Usage:'" "Usage:" "$help_out"
assert_contains "test_help_outputs_usage: includes --dry-run flag" "--dry-run" "$help_out"
assert_pass_if_clean "test_help_outputs_usage"

# ── test_unknown_flag_exits_nonzero ───────────────────────────────────────────
_snapshot_fail
unk_rc=0
bash "$SCRIPT" --not-a-real-flag-xyz >/dev/null 2>&1 || unk_rc=$?
assert_ne "test_unknown_flag_exits_nonzero: exit non-zero" "0" "$unk_rc"
assert_pass_if_clean "test_unknown_flag_exits_nonzero"

# ── test_missing_patterns_file_errors ─────────────────────────────────────────
# When --patterns-file points at a nonexistent path, the script should exit 1
# before any API call (so we don't even need a gh stub).
_snapshot_fail
mp_rc=0
mp_out="$(bash "$SCRIPT" \
    --repo test-owner/test-repo \
    --patterns-file /nonexistent/path/sub-pr-branch-patterns.txt \
    2>&1)" || mp_rc=$?
assert_eq "test_missing_patterns_file_errors: exit 1" "1" "$mp_rc"
assert_contains "test_missing_patterns_file_errors: mentions patterns file path" \
    "patterns file not found" "$mp_out"
assert_pass_if_clean "test_missing_patterns_file_errors"

# ── test_empty_patterns_file_errors ───────────────────────────────────────────
# Comments-only file → fail-closed; do NOT PATCH the ruleset to an empty array.
_snapshot_fail
ep_tmp="$(mktemp -d)"
trap 'rm -rf "$ep_tmp"' EXIT
ep_file="$ep_tmp/patterns.txt"
cat > "$ep_file" <<'EOF'
# this file is comments only
# no active patterns
EOF
ep_rc=0
ep_out="$(bash "$SCRIPT" \
    --repo test-owner/test-repo \
    --patterns-file "$ep_file" \
    2>&1)" || ep_rc=$?
assert_eq "test_empty_patterns_file_errors: exit 1" "1" "$ep_rc"
assert_contains "test_empty_patterns_file_errors: mentions zero active patterns" \
    "zero active patterns" "$ep_out"
assert_pass_if_clean "test_empty_patterns_file_errors"

# ── test_dry_run_drift_detected ───────────────────────────────────────────────
# Mock gh: live ruleset has 2 patterns, source-of-truth has 3 → drift, exit 0
# (dry-run), and DECISION line says "DRY-RUN PATCH".
_snapshot_fail
dr_tmp="$(mktemp -d)"
dr_patterns="$dr_tmp/patterns.txt"
cat > "$dr_patterns" <<'EOF'
# example patterns
session/**
worktree-**
fix-**
EOF

# gh stub: returns ruleset list + ruleset detail with only 2 of the 3 patterns.
dr_stub="$dr_tmp/gh"
cat > "$dr_stub" <<'STUB'
#!/usr/bin/env bash
# Args: api /repos/<repo>/rulesets — list
# Args: api /repos/<repo>/rulesets/<id> — detail
if [[ "${1:-}" == "api" && "${2:-}" =~ /rulesets$ ]]; then
    cat <<'JSON'
[{"id": 42, "name": "DSO Sub-PR Review Enforcement"}]
JSON
    exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" =~ /rulesets/42$ ]]; then
    cat <<'JSON'
{
  "id": 42,
  "name": "DSO Sub-PR Review Enforcement",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/heads/session/**", "refs/heads/worktree-**"], "exclude": []}},
  "bypass_actors": [],
  "rules": []
}
JSON
    exit 0
fi
echo "STUB_OTHER: $*" >&2
exit 0
STUB
chmod +x "$dr_stub"

dr_rc=0
dr_out="$(PATH="$dr_tmp:$PATH" bash "$SCRIPT" \
    --repo test-owner/test-repo \
    --patterns-file "$dr_patterns" \
    --dry-run 2>&1)" || dr_rc=$?
assert_eq "test_dry_run_drift_detected: exit 0" "0" "$dr_rc"
assert_contains "test_dry_run_drift_detected: DECISION: DRY-RUN PATCH" \
    "DECISION: DRY-RUN PATCH" "$dr_out"
assert_contains "test_dry_run_drift_detected: includes missing pattern fix-**" \
    "refs/heads/fix-**" "$dr_out"
# Negative: must NOT execute the actual PUT
assert_not_contains_check="present"
if echo "$dr_out" | grep -q "Applying PATCH to ruleset"; then assert_not_contains_check="absent"; fi
assert_eq "test_dry_run_drift_detected: no live PATCH applied" "present" "$assert_not_contains_check"
assert_pass_if_clean "test_dry_run_drift_detected"

# ── test_dry_run_in_sync ──────────────────────────────────────────────────────
# Mock gh: live ruleset matches the patterns file exactly → DECISION: SKIP.
_snapshot_fail
sy_tmp="$(mktemp -d)"
sy_patterns="$sy_tmp/patterns.txt"
cat > "$sy_patterns" <<'EOF'
session/**
worktree-**
EOF

sy_stub="$sy_tmp/gh"
cat > "$sy_stub" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" && "${2:-}" =~ /rulesets$ ]]; then
    cat <<'JSON'
[{"id": 42, "name": "DSO Sub-PR Review Enforcement"}]
JSON
    exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" =~ /rulesets/42$ ]]; then
    cat <<'JSON'
{
  "id": 42,
  "name": "DSO Sub-PR Review Enforcement",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/heads/session/**", "refs/heads/worktree-**"], "exclude": []}},
  "bypass_actors": [],
  "rules": []
}
JSON
    exit 0
fi
exit 0
STUB
chmod +x "$sy_stub"

sy_rc=0
sy_out="$(PATH="$sy_tmp:$PATH" bash "$SCRIPT" \
    --repo test-owner/test-repo \
    --patterns-file "$sy_patterns" \
    --dry-run 2>&1)" || sy_rc=$?
assert_eq "test_dry_run_in_sync: exit 0" "0" "$sy_rc"
assert_contains "test_dry_run_in_sync: DECISION: SKIP" "DECISION: SKIP" "$sy_out"
assert_pass_if_clean "test_dry_run_in_sync"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
