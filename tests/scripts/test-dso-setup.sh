#!/usr/bin/env bash
# tests/scripts/test-dso-setup.sh
# TDD red-phase tests for scripts/dso-setup.sh
#
# Verifies that dso-setup.sh installs the dso shim into a host project's
# .claude/scripts/ directory and writes dso.plugin_root to workflow-config.conf.
#
# RED PHASE: All tests are expected to FAIL until scripts/dso-setup.sh is created.
#
# Usage:
#   bash tests/scripts/test-dso-setup.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETUP_SCRIPT="$PLUGIN_ROOT/scripts/dso-setup.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

TMPDIRS=()
trap 'rm -rf "${TMPDIRS[@]}"' EXIT

echo "=== test-dso-setup.sh ==="

# ── test_setup_creates_shim ───────────────────────────────────────────────────
# Running dso-setup.sh must create .claude/scripts/dso in the target directory.
test_setup_creates_shim() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || true

    if [[ -f "$T/.claude/scripts/dso" ]]; then
        assert_eq "test_setup_creates_shim" "exists" "exists"
    else
        assert_eq "test_setup_creates_shim" "exists" "missing"
    fi
}

# ── test_setup_shim_executable ────────────────────────────────────────────────
# The installed shim must be executable (chmod +x).
test_setup_shim_executable() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || true

    if [[ -x "$T/.claude/scripts/dso" ]]; then
        assert_eq "test_setup_shim_executable" "executable" "executable"
    else
        assert_eq "test_setup_shim_executable" "executable" "not-executable"
    fi
}

# ── test_setup_writes_plugin_root ─────────────────────────────────────────────
# Running dso-setup.sh must write dso.plugin_root=<path> to workflow-config.conf
# in the target directory.
test_setup_writes_plugin_root() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || true

    local result="missing"
    if grep -q "^dso.plugin_root=" "$T/workflow-config.conf" 2>/dev/null; then
        result="exists"
    fi
    assert_eq "test_setup_writes_plugin_root" "exists" "$result"
}

# ── test_setup_is_idempotent ──────────────────────────────────────────────────
# Running dso-setup.sh twice must not duplicate the dso.plugin_root entry.
# Also: running setup on a target that already has a different dso.plugin_root
# entry must update it (not add a second line).
test_setup_is_idempotent() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    # Run twice — must not duplicate the entry
    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || true
    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || true

    local count=0
    count=$(grep -c "^dso.plugin_root=" "$T/workflow-config.conf" 2>/dev/null || echo "0")
    assert_eq "test_setup_is_idempotent" "1" "$count"

    # Also verify: pre-existing entry with different path is replaced, not duplicated
    local T2
    T2=$(mktemp -d)
    TMPDIRS+=("$T2")
    echo "dso.plugin_root=/old/path" > "$T2/workflow-config.conf"
    bash "$SETUP_SCRIPT" "$T2" "$PLUGIN_ROOT" >/dev/null 2>&1 || true

    local count2=0
    count2=$(grep -c "^dso.plugin_root=" "$T2/workflow-config.conf" 2>/dev/null || echo "0")
    assert_eq "test_setup_is_idempotent (pre-existing entry)" "1" "$count2"
}

# ── test_setup_dso_tk_help_works ──────────────────────────────────────────────
# After setup, invoking the installed shim with 'tk --help' (without
# CLAUDE_PLUGIN_ROOT set — forcing the shim to read from workflow-config.conf)
# must exit 0.
test_setup_dso_tk_help_works() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || true

    local exit_code=0
    (
        cd "$T"
        unset CLAUDE_PLUGIN_ROOT
        "./.claude/scripts/dso" tk --help >/dev/null 2>&1
    ) || exit_code=$?
    assert_eq "test_setup_dso_tk_help_works" "0" "$exit_code"
}

# REVIEW-DEFENSE: Error-path tests (missing arguments, invalid TARGET_DIR) are out of
# scope for this RED-phase task. The RED phase covers the happy-path contract that the
# script must satisfy. Error-path and edge-case coverage belongs in the GREEN implementation
# task (dso-jl2z), where the script's full interface is defined and tested.

# ── Prerequisite check tests (dso-zq4q) ──────────────────────────────────────

