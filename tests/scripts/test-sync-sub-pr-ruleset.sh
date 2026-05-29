#!/usr/bin/env bash
# tests/scripts/test-sync-sub-pr-ruleset.sh
# Behavioral tests for plugins/dso/scripts/sync-sub-pr-ruleset.sh.
#
# Coverage:
#   1. test_script_exists
#   2. test_shellcheck_clean
#   3. test_help_outputs_usage
#   4. test_unknown_flag_exits_nonzero
#   5. test_ruleset_not_found_exits_nonzero
#   6. test_dry_run_drift_detected     — allowlist-shaped ruleset → PATCH to negative-list
#   7. test_dry_run_in_sync            — already negative-list → SKIP, no PATCH
#
# Usage: bash tests/scripts/test-sync-sub-pr-ruleset.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/sync-sub-pr-ruleset.sh"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-sync-sub-pr-ruleset.sh ==="

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
assert_contains "test_help_outputs_usage: documents --dry-run" "--dry-run" "$help_out"
assert_pass_if_clean "test_help_outputs_usage"

# ── test_unknown_flag_exits_nonzero ───────────────────────────────────────────
_snapshot_fail
unk_rc=0
bash "$SCRIPT" --not-a-real-flag >/dev/null 2>&1 || unk_rc=$?
assert_ne "test_unknown_flag_exits_nonzero: exit non-zero" "0" "$unk_rc"
assert_pass_if_clean "test_unknown_flag_exits_nonzero"

# ── test_ruleset_not_found_exits_nonzero ──────────────────────────────────────
# gh stub returns empty ruleset list → script must exit 1 with a clear error.
_snapshot_fail
nf_tmp="$(mktemp -d)"
trap 'rm -rf "$nf_tmp"' EXIT
nf_stub="$nf_tmp/gh"
cat > "$nf_stub" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" && "${2:-}" =~ /rulesets$ ]]; then echo "[]"; exit 0; fi
exit 0
STUB
chmod +x "$nf_stub"
nf_rc=0
nf_out="$(PATH="$nf_tmp:$PATH" bash "$SCRIPT" --repo test/repo 2>&1)" || nf_rc=$?
assert_eq "test_ruleset_not_found_exits_nonzero: exit 1" "1" "$nf_rc"
assert_contains "test_ruleset_not_found_exits_nonzero: mentions ruleset not found" \
    "not found" "$nf_out"
assert_pass_if_clean "test_ruleset_not_found_exits_nonzero"

# ── test_dry_run_drift_detected ───────────────────────────────────────────────
# Mock gh: live ruleset is the old allowlist shape → script detects drift,
# emits DECISION: DRY-RUN PATCH, includes ~ALL in expected include, exits 0.
_snapshot_fail
dr_tmp="$(mktemp -d)"
dr_stub="$dr_tmp/gh"
cat > "$dr_stub" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" && "${2:-}" =~ /rulesets$ ]]; then
    echo '[{"id": 42, "name": "DSO Sub-PR Review Enforcement"}]'
    exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" =~ /rulesets/42$ ]]; then
    cat <<'JSON'
{
  "id": 42,
  "name": "DSO Sub-PR Review Enforcement",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/heads/session/**","refs/heads/worktree-**"], "exclude": []}},
  "bypass_actors": [],
  "rules": []
}
JSON
    exit 0
fi
exit 0
STUB
chmod +x "$dr_stub"
dr_rc=0
dr_out="$(PATH="$dr_tmp:$PATH" bash "$SCRIPT" --repo test/repo --dry-run 2>&1)" || dr_rc=$?
assert_eq "test_dry_run_drift_detected: exit 0" "0" "$dr_rc"
assert_contains "test_dry_run_drift_detected: DECISION DRY-RUN PATCH" \
    "DECISION: DRY-RUN PATCH" "$dr_out"
assert_contains "test_dry_run_drift_detected: expected include ~ALL" \
    '"~ALL"' "$dr_out"
assert_contains "test_dry_run_drift_detected: expected exclude refs/heads/main" \
    '"refs/heads/main"' "$dr_out"
# Negative: dry-run MUST NOT actually PATCH.
_patched="no"
if echo "$dr_out" | grep -q "Applying PATCH to ruleset"; then _patched="yes"; fi
assert_eq "test_dry_run_drift_detected: no live PATCH applied" "no" "$_patched"
assert_pass_if_clean "test_dry_run_drift_detected"

# ── test_dry_run_in_sync ──────────────────────────────────────────────────────
# Mock gh: live ruleset already matches negative-list shape → SKIP.
_snapshot_fail
sy_tmp="$(mktemp -d)"
sy_stub="$sy_tmp/gh"
cat > "$sy_stub" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" && "${2:-}" =~ /rulesets$ ]]; then
    echo '[{"id": 42, "name": "DSO Sub-PR Review Enforcement"}]'
    exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" =~ /rulesets/42$ ]]; then
    cat <<'JSON'
{
  "id": 42,
  "name": "DSO Sub-PR Review Enforcement",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~ALL"], "exclude": ["refs/heads/main"]}},
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
sy_out="$(PATH="$sy_tmp:$PATH" bash "$SCRIPT" --repo test/repo --dry-run 2>&1)" || sy_rc=$?
assert_eq "test_dry_run_in_sync: exit 0" "0" "$sy_rc"
assert_contains "test_dry_run_in_sync: DECISION SKIP" "DECISION: SKIP" "$sy_out"
assert_pass_if_clean "test_dry_run_in_sync"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
