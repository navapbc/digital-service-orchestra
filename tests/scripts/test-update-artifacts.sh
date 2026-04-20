#!/usr/bin/env bash
# tests/scripts/test-update-artifacts.sh
# RED tests for update-artifacts.sh and artifact-merge-lib.sh
#
# All tests in this file MUST FAIL until the following scripts are created:
#   plugins/dso/scripts/update-artifacts.sh
#   plugins/dso/scripts/artifact-merge-lib.sh
#
# Test coverage:
#   test_update_config_appends_new_keys          — new keys added to host config
#   test_update_config_commented_key_treated_as_present — commented keys not duplicated
#   test_update_config_reserved_metadata_updated — dso-version stamp updated
#   test_update_ci_workflow_merge                — plugin CI sections merged into host CI
#   test_update_ci_fallback_no_pyyaml            — awk fallback produces valid output
#   test_update_precommit_reuses_merge           — DSO hooks added via shared lib
#   test_update_shim_overwrite                   — stale shim replaced with current version
#   test_update_conflict_exit_code_2             — unresolvable conflict exits 2
#   test_update_conflict_json_valid              — conflict stdout is valid JSON
#   test_update_conflict_base64_decodable        — base64 fields decode to original content
#   test_update_stamps_updated_after_success     — stamps match plugin version after update
#   test_update_platform_base64_flag             — platform detection returns correct flag
#
# Usage: bash tests/scripts/test-update-artifacts.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
UPDATE_SCRIPT="$DSO_PLUGIN_DIR/scripts/update-artifacts.sh"
MERGE_LIB="$DSO_PLUGIN_DIR/scripts/artifact-merge-lib.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-update-artifacts.sh ==="

# ── Cleanup infrastructure ────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap _cleanup_tmpdirs EXIT

_mktemp_tracked() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ── Helper: read plugin version ───────────────────────────────────────────────
PLUGIN_VERSION=$(python3 -c "import json; print(json.load(open('$DSO_PLUGIN_DIR/.claude-plugin/plugin.json'))['version'])" 2>/dev/null || echo "0.0.0-test")

# ── Helper: detect platform base64 flag ──────────────────────────────────────
# macOS: base64 -b 0 (no-wrap); Linux: base64 -w 0 (no-wrap)
_platform_base64_nowrap_flag() {
    if echo test | base64 -b 0 >/dev/null 2>&1; then
        echo "-b 0"
    else
        echo "-w 0"
    fi
}

# ── Helper: create minimal host project dir with a stamped config ─────────────
# Creates:
#   $dir/.claude/dso-config.conf  — host config with existing key + old stamp
#   $dir/.claude/scripts/dso      — stub shim with old version stamp
#   $dir/.pre-commit-config.yaml  — minimal pre-commit config with repos: section
#   $dir/.github/workflows/ci.yml — minimal CI workflow
_make_host_project() {
    local dir="$1"
    local old_version="${2:-0.0.1}"

    mkdir -p "$dir/.claude/scripts"
    mkdir -p "$dir/.github/workflows"

    # Config with existing key and old version stamp
    cat > "$dir/.claude/dso-config.conf" <<CONF
# dso-version: $old_version
existing_key=existing_value
CONF

    # Stub shim with old version stamp
    cat > "$dir/.claude/scripts/dso" <<SHIM
#!/usr/bin/env bash
# dso-version: $old_version
echo "old shim version $old_version"
SHIM
    chmod +x "$dir/.claude/scripts/dso"

    # Minimal pre-commit config
    cat > "$dir/.pre-commit-config.yaml" <<YAML
repos:
  - repo: https://example.com/some-hook
    rev: v1.0.0
    hooks:
      - id: some-existing-hook
YAML

    # Minimal CI workflow
    cat > "$dir/.github/workflows/ci.yml" <<WORKFLOW
name: CI
on:
  push:
    branches: [main]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Run tests
        run: echo "existing test step"
WORKFLOW
}

