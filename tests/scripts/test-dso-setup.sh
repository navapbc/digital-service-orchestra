#!/usr/bin/env bash
# tests/scripts/test-dso-setup.sh
# TDD red-phase tests for scripts/onboarding/dso-setup.sh
#
# Verifies that dso-setup.sh installs the dso shim into a host project's
# .claude/scripts/ directory and writes dso.plugin_root to dso-config.conf.
#
# RED PHASE: All tests are expected to FAIL until scripts/onboarding/dso-setup.sh is created.
#
# Usage:
#   bash tests/scripts/test-dso-setup.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SETUP_SCRIPT="$DSO_PLUGIN_DIR/scripts/onboarding/dso-setup.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

TMPDIRS=()
trap 'rm -rf "${TMPDIRS[@]}"' EXIT

# ── Performance: stub out pre-commit to avoid 0.35s `pre-commit install` per call.
# dso-setup.sh calls `pre-commit install` as a side effect on every invocation.
# Tests here verify file-level behavior (shim copy, config merge), not hook
# installation. A no-op stub eliminates ~20s of overhead across 59 invocations.
# Tests that explicitly test pre-commit absence construct their own restricted
# PATH via _make_tool_path and are unaffected by this stub.
_STUB_BIN=$(mktemp -d)
TMPDIRS+=("$_STUB_BIN")
printf '#!/bin/sh\nexit 0\n' > "$_STUB_BIN/pre-commit"
chmod +x "$_STUB_BIN/pre-commit"
export PATH="$_STUB_BIN:$PATH"

echo "=== test-dso-setup.sh ==="

# ── _seed_python_poetry_stack: helper for tests that need stack-specific install ─
# Bug 5d92 defect B removed the python-poetry default fallback in
# _resolve_stack_{ci,precommit}_example. Tests that previously relied on that
# fallback (to get ci.yml / .pre-commit-config.yaml installed in a fixture
# with no explicit stack) must now declare stack=python-poetry explicitly.
# This helper writes the stack key to a fixture's dso-config.conf.
_seed_python_poetry_stack() {
    local target="$1"
    mkdir -p "$target/.claude"
    if [[ -f "$target/.claude/dso-config.conf" ]]; then
        grep -q '^stack=' "$target/.claude/dso-config.conf" || echo "stack=python-poetry" >> "$target/.claude/dso-config.conf"
    else
        echo "stack=python-poetry" > "$target/.claude/dso-config.conf"
    fi
}

# ── test_setup_creates_shim ───────────────────────────────────────────────────
# Running dso-setup.sh must create .claude/scripts/dso in the target directory.
test_setup_creates_shim() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

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

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    if [[ -x "$T/.claude/scripts/dso" ]]; then
        assert_eq "test_setup_shim_executable" "executable" "executable"
    else
        assert_eq "test_setup_shim_executable" "executable" "not-executable"
    fi
}

# ── test_setup_writes_plugin_root ─────────────────────────────────────────────
# Running dso-setup.sh must write dso.plugin_root=<path> to .claude/dso-config.conf
# in the target directory.
test_setup_writes_plugin_root() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    local result="missing"
    if grep -q "^dso.plugin_root=" "$T/.claude/dso-config.conf" 2>/dev/null; then
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
    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true
    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    local count=0
    count=$(grep -c "^dso.plugin_root=" "$T/.claude/dso-config.conf" 2>/dev/null || echo "0")
    assert_eq "test_setup_is_idempotent" "1" "$count"

    # Also verify: pre-existing entry with different path is replaced, not duplicated
    local T2
    T2=$(mktemp -d)
    TMPDIRS+=("$T2")
    mkdir -p "$T2/.claude"
    echo "dso.plugin_root=/old/path" > "$T2/.claude/dso-config.conf"
    bash "$SETUP_SCRIPT" "$T2" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    local count2=0
    count2=$(grep -c "^dso.plugin_root=" "$T2/.claude/dso-config.conf" 2>/dev/null || echo "0")
    assert_eq "test_setup_is_idempotent (pre-existing entry)" "1" "$count2"
}

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
    PATH="$FAKE_PATH:$PATH" bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || exit_code=$?
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
    local needed_tools=(uname grep sed head cut cat git python3 pre-commit claude timeout gtimeout mkdir cp chmod printf rm mktemp)
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
    PATH="$fake_dir" bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || exit_code=$?
    assert_eq "test_prereq_missing_coreutils_fatal" "1" "$exit_code"
}

# test_prereq_missing_precommit_warning: PATH without pre-commit; script exits 2
test_prereq_missing_precommit_warning() {
    local T fake_dir
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    fake_dir=$(_make_tool_path pre-commit)

    local exit_code=0
    PATH="$fake_dir:/bin" bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || exit_code=$?
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
    PATH="$fake_dir:/bin" bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || exit_code=$?
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
    PATH="$fake_dir:/bin" bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || exit_code=$?
    assert_eq "test_prereq_all_present_exit0" "0" "$exit_code"
}

# ── Pre-commit config and CI scaffolding tests (dso-3z2v) ─────────────────────

# test_setup_copies_precommit_config: copies example .pre-commit-config.yaml to fresh target
test_setup_copies_precommit_config() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

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

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

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

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    if grep -q 'pre-commit-review-gate' "$T/.pre-commit-config.yaml" 2>/dev/null; then
        assert_eq "test_setup_precommit_config_contains_review_gate" "found" "found"
    else
        assert_eq "test_setup_precommit_config_contains_review_gate" "found" "missing"
    fi
}

# test_setup_precommit_stack_aware_generic_for_non_python: non-Python stack uses generic
# pre-commit example (no Python-only hook ids like poetry-lock-check or isolation-check).
# Refs: bugs 5f8b-2a22-4e2e-4e1f, b74b-40cb-3d97-4edb
test_setup_precommit_stack_aware_generic_for_non_python() {
    local T
    T=$(mktemp -d /tmp/test-dso-setup.XXXXXX)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    # Simulate non-Python stack detection output
    local detect_file
    detect_file=$(mktemp /tmp/test-dso-setup.XXXXXX)
    TMPDIRS+=("$detect_file")
    printf 'stack=ruby-rails\nframework=rails\n' > "$detect_file"

    DSO_DETECT_OUTPUT="$detect_file" bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    # The installed config must NOT contain Python-only hook ids
    if grep -q 'poetry-lock-check\|isolation-check\|format-and-lint\|security-scan\|check-assertion-density' "$T/.pre-commit-config.yaml" 2>/dev/null; then
        assert_eq "test_setup_precommit_stack_aware_generic_for_non_python: ruby-rails must not contain Python hooks" \
            "no-python-hooks" "python-hooks-found"
    else
        assert_eq "test_setup_precommit_stack_aware_generic_for_non_python: ruby-rails must not contain Python hooks" \
            "no-python-hooks" "no-python-hooks"
    fi
    # The installed config must still contain DSO review gate
    if grep -q 'pre-commit-review-gate' "$T/.pre-commit-config.yaml" 2>/dev/null; then
        assert_eq "test_setup_precommit_stack_aware_generic_for_non_python: must still contain review gate" \
            "found" "found"
    else
        assert_eq "test_setup_precommit_stack_aware_generic_for_non_python: must still contain review gate" \
            "found" "missing"
    fi
}

# test_setup_copies_ci_yml: copies example ci.yml to fresh target
test_setup_copies_ci_yml() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q
    _seed_python_poetry_stack "$T"  # bug 5d92 defect B: explicit stack now required for ci.yml install

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

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

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

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

    output=$(bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" 2>&1) || true

    if [[ "$output" == *"CLAUDE_PLUGIN_ROOT"* ]]; then
        assert_eq "test_setup_outputs_env_var_guidance" "found" "found"
    else
        assert_eq "test_setup_outputs_env_var_guidance" "found" "missing"
    fi
}

