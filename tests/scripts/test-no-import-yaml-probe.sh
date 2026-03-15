#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-no-import-yaml-probe.sh
# TDD tests verifying that tk, worktree-create.sh, check-local-env.sh, and
# issue-batch.sh do NOT contain 'import yaml' interpreter probes or pyyaml/PyYAML
# references. These probes were used solely to find Python for read-config.sh,
# which no longer needs Python (the YAML path was removed). Scripts that use
# PyYAML for their own purposes (classify-task.py, check-file-syntax.py,
# ci-status.sh, resolve-stack-adapter.sh) are out of scope.
#
# Tests:
#   test_<script>_no_import_yaml_probe  — no 'import yaml' probe in script
#   test_<script>_no_pyyaml_reference   — no 'pyyaml' or 'PyYAML' reference in script
#
# Usage: bash lockpick-workflow/tests/scripts/test-no-import-yaml-probe.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-no-import-yaml-probe.sh ==="

SCRIPTS_DIR="$REPO_ROOT/lockpick-workflow/scripts"

# The 4 scripts that must NOT contain import yaml probes
TARGET_SCRIPTS=(
    "tk"
    "worktree-create.sh"
    "check-local-env.sh"
    "issue-batch.sh"
)

# ── test_<script>_no_import_yaml_probe ────────────────────────────────────────
# No 'import yaml' probe in any of the 4 scripts (non-comment lines only)
echo ""
echo "--- No 'import yaml' probe in target scripts ---"

for script in "${TARGET_SCRIPTS[@]}"; do
    _snapshot_fail
    filepath="$SCRIPTS_DIR/$script"
    if [[ ! -f "$filepath" ]]; then
        assert_eq "test_${script}_no_import_yaml_probe: file exists" "exists" "missing"
        continue
    fi
    # Count non-comment lines containing 'import yaml'
    probe_count=$(grep -v '^\s*#' "$filepath" | grep -c '"import yaml"\|import yaml' || true)
    assert_eq "test_${script}_no_import_yaml_probe" "0" "$probe_count"
    assert_pass_if_clean "test_${script}_no_import_yaml_probe"
done

# ── test_<script>_no_pyyaml_reference ─────────────────────────────────────────
# No 'pyyaml' or 'PyYAML' reference in any of the 4 scripts (non-comment lines only)
echo ""
echo "--- No 'pyyaml' or 'PyYAML' reference in target scripts ---"

for script in "${TARGET_SCRIPTS[@]}"; do
    _snapshot_fail
    filepath="$SCRIPTS_DIR/$script"
    if [[ ! -f "$filepath" ]]; then
        assert_eq "test_${script}_no_pyyaml_reference: file exists" "exists" "missing"
        continue
    fi
    # Count non-comment lines containing 'pyyaml' or 'PyYAML' (case-insensitive)
    ref_count=$(grep -v '^\s*#' "$filepath" | grep -ci 'pyyaml' || true)
    assert_eq "test_${script}_no_pyyaml_reference" "0" "$ref_count"
    assert_pass_if_clean "test_${script}_no_pyyaml_reference"
done

print_summary