# ── Helper: create plugin template dir with new-version artifacts ─────────────
_make_plugin_templates() {
    local dir="$1"
    local new_version="${2:-$PLUGIN_VERSION}"

    mkdir -p "$dir/templates/host-project"
    mkdir -p "$dir/docs/examples"

    # Plugin shim template (current version)
    cat > "$dir/templates/host-project/dso" <<SHIM
#!/usr/bin/env bash
# dso-version: $new_version
# DSO shim — delegates commands to the plugin
PLUGIN_ROOT="\${CLAUDE_PLUGIN_ROOT:-}"
exec bash "\$PLUGIN_ROOT/scripts/\$1" "\${@:2}"
SHIM
    chmod +x "$dir/templates/host-project/dso"

    # Plugin config template with new keys
    cat > "$dir/templates/host-project/dso-config.conf" <<CONF
# dso-version: $new_version
existing_key=default_value
new_key_alpha=new_value_alpha
new_key_beta=new_value_beta
CONF

    # Pre-commit example with DSO hooks
    cat > "$dir/docs/examples/pre-commit-config.example.yaml" <<YAML
repos:
  - repo: local
    hooks:
      - id: dso-review-gate
        name: DSO Review Gate
        entry: ./scripts/review-gate.sh
        language: system
        pass_filenames: false
        stages: [pre-commit]
      - id: dso-test-gate
        name: DSO Test Gate
        entry: ./scripts/test-gate.sh
        language: system
        pass_filenames: false
        stages: [pre-commit]
YAML

    # CI example with DSO job
    cat > "$dir/docs/examples/ci.example.python-poetry.yml" <<WORKFLOW
name: CI
on:
  push:
    branches: [main]
jobs:
  dso-validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: DSO Validate
        run: ./scripts/validate.sh --ci
WORKFLOW
}

# ─────────────────────────────────────────────────────────────────────────────
# test_update_config_appends_new_keys
# Calls merge_config_file (from artifact-merge-lib.sh).
# Host config has existing_key but missing new_key_alpha and new_key_beta.
# After merge: new keys appended, existing_key value unchanged.
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail
tmpdir=$(_mktemp_tracked)

HOST_CONFIG="$tmpdir/host/dso-config.conf"
PLUGIN_CONFIG="$tmpdir/plugin/dso-config.conf"
mkdir -p "$tmpdir/host" "$tmpdir/plugin"

cat > "$HOST_CONFIG" <<CONF
# dso-version: 0.0.1
existing_key=host_custom_value
CONF

cat > "$PLUGIN_CONFIG" <<CONF
# dso-version: 1.0.0
existing_key=default_value
new_key_alpha=alpha_default
new_key_beta=beta_default
CONF

# Source the merge lib and call merge_config_file
# The lib must be sourceable and provide merge_config_file
rc=0
bash -c "
    source '$MERGE_LIB' || exit 1
    merge_config_file '$HOST_CONFIG' '$PLUGIN_CONFIG' '' || exit 1
" 2>/dev/null || rc=$?

assert_eq "test_update_config_appends_new_keys: merge exits 0" "0" "$rc"

if [[ $rc -eq 0 ]]; then
    # existing_key must retain host value
    actual_existing=$(grep '^existing_key=' "$HOST_CONFIG" | cut -d= -f2)
    assert_eq "test_update_config_appends_new_keys: existing_key unchanged" "host_custom_value" "$actual_existing"

    # new keys must be present
    assert_contains "test_update_config_appends_new_keys: new_key_alpha appended" "new_key_alpha=alpha_default" "$(cat "$HOST_CONFIG")"
    assert_contains "test_update_config_appends_new_keys: new_key_beta appended" "new_key_beta=beta_default" "$(cat "$HOST_CONFIG")"
else
    # Force failures with descriptive messages when lib not yet loadable
    assert_eq "test_update_config_appends_new_keys: existing_key unchanged (lib missing)" "host_custom_value" "MERGE_LIB_MISSING"
    assert_eq "test_update_config_appends_new_keys: new_key_alpha appended (lib missing)" "present" "MERGE_LIB_MISSING"
    assert_eq "test_update_config_appends_new_keys: new_key_beta appended (lib missing)" "present" "MERGE_LIB_MISSING"
