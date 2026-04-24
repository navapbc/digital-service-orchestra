#!/usr/bin/env bash
# shellcheck source=tests/lib/assert.sh
# source tests/lib/assert.sh — loaded dynamically below after PLUGIN_ROOT is resolved
# tests/scripts/test-project-detect.sh
# TDD red-phase tests for plugins/dso/scripts/onboarding/project-detect.sh
#
# Usage: bash tests/scripts/test-project-detect.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# NOTE: These tests are expected to FAIL until project-detect.sh is implemented.
#
# Output schema tested (key=value lines emitted by project-detect.sh):
#   stack=<value>
#   targets=<comma-separated>
#   python_version=<value>|unknown
#   python_version_confidence=high|low
#   db_present=true|false
#   db_services=<comma-separated>
#   files_present=<comma-separated>
#   ci_workflow_names=<comma-separated>
#   ci_workflow_test_guarded=true|false
#   ci_workflow_lint_guarded=true|false
#   ci_workflow_format_guarded=true|false
#   installed_deps=<comma-separated>
#   ports=<comma-separated>
#   version_files=<comma-separated>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SCRIPT="$DSO_PLUGIN_DIR/scripts/onboarding/project-detect.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-project-detect.sh ==="

# Create temp fixture dirs
TMPDIR_FIXTURE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FIXTURE"' EXIT

# ── Helper: extract a key=value line from output ──────────────────────────────
# Usage: get_key output key
# Returns the value portion of a "key=value" line, or empty string if absent.
get_key() {
    local output="$1" key="$2"
    echo "$output" | grep "^${key}=" | head -1 | cut -d= -f2-
}

# ── Category 1: Script existence and executability ────────────────────────────
if [[ -f "$SCRIPT" ]]; then
    actual_exists="exists"
else
    actual_exists="missing"
fi
assert_eq "cat1: script exists at expected path" "exists" "$actual_exists"

if [[ -x "$SCRIPT" ]]; then
    actual_exec="executable"
else
    actual_exec="not_executable"
fi
assert_eq "cat1: script is executable" "executable" "$actual_exec"

# ── Category 2: Stack detection (delegates to detect-stack.sh) ────────────────
# Happy path: python-poetry
PYTHON_DIR="$TMPDIR_FIXTURE/python_project"
mkdir -p "$PYTHON_DIR"
printf '[build-system]\nrequires = ["poetry-core"]\n' > "$PYTHON_DIR/pyproject.toml"

python_exit=0
python_output=$(bash "$SCRIPT" "$PYTHON_DIR" 2>&1) || python_exit=$?
assert_eq "cat2: python project exits 0" "0" "$python_exit"
assert_eq "cat2: stack=python-poetry for pyproject.toml" "python-poetry" "$(get_key "$python_output" stack)"

# Happy path: node-npm
NODE_DIR="$TMPDIR_FIXTURE/node_project"
mkdir -p "$NODE_DIR"
printf '{"name": "my-package", "version": "1.0.0"}\n' > "$NODE_DIR/package.json"

node_exit=0
node_output=$(bash "$SCRIPT" "$NODE_DIR" 2>&1) || node_exit=$?
assert_eq "cat2: node project exits 0" "0" "$node_exit"
assert_eq "cat2: stack=node-npm for package.json" "node-npm" "$(get_key "$node_output" stack)"

# Happy path: golang
GO_DIR="$TMPDIR_FIXTURE/go_project"
mkdir -p "$GO_DIR"
printf 'module example.com/mymod\n\ngo 1.21\n' > "$GO_DIR/go.mod"

go_exit=0
go_output=$(bash "$SCRIPT" "$GO_DIR" 2>&1) || go_exit=$?
assert_eq "cat2: golang project exits 0" "0" "$go_exit"
assert_eq "cat2: stack=golang for go.mod" "golang" "$(get_key "$go_output" stack)"

# Happy path: rust-cargo
RUST_DIR="$TMPDIR_FIXTURE/rust_project"
mkdir -p "$RUST_DIR"
printf '[package]\nname = "my-crate"\n' > "$RUST_DIR/Cargo.toml"

rust_exit=0
rust_output=$(bash "$SCRIPT" "$RUST_DIR" 2>&1) || rust_exit=$?
assert_eq "cat2: rust project exits 0" "0" "$rust_exit"
assert_eq "cat2: stack=rust-cargo for Cargo.toml" "rust-cargo" "$(get_key "$rust_output" stack)"

# Happy path: convention-based (Makefile with test/lint/format)
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

make_exit=0
make_output=$(bash "$SCRIPT" "$MAKE_DIR" 2>&1) || make_exit=$?
assert_eq "cat2: makefile project exits 0" "0" "$make_exit"
assert_eq "cat2: stack=convention-based for Makefile" "convention-based" "$(get_key "$make_output" stack)"

# Absent-input: unknown stack
EMPTY_STACK_DIR="$TMPDIR_FIXTURE/empty_stack_project"
mkdir -p "$EMPTY_STACK_DIR"

empty_stack_exit=0
empty_stack_output=$(bash "$SCRIPT" "$EMPTY_STACK_DIR" 2>&1) || empty_stack_exit=$?
assert_eq "cat2: empty dir exits 0" "0" "$empty_stack_exit"
assert_eq "cat2: stack=unknown for empty dir" "unknown" "$(get_key "$empty_stack_output" stack)"

# ── Category 3: Target enumeration ───────────────────────────────────────────
# Happy path: Makefile targets
TARGETS_DIR="$TMPDIR_FIXTURE/targets_project"
mkdir -p "$TARGETS_DIR"
cat > "$TARGETS_DIR/Makefile" <<'MAKEFILE'
.PHONY: test lint format build

test:
	pytest

lint:
	ruff check .

format:
	ruff format .

build:
	docker build .
MAKEFILE

targets_exit=0
targets_output=$(bash "$SCRIPT" "$TARGETS_DIR" 2>&1) || targets_exit=$?
assert_eq "cat3: targets project exits 0" "0" "$targets_exit"
targets_val="$(get_key "$targets_output" targets)"
assert_contains "cat3: targets contains test" "test" "$targets_val"
assert_contains "cat3: targets contains lint" "lint" "$targets_val"

# Happy path: package.json scripts
PKG_TARGETS_DIR="$TMPDIR_FIXTURE/pkg_targets_project"
mkdir -p "$PKG_TARGETS_DIR"
cat > "$PKG_TARGETS_DIR/package.json" <<'JSON'
{
  "scripts": {
    "test": "jest",
    "build": "tsc",
    "lint": "eslint ."
  }
}
JSON

pkg_targets_exit=0
pkg_targets_output=$(bash "$SCRIPT" "$PKG_TARGETS_DIR" 2>&1) || pkg_targets_exit=$?
assert_eq "cat3: pkg.json targets project exits 0" "0" "$pkg_targets_exit"
pkg_targets_val="$(get_key "$pkg_targets_output" targets)"
assert_contains "cat3: pkg.json targets contains test" "test" "$pkg_targets_val"

# Absent-input: no Makefile or package.json → empty targets
NO_TARGETS_DIR="$TMPDIR_FIXTURE/no_targets_project"
mkdir -p "$NO_TARGETS_DIR"
no_targets_exit=0
no_targets_output=$(bash "$SCRIPT" "$NO_TARGETS_DIR" 2>&1) || no_targets_exit=$?
assert_eq "cat3: no-targets project exits 0" "0" "$no_targets_exit"

# ── Category 4: CI workflow analysis ─────────────────────────────────────────
# Happy path: workflow with test/lint/format guards
CI_DIR="$TMPDIR_FIXTURE/ci_project"
mkdir -p "$CI_DIR/.github/workflows"
cat > "$CI_DIR/.github/workflows/ci.yml" <<'YAML'
name: CI Pipeline
on: [push]
jobs:
  test:
    name: Run Tests
    runs-on: ubuntu-latest
    steps:
      - run: make test
  lint:
    name: Lint Check
    runs-on: ubuntu-latest
    steps:
      - run: make lint
  format:
    name: Format Check
    runs-on: ubuntu-latest
    steps:
      - run: make format
YAML

