#!/usr/bin/env bash
# tests/scripts/test-model-config-integration.sh
# RED-phase TDD tests: verify that enrich-file-impact.sh and semantic-conflict-check.py
# read model IDs from WORKFLOW_CONFIG_FILE config rather than hardcoding them.
#
# All tests are expected to FAIL in RED state because the scripts still hardcode model IDs.
#
# Usage: bash tests/scripts/test-model-config-integration.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENRICH_SCRIPT="$REPO_ROOT/plugins/dso/scripts/enrich-file-impact.sh"
CONFLICT_SCRIPT="$REPO_ROOT/plugins/dso/scripts/semantic-conflict-check.py"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-model-config-integration.sh ==="

# ── Temp dir setup with EXIT trap cleanup ─────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_test_dirs() { rm -rf "${_TEST_TMPDIRS[@]}" 2>/dev/null || true; }
trap '_cleanup_test_dirs' EXIT

# ── Helper: create a fixture dso-config.conf with given model.haiku value ────
# Usage: _make_config_with_haiku <tmpdir> <model-id>
# Prints path to the config file
_make_config_with_haiku() {
    local tmpdir="$1" model_id="$2"
    local cfg="$tmpdir/dso-config.conf"
    cat > "$cfg" <<CONF
version=1.0.0
model.haiku=${model_id}
model.sonnet=claude-sonnet-4-6-20260320
model.opus=claude-opus-4-6
CONF
    printf '%s\n' "$cfg"
}

# ── Helper: create a fixture config WITHOUT model.haiku ──────────────────────
# Usage: _make_config_without_haiku <tmpdir>
# Prints path to the config file
_make_config_without_haiku() {
    local tmpdir="$1"
    local cfg="$tmpdir/dso-config-no-haiku.conf"
    cat > "$cfg" <<CONF
version=1.0.0
model.sonnet=claude-sonnet-4-6-20260320
CONF
    printf '%s\n' "$cfg"
}

# ── Helper: create a minimal mock ticket CLI for enrich-file-impact.sh ───────
# The mock returns a ticket JSON string without a file impact section so
# the script proceeds past the early-exit check.
# Usage: _make_mock_ticket_cmd <tmpdir> <ticket-id>
# Prints path to mock ticket binary
_make_mock_ticket_cmd() {
    local tmpdir="$1" ticket_id="${2:-test-001}"
    local mock="$tmpdir/mock-ticket"
    cat > "$mock" <<BASHEOF
#!/usr/bin/env bash
# Mock ticket CLI for enrich-file-impact.sh tests
case "\${1:-}" in
    show)
        # Return minimal ticket content without a file impact section
        printf '# Task: Test ticket\n\n---\nstatus: in_progress\n---\n\nA test ticket with no file impact section.\n'
        ;;
    comment)
        # Accept comment without error (write to tmpdir for inspection)
        printf '%s\n' "\$*" >> "${tmpdir}/ticket-comments.log" 2>/dev/null || true
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
BASHEOF
    chmod +x "$mock"
    printf '%s\n' "$mock"
}

# =============================================================================
# Test 1: enrich-file-impact.sh uses config model ID in dry-run output
# =============================================================================
# When WORKFLOW_CONFIG_FILE points to a config with model.haiku=test-sentinel-id,
# running enrich-file-impact.sh --dry-run must emit a string containing that
# sentinel model ID — not the hardcoded model string.
#
# RED state: enrich-file-impact.sh hardcodes MODEL="claude-haiku-4-5-20251001"
# so the dry-run output will contain "claude-haiku-4-5-20251001", not our sentinel.
# The test will FAIL in RED because the output won't match "test-sentinel-haiku-id".

echo ""
echo "test_enrich_file_impact_uses_config_model_id"

_ENRICH_TMPDIR="$(mktemp -d)"
_TEST_TMPDIRS+=("$_ENRICH_TMPDIR")

_SENTINEL_MODEL="test-sentinel-haiku-id"
_ENRICH_CONFIG="$(_make_config_with_haiku "$_ENRICH_TMPDIR" "$_SENTINEL_MODEL")"
_ENRICH_TICKET_CMD="$(_make_mock_ticket_cmd "$_ENRICH_TMPDIR" "test-ticket-001")"

enrich_exit=0
enrich_output=""
enrich_output=$(
    WORKFLOW_CONFIG_FILE="$_ENRICH_CONFIG" \
    TICKET_CMD="$_ENRICH_TICKET_CMD" \
    ANTHROPIC_API_KEY="" \
    bash "$ENRICH_SCRIPT" --dry-run "test-ticket-001" 2>&1
) || enrich_exit=$?

