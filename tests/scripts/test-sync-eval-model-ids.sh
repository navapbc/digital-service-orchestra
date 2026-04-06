#!/usr/bin/env bash
# tests/scripts/test-sync-eval-model-ids.sh
# Behavioral tests for plugins/dso/scripts/sync-eval-model-ids.sh — rewrites
# eval config (promptfooconfig.yaml) model IDs from dso-config.conf values.
#
# Tests:
#  1. test_replaces_haiku_model_id      — old haiku ID → new haiku from config
#  2. test_replaces_sonnet_model_id     — old sonnet ID → new sonnet from config
#  3. test_replaces_opus_model_id       — old opus ID (including undated) → new opus from config
#  4. test_handles_anthropic_prefix     — anthropic:messages:claude-* prefix replaced correctly
#  5. test_handles_bare_model_id        — bare claude-* in modelId field replaced correctly
#  6. test_respects_model_pin_marker    — lines with # model-pin are not modified
#  7. test_reports_file_count           — stdout mentions number of files updated
#
# Isolation:
#  - FIXTURE configs created in mktemp dirs (never reads real dso-config.conf)
#  - resolve-model-id.sh is STUBBED via PATH override for deterministic output
#  - WORKFLOW_CONFIG_FILE set to fixture config to prevent real config reads
#
# TDD: RED phase. Tests fail because sync-eval-model-ids.sh does not exist yet.
#
# Usage: bash tests/scripts/test-sync-eval-model-ids.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# REVIEW-DEFENSE: '-e' is intentionally omitted. The test harness captures
# non-zero exit codes from script invocations via || assignment. With '-e',
# expected non-zero exits would abort the script before assertions run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/sync-eval-model-ids.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-sync-eval-model-ids.sh ==="

# ── Global temp dir management ────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap '_cleanup' EXIT

_make_tmpdir() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ── Stub resolve-model-id.sh factory ─────────────────────────────────────────
# Creates a stub resolve-model-id.sh in a temp bin dir that echoes model IDs
# from the fixture config. Returns the path to the bin dir (caller prepends to PATH).
#
# Usage: _make_stub_bin <haiku_id> <sonnet_id> <opus_id>
_make_stub_bin() {
    local haiku_id="$1" sonnet_id="$2" opus_id="$3"
    local bin_dir
    bin_dir=$(_make_tmpdir)

    cat > "$bin_dir/resolve-model-id.sh" <<STUB
#!/usr/bin/env bash
# Stub resolve-model-id.sh for testing
tier="\${1:-}"
case "\$tier" in
    haiku)  printf '%s\n' "$haiku_id" ;;
    sonnet) printf '%s\n' "$sonnet_id" ;;
    opus)   printf '%s\n' "$opus_id" ;;
    *)      echo "Error: unknown tier '\$tier'" >&2; exit 1 ;;
esac
STUB
    chmod +x "$bin_dir/resolve-model-id.sh"

    # Also add a wrapper named 'resolve-model-id' in case the script calls without .sh extension
    cat > "$bin_dir/resolve-model-id" <<STUB
#!/usr/bin/env bash
exec "$bin_dir/resolve-model-id.sh" "\$@"
STUB
    chmod +x "$bin_dir/resolve-model-id"

    echo "$bin_dir"
}

# ── Fixture config factory ────────────────────────────────────────────────────
# Creates a dso-config.conf fixture with the given model IDs.
_make_fixture_config() {
    local dir="$1" haiku_id="$2" sonnet_id="$3" opus_id="$4"
    local conf_file="$dir/dso-config.conf"
    cat > "$conf_file" <<CONF
version=1.0
model.haiku=$haiku_id
model.sonnet=$sonnet_id
model.opus=$opus_id
CONF
    echo "$conf_file"
}

