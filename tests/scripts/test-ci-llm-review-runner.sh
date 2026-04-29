#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031  # PATH/env modifications in subshells are intentional test isolation
# tests/scripts/test-ci-llm-review-runner.sh
# RED-phase behavioral tests for plugins/dso/scripts/ci-llm-review-runner.sh
# (not yet implemented — all tests must FAIL until the runner is created).
#
# Tests covered:
#   1. test_runner_rejects_missing_api_key          — exits 1 when ANTHROPIC_API_KEY is empty
#   2. test_runner_rejects_unknown_flags            — exits 1 for unrecognized CLI flag
#   3. test_runner_exits_zero_for_empty_diff        — exits 0 with "No diff" message for empty stdin
#   4. test_runner_calls_anthropic_api_with_system_prompt — API request body contains .system field
#   5. test_runner_extracts_json_from_markdown_fence — unwraps ```json fence before passing to write-reviewer-findings
#   6. test_runner_reads_review_status_and_exits_nonzero_when_failed — exits 1 when review-status=failed
#   7. test_runner_exits_zero_when_review_passes    — exits 0 when review-status=passed
#   8. test_runner_exits_nonzero_on_unknown_tier    — exits non-zero when classifier returns unknown tier
#   9. test_runner_integration_real_classifier_mocked_curl — classifier runs without error; runner exits 0
#  10. test_runner_integration_real_record_review_writes_status — record-review.sh writes review-status file
#
# Usage: bash tests/scripts/test-ci-llm-review-runner.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

RUNNER="$REPO_ROOT/plugins/dso/scripts/ci-llm-review-runner.sh"

# Track temp dirs for cleanup
_TEST_TMPDIRS=()
cleanup() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap cleanup EXIT

# ── Helper: create a mock curl script in $1 ───────────────────────────────────
# Usage: _create_mock_curl <mock_dir> [<body_capture_file>]
#   mock_dir         — directory where mock curl will be written and made +x
#   body_capture_file — optional path; when provided, the --data-raw argument
#                       is captured to that file at runtime.
# The mock always prints a minimal valid Anthropic API response JSON.
_create_mock_curl() {
    local mock_dir="$1"
    local body_file="${2:-}"
    # Write the canned response to a data file so the generated script can cat it
    # without any shell-quoting issues (JSON contains both { and " characters).
    local response_file="$mock_dir/curl-response.json"
    printf '%s' '{"content":[{"text":"{\"scores\":{\"hygiene\":4,\"design\":4,\"maintainability\":4,\"correctness\":4,\"verification\":4},\"summary\":\"OK\",\"findings\":[]}"}],"stop_reason":"end_turn"}' \
        > "$response_file"

    if [[ -n "$body_file" ]]; then
        # Double-quoted heredoc: ${body_file} and ${response_file} expand NOW (baked
        # into the script), while \$@, \$prev, \$i are escaped so they remain as
        # literal $ in the generated mock script.
        cat > "$mock_dir/curl" <<MOCKEOF
#!/usr/bin/env bash
prev=""
for i in "\$@"; do
    if [[ "\$prev" == "--data-raw" || "\$prev" == "-d" ]]; then
        printf '%s' "\$i" > "${body_file}"
    fi
    prev="\$i"
done
cat "${response_file}"
MOCKEOF
    else
        cat > "$mock_dir/curl" <<MOCKEOF
#!/usr/bin/env bash
cat > /dev/null
cat "${response_file}"
MOCKEOF
    fi
    chmod +x "$mock_dir/curl"
}

echo "=== test-ci-llm-review-runner.sh ==="

# ── test_runner_rejects_missing_api_key ───────────────────────────────────────
# Given: ANTHROPIC_API_KEY is empty
# When:  runner is invoked with empty stdin
# Then:  exit code is 1
_snapshot_fail
missing_key_exit=0
( ANTHROPIC_API_KEY='' bash "$RUNNER" < /dev/null ) || missing_key_exit=$?
assert_eq "test_runner_rejects_missing_api_key: exits 1 when ANTHROPIC_API_KEY is empty" "1" "$missing_key_exit"
assert_pass_if_clean "test_runner_rejects_missing_api_key"

# ── test_runner_rejects_unknown_flags ─────────────────────────────────────────
# Given: a valid API key but an unknown flag --unknown-flag
# When:  runner is invoked
# Then:  exit code is 1
_snapshot_fail
unknown_flag_exit=0
( ANTHROPIC_API_KEY='x' bash "$RUNNER" --unknown-flag < /dev/null ) || unknown_flag_exit=$?
assert_eq "test_runner_rejects_unknown_flags: exits 1 for unknown flag" "1" "$unknown_flag_exit"
assert_pass_if_clean "test_runner_rejects_unknown_flags"

# ── test_runner_exits_zero_for_empty_diff ─────────────────────────────────────
# Given: ANTHROPIC_API_KEY set, stdin is empty
# When:  runner is invoked
# Then:  exit code is 0 and stdout contains "No diff" message
_snapshot_fail
empty_diff_exit=0
empty_diff_output=""
empty_diff_output=$( ANTHROPIC_API_KEY='x' bash "$RUNNER" < /dev/null 2>&1 ) || empty_diff_exit=$?
assert_eq "test_runner_exits_zero_for_empty_diff: exits 0" "0" "$empty_diff_exit"
assert_contains "test_runner_exits_zero_for_empty_diff: output contains 'No diff'" "No diff" "$empty_diff_output"
assert_pass_if_clean "test_runner_exits_zero_for_empty_diff"

# ── test_runner_calls_anthropic_api_with_system_prompt ────────────────────────
# Given: mocked curl, write-reviewer-findings.sh, and record-review.sh
# When:  runner is fed a non-empty diff
# Then:  the API request body sent to curl contains a .system field
_snapshot_fail
api_system_exit=0
MOCK4=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK4")
ARTIFACTS4=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS4")
BODY4_FILE="$MOCK4/curl-body.json"

# Mock curl: capture --data-raw body, return a minimal valid API response
_create_mock_curl "$MOCK4" "$BODY4_FILE"

# Mock write-reviewer-findings.sh: accept valid JSON on stdin, echo 64-char hex hash
cat > "$MOCK4/write-reviewer-findings.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null  # consume stdin
printf '%064x\n' 0
MOCKEOF

# Mock record-review.sh: write "passed" to review-status
cat > "$MOCK4/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$ARTIFACTS4"
printf 'passed\n' > "$ARTIFACTS4/review-status"
MOCKEOF

chmod +x "$MOCK4/curl" "$MOCK4/write-reviewer-findings.sh" "$MOCK4/record-review.sh"

# Also mock review-complexity-classifier.sh to return a stable light tier output
cat > "$MOCK4/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null  # consume stdin
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK4/review-complexity-classifier.sh"

