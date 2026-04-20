#!/usr/bin/env bash
# tests/scripts/test-dso-setup-stack-aware-ci.sh
# RED-phase tests for bug c023-5e98:
#   dso-setup.sh's merge_ci_workflow blindly merges the Python/DSO-team-specific
#   ci.example.yml into any target project's ci.yml, including NextJS (node-npm)
#   projects that have no Python tooling — causing Python-specific jobs to leak in.
#
# These tests FAIL against the current dso-setup.sh (before the fix) because
# dso-setup.sh does not read stack= from DSO_DETECT_OUTPUT and always uses
# ci.example.yml (the Python/Poetry template) regardless of project stack.
#
# Usage:
#   bash tests/scripts/test-dso-setup-stack-aware-ci.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SETUP_SCRIPT="$DSO_PLUGIN_DIR/scripts/dso-setup.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

TMPDIRS=()
trap 'rm -rf "${TMPDIRS[@]}"' EXIT

# ── Performance: stub out pre-commit (same pattern as test-dso-setup.sh) ────
_STUB_BIN=$(mktemp -d)
TMPDIRS+=("$_STUB_BIN")
printf '#!/bin/sh\nexit 0\n' > "$_STUB_BIN/pre-commit"
chmod +x "$_STUB_BIN/pre-commit"
export PATH="$_STUB_BIN:$PATH"

echo "=== test-dso-setup-stack-aware-ci.sh ==="

# ── _make_nextjs_fixture: create a minimal NextJS project fixture ─────────────
# Sets up a git repo with:
#   - .claude/dso-config.conf containing stack=node-npm and commands.*
#   - .github/workflows/ci.yml with 3 NextJS jobs (fast-gate/tests/build)
#   - No Python files, no poetry.lock, no app/
# Prints the fixture directory path.
_make_nextjs_fixture() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    # Write dso-config.conf with node-npm stack
    mkdir -p "$T/.claude"
    cat > "$T/.claude/dso-config.conf" << 'EOF'
stack=node-npm
commands.test=npm test
commands.lint=npm run lint
commands.format_check=npm run format:check
EOF

    # Write a minimal NextJS CI workflow (fast-gate/tests/build)
    mkdir -p "$T/.github/workflows"
    cat > "$T/.github/workflows/ci.yml" << 'EOF'
name: CI
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
jobs:
  fast-gate:
    name: Fast Gate
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
      - run: npm ci
      - run: npm run lint
      - run: npm run format:check
  tests:
    name: Tests
    runs-on: ubuntu-latest
    needs: [fast-gate]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
      - run: npm ci
      - run: npm test
  build:
    name: Build
    runs-on: ubuntu-latest
    needs: [fast-gate]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
      - run: npm ci
      - run: npm run build
EOF

    echo "$T"
}

# ── _make_detect_output: write a DSO_DETECT_OUTPUT file with node-npm stack ──
# Writes stack=node-npm and ci_workflow_* guard lines to a temp file.
# Prints the file path.
_make_detect_output() {
    local detect_file
    detect_file=$(mktemp)
    TMPDIRS+=("$detect_file")
    cat > "$detect_file" << 'EOF'
stack=node-npm
ci_workflow_lint_guarded=true
ci_workflow_test_guarded=true
ci_workflow_format_guarded=true
EOF
    echo "$detect_file"
}

# ── test_node_npm_ci_does_not_get_python_jobs ─────────────────────────────────
# When dso-setup.sh is run against a node-npm project (stack=node-npm in
# DSO_DETECT_OUTPUT), the resulting ci.yml must NOT contain Python-specific
# job names that come from ci.example.yml (the Python/Poetry template).
#
# RED ASSERTION: This test FAILS before the fix because dso-setup.sh always
# merges ci.example.yml regardless of stack, injecting mypy, test-unit-agents,
# coverage-check, test-integration-hermetic, and persistence-check jobs.
test_node_npm_ci_does_not_get_python_jobs() {
    local T detect_file
    T=$(_make_nextjs_fixture)
    detect_file=$(_make_detect_output)

    DSO_DETECT_OUTPUT="$detect_file" \
        bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    local ci_file="$T/.github/workflows/ci.yml"

    # --- Python job assertions (must ALL be absent after a correct fix) ---
    local python_jobs=(
        "mypy:"
        "test-unit-agents:"
        "test-unit-services:"
        "test-unit-api:"
        "test-unit-core:"
        "coverage-check:"
        "test-integration-hermetic:"
        "test-integration-external:"
        "persistence-check:"
    )

    local failed_job=""
    for job in "${python_jobs[@]}"; do
        if grep -q "$job" "$ci_file" 2>/dev/null; then
            failed_job="$job"
            break
        fi
    done

    if [[ -n "$failed_job" ]]; then
        assert_eq "test_node_npm_ci_does_not_get_python_jobs: Python job leaked into node-npm CI" \
            "absent" "present: $failed_job"
    else
        assert_eq "test_node_npm_ci_does_not_get_python_jobs: no Python jobs present" \
            "absent" "absent"
    fi
}