# ── test_replaces_haiku_model_id ──────────────────────────────────────────────
# A promptfooconfig.yaml containing an old haiku model ID must have that ID
# replaced with the new haiku model ID from dso-config.conf.
test_replaces_haiku_model_id() {
    _snapshot_fail
    local _dir _conf _bin_dir _eval_file _out _exit
    _dir=$(_make_tmpdir)
    _conf=$(_make_fixture_config "$_dir" \
        "claude-haiku-4-5-20251022" \
        "claude-sonnet-4-6-20260320" \
        "claude-opus-4-6-20260320")
    _bin_dir=$(_make_stub_bin \
        "claude-haiku-4-5-20251022" \
        "claude-sonnet-4-6-20260320" \
        "claude-opus-4-6-20260320")

    _eval_file="$_dir/promptfooconfig.yaml"
    cat > "$_eval_file" <<'YAML'
providers:
  - id: "anthropic:messages:claude-haiku-4-5-20251001"
    config:
      max_tokens: 1024
YAML

    _exit=0
    _out=$(PATH="$_bin_dir:$PATH" WORKFLOW_CONFIG_FILE="$_conf" \
        bash "$SCRIPT" "$_eval_file" 2>&1) || _exit=$?
    assert_eq "test_replaces_haiku_model_id: exits 0" "0" "$_exit"

    local _content
    _content=$(cat "$_eval_file")
    assert_contains "test_replaces_haiku_model_id: new haiku ID in file" \
        "claude-haiku-4-5-20251022" "$_content"
    # Old ID must be gone
    local _old_present=0
    [[ "$_content" == *"claude-haiku-4-5-20251001"* ]] && _old_present=1
    assert_eq "test_replaces_haiku_model_id: old haiku ID removed" "0" "$_old_present"
    assert_pass_if_clean "test_replaces_haiku_model_id"
}

# ── test_replaces_sonnet_model_id ─────────────────────────────────────────────
# A promptfooconfig.yaml containing an old sonnet model ID must have that ID
# replaced with the new sonnet model ID from dso-config.conf.
test_replaces_sonnet_model_id() {
    _snapshot_fail
    local _dir _conf _bin_dir _eval_file _out _exit
    _dir=$(_make_tmpdir)
    _conf=$(_make_fixture_config "$_dir" \
        "claude-haiku-4-5-20251022" \
        "claude-sonnet-4-6-20260320" \
        "claude-opus-4-6-20260320")
    _bin_dir=$(_make_stub_bin \
        "claude-haiku-4-5-20251022" \
        "claude-sonnet-4-6-20260320" \
        "claude-opus-4-6-20260320")

    _eval_file="$_dir/promptfooconfig.yaml"
    cat > "$_eval_file" <<'YAML'
providers:
  - id: "anthropic:messages:claude-sonnet-4-5-20251022"
    config:
      max_tokens: 4096
defaultTest:
  options:
    provider: "anthropic:messages:claude-sonnet-4-5"
YAML

    _exit=0
    _out=$(PATH="$_bin_dir:$PATH" WORKFLOW_CONFIG_FILE="$_conf" \
        bash "$SCRIPT" "$_eval_file" 2>&1) || _exit=$?
    assert_eq "test_replaces_sonnet_model_id: exits 0" "0" "$_exit"

    local _content
    _content=$(cat "$_eval_file")
    assert_contains "test_replaces_sonnet_model_id: new sonnet ID in file" \
        "claude-sonnet-4-6-20260320" "$_content"
    assert_pass_if_clean "test_replaces_sonnet_model_id"
}

# ── test_replaces_opus_model_id ───────────────────────────────────────────────
# A promptfooconfig.yaml containing an old opus model ID (including undated variants
# like claude-opus-4-5) must have that ID replaced with the new opus model ID.
test_replaces_opus_model_id() {
    _snapshot_fail
    local _dir _conf _bin_dir _eval_file _out _exit
    _dir=$(_make_tmpdir)
    _conf=$(_make_fixture_config "$_dir" \
        "claude-haiku-4-5-20251022" \
        "claude-sonnet-4-6-20260320" \
        "claude-opus-4-6-20260320")
    _bin_dir=$(_make_stub_bin \
        "claude-haiku-4-5-20251022" \
        "claude-sonnet-4-6-20260320" \
        "claude-opus-4-6-20260320")

    _eval_file="$_dir/promptfooconfig.yaml"
    # Include both dated and undated opus variants
    cat > "$_eval_file" <<'YAML'
providers:
  - id: "anthropic:messages:claude-opus-4-5"
    config:
      max_tokens: 8192
  - id: "anthropic:messages:claude-opus-4-5-20250101"
    config:
      max_tokens: 8192
YAML

    _exit=0
    _out=$(PATH="$_bin_dir:$PATH" WORKFLOW_CONFIG_FILE="$_conf" \
        bash "$SCRIPT" "$_eval_file" 2>&1) || _exit=$?
    assert_eq "test_replaces_opus_model_id: exits 0" "0" "$_exit"

    local _content
    _content=$(cat "$_eval_file")
    assert_contains "test_replaces_opus_model_id: new opus ID in file" \
        "claude-opus-4-6-20260320" "$_content"
    # Old undated opus must be gone
    local _old_undated=0
    [[ "$_content" == *"claude-opus-4-5\""* ]] && _old_undated=1
    assert_eq "test_replaces_opus_model_id: old undated opus ID removed" "0" "$_old_undated"
    assert_pass_if_clean "test_replaces_opus_model_id"
}

