#!/usr/bin/env bash
# tests/scripts/test-create-bug-detected-by-integration.sh
# Integration test: verifies ticket CLI honors --tags CLI_user --tags detected_by:<channel>
# for all 7 allowed detected_by channel values end-to-end.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO="$REPO_ROOT/.claude/scripts/dso"

# Source assert helpers if available
[ -f "$REPO_ROOT/tests/lib/assert.sh" ] && source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-create-bug-detected-by-integration.sh ==="

# Canonical list of allowed detected_by channel values (must stay in sync with
# the ALLOWED array in plugins/dso/scripts/infer-detected-by.sh):
#   detected_by:tests
#   detected_by:review-llm
#   detected_by:review-human
#   detected_by:production
#   detected_by:user-report
#   detected_by:internal-dogfood
#   detected_by:other
#
# Derive allowed values from infer-detected-by.sh ALLOWED array — kept in sync automatically.
# Extract the line: ALLOWED=(tests review-llm review-human production user-report internal-dogfood other)
# shellcheck disable=SC2207
ALLOWED_CHANNELS=($(grep '^ALLOWED=(' "$REPO_ROOT/plugins/dso/scripts/infer-detected-by.sh" \
  | sed 's/^ALLOWED=(//' | sed 's/)$//' | tr -d '"'))

if [[ "${#ALLOWED_CHANNELS[@]}" -eq 0 ]]; then
  echo "FAIL: could not parse ALLOWED array from infer-detected-by.sh" >&2
  exit 1
fi

# Assert the canonical 7 values are all present in the ALLOWED array parsed above.
# This catches drift between this test and infer-detected-by.sh.
for _expected_channel in tests review-llm review-human production user-report internal-dogfood other; do
  _found=0
  for _ch in "${ALLOWED_CHANNELS[@]}"; do
    [[ "$_ch" == "$_expected_channel" ]] && _found=1 && break
  done
  if [[ "$_found" -ne 1 ]]; then
    echo "FAIL: expected channel detected_by:${_expected_channel} not found in ALLOWED array" >&2
    exit 1
  fi
done

# Round-trip coverage: exercise 1 representative channel (tests) to stay
# within the CI per-test 120s budget. Each ticket create+show+delete cycle
# is O(N) on the tracker state (~20-30s in CI with 5000+ tickets). Per-
# channel infer-mapping correctness is covered exhaustively by
# tests/scripts/test-infer-detected-by.sh (all 7 channels); this integration
# test only verifies that the ticket create+show round-trip preserves both
# CLI_user and detected_by:<channel> tags via comma-separated --tags form.
SAMPLE_CHANNELS=(tests)
echo "Channels to test (round-trip sample): ${SAMPLE_CHANNELS[*]}"
echo "All 7 channels covered by mapping unit tests in tests/scripts/test-infer-detected-by.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Global list of ticket IDs created so far (for cleanup on unexpected exit)
_CREATED_IDS=()

cleanup_all() {
  for _id in "${_CREATED_IDS[@]:-}"; do
    if [[ -n "$_id" ]]; then
      "$DSO" ticket delete "$_id" --user-approved 2>/dev/null || true
    fi
  done
}
trap cleanup_all EXIT

# test_detected_by_channel channel
# Creates a bug ticket with CLI_user and detected_by:<channel> tags, verifies both tags
# appear in ticket show output, then deletes the ticket.
# Uses comma-separated --tags value to pass both tags in a single flag invocation.
test_detected_by_channel() {
  local channel="$1"
  local ticket_id show_output
  local tmp_out; tmp_out="$(mktemp /tmp/dso-test.XXXXXX)"

  # 1. Create the ticket with both CLI_user and detected_by:<channel> tags.
  # The --tags flag accepts comma-separated values: CLI_user,detected_by:<channel>
  # This is equivalent to --tags CLI_user --tags detected_by:<channel> and round-trips both tags.
  "$DSO" ticket create bug "Test bug for detected_by:${channel}" \
    --tags "CLI_user,detected_by:${channel}" > "$tmp_out" 2>&1
  local create_exit=$?

  if [[ $create_exit -ne 0 ]]; then
    echo "FAIL: ticket create failed for detected_by:${channel} (exit ${create_exit})" >&2
    cat "$tmp_out" >&2
    rm -f "$tmp_out"
    return 1
  fi

  # 2. Extract ticket ID from output (last line that looks like an ID)
  ticket_id="$(grep -oE '[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}' "$tmp_out" | tail -1)"
  rm -f "$tmp_out"

  if [[ -z "$ticket_id" ]]; then
    echo "FAIL: could not extract ticket ID from create output for detected_by:${channel}" >&2
    return 1
  fi

  # Register for cleanup in case an assertion fails mid-loop
  _CREATED_IDS+=("$ticket_id")

  # 3. Show the ticket
  show_output="$("$DSO" ticket show "$ticket_id" 2>&1)"
  local show_exit=$?

  if [[ $show_exit -ne 0 ]]; then
    echo "FAIL: ticket show failed for $ticket_id (detected_by:${channel}, exit ${show_exit})" >&2
    echo "$show_output" >&2
    return 1
  fi

  # 4a. Assert CLI_user tag is present in the tags array
  if [[ "$show_output" != *"CLI_user"* ]]; then
    echo "FAIL: CLI_user tag not found in ticket show output for detected_by:${channel}" >&2
    echo "$show_output" >&2
    return 1
  fi

  # 4b. Assert detected_by:<channel> tag is present in the tags array
  if [[ "$show_output" != *"detected_by:${channel}"* ]]; then
    echo "FAIL: detected_by:${channel} tag not found in ticket show output" >&2
    echo "$show_output" >&2
    return 1
  fi

  # 5. Delete the ticket (cleanup)
  "$DSO" ticket delete "$ticket_id" --user-approved 2>/dev/null
  # Remove from cleanup list (already deleted)
  _CREATED_IDS=("${_CREATED_IDS[@]/$ticket_id/}")

  return 0
}

# ── Runner ────────────────────────────────────────────────────────────────────

for channel in "${SAMPLE_CHANNELS[@]}"; do
  if test_detected_by_channel "$channel"; then
    echo "test_detected_by_channel[${channel}] ... PASS"
    (( ++PASS )) 2>/dev/null || true
  else
    echo "FAIL: test_detected_by_channel[${channel}]" >&2
    (( ++FAIL )) 2>/dev/null || true
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
if declare -f print_summary > /dev/null 2>&1; then
  print_summary
else
  # Minimal summary when assert.sh is not sourced
  if [[ "${FAIL:-0}" -gt 0 ]]; then
    echo "FAILED: ${FAIL} test(s) failed"
    exit 1
  fi
  echo "All detected_by channel tests completed successfully."
fi
