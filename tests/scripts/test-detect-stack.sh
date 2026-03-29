#!/usr/bin/env bash
# tests/scripts/test-detect-stack.sh
# TDD red-phase tests for scripts/detect-stack.sh
#
# Usage: bash tests/scripts/test-detect-stack.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# NOTE: These tests are expected to FAIL until detect-stack.sh is implemented.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$DSO_PLUGIN_DIR/scripts/detect-stack.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

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
# A directory containing a valid pyproject.toml must output 'python-poetry'.
PYTHON_DIR="$TMPDIR_FIXTURE/python_project"
mkdir -p "$PYTHON_DIR"
printf '[build-system]\nrequires = ["poetry-core"]\n' > "$PYTHON_DIR/pyproject.toml"

python_output=""
python_exit=0
python_output=$(bash "$SCRIPT" "$PYTHON_DIR" 2>&1) || python_exit=$?
assert_eq "test_detect_stack_python_project: exit 0" "0" "$python_exit"
assert_eq "test_detect_stack_python_project: outputs python-poetry" "python-poetry" "$python_output"

# ── test_detect_stack_node_project ───────────────────────────────────────────
# A directory containing a valid package.json must output 'node-npm'.
NODE_DIR="$TMPDIR_FIXTURE/node_project"
mkdir -p "$NODE_DIR"
printf '{"name": "my-package", "version": "1.0.0"}\n' > "$NODE_DIR/package.json"

node_output=""
node_exit=0
node_output=$(bash "$SCRIPT" "$NODE_DIR" 2>&1) || node_exit=$?
assert_eq "test_detect_stack_node_project: exit 0" "0" "$node_exit"
assert_eq "test_detect_stack_node_project: outputs node-npm" "node-npm" "$node_output"

# ── test_detect_stack_rust_project ───────────────────────────────────────────
# A directory containing a non-empty Cargo.toml must output 'rust-cargo'.
RUST_DIR="$TMPDIR_FIXTURE/rust_project"
mkdir -p "$RUST_DIR"
printf '[package]\nname = "my-crate"\n' > "$RUST_DIR/Cargo.toml"

rust_output=""
rust_exit=0
rust_output=$(bash "$SCRIPT" "$RUST_DIR" 2>&1) || rust_exit=$?
assert_eq "test_detect_stack_rust_project: exit 0" "0" "$rust_exit"
assert_eq "test_detect_stack_rust_project: outputs rust-cargo" "rust-cargo" "$rust_output"

# ── test_detect_stack_go_project ─────────────────────────────────────────────
# A directory containing a non-empty go.mod must output 'golang'.
GO_DIR="$TMPDIR_FIXTURE/go_project"
mkdir -p "$GO_DIR"
printf 'module example.com/mymod\n\ngo 1.21\n' > "$GO_DIR/go.mod"

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
# because Python takes priority. Both files contain valid content to pass CoVe.
MULTI_DIR="$TMPDIR_FIXTURE/multi_project"
mkdir -p "$MULTI_DIR"
printf '[build-system]\nrequires = ["poetry-core"]\n' > "$MULTI_DIR/pyproject.toml"
printf '{"name": "my-package"}\n' > "$MULTI_DIR/package.json"

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

# ── test_detect_stack_python_empty_pyproject ─────────────────────────────────
# An empty pyproject.toml (0 bytes) is not a valid Python project marker.
# detect-stack.sh must verify file content, not just existence.
# RED: current detect-stack.sh only checks file existence with test -f.
EMPTY_PYPROJECT_DIR="$TMPDIR_FIXTURE/empty_pyproject_project"
mkdir -p "$EMPTY_PYPROJECT_DIR"
: > "$EMPTY_PYPROJECT_DIR/pyproject.toml"   # create 0-byte file

empty_pyproject_output=""
empty_pyproject_exit=0
empty_pyproject_output=$(bash "$SCRIPT" "$EMPTY_PYPROJECT_DIR" 2>&1) || empty_pyproject_exit=$?
assert_eq "test_detect_stack_python_empty_pyproject: exit 0" "0" "$empty_pyproject_exit"
assert_eq "test_detect_stack_python_empty_pyproject: empty pyproject.toml → unknown" "unknown" "$empty_pyproject_output"

# ── test_detect_stack_node_invalid_json ──────────────────────────────────────
# A package.json containing invalid JSON is not a valid Node project marker.
# detect-stack.sh must verify file content is parseable JSON, not just existence.
# RED: current detect-stack.sh only checks file existence with test -f.
INVALID_JSON_DIR="$TMPDIR_FIXTURE/invalid_json_project"
mkdir -p "$INVALID_JSON_DIR"
printf 'not json' > "$INVALID_JSON_DIR/package.json"

invalid_json_output=""
invalid_json_exit=0
invalid_json_output=$(bash "$SCRIPT" "$INVALID_JSON_DIR" 2>&1) || invalid_json_exit=$?
assert_eq "test_detect_stack_node_invalid_json: exit 0" "0" "$invalid_json_exit"
assert_eq "test_detect_stack_node_invalid_json: invalid JSON package.json → unknown" "unknown" "$invalid_json_output"

# ── test_detect_stack_empty_cargo_toml ───────────────────────────────────────
# An empty Cargo.toml (0 bytes) is not a valid Rust project marker.
# detect-stack.sh must verify file content, not just existence.
# RED: current detect-stack.sh only checks file existence with test -f.
EMPTY_CARGO_DIR="$TMPDIR_FIXTURE/empty_cargo_project"
mkdir -p "$EMPTY_CARGO_DIR"
: > "$EMPTY_CARGO_DIR/Cargo.toml"   # create 0-byte file

