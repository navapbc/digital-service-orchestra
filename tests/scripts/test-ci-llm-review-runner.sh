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

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
