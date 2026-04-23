#!/usr/bin/env bash
# tests/hooks/test-merge-to-main-portability.sh
# Portability smoke test: merge-to-main.sh with a minimal dso-config.conf
# that has no merge: section (no visual_baseline_path, no ci_workflow_name).
#
# Verifies that the config-absent code paths (skip baseline check, skip CI
# trigger) work correctly and the script completes a successful merge.
#
# Also verifies that a custom tickets.directory (e.g. .issues) is respected
# for the dirty-files exclusion check.
#
# Usage: bash tests/hooks/test-merge-to-main-portability.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main.sh"

# Ensure CLAUDE_PLUGIN_ROOT is set (run-hook-tests.sh exports this, but
# standalone runs may not have it).
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$DSO_PLUGIN_DIR}"

# Disable commit signing for test repos — global gpgsign=true causes failures
# when the signing server is unavailable.
export GIT_CONFIG_COUNT="${GIT_CONFIG_COUNT:-1}"
export GIT_CONFIG_KEY_0="${GIT_CONFIG_KEY_0:-commit.gpgsign}"
export GIT_CONFIG_VALUE_0="${GIT_CONFIG_VALUE_0:-false}"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Prevent PROJECT_ROOT from leaking into temp-repo merge-to-main.sh invocations.
# The dso shim exports PROJECT_ROOT; if inherited, merge-to-main.sh uses the
# actual project root instead of the temp repo, causing false dirty-worktree failures.
unset PROJECT_ROOT

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# ── Ensure read-config.sh can find a python3 with pyyaml ─────────────────────
# read-config.sh probes for a python3 with pyyaml; in temp test environments
# REPO_ROOT points to the temp dir (no venv there), so the probe falls back to
# the system python3 which may lack pyyaml. Set CLAUDE_PLUGIN_PYTHON to the
# first candidate that works, so all read-config.sh calls in the test env
# succeed (required for custom tickets.directory tests).
if [[ -z "${CLAUDE_PLUGIN_PYTHON:-}" ]]; then
    for _py_candidate in \
            "$REPO_ROOT/app/.venv/bin/python3" \
            "$REPO_ROOT/.venv/bin/python3" \
            "/usr/bin/python3" \
            "python3"; do
        [[ -z "$_py_candidate" ]] && continue
        if "$_py_candidate" -c "import yaml" 2>/dev/null; then
            export CLAUDE_PLUGIN_PYTHON="$_py_candidate"
            break
        fi
    done
fi

# ── Helper: create a minimal ticket file ─────────────────────────────────────
make_ticket_file() {
    local dir="$1"
    local ticket_id="$2"
    local tickets_subdir="${3:-.tickets}"
    mkdir -p "$dir/$tickets_subdir"
    cat > "$dir/$tickets_subdir/${ticket_id}.md" <<EOF
---
id: $ticket_id
status: open
deps: []
links: []
created: 2026-01-01T00:00:00Z
type: task
priority: 2
---
# Ticket $ticket_id
EOF
}

# ── Helper: create a minimal dso-config.conf with only version + tickets dir ──
make_minimal_config() {
    local dir="$1"
    local tickets_dir="${2:-.tickets}"
    mkdir -p "$dir/.claude"
    cat > "$dir/.claude/dso-config.conf" <<CONF
tickets.directory=$tickets_dir
CONF
}