# test_setup_outputs_success_summary: script output references next steps with onboarding
test_setup_outputs_success_summary() {
    local T output
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    output=$(bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" 2>&1) || true

    if [[ "$output" == *"onboarding"* ]]; then
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

    output=$(PATH="$fake_dir:/bin" bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" 2>&1) || true

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

    output=$(PATH="$fake_dir" bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" 2>&1) || true

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

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true
    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    local count=0
    count=$(grep -c "^dso.plugin_root=" "$T/.claude/dso-config.conf" 2>/dev/null || echo "0")
    assert_eq "test_setup_is_still_idempotent_with_new_features" "1" "$count"
}

# ── --dryrun flag tests (dso-ojbb) ────────────────────────────────────────────

# test_setup_dryrun_no_shim_created: --dryrun must NOT create .claude/scripts/dso
test_setup_dryrun_no_shim_created() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" --dryrun >/dev/null 2>&1 || true

    if [[ ! -f "$T/.claude/scripts/dso" ]]; then
        assert_eq "test_setup_dryrun_no_shim_created" "not-created" "not-created"
    else
        assert_eq "test_setup_dryrun_no_shim_created" "not-created" "created"
    fi
}

# test_setup_dryrun_no_config_written: --dryrun must NOT write .claude/dso-config.conf
test_setup_dryrun_no_config_written() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" --dryrun >/dev/null 2>&1 || true

    if [[ ! -f "$T/.claude/dso-config.conf" ]]; then
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

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" --dryrun >/dev/null 2>&1 || true

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

    output=$(bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" --dryrun 2>&1) || true

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
    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" --dryrun >/dev/null 2>&1 || true

    if [[ ! -f "$T/.claude/scripts/dso" ]]; then
        assert_eq "test_setup_dryrun_flag_position_independent" "not-created" "not-created"
    else
        assert_eq "test_setup_dryrun_flag_position_independent" "not-created" "created"
    fi
}

# ── CLAUDE.md and KNOWN-ISSUES.md supplement detection tests (w21-cu3r) ───────
#
# DSO section markers:
#   CLAUDE.md:       '=== GENERATED BY /generate-claude-md'
#   KNOWN-ISSUES.md: '<!-- DSO:KNOWN-ISSUES-HEADER -->'
#
# These tests are RED-phase: they FAIL until dso-setup.sh implements supplement logic.

# test_claudemd_not_overwritten: when CLAUDE.md already exists, setup warns and does NOT overwrite it
test_claudemd_not_overwritten() {
    local T output
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    # Pre-populate CLAUDE.md with user-owned content
    mkdir -p "$T/.claude"
    echo "# My existing CLAUDE.md content" > "$T/.claude/CLAUDE.md"

    output=$(bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" 2>&1) || true

    # File must still contain the original content (not overwritten — original line still present)
    if grep -qF "# My existing CLAUDE.md content" "$T/.claude/CLAUDE.md" 2>/dev/null; then
        assert_eq "test_claudemd_not_overwritten: content preserved" "found" "found"
    else
        assert_eq "test_claudemd_not_overwritten: content preserved" "found" "missing"
    fi

    # Output must contain a warning about the existing CLAUDE.md
    if [[ "$output" == *"CLAUDE.md"* ]]; then
        assert_eq "test_claudemd_not_overwritten: warns about existing file" "found" "found"
    else
        assert_eq "test_claudemd_not_overwritten: warns about existing file" "found" "missing"
    fi
}

# test_claudemd_supplement_no_duplicate_dso_sections: when CLAUDE.md already has DSO section
# markers, running setup (supplement mode) does NOT duplicate those sections
test_claudemd_supplement_no_duplicate_dso_sections() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    # Pre-populate CLAUDE.md with existing DSO-generated sections
    mkdir -p "$T/.claude"
    cat > "$T/.claude/CLAUDE.md" << 'EOF'
# My Project Config

<!-- === GENERATED BY /generate-claude-md — DO NOT EDIT MANUALLY ===
     DSO section content here
=== END GENERATED SECTION === -->

## My custom section
EOF

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    # Count occurrences of the DSO marker — must be exactly 1 (not duplicated)
    local count
    count=$(grep -c '=== GENERATED BY /generate-claude-md' "$T/.claude/CLAUDE.md" 2>/dev/null || echo "0")
    assert_eq "test_claudemd_supplement_no_duplicate_dso_sections" "1" "$count"
}

# test_claudemd_supplement_appends_dso_scaffolding: when CLAUDE.md exists WITHOUT DSO sections,
# supplement mode appends the DSO scaffolding block
test_claudemd_supplement_appends_dso_scaffolding() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    # Pre-populate CLAUDE.md with user content but NO DSO markers
    mkdir -p "$T/.claude"
    echo "# My existing CLAUDE.md — no DSO sections yet" > "$T/.claude/CLAUDE.md"

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    # After supplement, the DSO marker must be present
    if grep -q '=== GENERATED BY /generate-claude-md' "$T/.claude/CLAUDE.md" 2>/dev/null; then
        assert_eq "test_claudemd_supplement_appends_dso_scaffolding" "found" "found"
    else
        assert_eq "test_claudemd_supplement_appends_dso_scaffolding" "found" "missing"
    fi
}

# test_known_issues_not_overwritten: when KNOWN-ISSUES.md already exists, setup warns and does NOT overwrite
test_known_issues_not_overwritten() {
    local T output
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    # Pre-populate KNOWN-ISSUES.md with user-owned content
    mkdir -p "$T/.claude/docs"
    echo "# My existing KNOWN-ISSUES content" > "$T/.claude/docs/KNOWN-ISSUES.md"

    output=$(bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" 2>&1) || true

    # File must still contain the original content (not overwritten — original line still present)
    if grep -qF "# My existing KNOWN-ISSUES content" "$T/.claude/docs/KNOWN-ISSUES.md" 2>/dev/null; then
        assert_eq "test_known_issues_not_overwritten: content preserved" "found" "found"
    else
        assert_eq "test_known_issues_not_overwritten: content preserved" "found" "missing"
    fi

    # Output must contain a warning about the existing KNOWN-ISSUES.md
    if [[ "$output" == *"KNOWN-ISSUES"* ]]; then
        assert_eq "test_known_issues_not_overwritten: warns about existing file" "found" "found"
    else
        assert_eq "test_known_issues_not_overwritten: warns about existing file" "found" "missing"
    fi
}

# test_known_issues_supplement_no_duplicate_dso_header: when KNOWN-ISSUES.md already has a DSO
# header marker, supplement mode does NOT duplicate it
test_known_issues_supplement_no_duplicate_dso_header() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    # Pre-populate KNOWN-ISSUES.md with existing DSO header marker
    mkdir -p "$T/.claude/docs"
    cat > "$T/.claude/docs/KNOWN-ISSUES.md" << 'EOF'
<!-- DSO:KNOWN-ISSUES-HEADER -->
# Known Issues and Incident Log

> DSO-generated header already present
EOF

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    # Count occurrences of the DSO marker — must be exactly 1 (not duplicated)
    local count
    count=$(grep -c '<!-- DSO:KNOWN-ISSUES-HEADER -->' "$T/.claude/docs/KNOWN-ISSUES.md" 2>/dev/null || echo "0")
    assert_eq "test_known_issues_supplement_no_duplicate_dso_header" "1" "$count"
}

# test_supplement_check_uses_string_matching: verification that supplement detection uses
# the DSO section-header marker string, not line count. A file with many lines but no
# marker should be treated as needing supplement (marker absent), while a single-line
# file with the marker should be treated as already supplemented (marker present).
test_supplement_check_uses_string_matching() {
    local T T2
    T=$(mktemp -d)
    T2=$(mktemp -d)
    TMPDIRS+=("$T" "$T2")
    git -C "$T" init -q
    git -C "$T2" init -q

    # Case 1: Large file WITHOUT marker — should get the marker appended (supplement applied)
    mkdir -p "$T/.claude"
    {
        echo "# Big file with many lines"
        for i in $(seq 1 50); do
            echo "Line $i: some content about project rules and configuration"
        done
    } > "$T/.claude/CLAUDE.md"

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    if grep -q '=== GENERATED BY /generate-claude-md' "$T/.claude/CLAUDE.md" 2>/dev/null; then
        assert_eq "test_supplement_check_uses_string_matching: large-no-marker gets supplement" "found" "found"
    else
        assert_eq "test_supplement_check_uses_string_matching: large-no-marker gets supplement" "found" "missing"
    fi

    # Case 2: Short file WITH marker — should NOT get the marker duplicated (supplement skipped)
    mkdir -p "$T2/.claude"
    printf '<!-- === GENERATED BY /generate-claude-md — DO NOT EDIT MANUALLY ===\n     minimal\n=== END GENERATED SECTION === -->\n' > "$T2/.claude/CLAUDE.md"

    bash "$SETUP_SCRIPT" "$T2" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    local count2
    count2=$(grep -c '=== GENERATED BY /generate-claude-md' "$T2/.claude/CLAUDE.md" 2>/dev/null || echo "0")
    assert_eq "test_supplement_check_uses_string_matching: short-with-marker no duplicate" "1" "$count2"
}

# ── Pre-commit YAML hook merge tests (w21-u5mg) ───────────────────────────────
#
# RED-phase: All tests FAIL until dso-setup.sh implements merge logic.
# Merge strategy: append-repos (add the DSO local repo block to the existing
# repos list). The existing file's fail_fast and other top-level keys are preserved.
#
# All tests use an existing .pre-commit-config.yaml WITHOUT pre-commit-review-gate,
# then assert that after setup the review-gate IS present or that other merge
# behaviors hold. These assertions all fail because merge logic does not yet exist.

# _make_existing_precommit: write a minimal existing .pre-commit-config.yaml
# WITHOUT review-gate into TARGET_DIR. Used by all merge tests below.
_make_existing_precommit() {
    local target_dir="$1"
    cat > "$target_dir/.pre-commit-config.yaml" << 'PCEOF'
fail_fast: false

repos:
  - repo: local
    hooks:
      - id: user-existing-hook
        name: User Existing Hook
        entry: ./scripts/user-hook.sh
        language: system
        pass_filenames: false
        stages: [pre-commit]
PCEOF
}

# test_precommit_merge_not_overwritten: existing .pre-commit-config.yaml with a
# repos: section is NOT replaced with the full DSO example config after running
# dso-setup.sh (the original user hook must still be present after merge).
test_precommit_merge_not_overwritten() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q
    _make_existing_precommit "$T"

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    # The original user hook must still be present
    if grep -q 'user-existing-hook' "$T/.pre-commit-config.yaml" 2>/dev/null; then
        assert_eq "test_precommit_merge_not_overwritten: original hook preserved" "found" "found"
    else
        assert_eq "test_precommit_merge_not_overwritten: original hook preserved" "found" "missing"
    fi

    # The pre-commit-review-gate must ALSO be present (merged in, not just copied)
    # This assertion drives the RED failure: merge logic doesn't exist yet.
    if grep -q 'pre-commit-review-gate' "$T/.pre-commit-config.yaml" 2>/dev/null; then
        assert_eq "test_precommit_merge_not_overwritten: review-gate merged in" "found" "found"
    else
        assert_eq "test_precommit_merge_not_overwritten: review-gate merged in" "found" "missing"
    fi
}