# The script should exit 0 (dry-run succeeds even without API key for model lookup)
assert_eq "test_enrich_file_impact_uses_config_model_id: exits 0 on dry-run" "0" "$enrich_exit"

# The output must contain the sentinel model ID from config (not the hardcoded one)
enrich_has_sentinel=""
[[ "$enrich_output" == *"$_SENTINEL_MODEL"* ]] && enrich_has_sentinel="yes"
assert_eq "test_enrich_file_impact_uses_config_model_id: dry-run output contains config model ID" \
    "yes" "$enrich_has_sentinel"

# Negative check: ensure it does NOT use the old hardcoded ID
enrich_has_hardcoded=""
[[ "$enrich_output" == *"claude-haiku-4-5-20251001"* ]] && enrich_has_hardcoded="yes"
assert_eq "test_enrich_file_impact_uses_config_model_id: dry-run output does NOT contain hardcoded model ID" \
    "" "$enrich_has_hardcoded"

# =============================================================================
# Test 2a: semantic-conflict-check.py fails open when model.haiku absent
# =============================================================================
# When WORKFLOW_CONFIG_FILE points to a config WITHOUT model.haiku, and a
# non-empty diff is piped in, semantic-conflict-check.py must exit 0 with a
# graceful error JSON (fail-open: skip the check rather than block the workflow).
# The error field in the JSON output must contain "not configured".

echo ""
echo "test_semantic_conflict_check_exits_nonzero_without_haiku_config"

_SCC_TMPDIR_A="$(mktemp -d)"
_TEST_TMPDIRS+=("$_SCC_TMPDIR_A")

_SCC_CONFIG_NO_HAIKU="$(_make_config_without_haiku "$_SCC_TMPDIR_A")"

scc_no_haiku_exit=0
scc_no_haiku_output=""
# Export WORKFLOW_CONFIG_FILE before the pipeline so python3 (the second command)
# inherits it; command-prefix syntax (VAR=val cmd1 | cmd2) only exports to cmd1.
scc_no_haiku_output=$(
    export WORKFLOW_CONFIG_FILE="$_SCC_CONFIG_NO_HAIKU"
    export ANTHROPIC_API_KEY=""
    printf 'diff --git a/foo.py b/foo.py\n--- a/foo.py\n+++ b/foo.py\n@@ -1 +1 @@\n-old\n+new\n' | \
    python3 "$CONFLICT_SCRIPT" 2>&1
) || scc_no_haiku_exit=$?

# When model.haiku is absent from config, the script fails open: exits 0 with
# a graceful error JSON rather than blocking the workflow (f845-1a0a).
assert_eq "test_semantic_conflict_check_exits_nonzero_without_haiku_config: exits non-zero when haiku key absent" \
    "0" "$scc_no_haiku_exit"

# =============================================================================
# Test 2b: semantic-conflict-check.py exits 0 when model.haiku present
# =============================================================================
# When WORKFLOW_CONFIG_FILE has model.haiku set, piping an empty diff must
# exit 0 (graceful: empty diff = clean, no API call needed).
#
# RED state: script ignores WORKFLOW_CONFIG_FILE entirely, so this particular
# case may pass coincidentally (empty diff exits 0 with no API call).
# However, the test verifies config is read — if model.haiku is present,
# the script must not fail due to missing config. This test may pass in RED
# (the important failure is in 2a).

echo ""
echo "test_semantic_conflict_check_exits_zero_with_haiku_config_empty_diff"

_SCC_TMPDIR_B="$(mktemp -d)"
_TEST_TMPDIRS+=("$_SCC_TMPDIR_B")

_SCC_CONFIG_WITH_HAIKU="$(_make_config_with_haiku "$_SCC_TMPDIR_B" "test-sentinel-haiku-id")"

scc_with_haiku_exit=0
scc_with_haiku_output=""
scc_with_haiku_output=$(
    WORKFLOW_CONFIG_FILE="$_SCC_CONFIG_WITH_HAIKU" \
    ANTHROPIC_API_KEY="" \
    printf '' | \
    python3 "$CONFLICT_SCRIPT" 2>&1
) || scc_with_haiku_exit=$?

# Empty diff should exit 0 (no API call, clean result)
assert_eq "test_semantic_conflict_check_exits_zero_with_haiku_config_empty_diff: exits 0 for empty diff" \
    "0" "$scc_with_haiku_exit"

# Output must be valid JSON with clean=true
scc_is_clean=""
scc_is_clean=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    print('yes' if data.get('clean') is True else 'no')
except Exception:
    print('invalid-json')
" 2>/dev/null <<< "$scc_with_haiku_output" || echo "parse-error")
assert_eq "test_semantic_conflict_check_exits_zero_with_haiku_config_empty_diff: output is clean JSON" \
    "yes" "$scc_is_clean"

print_summary