# ── Helper: set up a merge-to-main test environment ──────────────────────────
# Creates:
#   $REALENV/bare.git       — bare repo acting as "origin"
#   $REALENV/main-clone/    — main repo cloned from bare (main checked out)
#   $REALENV/worktree/      — worktree linked from main-clone on a feature branch
#
# Places a minimal dso-config.conf (no merge: section) in both main-clone
# and worktree directories so read-config.sh finds it from $(pwd).
#
# Outputs the canonicalized env root to stdout.
setup_portability_env() {
    local tickets_dir="${1:-.tickets}"
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local REALENV
    REALENV=$(cd "$tmpdir" && pwd -P)

    # 1. Seed repo with initial commit
    git init -q -b main "$REALENV/seed"
    git -C "$REALENV/seed" config user.email "test@test.com"
    git -C "$REALENV/seed" config user.name "Test"
    echo "initial" > "$REALENV/seed/README.md"
    make_ticket_file "$REALENV/seed" "seed-init" "$tickets_dir"
    make_minimal_config "$REALENV/seed" "$tickets_dir"
    git -C "$REALENV/seed" add -A
    git -C "$REALENV/seed" commit -q -m "init"

    # 2. Bare repo cloned from seed (acts as origin)
    git clone --bare -q "$REALENV/seed" "$REALENV/bare.git"

    # 3. Clone bare into main-clone
    git clone -q "$REALENV/bare.git" "$REALENV/main-clone"
    git -C "$REALENV/main-clone" config user.email "test@test.com"
    git -C "$REALENV/main-clone" config user.name "Test"

    # 4. Create a feature branch worktree
    git -C "$REALENV/main-clone" branch feature-branch 2>/dev/null || true
    git -C "$REALENV/main-clone" worktree add -q "$REALENV/worktree" feature-branch 2>/dev/null
    git -C "$REALENV/worktree" config user.email "test@test.com"
    git -C "$REALENV/worktree" config user.name "Test"

    echo "$REALENV"
}

# ── Helper: cleanup ──────────────────────────────────────────────────────────
cleanup_env() {
    local env_dir="$1"
    git -C "$env_dir/main-clone" worktree remove --force "$env_dir/worktree" 2>/dev/null || true
    rm -rf "$env_dir"
}

# =============================================================================
# Test 1: Minimal config — merge succeeds, no baseline check, no CI trigger
# dso-config.conf has only version + tickets.directory (no merge: section).
# merge-to-main.sh should:
#   - Skip the visual baseline check (INFO message printed)
#   - Skip the CI trigger (INFO message printed)
#   - Complete successfully (DONE message present)
# =============================================================================
TMPENV1=$(setup_portability_env ".tickets")
WT1=$(cd "$TMPENV1/worktree" && pwd -P)

# Make a committed change on the feature branch so merge has something to do
echo "portability feature" > "$WT1/portability.txt"
(cd "$WT1" && git add portability.txt && git commit -q -m "feat: portability feature")

