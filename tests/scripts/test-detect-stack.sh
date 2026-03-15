#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-detect-stack.sh
# TDD red-phase tests for lockpick-workflow/scripts/detect-stack.sh
#
# Usage: bash lockpick-workflow/tests/scripts/test-detect-stack.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# NOTE: These tests are expected to FAIL until detect-stack.sh is implemented.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/detect-stack.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-detect-stack.sh ==="

# Create a temp dir for fixture project directories used in tests
TMPDIR_FIXTURE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FIXTURE"' EXIT

# ── test_detect_stack_script_exists ───────────────────────────────────────────
# The script must exist at the expected path and be executable.
if [[ -f "$SCRIPT" ]]; then
    actual_exists="exists"
else
    actual_exists="missing"
fi
assert_eq "test_detect_stack_script_exists: file exists" "exists" "$actual_exists"

if [[ -x "$SCRIPT" ]]; then
    actual_exec="executable"
else
    actual_exec="not_executable"
fi
assert_eq "test_detect_stack_script_exists: file is executable" "executable" "$actual_exec"

# ── test_detect_stack_python_project ─────────────────────────────────────────
# A directory containing pyproject.toml must output 'python-poetry'.
PYTHON_DIR="$TMPDIR_FIXTURE/python_project"
mkdir -p "$PYTHON_DIR"
touch "$PYTHON_DIR/pyproject.toml"

python_output=""
python_exit=0
python_output=$(bash "$SCRIPT" "$PYTHON_DIR" 2>&1) || python_exit=$?
assert_eq "test_detect_stack_python_project: exit 0" "0" "$python_exit"
assert_eq "test_detect_stack_python_project: outputs python-poetry" "python-poetry" "$python_output"

# ── test_detect_stack_node_project ───────────────────────────────────────────
# A directory containing package.json must output 'node-npm'.
NODE_DIR="$TMPDIR_FIXTURE/node_project"
mkdir -p "$NODE_DIR"
touch "$NODE_DIR/package.json"

node_output=""
node_exit=0
node_output=$(bash "$SCRIPT" "$NODE_DIR" 2>&1) || node_exit=$?
assert_eq "test_detect_stack_node_project: exit 0" "0" "$node_exit"
assert_eq "test_detect_stack_node_project: outputs node-npm" "node-npm" "$node_output"

# ── test_detect_stack_rust_project ───────────────────────────────────────────
# A directory containing Cargo.toml must output 'rust-cargo'.
RUST_DIR="$TMPDIR_FIXTURE/rust_project"
mkdir -p "$RUST_DIR"
touch "$RUST_DIR/Cargo.toml"

rust_output=""
rust_exit=0
rust_output=$(bash "$SCRIPT" "$RUST_DIR" 2>&1) || rust_exit=$?
assert_eq "test_detect_stack_rust_project: exit 0" "0" "$rust_exit"
assert_eq "test_detect_stack_rust_project: outputs rust-cargo" "rust-cargo" "$rust_output"

# ── test_detect_stack_go_project ─────────────────────────────────────────────
# A directory containing go.mod must output 'golang'.
GO_DIR="$TMPDIR_FIXTURE/go_project"
mkdir -p "$GO_DIR"
touch "$GO_DIR/go.mod"

go_output=""
go_exit=0
go_output=$(bash "$SCRIPT" "$GO_DIR" 2>&1) || go_exit=$?
assert_eq "test_detect_stack_go_project: exit 0" "0" "$go_exit"
assert_eq "test_detect_stack_go_project: outputs golang" "golang" "$go_output"

# ── test_detect_stack_makefile_project ───────────────────────────────────────
# A directory containing a Makefile with test/lint/format targets must output
# 'convention-based'.
MAKE_DIR="$TMPDIR_FIXTURE/make_project"
mkdir -p "$MAKE_DIR"
cat > "$MAKE_DIR/Makefile" <<'MAKEFILE'
.PHONY: test lint format

test:
	pytest

lint:
	ruff check .

format:
	ruff format .
MAKEFILE

make_output=""
make_exit=0
make_output=$(bash "$SCRIPT" "$MAKE_DIR" 2>&1) || make_exit=$?
assert_eq "test_detect_stack_makefile_project: exit 0" "0" "$make_exit"
assert_eq "test_detect_stack_makefile_project: outputs convention-based" "convention-based" "$make_output"

# ── test_detect_stack_multi_marker ───────────────────────────────────────────
# A directory with both pyproject.toml and package.json must output 'python-poetry'
# because Python takes priority.
MULTI_DIR="$TMPDIR_FIXTURE/multi_project"
mkdir -p "$MULTI_DIR"
touch "$MULTI_DIR/pyproject.toml"
touch "$MULTI_DIR/package.json"

multi_output=""
multi_exit=0
multi_output=$(bash "$SCRIPT" "$MULTI_DIR" 2>&1) || multi_exit=$?
assert_eq "test_detect_stack_multi_marker: exit 0" "0" "$multi_exit"
assert_eq "test_detect_stack_multi_marker: python-poetry takes priority over node-npm" "python-poetry" "$multi_output"

# ── test_detect_stack_empty_dir ──────────────────────────────────────────────
# A directory with no recognized marker files must output 'unknown'.
EMPTY_DIR="$TMPDIR_FIXTURE/empty_project"
mkdir -p "$EMPTY_DIR"

empty_output=""
empty_exit=0
empty_output=$(bash "$SCRIPT" "$EMPTY_DIR" 2>&1) || empty_exit=$?
assert_eq "test_detect_stack_empty_dir: exit 0" "0" "$empty_exit"
assert_eq "test_detect_stack_empty_dir: outputs unknown" "unknown" "$empty_output"

print_summary
