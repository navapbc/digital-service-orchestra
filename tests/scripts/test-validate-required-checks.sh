#!/usr/bin/env bash
# tests/scripts/test-validate-required-checks.sh
# Behavioral tests for validate-required-checks.sh
#
# Usage: bash tests/scripts/test-validate-required-checks.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

SCRIPT="$REPO_ROOT/plugins/dso/scripts/onboarding/validate-required-checks.sh"

# Shared cleanup: accumulate all temp dirs in one array, clean up once at exit
_TMP_DIRS=()
trap 'rm -rf "${_TMP_DIRS[@]}"' EXIT

echo "=== test-validate-required-checks.sh ==="

# -- test_script_exists -------------------------------------------------------
# Script exists and is executable.
_snapshot_fail
assert_eq "test_script_exists: file present" "true" "$([[ -f "$SCRIPT" ]] && echo true || echo false)"
assert_eq "test_script_exists: executable" "true" "$([[ -x "$SCRIPT" ]] && echo true || echo false)"
assert_pass_if_clean "test_script_exists"

# -- test_all_names_match_exits_zero ------------------------------------------
# All check names resolve to real job names → exit 0.
_snapshot_fail
TMP_DIR="$(mktemp -d)"
_TMP_DIRS+=("$TMP_DIR")

CHECKS_FILE="$(mktemp "$TMP_DIR/checks.XXXXXX")"
cat > "$CHECKS_FILE" <<'EOF'
# required checks
ShellCheck
Lint Python (ruff)
EOF

WORKFLOWS_DIR="$TMP_DIR/workflows"
mkdir -p "$WORKFLOWS_DIR"
cat > "$WORKFLOWS_DIR/ci.yml" <<'EOF'
name: CI
jobs:
  shellcheck:
    name: ShellCheck
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
  lint-python:
    name: Lint Python (ruff)
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
EOF

rc=0
bash "$SCRIPT" --checks-file "$CHECKS_FILE" --workflows-dir "$WORKFLOWS_DIR" 2>/dev/null || rc=$?
assert_eq "test_all_names_match_exits_zero exit" "0" "$rc"
assert_pass_if_clean "test_all_names_match_exits_zero"

# -- test_unmatched_name_exits_nonzero ----------------------------------------
# One check name has no matching job → exit 1.
_snapshot_fail
TMP_DIR2="$(mktemp -d)"
_TMP_DIRS+=("$TMP_DIR2")

CHECKS_FILE2="$(mktemp "$TMP_DIR2/checks.XXXXXX")"
cat > "$CHECKS_FILE2" <<'EOF'
ShellCheck
NonexistentJob
EOF

WORKFLOWS_DIR2="$TMP_DIR2/workflows"
mkdir -p "$WORKFLOWS_DIR2"
cat > "$WORKFLOWS_DIR2/ci.yml" <<'EOF'
name: CI
jobs:
  shellcheck:
    name: ShellCheck
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
EOF

rc2=0
bash "$SCRIPT" --checks-file "$CHECKS_FILE2" --workflows-dir "$WORKFLOWS_DIR2" 2>/dev/null || rc2=$?
assert_eq "test_unmatched_name_exits_nonzero exit" "1" "$rc2"
assert_pass_if_clean "test_unmatched_name_exits_nonzero"

# -- test_matrix_expansion ----------------------------------------------------
# Matrix-expanded job names resolve correctly.
_snapshot_fail
TMP_DIR3="$(mktemp -d)"
_TMP_DIRS+=("$TMP_DIR3")

CHECKS_FILE3="$(mktemp "$TMP_DIR3/checks.XXXXXX")"
cat > "$CHECKS_FILE3" <<'EOF'
Ticket tests (linux-bash4)
EOF

WORKFLOWS_DIR3="$TMP_DIR3/workflows"
mkdir -p "$WORKFLOWS_DIR3"
cat > "$WORKFLOWS_DIR3/ticket-platform-matrix.yml" <<'EOF'
name: ticket-platform-matrix
jobs:
  ticket-platform-tests:
    name: "Ticket tests (${{ matrix.name }})"
    runs-on: ubuntu-latest
    strategy:
      matrix:
        include:
          - name: linux-bash4
            os: ubuntu-latest
          - name: macos-bash3
            os: macos-latest
    steps:
      - run: echo ok
