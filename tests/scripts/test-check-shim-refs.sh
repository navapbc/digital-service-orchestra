#!/usr/bin/env bash
# tests/scripts/test-check-shim-refs.sh
# Behavioral tests for check-shim-refs.sh — detects DSO shim violation patterns
# in instruction files within plugins/dso/.
#
# Tests:
#  1. test_exit_nonzero_on_literal_path       — plugins/dso/scripts/foo.sh literal path → exit != 0
#  2. test_exit_nonzero_on_variable_path      — $PLUGIN_SCRIPTS/foo.sh variable path → exit != 0
#  3. test_exit_nonzero_on_curly_variable_path — ${CLAUDE_PLUGIN_ROOT}/scripts/foo.sh → exit != 0
#  4. test_source_hooks_lib_excluded          — source plugins/dso/hooks/lib/merge-state.sh → exit 0
#  5. test_script_to_script_excluded          — reference inside plugins/dso/scripts/ file → exit 0
#  6. test_shim_exempt_comment_suppresses     — line with # shim-exempt: reason → exit 0
#  7. test_exit_zero_on_clean_file            — file with no violation patterns → exit 0
#  8. test_multi_pattern_detection            — file with multiple violation types → exit != 0
#  9. test_scope_filtering_out_of_scope       — file outside plugins/dso/ scope → exit 0
#
# Usage: bash tests/scripts/test-check-shim-refs.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# REVIEW-DEFENSE: '-e' is intentionally omitted. The test harness captures
# non-zero exit codes from script invocations via || assignment. With '-e',
# expected non-zero exits would abort the script before assertions run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/check-shim-refs.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-check-shim-refs.sh ==="

_TEST_TMPDIRS=()
_cleanup() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap '_cleanup' EXIT

_make_tmpdir() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ── test_exit_nonzero_on_literal_path ─────────────────────────────────────────
# A skill file containing a literal reference to plugins/dso/scripts/ must cause
# the script to exit non-zero and report the violation.
test_exit_nonzero_on_literal_path() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    # Simulate a skill file inside plugins/dso/ by placing it under a matching subdir
    mkdir -p "$_dir/plugins/dso/skills/my-skill"
    _file="$_dir/plugins/dso/skills/my-skill/SKILL.md"
    printf '# My Skill\n\nRun `plugins/dso/scripts/validate.sh --ci` to validate.\n' > "$_file"
    _exit=0
    _out=$(bash "$SCRIPT" "$_file" 2>&1) || _exit=$?
    assert_ne "test_exit_nonzero_on_literal_path: exit != 0 for literal path" "0" "$_exit"
    assert_contains "test_exit_nonzero_on_literal_path: violation reported in output" "SKILL.md" "$_out"
    assert_pass_if_clean "test_exit_nonzero_on_literal_path"
}

# ── test_exit_nonzero_on_variable_path ────────────────────────────────────────
# A skill file containing $PLUGIN_SCRIPTS/foo.sh must cause the script to exit
# non-zero and report the violating file.
test_exit_nonzero_on_variable_path() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    mkdir -p "$_dir/plugins/dso/agents"
    _file="$_dir/plugins/dso/agents/my-agent.md"
    printf '# My Agent\n\nInvoke via `$PLUGIN_SCRIPTS/validate.sh --ci`.\n' > "$_file"
    _exit=0
    _out=$(bash "$SCRIPT" "$_file" 2>&1) || _exit=$?
    assert_ne "test_exit_nonzero_on_variable_path: exit != 0 for \$PLUGIN_SCRIPTS path" "0" "$_exit"
    assert_contains "test_exit_nonzero_on_variable_path: violation reported in output" "my-agent.md" "$_out"
    assert_pass_if_clean "test_exit_nonzero_on_variable_path"
}

# ── test_exit_nonzero_on_curly_variable_path ──────────────────────────────────
# A skill file referencing ${CLAUDE_PLUGIN_ROOT}/scripts/ must cause the script
# to exit non-zero and report the violating file.
test_exit_nonzero_on_curly_variable_path() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    mkdir -p "$_dir/plugins/dso/docs"
    _file="$_dir/plugins/dso/docs/GUIDE.md"
    printf '# Guide\n\nUse `${CLAUDE_PLUGIN_ROOT}/scripts/validate.sh`.\n' > "$_file"
    _exit=0
    _out=$(bash "$SCRIPT" "$_file" 2>&1) || _exit=$?
    assert_ne "test_exit_nonzero_on_curly_variable_path: exit != 0 for \${CLAUDE_PLUGIN_ROOT}/scripts/" "0" "$_exit"
    assert_contains "test_exit_nonzero_on_curly_variable_path: violation reported in output" "GUIDE.md" "$_out"
    assert_pass_if_clean "test_exit_nonzero_on_curly_variable_path"
}

