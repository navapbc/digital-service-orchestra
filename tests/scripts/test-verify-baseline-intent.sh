#!/usr/bin/env bash
# tests/scripts/test-verify-baseline-intent.sh
# TDD tests for verify-baseline-intent.sh config-driven behavior:
#   1. workflow-config.conf contains the required keys:
#      - visual.baseline_directory → 'app/tests/e2e/snapshots/'
#      - design.manifest_patterns  → a list with exactly two entries
#   2. scripts/verify-baseline-intent.sh:
#      - reads visual.baseline_directory from config (not hardcoded)
#      - reads design.manifest_patterns from config (not hardcoded)
#      - exits 0 (no-op) when visual.baseline_directory is absent from config
#      - is executable
#
# Usage: bash tests/scripts/test-verify-baseline-intent.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
READ_CONFIG="$PLUGIN_ROOT/scripts/read-config.sh"
CONFIG="$REPO_ROOT/workflow-config.conf"
PLUGIN_SCRIPT="$PLUGIN_ROOT/scripts/verify-baseline-intent.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-verify-baseline-intent.sh ==="

# ── test_visual_baseline_directory ───────────────────────────────────────────
# visual.baseline_directory must return 'app/tests/e2e/snapshots/'
_snapshot_fail
baseline_exit=0
baseline_output=""
baseline_output=$(bash "$READ_CONFIG" visual.baseline_directory "$CONFIG" 2>&1) || baseline_exit=$?
assert_eq "test_visual_baseline_directory: exit 0" "0" "$baseline_exit"
assert_eq "test_visual_baseline_directory: value is app/tests/e2e/snapshots/" \
    "app/tests/e2e/snapshots/" "$baseline_output"
assert_pass_if_clean "test_visual_baseline_directory"

# ── test_design_manifest_patterns_count ──────────────────────────────────────
# design.manifest_patterns must be a list with exactly 2 entries
_snapshot_fail
manifest_exit=0
manifest_output=""
manifest_output=$(bash "$READ_CONFIG" --list design.manifest_patterns "$CONFIG" 2>&1) || manifest_exit=$?
manifest_count=$(echo "$manifest_output" | grep -c .)
assert_eq "test_design_manifest_patterns_count: exit 0" "0" "$manifest_exit"
assert_eq "test_design_manifest_patterns_count: exactly 2 entries" "2" "$manifest_count"
assert_pass_if_clean "test_design_manifest_patterns_count"

# ── test_design_manifest_patterns_values ─────────────────────────────────────
# The two entries must be designs/*/manifest.md and designs/*/brief.md
_snapshot_fail
manifest_val_exit=0
manifest_val_output=""
manifest_val_output=$(bash "$READ_CONFIG" --list design.manifest_patterns "$CONFIG" 2>&1) || manifest_val_exit=$?
assert_eq "test_design_manifest_patterns_values: exit 0" "0" "$manifest_val_exit"
assert_contains "test_design_manifest_patterns_values: contains designs/*/manifest.md" \
    "designs/*/manifest.md" "$manifest_val_output"
assert_contains "test_design_manifest_patterns_values: contains designs/*/brief.md" \
    "designs/*/brief.md" "$manifest_val_output"
assert_pass_if_clean "test_design_manifest_patterns_values"

# ── test_plugin_script_exists ─────────────────────────────────────────────────
# scripts/verify-baseline-intent.sh must exist
_snapshot_fail
if [[ -f "$PLUGIN_SCRIPT" ]]; then
    assert_eq "test_plugin_script_exists: file exists" "yes" "yes"
else
    assert_eq "test_plugin_script_exists: file exists" "yes" "no"
fi
assert_pass_if_clean "test_plugin_script_exists"

# ── test_plugin_script_is_executable ─────────────────────────────────────────
# scripts/verify-baseline-intent.sh must be executable
_snapshot_fail
if [[ -x "$PLUGIN_SCRIPT" ]]; then
    assert_eq "test_plugin_script_is_executable: executable" "yes" "yes"
