#!/usr/bin/env bash
# tests/hooks/test-check-plugin-boundary.sh
# Tests for plugins/dso/hooks/pre-commit/check-plugin-boundary.sh
#
# Verifies all 8 done definitions from story c73a-1918:
#   1. Hook file exists and is executable
#   2. Allowlist config file exists
#   3. Allowlist config contains a comment block explaining how to add permitted paths
#   4. Hook exits 0 against current post-S1 plugins/dso/ dir (no violations)
#   5. Hook exits non-zero for a staged file at plugins/dso/docs/designs/test.md
#      AND output contains "plugin-boundary-allowlist.conf"
#   6. Hook exits 0 (fail-open) when the allowlist file is missing
#   7. .pre-commit-config.yaml contains an entry referencing "check-plugin-boundary"
#   8. This test file itself is executable
#
# NOTE: Assertions 1, 2, 4, 5, 6, 7 will be RED until the hook is created.
#
# Design note (staged-file simulation):
#   The hook reads staged additions via `git diff --cached --name-only --diff-filter=A`.
#   Tests create a temp git repo, stage files there, then invoke the hook with
#   GIT_DIR pointed at that repo so the hook sees the simulated staged files.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git -C "$PLUGIN_ROOT" rev-parse --show-toplevel)"

HOOK="$DSO_PLUGIN_DIR/hooks/pre-commit/check-plugin-boundary.sh"
ALLOWLIST="$DSO_PLUGIN_DIR/hooks/pre-commit/plugin-boundary-allowlist.conf"
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
# Creates a minimal git repo with one initial commit.
# Returns the repo directory path on stdout.
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

# ── Helper: run the hook from within a temp git repo ─────────────────────────
# Stages the given file path (relative to test repo) and invokes the hook.
# Returns both exit code and combined stdout+stderr.
# Usage:
#   output=$(run_hook_with_staged_file <test_repo> <relative_staged_path> [<allowlist_override>])
#   hook_exit=$?
#
# If <allowlist_override> is provided, it sets PLUGIN_BOUNDARY_ALLOWLIST env var
# so the hook uses that path instead of the default.
run_hook_with_staged_file() {
    local repo_dir="$1"
    local staged_rel_path="$2"
    local allowlist_override="${3:-}"

    local exit_code=0
    (
        cd "$repo_dir"
        # Create the file so we can stage it
        mkdir -p "$(dirname "$staged_rel_path")"
        echo "test content" > "$staged_rel_path"
        git add "$staged_rel_path" 2>/dev/null

        if [[ -n "$allowlist_override" ]]; then
            export PLUGIN_BOUNDARY_ALLOWLIST="$allowlist_override"
        fi
        bash "$HOOK" 2>&1
    ) || exit_code=$?
    return "$exit_code"
}

# ── Helper: run the hook with no staged files ─────────────────────────────────
run_hook_no_staged_files() {
    local repo_dir="$1"
    local allowlist_override="${2:-}"

    local exit_code=0
    (
        cd "$repo_dir"
        if [[ -n "$allowlist_override" ]]; then
            export PLUGIN_BOUNDARY_ALLOWLIST="$allowlist_override"
        fi
        bash "$HOOK" 2>&1
    ) || exit_code=$?
    return "$exit_code"
}

# ── Assertion 1: Hook file exists and is executable ───────────────────────────
test_hook_file_exists_and_is_executable() {
    if [[ -f "$HOOK" ]]; then
        (( ++PASS ))
        echo "PASS: hook file exists at $HOOK"
    else
        (( ++FAIL ))
        printf "FAIL: hook file not found at %s\n" "$HOOK" >&2
    fi

    if [[ -x "$HOOK" ]]; then
        (( ++PASS ))
        echo "PASS: hook file is executable"
    else
        (( ++FAIL ))
        printf "FAIL: hook file is not executable: %s\n" "$HOOK" >&2
    fi
}

# ── Assertion 2: Allowlist config file exists ─────────────────────────────────
test_allowlist_file_exists() {
    if [[ -f "$ALLOWLIST" ]]; then
        (( ++PASS ))
        echo "PASS: allowlist file exists at $ALLOWLIST"
    else
        (( ++FAIL ))
        printf "FAIL: allowlist file not found at %s\n" "$ALLOWLIST" >&2
    fi
}