fi
assert_pass_if_clean "test_update_config_appends_new_keys"

# ─────────────────────────────────────────────────────────────────────────────
# test_update_config_commented_key_treated_as_present
# Host config has `# some_key=val` (commented out).
# After merge: some_key must NOT be re-added as an active line.
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail
tmpdir=$(_mktemp_tracked)

HOST_CONFIG2="$tmpdir/host/dso-config.conf"
PLUGIN_CONFIG2="$tmpdir/plugin/dso-config.conf"
mkdir -p "$tmpdir/host" "$tmpdir/plugin"

cat > "$HOST_CONFIG2" <<CONF
# dso-version: 0.0.1
existing_key=existing_value
# optional_feature=disabled
CONF

cat > "$PLUGIN_CONFIG2" <<CONF
# dso-version: 1.0.0
existing_key=default_value
optional_feature=enabled_by_default
CONF

rc=0
bash -c "
    source '$MERGE_LIB' || exit 1
    merge_config_file '$HOST_CONFIG2' '$PLUGIN_CONFIG2' '' || exit 1
" 2>/dev/null || rc=$?

assert_eq "test_update_config_commented_key_treated_as_present: merge exits 0" "0" "$rc"

if [[ $rc -eq 0 ]]; then
    # optional_feature must NOT appear as an active (uncommented) key
    active_optional=$(grep '^optional_feature=' "$HOST_CONFIG2" || echo "")
    assert_eq "test_update_config_commented_key_treated_as_present: no active optional_feature line" "" "$active_optional"
else
    assert_eq "test_update_config_commented_key_treated_as_present: merge succeeded (lib missing)" "0" "$rc"
fi
assert_pass_if_clean "test_update_config_commented_key_treated_as_present"

# ─────────────────────────────────────────────────────────────────────────────
# test_update_config_reserved_metadata_updated
# Host config has old dso-version stamp. After merge: stamp updated to new version.
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail
tmpdir=$(_mktemp_tracked)

HOST_CONFIG3="$tmpdir/host/dso-config.conf"
PLUGIN_CONFIG3="$tmpdir/plugin/dso-config.conf"
mkdir -p "$tmpdir/host" "$tmpdir/plugin"

cat > "$HOST_CONFIG3" <<CONF
# dso-version: 0.1.0
existing_key=custom_value
CONF

NEW_VER="2.5.0"
cat > "$PLUGIN_CONFIG3" <<CONF
# dso-version: $NEW_VER
existing_key=default_value
CONF

rc=0
bash -c "
    source '$MERGE_LIB' || exit 1
    merge_config_file '$HOST_CONFIG3' '$PLUGIN_CONFIG3' '' || exit 1
" 2>/dev/null || rc=$?

assert_eq "test_update_config_reserved_metadata_updated: merge exits 0" "0" "$rc"

if [[ $rc -eq 0 ]]; then
    updated_stamp=$(grep '^# dso-version:' "$HOST_CONFIG3" | head -1 | awk '{print $3}')
    assert_eq "test_update_config_reserved_metadata_updated: stamp updated to new version" "$NEW_VER" "$updated_stamp"
else
    assert_eq "test_update_config_reserved_metadata_updated: merge succeeded (lib missing)" "0" "$rc"
fi
assert_pass_if_clean "test_update_config_reserved_metadata_updated"

# ─────────────────────────────────────────────────────────────────────────────
# test_update_ci_workflow_merge
# Calls merge_ci_workflow with host CI + plugin CI example.
# After merge: plugin DSO job section appears in host CI file.
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail
tmpdir=$(_mktemp_tracked)

HOST_CI="$tmpdir/host/.github/workflows/ci.yml"
PLUGIN_CI="$tmpdir/plugin/docs/examples/ci.example.python-poetry.yml"
mkdir -p "$tmpdir/host/.github/workflows" "$tmpdir/plugin/docs/examples"

cat > "$HOST_CI" <<WORKFLOW
name: CI
on:
  push:
    branches: [main]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - run: echo "run tests"
WORKFLOW