else
    assert_eq "test_plugin_script_is_executable: executable" "yes" "no"
fi
assert_pass_if_clean "test_plugin_script_is_executable"

# ── test_no_hardcoded_baseline_path ──────────────────────────────────────────
# Script must NOT contain hardcoded 'app/tests/e2e/snapshots/'
_snapshot_fail
if grep -q 'app/tests/e2e/snapshots' "$PLUGIN_SCRIPT" 2>/dev/null; then
    assert_eq "test_no_hardcoded_baseline_path: no hardcoded path" "no_hardcode" "hardcoded"
else
    assert_eq "test_no_hardcoded_baseline_path: no hardcoded path" "no_hardcode" "no_hardcode"
fi
assert_pass_if_clean "test_no_hardcoded_baseline_path"

# ── test_no_hardcoded_manifest_pattern ───────────────────────────────────────
# Script must NOT contain hardcoded 'designs/*/manifest.md'
_snapshot_fail
if grep -q "designs/\*/manifest\.md" "$PLUGIN_SCRIPT" 2>/dev/null; then
    assert_eq "test_no_hardcoded_manifest_pattern: no hardcoded pattern" "no_hardcode" "hardcoded"
else
    assert_eq "test_no_hardcoded_manifest_pattern: no hardcoded pattern" "no_hardcode" "no_hardcode"
fi
assert_pass_if_clean "test_no_hardcoded_manifest_pattern"

# ── test_reads_visual_baseline_directory ─────────────────────────────────────
# Script must reference 'visual.baseline_directory' (reads from config)
_snapshot_fail
if grep -q 'visual\.baseline_directory' "$PLUGIN_SCRIPT" 2>/dev/null; then
    assert_eq "test_reads_visual_baseline_directory: key referenced" "yes" "yes"
else
    assert_eq "test_reads_visual_baseline_directory: key referenced" "yes" "no"
fi
assert_pass_if_clean "test_reads_visual_baseline_directory"

# ── test_reads_design_manifest_patterns ──────────────────────────────────────
# Script must reference 'design.manifest_patterns' (reads from config)
_snapshot_fail
if grep -q 'design\.manifest_patterns' "$PLUGIN_SCRIPT" 2>/dev/null; then
    assert_eq "test_reads_design_manifest_patterns: key referenced" "yes" "yes"
else
    assert_eq "test_reads_design_manifest_patterns: key referenced" "yes" "no"
fi
assert_pass_if_clean "test_reads_design_manifest_patterns"

# ── test_absent_config_exits_0 ───────────────────────────────────────────────
# When visual.baseline_directory is absent from config, script exits 0 (no-op).
# We test this by passing a config that has no visual section.
_snapshot_fail
TMPDIR_FIXTURE="$(mktemp -d)"
_CLEANUP_DIRS="$TMPDIR_FIXTURE"
trap 'rm -rf $_CLEANUP_DIRS' EXIT

EMPTY_CONFIG="$TMPDIR_FIXTURE/workflow-config.conf"
cat > "$EMPTY_CONFIG" <<'CONF'
stack=python-poetry
CONF

absent_exit=0
absent_output=""
# Run the plugin script with the empty config, passing it via CLAUDE_PLUGIN_ROOT
# (which read-config.sh checks first), but our fixture is not in that structure.
# Instead, we run from the tmpdir so read-config.sh finds the empty config via pwd.
absent_output=$(
    cd "$TMPDIR_FIXTURE" && \
    bash "$PLUGIN_SCRIPT" 2>&1
) || absent_exit=$?

assert_eq "test_absent_config_exits_0: exit code" "0" "$absent_exit"
assert_contains "test_absent_config_exits_0: info message" \
    "not configured" "$absent_output"
assert_pass_if_clean "absent_config_exits_0"

