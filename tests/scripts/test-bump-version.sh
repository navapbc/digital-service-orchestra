#!/usr/bin/env bash
# tests/scripts/test-bump-version.sh
# TDD tests for scripts/bump-version.sh
#
# Covers:
#   - All three file formats: .json (version key), .toml (version field), plaintext/no-extension
#   - No-config skip behavior (version.file_path not set → exits 0 with no changes)
#   - Correct pre/post version values for --patch, --minor, --major
#   - Malformed file error cases (exits non-zero)
#   - File does not exist error case (exits non-zero)
#
# Usage: bash tests/scripts/test-bump-version.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SCRIPT="$DSO_PLUGIN_DIR/scripts/bump-version.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-bump-version.sh ==="

# Create temp dir for fixture files
TMPDIR_FIXTURE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FIXTURE"' EXIT

# Helper: make a minimal workflow-config.conf in a temp dir with version.file_path set
make_conf_with_path() {
    local dir="$1"
    local version_file_path="$2"
    cat > "$dir/workflow-config.conf" <<CONF
# workflow-config.conf test fixture
version=1.0.0
version.file_path=$version_file_path
CONF
}

# Helper: make a workflow-config.conf without version.file_path
make_conf_no_path() {
    local dir="$1"
    cat > "$dir/workflow-config.conf" <<'CONF'
# workflow-config.conf test fixture — no version.file_path
version=1.0.0
CONF
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1: No-config skip behavior
# ─────────────────────────────────────────────────────────────────────────────

# test_no_config_skip: version.file_path not set → exits 0 with no changes
_snapshot_fail
CONF_DIR_NOPATH="$TMPDIR_FIXTURE/nopath"
mkdir -p "$CONF_DIR_NOPATH"
make_conf_no_path "$CONF_DIR_NOPATH"

rc=0
output=$(GIT_DIR=/dev/null bash "$SCRIPT" --patch --config "$CONF_DIR_NOPATH/workflow-config.conf" 2>&1) || rc=$?
assert_eq "test_no_config_skip exit" "0" "$rc"
assert_pass_if_clean "test_no_config_skip"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2: JSON format (.json extension)
# ─────────────────────────────────────────────────────────────────────────────

# test_json_patch_bump: 1.2.3 --patch → 1.2.4
_snapshot_fail
CONF_DIR_JSON="$TMPDIR_FIXTURE/json_patch"
mkdir -p "$CONF_DIR_JSON"
VERSION_FILE_JSON="$CONF_DIR_JSON/version.json"
cat > "$VERSION_FILE_JSON" <<'JSON'
{
  "name": "my-project",
  "version": "1.2.3"
}
JSON
make_conf_with_path "$CONF_DIR_JSON" "$VERSION_FILE_JSON"

bash "$SCRIPT" --patch --config "$CONF_DIR_JSON/workflow-config.conf"
result=$(python3 -c "import json; d=json.load(open('$VERSION_FILE_JSON')); print(d['version'])")
assert_eq "test_json_patch_bump version" "1.2.4" "$result"
assert_pass_if_clean "test_json_patch_bump"

# test_json_minor_bump: 1.2.3 --minor → 1.3.0
_snapshot_fail
CONF_DIR_JSON_MINOR="$TMPDIR_FIXTURE/json_minor"
mkdir -p "$CONF_DIR_JSON_MINOR"
VERSION_FILE_JSON_MINOR="$CONF_DIR_JSON_MINOR/version.json"
cat > "$VERSION_FILE_JSON_MINOR" <<'JSON'
{
  "version": "1.2.3"
}
JSON
make_conf_with_path "$CONF_DIR_JSON_MINOR" "$VERSION_FILE_JSON_MINOR"

bash "$SCRIPT" --minor --config "$CONF_DIR_JSON_MINOR/workflow-config.conf"
result=$(python3 -c "import json; d=json.load(open('$VERSION_FILE_JSON_MINOR')); print(d['version'])")
assert_eq "test_json_minor_bump version" "1.3.0" "$result"
assert_pass_if_clean "test_json_minor_bump"

# test_json_major_bump: 1.2.3 --major → 2.0.0
_snapshot_fail
CONF_DIR_JSON_MAJOR="$TMPDIR_FIXTURE/json_major"
mkdir -p "$CONF_DIR_JSON_MAJOR"
VERSION_FILE_JSON_MAJOR="$CONF_DIR_JSON_MAJOR/version.json"
cat > "$VERSION_FILE_JSON_MAJOR" <<'JSON'
{"version": "1.2.3", "extra": "field"}
JSON
make_conf_with_path "$CONF_DIR_JSON_MAJOR" "$VERSION_FILE_JSON_MAJOR"

bash "$SCRIPT" --major --config "$CONF_DIR_JSON_MAJOR/workflow-config.conf"
result=$(python3 -c "import json; d=json.load(open('$VERSION_FILE_JSON_MAJOR')); print(d['version'])")
assert_eq "test_json_major_bump version" "2.0.0" "$result"
# Other fields must not be corrupted
other=$(python3 -c "import json; d=json.load(open('$VERSION_FILE_JSON_MAJOR')); print(d['extra'])")
assert_eq "test_json_major_bump other_fields_preserved" "field" "$other"
assert_pass_if_clean "test_json_major_bump"

# test_json_malformed: malformed JSON → exits non-zero, file unchanged
_snapshot_fail
CONF_DIR_JSON_BAD="$TMPDIR_FIXTURE/json_bad"
mkdir -p "$CONF_DIR_JSON_BAD"
VERSION_FILE_JSON_BAD="$CONF_DIR_JSON_BAD/version.json"
printf 'NOT VALID JSON {{{' > "$VERSION_FILE_JSON_BAD"
original_content=$(cat "$VERSION_FILE_JSON_BAD")
make_conf_with_path "$CONF_DIR_JSON_BAD" "$VERSION_FILE_JSON_BAD"

rc=0
bash "$SCRIPT" --patch --config "$CONF_DIR_JSON_BAD/workflow-config.conf" 2>/dev/null || rc=$?
assert_ne "test_json_malformed exit" "0" "$rc"
after_content=$(cat "$VERSION_FILE_JSON_BAD")
assert_eq "test_json_malformed file_unchanged" "$original_content" "$after_content"
assert_pass_if_clean "test_json_malformed"

# test_json_missing_version_key: JSON without "version" key → exits non-zero
_snapshot_fail
CONF_DIR_JSON_NOKEY="$TMPDIR_FIXTURE/json_nokey"
mkdir -p "$CONF_DIR_JSON_NOKEY"
VERSION_FILE_JSON_NOKEY="$CONF_DIR_JSON_NOKEY/version.json"
printf '{"name": "test"}' > "$VERSION_FILE_JSON_NOKEY"
make_conf_with_path "$CONF_DIR_JSON_NOKEY" "$VERSION_FILE_JSON_NOKEY"

rc=0
bash "$SCRIPT" --patch --config "$CONF_DIR_JSON_NOKEY/workflow-config.conf" 2>/dev/null || rc=$?
assert_ne "test_json_missing_version_key exit" "0" "$rc"
assert_pass_if_clean "test_json_missing_version_key"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3: TOML format (.toml extension)
# ─────────────────────────────────────────────────────────────────────────────

# test_toml_patch_bump: 0.1.0 --patch → 0.1.1
_snapshot_fail
CONF_DIR_TOML="$TMPDIR_FIXTURE/toml_patch"
mkdir -p "$CONF_DIR_TOML"
VERSION_FILE_TOML="$CONF_DIR_TOML/version.toml"
cat > "$VERSION_FILE_TOML" <<'TOML'
[package]
name = "my-project"
version = "0.1.0"
TOML
make_conf_with_path "$CONF_DIR_TOML" "$VERSION_FILE_TOML"

bash "$SCRIPT" --patch --config "$CONF_DIR_TOML/workflow-config.conf"
result=$(grep '^version = ' "$VERSION_FILE_TOML" | head -1 | cut -d'"' -f2)
assert_eq "test_toml_patch_bump version" "0.1.1" "$result"
assert_pass_if_clean "test_toml_patch_bump"

# test_toml_minor_bump: 0.1.0 --minor → 0.2.0
_snapshot_fail
CONF_DIR_TOML_MINOR="$TMPDIR_FIXTURE/toml_minor"
mkdir -p "$CONF_DIR_TOML_MINOR"
VERSION_FILE_TOML_MINOR="$CONF_DIR_TOML_MINOR/version.toml"
cat > "$VERSION_FILE_TOML_MINOR" <<'TOML'
version = "0.1.0"
TOML
make_conf_with_path "$CONF_DIR_TOML_MINOR" "$VERSION_FILE_TOML_MINOR"

bash "$SCRIPT" --minor --config "$CONF_DIR_TOML_MINOR/workflow-config.conf"
result=$(grep '^version = ' "$VERSION_FILE_TOML_MINOR" | head -1 | cut -d'"' -f2)
assert_eq "test_toml_minor_bump version" "0.2.0" "$result"
assert_pass_if_clean "test_toml_minor_bump"

# test_toml_major_bump: 2.3.4 --major → 3.0.0
_snapshot_fail
CONF_DIR_TOML_MAJOR="$TMPDIR_FIXTURE/toml_major"
mkdir -p "$CONF_DIR_TOML_MAJOR"
VERSION_FILE_TOML_MAJOR="$CONF_DIR_TOML_MAJOR/version.toml"
cat > "$VERSION_FILE_TOML_MAJOR" <<'TOML'
[package]
version = "2.3.4"
description = "a project"
TOML
make_conf_with_path "$CONF_DIR_TOML_MAJOR" "$VERSION_FILE_TOML_MAJOR"

bash "$SCRIPT" --major --config "$CONF_DIR_TOML_MAJOR/workflow-config.conf"
result=$(grep '^version = ' "$VERSION_FILE_TOML_MAJOR" | head -1 | cut -d'"' -f2)
assert_eq "test_toml_major_bump version" "3.0.0" "$result"
# Other fields preserved
desc=$(grep 'description' "$VERSION_FILE_TOML_MAJOR")
assert_contains "test_toml_major_bump other_fields_preserved" "description" "$desc"
assert_pass_if_clean "test_toml_major_bump"

# test_toml_malformed: no version line → exits non-zero
_snapshot_fail
CONF_DIR_TOML_BAD="$TMPDIR_FIXTURE/toml_bad"
mkdir -p "$CONF_DIR_TOML_BAD"
VERSION_FILE_TOML_BAD="$CONF_DIR_TOML_BAD/version.toml"
cat > "$VERSION_FILE_TOML_BAD" <<'TOML'
[package]
name = "no-version-here"
TOML
original_content=$(cat "$VERSION_FILE_TOML_BAD")
make_conf_with_path "$CONF_DIR_TOML_BAD" "$VERSION_FILE_TOML_BAD"

rc=0
bash "$SCRIPT" --patch --config "$CONF_DIR_TOML_BAD/workflow-config.conf" 2>/dev/null || rc=$?
assert_ne "test_toml_malformed exit" "0" "$rc"
after_content=$(cat "$VERSION_FILE_TOML_BAD")
assert_eq "test_toml_malformed file_unchanged" "$original_content" "$after_content"
assert_pass_if_clean "test_toml_malformed"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4: Plaintext format (no extension / .txt)
# ─────────────────────────────────────────────────────────────────────────────

# test_plaintext_patch_bump: file with single semver line, no extension
_snapshot_fail
CONF_DIR_PLAIN="$TMPDIR_FIXTURE/plain_patch"
mkdir -p "$CONF_DIR_PLAIN"
VERSION_FILE_PLAIN="$CONF_DIR_PLAIN/VERSION"
printf '3.0.0\n' > "$VERSION_FILE_PLAIN"
make_conf_with_path "$CONF_DIR_PLAIN" "$VERSION_FILE_PLAIN"

bash "$SCRIPT" --patch --config "$CONF_DIR_PLAIN/workflow-config.conf"
result=$(cat "$VERSION_FILE_PLAIN")
assert_eq "test_plaintext_patch_bump version" "3.0.1" "$result"
assert_pass_if_clean "test_plaintext_patch_bump"

# test_plaintext_minor_bump: .txt extension
_snapshot_fail
CONF_DIR_TXT="$TMPDIR_FIXTURE/txt_minor"
mkdir -p "$CONF_DIR_TXT"
VERSION_FILE_TXT="$CONF_DIR_TXT/version.txt"
printf '0.5.0\n' > "$VERSION_FILE_TXT"
make_conf_with_path "$CONF_DIR_TXT" "$VERSION_FILE_TXT"

bash "$SCRIPT" --minor --config "$CONF_DIR_TXT/workflow-config.conf"
result=$(cat "$VERSION_FILE_TXT")
assert_eq "test_plaintext_minor_bump version" "0.6.0" "$result"
assert_pass_if_clean "test_plaintext_minor_bump"

# test_plaintext_major_bump: VERSION file (no extension)
_snapshot_fail
CONF_DIR_PLAIN_MAJOR="$TMPDIR_FIXTURE/plain_major"
mkdir -p "$CONF_DIR_PLAIN_MAJOR"
VERSION_FILE_PLAIN_MAJOR="$CONF_DIR_PLAIN_MAJOR/VERSION"
printf '1.9.9\n' > "$VERSION_FILE_PLAIN_MAJOR"
make_conf_with_path "$CONF_DIR_PLAIN_MAJOR" "$VERSION_FILE_PLAIN_MAJOR"

bash "$SCRIPT" --major --config "$CONF_DIR_PLAIN_MAJOR/workflow-config.conf"
result=$(cat "$VERSION_FILE_PLAIN_MAJOR")
assert_eq "test_plaintext_major_bump version" "2.0.0" "$result"
assert_pass_if_clean "test_plaintext_major_bump"

# test_plaintext_malformed: file content is not a semver → exits non-zero, file unchanged
_snapshot_fail
CONF_DIR_PLAIN_BAD="$TMPDIR_FIXTURE/plain_bad"
mkdir -p "$CONF_DIR_PLAIN_BAD"
VERSION_FILE_PLAIN_BAD="$CONF_DIR_PLAIN_BAD/VERSION"
printf 'not-a-version\n' > "$VERSION_FILE_PLAIN_BAD"
original_content=$(cat "$VERSION_FILE_PLAIN_BAD")
make_conf_with_path "$CONF_DIR_PLAIN_BAD" "$VERSION_FILE_PLAIN_BAD"

rc=0
bash "$SCRIPT" --patch --config "$CONF_DIR_PLAIN_BAD/workflow-config.conf" 2>/dev/null || rc=$?
assert_ne "test_plaintext_malformed exit" "0" "$rc"
after_content=$(cat "$VERSION_FILE_PLAIN_BAD")
assert_eq "test_plaintext_malformed file_unchanged" "$original_content" "$after_content"
assert_pass_if_clean "test_plaintext_malformed"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 5: File-not-found error case
# ─────────────────────────────────────────────────────────────────────────────

# test_file_not_found: version.file_path configured but file does not exist → exits non-zero
_snapshot_fail
CONF_DIR_MISSING="$TMPDIR_FIXTURE/missing_file"
mkdir -p "$CONF_DIR_MISSING"
NONEXISTENT_FILE="$CONF_DIR_MISSING/does_not_exist.json"
make_conf_with_path "$CONF_DIR_MISSING" "$NONEXISTENT_FILE"

rc=0
bash "$SCRIPT" --patch --config "$CONF_DIR_MISSING/workflow-config.conf" 2>/dev/null || rc=$?
assert_ne "test_file_not_found exit" "0" "$rc"
assert_pass_if_clean "test_file_not_found"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 6: Flag validation
# ─────────────────────────────────────────────────────────────────────────────

# test_no_flag: missing bump flag → exits non-zero
_snapshot_fail
CONF_DIR_NOFLAG="$TMPDIR_FIXTURE/noflag"
mkdir -p "$CONF_DIR_NOFLAG"
make_conf_no_path "$CONF_DIR_NOFLAG"

rc=0
bash "$SCRIPT" --config "$CONF_DIR_NOFLAG/workflow-config.conf" 2>/dev/null || rc=$?
assert_ne "test_no_flag exit" "0" "$rc"
assert_pass_if_clean "test_no_flag"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
print_summary