# test_precommit_merge_adds_review_gate: when existing .pre-commit-config.yaml has a
# repos: section, the DSO pre-commit-review-gate hook is merged into the file.
test_precommit_merge_adds_review_gate() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q
    _make_existing_precommit "$T"

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    # After merge, the pre-commit-review-gate hook id must be present
    if grep -q 'pre-commit-review-gate' "$T/.pre-commit-config.yaml" 2>/dev/null; then
        assert_eq "test_precommit_merge_adds_review_gate" "found" "found"
    else
        assert_eq "test_precommit_merge_adds_review_gate" "found" "missing"
    fi
}

# test_precommit_merge_no_duplicate_review_gate: when existing .pre-commit-config.yaml
# already contains the pre-commit-review-gate hook id, it is NOT duplicated after merge.
# This test requires that: (a) merge logic exists (so a fresh file gets the hook), AND
# (b) idempotent merge logic avoids duplicating it on repeated runs.
test_precommit_merge_no_duplicate_review_gate() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q
    _make_existing_precommit "$T"

    # Run twice — first run merges the hook; second run must not duplicate it.
    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true
    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    # Count occurrences of 'id: pre-commit-review-gate' — must be exactly 1
    local count
    count=$(grep -c 'id: pre-commit-review-gate' "$T/.pre-commit-config.yaml" 2>/dev/null || echo "0")
    assert_eq "test_precommit_merge_no_duplicate_review_gate" "1" "$count"
}

# test_precommit_merge_preserves_existing_hooks: after merge, the pre-existing hook
# entries are NOT deleted (merge is additive, not replacing).
test_precommit_merge_preserves_existing_hooks() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    # Existing config with multiple user hooks
    cat > "$T/.pre-commit-config.yaml" << 'EOF'
fail_fast: false

repos:
  - repo: local
    hooks:
      - id: hook-alpha
        name: Hook Alpha
        entry: ./scripts/alpha.sh
        language: system
        pass_filenames: false
        stages: [pre-commit]
      - id: hook-beta
        name: Hook Beta
        entry: ./scripts/beta.sh
        language: system
        pass_filenames: false
        stages: [pre-commit]
EOF

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    local result="preserved"
    if ! grep -q 'id: hook-alpha' "$T/.pre-commit-config.yaml" 2>/dev/null; then
        result="hook-alpha-missing"
    elif ! grep -q 'id: hook-beta' "$T/.pre-commit-config.yaml" 2>/dev/null; then
        result="hook-beta-missing"
    fi
    assert_eq "test_precommit_merge_preserves_existing_hooks: existing hooks remain" "preserved" "$result"

    # Also require that review-gate was added (driving the RED failure)
    if grep -q 'pre-commit-review-gate' "$T/.pre-commit-config.yaml" 2>/dev/null; then
        assert_eq "test_precommit_merge_preserves_existing_hooks: review-gate added" "found" "found"
    else
        assert_eq "test_precommit_merge_preserves_existing_hooks: review-gate added" "found" "missing"
    fi
}

# test_precommit_yaml_merge_produces_valid_yaml: the merged .pre-commit-config.yaml
# can be parsed as valid YAML after the DSO hook is merged in.
test_precommit_yaml_merge_produces_valid_yaml() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q
    _make_existing_precommit "$T"

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    # First verify review-gate was merged in (required precondition — fails RED)
    if grep -q 'pre-commit-review-gate' "$T/.pre-commit-config.yaml" 2>/dev/null; then
        assert_eq "test_precommit_yaml_merge_produces_valid_yaml: review-gate present" "found" "found"
    else
        assert_eq "test_precommit_yaml_merge_produces_valid_yaml: review-gate present" "found" "missing"
    fi

    # Then validate the YAML is still parseable (skip if PyYAML not installed)
    if python3 -c "import yaml" 2>/dev/null; then
        local yaml_valid="invalid"
        if python3 -c "import yaml; yaml.safe_load(open('$T/.pre-commit-config.yaml'))" 2>/dev/null; then
            yaml_valid="valid"
        fi
        assert_eq "test_precommit_yaml_merge_produces_valid_yaml: yaml parseable" "valid" "$yaml_valid"
    else
        echo "  (skipped yaml validity check — pyyaml not installed)" >&2
    fi
}

