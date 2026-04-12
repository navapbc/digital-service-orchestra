#!/usr/bin/env bash
# tests/scripts/test-model-id-lint.sh
# Behavioral tests for check-model-id-lint.sh — detects hardcoded Claude model
# IDs in plugins/dso/ source files.
#
# Tests:
#  1. test_detects_haiku_model_id   — file with claude-haiku-4-5-20251001 → exit != 0
#  2. test_detects_sonnet_model_id  — file with claude-sonnet-4-6 → exit != 0
#  3. test_excludes_dso_config_conf — dso-config.conf excluded from scan → exit 0
#  4. test_excludes_test_index      — .test-index excluded from scan → exit 0
#  5. test_excludes_tests_dir       — tests/ directory excluded from scan → exit 0
#  6. test_passes_clean_file        — file without hardcoded model IDs → exit 0
#
# TDD: RED phase. Tests fail because check-model-id-lint.sh does not yet exist.
#
# Usage: bash tests/scripts/test-model-id-lint.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# REVIEW-DEFENSE: '-e' is intentionally omitted. The test harness captures
# non-zero exit codes from script invocations via || assignment. With '-e',
# expected non-zero exits would abort the script before assertions run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/check-model-id-lint.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-model-id-lint.sh ==="

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

# ── test_detects_haiku_model_id ───────────────────────────────────────────────
# A file inside plugins/dso/ containing a hardcoded claude-haiku-4-5-20251001
# model ID must cause the script to exit non-zero and report the violation.
test_detects_haiku_model_id() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    mkdir -p "$_dir/plugins/dso/evals"
    _file="$_dir/plugins/dso/evals/my-eval.yaml"
    printf 'provider: anthropic:messages:claude-haiku-4-5-20251001\nmodel: claude-haiku-4-5-20251001\n' > "$_file"
    _exit=0
    _out=$(bash "$SCRIPT" --scan-dir "$_dir/plugins/dso" "$_file" 2>&1) || _exit=$?
    assert_ne "test_detects_haiku_model_id: exit non-zero for hardcoded haiku model ID" "0" "$_exit"
    assert_pass_if_clean "test_detects_haiku_model_id"
}

# ── test_detects_sonnet_model_id ─────────────────────────────────────────────
# A file inside plugins/dso/ containing a hardcoded claude-sonnet-4-6 model ID
# must cause the script to exit non-zero and report the violation.
test_detects_sonnet_model_id() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    mkdir -p "$_dir/plugins/dso/scripts"
    _file="$_dir/plugins/dso/scripts/my-script.sh"
    printf '#!/usr/bin/env bash\nMODEL="claude-sonnet-4-6"\n' > "$_file"
    _exit=0
    _out=$(bash "$SCRIPT" --scan-dir "$_dir/plugins/dso" "$_file" 2>&1) || _exit=$?
    assert_ne "test_detects_sonnet_model_id: exit non-zero for hardcoded sonnet model ID" "0" "$_exit"
    assert_pass_if_clean "test_detects_sonnet_model_id"
}

# ── test_excludes_dso_config_conf ─────────────────────────────────────────────
# dso-config.conf is the canonical location for model ID configuration — it is
# intentionally excluded from the scan so the centralized definition does not
# trigger a violation.
test_excludes_dso_config_conf() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    # Place dso-config.conf INSIDE the scanned tree so the test verifies
    # name-based exclusion, not just filesystem boundary.
    mkdir -p "$_dir/plugins/dso/.claude"
    _file="$_dir/plugins/dso/.claude/dso-config.conf"
    printf 'model.haiku=claude-haiku-4-5-20251001\nmodel.sonnet=claude-sonnet-4-6\n' > "$_file"
    _exit=0
    _out=$(bash "$SCRIPT" --scan-dir "$_dir/plugins/dso" 2>&1) || _exit=$?
    assert_eq "test_excludes_dso_config_conf: dso-config.conf does not trigger violation" "0" "$_exit"
    assert_pass_if_clean "test_excludes_dso_config_conf"
}