# ── test_source_hooks_lib_excluded ────────────────────────────────────────────
# A source command targeting plugins/dso/hooks/lib/ must NOT be flagged as a
# violation — these are legitimate internal library sourcing patterns.
test_source_hooks_lib_excluded() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    mkdir -p "$_dir/plugins/dso/hooks"
    _file="$_dir/plugins/dso/hooks/my-hook.sh"
    printf '#!/usr/bin/env bash\nsource plugins/dso/hooks/lib/merge-state.sh\necho done\n' > "$_file"
    _exit=0
    _out=$(bash "$SCRIPT" "$_file" 2>&1) || _exit=$?
    assert_eq "test_source_hooks_lib_excluded: exit 0 for source hooks/lib/ command" "0" "$_exit"
    assert_pass_if_clean "test_source_hooks_lib_excluded"
}

# ── test_script_to_script_excluded ────────────────────────────────────────────
# A reference to plugins/dso/scripts/ inside a file that is itself located in
# plugins/dso/scripts/ must NOT be flagged (script-to-script references are
# out of scope).
test_script_to_script_excluded() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    mkdir -p "$_dir/plugins/dso/scripts"
    _file="$_dir/plugins/dso/scripts/my-orchestrator.sh"
    printf '#!/usr/bin/env bash\nbash plugins/dso/scripts/validate.sh --ci\n' > "$_file"
    _exit=0
    _out=$(bash "$SCRIPT" "$_file" 2>&1) || _exit=$?
    assert_eq "test_script_to_script_excluded: exit 0 for script-to-script reference" "0" "$_exit"
    assert_pass_if_clean "test_script_to_script_excluded"
}

# ── test_shim_exempt_comment_suppresses ───────────────────────────────────────
# A line containing a violation pattern but also carrying a # shim-exempt: <reason>
# comment must be suppressed — the script must exit 0 for that file.
test_shim_exempt_comment_suppresses() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    mkdir -p "$_dir/plugins/dso/skills/my-skill"
    _file="$_dir/plugins/dso/skills/my-skill/SKILL.md"
    printf '# My Skill\n\nRun `plugins/dso/scripts/validate.sh` # shim-exempt: direct reference in example\n' > "$_file"
    _exit=0
    _out=$(bash "$SCRIPT" "$_file" 2>&1) || _exit=$?
    assert_eq "test_shim_exempt_comment_suppresses: exit 0 when shim-exempt comment present" "0" "$_exit"
    assert_pass_if_clean "test_shim_exempt_comment_suppresses"
}

# ── test_exit_zero_on_clean_file ──────────────────────────────────────────────
# A skill file with no violation patterns must cause the script to exit 0.
test_exit_zero_on_clean_file() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    mkdir -p "$_dir/plugins/dso/skills/my-skill"
    _file="$_dir/plugins/dso/skills/my-skill/SKILL.md"
    cat > "$_file" << 'EOF'
# My Skill

Use `/dso:sprint` to run epics end-to-end.
Use `.claude/scripts/dso validate.sh --ci` to validate.
This file has no shim violation patterns.
EOF
    _exit=0
    _out=$(bash "$SCRIPT" "$_file" 2>&1) || _exit=$?
    assert_eq "test_exit_zero_on_clean_file: exit 0 for clean file" "0" "$_exit"
    assert_pass_if_clean "test_exit_zero_on_clean_file"
}

# ── test_multi_pattern_detection ──────────────────────────────────────────────
# A file containing multiple distinct violation patterns (literal path AND
# variable path) must be flagged — the script exits non-zero and reports
# the violating file.
test_multi_pattern_detection() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    mkdir -p "$_dir/plugins/dso/skills/my-skill"
    _file="$_dir/plugins/dso/skills/my-skill/SKILL.md"
    cat > "$_file" << 'EOF'