empty_cargo_output=""
empty_cargo_exit=0
empty_cargo_output=$(bash "$SCRIPT" "$EMPTY_CARGO_DIR" 2>&1) || empty_cargo_exit=$?
assert_eq "test_detect_stack_empty_cargo_toml: exit 0" "0" "$empty_cargo_exit"
assert_eq "test_detect_stack_empty_cargo_toml: empty Cargo.toml → unknown" "unknown" "$empty_cargo_output"

# ── test_detect_stack_rails_project ──────────────────────────────────────────
# A directory containing a non-empty Gemfile AND config/routes.rb must output
# 'ruby-rails'. RED: detect-stack.sh does not yet handle Rails detection.
RAILS_DIR="$TMPDIR_FIXTURE/rails_project"
mkdir -p "$RAILS_DIR/config"
printf 'source "https://rubygems.org"\ngem "rails"\n' > "$RAILS_DIR/Gemfile"
printf '# Rails routes\n' > "$RAILS_DIR/config/routes.rb"

rails_output=""
rails_exit=0
rails_output=$(bash "$SCRIPT" "$RAILS_DIR" 2>&1) || rails_exit=$?
assert_eq "test_detect_stack_rails_project: exit 0" "0" "$rails_exit"
assert_eq "test_detect_stack_rails_project: outputs ruby-rails" "ruby-rails" "$rails_output"

# ── test_detect_stack_jekyll_project ─────────────────────────────────────────
# A directory containing a non-empty Gemfile AND _config.yml must output
# 'ruby-jekyll'. RED: detect-stack.sh does not yet handle Jekyll detection.
JEKYLL_DIR="$TMPDIR_FIXTURE/jekyll_project"
mkdir -p "$JEKYLL_DIR"
printf 'source "https://rubygems.org"\ngem "jekyll"\n' > "$JEKYLL_DIR/Gemfile"
printf 'title: My Site\n' > "$JEKYLL_DIR/_config.yml"

jekyll_output=""
jekyll_exit=0
jekyll_output=$(bash "$SCRIPT" "$JEKYLL_DIR" 2>&1) || jekyll_exit=$?
assert_eq "test_detect_stack_jekyll_project: exit 0" "0" "$jekyll_exit"
assert_eq "test_detect_stack_jekyll_project: outputs ruby-jekyll" "ruby-jekyll" "$jekyll_output"

# ── test_detect_stack_rails_jekyll_precedence ─────────────────────────────────
# A directory containing Gemfile + config/routes.rb + _config.yml must output
# 'ruby-rails' — the more specific Rails marker takes precedence over Jekyll.
# RED: detect-stack.sh does not yet handle Rails/Jekyll detection.
RAILS_JEKYLL_DIR="$TMPDIR_FIXTURE/rails_jekyll_project"
mkdir -p "$RAILS_JEKYLL_DIR/config"
printf 'source "https://rubygems.org"\ngem "rails"\n' > "$RAILS_JEKYLL_DIR/Gemfile"
printf '# Rails routes\n' > "$RAILS_JEKYLL_DIR/config/routes.rb"
printf 'title: My Site\n' > "$RAILS_JEKYLL_DIR/_config.yml"

rails_jekyll_output=""
rails_jekyll_exit=0
rails_jekyll_output=$(bash "$SCRIPT" "$RAILS_JEKYLL_DIR" 2>&1) || rails_jekyll_exit=$?
assert_eq "test_detect_stack_rails_jekyll_precedence: exit 0" "0" "$rails_jekyll_exit"
assert_eq "test_detect_stack_rails_jekyll_precedence: ruby-rails takes priority over ruby-jekyll" "ruby-rails" "$rails_jekyll_output"

# ── test_detect_stack_rails_no_gemfile ────────────────────────────────────────
# config/routes.rb WITHOUT a Gemfile must output 'unknown' — Gemfile is the gate
# for Ruby project detection. This test should PASS at RED (current behavior).
RAILS_NO_GEMFILE_DIR="$TMPDIR_FIXTURE/rails_no_gemfile_project"
mkdir -p "$RAILS_NO_GEMFILE_DIR/config"
printf '# Rails routes\n' > "$RAILS_NO_GEMFILE_DIR/config/routes.rb"

rails_no_gemfile_output=""
rails_no_gemfile_exit=0
rails_no_gemfile_output=$(bash "$SCRIPT" "$RAILS_NO_GEMFILE_DIR" 2>&1) || rails_no_gemfile_exit=$?
assert_eq "test_detect_stack_rails_no_gemfile: exit 0" "0" "$rails_no_gemfile_exit"
assert_eq "test_detect_stack_rails_no_gemfile: routes.rb without Gemfile → unknown" "unknown" "$rails_no_gemfile_output"

# ── test_detect_stack_jekyll_no_gemfile ───────────────────────────────────────
# _config.yml WITHOUT a Gemfile must output 'unknown' — Gemfile is the gate
# for Ruby project detection. This test should PASS at RED (current behavior).
JEKYLL_NO_GEMFILE_DIR="$TMPDIR_FIXTURE/jekyll_no_gemfile_project"
mkdir -p "$JEKYLL_NO_GEMFILE_DIR"
printf 'title: My Site\n' > "$JEKYLL_NO_GEMFILE_DIR/_config.yml"

jekyll_no_gemfile_output=""
jekyll_no_gemfile_exit=0
jekyll_no_gemfile_output=$(bash "$SCRIPT" "$JEKYLL_NO_GEMFILE_DIR" 2>&1) || jekyll_no_gemfile_exit=$?
assert_eq "test_detect_stack_jekyll_no_gemfile: exit 0" "0" "$jekyll_no_gemfile_exit"
assert_eq "test_detect_stack_jekyll_no_gemfile: _config.yml without Gemfile → unknown" "unknown" "$jekyll_no_gemfile_output"

print_summary
