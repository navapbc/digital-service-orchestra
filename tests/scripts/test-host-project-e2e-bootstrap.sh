#!/usr/bin/env bash
# tests/scripts/test-host-project-e2e-bootstrap.sh
# E2E setup test: bootstraps a host project via create-dso-app.sh in a temp
# directory and configures it for CI llm-review verification.
#
# This is the setup phase for f731-3fa0 (host-project E2E verification of the
# 3-tier distribution mechanism). The bootstrapped project path is written to a
# state file for use by the next task in the series.
#
# Tests covered:
#   1. test_host_bootstrap_and_config_patch — bootstrap + merge.strategy=pr patch
#
# Usage: bash tests/scripts/test-host-project-e2e-bootstrap.sh
# Returns: exit 0 if all tests pass/skipped, exit 1 on failure
#
# Prerequisites (explicit SKIP when missing):
#   - gh auth must be configured
#   - ANTHROPIC_API_KEY must be set
#   - scripts/create-dso-app.sh must exist in the repo

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

# Track temp dirs for cleanup — only cleaned up on failure (preserved on success)
_TEST_TMPDIRS=()
_TEST_FAILED=0

cleanup() {
    if [[ "$_TEST_FAILED" -ne 0 ]]; then
        for d in "${_TEST_TMPDIRS[@]:-}"; do
            rm -rf "$d" 2>/dev/null || true
        done
    else
        # On success: print the scratch dir path so subsequent tasks can find it
        for d in "${_TEST_TMPDIRS[@]:-}"; do
            if [[ -d "$d" ]]; then
                echo "[bootstrap] Scratch dir preserved for downstream tasks: $d" >&2
            fi
        done
    fi
}
trap cleanup EXIT

# ── test_host_bootstrap_and_config_patch ─────────────────────────────────────
# Given: gh auth configured, ANTHROPIC_API_KEY set, create-dso-app.sh present
# When:  create-dso-app.sh is run with a project name in a temp dir
# Then:  exit code is 0, .claude/dso-config.conf exists, merge.strategy=pr is set
#        and the bootstrapped path is written to the state file
_snapshot_fail

# Prerequisites check (explicit SKIP — never silently ignore)
# Collect all skip reasons before exiting so the full set is reported.
_SKIP_REASONS=()
if ! gh auth status &>/dev/null; then
    _SKIP_REASONS+=("gh auth not configured")
fi
if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${OPENAI_API_KEY:-}" ]]; then
    _SKIP_REASONS+=("neither ANTHROPIC_API_KEY nor OPENAI_API_KEY is set")
fi
if [[ "${#_SKIP_REASONS[@]}" -gt 0 ]]; then
    for _reason in "${_SKIP_REASONS[@]}"; do
        echo "SKIP: test_host_bootstrap_and_config_patch — $_reason" >&2
    done
    print_summary
fi

if [[ ! -f "$REPO_ROOT/scripts/create-dso-app.sh" ]]; then
    echo "FAIL: test_host_bootstrap_and_config_patch — scripts/create-dso-app.sh not found" >&2
    (( ++FAIL ))
    assert_pass_if_clean "test_host_bootstrap_and_config_patch"
    print_summary
fi

# Step 1: Create scratch directory
SCRATCH=$(mktemp -d)
_TEST_TMPDIRS+=("$SCRATCH")

# Step 2: Bootstrap host project via create-dso-app.sh
# Invocation: bash <script> <project-name> [<target-dir>]
# project-name = "host-project", target-dir = $SCRATCH
bootstrap_exit=0
bootstrap_output=""
bootstrap_output=$(
    bash "$REPO_ROOT/scripts/create-dso-app.sh" "host-project" "$SCRATCH" 2>&1
) || bootstrap_exit=$?

assert_eq "test_host_bootstrap_and_config_patch: create-dso-app.sh exits 0" \
    "0" "$bootstrap_exit"

# Step 3: Verify the project directory was created
project_dir="$SCRATCH/host-project"
if [[ -d "$project_dir" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    printf "FAIL: %s\n  expected directory: %s\n  create-dso-app output:\n%s\n" \
        "test_host_bootstrap_and_config_patch: project directory exists" \
        "$project_dir" "$bootstrap_output" >&2
fi

# Step 4: Verify dso-config.conf exists
config_file="$project_dir/.claude/dso-config.conf"
if [[ -f "$config_file" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    printf "FAIL: %s\n  expected file: %s\n" \
        "test_host_bootstrap_and_config_patch: dso-config.conf exists" \
        "$config_file" >&2
fi

# Step 5: Config patch — set merge.strategy=pr (cross-platform: BSD and GNU sed)
if grep -q '^merge\.strategy=' "$config_file" 2>/dev/null; then
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i 's/^merge\.strategy=.*/merge.strategy=pr/' "$config_file"
    else
        sed -i '' 's/^merge\.strategy=.*/merge.strategy=pr/' "$config_file"
    fi
else
    echo 'merge.strategy=pr' >> "$config_file"
fi

# Step 6: Assert merge.strategy=pr is present
if grep -q 'merge\.strategy=pr' "$config_file" 2>/dev/null; then
    (( ++PASS ))
else
    (( ++FAIL ))
    printf "FAIL: %s\n  key merge.strategy=pr not found in: %s\n" \
        "test_host_bootstrap_and_config_patch: merge.strategy=pr set in config" \
        "$config_file" >&2
fi

# Step 7: Write state file for downstream tasks
state_file="/tmp/dso-e2e-host-project-path.txt"
printf '%s\n' "$project_dir" > "$state_file"

if [[ -f "$state_file" ]]; then
    (( ++PASS ))
    echo "[bootstrap] State file written: $state_file (path: $project_dir)" >&2
else
    (( ++FAIL ))
    printf "FAIL: %s\n  state file not written: %s\n" \
        "test_host_bootstrap_and_config_patch: state file written" \
        "$state_file" >&2
fi

# Update failure flag so cleanup trap knows whether to preserve scratch dir
if [[ "$FAIL" -gt 0 ]]; then
    _TEST_FAILED=1
fi

assert_pass_if_clean "test_host_bootstrap_and_config_patch"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