# Run merge-to-main.sh from the worktree directory
MERGE_OUTPUT1=$(cd "$WT1" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

# Merge should succeed
assert_contains "test_portability_merge_succeeds" "DONE" "$MERGE_OUTPUT1"

# No baseline check should have run — must not see "Visual baseline" or
# "verify-baseline-intent" in the output
BASELINE_ABSENT1="true"
_tmp="$MERGE_OUTPUT1"; if [[ "$_tmp" =~ Visual\ baseline|verify-baseline-intent ]]; then
    BASELINE_ABSENT1="false"
fi
assert_eq "test_portability_no_baseline_check" "true" "$BASELINE_ABSENT1"

# No CI trigger should have run — must not see "workflow run" in the output
CI_ABSENT1="true"
_tmp="$MERGE_OUTPUT1"; if [[ "$_tmp" =~ workflow\ run ]]; then
    CI_ABSENT1="false"
fi
assert_eq "test_portability_no_ci_trigger" "true" "$CI_ABSENT1"

# INFO message for skipped baseline must be present
assert_contains "test_portability_baseline_skip_info" \
    "INFO: merge.visual_baseline_path not configured" "$MERGE_OUTPUT1"

# INFO message for skipped CI trigger must be present
assert_contains "test_portability_ci_skip_info" \
    "INFO: merge.ci_workflow_name not configured" "$MERGE_OUTPUT1"

# Info message for no-args sequential run must appear — merge-to-main.sh always
# emits this when invoked with no arguments (the normal single-step usage pattern).
assert_contains "test_portability_noargs_message_present" \
    "Running all phases sequentially" "$MERGE_OUTPUT1"

cleanup_env "$TMPENV1"

# =============================================================================
# Test 2: Feature file lands on main after minimal-config merge
# Validates that the merge actually committed the feature content to main.
# =============================================================================
TMPENV2=$(setup_portability_env ".tickets")
WT2=$(cd "$TMPENV2/worktree" && pwd -P)
MAIN2="$TMPENV2/main-clone"

echo "portability feature2" > "$WT2/portability2.txt"
(cd "$WT2" && git add portability2.txt && git commit -q -m "feat: portability feature2")

MERGE_OUTPUT2=$(cd "$WT2" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

assert_contains "test_portability_merge2_succeeds" "DONE" "$MERGE_OUTPUT2"

# Feature file should exist on main after the merge
FEATURE_ON_MAIN2=$(cd "$MAIN2" && git show HEAD:portability2.txt 2>/dev/null || echo "NOT_FOUND")
assert_eq "test_portability_feature_on_main" "portability feature2" "$FEATURE_ON_MAIN2"

cleanup_env "$TMPENV2"

# =============================================================================
# Test 3: Custom tickets.directory — merge succeeds with .issues/ as ticket dir
# dso-config.conf sets tickets.directory to ".issues".
# merge-to-main.sh must use ".issues" for exclusions so dirty .issues/ files
# are excluded from the uncommitted-changes check.
# =============================================================================
TMPENV3=$(setup_portability_env ".issues")
WT3=$(cd "$TMPENV3/worktree" && pwd -P)

echo "custom tickets dir feature" > "$WT3/custom-dir.txt"
(cd "$WT3" && git add custom-dir.txt && git commit -q -m "feat: custom-dir feature")

# Create a dirty (untracked) .issues/ file — with default .tickets/ exclusion,
# this would NOT be excluded and would block the merge
make_ticket_file "$WT3" "dirty-issue-test" ".issues"

MERGE_OUTPUT3=$(cd "$WT3" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    WORKFLOW_CONFIG_FILE="$WT3/.claude/dso-config.conf" bash "$MERGE_SCRIPT" 2>&1 || true)

# Merge must succeed — the custom tickets dir must be properly excluded
assert_contains "test_portability_custom_dir_merge_succeeds" "DONE" "$MERGE_OUTPUT3"

# Confirm the dirty ticket did not block the merge (no ERROR about uncommitted changes)
UNCOMMITTED_ERROR3="false"
_tmp="$MERGE_OUTPUT3"; if [[ "$_tmp" =~ ERROR:\ Uncommitted\ changes ]]; then
    UNCOMMITTED_ERROR3="true"
fi
assert_eq "test_portability_custom_dir_no_uncommitted_error" "false" "$UNCOMMITTED_ERROR3"

cleanup_env "$TMPENV3"

# =============================================================================
# Test 4: No dso-config.conf at all — merge still succeeds
# Verifies absolute portability: even with no config file present, the script
# completes successfully (all config reads return empty, defaults apply).
# =============================================================================
TMPENV4=$(setup_portability_env ".tickets")
WT4=$(cd "$TMPENV4/worktree" && pwd -P)

# Remove the dso-config.conf from both main-clone and worktree
rm -f "$TMPENV4/main-clone/.claude/dso-config.conf"
rm -f "$WT4/.claude/dso-config.conf"

# Commit the removal so worktree is clean (excluding .tickets/)
(cd "$TMPENV4/main-clone" && \
    git rm --cached .claude/dso-config.conf -q 2>/dev/null && \
    rm -f .claude/dso-config.conf && \
    git commit -q -m "chore: remove config for portability test" && \
    git push -q origin main 2>/dev/null)

# Feature branch: remove config and add a feature commit
(cd "$WT4" && \
    git rm --cached .claude/dso-config.conf -q 2>/dev/null && \
    rm -f .claude/dso-config.conf 2>/dev/null; \
    echo "no-config feature" > "$WT4/no-config.txt" && \
    git add no-config.txt && \
    git commit -q -m "feat: no-config feature")

MERGE_OUTPUT4=$(cd "$WT4" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

# Merge must succeed — no config is a valid configuration
assert_contains "test_portability_no_config_merge_succeeds" "DONE" "$MERGE_OUTPUT4"

cleanup_env "$TMPENV4"

# =============================================================================
print_summary