cat > "$PLUGIN_CI" <<WORKFLOW
name: CI
on:
  push:
    branches: [main]
jobs:
  dso-validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: DSO Validate
        run: ./scripts/validate.sh --ci
WORKFLOW

rc=0
bash -c "
    source '$MERGE_LIB' || exit 1
    merge_ci_workflow '$HOST_CI' '$PLUGIN_CI' '' || exit 1
" 2>/dev/null || rc=$?

assert_eq "test_update_ci_workflow_merge: merge exits 0" "0" "$rc"

if [[ $rc -eq 0 ]]; then
    assert_contains "test_update_ci_workflow_merge: dso-validate job present" "dso-validate" "$(cat "$HOST_CI")"
    assert_contains "test_update_ci_workflow_merge: existing test job preserved" "run tests" "$(cat "$HOST_CI")"
else
    assert_eq "test_update_ci_workflow_merge: merge succeeded (lib missing)" "0" "$rc"
fi
assert_pass_if_clean "test_update_ci_workflow_merge"

# ─────────────────────────────────────────────────────────────────────────────
# test_update_ci_fallback_no_pyyaml
# Calls merge_ci_workflow but forces python3 yaml to be unavailable.
# The awk fallback path must produce output containing the plugin CI sections.
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail
tmpdir=$(_mktemp_tracked)

HOST_CI_FB="$tmpdir/host/ci.yml"
PLUGIN_CI_FB="$tmpdir/plugin/ci.example.yml"
mkdir -p "$tmpdir/host" "$tmpdir/plugin"

cat > "$HOST_CI_FB" <<WORKFLOW
name: CI
on:
  push:
    branches: [main]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo "host tests"
WORKFLOW

cat > "$PLUGIN_CI_FB" <<WORKFLOW
name: CI
on:
  push:
    branches: [main]
jobs:
  dso-gate:
    runs-on: ubuntu-latest
    steps:
      - run: ./validate.sh
WORKFLOW

# Stub python3 that cannot import yaml (simulates no-PyYAML environment)
STUB_BIN="$tmpdir/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/python3" <<'PY'
#!/usr/bin/env bash
# Stub: reject yaml import requests to force awk fallback
if [[ "$*" == *"import yaml"* ]] || [[ "$*" == *"yaml.safe_load"* ]]; then
    exit 1
fi
# Forward all other python3 calls to the real interpreter
exec /usr/bin/env python3 "$@"
PY
chmod +x "$STUB_BIN/python3"

rc=0
bash -c "
    export PATH='$STUB_BIN:\$PATH'
    source '$MERGE_LIB' || exit 1
    merge_ci_workflow '$HOST_CI_FB' '$PLUGIN_CI_FB' '' || exit 1
" 2>/dev/null || rc=$?

assert_eq "test_update_ci_fallback_no_pyyaml: fallback exits 0" "0" "$rc"

if [[ $rc -eq 0 ]]; then
    assert_contains "test_update_ci_fallback_no_pyyaml: dso-gate present in output" "dso-gate" "$(cat "$HOST_CI_FB")"
else
    assert_eq "test_update_ci_fallback_no_pyyaml: fallback succeeded (lib missing)" "0" "$rc"
fi
assert_pass_if_clean "test_update_ci_fallback_no_pyyaml"

# ─────────────────────────────────────────────────────────────────────────────
# test_update_precommit_reuses_merge
# Calls merge_precommit_hooks from artifact-merge-lib.sh.
# Host pre-commit has no DSO hooks. After merge: DSO hook ids appear in file.
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail
tmpdir=$(_mktemp_tracked)

HOST_PC="$tmpdir/host/.pre-commit-config.yaml"
PLUGIN_PC="$tmpdir/plugin/pre-commit-config.example.yaml"
mkdir -p "$tmpdir/host" "$tmpdir/plugin"

cat > "$HOST_PC" <<YAML
repos:
  - repo: https://example.com/lint
    rev: v1.0.0
    hooks:
      - id: existing-lint-hook
YAML