ci_exit=0
ci_output=$(bash "$SCRIPT" "$CI_DIR" 2>&1) || ci_exit=$?
assert_eq "cat4: ci project exits 0" "0" "$ci_exit"
ci_names="$(get_key "$ci_output" ci_workflow_names)"
assert_contains "cat4: ci_workflow_names contains CI Pipeline" "CI Pipeline" "$ci_names"
assert_eq "cat4: ci_workflow_test_guarded=true" "true" "$(get_key "$ci_output" ci_workflow_test_guarded)"
assert_eq "cat4: ci_workflow_lint_guarded=true" "true" "$(get_key "$ci_output" ci_workflow_lint_guarded)"
assert_eq "cat4: ci_workflow_format_guarded=true" "true" "$(get_key "$ci_output" ci_workflow_format_guarded)"

# Absent-input: no .github/workflows → no CI workflow info
NO_CI_DIR="$TMPDIR_FIXTURE/no_ci_project"
mkdir -p "$NO_CI_DIR"
no_ci_exit=0
no_ci_output=$(bash "$SCRIPT" "$NO_CI_DIR" 2>&1) || no_ci_exit=$?
assert_eq "cat4: no-ci project exits 0" "0" "$no_ci_exit"
assert_eq "cat4: ci_workflow_test_guarded=false when no CI" "false" "$(get_key "$no_ci_output" ci_workflow_test_guarded)"
assert_eq "cat4: ci_workflow_lint_guarded=false when no CI" "false" "$(get_key "$no_ci_output" ci_workflow_lint_guarded)"
assert_eq "cat4: ci_workflow_format_guarded=false when no CI" "false" "$(get_key "$no_ci_output" ci_workflow_format_guarded)"

# ── CI workflow named tests (AC-required labels) ──────────────────────────────

# test_project_detect_ci_workflow_names: workflow file name appears in output
_snapshot_fail
_ci_names_dir="$TMPDIR_FIXTURE/ci_names_project"
mkdir -p "$_ci_names_dir/.github/workflows"
cat > "$_ci_names_dir/.github/workflows/ci.yml" <<'YAML'
name: CI Pipeline
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: make test
YAML
_ci_names_out=$(bash "$SCRIPT" "$_ci_names_dir" 2>&1)
assert_contains "test_project_detect_ci_workflow_names: ci_workflow_names contains CI Pipeline" \
    "CI Pipeline" "$(get_key "$_ci_names_out" ci_workflow_names)"
assert_pass_if_clean "test_project_detect_ci_workflow_names"

# test_project_detect_ci_workflow_test_guarded: make test triggers guard
_snapshot_fail
_ci_test_dir="$TMPDIR_FIXTURE/ci_test_guarded_project"
mkdir -p "$_ci_test_dir/.github/workflows"
cat > "$_ci_test_dir/.github/workflows/test.yml" <<'YAML'
name: Test Suite
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: make test
YAML
_ci_test_out=$(bash "$SCRIPT" "$_ci_test_dir" 2>&1)
assert_eq "test_project_detect_ci_workflow_test_guarded: ci_workflow_test_guarded=true" \
    "true" "$(get_key "$_ci_test_out" ci_workflow_test_guarded)"
assert_pass_if_clean "test_project_detect_ci_workflow_test_guarded"

# test_project_detect_ci_workflow_no_workflows: no dir → confidence=low
_snapshot_fail
_ci_no_wf_dir="$TMPDIR_FIXTURE/ci_no_workflows_project"
mkdir -p "$_ci_no_wf_dir"
_ci_no_wf_out=$(bash "$SCRIPT" "$_ci_no_wf_dir" 2>&1)
assert_eq "test_project_detect_ci_workflow_no_workflows: confidence=low when no dir" \
    "low" "$(get_key "$_ci_no_wf_out" ci_workflow_confidence)"
assert_eq "test_project_detect_ci_workflow_no_workflows: exits 0 when no workflows dir" \
    "0" "$(bash "$SCRIPT" "$_ci_no_wf_dir" > /dev/null 2>&1; echo $?)"
assert_pass_if_clean "test_project_detect_ci_workflow_no_workflows"

# test_project_detect_ci_workflow_confidence_high: workflows present → confidence=high
_snapshot_fail
_ci_conf_dir="$TMPDIR_FIXTURE/ci_confidence_high_project"
mkdir -p "$_ci_conf_dir/.github/workflows"
cat > "$_ci_conf_dir/.github/workflows/ci.yml" <<'YAML'
name: High Confidence CI
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo "building"
YAML
_ci_conf_out=$(bash "$SCRIPT" "$_ci_conf_dir" 2>&1)
assert_eq "test_project_detect_ci_workflow_confidence_high: confidence=high when workflows exist" \
    "high" "$(get_key "$_ci_conf_out" ci_workflow_confidence)"
assert_pass_if_clean "test_project_detect_ci_workflow_confidence_high"

# ── Category 5: Database presence ────────────────────────────────────────────
# Happy path: docker-compose.yml with db service
DB_DIR="$TMPDIR_FIXTURE/db_project"
mkdir -p "$DB_DIR"
cat > "$DB_DIR/docker-compose.yml" <<'YAML'
services:
  postgres:
    image: postgres:15
  redis:
    image: redis:7
YAML

db_exit=0
db_output=$(bash "$SCRIPT" "$DB_DIR" 2>&1) || db_exit=$?
assert_eq "cat5: db project exits 0" "0" "$db_exit"
assert_eq "cat5: db_present=true when postgres in compose" "true" "$(get_key "$db_output" db_present)"
db_services="$(get_key "$db_output" db_services)"
assert_contains "cat5: db_services contains postgres" "postgres" "$db_services"

# Absent-input: no docker-compose.yml → db_present=false
NO_DB_DIR="$TMPDIR_FIXTURE/no_db_project"
mkdir -p "$NO_DB_DIR"
no_db_exit=0
no_db_output=$(bash "$SCRIPT" "$NO_DB_DIR" 2>&1) || no_db_exit=$?
assert_eq "cat5: no-db project exits 0" "0" "$no_db_exit"
assert_eq "cat5: db_present=false when no compose file" "false" "$(get_key "$no_db_output" db_present)"

# ── Category 6: Python version detection ─────────────────────────────────────
# Happy path: pyproject.toml with requires-python
PY_VER_DIR="$TMPDIR_FIXTURE/py_ver_project"
mkdir -p "$PY_VER_DIR"
cat > "$PY_VER_DIR/pyproject.toml" <<'TOML'
[project]
requires-python = ">=3.11"

[tool.poetry]
name = "myapp"
TOML

py_ver_exit=0
py_ver_output=$(bash "$SCRIPT" "$PY_VER_DIR" 2>&1) || py_ver_exit=$?
assert_eq "cat6: py-ver project exits 0" "0" "$py_ver_exit"
assert_eq "cat6: python_version_confidence=high when pyproject.toml present" "high" "$(get_key "$py_ver_output" python_version_confidence)"
py_ver_val="$(get_key "$py_ver_output" python_version)"
assert_ne "cat6: python_version not empty when pyproject.toml has requires-python" "" "$py_ver_val"

# Happy path: .python-version file
PY_VER_FILE_DIR="$TMPDIR_FIXTURE/py_ver_file_project"
mkdir -p "$PY_VER_FILE_DIR"
echo "3.12.3" > "$PY_VER_FILE_DIR/.python-version"

py_ver_file_exit=0
py_ver_file_output=$(bash "$SCRIPT" "$PY_VER_FILE_DIR" 2>&1) || py_ver_file_exit=$?
assert_eq "cat6: py-ver-file project exits 0" "0" "$py_ver_file_exit"
assert_eq "cat6: python_version=3.12.3 from .python-version" "3.12.3" "$(get_key "$py_ver_file_output" python_version)"
assert_eq "cat6: python_version_confidence=high for .python-version" "high" "$(get_key "$py_ver_file_output" python_version_confidence)"

# Absent-input: no pyproject.toml or .python-version → fallback/low confidence
NO_PY_VER_DIR="$TMPDIR_FIXTURE/no_py_ver_project"
mkdir -p "$NO_PY_VER_DIR"
no_py_ver_exit=0
no_py_ver_output=$(bash "$SCRIPT" "$NO_PY_VER_DIR" 2>&1) || no_py_ver_exit=$?
assert_eq "cat6: no-py-ver project exits 0" "0" "$no_py_ver_exit"
# When heuristic is uncertain, confidence degrades to low (or unknown)
no_py_ver_conf="$(get_key "$no_py_ver_output" python_version_confidence)"
assert_ne "cat6: python_version_confidence is not high when no version files" "high" "$no_py_ver_conf"

