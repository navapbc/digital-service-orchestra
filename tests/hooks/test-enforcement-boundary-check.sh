#!/usr/bin/env bash
# tests/hooks/test-enforcement-boundary-check.sh
# RED behavioral tests for plugins/dso/hooks/pre-commit-enforcement-boundary-check.sh
#
# The pre-commit check (to be created by task 1028-7439) blocks commits where a
# file marked with '# hook-boundary: enforcement' in its header also sources
# hook-error-handler.sh.  Enforcement hooks are intentionally strict / exit-non-zero
# and must NOT use the shared fail-open ERR handler.
#
# All tests are RED until pre-commit-enforcement-boundary-check.sh is created.
#
# Test strategy (staged-file simulation):
#   Create an isolated git repo per test, stage the appropriate file(s), then
#   invoke the check script with GIT_DIR set to that repo so it sees the simulated
#   staged files — same technique used in test-check-plugin-boundary.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git -C "$PLUGIN_ROOT" rev-parse --show-toplevel)"

CHECK_SCRIPT="$PLUGIN_ROOT/plugins/dso/hooks/pre-commit-enforcement-boundary-check.sh"
PRE_COMMIT_CONFIG="$REPO_ROOT/.pre-commit-config.yaml"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

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
    echo "initial" > "$tmpdir/README.md"
    git -C "$tmpdir" add README.md
    git -C "$tmpdir" commit -q -m "init"
    echo "$tmpdir"
}

# ── Test 1: check script exists and is executable ────────────────────────────
test_enforcement_boundary_script_exists_and_executable() {
    if [[ -f "$CHECK_SCRIPT" ]]; then
        (( ++PASS ))
        echo "PASS: check script exists at $CHECK_SCRIPT"
    else
        (( ++FAIL ))
        printf "FAIL: check script not found at %s\n" "$CHECK_SCRIPT" >&2
    fi

    if [[ -x "$CHECK_SCRIPT" ]]; then
        (( ++PASS ))
        echo "PASS: check script is executable"
    else
        (( ++FAIL ))
        printf "FAIL: check script is not executable: %s\n" "$CHECK_SCRIPT" >&2
    fi
}