# ── test_node_npm_ci_preserves_nextjs_jobs ────────────────────────────────────
# The original NextJS jobs (fast-gate, tests, build) must still be present in
# ci.yml after dso-setup.sh runs — the merge must not destroy the host content.
#
# This assertion is GREEN-compatible (the current code preserves existing jobs
# during merge), but it is included to protect against regressions in the fix.
test_node_npm_ci_preserves_nextjs_jobs() {
    local T detect_file
    T=$(_make_nextjs_fixture)
    detect_file=$(_make_detect_output)

    DSO_DETECT_OUTPUT="$detect_file" \
        bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    local ci_file="$T/.github/workflows/ci.yml"

    # fast-gate must still be present
    if grep -q 'fast-gate:' "$ci_file" 2>/dev/null; then
        assert_eq "test_node_npm_ci_preserves_nextjs_jobs: fast-gate present" "found" "found"
    else
        assert_eq "test_node_npm_ci_preserves_nextjs_jobs: fast-gate present" "found" "missing"
    fi

    # tests must still be present
    if grep -q 'tests:' "$ci_file" 2>/dev/null; then
        assert_eq "test_node_npm_ci_preserves_nextjs_jobs: tests present" "found" "found"
    else
        assert_eq "test_node_npm_ci_preserves_nextjs_jobs: tests present" "found" "missing"
    fi

    # build must still be present
    if grep -q 'build:' "$ci_file" 2>/dev/null; then
        assert_eq "test_node_npm_ci_preserves_nextjs_jobs: build present" "found" "found"
    else
        assert_eq "test_node_npm_ci_preserves_nextjs_jobs: build present" "found" "missing"
    fi
}

# ── test_node_npm_ci_no_python_toolchain_refs ─────────────────────────────────
# The resulting ci.yml must NOT contain references to Python toolchain
# artifacts: poetry.lock, pyproject.toml, mypy, or bandit.
#
# RED ASSERTION: This test FAILS before the fix because ci.example.yml
# contains hashFiles('app/poetry.lock'), pyproject.toml, make lint-mypy, and
# bandit invocations that get merged into the node-npm project's ci.yml.
test_node_npm_ci_no_python_toolchain_refs() {
    local T detect_file
    T=$(_make_nextjs_fixture)
    detect_file=$(_make_detect_output)

    DSO_DETECT_OUTPUT="$detect_file" \
        bash "$SETUP_SCRIPT" "$T" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    local ci_file="$T/.github/workflows/ci.yml"

    # poetry.lock must not appear
    if grep -q 'poetry\.lock' "$ci_file" 2>/dev/null; then
        assert_eq "test_node_npm_ci_no_python_toolchain_refs: poetry.lock absent" "absent" "present"
    else
        assert_eq "test_node_npm_ci_no_python_toolchain_refs: poetry.lock absent" "absent" "absent"
    fi

    # pyproject.toml must not appear
    if grep -q 'pyproject\.toml' "$ci_file" 2>/dev/null; then
        assert_eq "test_node_npm_ci_no_python_toolchain_refs: pyproject.toml absent" "absent" "present"
    else
        assert_eq "test_node_npm_ci_no_python_toolchain_refs: pyproject.toml absent" "absent" "absent"
    fi

    # mypy must not appear
    if grep -q 'mypy' "$ci_file" 2>/dev/null; then
        assert_eq "test_node_npm_ci_no_python_toolchain_refs: mypy absent" "absent" "present"
    else
        assert_eq "test_node_npm_ci_no_python_toolchain_refs: mypy absent" "absent" "absent"
    fi

    # bandit must not appear
    if grep -q 'bandit' "$ci_file" 2>/dev/null; then
        assert_eq "test_node_npm_ci_no_python_toolchain_refs: bandit absent" "absent" "present"
    else
        assert_eq "test_node_npm_ci_no_python_toolchain_refs: bandit absent" "absent" "absent"
    fi
}