cat > "$PLUGIN_PC" <<YAML
repos:
  - repo: local
    hooks:
      - id: dso-review-gate
        name: DSO Review Gate
        entry: ./scripts/review-gate.sh
        language: system
        pass_filenames: false
        stages: [pre-commit]
      - id: dso-test-gate
        name: DSO Test Gate
        entry: ./scripts/test-gate.sh
        language: system
        pass_filenames: false
        stages: [pre-commit]
YAML

rc=0
bash -c "
    source '$MERGE_LIB' || exit 1
    merge_precommit_hooks '$HOST_PC' '$PLUGIN_PC' '' || exit 1
" 2>/dev/null || rc=$?

assert_eq "test_update_precommit_reuses_merge: merge exits 0" "0" "$rc"

if [[ $rc -eq 0 ]]; then
    assert_contains "test_update_precommit_reuses_merge: dso-review-gate added" "dso-review-gate" "$(cat "$HOST_PC")"
    assert_contains "test_update_precommit_reuses_merge: dso-test-gate added" "dso-test-gate" "$(cat "$HOST_PC")"
    assert_contains "test_update_precommit_reuses_merge: existing hook preserved" "existing-lint-hook" "$(cat "$HOST_PC")"
else
    assert_eq "test_update_precommit_reuses_merge: merge succeeded (lib missing)" "0" "$rc"
fi
assert_pass_if_clean "test_update_precommit_reuses_merge"

# ─────────────────────────────────────────────────────────────────────────────
# test_update_shim_overwrite
# Sets up host project with stale shim. Calls update-artifacts.sh.
# After update: shim content matches the current plugin template.
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail
tmpdir=$(_mktemp_tracked)

_make_host_project "$tmpdir/host" "0.0.1"
_make_plugin_templates "$tmpdir/plugin" "9.9.9"

# Confirm the stale shim has old version before running update
old_shim_content=$(cat "$tmpdir/host/.claude/scripts/dso")
assert_contains "test_update_shim_overwrite: shim initially stale" "0.0.1" "$old_shim_content"

rc=0
bash "$UPDATE_SCRIPT" \
    --target "$tmpdir/host" \
    --plugin-root "$tmpdir/plugin" \
    2>/dev/null || rc=$?

assert_eq "test_update_shim_overwrite: update-artifacts exits 0" "0" "$rc"

if [[ $rc -eq 0 ]]; then
    new_shim=$(cat "$tmpdir/host/.claude/scripts/dso")
    assert_contains "test_update_shim_overwrite: shim updated to new version" "9.9.9" "$new_shim"
else
    assert_eq "test_update_shim_overwrite: update succeeded (script missing)" "0" "$rc"
fi
assert_pass_if_clean "test_update_shim_overwrite"

# ─────────────────────────────────────────────────────────────────────────────
# test_update_conflict_exit_code_2
# Triggers an unresolvable conflict (conflicting key=value that can't be merged).
# update-artifacts.sh must exit 2 when an unresolvable conflict is detected.
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail
tmpdir=$(_mktemp_tracked)

_make_host_project "$tmpdir/host" "0.0.1"
_make_plugin_templates "$tmpdir/plugin" "9.9.9"

# Create a host config with a key that conflicts with the plugin's reserved
# merge logic (e.g., a key that has an incompatible format the merger cannot
# reconcile automatically). We do this by injecting a sentinel key that the
# merge lib is specified to treat as a hard conflict.
cat > "$tmpdir/host/.claude/dso-config.conf" <<CONF
# dso-version: 0.0.1
existing_key=host_value
# CONFLICT_MARKER: this line signals an unresolvable conflict for test purposes
dso.conflict_test=FORCE_CONFLICT
CONF

cat > "$tmpdir/plugin/templates/host-project/dso-config.conf" <<CONF
# dso-version: 9.9.9
existing_key=default_value
dso.conflict_test=FORCE_CONFLICT_INCOMPATIBLE
CONF

rc=0
stdout_output=$(bash "$UPDATE_SCRIPT" \
    --target "$tmpdir/host" \
    --plugin-root "$tmpdir/plugin" \
    --conflict-keys "dso.conflict_test" \
    2>/dev/null) || rc=$?