# ── Category 7: Installed CLI dependencies ────────────────────────────────────
# Happy path: check known-present tool (bash is always available)
CLI_DIR="$TMPDIR_FIXTURE/cli_project"
mkdir -p "$CLI_DIR"

cli_exit=0
cli_output=$(bash "$SCRIPT" "$CLI_DIR" 2>&1) || cli_exit=$?
assert_eq "cat7: cli project exits 0" "0" "$cli_exit"
# installed_deps key must always be present (may be empty when nothing found)
assert_contains "cat7: output contains installed_deps key" "installed_deps=" "$cli_output"

# ── Category 8: Existing file presence ───────────────────────────────────────
# Happy path: CLAUDE.md and KNOWN-ISSUES.md present
FILES_DIR="$TMPDIR_FIXTURE/files_project"
mkdir -p "$FILES_DIR/.claude"
touch "$FILES_DIR/CLAUDE.md"
touch "$FILES_DIR/KNOWN-ISSUES.md"
touch "$FILES_DIR/.pre-commit-config.yaml"
touch "$FILES_DIR/.claude/dso-config.conf"

files_exit=0
files_output=$(bash "$SCRIPT" "$FILES_DIR" 2>&1) || files_exit=$?
assert_eq "cat8: files project exits 0" "0" "$files_exit"
files_present="$(get_key "$files_output" files_present)"
assert_contains "cat8: files_present contains CLAUDE.md" "CLAUDE.md" "$files_present"
assert_contains "cat8: files_present contains KNOWN-ISSUES.md" "KNOWN-ISSUES.md" "$files_present"
assert_contains "cat8: files_present contains .pre-commit-config.yaml" ".pre-commit-config.yaml" "$files_present"
assert_contains "cat8: files_present contains .claude/dso-config.conf" ".claude/dso-config.conf" "$files_present"

# Absent-input: none of the marker files → files_present is empty or absent
NO_FILES_DIR="$TMPDIR_FIXTURE/no_files_project"
mkdir -p "$NO_FILES_DIR"
no_files_exit=0
no_files_output=$(bash "$SCRIPT" "$NO_FILES_DIR" 2>&1) || no_files_exit=$?
assert_eq "cat8: no-files project exits 0" "0" "$no_files_exit"
no_files_present="$(get_key "$no_files_output" files_present)"
assert_eq "cat8: files_present is empty when no marker files" "" "$no_files_present"

# ── Category 9: Port numbers from .claude/dso-config.conf ────────────────────
# Happy path: .claude/dso-config.conf with port entries
PORTS_DIR="$TMPDIR_FIXTURE/ports_project"
mkdir -p "$PORTS_DIR/.claude"
cat > "$PORTS_DIR/.claude/dso-config.conf" <<'CONF'
ci.app_port=8000
ci.db_port=5432
ci.redis_port=6379
CONF

ports_exit=0
ports_output=$(bash "$SCRIPT" "$PORTS_DIR" 2>&1) || ports_exit=$?
assert_eq "cat9: ports project exits 0" "0" "$ports_exit"
ports_val="$(get_key "$ports_output" ports)"
assert_contains "cat9: ports contains 8000" "8000" "$ports_val"

# Absent-input: no .claude/dso-config.conf → ports empty or absent
NO_PORTS_DIR="$TMPDIR_FIXTURE/no_ports_project"
mkdir -p "$NO_PORTS_DIR"
no_ports_exit=0
no_ports_output=$(bash "$SCRIPT" "$NO_PORTS_DIR" 2>&1) || no_ports_exit=$?
assert_eq "cat9: no-ports project exits 0" "0" "$no_ports_exit"

# ── Category 10: Version file candidates ─────────────────────────────────────
# Happy path: package.json with version field
VER_NODE_DIR="$TMPDIR_FIXTURE/ver_node_project"
mkdir -p "$VER_NODE_DIR"
cat > "$VER_NODE_DIR/package.json" <<'JSON'
{
  "name": "my-app",
  "version": "1.2.3"
}
JSON

ver_node_exit=0
ver_node_output=$(bash "$SCRIPT" "$VER_NODE_DIR" 2>&1) || ver_node_exit=$?
assert_eq "cat10: ver-node project exits 0" "0" "$ver_node_exit"
ver_node_files="$(get_key "$ver_node_output" version_files)"
assert_contains "cat10: version_files contains package.json" "package.json" "$ver_node_files"

# Happy path: pyproject.toml with version field
VER_PY_DIR="$TMPDIR_FIXTURE/ver_py_project"
mkdir -p "$VER_PY_DIR"
cat > "$VER_PY_DIR/pyproject.toml" <<'TOML'
[project]
version = "2.0.0"
name = "my-py-app"
TOML

ver_py_exit=0
ver_py_output=$(bash "$SCRIPT" "$VER_PY_DIR" 2>&1) || ver_py_exit=$?
assert_eq "cat10: ver-py project exits 0" "0" "$ver_py_exit"
ver_py_files="$(get_key "$ver_py_output" version_files)"
assert_contains "cat10: version_files contains pyproject.toml" "pyproject.toml" "$ver_py_files"

# Absent-input: no package.json or pyproject.toml → version_files empty
NO_VER_DIR="$TMPDIR_FIXTURE/no_ver_project"
mkdir -p "$NO_VER_DIR"
no_ver_exit=0
no_ver_output=$(bash "$SCRIPT" "$NO_VER_DIR" 2>&1) || no_ver_exit=$?
assert_eq "cat10: no-ver project exits 0" "0" "$no_ver_exit"

# ── Category 11: Confidence degradation ──────────────────────────────────────
# When python_version heuristic uses binary fallback (no explicit version files),
# confidence should be low, not high.
CONF_DEGRADE_DIR="$TMPDIR_FIXTURE/conf_degrade_project"
mkdir -p "$CONF_DEGRADE_DIR"
# Only a Makefile — no Python version markers — forces fallback path
cat > "$CONF_DEGRADE_DIR/Makefile" <<'MAKEFILE'
.PHONY: test lint

test:
	./run_tests.sh

lint:
	./lint.sh
MAKEFILE

conf_degrade_exit=0
conf_degrade_output=$(bash "$SCRIPT" "$CONF_DEGRADE_DIR" 2>&1) || conf_degrade_exit=$?
assert_eq "cat11: conf-degrade project exits 0" "0" "$conf_degrade_exit"
# python_version_confidence must not be "high" when no version anchor file exists
degrade_conf="$(get_key "$conf_degrade_output" python_version_confidence)"
assert_ne "cat11: python_version_confidence is not high when no explicit version markers" "high" "$degrade_conf"

# ── Category 12: Graceful degradation ────────────────────────────────────────
# Script must exit 0 even when ALL optional files/tools are absent.
GRACE_DIR="$TMPDIR_FIXTURE/graceful_project"
mkdir -p "$GRACE_DIR"
# Completely empty directory — no markers, no CI, no DB, no config

grace_exit=0
grace_output=$(bash "$SCRIPT" "$GRACE_DIR" 2>&1) || grace_exit=$?
assert_eq "cat12: graceful-degrade project exits 0" "0" "$grace_exit"
# Must still emit the core schema keys
assert_contains "cat12: output contains stack= key" "stack=" "$grace_output"
assert_contains "cat12: output contains db_present= key" "db_present=" "$grace_output"
assert_contains "cat12: output contains files_present= key" "files_present=" "$grace_output"
assert_contains "cat12: output contains ci_workflow_test_guarded= key" "ci_workflow_test_guarded=" "$grace_output"
assert_contains "cat12: output contains installed_deps= key" "installed_deps=" "$grace_output"

# ── Named tests: DB presence (AC-required labels) ────────────────────────────

# test_project_detect_db_present_docker_compose: db_present=true when postgres in docker-compose
_snapshot_fail
_db_present_dir="$TMPDIR_FIXTURE/db_present_named_project"
mkdir -p "$_db_present_dir"
cat > "$_db_present_dir/docker-compose.yml" <<'YAML'
services:
  postgres:
    image: postgres:15
  app:
    image: myapp:latest