# test_prereq_bash_version_fatal: inject fake bash reporting version 3; script exits 1
test_prereq_bash_version_fatal() {
    local T FAKE_PATH fake_bash
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    FAKE_PATH=$(mktemp -d)
    TMPDIRS+=("$FAKE_PATH")

    # Create a fake 'bash' that prints version 3.x when --version is called
    cat > "$FAKE_PATH/bash" << 'EOF'
#!/bin/sh
if [ "$1" = "--version" ]; then
    echo "GNU bash, version 3.2.57(1)-release (x86_64-apple-darwin)"
    exit 0
fi
exec /bin/bash "$@"
EOF
    chmod +x "$FAKE_PATH/bash"

    local exit_code=0
    PATH="$FAKE_PATH:$PATH" bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || exit_code=$?
    assert_eq "test_prereq_bash_version_fatal" "1" "$exit_code"
}

# _make_tool_path: build a fake PATH directory containing symlinks to system tools,
# excluding a specific set of commands. Appends the tmpdir to TMPDIRS for cleanup.
# Usage: _make_tool_path EXCLUDE_CMD [EXCLUDE_CMD ...] — prints path of fake dir
#
# NOTE: Callers must use PATH="$fake_dir:/bin" (NOT /usr/bin) to avoid macOS
# /usr/bin stubs for python3, etc. that exist even when the tool is not installed.
_make_tool_path() {
    local exclude=("$@")
    local fake_dir real_bash
    fake_dir=$(mktemp -d)
    TMPDIRS+=("$fake_dir")
    real_bash=$(command -v bash)

    # Tools the script needs beyond shell builtins (excluding bash — handled below)
    local needed_tools=(uname grep sed head cut git python3 pre-commit claude timeout gtimeout mkdir cp chmod printf rm)
    for cmd in "${needed_tools[@]}"; do
        local should_exclude=0
        for ex in "${exclude[@]}"; do
            if [[ "$cmd" == "$ex" ]]; then should_exclude=1; break; fi
        done
        [[ "$should_exclude" -eq 1 ]] && continue
        local src
        src=$(command -v "$cmd" 2>/dev/null) || true
        if [[ -n "$src" ]]; then
            ln -sf "$src" "$fake_dir/$cmd"
        fi
    done
    # Always provide a bash >=4 stub that delegates to the real bash via absolute path
    cat > "$fake_dir/bash" << EOF
#!/bin/sh
if [ "\$1" = "--version" ]; then
    echo "GNU bash, version 5.2.15(1)-release (x86_64-apple-darwin)"
    exit 0
fi
exec "$real_bash" "\$@"
EOF
    chmod +x "$fake_dir/bash"
    echo "$fake_dir"
}

# test_prereq_missing_coreutils_fatal: PATH without timeout/gtimeout; script exits 1
test_prereq_missing_coreutils_fatal() {
    local T fake_dir
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    fake_dir=$(_make_tool_path timeout gtimeout)

    local exit_code=0
    PATH="$fake_dir" bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || exit_code=$?
    assert_eq "test_prereq_missing_coreutils_fatal" "1" "$exit_code"
}

# test_prereq_missing_precommit_warning: PATH without pre-commit; script exits 2
test_prereq_missing_precommit_warning() {
    local T fake_dir
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    fake_dir=$(_make_tool_path pre-commit)

    local exit_code=0
    PATH="$fake_dir:/bin" bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || exit_code=$?
    assert_eq "test_prereq_missing_precommit_warning" "2" "$exit_code"
}

# test_prereq_missing_python3_warning: PATH without python3; script exits 2
# NOTE: /usr/bin is intentionally excluded from fake PATH to avoid the macOS
# /usr/bin/python3 stub that exists even without a real Python installation.
test_prereq_missing_python3_warning() {
    local T fake_dir
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    fake_dir=$(_make_tool_path python3)

    local exit_code=0
    PATH="$fake_dir:/bin" bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || exit_code=$?
    assert_eq "test_prereq_missing_python3_warning" "2" "$exit_code"
}

# test_prereq_all_present_exit0: controlled PATH with stubs for all warning-level tools; script exits 0
# Uses _make_tool_path so this test is not environment-dependent and passes in clean CI
# where 'claude' CLI may not be installed.
test_prereq_all_present_exit0() {
    local T fake_dir
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    # Build a fake PATH that includes symlinks to real tools from _make_tool_path.
    # Then ensure stubs exist for warning-level tools that may be absent in CI.
    fake_dir=$(_make_tool_path)
    # Ensure 'claude' stub exists (CI may not have it installed)
    if [[ ! -e "$fake_dir/claude" ]]; then
        printf '#!/bin/sh\nexit 0\n' > "$fake_dir/claude"
        chmod +x "$fake_dir/claude"
    fi
    # Ensure 'pre-commit' stub exists
    if [[ ! -e "$fake_dir/pre-commit" ]]; then
        printf '#!/bin/sh\nexit 0\n' > "$fake_dir/pre-commit"
        chmod +x "$fake_dir/pre-commit"
    fi
    # Ensure 'python3' stub exists
    if [[ ! -e "$fake_dir/python3" ]]; then
        printf '#!/bin/sh\nexit 0\n' > "$fake_dir/python3"
        chmod +x "$fake_dir/python3"
    fi

    local exit_code=0
    PATH="$fake_dir:/bin" bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || exit_code=$?
    assert_eq "test_prereq_all_present_exit0" "0" "$exit_code"
}