EOF

rc3=0
bash "$SCRIPT" --checks-file "$CHECKS_FILE3" --workflows-dir "$WORKFLOWS_DIR3" 2>/dev/null || rc3=$?
assert_eq "test_matrix_expansion exit" "0" "$rc3"
assert_pass_if_clean "test_matrix_expansion"

# -- test_ignores_comment_lines -----------------------------------------------
# Checks file with only comment lines → nothing to validate → exit 0.
_snapshot_fail
TMP_DIR4="$(mktemp -d)"
_TMP_DIRS+=("$TMP_DIR4")

CHECKS_FILE4="$(mktemp "$TMP_DIR4/checks.XXXXXX")"
cat > "$CHECKS_FILE4" <<'EOF'
# this is a comment
EOF

WORKFLOWS_DIR4="$TMP_DIR4/workflows"
mkdir -p "$WORKFLOWS_DIR4"
# Workflows dir is empty — no YAML files, nothing to parse
rc4=0
bash "$SCRIPT" --checks-file "$CHECKS_FILE4" --workflows-dir "$WORKFLOWS_DIR4" 2>/dev/null || rc4=$?
assert_eq "test_ignores_comment_lines exit" "0" "$rc4"
assert_pass_if_clean "test_ignores_comment_lines"

# -- test_empty_workflows_dir_with_checks_exits_nonzero -----------------------
# Non-empty checks file against an empty workflows dir → all checks unmatched → exit 1.
# This covers the mapfile empty-string edge case fixed in validate-required-checks.sh.
_snapshot_fail
TMP_DIR5="$(mktemp -d)"
_TMP_DIRS+=("$TMP_DIR5")

CHECKS_FILE5="$(mktemp "$TMP_DIR5/checks.XXXXXX")"
cat > "$CHECKS_FILE5" <<'EOF'
SomeRequiredCheck
EOF

WORKFLOWS_DIR5="$TMP_DIR5/workflows"
mkdir -p "$WORKFLOWS_DIR5"
# No YAML files in WORKFLOWS_DIR5 — python3 returns empty output
rc5=0
bash "$SCRIPT" --checks-file "$CHECKS_FILE5" --workflows-dir "$WORKFLOWS_DIR5" 2>/dev/null || rc5=$?
assert_eq "test_empty_workflows_dir_with_checks_exits_nonzero exit" "1" "$rc5"
assert_pass_if_clean "test_empty_workflows_dir_with_checks_exits_nonzero"

# ── MARKER BOUNDARY ──────────────────────────────────────────────────────
# The four tests below remain failing until update-required-checks-manifest.sh is
# created (T4) and validate-required-checks.sh gains duplicate/malformed-entry
# rejection (T4). They MUST fail before T4 is implemented.
#

UPDATE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/update-required-checks-manifest.sh"

# -- test_update_manifest_adds_merge_pipeline_checks --------------------------
# update-required-checks-manifest.sh adds 'merge-pipeline-checks' to the
# main-branch manifest when it is missing. review-sub-pr is intentionally NOT
# in REQUIRED_ENTRIES — see the rationale comment in
# update-required-checks-manifest.sh (it fires only on PRs targeting sub-PR
# branches and would deadlock every PR to main if required there).
_snapshot_fail
TMP_DIR6="$(mktemp -d)"
_TMP_DIRS+=("$TMP_DIR6")

MANIFEST6="$(mktemp "$TMP_DIR6/required-checks.XXXXXX")"
cat > "$MANIFEST6" <<'EOF'
# existing checks
ShellCheck
Lint Python (ruff)
EOF

rc6=0
bash "$UPDATE_SCRIPT" --checks-file "$MANIFEST6" 2>/dev/null || rc6=$?
assert_eq "test_update_manifest_adds_merge_pipeline_checks exit" "0" "$rc6"

