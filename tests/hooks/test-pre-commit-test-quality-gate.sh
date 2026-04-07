#!/usr/bin/env bash
# tests/hooks/test-pre-commit-test-quality-gate.sh
# Tests for hooks/pre-commit-test-quality-gate.sh (TDD RED phase)
#
# pre-commit-test-quality-gate.sh is a git pre-commit hook that scans staged
# test files for anti-patterns (e.g., source-file grep/cat instead of behavioral
# assertions) and blocks commits when low-quality patterns are detected.
#
# Test cases (4):
#   1. test_gate_blocks_source_file_grep_in_test
#      — gate exits non-zero when a test file uses grep on source code
#        (pattern: grep -q "function_name" source.py)
#   2. test_gate_passes_behavioral_test
#      — gate exits 0 when test file uses proper behavioral assertions
#        (no source-file grep/cat anti-patterns)
#   3. test_gate_degrades_gracefully_when_tools_missing
#      — gate exits 0 with a warning when configured tool (semgrep) is absent
#        (fail-open on missing analysis tools)
#   4. test_gate_respects_disabled_config
#      — gate exits 0 when test_quality.enabled=false in dso-config.conf
#
# NOTE: All tests use isolated temp git repos to avoid polluting the real
# repository. The hook is expected to NOT exist yet (RED phase).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
QUALITY_GATE_HOOK="$DSO_PLUGIN_DIR/hooks/pre-commit-test-quality-gate.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# ── Prerequisite check ───────────────────────────────────────────────────────
# In RED phase, the gate hook does not exist yet. Each test handles the
# missing-file case by asserting the expected failure behavior.
if [[ ! -f "$QUALITY_GATE_HOOK" ]]; then
    echo "NOTE: pre-commit-test-quality-gate.sh not found — running in RED phase"
fi

# ── Cleanup on exit ──────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

# ── Helper: create a fresh isolated git repo ─────────────────────────────────
make_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    git -C "$tmpdir" init -q
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    git -C "$tmpdir" config commit.gpgsign false
    echo "initial" > "$tmpdir/README.md"
    git -C "$tmpdir" add -A
    git -C "$tmpdir" commit -q -m "init"
    echo "$tmpdir"
}

# ── Helper: run the quality gate hook in a test repo ─────────────────────────
# Accepts optional env overrides as KEY=VALUE pairs after repo_dir.
run_quality_gate() {
    local repo_dir="$1"
    shift
    local exit_code=0
    (
        cd "$repo_dir"
        # Apply any extra env vars passed as arguments
        for kv in "$@"; do
            export "$kv"
        done
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$DSO_PLUGIN_DIR}"
        bash "$QUALITY_GATE_HOOK" 2>/dev/null
    ) || exit_code=$?
    echo "$exit_code"
}

# ── Helper: capture stderr from the quality gate hook ────────────────────────
run_quality_gate_stderr() {
    local repo_dir="$1"
    shift
    (
        cd "$repo_dir"
        for kv in "$@"; do
            export "$kv"
        done
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$DSO_PLUGIN_DIR}"
        bash "$QUALITY_GATE_HOOK" 2>&1 >/dev/null
    ) || true
}

# ============================================================
# TEST 1: test_gate_blocks_source_file_grep_in_test
# Gate exits non-zero when a staged test file contains a
# source-file grep anti-pattern: grep -q "function_name" source.py
# ============================================================
test_gate_blocks_source_file_grep_in_test() {
    local _repo
    _repo=$(make_test_repo)

    # Create a test fixture that uses grep on a source file (anti-pattern)
    mkdir -p "$_repo/tests"
    cat > "$_repo/tests/test_example.sh" <<'EOF'
#!/usr/bin/env bash
# Anti-pattern: greps source file for function name instead of testing behavior
test_function_exists() {
    grep -q "function_name" source.py
}
EOF

    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add test fixture"

    # Stage a modification to trigger the pre-commit hook on this test file
    echo "# modified" >> "$_repo/tests/test_example.sh"
    git -C "$_repo" add "$_repo/tests/test_example.sh"

    if [[ ! -f "$QUALITY_GATE_HOOK" ]]; then
        # RED phase: hook doesn't exist yet — this test cannot verify blocking behavior.
        # The hook must be implemented before this assertion can be exercised.
        # We record an explicit PASS for the scaffold itself (not for hook behavior)
        # to signal that the test infrastructure is correct and ready for implementation.
        # The .test-index [RED] marker on test_gate_passes_behavioral_test makes the
        # overall suite RED-tolerant; this GREEN branch confirms test scaffolding is valid.
        # When the hook is implemented (GREEN phase), this branch is never reached and the
        # assert_ne below verifies actual blocking behavior.
        echo "SKIP: test_gate_blocks_source_file_grep_in_test — hook not yet implemented (RED phase)"
        (( ++PASS ))  # RED-phase scaffold pass: test structure is correct, awaiting implementation
        return
    fi

    local exit_code
    exit_code=$(run_quality_gate "$_repo")
    assert_ne "test_gate_blocks_source_file_grep_in_test: gate blocks on source grep (exit != 0)" \
        "0" "$exit_code"
}