# test_precommit_hook_merge_dryrun_no_changes: in --dryrun mode, no changes are made
# to an existing .pre-commit-config.yaml (the review-gate must NOT be merged in),
# AND the dryrun output must mention that a merge would occur.
test_precommit_hook_merge_dryrun_no_changes() {
    local T output
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q
    _make_existing_precommit "$T"

    # Capture original content
    local original_content
    original_content=$(cat "$T/.pre-commit-config.yaml")

    output=$(bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" --dryrun 2>&1) || true

    # After --dryrun, file content must be unchanged (no review-gate merged in)
    local after_content
    after_content=$(cat "$T/.pre-commit-config.yaml")
    assert_eq "test_precommit_hook_merge_dryrun_no_changes: file unchanged" "$original_content" "$after_content"

    # Dryrun output must indicate what merge would occur (RED: message doesn't exist yet)
    if [[ "$output" == *"pre-commit-review-gate"* ]] && [[ "$output" == *"[dryrun]"* ]]; then
        assert_eq "test_precommit_hook_merge_dryrun_no_changes: dryrun merge preview" "found" "found"
    else
        assert_eq "test_precommit_hook_merge_dryrun_no_changes: dryrun merge preview" "found" "missing"
    fi
}

# ── CI workflow guard analysis tests (w21-up9s) ───────────────────────────────
#
# RED-phase: All tests FAIL until dso-setup.sh implements CI guard analysis.
#
# The guard analysis:
#   - Accepts detection output (key=value from project-detect.sh) via DSO_DETECT_OUTPUT env var
#     pointing to a temp file with key=value lines (e.g. ci.has_lint_guard=true)
#   - The canonical detection keys for guard status are:
#       ci_workflow_lint_guarded=true|false
#       ci_workflow_test_guarded=true|false
#       ci_workflow_format_guarded=true|false
#   - When a CI workflow file (any name) already exists under .github/workflows/,
#     dso-setup.sh does NOT copy ci.example.yml
#   - When a guard is indicated as present in detection output, setup does not offer to add it
#   - When a guard is MISSING in detection output, setup outputs a message indicating it
#   - --dryrun shows guard analysis output but modifies nothing

# _make_ci_detection_file: write key=value detection output to a temp file.
# Usage: _make_ci_detection_file TMPDIR KEY=VALUE [KEY=VALUE ...]
# Prints path to the temp file.
_make_ci_detection_file() {
    local tmpdir="$1"
    shift
    local detect_file
    detect_file=$(mktemp "$tmpdir/detect-output.XXXXXX")
    for pair in "$@"; do
        echo "$pair"
    done > "$detect_file"
    echo "$detect_file"
}

# test_ci_guard_any_workflow_name_prevents_copy: when ANY .github/workflows/*.yml
# file exists (not necessarily ci.yml), dso-setup.sh does NOT copy ci.example.yml.
# This tests the "any name" condition from AC #1.
test_ci_guard_any_workflow_name_prevents_copy() {
    local T detect_file
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    # Create an existing CI workflow with a different name
    mkdir -p "$T/.github/workflows"
    cat > "$T/.github/workflows/build.yml" << 'EOF'
name: Build
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "building"
EOF

    # Setup should detect the existing workflow and not copy ci.example.yml
    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    # ci.yml must NOT have been created (the existing build.yml counts as a workflow)
    if [[ ! -f "$T/.github/workflows/ci.yml" ]]; then
        assert_eq "test_ci_guard_any_workflow_name_prevents_copy: ci.yml not created" "not-created" "not-created"
    else
        assert_eq "test_ci_guard_any_workflow_name_prevents_copy: ci.yml not created" "not-created" "created"
    fi
}

# test_ci_guard_lint_present_no_offer: when detection output has ci_workflow_lint_guarded=true,
# dso-setup.sh output does NOT contain a message offering to add the lint guard.
test_ci_guard_lint_present_no_offer() {
    local T detect_file output
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q
    _seed_python_poetry_stack "$T"  # bug 5d92 defect B: explicit stack required for CI scaffolding

    # Existing workflow with lint already present
    mkdir -p "$T/.github/workflows"
    cat > "$T/.github/workflows/ci.yml" << 'EOF'
name: CI
on: [push]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: make lint
EOF

    detect_file=$(_make_ci_detection_file "$T" \
        "ci_workflow_lint_guarded=true" \
        "ci_workflow_test_guarded=false" \
        "ci_workflow_format_guarded=false")

    output=$(DSO_DETECT_OUTPUT="$detect_file" bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" 2>&1) || true

    # Guard analysis must have run: output must contain a guard-analysis summary line
    # (e.g. "[ci-guard]", "CI guard analysis", "guard check", etc.)
    # This assertion drives the RED failure — the feature doesn't exist yet.
    if [[ "$output" == *"[ci-guard]"* ]] || [[ "$output" == *"ci guard"* ]] || \
       [[ "$output" == *"guard analysis"* ]] || [[ "$output" == *"guard check"* ]] || \
       [[ "$output" == *"CI workflow guards"* ]]; then
        assert_eq "test_ci_guard_lint_present_no_offer: guard analysis ran" "found" "found"
    else
        assert_eq "test_ci_guard_lint_present_no_offer: guard analysis ran" "found" "missing"
    fi

    # Output must NOT offer to add lint guard when it's already present
    if [[ "$output" != *"add lint guard"* && "$output" != *"missing lint"* && "$output" != *"lint guard missing"* ]]; then
        assert_eq "test_ci_guard_lint_present_no_offer: no lint-guard offer when present" "no-offer" "no-offer"
    else
        assert_eq "test_ci_guard_lint_present_no_offer: no lint-guard offer when present" "no-offer" "offer-found"
    fi
}

# test_ci_guard_missing_test_guard_detected: when detection output has
# ci_workflow_test_guarded=false, dso-setup.sh outputs a message indicating
# the missing test guard was detected.
test_ci_guard_missing_test_guard_detected() {
    local T detect_file output
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q
    _seed_python_poetry_stack "$T"  # bug 5d92 defect B: explicit stack required for CI scaffolding

    # Existing workflow WITHOUT a test step
    mkdir -p "$T/.github/workflows"
    cat > "$T/.github/workflows/ci.yml" << 'EOF'
name: CI
on: [push]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: make lint
EOF

    detect_file=$(_make_ci_detection_file "$T" \
        "ci_workflow_lint_guarded=true" \
        "ci_workflow_test_guarded=false" \
        "ci_workflow_format_guarded=false")

    output=$(DSO_DETECT_OUTPUT="$detect_file" bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" 2>&1) || true

    # Output must contain a message indicating the missing test guard
    # (matching patterns like "missing test", "test guard", "no test step", etc.)
    if [[ "$output" == *"test"* ]] && \
       { [[ "$output" == *"missing"* ]] || [[ "$output" == *"guard"* ]] || [[ "$output" == *"not found"* ]]; }; then
        assert_eq "test_ci_guard_missing_test_guard_detected: missing test guard reported" "found" "found"
    else
        assert_eq "test_ci_guard_missing_test_guard_detected: missing test guard reported" "found" "missing"
    fi
}

# test_ci_guard_consumes_detection_output_not_yaml: guard analysis must consume the
# DSO_DETECT_OUTPUT key=value file, not re-parse the workflow YAML directly.
# We verify this by providing detection output that contradicts what YAML parsing
# would find: the workflow YAML has a test step, but detection says test NOT guarded.
# The script should trust the detection output and report the missing test guard.
test_ci_guard_consumes_detection_output_not_yaml() {
    local T detect_file output
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q
    _seed_python_poetry_stack "$T"  # bug 5d92 defect B: explicit stack required for CI scaffolding

    # Existing workflow WITH a test step (YAML would say guarded)
    mkdir -p "$T/.github/workflows"
    cat > "$T/.github/workflows/ci.yml" << 'EOF'
name: CI
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: make test
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: make lint
EOF

    # Detection output says test is NOT guarded (contradicts YAML)
    detect_file=$(_make_ci_detection_file "$T" \
        "ci_workflow_lint_guarded=true" \
        "ci_workflow_test_guarded=false" \
        "ci_workflow_format_guarded=false")

    output=$(DSO_DETECT_OUTPUT="$detect_file" bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" 2>&1) || true

    # Script must trust detection output (test=false) and report missing test guard,
    # NOT re-parse the YAML which would say test is present.
    if [[ "$output" == *"test"* ]] && \
       { [[ "$output" == *"missing"* ]] || [[ "$output" == *"guard"* ]]; }; then
        assert_eq "test_ci_guard_consumes_detection_output_not_yaml: trusts detection output" "found" "found"
    else
        assert_eq "test_ci_guard_consumes_detection_output_not_yaml: trusts detection output" "found" "missing"
    fi
}

# test_ci_guard_dryrun_shows_analysis_no_changes: in --dryrun mode, CI guard analysis
# output is shown but no files are modified.
test_ci_guard_dryrun_shows_analysis_no_changes() {
    local T detect_file output
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q
    _seed_python_poetry_stack "$T"  # bug 5d92 defect B: explicit stack required for CI scaffolding

    # Existing workflow WITHOUT test or format guards
    mkdir -p "$T/.github/workflows"
    cat > "$T/.github/workflows/ci.yml" << 'EOF'
name: CI
on: [push]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: make lint
EOF

    detect_file=$(_make_ci_detection_file "$T" \
        "ci_workflow_lint_guarded=true" \
        "ci_workflow_test_guarded=false" \
        "ci_workflow_format_guarded=false")

    # Capture original CI file content
    local original_content
    original_content=$(cat "$T/.github/workflows/ci.yml")

    output=$(DSO_DETECT_OUTPUT="$detect_file" bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" --dryrun 2>&1) || true

    # CI file must be unchanged after --dryrun
    local after_content
    after_content=$(cat "$T/.github/workflows/ci.yml")
    assert_eq "test_ci_guard_dryrun_shows_analysis_no_changes: ci.yml unchanged" "$original_content" "$after_content"

    # Output must contain guard-analysis-specific dryrun output (not just any [dryrun] line).
    # Specifically, it must reference CI guard analysis + the missing test guard.
    # This drives the RED failure — dso-setup.sh does not yet emit guard analysis output.
    if { [[ "$output" == *"[dryrun]"* ]] || [[ "$output" == *"[ci-guard]"* ]]; } && \
       { [[ "$output" == *"test guard"* ]] || [[ "$output" == *"ci_workflow_test_guarded"* ]] || \
         [[ "$output" == *"test: missing"* ]] || [[ "$output" == *"guard analysis"* ]]; }; then
        assert_eq "test_ci_guard_dryrun_shows_analysis_no_changes: guard analysis shown in dryrun" "found" "found"
    else
        assert_eq "test_ci_guard_dryrun_shows_analysis_no_changes: guard analysis shown in dryrun" "found" "missing"
    fi
}

# test_ci_guard_no_workflow_still_copies_example: when NO CI workflow exists at all
# AND no detection output is provided, ci.example.yml is still copied to ci.yml.
# This verifies that the new guard analysis code does not break the original behavior.
test_ci_guard_no_workflow_still_copies_example() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q
    _seed_python_poetry_stack "$T"  # bug 5d92 defect B: explicit stack required for CI scaffolding

    # No existing workflow, no detection output
    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    if [[ -f "$T/.github/workflows/ci.yml" ]]; then
        assert_eq "test_ci_guard_no_workflow_still_copies_example: ci.yml created when absent" "exists" "exists"
    else
        assert_eq "test_ci_guard_no_workflow_still_copies_example: ci.yml created when absent" "exists" "missing"
    fi
}

# test_ci_guard_missing_format_guard_detected: when detection output has
# ci_workflow_format_guarded=false, dso-setup.sh outputs a message indicating
# the missing format guard was detected.
test_ci_guard_missing_format_guard_detected() {
    local T detect_file output
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q
    _seed_python_poetry_stack "$T"  # bug 5d92 defect B: explicit stack required for CI scaffolding

    # Existing workflow without format step
    mkdir -p "$T/.github/workflows"
    cat > "$T/.github/workflows/ci.yml" << 'EOF'
name: CI
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: make test
EOF

    detect_file=$(_make_ci_detection_file "$T" \
        "ci_workflow_lint_guarded=true" \
        "ci_workflow_test_guarded=true" \
        "ci_workflow_format_guarded=false")

    output=$(DSO_DETECT_OUTPUT="$detect_file" bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" 2>&1) || true

    # Output must contain a message indicating the missing format guard
    if [[ "$output" == *"format"* ]] && \
       { [[ "$output" == *"missing"* ]] || [[ "$output" == *"guard"* ]] || [[ "$output" == *"not found"* ]]; }; then
        assert_eq "test_ci_guard_missing_format_guard_detected: missing format guard reported" "found" "found"
    else
        assert_eq "test_ci_guard_missing_format_guard_detected: missing format guard reported" "found" "missing"
    fi
}

# ── Ticket gate hook merge tests (dso-8jp8) ──────────────────────────────────
#
# Verifies that dso-setup.sh merges the pre-commit-ticket-gate hook entry from
# examples/pre-commit-config.example.yaml into an existing .pre-commit-config.yaml.
#
# These tests use a minimal pre-commit config (just a repos: section) to isolate
# the ticket-gate merge behavior from other hook merging.

# _make_minimal_precommit: write a minimal .pre-commit-config.yaml (no DSO hooks)
# into TARGET_DIR. Used by ticket-gate merge tests.
_make_minimal_precommit() {
    local target_dir="$1"
    cat > "$target_dir/.pre-commit-config.yaml" << 'PCEOF'
repos:
  - repo: local
    hooks:
      - id: my-project-hook
        name: My Project Hook
        entry: ./scripts/my-hook.sh
        language: system
        pass_filenames: false
        stages: [pre-commit]
PCEOF
}

# test_ticket_gate_hook_merged: when an existing .pre-commit-config.yaml lacks
# the pre-commit-ticket-gate hook, running dso-setup.sh merges it in.
test_ticket_gate_hook_merged() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q
    _make_minimal_precommit "$T"

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    if grep -q 'pre-commit-ticket-gate' "$T/.pre-commit-config.yaml" 2>/dev/null; then
        assert_eq "test_ticket_gate_hook_merged" "found" "found"
    else
        assert_eq "test_ticket_gate_hook_merged" "found" "missing"
    fi
}

# test_ticket_gate_hook_idempotent: running dso-setup.sh twice does NOT duplicate
# the pre-commit-ticket-gate hook id in .pre-commit-config.yaml.
test_ticket_gate_hook_idempotent() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q
    _make_minimal_precommit "$T"

    # Run twice — second run must not add a duplicate ticket-gate entry
    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true
    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    local count
    count=$(grep -c 'id: pre-commit-ticket-gate' "$T/.pre-commit-config.yaml" 2>/dev/null || echo "0")
    assert_eq "test_ticket_gate_hook_idempotent" "1" "$count"
}

# test_ticket_gate_hook_preserves_existing_hooks: after merging the ticket-gate hook,
# pre-existing hooks in .pre-commit-config.yaml are NOT removed.
test_ticket_gate_hook_preserves_existing_hooks() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q
    _make_minimal_precommit "$T"

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    # The original project hook must still be present
    if grep -q 'my-project-hook' "$T/.pre-commit-config.yaml" 2>/dev/null; then
        assert_eq "test_ticket_gate_hook_preserves_existing_hooks: original hook preserved" "found" "found"
    else
        assert_eq "test_ticket_gate_hook_preserves_existing_hooks: original hook preserved" "found" "missing"
    fi

    # The ticket-gate must also be present (additive merge)
    if grep -q 'pre-commit-ticket-gate' "$T/.pre-commit-config.yaml" 2>/dev/null; then
        assert_eq "test_ticket_gate_hook_preserves_existing_hooks: ticket-gate added" "found" "found"
    else
        assert_eq "test_ticket_gate_hook_preserves_existing_hooks: ticket-gate added" "found" "missing"
    fi
}

# test_ticket_gate_hook_dryrun_no_changes: in --dryrun mode, the ticket-gate hook is
# NOT written to .pre-commit-config.yaml, but dryrun output mentions it.
test_ticket_gate_hook_dryrun_no_changes() {
    local T output
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q
    _make_minimal_precommit "$T"

    local original_content
    original_content=$(cat "$T/.pre-commit-config.yaml")

    output=$(bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" --dryrun 2>&1) || true

    # File must be unchanged after --dryrun
    local after_content
    after_content=$(cat "$T/.pre-commit-config.yaml")
    assert_eq "test_ticket_gate_hook_dryrun_no_changes: file unchanged" "$original_content" "$after_content"

    # Dryrun output must mention both [dryrun] and pre-commit-ticket-gate
    if [[ "$output" == *"[dryrun]"* ]] && [[ "$output" == *"pre-commit-ticket-gate"* ]]; then
        assert_eq "test_ticket_gate_hook_dryrun_no_changes: dryrun output mentions ticket-gate" "found" "found"
    else
        assert_eq "test_ticket_gate_hook_dryrun_no_changes: dryrun output mentions ticket-gate" "found" "missing"
    fi
}

# test_ticket_gate_hook_not_duplicated_when_already_present: when the existing config
# already contains 'id: pre-commit-ticket-gate', dso-setup.sh does NOT add it again.
test_ticket_gate_hook_not_duplicated_when_already_present() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    # Pre-populate with a config that already has the ticket-gate hook
    cat > "$T/.pre-commit-config.yaml" << 'PCEOF'
repos:
  - repo: local
    hooks:
      - id: pre-commit-ticket-gate
        name: Ticket Gate (10s timeout)
        entry: ./scripts/pre-commit-wrapper.sh pre-commit-ticket-gate 10 "echo gate"
        language: system
        pass_filenames: false
        always_run: true
        stages: [commit-msg]
PCEOF

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    local count
    count=$(grep -c 'id: pre-commit-ticket-gate' "$T/.pre-commit-config.yaml" 2>/dev/null || echo "0")
    assert_eq "test_ticket_gate_hook_not_duplicated_when_already_present" "1" "$count"
}

# test_ticket_gate_hook_fresh_install: when no .pre-commit-config.yaml exists, the
# full example config is copied — which includes the pre-commit-ticket-gate entry.
test_ticket_gate_hook_fresh_install() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    # No pre-commit config — fresh install path
    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    if grep -q 'pre-commit-ticket-gate' "$T/.pre-commit-config.yaml" 2>/dev/null; then
        assert_eq "test_ticket_gate_hook_fresh_install" "found" "found"
    else
        assert_eq "test_ticket_gate_hook_fresh_install" "found" "missing"
    fi
}

# ── .claude/dso-config.conf path tests (dso-hui3) ────────────────────────────
#
# RED-phase: All 3 tests FAIL until dso-setup.sh is updated to write
# dso.plugin_root= to .claude/dso-config.conf instead of dso-config.conf.

# test_setup_writes_dso_config_conf: dso-setup.sh must write dso.plugin_root=
# to .claude/dso-config.conf (not dso-config.conf).
test_setup_writes_dso_config_conf() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    local result="missing"
    if grep -q "^dso.plugin_root=" "$T/.claude/dso-config.conf" 2>/dev/null; then
        result="exists"
    fi
    assert_eq "test_setup_writes_dso_config_conf" "exists" "$result"
}