api_system_exit=0
(
    export PATH="$MOCK4:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS4"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || api_system_exit=$?

# Verify: runner exited 0
assert_eq "test_runner_calls_anthropic_api_with_system_prompt: runner exits 0" "0" "$api_system_exit"

# Verify: the captured request body has a .system field
body_check_exit=0
body_check_output=""
if [[ -f "$BODY4_FILE" ]]; then
    body_check_output=$(python3 -c "
import json, sys
with open('$BODY4_FILE') as f:
    d = json.load(f)
if 'system' not in d:
    print('MISSING_SYSTEM: .system field not in API request body; keys=' + str(list(d.keys())))
    sys.exit(1)
print('OK')
" 2>&1) || body_check_exit=$?
else
    body_check_output="MISSING_BODY_FILE: curl body was not captured"
    body_check_exit=1
fi
assert_eq "test_runner_calls_anthropic_api_with_system_prompt: request contains .system" "0" "$body_check_exit"
assert_eq "test_runner_calls_anthropic_api_with_system_prompt: .system field present" "OK" "$body_check_output"
assert_pass_if_clean "test_runner_calls_anthropic_api_with_system_prompt"

# ── test_runner_extracts_json_from_markdown_fence ─────────────────────────────
# Given: curl returns a markdown-fenced JSON response
# When:  runner processes the API response
# Then:  write-reviewer-findings.sh receives parseable JSON (fence stripped)
_snapshot_fail
fence_exit=0
MOCK5=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK5")
ARTIFACTS5=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS5")
FENCE_FINDINGS='{"scores":{"hygiene":4,"design":4,"maintainability":4,"correctness":4,"verification":4},"summary":"OK","findings":[]}'
FENCE_RECEIVED="$MOCK5/findings-received.json"

# Mock curl: return JSON wrapped in ```json fence
cat > "$MOCK5/curl" <<MOCKEOF
#!/usr/bin/env bash
cat > /dev/null  # consume all args including body
printf '{"content":[{"text":"\`\`\`json\\n${FENCE_FINDINGS}\\n\`\`\`"}],"stop_reason":"end_turn"}'
MOCKEOF
chmod +x "$MOCK5/curl"

# Mock write-reviewer-findings.sh: validate that stdin is parseable JSON; fail if not
cat > "$MOCK5/write-reviewer-findings.sh" <<MOCKEOF
#!/usr/bin/env bash
# Read stdin and save to file
tee "$FENCE_RECEIVED" | python3 -c 'import json,sys; json.load(sys.stdin)' || exit 1
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK5/write-reviewer-findings.sh"

# Mock record-review.sh
cat > "$MOCK5/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$ARTIFACTS5"
printf 'passed\n' > "$ARTIFACTS5/review-status"
MOCKEOF
chmod +x "$MOCK5/record-review.sh"

# Mock classifier
cat > "$MOCK5/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK5/review-complexity-classifier.sh"

fence_exit=0
(
    export PATH="$MOCK5:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS5"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || fence_exit=$?

assert_eq "test_runner_extracts_json_from_markdown_fence: runner exits 0 (write-reviewer-findings received valid JSON)" "0" "$fence_exit"
assert_pass_if_clean "test_runner_extracts_json_from_markdown_fence"

# ── test_runner_reads_review_status_and_exits_nonzero_when_failed ─────────────
# Given: record-review.sh writes "failed" to review-status
# When:  runner completes
# Then:  runner exits 1
_snapshot_fail
failed_status_exit=0
MOCK6=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK6")
ARTIFACTS6=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS6")

cat > "$MOCK6/curl" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"content":[{"text":"{\"scores\":{\"hygiene\":2,\"design\":2,\"maintainability\":2,\"correctness\":2,\"verification\":2},\"summary\":\"Review failed\",\"findings\":[{\"severity\":\"critical\",\"dimension\":\"correctness\",\"description\":\"Bug\",\"location\":\"foo.sh:1\",\"recommendation\":\"Fix it\"}]}"}],"stop_reason":"end_turn"}'
MOCKEOF
chmod +x "$MOCK6/curl"

cat > "$MOCK6/write-reviewer-findings.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK6/write-reviewer-findings.sh"

cat > "$MOCK6/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$ARTIFACTS6"
printf 'failed\n' > "$ARTIFACTS6/review-status"
MOCKEOF
chmod +x "$MOCK6/record-review.sh"

cat > "$MOCK6/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK6/review-complexity-classifier.sh"

failed_status_exit=0
(
    export PATH="$MOCK6:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS6"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || failed_status_exit=$?

assert_eq "test_runner_reads_review_status_and_exits_nonzero_when_failed: exits 1 when status=failed" "1" "$failed_status_exit"
assert_pass_if_clean "test_runner_reads_review_status_and_exits_nonzero_when_failed"

# ── test_runner_exits_zero_when_review_passes ─────────────────────────────────
# Given: mocked curl/write-reviewer-findings/record-review; record-review writes "passed"
# When:  runner processes non-empty diff
# Then:  exits 0
_snapshot_fail
passed_exit=0
MOCK7=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK7")
ARTIFACTS7=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS7")

cat > "$MOCK7/curl" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"content":[{"text":"{\"scores\":{\"hygiene\":5,\"design\":5,\"maintainability\":5,\"correctness\":5,\"verification\":5},\"summary\":\"Excellent work\",\"findings\":[]}"}],"stop_reason":"end_turn"}'
MOCKEOF
chmod +x "$MOCK7/curl"

cat > "$MOCK7/write-reviewer-findings.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK7/write-reviewer-findings.sh"

cat > "$MOCK7/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$ARTIFACTS7"
printf 'passed\n' > "$ARTIFACTS7/review-status"
MOCKEOF
chmod +x "$MOCK7/record-review.sh"

cat > "$MOCK7/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK7/review-complexity-classifier.sh"

passed_exit=0
(
    export PATH="$MOCK7:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS7"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || passed_exit=$?

assert_eq "test_runner_exits_zero_when_review_passes: exits 0 when status=passed" "0" "$passed_exit"
assert_pass_if_clean "test_runner_exits_zero_when_review_passes"

# ── test_runner_exits_nonzero_on_unknown_tier ─────────────────────────────────
# Given: review-complexity-classifier.sh returns {"selected_tier":"garbage"}
# When:  runner tries to route the review
# Then:  exits non-zero (cannot proceed with unknown tier)
_snapshot_fail
unknown_tier_exit=0
MOCK8=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK8")
ARTIFACTS8=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS8")

cat > "$MOCK8/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"garbage","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK8/review-complexity-classifier.sh"

unknown_tier_exit=0
unknown_tier_output=""
unknown_tier_output=$(
    export PATH="$MOCK8:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS8"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER" 2>&1
) || unknown_tier_exit=$?

# Runner must exist AND exit non-zero for unknown tier — exit 127 (file not found) doesn't count
runner_exists=0
[[ -f "$RUNNER" ]] || runner_exists=1
assert_eq "test_runner_exits_nonzero_on_unknown_tier: runner script exists" "0" "$runner_exists"
assert_ne "test_runner_exits_nonzero_on_unknown_tier: exits non-zero for unknown tier" "0" "$unknown_tier_exit"
assert_pass_if_clean "test_runner_exits_nonzero_on_unknown_tier"

# ── test_runner_integration_real_classifier_mocked_curl ───────────────────────
# Given: real review-complexity-classifier.sh (no mock), mocked curl/write-reviewer-findings/record-review
# When:  runner receives a well-formed diff
# Then:  exits 0 (classifier ran successfully and produced a valid tier)
_snapshot_fail
real_cls_exit=0
MOCK9=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK9")
ARTIFACTS9=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS9")

_create_mock_curl "$MOCK9"

cat > "$MOCK9/write-reviewer-findings.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK9/write-reviewer-findings.sh"

cat > "$MOCK9/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$ARTIFACTS9"
printf 'passed\n' > "$ARTIFACTS9/review-status"
MOCKEOF
chmod +x "$MOCK9/record-review.sh"

real_cls_exit=0
(
    export PATH="$MOCK9:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS9"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || real_cls_exit=$?

assert_eq "test_runner_integration_real_classifier_mocked_curl: exits 0 (classifier ran without error)" "0" "$real_cls_exit"
assert_pass_if_clean "test_runner_integration_real_classifier_mocked_curl"

# ── test_runner_integration_real_record_review_writes_status ──────────────────
# Given: real record-review.sh (no mock); mocked curl + write-reviewer-findings.sh that
#        writes a valid reviewer-findings.json; WORKFLOW_PLUGIN_ARTIFACTS_DIR exported
# When:  runner processes a non-empty diff from repo root (so record-review.sh can source deps)
# Then:  a review-status file is written to WORKFLOW_PLUGIN_ARTIFACTS_DIR
_snapshot_fail
real_rr_exit=0
MOCK10=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK10")
ARTIFACTS10=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS10")

_create_mock_curl "$MOCK10"

# Mock write-reviewer-findings.sh: write valid findings JSON and echo its real sha256
# so record-review.sh can verify the hash without failure.
cat > "$MOCK10/write-reviewer-findings.sh" <<MOCKEOF
#!/usr/bin/env bash
cat > /dev/null  # consume stdin
# Write a valid reviewer-findings.json with a summary long enough to pass schema validation
mkdir -p "$ARTIFACTS10"
_FINDINGS='{"scores":{"hygiene":4,"design":4,"maintainability":4,"correctness":4,"verification":4},"summary":"Review completed with no findings.","findings":[]}'
printf '%s\n' "\$_FINDINGS" > "$ARTIFACTS10/reviewer-findings.json"
# Echo the real sha256 of the written file so record-review.sh hash check passes
sha256sum "$ARTIFACTS10/reviewer-findings.json" 2>/dev/null | cut -d' ' -f1 \
  || shasum -a 256 "$ARTIFACTS10/reviewer-findings.json" | cut -d' ' -f1
MOCKEOF
chmod +x "$MOCK10/write-reviewer-findings.sh"

# Mock classifier
cat > "$MOCK10/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK10/review-complexity-classifier.sh"

real_rr_exit=0
(
    cd "$REPO_ROOT"
    export PATH="$MOCK10:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS10"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || real_rr_exit=$?

assert_eq "test_runner_integration_real_record_review_writes_status: runner exits without error" "0" "$real_rr_exit"
if [[ -f "$ARTIFACTS10/review-status" ]]; then status_file_exists=0; else status_file_exists=1; fi
assert_eq "test_runner_integration_real_record_review_writes_status: review-status file written" "0" "$status_file_exists"
assert_pass_if_clean "test_runner_integration_real_record_review_writes_status"

# ── Test 11: overlay flags written to overlay-flags.env ──────────────────────
MOCK11=$(mktemp -d) && ARTIFACTS11=$(mktemp -d)

# Classifier that returns security_overlay=true, others false
cat > "$MOCK11/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":true,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK11/review-complexity-classifier.sh"

cat > "$MOCK11/curl" <<'MOCKEOF'
#!/usr/bin/env bash
printf '{"content":[{"type":"text","text":"{\"review_tier\":\"light\",\"selected_tier\":\"light\",\"scores\":{\"correctness\":5,\"verification\":5,\"hygiene\":5,\"design\":5,\"maintainability\":5},\"summary\":\"No findings. All checks passed.\",\"findings\":[]}"}]}'
MOCKEOF
chmod +x "$MOCK11/curl"

cat > "$MOCK11/write-reviewer-findings.sh" <<MOCKEOF
#!/usr/bin/env bash
_F='{"review_tier":"light","selected_tier":"light","scores":{"correctness":5,"verification":5,"hygiene":5,"design":5,"maintainability":5},"summary":"No findings. All checks passed.","findings":[]}'
printf '%s\n' "\$_F" > "$ARTIFACTS11/reviewer-findings.json"
sha256sum "$ARTIFACTS11/reviewer-findings.json" 2>/dev/null | cut -d' ' -f1 \
  || shasum -a 256 "$ARTIFACTS11/reviewer-findings.json" | cut -d' ' -f1
MOCKEOF
chmod +x "$MOCK11/write-reviewer-findings.sh"

overlay_exit=0
(
  cd "$REPO_ROOT"
  export PATH="$MOCK11:$PATH"
  export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS11"
  printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || overlay_exit=$?

assert_eq "test_runner_writes_overlay_flags_env: runner exits 0" "0" "$overlay_exit"
_overlay_file="$ARTIFACTS11/overlay-flags.env"
if [[ -f "$_overlay_file" ]]; then _overlay_exists=0; else _overlay_exists=1; fi
assert_eq "test_runner_writes_overlay_flags_env: overlay-flags.env exists" "0" "$_overlay_exists"
_sec=$(grep "^security_overlay=" "$_overlay_file" | cut -d= -f2)
_perf=$(grep "^performance_overlay=" "$_overlay_file" | cut -d= -f2)
_tq=$(grep "^test_quality_overlay=" "$_overlay_file" | cut -d= -f2)
assert_eq "test_runner_writes_overlay_flags_env: security_overlay=true from classifier" "true" "$_sec"
assert_eq "test_runner_writes_overlay_flags_env: performance_overlay=false" "false" "$_perf"
assert_eq "test_runner_writes_overlay_flags_env: test_quality_overlay=false" "false" "$_tq"
assert_pass_if_clean "test_runner_writes_overlay_flags_env"

# Cleanup test 11 temps
rm -rf "$MOCK11" "$ARTIFACTS11"

# ── Test 12: --overlay-security CLI flag overrides classifier false ───────────
MOCK12=$(mktemp -d) && ARTIFACTS12=$(mktemp -d)

cat > "$MOCK12/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK12/review-complexity-classifier.sh"

cat > "$MOCK12/curl" <<'MOCKEOF'
#!/usr/bin/env bash
printf '{"content":[{"type":"text","text":"{\"review_tier\":\"light\",\"selected_tier\":\"light\",\"scores\":{\"correctness\":5,\"verification\":5,\"hygiene\":5,\"design\":5,\"maintainability\":5},\"summary\":\"No findings. All checks passed.\",\"findings\":[]}"}]}'
MOCKEOF
chmod +x "$MOCK12/curl"

cat > "$MOCK12/write-reviewer-findings.sh" <<MOCKEOF
#!/usr/bin/env bash
_F='{"review_tier":"light","selected_tier":"light","scores":{"correctness":5,"verification":5,"hygiene":5,"design":5,"maintainability":5},"summary":"No findings. All checks passed.","findings":[]}'
printf '%s\n' "\$_F" > "$ARTIFACTS12/reviewer-findings.json"
sha256sum "$ARTIFACTS12/reviewer-findings.json" 2>/dev/null | cut -d' ' -f1 \
  || shasum -a 256 "$ARTIFACTS12/reviewer-findings.json" | cut -d' ' -f1
MOCKEOF
chmod +x "$MOCK12/write-reviewer-findings.sh"

cli_override_exit=0
(
  cd "$REPO_ROOT"
  export PATH="$MOCK12:$PATH"
  export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS12"
  printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER" --overlay-security
) || cli_override_exit=$?

assert_eq "test_runner_cli_overlay_overrides_classifier: runner exits 0" "0" "$cli_override_exit"
_sec2=$(grep "^security_overlay=" "$ARTIFACTS12/overlay-flags.env" | cut -d= -f2)
assert_eq "test_runner_cli_overlay_overrides_classifier: security_overlay=true from CLI" "true" "$_sec2"
assert_pass_if_clean "test_runner_cli_overlay_overrides_classifier"

# Cleanup test 12 temps
rm -rf "$MOCK12" "$ARTIFACTS12"
# This covers tests 13–16 (deep-tier dispatch) AND tests 17–20 (overlay dispatch) — all 8 RED
# tests are TDD boundaries for GREEN tasks 0db5-9a72 and a871-cce0. The runner currently falls
# back to standard for deep tier and writes overlay-flags.env but does not dispatch overlay curl
# calls — by design, those are GREEN task responsibilities. No separate .test-index entry is
# needed for each test after the boundary; the single marker covers the entire tail of the file.

# ── Test 13: deep-tier dispatches three specialist curl calls ─────────────────
# Given: classifier returns selected_tier=deep
# When:  runner processes a non-empty diff
# Then:  exactly 3 specialist curl calls are made (correctness, verification, hygiene)
#        and slot files reviewer-findings-correctness.json, reviewer-findings-verification.json,
#        reviewer-findings-hygiene.json are written to WORKFLOW_PLUGIN_ARTIFACTS_DIR
_snapshot_fail
MOCK13=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK13")
ARTIFACTS13=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS13")

# Counter file — incremented by each curl invocation
CURL_COUNT_FILE="$MOCK13/curl-call-count"
printf '0' > "$CURL_COUNT_FILE"

# Specialist slot response — valid reviewer-findings JSON
_SLOT_JSON='{"scores":{"correctness":4,"verification":4,"hygiene":4,"design":4,"maintainability":4},"summary":"Specialist OK","findings":[]}'

# Mock curl: count calls; write a slot file named after the agent being invoked
# (The runner is expected to pass --data-raw with a body referencing the agent file).
# For each call, write the appropriate slot file and increment the counter.
cat > "$MOCK13/curl" <<MOCKEOF
#!/usr/bin/env bash
# Detect which specialist this call is for by scanning --data-raw body for agent file path
_body=""
_prev=""
for _arg in "\$@"; do
    if [[ "\$_prev" == "--data-raw" || "\$_prev" == "-d" ]]; then
        _body="\$_arg"
    fi
    _prev="\$_arg"
done

_slot_json='${_SLOT_JSON}'

# Count and handle specialist calls only (not the arch synthesis call)
if printf '%s' "\$_body" | grep -q "code-reviewer-deep-correctness"; then
    _count=\$(cat "${CURL_COUNT_FILE}"); _count=\$((_count + 1)); printf '%s' "\$_count" > "${CURL_COUNT_FILE}"
    printf '%s\n' "\$_slot_json" > "${ARTIFACTS13}/reviewer-findings-correctness.json"
elif printf '%s' "\$_body" | grep -q "code-reviewer-deep-verification"; then
    _count=\$(cat "${CURL_COUNT_FILE}"); _count=\$((_count + 1)); printf '%s' "\$_count" > "${CURL_COUNT_FILE}"
    printf '%s\n' "\$_slot_json" > "${ARTIFACTS13}/reviewer-findings-verification.json"
elif printf '%s' "\$_body" | grep -q "code-reviewer-deep-hygiene"; then
    _count=\$(cat "${CURL_COUNT_FILE}"); _count=\$((_count + 1)); printf '%s' "\$_count" > "${CURL_COUNT_FILE}"
    printf '%s\n' "\$_slot_json" > "${ARTIFACTS13}/reviewer-findings-hygiene.json"
fi

# Return a minimal valid API response for every call
printf '{"content":[{"text":"%s"}],"stop_reason":"end_turn"}' "\$(printf '%s' "\$_slot_json" | sed 's/"/\\\\"/g')"
MOCKEOF
chmod +x "$MOCK13/curl"

# Mock classifier returning deep tier
cat > "$MOCK13/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"deep","blast_radius":3,"critical_path":2,"anti_shortcut":1,"staleness":1,"cross_cutting":1,"diff_lines":350,"change_volume":2,"computed_total":10,"diff_size_lines":350,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK13/review-complexity-classifier.sh"

cat > "$MOCK13/write-reviewer-findings.sh" <<MOCKEOF
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK13/write-reviewer-findings.sh"

cat > "$MOCK13/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$ARTIFACTS13"
printf 'passed\n' > "${ARTIFACTS13}/review-status"
MOCKEOF
chmod +x "$MOCK13/record-review.sh"

deep_dispatch_exit=0
(
    export PATH="$MOCK13:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS13"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || deep_dispatch_exit=$?

assert_eq "test_deep_tier_dispatches_three_specialist_calls: runner exits 0" "0" "$deep_dispatch_exit"

_curl_count=$(cat "$CURL_COUNT_FILE")
assert_eq "test_deep_tier_dispatches_three_specialist_calls: exactly 3 specialist curl calls" "3" "$_curl_count"

if [[ -f "$ARTIFACTS13/reviewer-findings-correctness.json" ]]; then _corr_exists=0; else _corr_exists=1; fi
assert_eq "test_deep_tier_dispatches_three_specialist_calls: correctness slot file written" "0" "$_corr_exists"

if [[ -f "$ARTIFACTS13/reviewer-findings-verification.json" ]]; then _verif_exists=0; else _verif_exists=1; fi
assert_eq "test_deep_tier_dispatches_three_specialist_calls: verification slot file written" "0" "$_verif_exists"

if [[ -f "$ARTIFACTS13/reviewer-findings-hygiene.json" ]]; then _hyg_exists=0; else _hyg_exists=1; fi
assert_eq "test_deep_tier_dispatches_three_specialist_calls: hygiene slot file written" "0" "$_hyg_exists"

assert_pass_if_clean "test_deep_tier_dispatches_three_specialist_calls"

# ── Test 14: deep-tier arch agent is sole final writer of reviewer-findings.json ─
# Given: classifier returns selected_tier=deep; 3 specialist slot files are present
# When:  runner completes the arch synthesis step
# Then:  a 4th curl call is made for the arch agent, and reviewer-findings.json is
#        written by that arch step (not by any specialist call)
_snapshot_fail
MOCK14=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK14")
ARTIFACTS14=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS14")

CURL_COUNT14="$MOCK14/curl-call-count"
printf '0' > "$CURL_COUNT14"

_SLOT14='{"scores":{"correctness":4,"verification":4,"hygiene":4,"design":4,"maintainability":4},"summary":"Specialist OK","findings":[]}'
_ARCH14='{"scores":{"correctness":5,"verification":5,"hygiene":5,"design":5,"maintainability":5},"summary":"Arch synthesis complete","findings":[]}'

# Mock curl: count calls; write slot files for specialist agents; write final
# reviewer-findings.json when the arch agent body is detected
cat > "$MOCK14/curl" <<MOCKEOF
#!/usr/bin/env bash
_count=\$(cat "${CURL_COUNT14}")
_count=\$((_count + 1))
printf '%s' "\$_count" > "${CURL_COUNT14}"

_body=""
_prev=""
for _arg in "\$@"; do
    if [[ "\$_prev" == "--data-raw" || "\$_prev" == "-d" ]]; then
        _body="\$_arg"
    fi
    _prev="\$_arg"
done

_slot='${_SLOT14}'
_arch='${_ARCH14}'

if printf '%s' "\$_body" | grep -q "code-reviewer-deep-correctness"; then
    printf '%s\n' "\$_slot" > "${ARTIFACTS14}/reviewer-findings-correctness.json"
    printf '{"content":[{"text":"%s"}],"stop_reason":"end_turn"}' "\$(printf '%s' "\$_slot" | sed 's/"/\\\\"/g')"
elif printf '%s' "\$_body" | grep -q "code-reviewer-deep-verification"; then
    printf '%s\n' "\$_slot" > "${ARTIFACTS14}/reviewer-findings-verification.json"
    printf '{"content":[{"text":"%s"}],"stop_reason":"end_turn"}' "\$(printf '%s' "\$_slot" | sed 's/"/\\\\"/g')"
elif printf '%s' "\$_body" | grep -q "code-reviewer-deep-hygiene"; then
    printf '%s\n' "\$_slot" > "${ARTIFACTS14}/reviewer-findings-hygiene.json"
    printf '{"content":[{"text":"%s"}],"stop_reason":"end_turn"}' "\$(printf '%s' "\$_slot" | sed 's/"/\\\\"/g')"
elif printf '%s' "\$_body" | grep -q "code-reviewer-deep-arch"; then
    printf '%s\n' "\$_arch" > "${ARTIFACTS14}/reviewer-findings.json"
    printf '{"content":[{"text":"%s"}],"stop_reason":"end_turn"}' "\$(printf '%s' "\$_arch" | sed 's/"/\\\\"/g')"
else
    printf '{"content":[{"text":"{\"scores\":{},\"summary\":\"fallback\",\"findings\":[]}"}],"stop_reason":"end_turn"}'
fi
MOCKEOF
chmod +x "$MOCK14/curl"

cat > "$MOCK14/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"deep","blast_radius":3,"critical_path":2,"anti_shortcut":1,"staleness":1,"cross_cutting":1,"diff_lines":350,"change_volume":2,"computed_total":10,"diff_size_lines":350,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK14/review-complexity-classifier.sh"

cat > "$MOCK14/write-reviewer-findings.sh" <<MOCKEOF
#!/usr/bin/env bash
# Read the pre-written reviewer-findings.json placed by arch mock curl above
# and return its hash — mimics what the real script does
cat > /dev/null
if [[ -f "${ARTIFACTS14}/reviewer-findings.json" ]]; then
    sha256sum "${ARTIFACTS14}/reviewer-findings.json" 2>/dev/null | cut -d' ' -f1 \
      || shasum -a 256 "${ARTIFACTS14}/reviewer-findings.json" | cut -d' ' -f1
else
    printf '%064x\n' 0
fi
MOCKEOF
chmod +x "$MOCK14/write-reviewer-findings.sh"

cat > "$MOCK14/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$ARTIFACTS14"
printf 'passed\n' > "${ARTIFACTS14}/review-status"
MOCKEOF
chmod +x "$MOCK14/record-review.sh"

arch_exit=0
(
    export PATH="$MOCK14:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS14"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || arch_exit=$?

assert_eq "test_deep_tier_arch_agent_is_sole_final_writer: runner exits 0" "0" "$arch_exit"

_curl_count14=$(cat "$CURL_COUNT14")
assert_eq "test_deep_tier_arch_agent_is_sole_final_writer: exactly 4 curl calls (3 specialists + arch)" "4" "$_curl_count14"

if [[ -f "$ARTIFACTS14/reviewer-findings.json" ]]; then _final_exists=0; else _final_exists=1; fi
assert_eq "test_deep_tier_arch_agent_is_sole_final_writer: reviewer-findings.json written by arch" "0" "$_final_exists"

# Verify reviewer-findings.json contains arch summary, not specialist summary
_arch_summary=""
if [[ -f "$ARTIFACTS14/reviewer-findings.json" ]]; then
    _arch_summary=$(python3 -c "
import json, sys
with open('$ARTIFACTS14/reviewer-findings.json') as f:
    d = json.load(f)
print(d.get('summary',''))
" 2>/dev/null || true)
fi
assert_eq "test_deep_tier_arch_agent_is_sole_final_writer: final findings contain arch summary" "Arch synthesis complete" "$_arch_summary"
assert_pass_if_clean "test_deep_tier_arch_agent_is_sole_final_writer"

# ── Test 15: deep-tier fails closed when a specialist slot file is missing ─────
# Given: classifier returns selected_tier=deep; a specialist curl mock that only
#        writes 2 of the 3 expected slot files (simulating partial specialist failure)
# When:  runner attempts arch synthesis
# Then:  runner exits non-zero (fail-closed; no slot file = no synthesis)
_snapshot_fail
MOCK15=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK15")
ARTIFACTS15=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS15")

_SLOT15='{"scores":{"correctness":4,"verification":4,"hygiene":4,"design":4,"maintainability":4},"summary":"Specialist OK","findings":[]}'

# Mock curl that only writes correctness + verification — hygiene slot is intentionally omitted
cat > "$MOCK15/curl" <<MOCKEOF
#!/usr/bin/env bash
_body=""
_prev=""
for _arg in "\$@"; do
    if [[ "\$_prev" == "--data-raw" || "\$_prev" == "-d" ]]; then
        _body="\$_arg"
    fi
    _prev="\$_arg"
done

_slot='${_SLOT15}'

if printf '%s' "\$_body" | grep -q "code-reviewer-deep-correctness"; then
    printf '%s\n' "\$_slot" > "${ARTIFACTS15}/reviewer-findings-correctness.json"
elif printf '%s' "\$_body" | grep -q "code-reviewer-deep-verification"; then
    printf '%s\n' "\$_slot" > "${ARTIFACTS15}/reviewer-findings-verification.json"
fi
# Intentionally do NOT write hygiene slot file

printf '{"content":[{"text":"%s"}],"stop_reason":"end_turn"}' "\$(printf '%s' "\$_slot" | sed 's/"/\\\\"/g')"
MOCKEOF
chmod +x "$MOCK15/curl"

cat > "$MOCK15/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"deep","blast_radius":3,"critical_path":2,"anti_shortcut":1,"staleness":1,"cross_cutting":1,"diff_lines":350,"change_volume":2,"computed_total":10,"diff_size_lines":350,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK15/review-complexity-classifier.sh"

cat > "$MOCK15/write-reviewer-findings.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK15/write-reviewer-findings.sh"

cat > "$MOCK15/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$ARTIFACTS15"
printf 'passed\n' > "${ARTIFACTS15}/review-status"
MOCKEOF
chmod +x "$MOCK15/record-review.sh"

missing_slot_exit=0
(
    export PATH="$MOCK15:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS15"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER" 2>/dev/null
) || missing_slot_exit=$?

assert_ne "test_deep_tier_fail_closed_on_missing_slot_file: exits non-zero when hygiene slot missing" "0" "$missing_slot_exit"
assert_pass_if_clean "test_deep_tier_fail_closed_on_missing_slot_file"

# ── Test 16: deep-tier fails closed when a slot file contains invalid JSON ─────
# Given: classifier returns selected_tier=deep; specialist curl mock writes invalid
#        JSON to one of the slot files
# When:  runner attempts arch synthesis
# Then:  runner exits non-zero (invalid JSON in slot = cannot synthesize)
_snapshot_fail
MOCK16=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK16")
ARTIFACTS16=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS16")

_SLOT16='{"scores":{"correctness":4,"verification":4,"hygiene":4,"design":4,"maintainability":4},"summary":"Specialist OK","findings":[]}'

# Mock curl: writes valid JSON for correctness and verification, but invalid JSON for hygiene
cat > "$MOCK16/curl" <<MOCKEOF
#!/usr/bin/env bash
_body=""
_prev=""
for _arg in "\$@"; do
    if [[ "\$_prev" == "--data-raw" || "\$_prev" == "-d" ]]; then
        _body="\$_arg"
    fi
    _prev="\$_arg"
done

_slot='${_SLOT16}'

if printf '%s' "\$_body" | grep -q "code-reviewer-deep-correctness"; then
    printf '%s\n' "\$_slot" > "${ARTIFACTS16}/reviewer-findings-correctness.json"
elif printf '%s' "\$_body" | grep -q "code-reviewer-deep-verification"; then
    printf '%s\n' "\$_slot" > "${ARTIFACTS16}/reviewer-findings-verification.json"
elif printf '%s' "\$_body" | grep -q "code-reviewer-deep-hygiene"; then
    # Write intentionally malformed JSON
    printf 'NOT VALID JSON {{{' > "${ARTIFACTS16}/reviewer-findings-hygiene.json"
fi

printf '{"content":[{"text":"%s"}],"stop_reason":"end_turn"}' "\$(printf '%s' "\$_slot" | sed 's/"/\\\\"/g')"
MOCKEOF
chmod +x "$MOCK16/curl"

cat > "$MOCK16/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"deep","blast_radius":3,"critical_path":2,"anti_shortcut":1,"staleness":1,"cross_cutting":1,"diff_lines":350,"change_volume":2,"computed_total":10,"diff_size_lines":350,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK16/review-complexity-classifier.sh"

cat > "$MOCK16/write-reviewer-findings.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK16/write-reviewer-findings.sh"

cat > "$MOCK16/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$ARTIFACTS16"
printf 'passed\n' > "${ARTIFACTS16}/review-status"
MOCKEOF
chmod +x "$MOCK16/record-review.sh"

invalid_json_exit=0
(
    export PATH="$MOCK16:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS16"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER" 2>/dev/null
) || invalid_json_exit=$?

assert_ne "test_deep_tier_fail_closed_on_invalid_slot_json: exits non-zero when slot file has invalid JSON" "0" "$invalid_json_exit"
assert_pass_if_clean "test_deep_tier_fail_closed_on_invalid_slot_json"

# Cleanup test 13–16 temps already registered in _TEST_TMPDIRS via trap

# ── test_overlay_dispatch_fires_curl_for_security_overlay ────────────────────
# Given: overlay-flags.env contains security_overlay=true
# When:  runner reads the env file and dispatches overlays
# Then:  an additional curl call is made using code-reviewer-security-red-team.md
#        and reviewer-findings-security-red.json is written to WORKFLOW_PLUGIN_ARTIFACTS_DIR
_snapshot_fail
MOCK_SEC=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK_SEC")
ARTIFACTS_SEC=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS_SEC")
CURL_CALL_LOG="$MOCK_SEC/curl-calls.log"

cat > "$MOCK_SEC/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK_SEC/review-complexity-classifier.sh"

# Mock curl that counts calls (logs each --data-raw invocation) and returns valid response
cat > "$MOCK_SEC/curl" <<MOCKEOF
#!/usr/bin/env bash
prev=""
for i in "\$@"; do
    if [[ "\$prev" == "--data-raw" || "\$prev" == "-d" ]]; then
        printf '%s\n---CURL_CALL---\n' "\$i" >> "${CURL_CALL_LOG}"
    fi
    prev="\$i"
done
printf '{"content":[{"text":"{\"scores\":{\"hygiene\":4,\"design\":4,\"maintainability\":4,\"correctness\":4,\"verification\":4},\"summary\":\"Security review completed\",\"findings\":[]}"}],"stop_reason":"end_turn"}'
MOCKEOF
chmod +x "$MOCK_SEC/curl"

cat > "$MOCK_SEC/write-reviewer-findings.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK_SEC/write-reviewer-findings.sh"

cat > "$MOCK_SEC/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "${ARTIFACTS_SEC}"
printf 'passed\n' > "${ARTIFACTS_SEC}/review-status"
MOCKEOF
chmod +x "$MOCK_SEC/record-review.sh"

# Pre-populate overlay-flags.env with security_overlay=true before the runner executes.
# The runner is expected to read this file after the classifier writes it and dispatch
# the security overlay curl call accordingly.
mkdir -p "$ARTIFACTS_SEC"
printf 'security_overlay=true\nperformance_overlay=false\ntest_quality_overlay=false\n' \
    > "$ARTIFACTS_SEC/overlay-flags.env"

sec_overlay_exit=0
(
    export PATH="$MOCK_SEC:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_SEC"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || sec_overlay_exit=$?

assert_eq "test_overlay_dispatch_fires_curl_for_security_overlay: runner exits 0" "0" "$sec_overlay_exit"

if [[ -f "$ARTIFACTS_SEC/reviewer-findings-security-red.json" ]]; then
    _sec_slot_exists=0
else
    _sec_slot_exists=1
fi
assert_eq "test_overlay_dispatch_fires_curl_for_security_overlay: reviewer-findings-security-red.json written" "0" "$_sec_slot_exists"

_curl_call_count=0
if [[ -f "$CURL_CALL_LOG" ]]; then
    _curl_call_count=$(grep -c '^---CURL_CALL---$' "$CURL_CALL_LOG" 2>/dev/null || printf '0')
fi
assert_ne "test_overlay_dispatch_fires_curl_for_security_overlay: more than one curl call (overlay fires)" "1" "$_curl_call_count"

assert_pass_if_clean "test_overlay_dispatch_fires_curl_for_security_overlay"

# ── test_overlay_dispatch_fires_curl_for_performance_overlay ─────────────────
# Given: overlay-flags.env contains performance_overlay=true
# When:  runner reads the env file and dispatches overlays
# Then:  an additional curl call is made using code-reviewer-performance.md
#        and reviewer-findings-performance.json is written to WORKFLOW_PLUGIN_ARTIFACTS_DIR
_snapshot_fail
MOCK_PERF=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK_PERF")
ARTIFACTS_PERF=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS_PERF")
CURL_CALL_LOG_PERF="$MOCK_PERF/curl-calls.log"

cat > "$MOCK_PERF/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK_PERF/review-complexity-classifier.sh"

cat > "$MOCK_PERF/curl" <<MOCKEOF
#!/usr/bin/env bash
prev=""
for i in "\$@"; do
    if [[ "\$prev" == "--data-raw" || "\$prev" == "-d" ]]; then
        printf '%s\n---CURL_CALL---\n' "\$i" >> "${CURL_CALL_LOG_PERF}"
    fi
    prev="\$i"
done
printf '{"content":[{"text":"{\"scores\":{\"hygiene\":4,\"design\":4,\"maintainability\":4,\"correctness\":4,\"verification\":4},\"summary\":\"Performance review completed\",\"findings\":[]}"}],"stop_reason":"end_turn"}'
MOCKEOF
chmod +x "$MOCK_PERF/curl"

cat > "$MOCK_PERF/write-reviewer-findings.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK_PERF/write-reviewer-findings.sh"

cat > "$MOCK_PERF/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "${ARTIFACTS_PERF}"
printf 'passed\n' > "${ARTIFACTS_PERF}/review-status"
MOCKEOF
chmod +x "$MOCK_PERF/record-review.sh"

mkdir -p "$ARTIFACTS_PERF"
printf 'security_overlay=false\nperformance_overlay=true\ntest_quality_overlay=false\n' \
    > "$ARTIFACTS_PERF/overlay-flags.env"

perf_overlay_exit=0
(
    export PATH="$MOCK_PERF:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_PERF"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || perf_overlay_exit=$?

assert_eq "test_overlay_dispatch_fires_curl_for_performance_overlay: runner exits 0" "0" "$perf_overlay_exit"

if [[ -f "$ARTIFACTS_PERF/reviewer-findings-performance.json" ]]; then
    _perf_slot_exists=0
else
    _perf_slot_exists=1
fi
assert_eq "test_overlay_dispatch_fires_curl_for_performance_overlay: reviewer-findings-performance.json written" "0" "$_perf_slot_exists"

_perf_curl_count=0
if [[ -f "$CURL_CALL_LOG_PERF" ]]; then
    _perf_curl_count=$(grep -c '^---CURL_CALL---$' "$CURL_CALL_LOG_PERF" 2>/dev/null || printf '0')
fi
assert_ne "test_overlay_dispatch_fires_curl_for_performance_overlay: more than one curl call (overlay fires)" "1" "$_perf_curl_count"

assert_pass_if_clean "test_overlay_dispatch_fires_curl_for_performance_overlay"

# ── test_overlay_dispatch_no_extra_curls_when_flags_false ─────────────────────
# Given: all overlay flags are false (classifier outputs false; no pre-populated env)
# When:  runner processes the diff
# Then:  exactly one curl call is made (tier call only, no overlay calls)
_snapshot_fail
MOCK_NONE=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK_NONE")
ARTIFACTS_NONE=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS_NONE")
CURL_CALL_LOG_NONE="$MOCK_NONE/curl-calls.log"

cat > "$MOCK_NONE/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK_NONE/review-complexity-classifier.sh"

cat > "$MOCK_NONE/curl" <<MOCKEOF
#!/usr/bin/env bash
prev=""
for i in "\$@"; do
    if [[ "\$prev" == "--data-raw" || "\$prev" == "-d" ]]; then
        printf '%s\n---CURL_CALL---\n' "\$i" >> "${CURL_CALL_LOG_NONE}"
    fi
    prev="\$i"
done
printf '{"content":[{"text":"{\"scores\":{\"hygiene\":4,\"design\":4,\"maintainability\":4,\"correctness\":4,\"verification\":4},\"summary\":\"Tier review completed\",\"findings\":[]}"}],"stop_reason":"end_turn"}'
MOCKEOF
chmod +x "$MOCK_NONE/curl"

cat > "$MOCK_NONE/write-reviewer-findings.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK_NONE/write-reviewer-findings.sh"

cat > "$MOCK_NONE/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "${ARTIFACTS_NONE}"
printf 'passed\n' > "${ARTIFACTS_NONE}/review-status"
MOCKEOF
chmod +x "$MOCK_NONE/record-review.sh"

# No pre-populated overlay-flags.env; classifier outputs all-false so runner writes false flags
none_exit=0
(
    export PATH="$MOCK_NONE:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_NONE"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || none_exit=$?

assert_eq "test_overlay_dispatch_no_extra_curls_when_flags_false: runner exits 0" "0" "$none_exit"

_none_curl_count=0
if [[ -f "$CURL_CALL_LOG_NONE" ]]; then
    _none_curl_count=$(grep -c '^---CURL_CALL---$' "$CURL_CALL_LOG_NONE" 2>/dev/null || printf '0')
fi
# Exactly 1 curl call (tier review only); overlay dispatch must NOT fire
assert_eq "test_overlay_dispatch_no_extra_curls_when_flags_false: exactly one curl call (no overlay dispatch)" "1" "$_none_curl_count"

assert_pass_if_clean "test_overlay_dispatch_no_extra_curls_when_flags_false"

# ── test_security_blue_team_dispatched_after_red_team ─────────────────────────
# Given: overlay-flags.env contains security_overlay=true
# When:  runner dispatches the security overlay
# Then:  after the red-team curl completes, a blue-team curl call is made using
#        code-reviewer-security-blue-team.md; reviewer-findings-security-blue.json
#        is written; both slot files exist when review-status is written (ordering check)
_snapshot_fail
MOCK_BLUE=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK_BLUE")
ARTIFACTS_BLUE=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS_BLUE")
DISPATCH_ORDER_LOG="$MOCK_BLUE/dispatch-order.log"

cat > "$MOCK_BLUE/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK_BLUE/review-complexity-classifier.sh"

# Mock curl: inspect --data-raw body to detect which reviewer is dispatched,
# write the appropriate slot file, and log the dispatch order.
cat > "$MOCK_BLUE/curl" <<MOCKEOF
#!/usr/bin/env bash
# Parse --data-raw argument to identify which agent is being called
_body=""
_prev=""
for _arg in "\$@"; do
    if [[ "\$_prev" == "--data-raw" || "\$_prev" == "-d" ]]; then
        _body="\$_arg"
    fi
    _prev="\$_arg"
done

if printf '%s' "\$_body" | grep -q "code-reviewer-security-red-team"; then
    printf 'red-team\n' >> "${DISPATCH_ORDER_LOG}"
    mkdir -p "${ARTIFACTS_BLUE}"
    printf '{"scores":{"hygiene":4,"design":4,"maintainability":4,"correctness":4,"verification":4},"summary":"Red team review completed","findings":[]}' \
        > "${ARTIFACTS_BLUE}/reviewer-findings-security-red.json"
elif printf '%s' "\$_body" | grep -q "code-reviewer-security-blue-team"; then
    printf 'blue-team\n' >> "${DISPATCH_ORDER_LOG}"
    mkdir -p "${ARTIFACTS_BLUE}"
    printf '{"scores":{"hygiene":4,"design":4,"maintainability":4,"correctness":4,"verification":4},"summary":"Blue team review completed","findings":[]}' \
        > "${ARTIFACTS_BLUE}/reviewer-findings-security-blue.json"
else
    printf 'tier\n' >> "${DISPATCH_ORDER_LOG}"
fi
printf '{"content":[{"text":"{\"scores\":{\"hygiene\":4,\"design\":4,\"maintainability\":4,\"correctness\":4,\"verification\":4},\"summary\":\"Review completed successfully\",\"findings\":[]}"}],"stop_reason":"end_turn"}'
MOCKEOF
chmod +x "$MOCK_BLUE/curl"

cat > "$MOCK_BLUE/write-reviewer-findings.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK_BLUE/write-reviewer-findings.sh"

# record-review checks that both security slot files exist at status-write time
cat > "$MOCK_BLUE/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "${ARTIFACTS_BLUE}"
if [[ -f "${ARTIFACTS_BLUE}/reviewer-findings-security-red.json" && \
      -f "${ARTIFACTS_BLUE}/reviewer-findings-security-blue.json" ]]; then
    printf 'both-slots-present\n' > "${ARTIFACTS_BLUE}/slot-check"
else
    printf 'slots-missing\n' > "${ARTIFACTS_BLUE}/slot-check"
fi
printf 'passed\n' > "${ARTIFACTS_BLUE}/review-status"
MOCKEOF
chmod +x "$MOCK_BLUE/record-review.sh"

mkdir -p "$ARTIFACTS_BLUE"
printf 'security_overlay=true\nperformance_overlay=false\ntest_quality_overlay=false\n' \
    > "$ARTIFACTS_BLUE/overlay-flags.env"

blue_exit=0
(
    export PATH="$MOCK_BLUE:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_BLUE"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || blue_exit=$?

assert_eq "test_security_blue_team_dispatched_after_red_team: runner exits 0" "0" "$blue_exit"

if [[ -f "$ARTIFACTS_BLUE/reviewer-findings-security-red.json" ]]; then _red_slot=0; else _red_slot=1; fi
assert_eq "test_security_blue_team_dispatched_after_red_team: reviewer-findings-security-red.json written" "0" "$_red_slot"

if [[ -f "$ARTIFACTS_BLUE/reviewer-findings-security-blue.json" ]]; then _blue_slot=0; else _blue_slot=1; fi
assert_eq "test_security_blue_team_dispatched_after_red_team: reviewer-findings-security-blue.json written" "0" "$_blue_slot"

_slot_check=""
if [[ -f "$ARTIFACTS_BLUE/slot-check" ]]; then _slot_check=$(cat "$ARTIFACTS_BLUE/slot-check"); fi
assert_eq "test_security_blue_team_dispatched_after_red_team: both slot files present when review-status written" "both-slots-present" "$_slot_check"

# Verify ordering: red-team must appear before blue-team in dispatch log
_dispatch_order=""
if [[ -f "$DISPATCH_ORDER_LOG" ]]; then
    _dispatch_order=$(grep -E "^(red-team|blue-team)$" "$DISPATCH_ORDER_LOG" | paste -s -d',' - 2>/dev/null || true)
fi
assert_eq "test_security_blue_team_dispatched_after_red_team: red-team dispatched before blue-team" "red-team,blue-team" "$_dispatch_order"

assert_pass_if_clean "test_security_blue_team_dispatched_after_red_team"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