YAML
_db_present_out=$(bash "$SCRIPT" "$_db_present_dir" 2>&1)
assert_eq "test_project_detect_db_present_docker_compose: db_present=true" \
    "true" "$(get_key "$_db_present_out" db_present)"
assert_contains "test_project_detect_db_present_docker_compose: db_services contains postgres" \
    "postgres" "$(get_key "$_db_present_out" db_services)"
assert_pass_if_clean "test_project_detect_db_present_docker_compose"

# test_project_detect_db_absent: db_present=false when no database markers
_snapshot_fail
_db_absent_dir="$TMPDIR_FIXTURE/db_absent_named_project"
mkdir -p "$_db_absent_dir"
_db_absent_out=$(bash "$SCRIPT" "$_db_absent_dir" 2>&1)
assert_eq "test_project_detect_db_absent: db_present=false" \
    "false" "$(get_key "$_db_absent_out" db_present)"
assert_pass_if_clean "test_project_detect_db_absent"

# ── Named tests: Port detection (AC-required labels) ─────────────────────────

# test_project_detect_ports_from_config: ports extracted from .claude/dso-config.conf _port keys
_snapshot_fail
_ports_conf_dir="$TMPDIR_FIXTURE/ports_conf_named_project"
mkdir -p "$_ports_conf_dir/.claude"
cat > "$_ports_conf_dir/.claude/dso-config.conf" <<'CONF'
ci.app_port=8080
ci.db_port=5432
CONF
_ports_conf_out=$(bash "$SCRIPT" "$_ports_conf_dir" 2>&1)
assert_contains "test_project_detect_ports_from_config: ports contains 8080" \
    "8080" "$(get_key "$_ports_conf_out" ports)"
assert_pass_if_clean "test_project_detect_ports_from_config"

# ── Named tests: Version file candidates (AC-required labels) ─────────────────

# test_project_detect_version_files_package_json: version_files=package.json when version key present
_snapshot_fail
_vf_pkg_dir="$TMPDIR_FIXTURE/vf_package_json_named_project"
mkdir -p "$_vf_pkg_dir"
cat > "$_vf_pkg_dir/package.json" <<'JSON'
{
  "name": "my-app",
  "version": "1.0.0"
}
JSON
_vf_pkg_out=$(bash "$SCRIPT" "$_vf_pkg_dir" 2>&1)
assert_contains "test_project_detect_version_files_package_json: version_files contains package.json" \
    "package.json" "$(get_key "$_vf_pkg_out" version_files)"
assert_pass_if_clean "test_project_detect_version_files_package_json"

# ── Named tests: --suites backward compatibility (AC-required labels) ─────────

# test_project_detect_suites_backward_compat_no_flag: without --suites flag,
# output is identical KEY=VALUE format — no JSON emitted, all standard keys present.
_snapshot_fail
_compat_dir="$TMPDIR_FIXTURE/suites_compat_project"
mkdir -p "$_compat_dir"
cat > "$_compat_dir/Makefile" <<'MAKEFILE'
.PHONY: test lint format

test:
	pytest

lint:
	ruff check .

format:
	ruff format .
MAKEFILE
mkdir -p "$_compat_dir/.github/workflows"
cat > "$_compat_dir/.github/workflows/ci.yml" <<'YAML'
name: CI
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: make test
YAML
# Run WITHOUT --suites flag
_compat_exit=0
_compat_out=$(bash "$SCRIPT" "$_compat_dir" 2>&1) || _compat_exit=$?
assert_eq "test_project_detect_suites_backward_compat_no_flag: exits 0" \
    "0" "$_compat_exit"
# All standard KEY=VALUE keys must be present
assert_contains "test_project_detect_suites_backward_compat_no_flag: stack= present" \
    "stack=" "$_compat_out"
assert_contains "test_project_detect_suites_backward_compat_no_flag: targets= present" \
    "targets=" "$_compat_out"
assert_contains "test_project_detect_suites_backward_compat_no_flag: db_present= present" \
    "db_present=" "$_compat_out"
assert_contains "test_project_detect_suites_backward_compat_no_flag: ci_workflow_test_guarded= present" \
    "ci_workflow_test_guarded=" "$_compat_out"
assert_contains "test_project_detect_suites_backward_compat_no_flag: files_present= present" \
    "files_present=" "$_compat_out"
assert_contains "test_project_detect_suites_backward_compat_no_flag: installed_deps= present" \
    "installed_deps=" "$_compat_out"
# No JSON array brackets in output (--suites not active)
_compat_json_count=$(echo "$_compat_out" | grep -cE '^\[' || true)
assert_eq "test_project_detect_suites_backward_compat_no_flag: no JSON array in output" \
    "0" "$_compat_json_count"
assert_pass_if_clean "test_project_detect_suites_backward_compat_no_flag"

# test_project_detect_suites_exit_zero_empty_repo: with --suites on empty repo,
# exits 0 and outputs empty JSON array [].
_snapshot_fail
_suites_empty_dir="$TMPDIR_FIXTURE/suites_empty_project"
mkdir -p "$_suites_empty_dir"
_suites_empty_exit=0
_suites_empty_out=$(bash "$SCRIPT" --suites "$_suites_empty_dir" 2>&1) || _suites_empty_exit=$?
assert_eq "test_project_detect_suites_exit_zero_empty_repo: exits 0" \
    "0" "$_suites_empty_exit"
# Output must be valid JSON empty array
_suites_empty_trimmed=$(echo "$_suites_empty_out" | tr -d '[:space:]')
assert_eq "test_project_detect_suites_exit_zero_empty_repo: outputs []" \
    "[]" "$_suites_empty_trimmed"
assert_pass_if_clean "test_project_detect_suites_exit_zero_empty_repo"

# test_project_detect_suites_exit_zero_always: with --suites on any repo, exits 0.
_snapshot_fail
_suites_any_dir="$TMPDIR_FIXTURE/suites_any_project"
mkdir -p "$_suites_any_dir"
cat > "$_suites_any_dir/Makefile" <<'MAKEFILE'
.PHONY: test lint

test:
	pytest

lint:
	ruff check .
MAKEFILE
_suites_any_exit=0
_suites_any_out=$(bash "$SCRIPT" --suites "$_suites_any_dir" 2>&1) || _suites_any_exit=$?
assert_eq "test_project_detect_suites_exit_zero_always: exits 0" \
    "0" "$_suites_any_exit"
assert_pass_if_clean "test_project_detect_suites_exit_zero_always"

# ── Named tests: --suites JSON schema and heuristic tests (T4 RED phase) ──────

# test_project_detect_suites_json_schema: with --suites on a Makefile repo with
# test-unit target, output is valid JSON array; each element has keys:
# name (string), command (string), speed_class (one of fast|slow|unknown),
# runner (one of make|pytest|npm|bash|config).
_snapshot_fail
_suites_schema_dir="$TMPDIR_FIXTURE/suites_schema_project"
mkdir -p "$_suites_schema_dir"
cat > "$_suites_schema_dir/Makefile" <<'MAKEFILE'
.PHONY: test-unit lint format

test-unit:
	pytest tests/unit/

lint:
	ruff check .

format:
	ruff format .
MAKEFILE
_suites_schema_exit=0
_suites_schema_out=$(bash "$SCRIPT" --suites "$_suites_schema_dir" 2>&1) || _suites_schema_exit=$?
assert_eq "test_project_detect_suites_json_schema: exits 0" \
    "0" "$_suites_schema_exit"