# ── Test 2: enforcement hook that sources handler is BLOCKED ─────────────────
# Stage a file with '# hook-boundary: enforcement' header AND a
# 'source hook-error-handler.sh' line — the check must exit non-zero.
test_enforcement_boundary_blocks_handler_source() {
    if [[ ! -f "$CHECK_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: cannot test blocking — check script missing: %s\n" "$CHECK_SCRIPT" >&2
        return
    fi

    local test_repo
    test_repo=$(make_test_repo)

    local exit_code=0
    local output
    output=$(
        cd "$test_repo"
        cat > "review-gate.sh" <<'EOF'
#!/usr/bin/env bash
# hook-boundary: enforcement
source hook-error-handler.sh
echo "do enforcement work"
EOF
        git add "review-gate.sh" 2>/dev/null
        GIT_DIR="$test_repo/.git" bash "$CHECK_SCRIPT" 2>&1
    ) || exit_code=$?

    assert_ne \
        "enforcement hook sourcing hook-error-handler.sh is blocked (exit non-zero)" \
        "0" "$exit_code"
}

# ── Test 3: non-enforcement hook that sources handler is ALLOWED ─────────────
# A file WITHOUT the enforcement header that sources hook-error-handler.sh
# should pass (exit 0) — the check only applies to enforcement-boundary files.
test_enforcement_boundary_allows_non_enforcement_source() {
    if [[ ! -f "$CHECK_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: cannot test allow — check script missing: %s\n" "$CHECK_SCRIPT" >&2
        return
    fi

    local test_repo
    test_repo=$(make_test_repo)

    local exit_code=0
    local output
    output=$(
        cd "$test_repo"
        cat > "regular-hook.sh" <<'EOF'
#!/usr/bin/env bash
# This is a regular (fail-open) hook — no enforcement boundary header
source hook-error-handler.sh
echo "do regular work"
EOF
        git add "regular-hook.sh" 2>/dev/null
        GIT_DIR="$test_repo/.git" bash "$CHECK_SCRIPT" 2>&1
    ) || exit_code=$?

    assert_eq \
        "non-enforcement hook sourcing hook-error-handler.sh is allowed (exit 0)" \
        "0" "$exit_code"
}

# ── Test 4: enforcement header with no source line passes ────────────────────
# A file WITH the enforcement header but NOT sourcing hook-error-handler.sh
# must be allowed (exit 0).
test_enforcement_header_present_no_source_passes() {
    if [[ ! -f "$CHECK_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: cannot test pass — check script missing: %s\n" "$CHECK_SCRIPT" >&2
        return
    fi

    local test_repo
    test_repo=$(make_test_repo)

    local exit_code=0
    local output
    output=$(
        cd "$test_repo"
        cat > "pre-commit-test-gate.sh" <<'EOF'
#!/usr/bin/env bash
# hook-boundary: enforcement
# Uses its own strict ERR handling — does NOT source hook-error-handler.sh
set -euo pipefail
echo "do strict enforcement work"
EOF
        git add "pre-commit-test-gate.sh" 2>/dev/null
        GIT_DIR="$test_repo/.git" bash "$CHECK_SCRIPT" 2>&1
    ) || exit_code=$?

    assert_eq \
        "enforcement header with no handler source line passes (exit 0)" \
        "0" "$exit_code"
}

# ── Test 5: only the header+source combination blocks; each alone does not ───
# Verifies annotation-driven logic: the check is purely additive — both the
# header AND the source line must be present to trigger a block.
test_enforcement_boundary_annotation_driven_combination() {
    if [[ ! -f "$CHECK_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: cannot test combination logic — check script missing: %s\n" "$CHECK_SCRIPT" >&2
        return
    fi

    # File A: enforcement header, no source → should pass
    local repo_a
    repo_a=$(make_test_repo)

    local exit_a=0
    (
        cd "$repo_a"
        cat > "hook-a.sh" <<'EOF'
#!/usr/bin/env bash
# hook-boundary: enforcement
echo "enforcement, no handler"
EOF
        git add "hook-a.sh" 2>/dev/null
        GIT_DIR="$repo_a/.git" bash "$CHECK_SCRIPT" 2>&1
    ) || exit_a=$?

    assert_eq \
        "enforcement-only file (no source) passes" \
        "0" "$exit_a"

    # File B: source only, no enforcement header → should pass
    local repo_b
    repo_b=$(make_test_repo)

    local exit_b=0
    (
        cd "$repo_b"
        cat > "hook-b.sh" <<'EOF'
#!/usr/bin/env bash
source hook-error-handler.sh
echo "regular hook"
EOF
        git add "hook-b.sh" 2>/dev/null
        GIT_DIR="$repo_b/.git" bash "$CHECK_SCRIPT" 2>&1
    ) || exit_b=$?

    assert_eq \
        "source-only file (no enforcement header) passes" \
        "0" "$exit_b"

    # File C: both header and source → must block
    local repo_c
    repo_c=$(make_test_repo)

    local exit_c=0
    (
        cd "$repo_c"
        cat > "hook-c.sh" <<'EOF'
#!/usr/bin/env bash
# hook-boundary: enforcement
source hook-error-handler.sh
echo "bad combination"
EOF
        git add "hook-c.sh" 2>/dev/null
        GIT_DIR="$repo_c/.git" bash "$CHECK_SCRIPT" 2>&1
    ) || exit_c=$?

    assert_ne \
        "combined enforcement header + source line is blocked" \
        "0" "$exit_c"
}

# ── Test 6: blocked output names the offending file ─────────────────────────
# When the check blocks, its output (stdout or stderr) must identify which
# staged file caused the violation so the committer can act on it.
test_enforcement_boundary_output_names_violating_file() {
    if [[ ! -f "$CHECK_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: cannot test output — check script missing: %s\n" "$CHECK_SCRIPT" >&2
        return
    fi

    local test_repo
    test_repo=$(make_test_repo)

    local exit_code=0
    local output
    output=$(
        cd "$test_repo"
        cat > "my-enforcement-hook.sh" <<'EOF'
#!/usr/bin/env bash
# hook-boundary: enforcement
source hook-error-handler.sh
EOF
        git add "my-enforcement-hook.sh" 2>/dev/null
        GIT_DIR="$test_repo/.git" bash "$CHECK_SCRIPT" 2>&1
    ) || exit_code=$?

    assert_contains \
        "blocked output names the offending file" \
        "my-enforcement-hook.sh" "$output"
}

# ── Test 7: .pre-commit-config.yaml references enforcement-boundary check ────
# After task 1028-7439 the config YAML must include a hook entry for this check.
test_pre_commit_config_references_enforcement_boundary_check() {
    if [[ ! -f "$PRE_COMMIT_CONFIG" ]]; then
        (( ++FAIL ))
        printf "FAIL: .pre-commit-config.yaml not found at %s\n" "$PRE_COMMIT_CONFIG" >&2
        return
    fi

    local found=0
    while IFS= read -r line; do
        if [[ "$line" == *"enforcement-boundary"* ]]; then
            found=1
            break
        fi
    done < "$PRE_COMMIT_CONFIG"

    if [[ "$found" -eq 1 ]]; then
        (( ++PASS ))
        echo "PASS: .pre-commit-config.yaml references enforcement-boundary check"
    else
        (( ++FAIL ))
        printf "FAIL: .pre-commit-config.yaml does not reference enforcement-boundary check\n" >&2
    fi
}

# ── Run all tests ─────────────────────────────────────────────────────────────
echo "=== test-enforcement-boundary-check ==="
echo ""

echo "--- Test 1: check script exists and is executable ---"
test_enforcement_boundary_script_exists_and_executable
echo ""

echo "--- Test 2: enforcement hook sourcing handler is blocked ---"
test_enforcement_boundary_blocks_handler_source
echo ""

echo "--- Test 3: non-enforcement hook sourcing handler is allowed ---"
test_enforcement_boundary_allows_non_enforcement_source
echo ""

echo "--- Test 4: enforcement header with no source line passes ---"
test_enforcement_header_present_no_source_passes
echo ""

echo "--- Test 5: annotation-driven — only header+source combination blocks ---"
test_enforcement_boundary_annotation_driven_combination
echo ""

echo "--- Test 6: blocked output names the violating file ---"
test_enforcement_boundary_output_names_violating_file
echo ""

echo "--- Test 7: .pre-commit-config.yaml references enforcement-boundary check ---"
test_pre_commit_config_references_enforcement_boundary_check
echo ""

print_summary