# Verify 'merge-pipeline-checks' was added to the manifest.
added6=false
grep -q 'merge-pipeline-checks' "$MANIFEST6" 2>/dev/null && added6=true
assert_eq "test_update_manifest_adds_merge_pipeline_checks entry-present" "true" "$added6"

# Negative assertion: review-sub-pr must NOT be added by this script — it
# belongs on the sub-PR ruleset, not the main-branch manifest.
not_added6=true
grep -q '^review-sub-pr$' "$MANIFEST6" 2>/dev/null && not_added6=false
assert_eq "test_update_manifest_adds_merge_pipeline_checks review-sub-pr absent" "true" "$not_added6"

assert_pass_if_clean "test_update_manifest_adds_merge_pipeline_checks"

# -- test_update_manifest_idempotent ------------------------------------------
# update-required-checks-manifest.sh is a no-op when both entries already
# exist.  Running it twice must produce identical manifest content.
_snapshot_fail
TMP_DIR7="$(mktemp -d)"
_TMP_DIRS+=("$TMP_DIR7")

MANIFEST7="$(mktemp "$TMP_DIR7/required-checks.XXXXXX")"
cat > "$MANIFEST7" <<'EOF'
# pre-populated checks
review-sub-pr
merge-pipeline-checks
ShellCheck
EOF

content_before7="$(cat "$MANIFEST7" 2>/dev/null || true)"

rc7=0
bash "$UPDATE_SCRIPT" --checks-file "$MANIFEST7" 2>/dev/null || rc7=$?
assert_eq "test_update_manifest_idempotent exit" "0" "$rc7"

content_after7="$(cat "$MANIFEST7" 2>/dev/null || true)"
assert_eq "test_update_manifest_idempotent manifest-unchanged" "$content_before7" "$content_after7"
assert_pass_if_clean "test_update_manifest_idempotent"

# -- test_validate_rejects_duplicate_entries ----------------------------------
# validate-required-checks.sh exits non-zero when the manifest contains
# duplicate entries.
_snapshot_fail
TMP_DIR8="$(mktemp -d)"
_TMP_DIRS+=("$TMP_DIR8")

CHECKS_FILE8="$(mktemp "$TMP_DIR8/checks.XXXXXX")"
cat > "$CHECKS_FILE8" <<'EOF'
ShellCheck
ShellCheck
EOF

WORKFLOWS_DIR8="$TMP_DIR8/workflows"
mkdir -p "$WORKFLOWS_DIR8"
cat > "$WORKFLOWS_DIR8/ci.yml" <<'EOF'
name: CI
jobs:
  shellcheck:
    name: ShellCheck
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
EOF

rc8=0
bash "$SCRIPT" --checks-file "$CHECKS_FILE8" --workflows-dir "$WORKFLOWS_DIR8" 2>/dev/null || rc8=$?
assert_eq "test_validate_rejects_duplicate_entries exit" "1" "$rc8"
assert_pass_if_clean "test_validate_rejects_duplicate_entries"

# -- test_validate_rejects_malformed_entries ----------------------------------
# validate-required-checks.sh exits non-zero when the manifest contains
# malformed entries (lines with leading/trailing special characters that would
# never match a real GitHub Actions job name).
_snapshot_fail
TMP_DIR9="$(mktemp -d)"
_TMP_DIRS+=("$TMP_DIR9")

CHECKS_FILE9="$(mktemp "$TMP_DIR9/checks.XXXXXX")"
cat > "$CHECKS_FILE9" <<'EOF'
  - invalid-yaml-list-entry
EOF

WORKFLOWS_DIR9="$TMP_DIR9/workflows"
mkdir -p "$WORKFLOWS_DIR9"
cat > "$WORKFLOWS_DIR9/ci.yml" <<'EOF'
name: CI
jobs:
  shellcheck:
    name: ShellCheck
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
EOF

rc9=0
bash "$SCRIPT" --checks-file "$CHECKS_FILE9" --workflows-dir "$WORKFLOWS_DIR9" 2>/dev/null || rc9=$?
assert_eq "test_validate_rejects_malformed_entries exit" "1" "$rc9"
assert_pass_if_clean "test_validate_rejects_malformed_entries"

print_summary