# My Skill

Step 1: Run `plugins/dso/scripts/validate.sh --ci`.
Step 2: Or use `$PLUGIN_SCRIPTS/validate.sh`.
EOF
    _exit=0
    _out=$(bash "$SCRIPT" "$_file" 2>&1) || _exit=$?
    assert_ne "test_multi_pattern_detection: exit != 0 for multiple violation types" "0" "$_exit"
    assert_contains "test_multi_pattern_detection: violating file reported in output" "SKILL.md" "$_out"
    assert_pass_if_clean "test_multi_pattern_detection"
}

# ── test_scope_filtering_out_of_scope ─────────────────────────────────────────
# A file located outside the plugins/dso/ directory tree must NOT be flagged
# regardless of whether it contains the violation patterns — only files within
# plugins/dso/ are in scope.
test_scope_filtering_out_of_scope() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    # Place the file outside plugins/dso/
    _file="$_dir/some-other-doc.md"
    printf '# Other Doc\n\nRun `plugins/dso/scripts/validate.sh --ci` from host repo.\n' > "$_file"
    _exit=0
    _out=$(bash "$SCRIPT" "$_file" 2>&1) || _exit=$?
    assert_eq "test_scope_filtering_out_of_scope: exit 0 for file outside plugins/dso/" "0" "$_exit"
    assert_pass_if_clean "test_scope_filtering_out_of_scope"
}

# ── test_validate_runs_shim_refs_check ────────────────────────────────────────
# Wiring check (SC3): validate.sh source must contain a call to check-shim-refs.sh
# as part of the --ci pipeline. This is a static contract test.
#
# Strategy: read validate.sh source and assert it references "check-shim-refs"
# (the check name that appears in run_check / report_check calls). This test
# passes only once validate.sh is updated to include the shim-refs check.
#
# This test FAILS (RED) until validate.sh is updated to include the shim-refs
# wiring in its --ci pipeline.
test_validate_runs_shim_refs_check() {
    _snapshot_fail
    local _validate_sh _has_ref
    _validate_sh="$PLUGIN_ROOT/plugins/dso/scripts/validate.sh"

    # Static check: validate.sh must contain the string "check-shim-refs"
    # in an actual run_check or report_check invocation — not just a comment
    if grep -qE '(run_check|report_check|tally_check).*shim-refs' "$_validate_sh" 2>/dev/null; then
        _has_ref="yes"
    else
        _has_ref="no"
    fi
    assert_eq "test_validate_runs_shim_refs_check: validate.sh wires check-shim-refs" "yes" "$_has_ref"
    assert_pass_if_clean "test_validate_runs_shim_refs_check"
}

# ── test_precommit_blocks_shim_violation ──────────────────────────────────────
# Pre-commit wiring check (SC4): .pre-commit-config.yaml must contain an entry
# that invokes check-shim-refs.sh as a pre-commit hook. This is a static
# contract test — it verifies the hook is wired into the pre-commit pipeline.
#
# This test FAILS (RED) until .pre-commit-config.yaml is updated to wire
# check-shim-refs.sh as a pre-commit hook for plugins/dso/ files.
test_precommit_blocks_shim_violation() {
    _snapshot_fail
    local _precommit_config _has_entry
    _precommit_config="$PLUGIN_ROOT/.pre-commit-config.yaml"

    # Static check: .pre-commit-config.yaml must contain a reference to
    # check-shim-refs.sh as a pre-commit hook entry
    if grep -q 'check-shim-refs' "$_precommit_config" 2>/dev/null; then
        _has_entry="yes"
    else
        _has_entry="no"
    fi
    assert_eq "test_precommit_blocks_shim_violation: .pre-commit-config.yaml wires check-shim-refs" "yes" "$_has_entry"
    assert_pass_if_clean "test_precommit_blocks_shim_violation"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_exit_nonzero_on_literal_path
test_exit_nonzero_on_variable_path
test_exit_nonzero_on_curly_variable_path
test_source_hooks_lib_excluded
test_script_to_script_excluded
test_shim_exempt_comment_suppresses
test_exit_zero_on_clean_file
test_multi_pattern_detection
test_scope_filtering_out_of_scope
test_validate_runs_shim_refs_check
test_precommit_blocks_shim_violation

print_summary