# ── test_excludes_test_index ──────────────────────────────────────────────────
# .test-index may contain model ID strings in comments and source→test mappings.
# It is excluded from the scan because it is generated metadata, not user code.
test_excludes_test_index() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    # Place .test-index INSIDE the scanned tree so the test verifies
    # name-based exclusion, not just filesystem boundary.
    # REVIEW-DEFENSE: _file is set to $_dir/plugins/dso/.test-index, which is
    # inside the --scan-dir tree ($dir/plugins/dso). The script receives no
    # explicit file path argument here — only --scan-dir. A file-system boundary
    # exclusion would pass trivially; this placement proves the exclusion is
    # name-based (i.e., the script skips files named ".test-index" regardless
    # of where they appear within the scanned tree).
    mkdir -p "$_dir/plugins/dso"
    _file="$_dir/plugins/dso/.test-index"
    printf '# Model ID references for TDD tracking\nplugins/dso/evals:tests/scripts/test-model-id-lint.sh\n' > "$_file"
    printf 'provider: claude-haiku-4-5-20251001\n' >> "$_file"
    _exit=0
    _out=$(bash "$SCRIPT" --scan-dir "$_dir/plugins/dso" 2>&1) || _exit=$?
    assert_eq "test_excludes_test_index: .test-index does not trigger violation" "0" "$_exit"
    assert_pass_if_clean "test_excludes_test_index"
}

# ── test_excludes_tests_dir ───────────────────────────────────────────────────
# The tests/ directory contains fixture files that legitimately reference model
# IDs for testing purposes. The scan must exclude tests/ to avoid false positives.
test_excludes_tests_dir() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    # Place the fixture INSIDE plugins/dso/tests/ so the test verifies that
    # the tests/ exclusion pattern applies within the scanned tree, not just
    # that files outside --scan-dir are not found.
    mkdir -p "$_dir/plugins/dso/tests/fixtures"
    _file="$_dir/plugins/dso/tests/fixtures/eval-fixture.yaml"
    printf 'model: claude-sonnet-4-6\nprovider: claude-haiku-4-5-20251001\n' > "$_file"
    _exit=0
    _out=$(bash "$SCRIPT" --scan-dir "$_dir/plugins/dso" 2>&1) || _exit=$?
    assert_eq "test_excludes_tests_dir: tests/ directory does not trigger violation" "0" "$_exit"
    assert_pass_if_clean "test_excludes_tests_dir"
}

# ── test_passes_clean_file ────────────────────────────────────────────────────
# A file inside plugins/dso/ that references model IDs only via config variables
# (not hardcoded strings) must cause the script to exit 0.
test_passes_clean_file() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    mkdir -p "$_dir/plugins/dso/scripts"
    _file="$_dir/plugins/dso/scripts/clean-script.sh"
    printf '#!/usr/bin/env bash\n# Uses model from config, not hardcoded\nMODEL="$(_cfg model.haiku)"\necho "Using model: $MODEL"\n' > "$_file"
    _exit=0
    _out=$(bash "$SCRIPT" --scan-dir "$_dir/plugins/dso" 2>&1) || _exit=$?
    assert_eq "test_passes_clean_file: clean file exits 0" "0" "$_exit"
    assert_pass_if_clean "test_passes_clean_file"
}

# ── test_completes_within_timeout ────────────────────────────────────────────
# Scanning the full plugins/dso/ tree must complete in under 30 seconds.
# This guards against per-file grep loops that time out at the 60s validate.sh
# TIMEOUT_SYNTAX budget (bug 9dea-99b1: serial grep loop took > 60s for 400+ files).
test_completes_within_timeout() {
    _snapshot_fail
    local _start _elapsed _exit
    # Only run if the plugins/dso/ tree exists (i.e., running from the repo)
    if [[ ! -d "$PLUGIN_ROOT/plugins/dso" ]]; then
        echo "test_completes_within_timeout: SKIP (no plugins/dso/ tree found)" >&2
        assert_pass_if_clean "test_completes_within_timeout"
        return
    fi
    _start=$SECONDS
    _exit=0
    bash "$SCRIPT" 2>/dev/null || _exit=$?
    _elapsed=$(( SECONDS - _start ))
    # The check must exit within 30 seconds (well under the 60s validate.sh budget)
    assert_eq "test_completes_within_timeout: scan completes in < 30s (took ${_elapsed}s)" "0" "$(( _elapsed >= 30 ? 1 : 0 ))"
    assert_pass_if_clean "test_completes_within_timeout"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_detects_haiku_model_id
test_detects_sonnet_model_id
test_excludes_dso_config_conf
test_excludes_test_index
test_excludes_tests_dir
test_passes_clean_file
test_completes_within_timeout

print_summary
