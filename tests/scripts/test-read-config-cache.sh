#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-read-config-cache.sh
# Tests for the flat-file caching layer in read-config.sh.
#
# Validates: --generate-cache, cache hit, cache miss, stale cache,
# config path mismatch, list mode from cache.
#
# Usage: bash lockpick-workflow/tests/scripts/test-read-config-cache.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/read-config.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# Resolve a Python with pyyaml (same logic as test-read-config.sh)
PYTHON=""
for candidate in \
    "$REPO_ROOT/app/.venv/bin/python3" \
    "$REPO_ROOT/.venv/bin/python3" \
    "python3"; do
    [[ "$candidate" != "python3" ]] && [[ ! -f "$candidate" ]] && continue
    if "$candidate" -c "import yaml" 2>/dev/null; then
        PYTHON="$candidate"
        break
    fi
done
if [[ -z "$PYTHON" ]]; then
    echo "Error: no python3 with pyyaml found" >&2
    exit 1
fi
export CLAUDE_PLUGIN_PYTHON="$PYTHON"

echo "=== test-read-config-cache.sh ==="

# Create isolated temp dir for fixtures and fake repo root
TMPDIR_FIXTURE="$(mktemp -d)"
mkdir -p "$TMPDIR_FIXTURE/fake-repo"
# Initialize a git repo so REPO_ROOT resolves
git -C "$TMPDIR_FIXTURE/fake-repo" init -q
# Use git rev-parse to get the canonical path (resolves macOS /var → /private/var symlinks)
FAKE_REPO=$(cd "$TMPDIR_FIXTURE/fake-repo" && git rev-parse --show-toplevel)

# Compute what the cache dir would be for the fake repo (matches _wcfg_cache_dir)
FAKE_HASH=$(echo -n "$FAKE_REPO" | shasum -a 256 | awk '{print $1}' | head -c 16)
CACHE_DIR="/tmp/workflow-plugin-${FAKE_HASH}"
CACHE_FILE="$CACHE_DIR/config-cache"

cleanup() {
    rm -rf "$TMPDIR_FIXTURE"
    rm -rf "$CACHE_DIR"
}
trap cleanup EXIT

# Write a fixture config in the fake repo
FIXTURE_CONFIG="$FAKE_REPO/workflow-config.yaml"
cat > "$FIXTURE_CONFIG" <<'YAML'
version: "1.0.0"
stack: python-poetry
commands:
  test: "make test"
  lint: "make lint"
  validate: "./scripts/validate.sh --ci"
format:
  extensions: ['.py', '.ts']
  source_dirs: ['app/src', 'app/tests']
empty_list: []
database:
  base_port: 5432
tickets:
  sync:
    bidirectional_comments: true
YAML

# Helper: run read-config.sh in the fake repo context
run_rc() {
    cd "$FAKE_REPO" && bash "$SCRIPT" "$@"
}

# ── test_generate_cache_creates_file ─────────────────────────────────────
_snapshot_fail
rm -f "$CACHE_FILE" 2>/dev/null || true
cd "$FAKE_REPO" && bash "$SCRIPT" --generate-cache "$FIXTURE_CONFIG"
if [[ -f "$CACHE_FILE" ]]; then
    actual="created"
else
    actual="missing"
fi
assert_eq "generate_cache creates file" "created" "$actual"
assert_pass_if_clean "test_generate_cache_creates_file"

# ── test_cache_has_header ────────────────────────────────────────────────
_snapshot_fail
header_version=$(head -1 "$CACHE_FILE")
assert_eq "cache header version" "# wcfg-cache v1" "$header_version"
header_config=$(sed -n 's/^# config=//p' "$CACHE_FILE" | head -1)
assert_eq "cache header config path" "$FIXTURE_CONFIG" "$header_config"
header_mtime=$(sed -n 's/^# mtime=//p' "$CACHE_FILE" | head -1)
assert_ne "cache header mtime non-empty" "" "$header_mtime"
assert_pass_if_clean "test_cache_has_header"