# ── Pre-commit config and CI scaffolding tests (dso-3z2v) ─────────────────────

# test_setup_copies_precommit_config: copies example .pre-commit-config.yaml to fresh target
test_setup_copies_precommit_config() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || true

    if [[ -f "$T/.pre-commit-config.yaml" ]]; then
        assert_eq "test_setup_copies_precommit_config" "exists" "exists"
    else
        assert_eq "test_setup_copies_precommit_config" "exists" "missing"
    fi
}

# test_setup_precommit_config_not_overwritten: existing .pre-commit-config.yaml is not overwritten
test_setup_precommit_config_not_overwritten() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    echo "existing-content" > "$T/.pre-commit-config.yaml"

    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || true

    local content
    content=$(cat "$T/.pre-commit-config.yaml")
    assert_eq "test_setup_precommit_config_not_overwritten" "existing-content" "$content"
}

# test_setup_precommit_config_contains_review_gate: copied config contains review-gate entry
test_setup_precommit_config_contains_review_gate() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || true

    if grep -q 'pre-commit-review-gate' "$T/.pre-commit-config.yaml" 2>/dev/null; then
        assert_eq "test_setup_precommit_config_contains_review_gate" "found" "found"
    else
        assert_eq "test_setup_precommit_config_contains_review_gate" "found" "missing"
    fi
}

# test_setup_copies_ci_yml: copies example ci.yml to fresh target
test_setup_copies_ci_yml() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || true

    if [[ -f "$T/.github/workflows/ci.yml" ]]; then
        assert_eq "test_setup_copies_ci_yml" "exists" "exists"
    else
        assert_eq "test_setup_copies_ci_yml" "exists" "missing"
    fi
}

# test_setup_ci_yml_not_overwritten: existing ci.yml is not overwritten
test_setup_ci_yml_not_overwritten() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    mkdir -p "$T/.github/workflows"
    echo "existing-ci" > "$T/.github/workflows/ci.yml"

    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || true

    local content
    content=$(cat "$T/.github/workflows/ci.yml")
    assert_eq "test_setup_ci_yml_not_overwritten" "existing-ci" "$content"
}

# ── Optional dep detection, env var guidance, success summary (dso-ghcp) ──────