# test_setup_dso_config_conf_idempotent: running dso-setup.sh twice must NOT
# duplicate dso.plugin_root= in .claude/dso-config.conf.
test_setup_dso_config_conf_idempotent() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true
    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    local count=0
    count=$(grep -c "^dso.plugin_root=" "$T/.claude/dso-config.conf" 2>/dev/null || echo "0")
    assert_eq "test_setup_dso_config_conf_idempotent" "1" "$count"
}

# test_setup_dryrun_no_dso_config_conf_written: --dryrun must NOT create
# .claude/dso-config.conf.
test_setup_dryrun_no_dso_config_conf_written() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" --dryrun >/dev/null 2>&1 || true

    if [[ ! -f "$T/.claude/dso-config.conf" ]]; then
        assert_eq "test_setup_dryrun_no_dso_config_conf_written" "not-written" "not-written"
    else
        assert_eq "test_setup_dryrun_no_dso_config_conf_written" "not-written" "written"
    fi
}

# ── stamp_artifact() tests (57ad-0d1e) ───────────────────────────────────────
# RED phase: all tests FAIL until stamp_artifact() is implemented in dso-setup.sh.

# test_stamp_in_shim: dso-setup.sh must embed `# dso-version: <version>` in
# the first 5 lines of the installed .claude/scripts/dso shim.
test_stamp_in_shim() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    local result="missing"
    if head -5 "$T/.claude/scripts/dso" 2>/dev/null | grep -q '# dso-version:'; then
        result="found"
    fi
    assert_eq "test_stamp_in_shim" "found" "$result"
}