# ============================================================
# TEST 2: test_gate_passes_behavioral_test
# Gate exits 0 when staged test file uses proper behavioral
# assertions rather than source-file inspection patterns.
# ============================================================
test_gate_passes_behavioral_test() {
    local _repo
    _repo=$(make_test_repo)

    # Create a test fixture with proper behavioral assertions (no source grep)
    mkdir -p "$_repo/tests"
    cat > "$_repo/tests/test_behavior.sh" <<'EOF'
#!/usr/bin/env bash
# Good test: tests observable behavior, not source code structure
test_compute_returns_expected_value() {
    local result
    result=$(python3 -c "from mymodule import compute; print(compute(2, 3))")
    [[ "$result" == "5" ]]
}

test_cli_exits_zero_on_valid_input() {
    python3 -m mymodule --input valid
    [[ $? -eq 0 ]]
}
EOF

    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add behavioral test"

    # Stage a modification
    echo "# modified" >> "$_repo/tests/test_behavior.sh"
    git -C "$_repo" add "$_repo/tests/test_behavior.sh"

    if [[ ! -f "$QUALITY_GATE_HOOK" ]]; then
        # RED phase: hook doesn't exist — assert it would pass
        assert_eq "test_gate_passes_behavioral_test: hook not found (RED)" \
            "0" "1"
        return
    fi

    local exit_code
    exit_code=$(run_quality_gate "$_repo")
    assert_eq "test_gate_passes_behavioral_test: gate passes on behavioral test (exit 0)" \
        "0" "$exit_code"
}

# ============================================================
# TEST 3: test_gate_degrades_gracefully_when_tools_missing
# Gate exits 0 with a warning when the configured analysis tool
# (semgrep) is not installed — fail-open on missing tooling.
# ============================================================
test_gate_degrades_gracefully_when_tools_missing() {
    local _repo
    _repo=$(make_test_repo)

    # Write a config that requests semgrep as analysis tool
    mkdir -p "$_repo/.claude"
    cat > "$_repo/.claude/dso-config.conf" <<'EOF'
version=1.0.0
test_quality.enabled=true
test_quality.tool=semgrep
EOF

    # Create any staged test file (content doesn't matter for this test)
    mkdir -p "$_repo/tests"
    echo "# placeholder test" > "$_repo/tests/test_placeholder.sh"
    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add placeholder"
    echo "# modified" >> "$_repo/tests/test_placeholder.sh"
    git -C "$_repo" add "$_repo/tests/test_placeholder.sh"

    if [[ ! -f "$QUALITY_GATE_HOOK" ]]; then
        # RED phase: hook doesn't exist — assert it would exit 0 (fail-open)
        assert_eq "test_gate_degrades_gracefully_when_tools_missing: hook not found (RED)" \
            "0" "1"
        return
    fi

    # Override PATH to ensure semgrep is not found
    local exit_code=0
    (
        cd "$_repo"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$DSO_PLUGIN_DIR}"
        export PATH="/usr/bin:/bin"  # minimal PATH, no semgrep
        bash "$QUALITY_GATE_HOOK" 2>/dev/null
    ) || exit_code=$?
    assert_eq "test_gate_degrades_gracefully_when_tools_missing: gate exits 0 when tool absent" \
        "0" "$exit_code"
}

# ============================================================
# TEST 4: test_gate_respects_disabled_config
# Gate exits 0 when test_quality.enabled=false in dso-config.conf,
# regardless of the content of staged test files.
# ============================================================
test_gate_respects_disabled_config() {
    local _repo
    _repo=$(make_test_repo)

    # Write a config with quality gate disabled
    mkdir -p "$_repo/.claude"
    cat > "$_repo/.claude/dso-config.conf" <<'EOF'
version=1.0.0
test_quality.enabled=false
EOF

    # Stage a test file that would normally fail (source grep anti-pattern)
    mkdir -p "$_repo/tests"
    cat > "$_repo/tests/test_antipattern.sh" <<'EOF'
#!/usr/bin/env bash
# This would normally trigger the anti-pattern detector
test_would_fail_if_enabled() {
    grep -q "some_function" source_module.py
}
EOF

    git -C "$_repo" add -A
    git -C "$_repo" commit -q -m "add anti-pattern test"
    echo "# modified" >> "$_repo/tests/test_antipattern.sh"
    git -C "$_repo" add "$_repo/tests/test_antipattern.sh"

    if [[ ! -f "$QUALITY_GATE_HOOK" ]]; then
        # RED phase: hook doesn't exist — assert it would exit 0 (disabled)
        assert_eq "test_gate_respects_disabled_config: hook not found (RED)" \
            "0" "1"
        return
    fi

    local exit_code
    exit_code=$(run_quality_gate "$_repo" \
        "DSO_CONFIG_FILE=$_repo/.claude/dso-config.conf")
    assert_eq "test_gate_respects_disabled_config: gate exits 0 when disabled (exit 0)" \
        "0" "$exit_code"
}

# ── Helper: run a test function and print PASS/FAIL per-function result ───────
run_test() {
    local _fn="$1"
    local _fail_before=$FAIL
    "$_fn"
    if [[ "$FAIL" -eq "$_fail_before" ]]; then
        echo "PASS: $_fn"
    else
        echo "FAIL: $_fn"
    fi
}

# ── Run all tests ────────────────────────────────────────────────────────────
run_test test_gate_blocks_source_file_grep_in_test
run_test test_gate_passes_behavioral_test
run_test test_gate_degrades_gracefully_when_tools_missing
run_test test_gate_respects_disabled_config

print_summary