# ── test_fresh_install_uses_stack_matched_example ────────────────────────────
# When no existing workflow file is present (fresh install), dso-setup.sh copies
# the stack-matched example. For a node-npm fixture, the resulting ci.yml must
# be the NextJS example — not the Python/Poetry one.
test_fresh_install_uses_stack_matched_example() {
    local fixture ci_file detect_file
    fixture=$(_make_nextjs_fixture)
    # Remove the existing ci.yml so dso-setup takes the "no workflow" branch (cp)
    rm -f "$fixture/.github/workflows/ci.yml"
    detect_file=$(_make_detect_output)

    DSO_DETECT_OUTPUT="$detect_file" bash "$SETUP_SCRIPT" "$fixture" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    ci_file="$fixture/.github/workflows/ci.yml"
    local ci_exists="no"
    [[ -f "$ci_file" ]] && ci_exists="yes"
    assert_eq "fresh install: ci.yml created" "yes" "$ci_exists"

    # Verify it's the node-npm example (contains NextJS-specific idioms) and not
    # the Python example (bandit / pyproject.toml).
    local has_tsc="no"
    grep -q 'tsc' "$ci_file" 2>/dev/null && has_tsc="yes"
    assert_eq "fresh install: node-npm example used (tsc present)" "yes" "$has_tsc"

    local has_bandit="no"
    grep -q 'bandit' "$ci_file" 2>/dev/null && has_bandit="yes"
    assert_eq "fresh install: python example NOT used (bandit absent)" "no" "$has_bandit"
}

# ── test_unknown_stack_generates_skeleton ────────────────────────────────────
# When no ci.example.${stack}.yml exists for the detected stack, _resolve_stack_ci_example
# falls through to _generate_ci_skeleton_from_config, which writes a minimal CI
# from commands.{test,lint,format_check} in dso-config.conf. Verify:
#   - skeleton file is produced (deterministic path under target_repo)
#   - output contains the commands declared in dso-config.conf
#   - skeleton is cleaned up after dso-setup.sh completes
test_unknown_stack_generates_skeleton() {
    local fixture detect_file
    fixture=$(_make_nextjs_fixture)

    # Override stack to something with no matching ci.example.*.yml
    printf 'stack=made-up-stack\n' > "$fixture/.claude/dso-config.conf.tmp"
    grep -v '^stack=' "$fixture/.claude/dso-config.conf" >> "$fixture/.claude/dso-config.conf.tmp"
    mv "$fixture/.claude/dso-config.conf.tmp" "$fixture/.claude/dso-config.conf"

    # Remove the existing ci.yml so the branch that cp's the resolved example fires
    rm -f "$fixture/.github/workflows/ci.yml"

    detect_file=$(mktemp)
    TMPDIRS+=("$detect_file")
    printf 'stack=made-up-stack\nstack_confidence=confirmed\nci_workflow_names=\nci_workflow_test_guarded=false\nci_workflow_lint_guarded=false\nci_workflow_format_guarded=false\n' > "$detect_file"

    DSO_DETECT_OUTPUT="$detect_file" bash "$SETUP_SCRIPT" "$fixture" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

    local ci_file="$fixture/.github/workflows/ci.yml"
    local ci_exists="no"
    [[ -f "$ci_file" ]] && ci_exists="yes"
    assert_eq "unknown stack: ci.yml produced from skeleton" "yes" "$ci_exists"

    # The skeleton should embed the commands from dso-config.conf
    local has_test_cmd="no"
    grep -q 'npm test' "$ci_file" 2>/dev/null && has_test_cmd="yes"
    assert_eq "unknown stack: skeleton contains commands.test" "yes" "$has_test_cmd"

    # Skeleton sentinel should have been cleaned up after dso-setup
    local sentinel_gone="yes"
    [[ -f "$fixture/.dso-ci-skeleton.tmp" ]] && sentinel_gone="no"
    assert_eq "unknown stack: skeleton sentinel cleaned up" "yes" "$sentinel_gone"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
# IMPORTANT: GREEN-path tests must run BEFORE the RED marker
# (test_node_npm_ci_does_not_get_python_jobs in .test-index).
test_fresh_install_uses_stack_matched_example
test_unknown_stack_generates_skeleton
test_node_npm_ci_does_not_get_python_jobs
test_node_npm_ci_preserves_nextjs_jobs
test_node_npm_ci_no_python_toolchain_refs

print_summary