# ── test_handles_anthropic_prefix ─────────────────────────────────────────────
# Model IDs appearing with the anthropic:messages: prefix must be rewritten in-place,
# preserving the prefix and quoting style.
test_handles_anthropic_prefix() {
    _snapshot_fail
    local _dir _conf _bin_dir _eval_file _out _exit
    _dir=$(_make_tmpdir)
    _conf=$(_make_fixture_config "$_dir" \
        "claude-haiku-4-5-20251022" \
        "claude-sonnet-4-6-20260320" \
        "claude-opus-4-6-20260320")
    _bin_dir=$(_make_stub_bin \
        "claude-haiku-4-5-20251022" \
        "claude-sonnet-4-6-20260320" \
        "claude-opus-4-6-20260320")

    _eval_file="$_dir/promptfooconfig.yaml"
    cat > "$_eval_file" <<'YAML'
providers:
  - id: "anthropic:messages:claude-haiku-4-5-20251001"
defaultTest:
  options:
    provider: "anthropic:messages:claude-sonnet-4-6"
YAML

    _exit=0
    _out=$(PATH="$_bin_dir:$PATH" WORKFLOW_CONFIG_FILE="$_conf" \
        bash "$SCRIPT" "$_eval_file" 2>&1) || _exit=$?
    assert_eq "test_handles_anthropic_prefix: exits 0" "0" "$_exit"

    local _content
    _content=$(cat "$_eval_file")
    # The prefix should be preserved
    assert_contains "test_handles_anthropic_prefix: anthropic:messages: prefix preserved for haiku" \
        "anthropic:messages:claude-haiku-4-5-20251022" "$_content"
    assert_contains "test_handles_anthropic_prefix: anthropic:messages: prefix preserved for sonnet" \
        "anthropic:messages:claude-sonnet-4-6-20260320" "$_content"
    assert_pass_if_clean "test_handles_anthropic_prefix"
}

# ── test_handles_bare_model_id ────────────────────────────────────────────────
# Model IDs appearing in a bare claude-* context (e.g. modelId: claude-haiku-4-5-20251001)
# without the anthropic:messages: prefix must also be rewritten.
test_handles_bare_model_id() {
    _snapshot_fail
    local _dir _conf _bin_dir _eval_file _out _exit
    _dir=$(_make_tmpdir)
    _conf=$(_make_fixture_config "$_dir" \
        "claude-haiku-4-5-20251022" \
        "claude-sonnet-4-6-20260320" \
        "claude-opus-4-6-20260320")
    _bin_dir=$(_make_stub_bin \
        "claude-haiku-4-5-20251022" \
        "claude-sonnet-4-6-20260320" \
        "claude-opus-4-6-20260320")

    _eval_file="$_dir/promptfooconfig.yaml"
    cat > "$_eval_file" <<'YAML'
providers:
  - modelId: claude-haiku-4-5-20251001
    config:
      max_tokens: 1024
  - modelId: claude-sonnet-4-5
    config:
      max_tokens: 4096
YAML

    _exit=0
    _out=$(PATH="$_bin_dir:$PATH" WORKFLOW_CONFIG_FILE="$_conf" \
        bash "$SCRIPT" "$_eval_file" 2>&1) || _exit=$?
    assert_eq "test_handles_bare_model_id: exits 0" "0" "$_exit"

    local _content
    _content=$(cat "$_eval_file")
    assert_contains "test_handles_bare_model_id: new haiku ID in bare modelId field" \
        "claude-haiku-4-5-20251022" "$_content"
    assert_contains "test_handles_bare_model_id: new sonnet ID in bare modelId field" \
        "claude-sonnet-4-6-20260320" "$_content"
    assert_pass_if_clean "test_handles_bare_model_id"
}