# ── Portability test helpers ──────────────────────────────────────────────────
# All portability tests run against isolated git repos in temp directories.
# They require:
#   1. CLAUDE_PLUGIN_PYTHON — points to python3 with pyyaml so read-config.sh
#      can parse yaml without resolving through the lockpick REPO_ROOT venv path.
#   2. Git identity configured in the isolated repo so commits work.
#   3. A proper `main` branch as merge-base target so git diff detects branch changes.
#
# Approach: init on the default branch (main), make a base commit, then checkout
# a feature branch. git merge-base HEAD main finds the base commit, and any
# commits on the feature branch appear in the diff.

PORTABILITY_TMPDIR="$(mktemp -d)"
_CLEANUP_DIRS="$_CLEANUP_DIRS $PORTABILITY_TMPDIR"

# Resolve python3 with pyyaml: use the lockpick venv if available, else system python3.
# REPO_ROOT is already set at the top of this file.
_PORTABILITY_PYTHON=""
for _py_candidate in \
    "$REPO_ROOT/app/.venv/bin/python3" \
    "python3"; do
    [[ -z "$_py_candidate" ]] && continue
    [[ "$_py_candidate" != "python3" ]] && [[ ! -f "$_py_candidate" ]] && continue
    if "$_py_candidate" -c "import yaml" 2>/dev/null; then
        _PORTABILITY_PYTHON="$_py_candidate"
        break
    fi
done

# Helper: create a minimal isolated git repo with a `main` branch and one base
# commit (the merge-base), then check out a feature branch for test additions.
# The workflow-config.conf content is written BEFORE the base commit so both
# branches share the same config (the base commit includes the config file).
_make_portability_repo() {
    local name="$1"
    local config_content="$2"
    local dir="$PORTABILITY_TMPDIR/$name"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email "test@test.local"
    git -C "$dir" config user.name "Test"
    printf '%s\n' "$config_content" > "$dir/workflow-config.conf"
    git -C "$dir" add workflow-config.conf
    git -C "$dir" commit -m "base" -q
    git -C "$dir" checkout -q -b feature/test
    echo "$dir"
}

# Helper: run PLUGIN_SCRIPT from within a portability repo dir with the
# correct python resolver so read-config.sh can parse yaml.
_run_portability() {
    local repo_dir="$1"
    (
        export CLAUDE_PLUGIN_PYTHON="${_PORTABILITY_PYTHON:-python3}"
        cd "$repo_dir"
        bash "$PLUGIN_SCRIPT" 2>&1
    )
}

# ── test_portability_no_visual_config_exits_0 ─────────────────────────────────
# Portability: an isolated git repo with no visual.baseline_directory in
# workflow-config.conf must cause the canonical script to exit 0 (no-op).
# This verifies the absent-config guard works end-to-end in a real git context.
_snapshot_fail
_p1_repo=$(_make_portability_repo "no-visual-config" "$(cat <<'CONF'
stack=python-poetry
CONF
)")

portability_no_visual_exit=0
portability_no_visual_output=""
portability_no_visual_output=$(_run_portability "$_p1_repo") || portability_no_visual_exit=$?

assert_eq "test_portability_no_visual_config_exits_0: exit code" "0" "$portability_no_visual_exit"
assert_contains "test_portability_no_visual_config_exits_0: not configured message" \
    "not configured" "$portability_no_visual_output"
assert_pass_if_clean "test_portability_no_visual_config_exits_0"

# ── test_portability_config_present_no_png_changes_exits_0 ────────────────────
# Portability: isolated git repo with visual.baseline_directory configured but
# no PNG changes on the feature branch versus main must exit 0.
_snapshot_fail
_p2_repo=$(_make_portability_repo "config-no-png" "$(cat <<'CONF'
stack=python-poetry
visual.baseline_directory=snapshots/
design.manifest_patterns=designs/*/manifest.md
design.manifest_patterns=designs/*/brief.md
CONF
)")
# Feature branch has no PNG additions — only a non-visual text file change
echo "readme" > "$_p2_repo/README.md"
git -C "$_p2_repo" add README.md
git -C "$_p2_repo" commit -m "non-visual change" -q

