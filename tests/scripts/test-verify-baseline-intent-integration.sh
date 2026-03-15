#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-verify-baseline-intent-integration.sh
# Integration tests for verify-baseline-intent.sh config-driven path reading.
#
# These are behavioral tests that run the script end-to-end in isolated git
# repos to verify it reads visual.baseline_directory from workflow-config.conf
# rather than any hardcoded path.
#
# Test cases:
#   1. Custom baseline dir with PNG and no manifest → exit 2 (WARNING, file listed)
#   2. Custom baseline dir configured, PNG at old hardcoded path → exit 0 (ignored)
#   3. Custom baseline dir with PNG AND manifest → exit 0 (intent confirmed)
#
# Usage: bash lockpick-workflow/tests/scripts/test-verify-baseline-intent-integration.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
PLUGIN_SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/verify-baseline-intent.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-verify-baseline-intent-integration.sh ==="

# ── Integration test helpers ──────────────────────────────────────────────────
# All integration tests run against isolated git repos in temp directories.
# They require:
#   1. CLAUDE_PLUGIN_PYTHON — points to python3 with pyyaml so read-config.sh
#      can parse yaml without resolving through the lockpick REPO_ROOT venv path.
#   2. Git identity configured in the isolated repo so commits work.
#   3. A proper `main` branch as merge-base target so git diff detects branch changes.
#
# Approach: init on the default branch (main), make a base commit, then checkout
# a feature branch. git merge-base HEAD main finds the base commit, and any
# commits on the feature branch appear in the diff.

INTEGRATION_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$INTEGRATION_TMPDIR"' EXIT

# Resolve python3 with pyyaml: use the lockpick venv if available, else system python3.
_INTEGRATION_PYTHON=""
for _py_candidate in \
    "$REPO_ROOT/app/.venv/bin/python3" \
    "python3"; do
    [[ -z "$_py_candidate" ]] && continue
    [[ "$_py_candidate" != "python3" ]] && [[ ! -f "$_py_candidate" ]] && continue
    if "$_py_candidate" -c "import yaml" 2>/dev/null; then
        _INTEGRATION_PYTHON="$_py_candidate"
        break
    fi
done

# Helper: create a minimal isolated git repo with a `main` branch and one base
# commit (the merge-base), then check out a feature branch for test additions.
# The workflow-config.conf content is written BEFORE the base commit so both
# branches share the same config (the base commit includes the config file).
_make_integration_repo() {
    local name="$1"
    local config_content="$2"
    local dir="$INTEGRATION_TMPDIR/$name"
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

# Helper: run PLUGIN_SCRIPT from within an integration repo dir with the
# correct python resolver so read-config.sh can parse yaml.
_run_integration() {
    local repo_dir="$1"
    (
        export CLAUDE_PLUGIN_PYTHON="${_INTEGRATION_PYTHON:-python3}"
        cd "$repo_dir"
        bash "$PLUGIN_SCRIPT" 2>&1
    )
}

# ── test_integration_custom_baseline_dir_png_no_manifest_exits_2 ──────────────
# Integration: script configured with custom/baselines/ dir; branch adds a PNG
# there without a manifest. Script must exit 2, print WARNING, and list the
# custom path — proving it reads visual.baseline_directory from config.
_snapshot_fail
_i1_repo=$(_make_integration_repo "custom-dir-png-no-manifest" "$(cat <<'CONF'
stack=python-poetry
visual.baseline_directory=custom/baselines/
design.manifest_patterns=designs/*/manifest.md
design.manifest_patterns=designs/*/brief.md
CONF
)")
mkdir -p "$_i1_repo/custom/baselines"
printf '\x89PNG\r\n\x1a\n' > "$_i1_repo/custom/baselines/screen.png"
git -C "$_i1_repo" add "custom/baselines/screen.png"
git -C "$_i1_repo" commit -m "add baseline" -q

i1_exit=0
i1_output=""
i1_output=$(_run_integration "$_i1_repo") || i1_exit=$?

assert_eq "test_integration_custom_baseline_dir_png_no_manifest_exits_2: exit code" \
    "2" "$i1_exit"
assert_contains "test_integration_custom_baseline_dir_png_no_manifest_exits_2: WARNING in output" \
    "WARNING" "$i1_output"
assert_contains "test_integration_custom_baseline_dir_png_no_manifest_exits_2: custom path listed" \
    "custom/baselines/screen.png" "$i1_output"
assert_pass_if_clean "test_integration_custom_baseline_dir_png_no_manifest_exits_2"

# ── test_integration_default_hardcoded_path_ignored_when_custom_dir_set ───────
# Integration: script configured with custom/baselines/; branch adds a PNG at
# the OLD hardcoded path app/tests/e2e/snapshots/ (not the configured dir).
# Script must exit 0 — the hardcoded path is outside the configured baseline dir
# and must NOT trigger a warning. Proves script does not use hardcoded paths.
_snapshot_fail
_i2_repo=$(_make_integration_repo "custom-dir-old-hardcoded-path" "$(cat <<'CONF'
stack=python-poetry
visual.baseline_directory=custom/baselines/
design.manifest_patterns=designs/*/manifest.md
design.manifest_patterns=designs/*/brief.md
CONF
)")
mkdir -p "$_i2_repo/app/tests/e2e/snapshots"
printf '\x89PNG\r\n\x1a\n' > "$_i2_repo/app/tests/e2e/snapshots/screen.png"
git -C "$_i2_repo" add "app/tests/e2e/snapshots/screen.png"
git -C "$_i2_repo" commit -m "add png at old path" -q

i2_exit=0
i2_output=""
i2_output=$(_run_integration "$_i2_repo") || i2_exit=$?

assert_eq "test_integration_default_hardcoded_path_ignored_when_custom_dir_set: exit code" \
    "0" "$i2_exit"
assert_contains "test_integration_default_hardcoded_path_ignored_when_custom_dir_set: OK message" \
    "OK" "$i2_output"
assert_pass_if_clean "test_integration_default_hardcoded_path_ignored_when_custom_dir_set"

# ── test_integration_custom_baseline_dir_with_manifest_exits_0 ────────────────
# Integration: script configured with custom/baselines/; branch adds a PNG in
# the configured dir AND a design manifest. Script must exit 0 — intent is
# confirmed. Proves intent-confirmation path works with a non-default baseline dir.
_snapshot_fail
_i3_repo=$(_make_integration_repo "custom-dir-png-with-manifest" "$(cat <<'CONF'
stack=python-poetry
visual.baseline_directory=custom/baselines/
design.manifest_patterns=designs/*/manifest.md
design.manifest_patterns=designs/*/brief.md
CONF
)")
mkdir -p "$_i3_repo/custom/baselines"
printf '\x89PNG\r\n\x1a\n' > "$_i3_repo/custom/baselines/screen.png"
git -C "$_i3_repo" add "custom/baselines/screen.png"
mkdir -p "$_i3_repo/designs/feat"
echo "# Feature Manifest" > "$_i3_repo/designs/feat/manifest.md"
git -C "$_i3_repo" add "designs/feat/manifest.md"
git -C "$_i3_repo" commit -m "add baseline and manifest" -q

i3_exit=0
i3_output=""
i3_output=$(_run_integration "$_i3_repo") || i3_exit=$?

assert_eq "test_integration_custom_baseline_dir_with_manifest_exits_0: exit code" \
    "0" "$i3_exit"
assert_contains "test_integration_custom_baseline_dir_with_manifest_exits_0: OK message" \
    "OK" "$i3_output"
assert_pass_if_clean "test_integration_custom_baseline_dir_with_manifest_exits_0"

print_summary