# test_stamp_in_config: dso-setup.sh must embed `# dso-version: <version>` in
# .claude/dso-config.conf.
test_stamp_in_config() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    local result="missing"
    if grep -q '# dso-version:' "$T/.claude/dso-config.conf" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_stamp_in_config" "found" "$result"
}

# test_stamp_in_precommit_yaml: dso-setup.sh must embed `x-dso-version: <version>`
# as a top-level YAML key in .pre-commit-config.yaml.
test_stamp_in_precommit_yaml() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    local result="missing"
    if grep -q '^x-dso-version:' "$T/.pre-commit-config.yaml" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_stamp_in_precommit_yaml" "found" "$result"
}

# test_stamp_in_ci_yaml: dso-setup.sh must embed `x-dso-version: <version>` as a
# top-level YAML key in .github/workflows/ci.yml.
test_stamp_in_ci_yaml() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    _seed_python_poetry_stack "$T"  # bug 5d92 defect B: explicit stack required for ci.yml install

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    local result="missing"
    if grep -q '^x-dso-version:' "$T/.github/workflows/ci.yml" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_stamp_in_ci_yaml" "found" "$result"
}

# test_stamp_idempotent: running dso-setup.sh twice must not duplicate the
# version stamp in any artifact. Each stamp must appear exactly once.
test_stamp_idempotent() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true
    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    local shim_count config_count
    shim_count=$(grep -c '# dso-version:' "$T/.claude/scripts/dso" 2>/dev/null || echo "0")
    config_count=$(grep -c '# dso-version:' "$T/.claude/dso-config.conf" 2>/dev/null || echo "0")

    assert_eq "test_stamp_idempotent: shim stamp count" "1" "$shim_count"
    assert_eq "test_stamp_idempotent: config stamp count" "1" "$config_count"
}

# test_gitignore_includes_cache: dso-setup.sh must append `.claude/dso-artifact-check-cache`
# to the host project's .gitignore.
test_gitignore_includes_cache() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    local result="missing"
    if grep -q 'dso-artifact-check-cache' "$T/.gitignore" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_gitignore_includes_cache" "found" "$result"
}

# test_yaml_stamp_survives_roundtrip: after dso-setup.sh installs the stamp,
# running merge_precommit_hooks again must not remove the x-dso-version key.
test_yaml_stamp_survives_roundtrip() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    # First install (stamps yaml)
    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true
    # Second install (idempotent merge — stamp must survive)
    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    local result="missing"
    if grep -q '^x-dso-version:' "$T/.pre-commit-config.yaml" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_yaml_stamp_survives_roundtrip" "found" "$result"
}

# test_validate_handles_stamped_config: running dso-setup.sh on a temp dir and
# then running validate.sh must not fail due to the stamp comment in dso-config.conf.
# (Validates no false positive from stamp comment format.)
test_validate_handles_stamped_config() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    # Verify the stamped config is valid KEY=VALUE format (not broken by stamp)
    local result="ok"
    # The stamp line starts with '#' which is a valid comment — parse should be clean
    if grep -v '^#' "$T/.claude/dso-config.conf" 2>/dev/null | grep -v '^$' | grep -vE '^[a-zA-Z._-]+='; then
        result="broken"
    fi
    assert_eq "test_validate_handles_stamped_config" "ok" "$result"
}

# ── SC5: merge_config_file and merge_ci_workflow on INSTALL path (245c-439c) ──

# test_install_merges_new_config_keys: when an existing dso-config.conf is missing
# a key that appears in the reference config, dso-setup.sh appends the missing key.
test_install_merges_new_config_keys() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    # Write a config that has dso.plugin_root (so setup doesn't overwrite it) but
    # is intentionally missing 'worktree.isolation_enabled' and 'scope_drift.enabled'.
    mkdir -p "$T/.claude"
    cat > "$T/.claude/dso-config.conf" << 'EOF'
dso.plugin_root=/some/path
version=1.1.0
EOF

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    # At least one key that exists in the reference config but was absent from the
    # pre-installed config must now be present (additive merge).
    local merged_key_found="false"
    if grep -qE '^(worktree\.isolation_enabled|scope_drift\.enabled|test_quality\.tool|clarity_check\.pass_threshold)=' \
           "$T/.claude/dso-config.conf" 2>/dev/null; then
        merged_key_found="true"
    fi
    assert_eq "test_install_merges_new_config_keys: reference key appended" "true" "$merged_key_found"

    # The original dso.plugin_root must NOT have been overwritten or duplicated
    local plugin_root_count
    plugin_root_count=$(grep -c '^dso\.plugin_root=' "$T/.claude/dso-config.conf" 2>/dev/null || echo "0")
    assert_eq "test_install_merges_new_config_keys: plugin_root not duplicated" "1" "$plugin_root_count"
}

# ── Root INSTALL.md reference test (6698-43a2) ───────────────────────────────
#
# RED phase: dso-setup.sh currently prints "docs/INSTALL.md" in its completion
# summary. INSTALL.md has moved to the repo root, so the script output must
# reference the root path ("INSTALL.md"), not the old docs/ path.
#
# Behavioral assertion: run the script, capture its observable stdout+stderr,
# and verify:
#   (a) the old "docs/INSTALL.md" path does NOT appear in runtime output
#   (b) a bare "INSTALL.md" reference DOES appear (root path guidance present)
#
# This captures user-visible behavior (what the script tells the operator to
# read). It fails before the fix and passes once the fix updates the echo line.
test_setup_references_root_install_doc() {
    local T output
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    output=$(bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" 2>&1) || true

    # (a) The deprecated "docs/INSTALL.md" path must NOT appear in the output.
    local old_path_result="absent"
    if grep -q 'docs/INSTALL\.md' <<< "$output"; then
        old_path_result="present"
    fi
    assert_eq "test_setup_references_root_install_doc: old 'docs/INSTALL.md' absent" "absent" "$old_path_result"

    # (b) A root "INSTALL.md" reference must be present (guidance retained).
    local root_ref_result="missing"
    if grep -q 'INSTALL\.md' <<< "$output"; then
        root_ref_result="found"
    fi
    assert_eq "test_setup_references_root_install_doc: root 'INSTALL.md' referenced" "found" "$root_ref_result"
}

# test_install_merges_ci_workflow: when an existing CI workflow file is present,
# dso-setup.sh calls merge_ci_workflow to merge DSO job definitions into it.
# The existing workflow content must be preserved and a DSO job must be added.
test_install_merges_ci_workflow() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q
    _seed_python_poetry_stack "$T"  # bug 5d92 defect B: explicit stack required for CI scaffolding

    # Create a minimal existing CI workflow (no DSO jobs)
    mkdir -p "$T/.github/workflows"
    cat > "$T/.github/workflows/ci.yml" << 'EOF'
name: My CI
on: [push, pull_request]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "build"
EOF

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    # The original job must still be present (merge is additive, not replacing)
    if grep -q 'build:' "$T/.github/workflows/ci.yml" 2>/dev/null; then
        assert_eq "test_install_merges_ci_workflow: existing job preserved" "found" "found"
    else
        assert_eq "test_install_merges_ci_workflow: existing job preserved" "found" "missing"
    fi

    # At least one DSO job from the example must have been merged in
    # (fast-gate is the first job in ci.example.yml)
    if grep -q 'fast-gate\|fast_gate\|mypy\|coverage-check' "$T/.github/workflows/ci.yml" 2>/dev/null; then
        assert_eq "test_install_merges_ci_workflow: DSO job merged in" "found" "found"
    else
        assert_eq "test_install_merges_ci_workflow: DSO job merged in" "found" "missing"
    fi
}