# ── Assertion 3: Allowlist conf contains a comment block explaining permitted paths ──
test_allowlist_contains_comment_block() {
    if [[ ! -f "$ALLOWLIST" ]]; then
        (( ++FAIL ))
        printf "FAIL: cannot test allowlist comment block — file missing: %s\n" "$ALLOWLIST" >&2
        return
    fi

    # The comment block must explain how to add new permitted paths.
    # We look for '#' lines that mention adding/permitted/paths (case-insensitive).
    local found_comment=0
    while IFS= read -r line; do
        if [[ "$line" == \#* ]]; then
            lower="${line,,}"
            if [[ "$lower" == *"add"* ]] || [[ "$lower" == *"permit"* ]] || [[ "$lower" == *"allow"* ]]; then
                found_comment=1
                break
            fi
        fi
    done < "$ALLOWLIST"

    if [[ "$found_comment" -eq 1 ]]; then
        (( ++PASS ))
        echo "PASS: allowlist contains comment block explaining how to add permitted paths"
    else
        (( ++FAIL ))
        printf "FAIL: allowlist does not contain a comment block explaining how to add permitted paths\n" >&2
    fi
}

# ── Assertion 4: Hook exits 0 for current plugins/dso/ (no violations) ────────
# Simulates staging existing allowed files within plugins/dso/
test_hook_exits_0_for_allowed_content() {
    if [[ ! -f "$HOOK" ]]; then
        (( ++FAIL ))
        printf "FAIL: cannot test exit 0 — hook missing: %s\n" "$HOOK" >&2
        return
    fi

    # Stage a file that should be permitted — a shell script in plugins/dso/scripts/
    local test_repo
    test_repo=$(make_test_repo)

    local exit_code=0
    local output
    output=$(
        cd "$test_repo"
        mkdir -p "plugins/dso/scripts"
        echo "#!/usr/bin/env bash" > "plugins/dso/scripts/example-tool.sh"
        git add "plugins/dso/scripts/example-tool.sh" 2>/dev/null
        bash "$HOOK" 2>&1
    ) || exit_code=$?

    assert_eq "hook exits 0 for permitted staged file" "0" "$exit_code"
}

# ── Assertion 5: Hook exits non-zero for plugins/dso/docs/designs/test.md ─────
# AND output contains "plugin-boundary-allowlist.conf"
test_hook_blocks_unpermitted_path_and_names_allowlist() {
    if [[ ! -f "$HOOK" ]]; then
        (( ++FAIL ))
        printf "FAIL: cannot test violation detection — hook missing: %s\n" "$HOOK" >&2
        return
    fi

    local test_repo
    test_repo=$(make_test_repo)

    local exit_code=0
    local output
    output=$(
        cd "$test_repo"
        mkdir -p "plugins/dso/docs/designs"
        echo "# Test design doc" > "plugins/dso/docs/designs/test.md"
        git add "plugins/dso/docs/designs/test.md" 2>/dev/null
        bash "$HOOK" 2>&1
    ) || exit_code=$?

    assert_ne "hook exits non-zero for plugins/dso/docs/designs/test.md" "0" "$exit_code"
    assert_contains "hook output names plugin-boundary-allowlist.conf" \
        "plugin-boundary-allowlist.conf" "$output"
}

# ── Assertion 6: Hook exits 0 (fail-open) when allowlist file is missing ──────
test_hook_fails_open_when_allowlist_missing() {
    if [[ ! -f "$HOOK" ]]; then
        (( ++FAIL ))
        printf "FAIL: cannot test fail-open — hook missing: %s\n" "$HOOK" >&2
        return
    fi

    local test_repo
    test_repo=$(make_test_repo)

    # Create a nonexistent allowlist path to simulate missing conf
    local missing_allowlist
    missing_allowlist=$(mktemp -d)
    _TEST_TMPDIRS+=("$missing_allowlist")
    missing_allowlist="$missing_allowlist/does-not-exist.conf"

    local exit_code=0
    (
        cd "$test_repo"
        mkdir -p "plugins/dso/docs/designs"
        echo "# Test design doc" > "plugins/dso/docs/designs/test.md"
        git add "plugins/dso/docs/designs/test.md" 2>/dev/null
        export PLUGIN_BOUNDARY_ALLOWLIST="$missing_allowlist"
        bash "$HOOK" 2>&1
    ) || exit_code=$?

    assert_eq "hook exits 0 (fail-open) when allowlist is missing" "0" "$exit_code"
}

# ── Assertion 7: .pre-commit-config.yaml references check-plugin-boundary ─────
test_pre_commit_config_references_hook() {
    if [[ ! -f "$PRE_COMMIT_CONFIG" ]]; then
        (( ++FAIL ))
        printf "FAIL: .pre-commit-config.yaml not found at %s\n" "$PRE_COMMIT_CONFIG" >&2
        return
    fi

    local found=0
    while IFS= read -r line; do
        if [[ "$line" == *"check-plugin-boundary"* ]]; then
            found=1
            break
        fi
    done < "$PRE_COMMIT_CONFIG"

    if [[ "$found" -eq 1 ]]; then
        (( ++PASS ))
        echo "PASS: .pre-commit-config.yaml contains entry referencing check-plugin-boundary"
    else
        (( ++FAIL ))
        printf "FAIL: .pre-commit-config.yaml does not reference check-plugin-boundary\n" >&2
    fi
}

# ── Assertion 8: This test file itself is executable ─────────────────────────
test_this_file_is_executable() {
    local this_file="${BASH_SOURCE[0]}"
    if [[ -x "$this_file" ]]; then
        (( ++PASS ))
        echo "PASS: test file is executable: $this_file"
    else
        (( ++FAIL ))
        printf "FAIL: test file is not executable: %s\n" "$this_file" >&2
    fi
}

# ── Run all assertions ────────────────────────────────────────────────────────
echo "=== test-check-plugin-boundary ==="
echo ""

echo "--- Assertion 1: Hook file exists and is executable ---"
test_hook_file_exists_and_is_executable
echo ""

echo "--- Assertion 2: Allowlist config file exists ---"
test_allowlist_file_exists
echo ""

echo "--- Assertion 3: Allowlist contains comment block ---"
test_allowlist_contains_comment_block
echo ""

echo "--- Assertion 4: Hook exits 0 for permitted content ---"
test_hook_exits_0_for_allowed_content
echo ""

echo "--- Assertion 5: Hook blocks violations and names allowlist ---"
test_hook_blocks_unpermitted_path_and_names_allowlist
echo ""

echo "--- Assertion 6: Hook fails-open when allowlist missing ---"
test_hook_fails_open_when_allowlist_missing
echo ""

echo "--- Assertion 7: .pre-commit-config.yaml references hook ---"
test_pre_commit_config_references_hook
echo ""

echo "--- Assertion 8: This test file is executable ---"
test_this_file_is_executable
echo ""

print_summary