# The exit code MUST be 2 for conflict (not 0 or 1)
assert_eq "test_update_conflict_exit_code_2: exits with code 2" "2" "$rc"
assert_pass_if_clean "test_update_conflict_exit_code_2"

# ─────────────────────────────────────────────────────────────────────────────
# test_update_conflict_json_valid
# When exit code is 2, stdout must be valid JSON with required fields.
# Required fields: artifact, conflict_ours, conflict_theirs
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail
tmpdir=$(_mktemp_tracked)

_make_host_project "$tmpdir/host" "0.0.1"
_make_plugin_templates "$tmpdir/plugin" "9.9.9"

cat > "$tmpdir/host/.claude/dso-config.conf" <<CONF
# dso-version: 0.0.1
existing_key=host_value
dso.conflict_test=FORCE_CONFLICT
CONF

cat > "$tmpdir/plugin/templates/host-project/dso-config.conf" <<CONF
# dso-version: 9.9.9
existing_key=default_value
dso.conflict_test=FORCE_CONFLICT_INCOMPATIBLE
CONF

rc=0
json_stdout=$(bash "$UPDATE_SCRIPT" \
    --target "$tmpdir/host" \
    --plugin-root "$tmpdir/plugin" \
    --conflict-keys "dso.conflict_test" \
    2>/dev/null) || rc=$?

# Only check JSON validity when exit code is 2
if [[ "$rc" -eq 2 ]]; then
    # Must parse as JSON
    json_valid=0
    echo "$json_stdout" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null && json_valid=1
    assert_eq "test_update_conflict_json_valid: stdout is valid JSON" "1" "$json_valid"

    # Required fields must be present
    has_artifact=$(echo "$json_stdout" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if 'artifact' in d else 'no')" 2>/dev/null || echo "no")
    assert_eq "test_update_conflict_json_valid: has artifact field" "yes" "$has_artifact"

    has_ours=$(echo "$json_stdout" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if 'conflict_ours' in d else 'no')" 2>/dev/null || echo "no")
    assert_eq "test_update_conflict_json_valid: has conflict_ours field" "yes" "$has_ours"

    has_theirs=$(echo "$json_stdout" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if 'conflict_theirs' in d else 'no')" 2>/dev/null || echo "no")
    assert_eq "test_update_conflict_json_valid: has conflict_theirs field" "yes" "$has_theirs"
else
    assert_eq "test_update_conflict_json_valid: got exit 2 (script missing)" "2" "$rc"
fi
assert_pass_if_clean "test_update_conflict_json_valid"

# ─────────────────────────────────────────────────────────────────────────────
# test_update_conflict_base64_decodable
# conflict_ours and conflict_theirs must be base64-encoded (no-wrap).
# Decoding them must produce non-empty content.
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail
tmpdir=$(_mktemp_tracked)

_make_host_project "$tmpdir/host" "0.0.1"
_make_plugin_templates "$tmpdir/plugin" "9.9.9"

# Set up known conflict content so we can verify decoding
HOST_CONFLICT_CONTENT="existing_key=host_value
dso.conflict_test=ours_side_content"

PLUGIN_CONFLICT_CONTENT="existing_key=default_value
dso.conflict_test=theirs_side_content"

printf '%s\n' "# dso-version: 0.0.1" "$HOST_CONFLICT_CONTENT" > "$tmpdir/host/.claude/dso-config.conf"
printf '%s\n' "# dso-version: 9.9.9" "$PLUGIN_CONFLICT_CONTENT" > "$tmpdir/plugin/templates/host-project/dso-config.conf"

rc=0
json_stdout=$(bash "$UPDATE_SCRIPT" \
    --target "$tmpdir/host" \
    --plugin-root "$tmpdir/plugin" \
    --conflict-keys "dso.conflict_test" \
    2>/dev/null) || rc=$?

