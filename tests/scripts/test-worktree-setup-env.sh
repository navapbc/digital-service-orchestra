#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-worktree-setup-env.sh
# Tests that worktree-setup-env.sh uses config-driven Python version discovery.
#
# Usage: bash lockpick-workflow/tests/scripts/test-worktree-setup-env.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-worktree-setup-env.sh ==="

SETUP_SCRIPT="$REPO_ROOT/scripts/worktree-setup-env.sh"

# ── test_python_version_config_driven ─────────────────────────────────────────
# Set WORKFLOW_CONFIG with worktree.python_version=3.11, mock try_find_python
# to return a path, verify the script uses that version.
_snapshot_fail

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Create a fake worktree structure
mkdir -p "$TMPDIR_TEST/worktree/app"
# Create a fake pyproject.toml so poetry commands can be recognized
touch "$TMPDIR_TEST/worktree/app/pyproject.toml"

# Create a config file with python_version
cat > "$TMPDIR_TEST/workflow-config.conf" <<'CONF'
version=1.0.0
worktree.python_version=3.11
CONF

# Create a mock script that replaces the real setup-env to test just the
# Python discovery logic. We extract and test the Python detection section.
# Strategy: source deps.sh (for try_find_python) and read-config.sh integration,
# then check that the script reads the config and attempts to find that version.

# We test by grepping the script source for the config-driven pattern
output=$(grep -c 'worktree\.python_version\|python_version' "$SETUP_SCRIPT" 2>/dev/null || echo "0")
assert_ne "test_python_version_config_driven: script references python_version config" "0" "$output"

# Now test the actual logic by creating a controlled environment
# Create a shim that pretends to be try_find_python
mkdir -p "$TMPDIR_TEST/bin"
cat > "$TMPDIR_TEST/bin/python3.11" <<'PYSHIM'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    echo "Python 3.11.0"
else
    echo "mock-python-3.11"
fi
PYSHIM
chmod +x "$TMPDIR_TEST/bin/python3.11"

# Create mock poetry
cat > "$TMPDIR_TEST/bin/poetry" <<'POETRYSHIM'
#!/bin/bash
echo "mock-poetry: $*" >&2
exit 0
POETRYSHIM
chmod +x "$TMPDIR_TEST/bin/poetry"

# Run the script with config pointing to python 3.11
# We need to override PATH so try_find_python finds our mock python
# and set WORKFLOW_CONFIG to our test config
exit_code=0
script_output=$(
    WORKTREE_PATH="$TMPDIR_TEST/worktree" \
    WORKFLOW_CONFIG="$TMPDIR_TEST/workflow-config.conf" \
    PATH="$TMPDIR_TEST/bin:$PATH" \
    bash "$SETUP_SCRIPT" 2>&1
) || exit_code=$?

# The script should have attempted to use python3.11 (from config),
# not hardcoded python3.13
assert_eq "test_python_version_config_driven: exit 0" "0" "$exit_code"
# Verify it did NOT try to use python3.13
if echo "$script_output" | grep -q 'python3\.13\|python@3\.13'; then
    (( ++FAIL ))
    echo "FAIL: test_python_version_config_driven: script used hardcoded python3.13" >&2
else
    (( ++PASS ))
fi

assert_pass_if_clean "test_python_version_config_driven"

# ── test_python_version_fallback_any_python3 ──────────────────────────────────
# No config set, verify script falls back to python3 on PATH.
_snapshot_fail

# Create a config WITHOUT python_version
cat > "$TMPDIR_TEST/workflow-config-noversion.conf" <<'CONF'
version=1.0.0
CONF

# Create mock python3 (generic, no version suffix)
cat > "$TMPDIR_TEST/bin/python3" <<'PYSHIM'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    echo "Python 3.12.0"
else
    echo "mock-python3"
fi
PYSHIM
chmod +x "$TMPDIR_TEST/bin/python3"

exit_code=0
script_output=$(
    WORKTREE_PATH="$TMPDIR_TEST/worktree" \
    WORKFLOW_CONFIG="$TMPDIR_TEST/workflow-config-noversion.conf" \
    PATH="$TMPDIR_TEST/bin:$PATH" \
    bash "$SETUP_SCRIPT" 2>&1
) || exit_code=$?

assert_eq "test_python_version_fallback_any_python3: exit 0" "0" "$exit_code"

assert_pass_if_clean "test_python_version_fallback_any_python3"

# ── test_python_version_no_python_errors ──────────────────────────────────────
# Neither config version nor python3 available, verify script exits with error.
_snapshot_fail

# Create an empty bin dir with only poetry and essential tools (no python at all)
TMPDIR_NOPY=$(mktemp -d)
mkdir -p "$TMPDIR_NOPY/bin"
cat > "$TMPDIR_NOPY/bin/poetry" <<'POETRYSHIM'
#!/bin/bash
echo "mock-poetry: $*" >&2
exit 0
POETRYSHIM
chmod +x "$TMPDIR_NOPY/bin/poetry"

# Create worktree dir
mkdir -p "$TMPDIR_NOPY/worktree/app"

# Build a PATH that has system tools but no python3
# Copy essential binaries (bash, grep, etc.) but NOT python
NOPY_BIN="$TMPDIR_NOPY/bin"
for tool in bash rm grep cut sed awk cat mkdir ls chmod dirname cd readlink uname; do
    tool_path=$(command -v "$tool" 2>/dev/null || true)
    if [[ -n "$tool_path" && -x "$tool_path" ]]; then
        ln -sf "$tool_path" "$NOPY_BIN/$tool" 2>/dev/null || true
    fi
done

exit_code=0
script_output=$(
    WORKTREE_PATH="$TMPDIR_NOPY/worktree" \
    WORKFLOW_CONFIG="$TMPDIR_TEST/workflow-config-noversion.conf" \
    PATH="$NOPY_BIN" \
    bash "$SETUP_SCRIPT" 2>&1
) || exit_code=$?

assert_ne "test_python_version_no_python_errors: exits non-zero" "0" "$exit_code"
# Should contain an error message about Python
assert_contains "test_python_version_no_python_errors: error message mentions Python" "ython" "$script_output"

rm -rf "$TMPDIR_NOPY"

assert_pass_if_clean "test_python_version_no_python_errors"

# ── test_no_hardcoded_python313 ───────────────────────────────────────────────
# Verify no hardcoded python3.13 or python@3.13 paths remain in the script.
_snapshot_fail

hardcoded_count=$(grep -cE 'python3\.13|python@3\.13' "$SETUP_SCRIPT" 2>/dev/null || true)
hardcoded_count="${hardcoded_count:-0}"
assert_eq "test_no_hardcoded_python313: no hardcoded python3.13 paths" "0" "$hardcoded_count"

assert_pass_if_clean "test_no_hardcoded_python313"

print_summary