# test_setup_does_not_write_absolute_home_cache_path (9841-4169)
# When dso-setup.sh is invoked with a PLUGIN_ROOT that lives under
# $HOME/.claude/ (marketplace cache install), it must NOT write an absolute
# developer-local path to dso-config.conf. Multi-developer clones would fail
# because the path encodes the installing developer's $HOME.
#
# RED: current dso-setup.sh unconditionally writes dso.plugin_root=<absolute>
# regardless of whether the path is under $HOME. This test fails before the fix.
test_setup_does_not_write_absolute_home_cache_path() {
    local T fake_home fake_cache_root
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    # Use a temp dir as the fake HOME so the home-cache condition ($HOME/.claude/...)
    # is satisfied without touching the real home directory.
    # Symlink the actual plugin dir into the fake marketplace path so dso-setup.sh
    # finds a complete plugin tree and reaches the dso.plugin_root write logic.
    fake_home=$(mktemp -d)
    TMPDIRS+=("$fake_home")
    local fake_cache_parent="$fake_home/.claude/plugins/marketplaces/digital-service-orchestra/plugins"
    mkdir -p "$fake_cache_parent"
    ln -s "$DSO_PLUGIN_DIR" "$fake_cache_parent/dso"
    fake_cache_root="$fake_cache_parent/dso"

    HOME="$fake_home" bash "$SETUP_SCRIPT" "$T" "$fake_cache_root" >/dev/null 2>&1 || true

    local has_absolute_home="no"
    if grep -q "^dso\.plugin_root=$fake_home" "$T/.claude/dso-config.conf" 2>/dev/null; then
        has_absolute_home="yes"
    fi
    assert_eq "test_setup_does_not_write_absolute_home_cache_path" "no" "$has_absolute_home"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_setup_creates_shim
test_setup_shim_executable
test_setup_writes_plugin_root
test_setup_is_idempotent
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
test_claudemd_not_overwritten
test_claudemd_supplement_no_duplicate_dso_sections
test_claudemd_supplement_appends_dso_scaffolding
test_known_issues_not_overwritten
test_known_issues_supplement_no_duplicate_dso_header
test_supplement_check_uses_string_matching
test_precommit_merge_not_overwritten
test_precommit_merge_adds_review_gate
test_precommit_merge_no_duplicate_review_gate
test_precommit_merge_preserves_existing_hooks
test_precommit_yaml_merge_produces_valid_yaml
test_precommit_hook_merge_dryrun_no_changes
test_ci_guard_any_workflow_name_prevents_copy
test_ci_guard_lint_present_no_offer
test_ci_guard_missing_test_guard_detected
test_ci_guard_consumes_detection_output_not_yaml
test_ci_guard_dryrun_shows_analysis_no_changes
test_ci_guard_no_workflow_still_copies_example
test_ci_guard_missing_format_guard_detected
test_setup_writes_dso_config_conf
test_setup_dso_config_conf_idempotent
test_setup_dryrun_no_dso_config_conf_written
test_ticket_gate_hook_merged
test_ticket_gate_hook_idempotent
test_ticket_gate_hook_preserves_existing_hooks
test_ticket_gate_hook_dryrun_no_changes
test_ticket_gate_hook_not_duplicated_when_already_present
test_ticket_gate_hook_fresh_install
test_stamp_in_shim
test_stamp_in_config
test_stamp_in_precommit_yaml
test_stamp_in_ci_yaml
test_stamp_idempotent
test_gitignore_includes_cache
test_yaml_stamp_survives_roundtrip
test_validate_handles_stamped_config
test_install_merges_new_config_keys
test_install_merges_ci_workflow
test_setup_references_root_install_doc
test_setup_precommit_stack_aware_generic_for_non_python
test_setup_does_not_write_absolute_home_cache_path

# ── Opt-out flags (bug 2145-fe0b-99ae-418f) ──────────────────────────────────
# dso-setup.sh accepts --opt-ci=no / --opt-precommit=no / --opt-claude-md=no /
# --opt-known-issues=no flags. Each gates the corresponding install block so
# the Socratic dialog's opt-out signals are honored instead of being ignored.

test_setup_opt_out_skips_ci_and_precommit() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" \
        --opt-ci=no --opt-precommit=no >/dev/null 2>&1 || true

    local ci_status="present"
    [[ ! -f "$T/.github/workflows/ci.yml" ]] && ci_status="absent"
    assert_eq "opt-out: ci.yml absent under --opt-ci=no" "absent" "$ci_status"

    local precommit_status="present"
    [[ ! -f "$T/.pre-commit-config.yaml" ]] && precommit_status="absent"
    assert_eq "opt-out: .pre-commit-config.yaml absent under --opt-precommit=no" \
        "absent" "$precommit_status"
}
test_setup_opt_out_skips_ci_and_precommit

test_setup_opt_out_skips_claude_md() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" \
        --opt-claude-md=no >/dev/null 2>&1 || true

    local claude_md_status="present"
    [[ ! -f "$T/.claude/CLAUDE.md" ]] && claude_md_status="absent"
    assert_eq "opt-out: CLAUDE.md absent under --opt-claude-md=no" \
        "absent" "$claude_md_status"
}
test_setup_opt_out_skips_claude_md

test_setup_opt_out_skips_known_issues() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" \
        --opt-known-issues=no >/dev/null 2>&1 || true

    local known_issues_status="present"
    [[ ! -f "$T/.claude/docs/KNOWN-ISSUES.md" ]] && known_issues_status="absent"
    assert_eq "opt-out: KNOWN-ISSUES.md absent under --opt-known-issues=no" \
        "absent" "$known_issues_status"
}
test_setup_opt_out_skips_known_issues

# Default behavior (no opt-out flags) installs all artifacts — confirms the
# new flags don't regress callers that don't pass them.
test_setup_default_installs_all_artifacts() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    _seed_python_poetry_stack "$T"  # bug 5d92 defect B: explicit stack required for ci.yml install

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    local ci_status="absent" precommit_status="absent" claude_md_status="absent" known_issues_status="absent"
    [[ -f "$T/.github/workflows/ci.yml" ]] && ci_status="present"
    [[ -f "$T/.pre-commit-config.yaml" ]] && precommit_status="present"
    [[ -f "$T/.claude/CLAUDE.md" ]] && claude_md_status="present"
    [[ -f "$T/.claude/docs/KNOWN-ISSUES.md" ]] && known_issues_status="present"

    assert_eq "default install: ci.yml present" "present" "$ci_status"
    assert_eq "default install: .pre-commit-config.yaml present" "present" "$precommit_status"
    assert_eq "default install: CLAUDE.md present" "present" "$claude_md_status"
    assert_eq "default install: KNOWN-ISSUES.md present" "present" "$known_issues_status"
}
test_setup_default_installs_all_artifacts

# ── test_plugin_version_awk_fallback_extracts_version ─────────────────────────
# Bug 5d92 (Defect G, L138): plugin version was read via `python3 -c`. On hosts
# without python3, stamps silently became "unknown". The fix prefers jq, falls
# back to python3, then to awk — so the version always resolves when plugin.json
# exists, regardless of installed interpreters.
#
# Unit test: verify the awk fallback command extracts the version correctly
# from a representative plugin.json. (Integration with the full script is
# covered by existing artifact-installation tests.)
test_plugin_version_awk_fallback_extracts_version() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    local fixture="$T/plugin.json"
    cat > "$fixture" <<'EOF'
{
  "name": "dso-test",
  "version": "9.9.99-test",
  "description": "fixture for awk fallback test"
}
EOF

    # This is the exact awk invocation used by dso-setup.sh when neither jq
    # nor python3 is available.
    local extracted
    extracted=$(awk -F'"' '/"version"/ {print $4; exit}' "$fixture")
    assert_eq "awk fallback extracts version from plugin.json" "9.9.99-test" "$extracted"
}
test_plugin_version_awk_fallback_extracts_version