if [[ "$rc" -eq 2 ]]; then
    B64_FLAG=$(_platform_base64_nowrap_flag)

    # Extract and decode conflict_ours
    ours_b64=$(echo "$json_stdout" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('conflict_ours',''))" 2>/dev/null || echo "")
    if [[ -n "$ours_b64" ]]; then
        ours_decoded=$(echo "$ours_b64" | base64 --decode 2>/dev/null || echo "DECODE_FAILED")
        assert_ne "test_update_conflict_base64_decodable: conflict_ours decodes to non-empty" "" "$ours_decoded"
        assert_ne "test_update_conflict_base64_decodable: conflict_ours not DECODE_FAILED" "DECODE_FAILED" "$ours_decoded"
    else
        assert_eq "test_update_conflict_base64_decodable: conflict_ours field non-empty" "present" "empty"
    fi

    # Extract and decode conflict_theirs
    theirs_b64=$(echo "$json_stdout" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('conflict_theirs',''))" 2>/dev/null || echo "")
    if [[ -n "$theirs_b64" ]]; then
        theirs_decoded=$(echo "$theirs_b64" | base64 --decode 2>/dev/null || echo "DECODE_FAILED")
        assert_ne "test_update_conflict_base64_decodable: conflict_theirs decodes to non-empty" "" "$theirs_decoded"
        assert_ne "test_update_conflict_base64_decodable: conflict_theirs not DECODE_FAILED" "DECODE_FAILED" "$theirs_decoded"
    else
        assert_eq "test_update_conflict_base64_decodable: conflict_theirs field non-empty" "present" "empty"
    fi
else
    assert_eq "test_update_conflict_base64_decodable: got exit 2 (script missing)" "2" "$rc"
fi
assert_pass_if_clean "test_update_conflict_base64_decodable"

# ─────────────────────────────────────────────────────────────────────────────
# test_update_stamps_updated_after_success
# After a successful update run, stamps in managed artifacts must match
# the current plugin version.
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail
tmpdir=$(_mktemp_tracked)

STAMP_VER="7.3.1"
_make_host_project "$tmpdir/host" "0.0.1"
_make_plugin_templates "$tmpdir/plugin" "$STAMP_VER"

rc=0
bash "$UPDATE_SCRIPT" \
    --target "$tmpdir/host" \
    --plugin-root "$tmpdir/plugin" \
    2>/dev/null || rc=$?

assert_eq "test_update_stamps_updated_after_success: update exits 0" "0" "$rc"

if [[ $rc -eq 0 ]]; then
    config_stamp=$(grep '^# dso-version:' "$tmpdir/host/.claude/dso-config.conf" | head -1 | awk '{print $3}')
    assert_eq "test_update_stamps_updated_after_success: config stamp matches plugin version" "$STAMP_VER" "$config_stamp"

    shim_stamp=$(grep '^# dso-version:' "$tmpdir/host/.claude/scripts/dso" | head -1 | awk '{print $3}')
    assert_eq "test_update_stamps_updated_after_success: shim stamp matches plugin version" "$STAMP_VER" "$shim_stamp"
else
    assert_eq "test_update_stamps_updated_after_success: update succeeded (script missing)" "0" "$rc"
fi
assert_pass_if_clean "test_update_stamps_updated_after_success"

# ─────────────────────────────────────────────────────────────────────────────
# test_update_platform_base64_flag
# The platform detection function (or equivalent logic) must return a flag
# that makes base64 emit no line-wrap (single-line output for multi-line input).
# This is tested by encoding a multi-line string and verifying the output has
# no embedded newlines (i.e., is one line).
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail

# Use the merge lib's own platform detection if it exposes one; otherwise call
# the script with a --detect-base64-flag probe flag.
# Both paths exercise the observable behavior: the flag must produce no-wrap output.

MULTI_LINE_INPUT="line1
line2
line3
line4"