# ── test_cache_contains_scalar_keys ──────────────────────────────────────
_snapshot_fail
cached_test=$(grep "^commands.test=" "$CACHE_FILE" | head -1 | cut -d= -f2-)
assert_eq "cache scalar: commands.test" "make test" "$cached_test"
cached_validate=$(grep "^commands.validate=" "$CACHE_FILE" | head -1 | cut -d= -f2-)
assert_eq "cache scalar: commands.validate" "./scripts/validate.sh --ci" "$cached_validate"
cached_port=$(grep "^database.base_port=" "$CACHE_FILE" | head -1 | cut -d= -f2-)
assert_eq "cache scalar: database.base_port" "5432" "$cached_port"
assert_pass_if_clean "test_cache_contains_scalar_keys"

# ── test_cache_contains_list_keys ────────────────────────────────────────
_snapshot_fail
cached_ext0=$(grep "^format.extensions.0=" "$CACHE_FILE" | cut -d= -f2-)
assert_eq "cache list: format.extensions.0" ".py" "$cached_ext0"
cached_ext1=$(grep "^format.extensions.1=" "$CACHE_FILE" | cut -d= -f2-)
assert_eq "cache list: format.extensions.1" ".ts" "$cached_ext1"
assert_pass_if_clean "test_cache_contains_list_keys"

# ── test_cache_marks_empty_lists ─────────────────────────────────────────
_snapshot_fail
if grep -q "^empty_list.__empty_list=" "$CACHE_FILE" 2>/dev/null; then
    actual="marked"
else
    actual="unmarked"
fi
assert_eq "cache marks empty lists" "marked" "$actual"
assert_pass_if_clean "test_cache_marks_empty_lists"

# ── test_cache_hit_returns_correct_scalar ────────────────────────────────
_snapshot_fail
result=$(run_rc "$FIXTURE_CONFIG" commands.test 2>&1)
assert_eq "cache hit scalar" "make test" "$result"
assert_pass_if_clean "test_cache_hit_returns_correct_scalar"

# ── test_cache_hit_returns_correct_list ──────────────────────────────────
_snapshot_fail
result=$(run_rc --list format.extensions "$FIXTURE_CONFIG" 2>&1)
expected=".py
.ts"
assert_eq "cache hit list" "$expected" "$result"
assert_pass_if_clean "test_cache_hit_returns_correct_list"

# ── test_cache_hit_list_nested ───────────────────────────────────────────
_snapshot_fail
result=$(run_rc --list format.source_dirs "$FIXTURE_CONFIG" 2>&1)
expected="app/src
app/tests"
assert_eq "cache hit nested list" "$expected" "$result"
assert_pass_if_clean "test_cache_hit_list_nested"

# ── test_cache_hit_missing_key_scalar ────────────────────────────────────
_snapshot_fail
exit_code=0
result=$(run_rc "$FIXTURE_CONFIG" nonexistent.key 2>&1) || exit_code=$?
assert_eq "cache hit missing key: exit 0" "0" "$exit_code"
assert_eq "cache hit missing key: empty output" "" "$result"
assert_pass_if_clean "test_cache_hit_missing_key_scalar"

# ── test_stale_cache_regenerates ─────────────────────────────────────────
# Modify the config file, which changes its mtime
_snapshot_fail
sleep 1  # ensure mtime changes
cat > "$FIXTURE_CONFIG" <<'YAML'
version: "2.0.0"
commands:
  test: "make test-v2"
YAML
result=$(run_rc "$FIXTURE_CONFIG" commands.test 2>&1)
assert_eq "stale cache regenerates" "make test-v2" "$result"
assert_pass_if_clean "test_stale_cache_regenerates"

# ── test_deeply_nested_key ───────────────────────────────────────────────
# Restore fixture with nested keys
_snapshot_fail
cat > "$FIXTURE_CONFIG" <<'YAML'
tickets:
  sync:
    jira_project_key: DTL
    bidirectional_comments: true
YAML
rm -f "$CACHE_FILE" 2>/dev/null || true  # force regeneration
result=$(run_rc "$FIXTURE_CONFIG" tickets.sync.jira_project_key 2>&1)
assert_eq "deeply nested key" "DTL" "$result"
assert_pass_if_clean "test_deeply_nested_key"

# ── test_boolean_value ───────────────────────────────────────────────────
_snapshot_fail
result=$(run_rc "$FIXTURE_CONFIG" tickets.sync.bidirectional_comments 2>&1)
assert_eq "boolean value" "True" "$result"
assert_pass_if_clean "test_boolean_value"

print_summary