# Output must be valid JSON (parseable by python3 json module)
_suites_schema_valid=$(python3 -c "
import sys, json
try:
    data = json.loads(sys.argv[1])
    assert isinstance(data, list), 'not a list'
    assert len(data) > 0, 'empty list'
    for entry in data:
        assert isinstance(entry.get('name'), str), 'name not a string'
        assert isinstance(entry.get('command'), str), 'command not a string'
        assert entry.get('speed_class') in ('fast', 'slow', 'unknown'), 'bad speed_class: ' + str(entry.get('speed_class'))
        assert entry.get('runner') in ('make', 'pytest', 'npm', 'bash', 'config'), 'bad runner: ' + str(entry.get('runner'))
    print('valid')
except Exception as e:
    print('invalid: ' + str(e))
" "$_suites_schema_out" 2>&1)
assert_eq "test_project_detect_suites_json_schema: valid JSON schema" \
    "valid" "$_suites_schema_valid"
assert_pass_if_clean "test_project_detect_suites_json_schema"

# test_project_detect_suites_makefile: fixture with Makefile containing
# 'test-unit:' and 'test-e2e:' targets -> JSON array contains entries with
# runner=make, name=unit, name=e2e, command='make test-unit', command='make test-e2e'.
_snapshot_fail
_suites_make_dir="$TMPDIR_FIXTURE/suites_makefile_project"
mkdir -p "$_suites_make_dir"
cat > "$_suites_make_dir/Makefile" <<'MAKEFILE'
.PHONY: test-unit test-e2e lint format

test-unit:
	pytest tests/unit/

test-e2e:
	pytest tests/e2e/

lint:
	ruff check .

format:
	ruff format .
MAKEFILE
_suites_make_exit=0
_suites_make_out=$(bash "$SCRIPT" --suites "$_suites_make_dir" 2>&1) || _suites_make_exit=$?
assert_eq "test_project_detect_suites_makefile: exits 0" \
    "0" "$_suites_make_exit"
# Validate entries via python3
_suites_make_valid=$(python3 -c "
import sys, json
try:
    data = json.loads(sys.argv[1])
    names = {e['name'] for e in data}
    runners = {e['runner'] for e in data}
    commands = {e['command'] for e in data}
    errors = []
    if 'unit' not in names:
        errors.append('missing name=unit')
    if 'e2e' not in names:
        errors.append('missing name=e2e')
    if 'make' not in runners:
        errors.append('missing runner=make')
    if 'make test-unit' not in commands:
        errors.append('missing command=make test-unit')
    if 'make test-e2e' not in commands:
        errors.append('missing command=make test-e2e')
    if errors:
        print('invalid: ' + '; '.join(errors))
    else:
        print('valid')
except Exception as e:
    print('invalid: ' + str(e))
" "$_suites_make_out" 2>&1)
assert_eq "test_project_detect_suites_makefile: correct entries" \
    "valid" "$_suites_make_valid"
assert_pass_if_clean "test_project_detect_suites_makefile"

# test_project_detect_suites_pytest: fixture with tests/models/ directory
# containing test_model.py -> JSON entry with runner=pytest, name=models,
# command='pytest tests/models/'.
_snapshot_fail
_suites_pytest_dir="$TMPDIR_FIXTURE/suites_pytest_project"
mkdir -p "$_suites_pytest_dir/tests/models"
cat > "$_suites_pytest_dir/tests/models/test_model.py" <<'PY'
def test_placeholder():
    pass
PY
_suites_pytest_exit=0
_suites_pytest_out=$(bash "$SCRIPT" --suites "$_suites_pytest_dir" 2>&1) || _suites_pytest_exit=$?
assert_eq "test_project_detect_suites_pytest: exits 0" \
    "0" "$_suites_pytest_exit"
# Validate pytest entry
_suites_pytest_valid=$(python3 -c "
import sys, json
try:
    data = json.loads(sys.argv[1])
    found = [e for e in data if e.get('runner') == 'pytest' and e.get('name') == 'models']
    if not found:
        print('invalid: no entry with runner=pytest, name=models')
    elif found[0].get('command') != 'pytest tests/models/':
        print('invalid: command=' + str(found[0].get('command')) + ', expected pytest tests/models/')
    else:
        print('valid')
except Exception as e:
    print('invalid: ' + str(e))
" "$_suites_pytest_out" 2>&1)
assert_eq "test_project_detect_suites_pytest: correct pytest entry" \
    "valid" "$_suites_pytest_valid"
assert_pass_if_clean "test_project_detect_suites_pytest"

# test_project_detect_suites_makefile_name_derivation: Makefile target
# 'test-integration' -> name='integration'; target 'test_smoke' -> name='smoke'
# (strip test- or test_ prefix for name).
_snapshot_fail
_suites_derive_dir="$TMPDIR_FIXTURE/suites_derivation_project"
mkdir -p "$_suites_derive_dir"
cat > "$_suites_derive_dir/Makefile" <<'MAKEFILE'
.PHONY: test-integration test_smoke

test-integration:
	pytest tests/integration/

test_smoke:
	pytest tests/smoke/
MAKEFILE
_suites_derive_exit=0
_suites_derive_out=$(bash "$SCRIPT" --suites "$_suites_derive_dir" 2>&1) || _suites_derive_exit=$?
assert_eq "test_project_detect_suites_makefile_name_derivation: exits 0" \
    "0" "$_suites_derive_exit"
# Validate name derivation
_suites_derive_valid=$(python3 -c "
import sys, json
try:
    data = json.loads(sys.argv[1])
    names = {e['name'] for e in data}
    errors = []
    if 'integration' not in names:
        errors.append('missing name=integration (from test-integration)')
    if 'smoke' not in names:
        errors.append('missing name=smoke (from test_smoke)')
    if errors:
        print('invalid: ' + '; '.join(errors))
    else:
        print('valid')
except Exception as e:
    print('invalid: ' + str(e))
" "$_suites_derive_out" 2>&1)
assert_eq "test_project_detect_suites_makefile_name_derivation: correct names" \
    "valid" "$_suites_derive_valid"
assert_pass_if_clean "test_project_detect_suites_makefile_name_derivation"

# ── Named tests: npm, bash runner, dedup, precedence (T5 RED phase) ────────

# test_project_detect_suites_npm: fixture with package.json scripts 'test:unit'
# and 'test:e2e' -> JSON entries with runner=npm, name=unit, name=e2e
# (strip 'test:' prefix for name), command='npm run test:unit', command='npm run test:e2e'.
_snapshot_fail
_suites_npm_dir="$TMPDIR_FIXTURE/suites_npm_project"
mkdir -p "$_suites_npm_dir"
cat > "$_suites_npm_dir/package.json" <<'JSON'
{
  "name": "npm-test-app",
  "version": "1.0.0",
  "scripts": {
    "test:unit": "jest --testPathPattern=unit",
    "test:e2e": "jest --testPathPattern=e2e",
    "build": "tsc",
    "lint": "eslint ."
  }
}
JSON
_suites_npm_exit=0
_suites_npm_out=$(bash "$SCRIPT" --suites "$_suites_npm_dir" 2>&1) || _suites_npm_exit=$?
assert_eq "test_project_detect_suites_npm: exits 0" \
    "0" "$_suites_npm_exit"
# Validate npm entries via python3
_suites_npm_valid=$(python3 -c "
import sys, json
try:
    data = json.loads(sys.argv[1])
    names = {e['name'] for e in data}
    runners = {e['runner'] for e in data}
    commands = {e['command'] for e in data}
    errors = []
    if 'unit' not in names:
        errors.append('missing name=unit')
    if 'e2e' not in names:
        errors.append('missing name=e2e')
    if 'npm' not in runners:
        errors.append('missing runner=npm')
    if 'npm run test:unit' not in commands:
        errors.append('missing command=npm run test:unit')
    if 'npm run test:e2e' not in commands:
        errors.append('missing command=npm run test:e2e')
    if errors:
        print('invalid: ' + '; '.join(errors))
    else:
        print('valid')
except Exception as e:
    print('invalid: ' + str(e))
" "$_suites_npm_out" 2>&1)
assert_eq "test_project_detect_suites_npm: correct npm entries" \
    "valid" "$_suites_npm_valid"
assert_pass_if_clean "test_project_detect_suites_npm"

# test_project_detect_suites_bash_runner: fixture with executable test-hooks.sh
# in repo root -> JSON entry with runner=bash, name=hooks (strip 'test-' prefix
# and '.sh' suffix), command='bash test-hooks.sh'.
_snapshot_fail
_suites_bash_dir="$TMPDIR_FIXTURE/suites_bash_project"
mkdir -p "$_suites_bash_dir"
cat > "$_suites_bash_dir/test-hooks.sh" <<'BASH'
#!/usr/bin/env bash
echo "running hook tests"
BASH
chmod +x "$_suites_bash_dir/test-hooks.sh"
_suites_bash_exit=0
_suites_bash_out=$(bash "$SCRIPT" --suites "$_suites_bash_dir" 2>&1) || _suites_bash_exit=$?
assert_eq "test_project_detect_suites_bash_runner: exits 0" \
    "0" "$_suites_bash_exit"
# Validate bash runner entry via python3
_suites_bash_valid=$(python3 -c "
import sys, json
try:
    data = json.loads(sys.argv[1])
    found = [e for e in data if e.get('runner') == 'bash' and e.get('name') == 'hooks']
    if not found:
        print('invalid: no entry with runner=bash, name=hooks')
    elif found[0].get('command') != 'bash test-hooks.sh':
        print('invalid: command=' + str(found[0].get('command')) + ', expected bash test-hooks.sh')
    else:
        print('valid')
except Exception as e:
    print('invalid: ' + str(e))
" "$_suites_bash_out" 2>&1)
assert_eq "test_project_detect_suites_bash_runner: correct bash entry" \
    "valid" "$_suites_bash_valid"
assert_pass_if_clean "test_project_detect_suites_bash_runner"

# test_project_detect_suites_dedup_by_name: fixture with Makefile 'test-unit'
# target AND tests/unit/ pytest dir -> only ONE entry for name=unit emitted;
# Makefile (higher precedence) wins; runner=make.
_snapshot_fail
_suites_dedup_dir="$TMPDIR_FIXTURE/suites_dedup_project"
mkdir -p "$_suites_dedup_dir/tests/unit"
cat > "$_suites_dedup_dir/Makefile" <<'MAKEFILE'
.PHONY: test-unit

test-unit:
	pytest tests/unit/
MAKEFILE
cat > "$_suites_dedup_dir/tests/unit/test_example.py" <<'PY'
def test_placeholder():
    pass
PY
_suites_dedup_exit=0
_suites_dedup_out=$(bash "$SCRIPT" --suites "$_suites_dedup_dir" 2>&1) || _suites_dedup_exit=$?
assert_eq "test_project_detect_suites_dedup_by_name: exits 0" \
    "0" "$_suites_dedup_exit"
# Validate dedup: only ONE entry with name=unit, runner=make
_suites_dedup_valid=$(python3 -c "
import sys, json
try:
    data = json.loads(sys.argv[1])
    unit_entries = [e for e in data if e.get('name') == 'unit']
    errors = []
    if len(unit_entries) == 0:
        errors.append('no entry with name=unit')
    elif len(unit_entries) > 1:
        errors.append('duplicate: found %d entries with name=unit, expected 1' % len(unit_entries))
    else:
        if unit_entries[0].get('runner') != 'make':
            errors.append('runner=%s, expected make (Makefile has higher precedence)' % unit_entries[0].get('runner'))
    if errors:
        print('invalid: ' + '; '.join(errors))
    else:
        print('valid')
except Exception as e:
    print('invalid: ' + str(e))
" "$_suites_dedup_out" 2>&1)
assert_eq "test_project_detect_suites_dedup_by_name: one entry, runner=make" \
    "valid" "$_suites_dedup_valid"
assert_pass_if_clean "test_project_detect_suites_dedup_by_name"

# test_project_detect_suites_precedence_config_over_makefile: fixture with
# Makefile 'test-unit' AND config key test.suite.unit.command='custom-cmd'
# -> config entry wins; runner=config, command='custom-cmd'.
_snapshot_fail
_suites_prec_dir="$TMPDIR_FIXTURE/suites_precedence_project"
mkdir -p "$_suites_prec_dir/.claude"
cat > "$_suites_prec_dir/Makefile" <<'MAKEFILE'
.PHONY: test-unit

test-unit:
	pytest tests/unit/
MAKEFILE
cat > "$_suites_prec_dir/.claude/dso-config.conf" <<'CONF'
test.suite.unit.command=custom-cmd
CONF
_suites_prec_exit=0
_suites_prec_out=$(bash "$SCRIPT" --suites "$_suites_prec_dir" 2>&1) || _suites_prec_exit=$?
assert_eq "test_project_detect_suites_precedence_config_over_makefile: exits 0" \
    "0" "$_suites_prec_exit"
# Validate config precedence: runner=config, command=custom-cmd
_suites_prec_valid=$(python3 -c "
import sys, json
try:
    data = json.loads(sys.argv[1])
    unit_entries = [e for e in data if e.get('name') == 'unit']
    errors = []
    if len(unit_entries) == 0:
        errors.append('no entry with name=unit')
    elif len(unit_entries) > 1:
        errors.append('duplicate: found %d entries with name=unit, expected 1' % len(unit_entries))
    else:
        entry = unit_entries[0]
        if entry.get('runner') != 'config':
            errors.append('runner=%s, expected config' % entry.get('runner'))
        if entry.get('command') != 'custom-cmd':
            errors.append('command=%s, expected custom-cmd' % entry.get('command'))
    if errors:
        print('invalid: ' + '; '.join(errors))
    else:
        print('valid')
except Exception as e:
    print('invalid: ' + str(e))
" "$_suites_prec_out" 2>&1)
assert_eq "test_project_detect_suites_precedence_config_over_makefile: config wins" \
    "valid" "$_suites_prec_valid"
assert_pass_if_clean "test_project_detect_suites_precedence_config_over_makefile"

# test_project_detect_suites_bash_name_derivation: bash file 'run-tests-integration.sh'
# -> name='integration' (strip 'test-', 'run-tests-', leading 'test' variants,
# and '.sh' suffix).
_snapshot_fail
_suites_bash_derive_dir="$TMPDIR_FIXTURE/suites_bash_derivation_project"
mkdir -p "$_suites_bash_derive_dir"
cat > "$_suites_bash_derive_dir/run-tests-integration.sh" <<'BASH'
#!/usr/bin/env bash
echo "running integration tests"
BASH
chmod +x "$_suites_bash_derive_dir/run-tests-integration.sh"
_suites_bash_derive_exit=0
_suites_bash_derive_out=$(bash "$SCRIPT" --suites "$_suites_bash_derive_dir" 2>&1) || _suites_bash_derive_exit=$?
assert_eq "test_project_detect_suites_bash_name_derivation: exits 0" \
    "0" "$_suites_bash_derive_exit"
# Validate name derivation: name=integration
_suites_bash_derive_valid=$(python3 -c "
import sys, json
try:
    data = json.loads(sys.argv[1])
    found = [e for e in data if e.get('name') == 'integration']
    if not found:
        names = [e.get('name') for e in data]
        print('invalid: no entry with name=integration; found names: ' + str(names))
    elif found[0].get('runner') != 'bash':
        print('invalid: runner=%s, expected bash' % found[0].get('runner'))
    else:
        print('valid')
except Exception as e:
    print('invalid: ' + str(e))
" "$_suites_bash_derive_out" 2>&1)
assert_eq "test_project_detect_suites_bash_name_derivation: name=integration" \
    "valid" "$_suites_bash_derive_valid"
assert_pass_if_clean "test_project_detect_suites_bash_name_derivation"

# ── Named tests: config merge and fixture acceptance (T6 RED phase) ──────────

# test_project_detect_suites_config_merge: fixture with dso-config.conf containing
# test.suite.custom.command='bash run-custom.sh' and test.suite.custom.speed_class='fast';
# AND Makefile 'test-unit' target; config entry has runner=config, speed_class=fast;
# Makefile entry has speed_class=unknown.
_snapshot_fail
_suites_cfgmerge_dir="$TMPDIR_FIXTURE/suites_config_merge_project"
mkdir -p "$_suites_cfgmerge_dir/.claude"
cat > "$_suites_cfgmerge_dir/Makefile" <<'MAKEFILE'
.PHONY: test-unit

test-unit:
	pytest tests/unit/
MAKEFILE
cat > "$_suites_cfgmerge_dir/.claude/dso-config.conf" <<'CONF'
test.suite.custom.command=bash run-custom.sh
test.suite.custom.speed_class=fast
CONF
_suites_cfgmerge_exit=0
_suites_cfgmerge_out=$(bash "$SCRIPT" --suites "$_suites_cfgmerge_dir" 2>&1) || _suites_cfgmerge_exit=$?
assert_eq "test_project_detect_suites_config_merge: exits 0" \
    "0" "$_suites_cfgmerge_exit"
# Validate: config entry has runner=config, speed_class=fast; Makefile entry has speed_class=unknown
_suites_cfgmerge_valid=$(python3 -c "
import sys, json
try:
    data = json.loads(sys.argv[1])
    errors = []
    # Find the custom entry (from config)
    custom_entries = [e for e in data if e.get('name') == 'custom']
    if len(custom_entries) == 0:
        errors.append('no entry with name=custom')
    else:
        ce = custom_entries[0]
        if ce.get('runner') != 'config':
            errors.append('custom runner=%s, expected config' % ce.get('runner'))
        if ce.get('speed_class') != 'fast':
            errors.append('custom speed_class=%s, expected fast' % ce.get('speed_class'))
        if ce.get('command') != 'bash run-custom.sh':
            errors.append('custom command=%s, expected bash run-custom.sh' % ce.get('command'))
    # Find the unit entry (from Makefile)
    unit_entries = [e for e in data if e.get('name') == 'unit']
    if len(unit_entries) == 0:
        errors.append('no entry with name=unit')
    else:
        ue = unit_entries[0]
        if ue.get('speed_class') != 'unknown':
            errors.append('unit speed_class=%s, expected unknown' % ue.get('speed_class'))
    if errors:
        print('invalid: ' + '; '.join(errors))
    else:
        print('valid')
except Exception as e:
    print('invalid: ' + str(e))
" "$_suites_cfgmerge_out" 2>&1)
assert_eq "test_project_detect_suites_config_merge: correct entries" \
    "valid" "$_suites_cfgmerge_valid"
assert_pass_if_clean "test_project_detect_suites_config_merge"

# test_project_detect_suites_config_overrides_autodiscovered: fixture where
# dso-config.conf has test.suite.unit.command='custom-unit-cmd' AND Makefile
# 'test-unit' target; result has ONE entry for name=unit with command='custom-unit-cmd'
# (config wins) and runner=config.
_snapshot_fail
_suites_cfgoverride_dir="$TMPDIR_FIXTURE/suites_config_override_project"
mkdir -p "$_suites_cfgoverride_dir/.claude"
cat > "$_suites_cfgoverride_dir/Makefile" <<'MAKEFILE'
.PHONY: test-unit

test-unit:
	pytest tests/unit/
MAKEFILE
cat > "$_suites_cfgoverride_dir/.claude/dso-config.conf" <<'CONF'
test.suite.unit.command=custom-unit-cmd
CONF
_suites_cfgoverride_exit=0
_suites_cfgoverride_out=$(bash "$SCRIPT" --suites "$_suites_cfgoverride_dir" 2>&1) || _suites_cfgoverride_exit=$?
assert_eq "test_project_detect_suites_config_overrides_autodiscovered: exits 0" \
    "0" "$_suites_cfgoverride_exit"
# Validate: ONE entry for name=unit, command=custom-unit-cmd, runner=config
_suites_cfgoverride_valid=$(python3 -c "
import sys, json
try:
    data = json.loads(sys.argv[1])
    unit_entries = [e for e in data if e.get('name') == 'unit']
    errors = []
    if len(unit_entries) == 0:
        errors.append('no entry with name=unit')
    elif len(unit_entries) > 1:
        errors.append('duplicate: found %d entries with name=unit, expected 1' % len(unit_entries))
    else:
        entry = unit_entries[0]
        if entry.get('command') != 'custom-unit-cmd':
            errors.append('command=%s, expected custom-unit-cmd' % entry.get('command'))
        if entry.get('runner') != 'config':
            errors.append('runner=%s, expected config' % entry.get('runner'))
    if errors:
        print('invalid: ' + '; '.join(errors))
    else:
        print('valid')
except Exception as e:
    print('invalid: ' + str(e))
" "$_suites_cfgoverride_out" 2>&1)
assert_eq "test_project_detect_suites_config_overrides_autodiscovered: config wins" \
    "valid" "$_suites_cfgoverride_valid"
assert_pass_if_clean "test_project_detect_suites_config_overrides_autodiscovered"

# test_project_detect_suites_fixture_acceptance: full fixture per story Done
# Definition #4 — repo with Makefile 'test-unit' and 'test-e2e', a tests/models/
# dir with test_model.py, and config test.suite.custom.command='bash run-custom.sh';
# assert JSON output has exactly 4 entries (name: unit/make, e2e/make, models/pytest,
# custom/config); each entry has all required fields.
_snapshot_fail
_suites_accept_dir="$TMPDIR_FIXTURE/suites_acceptance_project"
mkdir -p "$_suites_accept_dir/.claude"
mkdir -p "$_suites_accept_dir/tests/models"
cat > "$_suites_accept_dir/Makefile" <<'MAKEFILE'
.PHONY: test-unit test-e2e lint format

test-unit:
	pytest tests/unit/

test-e2e:
	pytest tests/e2e/

lint:
	ruff check .

format:
	ruff format .
MAKEFILE
cat > "$_suites_accept_dir/tests/models/test_model.py" <<'PY'
def test_placeholder():
    pass
PY
cat > "$_suites_accept_dir/.claude/dso-config.conf" <<'CONF'
test.suite.custom.command=bash run-custom.sh
CONF
_suites_accept_exit=0
_suites_accept_out=$(bash "$SCRIPT" --suites "$_suites_accept_dir" 2>&1) || _suites_accept_exit=$?
assert_eq "test_project_detect_suites_fixture_acceptance: exits 0" \
    "0" "$_suites_accept_exit"
# Validate: exactly 4 entries with correct names, runners, and all required fields
_suites_accept_valid=$(python3 -c "
import sys, json
try:
    data = json.loads(sys.argv[1])
    errors = []
    # Must have exactly 4 entries
    if len(data) != 4:
        errors.append('expected 4 entries, got %d' % len(data))
    # Build lookup by name
    by_name = {}
    for e in data:
        by_name[e.get('name')] = e
    # Check required entries
    expected = {
        'unit': 'make',
        'e2e': 'make',
        'models': 'pytest',
        'custom': 'config',
    }
    for name, runner in expected.items():
        if name not in by_name:
            errors.append('missing entry name=%s' % name)
        else:
            entry = by_name[name]
            if entry.get('runner') != runner:
                errors.append('%s: runner=%s, expected %s' % (name, entry.get('runner'), runner))
            # All required fields present
            for field in ('name', 'command', 'speed_class', 'runner'):
                if field not in entry:
                    errors.append('%s: missing field %s' % (name, field))
    if errors:
        print('invalid: ' + '; '.join(errors))
    else:
        print('valid')
except Exception as e:
    print('invalid: ' + str(e))
" "$_suites_accept_out" 2>&1)
assert_eq "test_project_detect_suites_fixture_acceptance: 4 entries with correct fields" \
    "valid" "$_suites_accept_valid"
assert_pass_if_clean "test_project_detect_suites_fixture_acceptance"

# ── Named test: Usage header documents --suites flag (dso-gxct regression guard) ──

# test_project_detect_header_documents_suites: the script header comment must
# include --suites in its Usage line and describe it so future edits do not
# accidentally drop the flag from the documentation.
_snapshot_fail
_header_content=$(head -20 "$SCRIPT")
assert_contains "test_project_detect_header_documents_suites: Usage line includes --suites" \
    "--suites" "$_header_content"
assert_contains "test_project_detect_header_documents_suites: header describes --suites flag" \
    "discover test suites" "$_header_content"
assert_pass_if_clean "test_project_detect_header_documents_suites"

# ── Named tests: Confidence tagging — GREEN (db_confidence implemented) ──────
# db_confidence is implemented in this batch. These tests pass GREEN.

# test_confidence_tagging_db_inferred: code importing sqlalchemy, no docker-compose → db_confidence=inferred
_snapshot_fail
_conf_db_inferred_dir="$TMPDIR_FIXTURE/conf_db_inferred_project"
mkdir -p "$_conf_db_inferred_dir"
cat > "$_conf_db_inferred_dir/app.py" <<'PYTHON'
import sqlalchemy
from sqlalchemy import create_engine

engine = create_engine("postgresql://user:pass@localhost/db")
PYTHON
_conf_db_inferred_out=$(bash "$SCRIPT" "$_conf_db_inferred_dir" 2>&1)
assert_eq "test_confidence_tagging_db_inferred: db_confidence=inferred" \
    "inferred" "$(get_key "$_conf_db_inferred_out" db_confidence)"
assert_pass_if_clean "test_confidence_tagging_db_inferred"

# test_confidence_tagging_db_confirmed: docker-compose.yml with postgres image → db_confidence=confirmed
_snapshot_fail
_conf_db_confirmed_dir="$TMPDIR_FIXTURE/conf_db_confirmed_project"
mkdir -p "$_conf_db_confirmed_dir"
cat > "$_conf_db_confirmed_dir/docker-compose.yml" <<'YAML'
services:
  postgres:
    image: postgres:15
  app:
    image: myapp:latest
YAML
_conf_db_confirmed_out=$(bash "$SCRIPT" "$_conf_db_confirmed_dir" 2>&1)
assert_eq "test_confidence_tagging_db_confirmed: db_confidence=confirmed" \
    "confirmed" "$(get_key "$_conf_db_confirmed_out" db_confidence)"
assert_pass_if_clean "test_confidence_tagging_db_confirmed"

# test_confidence_tagging_db_none: empty project (no docker-compose, no Dockerfile, no
# Python imports, no .env) → db_confidence=none (the default; no DB signal present)
_snapshot_fail
_conf_db_none_dir="$TMPDIR_FIXTURE/conf_db_none_project"
mkdir -p "$_conf_db_none_dir"
_conf_db_none_out=$(bash "$SCRIPT" "$_conf_db_none_dir" 2>&1)
assert_eq "test_confidence_tagging_db_none: db_confidence=none" \
    "none" "$(get_key "$_conf_db_none_out" db_confidence)"
assert_pass_if_clean "test_confidence_tagging_db_none"

# ── Named tests: Docker/code-based DB detection (GREEN — implemented) ────────
# These tests cover DB detection beyond docker-compose.yml image line parsing.
# test_db_detection_docker_compose_regression: guard against regression in
# existing docker-compose.yml detection (should PASS now — tests existing behavior).
# Uses a service named 'postgres' so db_services reports the service name.
_snapshot_fail
_db_dc_regress_dir="$TMPDIR_FIXTURE/db_dc_regression_project"
mkdir -p "$_db_dc_regress_dir"
cat > "$_db_dc_regress_dir/docker-compose.yml" <<'YAML'
services:
  postgres:
    image: postgres:14
  redis:
    image: redis:7
  app:
    image: myapp:latest
YAML
_db_dc_regress_out=$(bash "$SCRIPT" "$_db_dc_regress_dir" 2>&1)
assert_eq "test_db_detection_docker_compose_regression: db_present=true" \
    "true" "$(get_key "$_db_dc_regress_out" db_present)"
assert_contains "test_db_detection_docker_compose_regression: db_services contains postgres" \
    "postgres" "$(get_key "$_db_dc_regress_out" db_services)"
assert_pass_if_clean "test_db_detection_docker_compose_regression"

# test_db_detection_dockerfile: db_present=true when Dockerfile contains FROM postgres:14
# RED test — project-detect.sh does not yet scan Dockerfile for DB base images.
_snapshot_fail
_db_dockerfile_dir="$TMPDIR_FIXTURE/db_dockerfile_project"
mkdir -p "$_db_dockerfile_dir"
cat > "$_db_dockerfile_dir/Dockerfile" <<'DOCKERFILE'
FROM postgres:14
ENV POSTGRES_DB=mydb
ENV POSTGRES_USER=user
ENV POSTGRES_PASSWORD=secret
DOCKERFILE
_db_dockerfile_out=$(bash "$SCRIPT" "$_db_dockerfile_dir" 2>&1)
assert_eq "test_db_detection_dockerfile: db_present=true" \
    "true" "$(get_key "$_db_dockerfile_out" db_present)"
assert_contains "test_db_detection_dockerfile: db_services contains postgres" \
    "postgres" "$(get_key "$_db_dockerfile_out" db_services)"
assert_pass_if_clean "test_db_detection_dockerfile"

# test_db_detection_app_code_import: db_present=true when app.py contains 'import psycopg2'
# RED test — project-detect.sh does not yet scan app code for DB library imports.
_snapshot_fail
_db_code_dir="$TMPDIR_FIXTURE/db_app_code_project"
mkdir -p "$_db_code_dir"
cat > "$_db_code_dir/app.py" <<'PYTHON'
import psycopg2
import os

conn = psycopg2.connect(os.environ["DATABASE_URL"])
PYTHON
_db_code_out=$(bash "$SCRIPT" "$_db_code_dir" 2>&1)
assert_eq "test_db_detection_app_code_import: db_present=true" \
    "true" "$(get_key "$_db_code_out" db_present)"
assert_pass_if_clean "test_db_detection_app_code_import"

# test_db_detection_env_file: db_present=true when .env contains DATABASE_URL=postgresql://...
# RED test — project-detect.sh does not yet scan .env files for DATABASE_URL.
_snapshot_fail
_db_env_dir="$TMPDIR_FIXTURE/db_env_file_project"
mkdir -p "$_db_env_dir"
cat > "$_db_env_dir/.env" <<'ENV'
DATABASE_URL=postgresql://user:secret@localhost:5432/mydb
SECRET_KEY=abc123
ENV
_db_env_out=$(bash "$SCRIPT" "$_db_env_dir" 2>&1)
assert_eq "test_db_detection_env_file: db_present=true" \
    "true" "$(get_key "$_db_env_out" db_present)"
assert_pass_if_clean "test_db_detection_env_file"

# ── Named tests: Confidence tagging — RED (not yet implemented) ──────────────
# These tests assert confidence fields that are NOT yet emitted by project-detect.sh.
# They will fail (RED) until task fc8b-2c87 implements the remaining confidence fields.

# test_confidence_tagging_stack_confirmed: pyproject.toml → stack_confidence=confirmed
_snapshot_fail
_conf_stack_dir="$TMPDIR_FIXTURE/conf_stack_project"
mkdir -p "$_conf_stack_dir"
printf '[build-system]\nrequires = ["setuptools"]\n' > "$_conf_stack_dir/pyproject.toml"
_conf_stack_out=$(bash "$SCRIPT" "$_conf_stack_dir" 2>&1)
assert_eq "test_confidence_tagging_stack_confirmed: stack_confidence=confirmed" \
    "confirmed" "$(get_key "$_conf_stack_out" stack_confidence)"
assert_pass_if_clean "test_confidence_tagging_stack_confirmed"

# test_confidence_tagging_targets_confirmed: Makefile with real targets → targets_confidence=confirmed
_snapshot_fail
_conf_targets_dir="$TMPDIR_FIXTURE/conf_targets_project"
mkdir -p "$_conf_targets_dir"
cat > "$_conf_targets_dir/Makefile" <<'MAKEFILE'
.PHONY: test lint format

test:
	pytest

lint:
	ruff check .

format:
	ruff format .
MAKEFILE
_conf_targets_out=$(bash "$SCRIPT" "$_conf_targets_dir" 2>&1)
assert_eq "test_confidence_tagging_targets_confirmed: targets_confidence=confirmed" \
    "confirmed" "$(get_key "$_conf_targets_out" targets_confidence)"
assert_pass_if_clean "test_confidence_tagging_targets_confirmed"

# test_confidence_tagging_files_present_confirmed: CLAUDE.md present → files_present_confidence=confirmed
_snapshot_fail
_conf_files_dir="$TMPDIR_FIXTURE/conf_files_present_project"
mkdir -p "$_conf_files_dir"
touch "$_conf_files_dir/CLAUDE.md"
_conf_files_out=$(bash "$SCRIPT" "$_conf_files_dir" 2>&1)
assert_eq "test_confidence_tagging_files_present_confirmed: files_present_confidence=confirmed" \
    "confirmed" "$(get_key "$_conf_files_out" files_present_confidence)"
assert_pass_if_clean "test_confidence_tagging_files_present_confirmed"

# test_confidence_tagging_installed_deps_confirmed: command -v detection → installed_deps_confidence=confirmed
_snapshot_fail
_conf_deps_dir="$TMPDIR_FIXTURE/conf_installed_deps_project"
mkdir -p "$_conf_deps_dir"
_conf_deps_out=$(bash "$SCRIPT" "$_conf_deps_dir" 2>&1)
assert_eq "test_confidence_tagging_installed_deps_confirmed: installed_deps_confidence=confirmed" \
    "confirmed" "$(get_key "$_conf_deps_out" installed_deps_confidence)"
assert_pass_if_clean "test_confidence_tagging_installed_deps_confirmed"

print_summary