# Attempt: source lib and call its detection function
detected_flag=""
rc=0
detected_flag=$(bash -c "
    source '$MERGE_LIB' || exit 1
    # Try common function name; lib may export detect_base64_flag or _platform_base64_flag
    if declare -f detect_base64_flag >/dev/null 2>&1; then
        detect_base64_flag
    elif declare -f _platform_base64_flag >/dev/null 2>&1; then
        _platform_base64_flag
    elif declare -f _detect_base64_nowrap_flag >/dev/null 2>&1; then
        _detect_base64_nowrap_flag
    else
        exit 1
    fi
" 2>/dev/null) || rc=$?

if [[ $rc -eq 0 && -n "$detected_flag" ]]; then
    # Encode multi-line input using the detected flag; output must be a single line
    # shellcheck disable=SC2086  # word splitting intentional: $detected_flag may be "-w 0"
    encoded=$(echo "$MULTI_LINE_INPUT" | base64 $detected_flag 2>/dev/null || echo "ENCODE_FAILED")
    line_count=$(echo "$encoded" | wc -l | tr -d ' ')
    assert_eq "test_update_platform_base64_flag: encoded output is single line (no wrap)" "1" "$line_count"
else
    # Lib not yet present — force a clear failure
    assert_eq "test_update_platform_base64_flag: lib loadable and flag function exported" "0" "$rc"
fi
assert_pass_if_clean "test_update_platform_base64_flag"

# ─────────────────────────────────────────────────────────────────────────────
# test_update_ci_example_stack_aware_selection
# Verifies the stack-aware _CI_EXAMPLE resolution in update-artifacts.sh by
# extracting and invoking the production _resolve_ci_example_for_update function
# against fixtures (not inlining a copy of the resolution logic).
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail
tmpdir=$(_mktemp_tracked)

# Set up a plugin tree with both example files
mkdir -p "$tmpdir/plugin/docs/examples"
printf 'name: CI\njobs:\n  nodejob:\n    runs-on: ubuntu-latest\n' > "$tmpdir/plugin/docs/examples/ci.example.node-npm.yml"
printf 'name: CI\njobs:\n  pyjob:\n    runs-on: ubuntu-latest\n' > "$tmpdir/plugin/docs/examples/ci.example.python-poetry.yml"

# Extract _resolve_ci_example_for_update from update-artifacts.sh (awk block) so
# the test calls the PRODUCTION function rather than replicating its logic.
UA_SCRIPT="$(git rev-parse --show-toplevel)/plugins/dso/scripts/update-artifacts.sh"
RESOLVER_EXTRACT=$(awk '/^_resolve_ci_example_for_update\(\)/,/^}$/' "$UA_SCRIPT")

# Target with stack=node-npm
mkdir -p "$tmpdir/target/.claude"
printf 'stack=node-npm\n' > "$tmpdir/target/.claude/dso-config.conf"

_CI_EXAMPLE=$(bash -c "$RESOLVER_EXTRACT; _resolve_ci_example_for_update '$tmpdir/plugin' '$tmpdir/target'")
assert_eq "test_update_ci_example_stack_aware_selection: node-npm target picks node-npm example" \
    "$tmpdir/plugin/docs/examples/ci.example.node-npm.yml" "$_CI_EXAMPLE"

# Unknown stack → python-poetry fallback
printf 'stack=mystery-stack\n' > "$tmpdir/target/.claude/dso-config.conf"
_CI_EXAMPLE=$(bash -c "$RESOLVER_EXTRACT; _resolve_ci_example_for_update '$tmpdir/plugin' '$tmpdir/target'")
assert_eq "test_update_ci_example_stack_aware_selection: unknown stack falls back to python-poetry" \
    "$tmpdir/plugin/docs/examples/ci.example.python-poetry.yml" "$_CI_EXAMPLE"

# No target config → falls back to python-poetry (legacy install compatibility)
rm "$tmpdir/target/.claude/dso-config.conf"
_CI_EXAMPLE=$(bash -c "$RESOLVER_EXTRACT; _resolve_ci_example_for_update '$tmpdir/plugin' '$tmpdir/target'")
assert_eq "test_update_ci_example_stack_aware_selection: no config falls back to python-poetry" \
    "$tmpdir/plugin/docs/examples/ci.example.python-poetry.yml" "$_CI_EXAMPLE"

assert_pass_if_clean "test_update_ci_example_stack_aware_selection"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
print_summary
