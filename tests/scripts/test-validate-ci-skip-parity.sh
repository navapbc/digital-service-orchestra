#!/usr/bin/env bash
# tests/scripts/test-validate-ci-skip-parity.sh
# Behavioral tests for validate-ci-skip-parity.sh
#
# Asserts that the set of job-name fields in ci-skip.yml equals
# (jobs in ci.yml) ∩ (entries in required-checks.txt).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

SCRIPT="$REPO_ROOT/plugins/dso/scripts/onboarding/validate-ci-skip-parity.sh"

_TMP_DIRS=()
trap 'rm -rf "${_TMP_DIRS[@]}"' EXIT

echo "=== test-validate-ci-skip-parity.sh ==="

# Helper: write a CI workflow with the given job names (one per line) under .github/workflows/ci.yml.
_write_ci_yml() {
    local path="$1"; shift
    {
        echo "name: CI"
        echo "on:"
        echo "  pull_request:"
        echo "    paths-ignore: ['**/*.md']"
        echo "jobs:"
        local i=0
        for n in "$@"; do
            i=$((i+1))
            echo "  job${i}:"
            echo "    name: \"${n}\""
            echo "    runs-on: ubuntu-latest"
            echo "    steps:"
            echo "      - run: echo ok"
        done
    } > "$path"
}

_write_skip_yml() {
    local path="$1"; shift
    {
        echo "name: CI Skip"
        echo "on:"
        echo "  pull_request:"
        echo "    paths: ['**/*.md']"
        echo "jobs:"
        local i=0
        for n in "$@"; do
            i=$((i+1))
            echo "  job${i}:"
            echo "    name: \"${n}\""
            echo "    runs-on: ubuntu-latest"
            echo "    steps:"
            echo "      - run: echo skipped"
        done
    } > "$path"
}

# -- test_script_exists -------------------------------------------------------
_snapshot_fail
assert_eq "test_script_exists: file present" "true" "$([[ -f "$SCRIPT" ]] && echo true || echo false)"
assert_eq "test_script_exists: executable" "true" "$([[ -x "$SCRIPT" ]] && echo true || echo false)"
assert_pass_if_clean "test_script_exists"

# -- test_in_sync_exits_zero --------------------------------------------------
# ci.yml has [A, B, C]; required-checks.txt has [A, B]; ci-skip.yml has [A, B] → exit 0.
_snapshot_fail
TMP1="$(mktemp -d)"; _TMP_DIRS+=("$TMP1")
mkdir -p "$TMP1/.github/workflows"
_write_ci_yml   "$TMP1/.github/workflows/ci.yml"      "JobA" "JobB" "JobC"
_write_skip_yml "$TMP1/.github/workflows/ci-skip.yml" "JobA" "JobB"
cat > "$TMP1/.github/required-checks.txt" <<'EOF'
JobA
JobB
EOF
rc=0
bash "$SCRIPT" --repo-root "$TMP1" 2>/dev/null || rc=$?
assert_eq "test_in_sync_exits_zero" "0" "$rc"
assert_pass_if_clean "test_in_sync_exits_zero"

# -- test_missing_stub_exits_nonzero ------------------------------------------
# required-checks.txt lists JobB but ci-skip.yml omits it → exit 1.
_snapshot_fail
TMP2="$(mktemp -d)"; _TMP_DIRS+=("$TMP2")
mkdir -p "$TMP2/.github/workflows"
_write_ci_yml   "$TMP2/.github/workflows/ci.yml"      "JobA" "JobB"
_write_skip_yml "$TMP2/.github/workflows/ci-skip.yml" "JobA"
cat > "$TMP2/.github/required-checks.txt" <<'EOF'
JobA
JobB
EOF
rc=0
bash "$SCRIPT" --repo-root "$TMP2" 2>/dev/null || rc=$?
assert_eq "test_missing_stub_exits_nonzero" "1" "$rc"
assert_pass_if_clean "test_missing_stub_exits_nonzero"

# -- test_extra_stub_exits_nonzero --------------------------------------------
# ci-skip.yml stubs a job not in required-checks.txt → exit 1 (drift).
_snapshot_fail
TMP3="$(mktemp -d)"; _TMP_DIRS+=("$TMP3")
mkdir -p "$TMP3/.github/workflows"
_write_ci_yml   "$TMP3/.github/workflows/ci.yml"      "JobA" "JobB"
_write_skip_yml "$TMP3/.github/workflows/ci-skip.yml" "JobA" "JobB"
cat > "$TMP3/.github/required-checks.txt" <<'EOF'
JobA
EOF
rc=0
bash "$SCRIPT" --repo-root "$TMP3" 2>/dev/null || rc=$?
assert_eq "test_extra_stub_exits_nonzero" "1" "$rc"
assert_pass_if_clean "test_extra_stub_exits_nonzero"

# -- test_required_check_not_in_ci_yml_is_ignored -----------------------------
# A required check that isn't emitted by ci.yml (e.g., from another workflow without
# paths-ignore) must NOT require a stub — parity is scoped to ci.yml's jobs.
_snapshot_fail
TMP4="$(mktemp -d)"; _TMP_DIRS+=("$TMP4")
mkdir -p "$TMP4/.github/workflows"
_write_ci_yml   "$TMP4/.github/workflows/ci.yml"      "JobA"
_write_skip_yml "$TMP4/.github/workflows/ci-skip.yml" "JobA"
# Another workflow file emits "OtherJob" (not gated by paths-ignore)
cat > "$TMP4/.github/workflows/other.yml" <<'EOF'
name: Other
on:
  pull_request:
jobs:
  other:
    name: "OtherJob"
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
EOF
cat > "$TMP4/.github/required-checks.txt" <<'EOF'
JobA
OtherJob
EOF
rc=0
bash "$SCRIPT" --repo-root "$TMP4" 2>/dev/null || rc=$?
assert_eq "test_required_check_not_in_ci_yml_is_ignored" "0" "$rc"
assert_pass_if_clean "test_required_check_not_in_ci_yml_is_ignored"

# -- test_missing_ci_skip_yml_exits_nonzero -----------------------------------
# ci-skip.yml absent while ci.yml has paths-ignore + required checks → exit 1.
_snapshot_fail
TMP5="$(mktemp -d)"; _TMP_DIRS+=("$TMP5")
mkdir -p "$TMP5/.github/workflows"
_write_ci_yml   "$TMP5/.github/workflows/ci.yml"      "JobA"
cat > "$TMP5/.github/required-checks.txt" <<'EOF'
JobA
EOF
rc=0
bash "$SCRIPT" --repo-root "$TMP5" 2>/dev/null || rc=$?
assert_eq "test_missing_ci_skip_yml_exits_nonzero" "1" "$rc"
assert_pass_if_clean "test_missing_ci_skip_yml_exits_nonzero"

print_summary