no_png_exit=0
no_png_output=""
no_png_output=$(_run_portability "$_p2_repo") || no_png_exit=$?

assert_eq "test_portability_config_present_no_png_changes_exits_0: exit code" "0" "$no_png_exit"
assert_contains "test_portability_config_present_no_png_changes_exits_0: OK message" \
    "OK" "$no_png_output"
assert_pass_if_clean "test_portability_config_present_no_png_changes_exits_0"

# ── test_portability_baseline_changes_no_manifests_exits_2 ────────────────────
# Portability: isolated git repo where visual.baseline_directory is configured,
# there are PNG changes on the feature branch versus main, but no manifest
# files were added. Assert exit code 2 (unintended visual changes).
_snapshot_fail
_p3_repo=$(_make_portability_repo "png-no-manifest" "$(cat <<'CONF'
stack=python-poetry
visual.baseline_directory=snapshots/
design.manifest_patterns=designs/*/manifest.md
design.manifest_patterns=designs/*/brief.md
CONF
)")
# Add a fake PNG in the baseline directory — no accompanying manifest
mkdir -p "$_p3_repo/snapshots"
printf '\x89PNG\r\n\x1a\n' > "$_p3_repo/snapshots/homepage.png"
git -C "$_p3_repo" add "snapshots/homepage.png"
git -C "$_p3_repo" commit -m "update baseline" -q

no_manifest_exit=0
no_manifest_output=""
no_manifest_output=$(_run_portability "$_p3_repo") || no_manifest_exit=$?

assert_eq "test_portability_baseline_changes_no_manifests_exits_2: exit code" "2" "$no_manifest_exit"
assert_contains "test_portability_baseline_changes_no_manifests_exits_2: WARNING in output" \
    "WARNING" "$no_manifest_output"
assert_contains "test_portability_baseline_changes_no_manifests_exits_2: baseline file listed" \
    "snapshots/homepage.png" "$no_manifest_output"
assert_pass_if_clean "test_portability_baseline_changes_no_manifests_exits_2"

# ── test_portability_baseline_changes_with_manifests_exits_0 ──────────────────
# Portability: isolated git repo where PNG baseline changes are accompanied by a
# design manifest file on the feature branch. Assert exit code 0 (intent confirmed).
_snapshot_fail
_p4_repo=$(_make_portability_repo "png-with-manifest" "$(cat <<'CONF'
stack=python-poetry
visual.baseline_directory=snapshots/
design.manifest_patterns=designs/*/manifest.md
design.manifest_patterns=designs/*/brief.md
CONF
)")
# Add a fake PNG baseline change AND a matching design manifest
mkdir -p "$_p4_repo/snapshots"
printf '\x89PNG\r\n\x1a\n' > "$_p4_repo/snapshots/dashboard.png"
git -C "$_p4_repo" add "snapshots/dashboard.png"
mkdir -p "$_p4_repo/designs/dashboard-redesign"
echo "# Dashboard Redesign Manifest" > "$_p4_repo/designs/dashboard-redesign/manifest.md"
git -C "$_p4_repo" add "designs/dashboard-redesign/manifest.md"
git -C "$_p4_repo" commit -m "add baseline and manifest" -q

with_manifest_exit=0
with_manifest_output=""
with_manifest_output=$(_run_portability "$_p4_repo") || with_manifest_exit=$?

assert_eq "test_portability_baseline_changes_with_manifests_exits_0: exit code" "0" "$with_manifest_exit"
assert_contains "test_portability_baseline_changes_with_manifests_exits_0: OK message" \
    "OK" "$with_manifest_output"
assert_pass_if_clean "test_portability_baseline_changes_with_manifests_exits_0"

print_summary