# ── test_respects_model_pin_marker ────────────────────────────────────────────
# Lines containing the # model-pin comment marker must not be modified, even
# if they contain a model ID that would otherwise be replaced.
test_respects_model_pin_marker() {
    _snapshot_fail
    local _dir _conf _bin_dir _eval_file _out _exit
    _dir=$(_make_tmpdir)
    _conf=$(_make_fixture_config "$_dir" \
        "claude-haiku-4-5-20251022" \
        "claude-sonnet-4-6-20260320" \
        "claude-opus-4-6-20260320")
    _bin_dir=$(_make_stub_bin \
        "claude-haiku-4-5-20251022" \
        "claude-sonnet-4-6-20260320" \
        "claude-opus-4-6-20260320")

    _eval_file="$_dir/promptfooconfig.yaml"
    cat > "$_eval_file" <<'YAML'
providers:
  - id: "anthropic:messages:claude-haiku-4-5-20251001"  # model-pin
    config:
      max_tokens: 1024
  - id: "anthropic:messages:claude-sonnet-4-6"
    config:
      max_tokens: 4096
YAML

    _exit=0
    _out=$(PATH="$_bin_dir:$PATH" WORKFLOW_CONFIG_FILE="$_conf" \
        bash "$SCRIPT" "$_eval_file" 2>&1) || _exit=$?
    assert_eq "test_respects_model_pin_marker: exits 0" "0" "$_exit"

    local _content
    _content=$(cat "$_eval_file")
    # Pinned line: old haiku ID must remain
    assert_contains "test_respects_model_pin_marker: pinned haiku ID preserved" \
        "claude-haiku-4-5-20251001" "$_content"
    # Non-pinned line: sonnet must be updated
    assert_contains "test_respects_model_pin_marker: non-pinned sonnet ID updated" \
        "claude-sonnet-4-6-20260320" "$_content"
    assert_pass_if_clean "test_respects_model_pin_marker"
}

# ── test_reports_file_count ───────────────────────────────────────────────────
# When given multiple files, the script's output must mention the number of files
# that were updated (e.g. "2 file(s)" or "updated 2").
test_reports_file_count() {
    _snapshot_fail
    local _dir _conf _bin_dir _eval_file1 _eval_file2 _out _exit
    _dir=$(_make_tmpdir)
    _conf=$(_make_fixture_config "$_dir" \
        "claude-haiku-4-5-20251022" \
        "claude-sonnet-4-6-20260320" \
        "claude-opus-4-6-20260320")
    _bin_dir=$(_make_stub_bin \
        "claude-haiku-4-5-20251022" \
        "claude-sonnet-4-6-20260320" \
        "claude-opus-4-6-20260320")

    # Create two eval config files that both need updating
    _eval_file1="$_dir/eval1/promptfooconfig.yaml"
    mkdir -p "$_dir/eval1"
    cat > "$_eval_file1" <<'YAML'
providers:
  - id: "anthropic:messages:claude-haiku-4-5-20251001"
YAML

    _eval_file2="$_dir/eval2/promptfooconfig.yaml"
    mkdir -p "$_dir/eval2"
    cat > "$_eval_file2" <<'YAML'
providers:
  - id: "anthropic:messages:claude-sonnet-4-6"
YAML

    _exit=0
    _out=$(PATH="$_bin_dir:$PATH" WORKFLOW_CONFIG_FILE="$_conf" \
        bash "$SCRIPT" "$_eval_file1" "$_eval_file2" 2>&1) || _exit=$?
    assert_eq "test_reports_file_count: exits 0" "0" "$_exit"

    # Output must mention "2" as the file count (updated/processed)
    assert_contains "test_reports_file_count: output mentions file count '2'" "2" "$_out"
    assert_pass_if_clean "test_reports_file_count"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_replaces_haiku_model_id
test_replaces_sonnet_model_id
test_replaces_opus_model_id
test_handles_anthropic_prefix
test_handles_bare_model_id
test_respects_model_pin_marker
test_reports_file_count

print_summary