# test_setup_outputs_env_var_guidance: script output contains CLAUDE_PLUGIN_ROOT guidance
test_setup_outputs_env_var_guidance() {
    local T output
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    output=$(bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" 2>&1) || true

    if [[ "$output" == *"CLAUDE_PLUGIN_ROOT"* ]]; then
        assert_eq "test_setup_outputs_env_var_guidance" "found" "found"
    else
        assert_eq "test_setup_outputs_env_var_guidance" "found" "missing"
    fi
}

# test_setup_outputs_success_summary: script output references next steps with project-setup
test_setup_outputs_success_summary() {
    local T output
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    output=$(bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" 2>&1) || true

    if [[ "$output" == *"project-setup"* ]]; then
        assert_eq "test_setup_outputs_success_summary" "found" "found"
    else
        assert_eq "test_setup_outputs_success_summary" "found" "missing"
    fi
}

# test_setup_outputs_optional_dep_guidance: when acli not in PATH, output mentions acli
# Uses exclusive PATH (fake_dir:/bin) to prevent real acli from being found.
test_setup_outputs_optional_dep_guidance() {
    local T fake_dir output
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q
    # Build fake PATH without acli; use exclusive PATH to prevent system acli from being found
    fake_dir=$(_make_tool_path acli)

    output=$(PATH="$fake_dir:/bin" bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" 2>&1) || true

    if [[ "$output" == *"acli"* ]]; then
        assert_eq "test_setup_outputs_optional_dep_guidance" "found" "found"
    else
        assert_eq "test_setup_outputs_optional_dep_guidance" "found" "missing"
    fi
}

# test_pyyaml_check_skipped_when_python3_absent: when python3 is not on PATH,
# the PyYAML optional-dep message should NOT appear (guard against missing python3)
test_pyyaml_check_skipped_when_python3_absent() {
    local T fake_dir output
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q
    # Build fake PATH without python3 (exclusive PATH to avoid system stubs)
    fake_dir=$(_make_tool_path python3)

    output=$(PATH="$fake_dir" bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" 2>&1) || true

    if [[ "$output" != *"PyYAML"* ]]; then
        assert_eq "test_pyyaml_check_skipped_when_python3_absent" "not_found" "not_found"
    else
        assert_eq "test_pyyaml_check_skipped_when_python3_absent" "not_found" "found"
    fi
}

# test_setup_is_still_idempotent_with_new_features: running twice produces same state
test_setup_is_still_idempotent_with_new_features() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || true
    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || true

    local count=0
    count=$(grep -c "^dso.plugin_root=" "$T/workflow-config.conf" 2>/dev/null || echo "0")
    assert_eq "test_setup_is_still_idempotent_with_new_features" "1" "$count"
}

# ── --dryrun flag tests (dso-ojbb) ────────────────────────────────────────────

# test_setup_dryrun_no_shim_created: --dryrun must NOT create .claude/scripts/dso
test_setup_dryrun_no_shim_created() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" --dryrun >/dev/null 2>&1 || true

    if [[ ! -f "$T/.claude/scripts/dso" ]]; then
        assert_eq "test_setup_dryrun_no_shim_created" "not-created" "not-created"
    else
        assert_eq "test_setup_dryrun_no_shim_created" "not-created" "created"
    fi
}

# test_setup_dryrun_no_config_written: --dryrun must NOT write workflow-config.conf
test_setup_dryrun_no_config_written() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" --dryrun >/dev/null 2>&1 || true

    if [[ ! -f "$T/workflow-config.conf" ]]; then
        assert_eq "test_setup_dryrun_no_config_written" "not-written" "not-written"
    else
        assert_eq "test_setup_dryrun_no_config_written" "not-written" "written"
    fi
}

# test_setup_dryrun_no_precommit_copied: --dryrun must NOT copy .pre-commit-config.yaml
test_setup_dryrun_no_precommit_copied() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" --dryrun >/dev/null 2>&1 || true

    if [[ ! -f "$T/.pre-commit-config.yaml" ]]; then
        assert_eq "test_setup_dryrun_no_precommit_copied" "not-copied" "not-copied"
    else
        assert_eq "test_setup_dryrun_no_precommit_copied" "not-copied" "copied"
    fi
}

# test_setup_dryrun_output_contains_shim_preview: --dryrun stdout must contain '[dryrun]'
test_setup_dryrun_output_contains_shim_preview() {
    local T output
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    output=$(bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" --dryrun 2>&1) || true

    if [[ "$output" == *"[dryrun]"* ]]; then
        assert_eq "test_setup_dryrun_output_contains_shim_preview" "found" "found"
    else
        assert_eq "test_setup_dryrun_output_contains_shim_preview" "found" "missing"
    fi
}

# test_setup_dryrun_flag_position_independent: --dryrun works as 3rd positional arg
test_setup_dryrun_flag_position_independent() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    # --dryrun is already the 3rd arg (after TARGET_REPO and PLUGIN_ROOT)
    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" --dryrun >/dev/null 2>&1 || true

    if [[ ! -f "$T/.claude/scripts/dso" ]]; then
        assert_eq "test_setup_dryrun_flag_position_independent" "not-created" "not-created"
    else
        assert_eq "test_setup_dryrun_flag_position_independent" "not-created" "created"
    fi
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_setup_creates_shim
test_setup_shim_executable
test_setup_writes_plugin_root
test_setup_is_idempotent
test_setup_dso_tk_help_works
test_prereq_bash_version_fatal
test_prereq_missing_coreutils_fatal
test_prereq_missing_precommit_warning
test_prereq_missing_python3_warning
test_prereq_all_present_exit0
test_setup_copies_precommit_config
test_setup_precommit_config_not_overwritten
test_setup_precommit_config_contains_review_gate
test_setup_copies_ci_yml
test_setup_ci_yml_not_overwritten
test_setup_outputs_env_var_guidance
test_setup_outputs_success_summary
test_setup_outputs_optional_dep_guidance
test_pyyaml_check_skipped_when_python3_absent
test_setup_is_still_idempotent_with_new_features
test_setup_dryrun_no_shim_created
test_setup_dryrun_no_config_written
test_setup_dryrun_no_precommit_copied
test_setup_dryrun_output_contains_shim_preview
test_setup_dryrun_flag_position_independent

print_summary