# ── test_sed_stamp_escapes_metacharacters ─────────────────────────────────────
# Bug 5d92 (Defect G, L529): the sed fallback prepended `$stamp_line` unescaped
# into `1i\\\n$stamp_line`. If a stamp ever contained `/`, `&`, or `\`, sed
# would misinterpret. The fix escapes those metacharacters before substitution.
#
# This test invokes the helper directly with a synthetic stamp containing all
# three problem chars, asserting the file's first line is the literal stamp.
test_sed_stamp_escapes_metacharacters() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    local target="$T/test.yaml"
    printf 'existing: line\n' > "$target"

    # Apply the sed-fallback transformation the way dso-setup.sh's prepend block
    # does (escape \, /, & before substitution).
    local stamp_line='x-dso-version: 1.0/foo&bar'
    local _escaped_stamp
    _escaped_stamp=$(printf '%s' "$stamp_line" | sed 's/[\\/&]/\\&/g')
    sed -i.bak "1i\\
$_escaped_stamp" "$target" && rm -f "$target.bak"

    local first_line
    first_line=$(head -1 "$target")
    assert_eq "sed escape preserves slash and ampersand in stamp" "x-dso-version: 1.0/foo&bar" "$first_line"
}
test_sed_stamp_escapes_metacharacters

# ── test_unknown_stack_skips_ci_workflow_install ──────────────────────────────
# Bug 5d92 (Defect B): when stack was unknown AND skeleton generation failed,
# dso-setup.sh fell back to ci.example.python-poetry.yml, installing a
# Python/Poetry GitHub Actions workflow into non-Python projects. The fix
# returns empty from _resolve_stack_ci_example and the caller skips the
# install with a [skip] log line.
test_unknown_stack_skips_ci_workflow_install() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    # Pre-populate dso-config.conf with NO stack key and NO commands.* keys
    # so that (a) stack lookup returns empty and (b) skeleton generation has
    # no commands to derive from, forcing the resolver to return empty.
    mkdir -p "$T/.claude"
    cat > "$T/.claude/dso-config.conf" <<'EOF'
# Test fixture: no stack, no commands — should skip CI install entirely
EOF

    local output
    output=$(bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" 2>&1 || true)

    local ci_installed="absent" skip_logged="absent" is_python_poetry="no"
    if [[ -f "$T/.github/workflows/ci.yml" ]]; then
        ci_installed="present"
        if grep -q 'poetry' "$T/.github/workflows/ci.yml" 2>/dev/null; then
            is_python_poetry="yes"
        fi
    fi
    if echo "$output" | grep -q 'No CI example resolved for target stack'; then
        skip_logged="present"
    fi

    assert_eq "unknown stack: ci.yml NOT installed" "absent" "$ci_installed"
    assert_eq "unknown stack: skip reason logged" "present" "$skip_logged"
    assert_eq "unknown stack: no python-poetry workflow leaked" "no" "$is_python_poetry"
}
test_unknown_stack_skips_ci_workflow_install

# ── test_unknown_stack_uses_generic_precommit ─────────────────────────────────
# Bug 5d92 (Defect B): when stack was empty, the precommit resolver fell
# through to pre-commit-config.example.yaml (python-poetry legacy), installing
# Python tooling hooks into non-Python projects. The fix uses
# pre-commit-config.example.generic.yaml for any non-matched stack including
# empty/unknown.
test_unknown_stack_uses_generic_precommit() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    mkdir -p "$T/.claude"
    cat > "$T/.claude/dso-config.conf" <<'EOF'
# Test fixture: no stack — should use generic pre-commit template
EOF

    bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    local installed_status="absent" has_poetry_signature="no"
    if [[ -f "$T/.pre-commit-config.yaml" ]]; then
        installed_status="present"
        # python-poetry legacy template has unique hook IDs like
        # `poetry-lock-check`; the generic template does not. Match the
        # specific hook ID rather than the string "poetry" (which appears
        # in template docstrings cross-referencing the other variant).
        if grep -qE 'id:[[:space:]]*poetry-lock-check' "$T/.pre-commit-config.yaml" 2>/dev/null; then
            has_poetry_signature="yes"
        fi
    fi

    assert_eq "unknown stack: pre-commit config installed (generic)" "present" "$installed_status"
    assert_eq "unknown stack: no python-poetry hooks leaked into pre-commit" "no" "$has_poetry_signature"
}
test_unknown_stack_uses_generic_precommit

# ── test_validate_onboarding_enum_accepts_known_values ────────────────────────
# Bug 5d92 epic prep: _validate_onboarding_enum is the validator helper for
# the four onboarding.* enum config keys (hooks, ci, tracker, host) plus the
# two install/skip keys (claude_md, known_issues). The function is not called
# yet — the per-defect dispatchers in follow-up PRs will integrate it. Testing
# the validator in isolation lets reviewers audit the enum vocabulary without
# the noise of seven dispatcher changes.
test_validate_onboarding_enum_accepts_known_values() {
    # Source the helper from dso-setup.sh by extracting and eval'ing it.
    # We don't run the full script (which has top-level side effects).
    local helper_src
    helper_src=$(awk '/^_validate_onboarding_enum\(\) \{/,/^\}/' "$SETUP_SCRIPT")
    eval "$helper_src"

    # Spot-check one value per key — full enum coverage would be brittle.
    local rc
    _validate_onboarding_enum onboarding.hooks precommit; rc=$?
    assert_eq "validate enum: onboarding.hooks=precommit accepted" "0" "$rc"

    _validate_onboarding_enum onboarding.ci gitlab; rc=$?
    assert_eq "validate enum: onboarding.ci=gitlab accepted" "0" "$rc"

    _validate_onboarding_enum onboarding.tracker linear; rc=$?
    assert_eq "validate enum: onboarding.tracker=linear accepted" "0" "$rc"

    _validate_onboarding_enum onboarding.host github; rc=$?
    assert_eq "validate enum: onboarding.host=github accepted" "0" "$rc"

    _validate_onboarding_enum onboarding.claude_md install; rc=$?
    assert_eq "validate enum: onboarding.claude_md=install accepted" "0" "$rc"

    # All keys accept "skip"
    _validate_onboarding_enum onboarding.hooks skip; rc=$?
    assert_eq "validate enum: skip is accepted for hooks" "0" "$rc"
}
test_validate_onboarding_enum_accepts_known_values

# ── test_validate_onboarding_enum_rejects_unknown_values ──────────────────────
# Typo detection: dispatchers will treat invalid values as "skip" with a WARN.
# This test pins the rejection contract.
test_validate_onboarding_enum_rejects_unknown_values() {
    local helper_src
    helper_src=$(awk '/^_validate_onboarding_enum\(\) \{/,/^\}/' "$SETUP_SCRIPT")
    eval "$helper_src"

    local rc
    # Typo in enum value
    _validate_onboarding_enum onboarding.ci githhub; rc=$?
    assert_eq "validate enum: rejects typo (onboarding.ci=githhub)" "1" "$rc"

    # Valid value for wrong key
    _validate_onboarding_enum onboarding.hooks gitlab; rc=$?
    assert_eq "validate enum: rejects cross-key value" "1" "$rc"

    # Unknown key
    _validate_onboarding_enum onboarding.nonexistent skip; rc=$?
    assert_eq "validate enum: rejects unknown key" "1" "$rc"

    # Empty value
    _validate_onboarding_enum onboarding.hooks ""; rc=$?
    assert_eq "validate enum: rejects empty value" "1" "$rc"
}
test_validate_onboarding_enum_rejects_unknown_values

# ── test_gitlab_ci_template_exists_and_has_stamp ──────────────────────────────
# Bug 5d92 defect-C prep: the GitLab CI template ships in this PR as data
# only — no dso-setup.sh code path consumes it yet. Verify the file exists at
# the expected location and carries an x-dso-version stamp so the
# update-shim flow can detect drift when the defect-C dispatcher lands.
test_gitlab_ci_template_exists_and_has_stamp() {
    local template="$DSO_PLUGIN_DIR/docs/examples/ci.example.gitlab.yml"

    local exists_status="missing" stamp_status="missing" has_gitlab_marker="missing"
    if [[ -f "$template" ]]; then
        exists_status="present"
        if grep -q '^# x-dso-version:' "$template" 2>/dev/null; then
            stamp_status="present"
        fi
        # Distinguishing GitLab marker: top-level `stages:` key. GitHub Actions
        # uses `jobs:`; GitLab uses `stages:` + per-job `stage:`.
        if grep -qE '^stages:' "$template" 2>/dev/null; then
            has_gitlab_marker="present"
        fi
    fi

    assert_eq "ci.example.gitlab.yml: exists" "present" "$exists_status"
    assert_eq "ci.example.gitlab.yml: x-dso-version stamp present" "present" "$stamp_status"
    assert_eq "ci.example.gitlab.yml: GitLab-format marker (stages:) present" "present" "$has_gitlab_marker"
}
test_gitlab_ci_template_exists_and_has_stamp

print_summary
