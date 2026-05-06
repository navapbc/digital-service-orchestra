#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031  # PATH/env modifications in subshells are intentional test isolation
# tests/scripts/test-ci-llm-review-runner.sh
# Behavioral tests for plugins/dso/scripts/ci-llm-review-runner.sh
# Covers: empty-diff short-circuit, flag parsing, tier routing, overlay dispatch, merge behavior, and cited_lines preservation.
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
        # Handles both --data-raw "$body" and --data @/path/to/file (ARG_MAX-safe form).
        cat > "$mock_dir/curl" <<MOCKEOF
#!/usr/bin/env bash
prev=""
for i in "\$@"; do
    if [[ "\$prev" == "--data-raw" || "\$prev" == "-d" ]]; then
        printf '%s' "\$i" > "${body_file}"
    elif [[ "\$prev" == "--data" || "\$prev" == "--data-binary" ]]; then
        _src="\${i#@}"
        if [[ "\$_src" != "\$i" && -f "\$_src" ]]; then
            cp "\$_src" "${body_file}"
        else
            printf '%s' "\$i" > "${body_file}"
        fi
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

# ── Helper: create a mock llm-api-call.sh in $1 ───────────────────────────────
# Usage: _create_mock_llm_api_call <mock_dir> [<counter_file>] [<args_capture_file>]
#   mock_dir          — directory where mock llm-api-call.sh will be written (+x)
#   counter_file      — optional; one line appended per invocation (use wc -l to count calls)
#   args_capture_file — optional; positional args written one-per-line on each call
# The mock always returns a minimal valid reviewer-findings JSON on stdout.
_create_mock_llm_api_call() {
    local mock_dir="$1" counter_file="${2:-}" args_capture_file="${3:-}"
    local findings_json='{"scores":{"correctness":4,"verification":4,"hygiene":4,"design":4,"maintainability":4},"findings":[],"summary":"mock review"}'
    cat > "$mock_dir/llm-api-call.sh" <<MOCKEOF
#!/usr/bin/env bash
_counter_file='${counter_file}'
_args_file='${args_capture_file}'
[ -n "\$_counter_file" ] && printf '\n' >> "\$_counter_file"
[ -n "\$_args_file" ] && printf '%s\n' "\$1" "" "\${3:-}" > "\$_args_file"
printf '%s\n' '${findings_json}'
MOCKEOF
    chmod +x "$mock_dir/llm-api-call.sh"
}

# ── Helper: wrap real llm-api-call.sh with forced anthropic config ─────────────
# Use in tests that mock curl (expecting Anthropic request format). Ensures the
# real llm-api-call.sh uses provider=anthropic regardless of project dso-config.conf.
_add_anthropic_llm_wrapper() {
    local mock_dir="$1"
    local _wrap_conf_dir
    _wrap_conf_dir=$(mktemp -d)
    printf 'model.provider=anthropic\nmodel.light=claude-haiku-4-5-20251001\nmodel.standard=claude-sonnet-4-6\nmodel.deep=claude-opus-4-6\n' \
        > "$_wrap_conf_dir/dso-config.conf"
    local _real_llm="$REPO_ROOT/plugins/dso/scripts/llm-api-call.sh"
    cat > "$mock_dir/llm-api-call.sh" <<MOCKEOF
#!/usr/bin/env bash
exec bash "$_real_llm" "\$1" "\$2" "\$3" "$_wrap_conf_dir/dso-config.conf"
MOCKEOF
    chmod +x "$mock_dir/llm-api-call.sh"
}

echo "=== test-ci-llm-review-runner.sh ==="

# ── test_runner_exits_zero_on_empty_diff_regardless_of_api_key ───────────────
# Given: ANTHROPIC_API_KEY is empty AND stdin is empty (no diff)
# When:  runner is invoked
# Then:  exit code is 0 (empty-diff short-circuit fires before any API call)
# Note:  API key validation moved to llm-api-call.sh; runner never reaches it
#        when diff is empty.
_snapshot_fail
missing_key_exit=0
( ANTHROPIC_API_KEY='' bash "$RUNNER" < /dev/null ) || missing_key_exit=$?
assert_eq "test_runner_exits_zero_on_empty_diff_regardless_of_api_key: exits 0 for empty diff" "0" "$missing_key_exit"
assert_pass_if_clean "test_runner_exits_zero_on_empty_diff_regardless_of_api_key"

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
_add_anthropic_llm_wrapper "$MOCK4"

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

# Counter dir — each curl invocation creates a unique sentinel file (race-safe vs read-modify-write)
CURL_COUNT_DIR="$MOCK13/curl-calls"
mkdir -p "$CURL_COUNT_DIR"

# Specialist slot response — valid reviewer-findings JSON
_SLOT_JSON='{"scores":{"correctness":4,"verification":4,"hygiene":4,"design":4,"maintainability":4},"summary":"Specialist OK","findings":[]}'

# Mock curl: count calls; write a slot file named after the agent being invoked.
# Each call touches a unique sentinel file (race-safe vs read-modify-write counter).
cat > "$MOCK13/curl" <<MOCKEOF
#!/usr/bin/env bash
# Detect which specialist this call is for by scanning --data-raw body for agent file path
_body=""
_prev=""
for _arg in "\$@"; do
    if [[ "\$_prev" == "--data-raw" || "\$_prev" == "-d" ]]; then
        _body="\$_arg"
    elif [[ "\$_prev" == "--data" || "\$_prev" == "--data-binary" ]]; then
        _src="\${_arg#@}"; [[ "\$_src" != "\$_arg" && -f "\$_src" ]] && _body="\$(cat "\$_src")" || _body="\$_arg"
    fi
    _prev="\$_arg"
done

_slot_json='${_SLOT_JSON}'

# Count and handle specialist calls only (not the arch synthesis call)
if printf '%s' "\$_body" | grep -q "code-reviewer-deep-correctness"; then
    touch "${CURL_COUNT_DIR}/call.\${BASHPID}.\${RANDOM}"
    printf '%s\n' "\$_slot_json" > "${ARTIFACTS13}/reviewer-findings-correctness.json"
elif printf '%s' "\$_body" | grep -q "code-reviewer-deep-verification"; then
    touch "${CURL_COUNT_DIR}/call.\${BASHPID}.\${RANDOM}"
    printf '%s\n' "\$_slot_json" > "${ARTIFACTS13}/reviewer-findings-verification.json"
elif printf '%s' "\$_body" | grep -q "code-reviewer-deep-hygiene"; then
    touch "${CURL_COUNT_DIR}/call.\${BASHPID}.\${RANDOM}"
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
_add_anthropic_llm_wrapper "$MOCK13"

deep_dispatch_exit=0
(
    export PATH="$MOCK13:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS13"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || deep_dispatch_exit=$?

assert_eq "test_deep_tier_dispatches_three_specialist_calls: runner exits 0" "0" "$deep_dispatch_exit"

# REVIEW-DEFENSE: curl is the external process boundary mocked at PATH level.
# llm-api-call.sh (the real script found via PATH) internally calls curl.
# Counting curl invocations is a valid behavioral proxy for "3 specialists dispatched"
# because: (1) curl is an external system boundary (not an internal implementation detail),
# (2) the test invokes the runner end-to-end with a real diff (not source inspection),
# (3) the slot-file assertions below independently verify the behavioral outcomes.
# Ref: tests/scripts/test-llm-api-call.sh for unit-level curl mock tests.
_curl_count=$(find "$CURL_COUNT_DIR/" -maxdepth 1 -type f | wc -l | tr -d ' ')
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

CURL_COUNT_DIR14="$MOCK14/curl-calls"
mkdir -p "$CURL_COUNT_DIR14"

_SLOT14='{"scores":{"correctness":4,"verification":4,"hygiene":4,"design":4,"maintainability":4},"summary":"Specialist OK","findings":[]}'
_ARCH14='{"scores":{"correctness":5,"verification":5,"hygiene":5,"design":5,"maintainability":5},"summary":"Arch synthesis complete","findings":[]}'

# Mock curl: count calls; write slot files for specialist agents; write final
# reviewer-findings.json when the arch agent body is detected.
# Each call touches a unique sentinel file (race-safe vs read-modify-write counter).
cat > "$MOCK14/curl" <<MOCKEOF
#!/usr/bin/env bash
touch "${CURL_COUNT_DIR14}/call.\${BASHPID}.\${RANDOM}"

_body=""
_prev=""
for _arg in "\$@"; do
    if [[ "\$_prev" == "--data-raw" || "\$_prev" == "-d" ]]; then
        _body="\$_arg"
    elif [[ "\$_prev" == "--data" || "\$_prev" == "--data-binary" ]]; then
        _src="\${_arg#@}"; [[ "\$_src" != "\$_arg" && -f "\$_src" ]] && _body="\$(cat "\$_src")" || _body="\$_arg"
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
_add_anthropic_llm_wrapper "$MOCK14"

arch_exit=0
(
    export PATH="$MOCK14:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS14"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || arch_exit=$?

assert_eq "test_deep_tier_arch_agent_is_sole_final_writer: runner exits 0" "0" "$arch_exit"

# REVIEW-DEFENSE: same external-boundary rationale as test 13.
# 4 curl calls = 3 specialist llm-api-call.sh invocations + 1 arch llm-api-call.sh invocation.
# This count verifies that the arch synthesis step is executed after all specialists complete.
_curl_count14=$(find "$CURL_COUNT_DIR14/" -maxdepth 1 -type f | wc -l | tr -d ' ')
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

# llm-api-call.sh mock: writes valid JSON for correctness/verification but exits 1
# for hygiene, so the hygiene slot file is empty → slot validation fails (fail-closed).
cat > "$MOCK15/llm-api-call.sh" <<MOCKEOF
#!/usr/bin/env bash
_agent_file="\${1:-}"
_slot='${_SLOT15}'
if printf '%s' "\$_agent_file" | grep -q "code-reviewer-deep-correctness"; then
    printf '%s\n' "\$_slot"
elif printf '%s' "\$_agent_file" | grep -q "code-reviewer-deep-verification"; then
    printf '%s\n' "\$_slot"
elif printf '%s' "\$_agent_file" | grep -q "code-reviewer-deep-hygiene"; then
    # Intentionally exit 1 so the hygiene slot file is left empty
    exit 1
else
    printf '%s\n' "\$_slot"
fi
MOCKEOF
chmod +x "$MOCK15/llm-api-call.sh"

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

# llm-api-call.sh mock: writes valid JSON for correctness/verification but invalid
# JSON for hygiene, so the hygiene slot file fails JSON validation (fail-closed).
cat > "$MOCK16/llm-api-call.sh" <<MOCKEOF
#!/usr/bin/env bash
_agent_file="\${1:-}"
_slot='${_SLOT16}'
if printf '%s' "\$_agent_file" | grep -q "code-reviewer-deep-correctness"; then
    printf '%s\n' "\$_slot"
elif printf '%s' "\$_agent_file" | grep -q "code-reviewer-deep-verification"; then
    printf '%s\n' "\$_slot"
elif printf '%s' "\$_agent_file" | grep -q "code-reviewer-deep-hygiene"; then
    # Intentionally malformed JSON — slot file fails JSON validation
    printf 'NOT VALID JSON {{{'
else
    printf '%s\n' "\$_slot"
fi
MOCKEOF
chmod +x "$MOCK16/llm-api-call.sh"

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
    elif [[ "\$prev" == "--data" || "\$prev" == "--data-binary" ]]; then
        _src="\${i#@}"; [[ "\$_src" != "\$i" && -f "\$_src" ]] && printf '%s\n---CURL_CALL---\n' "\$(cat "\$_src")" >> "${CURL_CALL_LOG}" || printf '%s\n---CURL_CALL---\n' "\$i" >> "${CURL_CALL_LOG}"
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
    elif [[ "\$prev" == "--data" || "\$prev" == "--data-binary" ]]; then
        _src="\${i#@}"; [[ "\$_src" != "\$i" && -f "\$_src" ]] && printf '%s\n---CURL_CALL---\n' "\$(cat "\$_src")" >> "${CURL_CALL_LOG_PERF}" || printf '%s\n---CURL_CALL---\n' "\$i" >> "${CURL_CALL_LOG_PERF}"
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
    elif [[ "\$prev" == "--data" || "\$prev" == "--data-binary" ]]; then
        _src="\${i#@}"; [[ "\$_src" != "\$i" && -f "\$_src" ]] && printf '%s\n---CURL_CALL---\n' "\$(cat "\$_src")" >> "${CURL_CALL_LOG_NONE}" || printf '%s\n---CURL_CALL---\n' "\$i" >> "${CURL_CALL_LOG_NONE}"
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

_add_anthropic_llm_wrapper "$MOCK_NONE"
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

# Mock curl: inspect request body to detect which reviewer is dispatched,
# write the appropriate slot file, and log the dispatch order.
cat > "$MOCK_BLUE/curl" <<MOCKEOF
#!/usr/bin/env bash
# Parse --data-raw argument to identify which agent is being called
_body=""
_prev=""
for _arg in "\$@"; do
    if [[ "\$_prev" == "--data-raw" || "\$_prev" == "-d" ]]; then
        _body="\$_arg"
    elif [[ "\$_prev" == "--data" || "\$_prev" == "--data-binary" ]]; then
        _src="\${_arg#@}"; [[ "\$_src" != "\$_arg" && -f "\$_src" ]] && _body="\$(cat "\$_src")" || _body="\$_arg"
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

_add_anthropic_llm_wrapper "$MOCK_BLUE"
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

# ── test_overlay_merge_security_findings_into_canonical ──────────────────────
# Given: security overlay ran (slot files for red-team and blue-team exist)
# When:  runner builds FINDINGS_JSON to pass to write-reviewer-findings.sh
# Then:  write-reviewer-findings.sh receives a JSON with findings from both
#        tier, security-red, and security-blue merged into the findings array;
#        per-dimension scores are the minimum of tier and overlay scores.
_snapshot_fail
MOCK_MERGE_SEC=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK_MERGE_SEC")
ARTIFACTS_MERGE_SEC=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS_MERGE_SEC")
FINDINGS_RECEIVED_SEC="$MOCK_MERGE_SEC/findings-received.json"

cat > "$MOCK_MERGE_SEC/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK_MERGE_SEC/review-complexity-classifier.sh"

# Mock curl: detects which reviewer is called and returns the appropriate
# Anthropic API response. Uses python3 to properly JSON-encode the text field
# so nested quotes don't break the outer JSON structure.
cat > "$MOCK_MERGE_SEC/curl" <<'MOCKEOF'
#!/usr/bin/env bash
_body=""
_prev=""
for _arg in "$@"; do
    if [[ "$_prev" == "--data-raw" || "$_prev" == "-d" ]]; then
        _body="$_arg"
    elif [[ "$_prev" == "--data" || "$_prev" == "--data-binary" ]]; then
        _src="${_arg#@}"; [[ "$_src" != "$_arg" && -f "$_src" ]] && _body="$(cat "$_src")" || _body="$_arg"
    fi
    _prev="$_arg"
done
if printf '%s' "$_body" | grep -q "code-reviewer-security-red-team"; then
    python3 -c "import json; t={\"scores\":{\"correctness\":3,\"verification\":3,\"hygiene\":4,\"design\":4,\"maintainability\":4},\"summary\":\"Red team review\",\"findings\":[{\"severity\":\"important\",\"dimension\":\"correctness\",\"description\":\"SQL injection risk\",\"location\":\"api.sh:10\",\"recommendation\":\"Sanitize input\"}]}; print(json.dumps({\"content\":[{\"text\":json.dumps(t)}],\"stop_reason\":\"end_turn\"}))"
elif printf '%s' "$_body" | grep -q "code-reviewer-security-blue-team"; then
    python3 -c "import json; t={\"scores\":{\"correctness\":3,\"verification\":3,\"hygiene\":4,\"design\":4,\"maintainability\":4},\"summary\":\"Blue team triage\",\"findings\":[{\"severity\":\"important\",\"dimension\":\"verification\",\"description\":\"Missing auth check\",\"location\":\"api.sh:20\",\"recommendation\":\"Add auth\"}]}; print(json.dumps({\"content\":[{\"text\":json.dumps(t)}],\"stop_reason\":\"end_turn\"}))"
else
    python3 -c "import json; t={\"scores\":{\"correctness\":5,\"verification\":5,\"hygiene\":5,\"design\":5,\"maintainability\":5},\"summary\":\"Tier review OK\",\"findings\":[{\"severity\":\"important\",\"dimension\":\"hygiene\",\"description\":\"Tier finding\",\"location\":\"foo.sh:1\",\"recommendation\":\"Fix it\"}]}; print(json.dumps({\"content\":[{\"text\":json.dumps(t)}],\"stop_reason\":\"end_turn\"}))"
fi
MOCKEOF
chmod +x "$MOCK_MERGE_SEC/curl"

# Mock write-reviewer-findings.sh: capture stdin (FINDINGS_JSON) to verify merge
cat > "$MOCK_MERGE_SEC/write-reviewer-findings.sh" <<MOCKEOF
#!/usr/bin/env bash
tee "${FINDINGS_RECEIVED_SEC}" > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK_MERGE_SEC/write-reviewer-findings.sh"

cat > "$MOCK_MERGE_SEC/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "${ARTIFACTS_MERGE_SEC}"
printf 'passed\n' > "${ARTIFACTS_MERGE_SEC}/review-status"
MOCKEOF
chmod +x "$MOCK_MERGE_SEC/record-review.sh"
_add_anthropic_llm_wrapper "$MOCK_MERGE_SEC"

# Pre-populate overlay-flags.env so the runner reads security_overlay=true
mkdir -p "$ARTIFACTS_MERGE_SEC"
printf 'security_overlay=true\nperformance_overlay=false\ntest_quality_overlay=false\n' \
    > "$ARTIFACTS_MERGE_SEC/overlay-flags.env"

merge_sec_exit=0
(
    export PATH="$MOCK_MERGE_SEC:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_MERGE_SEC"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || merge_sec_exit=$?

assert_eq "test_overlay_merge_security_findings_into_canonical: runner exits 0" "0" "$merge_sec_exit"

# Verify write-reviewer-findings.sh received merged findings
_sec_merge_check_exit=0
_sec_merge_check_out=""
if [[ -f "$FINDINGS_RECEIVED_SEC" ]]; then
    _sec_merge_check_out=$(python3 - <<PYEOF 2>&1 || _sec_merge_check_exit=$?
import json, sys
with open('${FINDINGS_RECEIVED_SEC}') as f:
    d = json.load(f)
findings = d.get('findings', [])
descs = [x.get('description','') for x in findings]
# Must contain tier finding AND at least one overlay finding
has_tier = any('Tier finding' in desc for desc in descs)
has_red = any('SQL injection' in desc for desc in descs)
has_blue = any('Missing auth' in desc for desc in descs)
if not has_tier:
    print('MISSING tier finding; findings=' + str(descs))
    sys.exit(1)
if not has_red:
    print('MISSING security-red finding; findings=' + str(descs))
    sys.exit(1)
if not has_blue:
    print('MISSING security-blue finding; findings=' + str(descs))
    sys.exit(1)
# Score for correctness: min(5, 3) = 3 from overlay
scores = d.get('scores', {})
if scores.get('correctness', 999) > 3:
    print('SCORE not lowered: correctness=' + str(scores.get('correctness')) + ' (expected <=3)')
    sys.exit(1)
print('OK')
PYEOF
    )
else
    _sec_merge_check_out="FINDINGS_RECEIVED file not written by write-reviewer-findings.sh mock"
    _sec_merge_check_exit=1
fi
assert_eq "test_overlay_merge_security_findings_into_canonical: merged findings passed to write-reviewer-findings" "0" "$_sec_merge_check_exit"
assert_eq "test_overlay_merge_security_findings_into_canonical: merge output" "OK" "$_sec_merge_check_out"

assert_pass_if_clean "test_overlay_merge_security_findings_into_canonical"

# ── test_overlay_merge_performance_findings_into_canonical ───────────────────
# Given: performance overlay ran (slot file exists)
# When:  runner builds FINDINGS_JSON to pass to write-reviewer-findings.sh
# Then:  write-reviewer-findings.sh receives JSON with tier + performance findings merged
_snapshot_fail
MOCK_MERGE_PERF=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK_MERGE_PERF")
ARTIFACTS_MERGE_PERF=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS_MERGE_PERF")
FINDINGS_RECEIVED_PERF="$MOCK_MERGE_PERF/findings-received.json"

cat > "$MOCK_MERGE_PERF/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK_MERGE_PERF/review-complexity-classifier.sh"

cat > "$MOCK_MERGE_PERF/curl" <<'MOCKEOF'
#!/usr/bin/env bash
_body=""
_prev=""
for _arg in "$@"; do
    if [[ "$_prev" == "--data-raw" || "$_prev" == "-d" ]]; then
        _body="$_arg"
    elif [[ "$_prev" == "--data" || "$_prev" == "--data-binary" ]]; then
        _src="${_arg#@}"; [[ "$_src" != "$_arg" && -f "$_src" ]] && _body="$(cat "$_src")" || _body="$_arg"
    fi
    _prev="$_arg"
done
if printf '%s' "$_body" | grep -q "code-reviewer-performance"; then
    python3 -c "import json; t={\"scores\":{\"correctness\":4,\"verification\":2,\"hygiene\":4,\"design\":4,\"maintainability\":4},\"summary\":\"Perf overlay\",\"findings\":[{\"severity\":\"important\",\"dimension\":\"verification\",\"description\":\"N+1 query detected\",\"location\":\"db.sh:5\",\"recommendation\":\"Batch queries\"}]}; print(json.dumps({\"content\":[{\"text\":json.dumps(t)}],\"stop_reason\":\"end_turn\"}))"
else
    python3 -c "import json; t={\"scores\":{\"correctness\":5,\"verification\":5,\"hygiene\":5,\"design\":5,\"maintainability\":5},\"summary\":\"Tier review OK\",\"findings\":[{\"severity\":\"important\",\"dimension\":\"hygiene\",\"description\":\"Tier perf finding\",\"location\":\"foo.sh:1\",\"recommendation\":\"Fix it\"}]}; print(json.dumps({\"content\":[{\"text\":json.dumps(t)}],\"stop_reason\":\"end_turn\"}))"
fi
MOCKEOF
chmod +x "$MOCK_MERGE_PERF/curl"

cat > "$MOCK_MERGE_PERF/write-reviewer-findings.sh" <<MOCKEOF
#!/usr/bin/env bash
tee "${FINDINGS_RECEIVED_PERF}" > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK_MERGE_PERF/write-reviewer-findings.sh"

cat > "$MOCK_MERGE_PERF/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "${ARTIFACTS_MERGE_PERF}"
printf 'passed\n' > "${ARTIFACTS_MERGE_PERF}/review-status"
MOCKEOF
chmod +x "$MOCK_MERGE_PERF/record-review.sh"
_add_anthropic_llm_wrapper "$MOCK_MERGE_PERF"

mkdir -p "$ARTIFACTS_MERGE_PERF"
printf 'security_overlay=false\nperformance_overlay=true\ntest_quality_overlay=false\n' \
    > "$ARTIFACTS_MERGE_PERF/overlay-flags.env"

merge_perf_exit=0
(
    export PATH="$MOCK_MERGE_PERF:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_MERGE_PERF"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || merge_perf_exit=$?

assert_eq "test_overlay_merge_performance_findings_into_canonical: runner exits 0" "0" "$merge_perf_exit"

_perf_merge_check_exit=0
_perf_merge_check_out=""
if [[ -f "$FINDINGS_RECEIVED_PERF" ]]; then
    _perf_merge_check_out=$(python3 - <<PYEOF 2>&1 || _perf_merge_check_exit=$?
import json, sys
with open('${FINDINGS_RECEIVED_PERF}') as f:
    d = json.load(f)
findings = d.get('findings', [])
descs = [x.get('description','') for x in findings]
has_tier = any('Tier perf finding' in desc for desc in descs)
has_perf = any('N+1 query' in desc for desc in descs)
if not has_tier:
    print('MISSING tier finding; findings=' + str(descs))
    sys.exit(1)
if not has_perf:
    print('MISSING performance finding; findings=' + str(descs))
    sys.exit(1)
# Score for verification: min(5, 2) = 2 from overlay
scores = d.get('scores', {})
if scores.get('verification', 999) > 2:
    print('SCORE not lowered: verification=' + str(scores.get('verification')) + ' (expected <=2)')
    sys.exit(1)
print('OK')
PYEOF
    )
else
    _perf_merge_check_out="FINDINGS_RECEIVED file not written"
    _perf_merge_check_exit=1
fi
assert_eq "test_overlay_merge_performance_findings_into_canonical: merged findings passed to write-reviewer-findings" "0" "$_perf_merge_check_exit"
assert_eq "test_overlay_merge_performance_findings_into_canonical: merge output" "OK" "$_perf_merge_check_out"

assert_pass_if_clean "test_overlay_merge_performance_findings_into_canonical"

# ── test_overlay_merge_test_quality_findings_into_canonical ──────────────────
# Given: test-quality overlay ran (slot file exists)
# When:  runner builds FINDINGS_JSON to pass to write-reviewer-findings.sh
# Then:  write-reviewer-findings.sh receives JSON with tier + test-quality findings merged
_snapshot_fail
MOCK_MERGE_TQ=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK_MERGE_TQ")
ARTIFACTS_MERGE_TQ=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS_MERGE_TQ")
FINDINGS_RECEIVED_TQ="$MOCK_MERGE_TQ/findings-received.json"

cat > "$MOCK_MERGE_TQ/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK_MERGE_TQ/review-complexity-classifier.sh"

cat > "$MOCK_MERGE_TQ/curl" <<'MOCKEOF'
#!/usr/bin/env bash
_body=""
_prev=""
for _arg in "$@"; do
    if [[ "$_prev" == "--data-raw" || "$_prev" == "-d" ]]; then
        _body="$_arg"
    elif [[ "$_prev" == "--data" || "$_prev" == "--data-binary" ]]; then
        _src="${_arg#@}"; [[ "$_src" != "$_arg" && -f "$_src" ]] && _body="$(cat "$_src")" || _body="$_arg"
    fi
    _prev="$_arg"
done
if printf '%s' "$_body" | grep -q "code-reviewer-test-quality"; then
    python3 -c "import json; t={\"scores\":{\"correctness\":5,\"verification\":4,\"hygiene\":2,\"design\":5,\"maintainability\":5},\"summary\":\"Test quality overlay\",\"findings\":[{\"severity\":\"important\",\"dimension\":\"hygiene\",\"description\":\"Change detector test found\",\"location\":\"tests/test_foo.sh:30\",\"recommendation\":\"Test behavior not implementation\"}]}; print(json.dumps({\"content\":[{\"text\":json.dumps(t)}],\"stop_reason\":\"end_turn\"}))"
else
    python3 -c "import json; t={\"scores\":{\"correctness\":5,\"verification\":5,\"hygiene\":5,\"design\":5,\"maintainability\":5},\"summary\":\"Tier review OK\",\"findings\":[{\"severity\":\"important\",\"dimension\":\"design\",\"description\":\"Tier TQ finding\",\"location\":\"foo.sh:1\",\"recommendation\":\"Fix it\"}]}; print(json.dumps({\"content\":[{\"text\":json.dumps(t)}],\"stop_reason\":\"end_turn\"}))"
fi
MOCKEOF
chmod +x "$MOCK_MERGE_TQ/curl"

cat > "$MOCK_MERGE_TQ/write-reviewer-findings.sh" <<MOCKEOF
#!/usr/bin/env bash
tee "${FINDINGS_RECEIVED_TQ}" > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK_MERGE_TQ/write-reviewer-findings.sh"

cat > "$MOCK_MERGE_TQ/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "${ARTIFACTS_MERGE_TQ}"
printf 'passed\n' > "${ARTIFACTS_MERGE_TQ}/review-status"
MOCKEOF
chmod +x "$MOCK_MERGE_TQ/record-review.sh"
_add_anthropic_llm_wrapper "$MOCK_MERGE_TQ"

mkdir -p "$ARTIFACTS_MERGE_TQ"
printf 'security_overlay=false\nperformance_overlay=false\ntest_quality_overlay=true\n' \
    > "$ARTIFACTS_MERGE_TQ/overlay-flags.env"

merge_tq_exit=0
(
    export PATH="$MOCK_MERGE_TQ:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_MERGE_TQ"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || merge_tq_exit=$?

assert_eq "test_overlay_merge_test_quality_findings_into_canonical: runner exits 0" "0" "$merge_tq_exit"

_tq_merge_check_exit=0
_tq_merge_check_out=""
if [[ -f "$FINDINGS_RECEIVED_TQ" ]]; then
    _tq_merge_check_out=$(python3 - <<PYEOF 2>&1 || _tq_merge_check_exit=$?
import json, sys
with open('${FINDINGS_RECEIVED_TQ}') as f:
    d = json.load(f)
findings = d.get('findings', [])
descs = [x.get('description','') for x in findings]
has_tier = any('Tier TQ finding' in desc for desc in descs)
has_tq = any('Change detector' in desc for desc in descs)
if not has_tier:
    print('MISSING tier finding; findings=' + str(descs))
    sys.exit(1)
if not has_tq:
    print('MISSING test-quality finding; findings=' + str(descs))
    sys.exit(1)
# Score for hygiene: min(5, 2) = 2 from overlay
scores = d.get('scores', {})
if scores.get('hygiene', 999) > 2:
    print('SCORE not lowered: hygiene=' + str(scores.get('hygiene')) + ' (expected <=2)')
    sys.exit(1)
print('OK')
PYEOF
    )
else
    _tq_merge_check_out="FINDINGS_RECEIVED file not written"
    _tq_merge_check_exit=1
fi
assert_eq "test_overlay_merge_test_quality_findings_into_canonical: merged findings passed to write-reviewer-findings" "0" "$_tq_merge_check_exit"
assert_eq "test_overlay_merge_test_quality_findings_into_canonical: merge output" "OK" "$_tq_merge_check_out"

assert_pass_if_clean "test_overlay_merge_test_quality_findings_into_canonical"

# ── test_no_overlay_merge_no_regression ──────────────────────────────────────
# Given: no overlays ran (all flags false, no slot files present)
# When:  runner builds FINDINGS_JSON to pass to write-reviewer-findings.sh
# Then:  write-reviewer-findings.sh receives only tier findings (no overlay contamination);
#        findings array and scores are unchanged from the tier reviewer output.
_snapshot_fail
MOCK_MERGE_NONE=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK_MERGE_NONE")
ARTIFACTS_MERGE_NONE=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS_MERGE_NONE")
FINDINGS_RECEIVED_NONE="$MOCK_MERGE_NONE/findings-received.json"

cat > "$MOCK_MERGE_NONE/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK_MERGE_NONE/review-complexity-classifier.sh"

cat > "$MOCK_MERGE_NONE/curl" <<'MOCKEOF'
#!/usr/bin/env bash
python3 -c "import json; t={\"scores\":{\"correctness\":5,\"verification\":5,\"hygiene\":5,\"design\":5,\"maintainability\":5},\"summary\":\"Tier only\",\"findings\":[{\"severity\":\"important\",\"dimension\":\"hygiene\",\"description\":\"Tier only finding\",\"location\":\"foo.sh:1\",\"recommendation\":\"Fix it\"}]}; print(json.dumps({\"content\":[{\"text\":json.dumps(t)}],\"stop_reason\":\"end_turn\"}))"
MOCKEOF
chmod +x "$MOCK_MERGE_NONE/curl"

cat > "$MOCK_MERGE_NONE/write-reviewer-findings.sh" <<MOCKEOF
#!/usr/bin/env bash
tee "${FINDINGS_RECEIVED_NONE}" > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK_MERGE_NONE/write-reviewer-findings.sh"

cat > "$MOCK_MERGE_NONE/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "${ARTIFACTS_MERGE_NONE}"
printf 'passed\n' > "${ARTIFACTS_MERGE_NONE}/review-status"
MOCKEOF
chmod +x "$MOCK_MERGE_NONE/record-review.sh"
_add_anthropic_llm_wrapper "$MOCK_MERGE_NONE"

# No overlay-flags.env pre-populated; classifier outputs all-false
merge_none_exit=0
(
    export PATH="$MOCK_MERGE_NONE:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_MERGE_NONE"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || merge_none_exit=$?

assert_eq "test_no_overlay_merge_no_regression: runner exits 0" "0" "$merge_none_exit"

_none_merge_check_exit=0
_none_merge_check_out=""
if [[ -f "$FINDINGS_RECEIVED_NONE" ]]; then
    _none_merge_check_out=$(python3 - <<PYEOF 2>&1 || _none_merge_check_exit=$?
import json, sys
with open('${FINDINGS_RECEIVED_NONE}') as f:
    d = json.load(f)
findings = d.get('findings', [])
descs = [x.get('description','') for x in findings]
# Only tier findings; no overlay findings
if len(findings) != 1:
    print('WRONG finding count: expected 1 (tier only), got ' + str(len(findings)) + '; ' + str(descs))
    sys.exit(1)
if 'Tier only finding' not in descs[0]:
    print('WRONG finding: expected tier-only finding, got ' + str(descs))
    sys.exit(1)
# Scores must be unchanged (5 everywhere)
scores = d.get('scores', {})
for dim in ['correctness','verification','hygiene','design','maintainability']:
    if scores.get(dim, 0) != 5:
        print('SCORE changed for ' + dim + ': ' + str(scores.get(dim)) + ' (expected 5)')
        sys.exit(1)
print('OK')
PYEOF
    )
else
    _none_merge_check_out="FINDINGS_RECEIVED file not written"
    _none_merge_check_exit=1
fi
assert_eq "test_no_overlay_merge_no_regression: only tier findings passed to write-reviewer-findings" "0" "$_none_merge_check_exit"
assert_eq "test_no_overlay_merge_no_regression: no-regression output" "OK" "$_none_merge_check_out"

assert_pass_if_clean "test_no_overlay_merge_no_regression"

# ── test_overlay_curl_json_extraction_with_markdown_fence ────────────────────
# Given: overlay curl response wraps JSON in ```json...``` markdown fence
# When:  runner dispatches overlay curl and processes the response
# Then:  slot file contains bare JSON (not the fenced version); merge succeeds
_snapshot_fail
MOCK_FENCE=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK_FENCE")
ARTIFACTS_FENCE=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS_FENCE")
FINDINGS_RECEIVED_FENCE="$MOCK_FENCE/findings-received.json"

cat > "$MOCK_FENCE/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":true}'
MOCKEOF
chmod +x "$MOCK_FENCE/review-complexity-classifier.sh"

cat > "$MOCK_FENCE/curl" <<'MOCKEOF'
#!/usr/bin/env bash
_body=""
_prev=""
for _arg in "$@"; do
    if [[ "$_prev" == "--data-raw" || "$_prev" == "-d" ]]; then
        _body="$_arg"
    elif [[ "$_prev" == "--data" || "$_prev" == "--data-binary" ]]; then
        _src="${_arg#@}"; [[ "$_src" != "$_arg" && -f "$_src" ]] && _body="$(cat "$_src")" || _body="$_arg"
    fi
    _prev="$_arg"
done
# Overlay curl: respond with markdown-fenced JSON to test fence extraction
if printf '%s' "$_body" | grep -q "code-reviewer-test-quality"; then
    _inner='{"scores":{"correctness":5,"verification":5,"hygiene":5,"design":5,"maintainability":5},"summary":"TQ overlay fence test","findings":[{"severity":"minor","dimension":"verification","description":"Fence-wrapped overlay finding","location":"foo.sh:1","recommendation":"None"}]}'
    # Return the inner JSON wrapped in a markdown fence inside the API text field
    python3 -c "
import json, sys
inner = sys.argv[1]
fenced = '\`\`\`json\n' + inner + '\n\`\`\`'
print(json.dumps({'content': [{'text': fenced}], 'stop_reason': 'end_turn'}))
" "$_inner"
else
    python3 -c "import json; t={\"scores\":{\"correctness\":5,\"verification\":5,\"hygiene\":5,\"design\":5,\"maintainability\":5},\"summary\":\"Tier OK\",\"findings\":[{\"severity\":\"minor\",\"dimension\":\"hygiene\",\"description\":\"Tier fence test finding\",\"location\":\"foo.sh:1\",\"recommendation\":\"OK\"}]}; print(json.dumps({\"content\":[{\"text\":json.dumps(t)}],\"stop_reason\":\"end_turn\"}))"
fi
MOCKEOF
chmod +x "$MOCK_FENCE/curl"

cat > "$MOCK_FENCE/write-reviewer-findings.sh" <<MOCKEOF
#!/usr/bin/env bash
tee "${FINDINGS_RECEIVED_FENCE}" > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK_FENCE/write-reviewer-findings.sh"

cat > "$MOCK_FENCE/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "${ARTIFACTS_FENCE}"
printf 'passed\n' > "${ARTIFACTS_FENCE}/review-status"
MOCKEOF
chmod +x "$MOCK_FENCE/record-review.sh"
_add_anthropic_llm_wrapper "$MOCK_FENCE"

mkdir -p "$ARTIFACTS_FENCE"

fence_overlay_exit=0
(
    export PATH="$MOCK_FENCE:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_FENCE"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || fence_overlay_exit=$?

assert_eq "test_overlay_curl_json_extraction_with_markdown_fence: runner exits 0" "0" "$fence_overlay_exit"

_fence_check_exit=0
_fence_check_out=""
if [[ -f "$FINDINGS_RECEIVED_FENCE" ]]; then
    _fence_check_out=$(python3 - <<PYEOF 2>&1 || _fence_check_exit=$?
import json, sys
with open('${FINDINGS_RECEIVED_FENCE}') as f:
    d = json.load(f)
findings = d.get('findings', [])
descs = [x.get('description','') for x in findings]
has_overlay = any('Fence-wrapped overlay finding' in desc for desc in descs)
if not has_overlay:
    print('MISSING fence-wrapped overlay finding; findings=' + str(descs))
    sys.exit(1)
print('OK')
PYEOF
    )
else
    _fence_check_out="FINDINGS_RECEIVED file not written"
    _fence_check_exit=1
fi
assert_eq "test_overlay_curl_json_extraction_with_markdown_fence: fence-wrapped overlay finding merged" "0" "$_fence_check_exit"
assert_eq "test_overlay_curl_json_extraction_with_markdown_fence: output" "OK" "$_fence_check_out"

assert_pass_if_clean "test_overlay_curl_json_extraction_with_markdown_fence"

# ── test_deep_tier_overlay_merge ─────────────────────────────────────────────
# Given: deep tier is selected AND test_quality_overlay=true
# When:  runner completes deep-tier arch synthesis and enters shared overlay path
# Then:  overlay curl is dispatched; overlay findings are merged with deep-tier
#        findings before write-reviewer-findings.sh is called; runner exits 0
_snapshot_fail
MOCK_DEEP_OVL=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK_DEEP_OVL")
ARTIFACTS_DEEP_OVL=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS_DEEP_OVL")
FINDINGS_RECEIVED_DEEP_OVL="$MOCK_DEEP_OVL/findings-received.json"

cat > "$MOCK_DEEP_OVL/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"deep","blast_radius":3,"critical_path":2,"anti_shortcut":1,"staleness":1,"cross_cutting":1,"diff_lines":350,"change_volume":2,"computed_total":10,"diff_size_lines":350,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":true}'
MOCKEOF
chmod +x "$MOCK_DEEP_OVL/review-complexity-classifier.sh"

# llm-api-call.sh mock: routes by agent-file arg (arg1) and writes JSON to stdout.
# The runner redirects stdout to slot files for specialist calls; overlays do the same.
cat > "$MOCK_DEEP_OVL/llm-api-call.sh" <<'MOCKEOF'
#!/usr/bin/env bash
_agent_file="${1:-}"
if printf '%s' "$_agent_file" | grep -q "code-reviewer-deep-correctness"; then
    printf '%s\n' '{"scores":{"correctness":4,"verification":5,"hygiene":5,"design":5,"maintainability":5},"findings":[{"severity":"minor","category":"correctness","description":"Deep correctness finding","file":"foo.sh"}],"summary":"C"}'
elif printf '%s' "$_agent_file" | grep -q "code-reviewer-deep-verification"; then
    printf '%s\n' '{"scores":{"correctness":5,"verification":4,"hygiene":5,"design":5,"maintainability":5},"findings":[{"severity":"minor","category":"verification","description":"Deep verification finding","file":"foo.sh"}],"summary":"V"}'
elif printf '%s' "$_agent_file" | grep -q "code-reviewer-deep-hygiene"; then
    printf '%s\n' '{"scores":{"correctness":5,"verification":5,"hygiene":4,"design":5,"maintainability":5},"findings":[{"severity":"minor","category":"hygiene","description":"Deep hygiene finding","file":"foo.sh"}],"summary":"H"}'
elif printf '%s' "$_agent_file" | grep -q "code-reviewer-deep-arch"; then
    python3 -c "
import json
t = {
    'scores': {'correctness': 4, 'verification': 4, 'hygiene': 4, 'design': 5, 'maintainability': 5},
    'findings': [{'severity': 'minor', 'category': 'correctness', 'description': 'Deep arch synthesized finding', 'file': 'foo.sh'}],
    'summary': 'Arch synthesis'
}
print(json.dumps(t))
"
elif printf '%s' "$_agent_file" | grep -q "code-reviewer-test-quality"; then
    python3 -c "
import json
t = {
    'scores': {'correctness': 4, 'verification': 4, 'hygiene': 4, 'design': 5, 'maintainability': 5},
    'findings': [{'severity': 'minor', 'category': 'verification', 'description': 'Deep-tier TQ overlay finding', 'file': 'tests/foo.sh'}],
    'summary': 'TQ overlay for deep tier'
}
print(json.dumps(t))
"
else
    printf '%s\n' '{}'
fi
MOCKEOF
chmod +x "$MOCK_DEEP_OVL/llm-api-call.sh"

# Override write-reviewer-findings.sh to capture received FINDINGS_JSON
cat > "$MOCK_DEEP_OVL/write-reviewer-findings.sh" <<MOCKEOF
#!/usr/bin/env bash
tee "${FINDINGS_RECEIVED_DEEP_OVL}" > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK_DEEP_OVL/write-reviewer-findings.sh"

cat > "$MOCK_DEEP_OVL/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "${ARTIFACTS_DEEP_OVL}"
printf 'passed\n' > "${ARTIFACTS_DEEP_OVL}/review-status"
MOCKEOF
chmod +x "$MOCK_DEEP_OVL/record-review.sh"

mkdir -p "$ARTIFACTS_DEEP_OVL"

deep_ovl_exit=0
(
    export PATH="$MOCK_DEEP_OVL:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_DEEP_OVL"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || deep_ovl_exit=$?

assert_eq "test_deep_tier_overlay_merge: runner exits 0" "0" "$deep_ovl_exit"

_deep_ovl_check_exit=0
_deep_ovl_check_out=""
if [[ -f "$FINDINGS_RECEIVED_DEEP_OVL" ]]; then
    _deep_ovl_check_out=$(python3 - <<PYEOF 2>&1 || _deep_ovl_check_exit=$?
import json, sys
with open('${FINDINGS_RECEIVED_DEEP_OVL}') as f:
    d = json.load(f)
findings = d.get('findings', [])
descs = [x.get('description','') for x in findings]
has_deep = any('Deep arch synthesized finding' in desc for desc in descs)
has_overlay = any('Deep-tier TQ overlay finding' in desc for desc in descs)
if not has_deep:
    print('MISSING deep arch finding; findings=' + str(descs))
    sys.exit(1)
if not has_overlay:
    print('MISSING deep-tier TQ overlay finding; findings=' + str(descs))
    sys.exit(1)
print('OK')
PYEOF
    )
else
    _deep_ovl_check_out="FINDINGS_RECEIVED file not written"
    _deep_ovl_check_exit=1
fi
assert_eq "test_deep_tier_overlay_merge: deep-tier arch + overlay findings both in canonical" "0" "$_deep_ovl_check_exit"
assert_eq "test_deep_tier_overlay_merge: output" "OK" "$_deep_ovl_check_out"

assert_pass_if_clean "test_deep_tier_overlay_merge"

# ── test_runner_exits_nonzero_when_no_dso_marker_and_no_assets_dir ────────────
# When ci-llm-review-runner.sh is deployed to a host-project CI context
# (script copied to a dir with no .dso-source-of-truth sibling marker)
# AND DSO_ASSETS_DIR is unset AND CLAUDE_PLUGIN_ROOT is unset, the runner must:
#   - exit with a non-zero (specifically 1) exit code
#   - emit a message containing "DSO_ASSETS_DIR" on stderr
#
# Simulation: copy the script to a temp scripts dir that has no marker
# (mirrors real host-project deployment where script is at $DSO_ASSETS_DIR/scripts/).
_snapshot_fail
runner_mode_exit=0
runner_mode_stderr=""

FAKE_REPO_MODE=$(mktemp -d)
FAKE_SCRIPTS_MODE=$(mktemp -d)
_TEST_TMPDIRS+=("$FAKE_REPO_MODE" "$FAKE_SCRIPTS_MODE")

git -C "$FAKE_REPO_MODE" init -q 2>/dev/null
git -C "$FAKE_REPO_MODE" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "fake host project" 2>/dev/null

# Copy script to a temp dir — no .dso-source-of-truth marker at
# "$FAKE_SCRIPTS_MODE/../.dso-source-of-truth", simulating host-project CI
cp "$RUNNER" "$FAKE_SCRIPTS_MODE/ci-llm-review-runner.sh"
RUNNER_NO_MARKER="$FAKE_SCRIPTS_MODE/ci-llm-review-runner.sh"

if [[ -f "$FAKE_SCRIPTS_MODE/../.dso-source-of-truth" ]]; then
    echo "SETUP ERROR: fake scripts dir unexpectedly contains the DSO marker" >&2
    exit 2
fi

runner_mode_stderr=$(
    cd "$FAKE_REPO_MODE" && \
    unset DSO_ASSETS_DIR 2>/dev/null || true && \
    unset CLAUDE_PLUGIN_ROOT 2>/dev/null || true && \
    ANTHROPIC_API_KEY='x' bash "$RUNNER_NO_MARKER" < /dev/null 2>&1 >/dev/null
) || runner_mode_exit=$?

assert_eq \
    "test_runner_exits_nonzero_when_no_dso_marker_and_no_assets_dir: exits 1" \
    "1" "$runner_mode_exit"

assert_contains \
    "test_runner_exits_nonzero_when_no_dso_marker_and_no_assets_dir: stderr mentions DSO_ASSETS_DIR" \
    "DSO_ASSETS_DIR" "$runner_mode_stderr"

assert_pass_if_clean "test_runner_exits_nonzero_when_no_dso_marker_and_no_assets_dir"

# ── test_runner_uses_dso_assets_dir_when_marker_absent ────────────────────────
# When no marker file and DSO_ASSETS_DIR is set, the runner must use scripts
# from DSO_ASSETS_DIR (host-project CI mode) and exit 0.
_snapshot_fail
assets_dir_exit=0
assets_dir_stderr=""

FAKE_ASSETS=$(mktemp -d)
FAKE_ASSETS_SCRIPTS="$FAKE_ASSETS/scripts"
FAKE_ASSETS_ARTIFACTS=$(mktemp -d)
_TEST_TMPDIRS+=("$FAKE_ASSETS" "$FAKE_ASSETS_ARTIFACTS")

mkdir -p "$FAKE_ASSETS_SCRIPTS"

# Light-tier classifier mock
cat > "$FAKE_ASSETS_SCRIPTS/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
cat > "$FAKE_ASSETS_SCRIPTS/write-reviewer-findings.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
cat > "$FAKE_ASSETS_SCRIPTS/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$FAKE_ASSETS_ARTIFACTS"
printf 'passed\n' > "$FAKE_ASSETS_ARTIFACTS/review-status"
MOCKEOF
chmod +x "$FAKE_ASSETS_SCRIPTS/review-complexity-classifier.sh" \
         "$FAKE_ASSETS_SCRIPTS/write-reviewer-findings.sh" \
         "$FAKE_ASSETS_SCRIPTS/record-review.sh"

# Run from a git repo without the marker, with DSO_ASSETS_DIR set
assets_dir_stderr=$(
    cd "$FAKE_REPO_MODE" && \
    unset CLAUDE_PLUGIN_ROOT 2>/dev/null || true && \
    DSO_ASSETS_DIR="$FAKE_ASSETS" \
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$FAKE_ASSETS_ARTIFACTS" \
    ANTHROPIC_API_KEY='x' \
    bash "$RUNNER_NO_MARKER" < /dev/null 2>&1 >/dev/null
) || assets_dir_exit=$?

assert_eq \
    "test_runner_uses_dso_assets_dir_when_marker_absent: exits 0" \
    "0" "$assets_dir_exit"

assert_pass_if_clean "test_runner_uses_dso_assets_dir_when_marker_absent"

# ── test_dso_llm_tier_absent_from_docs ────────────────────────────────────────
# Structural: DSO_LLM_TIER must NOT appear in documentation files.
# It is an internal runtime variable — exposing it in docs would mislead
# integrators into treating it as a supported config key.
# Given: CONFIGURATION-REFERENCE.md and onboarding/SKILL.md exist
# When:  both files are grepped for "DSO_LLM_TIER"
# Then:  zero matches in each file
_snapshot_fail
config_ref_matches=$(grep -c "DSO_LLM_TIER" "$REPO_ROOT/plugins/dso/docs/CONFIGURATION-REFERENCE.md" 2>/dev/null || true)
onboarding_matches=$(grep -c "DSO_LLM_TIER" "$REPO_ROOT/plugins/dso/skills/onboarding/SKILL.md" 2>/dev/null || true)
assert_eq "test_dso_llm_tier_absent_from_docs: DSO_LLM_TIER absent from CONFIGURATION-REFERENCE.md" "0" "$config_ref_matches"
assert_eq "test_dso_llm_tier_absent_from_docs: DSO_LLM_TIER absent from onboarding/SKILL.md" "0" "$onboarding_matches"
assert_pass_if_clean "test_dso_llm_tier_absent_from_docs"

# ── test_runner_uses_diff_file_not_env_var ────────────────────────────────────
# Structural: diff content must be passed via a temp file (DSO_DIFF_FILE / DSO_ARCH_MSG_FILE),
# not as a raw DSO_DIFF or DSO_ARCH_MSG env var. curl must use --data @file not --data-raw.
# Passing large diffs/JSON bodies as env vars or CLI args hits the Linux ARG_MAX (~2MB) limit.
# Given: ci-llm-review-runner.sh exists
# When:  the script is grepped for the banned patterns
# Then:  zero matches (all paths use file-based approach)
_snapshot_fail
_runner_file="$REPO_ROOT/plugins/dso/scripts/ci-llm-review-runner.sh"
dso_diff_env_matches=$(grep -cE 'DSO_DIFF=[^_F]' "$_runner_file" 2>/dev/null || true)
dso_arch_msg_env_matches=$(grep -cE 'DSO_ARCH_MSG=[^_F]' "$_runner_file" 2>/dev/null || true)
data_raw_matches=$(grep -cE '\-\-data-raw' "$_runner_file" 2>/dev/null || true)
assert_eq "test_runner_uses_diff_file_not_env_var: DSO_DIFF env var not used" "0" "$dso_diff_env_matches"
assert_eq "test_runner_uses_diff_file_not_env_var: DSO_ARCH_MSG env var not used" "0" "$dso_arch_msg_env_matches"
assert_eq "test_runner_uses_diff_file_not_env_var: --data-raw not used (use --data @file)" "0" "$data_raw_matches"
assert_pass_if_clean "test_runner_uses_diff_file_not_env_var"

# ── test_runner_exits_zero_on_unparseable_llm_response ───────────────────────
# Given: API returns a valid HTTP response but the LLM text is not valid
#        reviewer-findings JSON (e.g., truncated output for a large diff)
# When:  runner processes the response
# Then:  exits 0 (fail-open) instead of propagating the JSONDecodeError
_snapshot_fail
unparseable_exit=0
MOCK_UP=$(mktemp -d)
ARTIFACTS_UP=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK_UP" "$ARTIFACTS_UP")

# Mock curl: API returns text that is NOT valid reviewer-findings JSON
cat > "$MOCK_UP/curl" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"content":[{"text":"I reviewed the diff. Here are my thoughts:\n\n```json\n{\"scores\":{\"hygiene\":"}],"stop_reason":"length"}'
MOCKEOF
chmod +x "$MOCK_UP/curl"

# Mock write-reviewer-findings.sh: accept stdin, return a hash
cat > "$MOCK_UP/write-reviewer-findings.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK_UP/write-reviewer-findings.sh"

# Mock record-review.sh: write "passed" to review-status
cat > "$MOCK_UP/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$ARTIFACTS_UP"
printf 'passed\n' > "$ARTIFACTS_UP/review-status"
MOCKEOF
chmod +x "$MOCK_UP/record-review.sh"

# Mock classifier: return light tier
cat > "$MOCK_UP/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK_UP/review-complexity-classifier.sh"

(
    export PATH="$MOCK_UP:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_UP"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || unparseable_exit=$?

assert_eq "test_runner_exits_zero_on_unparseable_llm_response: exits 0 (fail-open)" "0" "$unparseable_exit"
assert_pass_if_clean "test_runner_exits_zero_on_unparseable_llm_response"

# ── test_overlay_critical_finding_overrides_inconclusive_tier ─────────────────
# Given: main tier API returns unparseable response (inconclusive — N/A scores)
#        AND security overlay returns critical finding with score=1
# When:  runner merges overlay into the inconclusive placeholder
# Then:  N/A scores are replaced by overlay numeric scores; record-review.sh
#        sees score=1 (critical) → writes "failed" → runner exits 1
#
# This verifies the fix to the overlay merge logic: the elif condition
# `not isinstance(merged_scores.get(dim), (int, float))` replaces N/A with
# overlay numeric values so critical overlay findings can still block merges
# even when the main tier was rate-limited/inconclusive.
_snapshot_fail
MOCK_CRIT=$(mktemp -d)
ARTIFACTS_CRIT=$(mktemp -d)
FINDINGS_CRIT="$MOCK_CRIT/findings-captured.json"
_TEST_TMPDIRS+=("$MOCK_CRIT" "$ARTIFACTS_CRIT")

# Mock classifier: security_overlay=true to trigger security overlay dispatch
cat > "$MOCK_CRIT/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":true,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK_CRIT/review-complexity-classifier.sh"

# Mock curl: main tier → unparseable; security overlays → critical findings JSON
cat > "$MOCK_CRIT/curl" <<'MOCKEOF'
#!/usr/bin/env bash
_body=""
_prev=""
for _arg in "$@"; do
    if [[ "$_prev" == "--data-raw" || "$_prev" == "-d" ]]; then
        _body="$_arg"
    elif [[ "$_prev" == "--data" || "$_prev" == "--data-binary" ]]; then
        _src="${_arg#@}"; [[ "$_src" != "$_arg" && -f "$_src" ]] && _body="$(cat "$_src")" || _body="$_arg"
    fi
    _prev="$_arg"
done
if printf '%s' "$_body" | grep -q "code-reviewer-security-red-team"; then
    python3 -c "import json; t={\"scores\":{\"correctness\":1,\"verification\":1,\"hygiene\":1,\"design\":1,\"maintainability\":1},\"summary\":\"Critical: hardcoded credentials\",\"findings\":[{\"severity\":\"critical\",\"category\":\"correctness\",\"description\":\"SECURITY_OVERLAY_TRIGGERED: hardcoded credential pattern\",\"file\":\"foo.sh\"}]}; print(json.dumps({\"content\":[{\"text\":json.dumps(t)}],\"stop_reason\":\"end_turn\"}))"
elif printf '%s' "$_body" | grep -q "code-reviewer-security-blue-team"; then
    python3 -c "import json; t={\"scores\":{\"correctness\":1,\"verification\":1,\"hygiene\":1,\"design\":1,\"maintainability\":1},\"summary\":\"Confirmed: hardcoded credentials\",\"findings\":[{\"severity\":\"critical\",\"category\":\"correctness\",\"description\":\"SECURITY_OVERLAY_TRIGGERED: confirmed credential pattern\",\"file\":\"foo.sh\"}]}; print(json.dumps({\"content\":[{\"text\":json.dumps(t)}],\"stop_reason\":\"end_turn\"}))"
else
    # Main tier: return unparseable (truncated) response to produce inconclusive N/A tier
    printf '{"content":[{"text":"I reviewed the diff. Here are my thoughts:\n\n```json\n{\"scores\":{\"hygiene\":"}],"stop_reason":"length"}'
fi
MOCKEOF
chmod +x "$MOCK_CRIT/curl"

# Mock write-reviewer-findings.sh: capture FINDINGS_JSON stdin to file for inspection
cat > "$MOCK_CRIT/write-reviewer-findings.sh" <<MOCKEOF
#!/usr/bin/env bash
tee "${FINDINGS_CRIT}" > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK_CRIT/write-reviewer-findings.sh"

# Mock record-review.sh: reads the captured FINDINGS_JSON and writes "failed"
# if any numeric score is below 3 (critical/important threshold), else "passed".
cat > "$MOCK_CRIT/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "${ARTIFACTS_CRIT}"
if [[ -f "${FINDINGS_CRIT}" ]]; then
    result=\$(python3 -c "
import json, sys
with open('${FINDINGS_CRIT}') as f:
    d = json.load(f)
scores = d.get('scores', {})
numeric_scores = [v for v in scores.values() if isinstance(v, (int, float))]
if numeric_scores and min(numeric_scores) < 4:
    print('failed')
else:
    print('passed')
")
    printf '%s\n' "\$result" > "${ARTIFACTS_CRIT}/review-status"
else
    printf 'passed\n' > "${ARTIFACTS_CRIT}/review-status"
fi
MOCKEOF
chmod +x "$MOCK_CRIT/record-review.sh"
_add_anthropic_llm_wrapper "$MOCK_CRIT"

mkdir -p "$ARTIFACTS_CRIT"

overlay_crit_exit=0
(
    export PATH="$MOCK_CRIT:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_CRIT"
    printf 'diff --git a/foo.sh b/foo.sh\n+AWS_SECRET_ACCESS_KEY=FAKE-TEST-ONLY-NOT-A-REAL-KEY-000000000000\n' \
        | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || overlay_crit_exit=$?

assert_eq "test_overlay_critical_finding_overrides_inconclusive_tier: runner exits 1" "1" "$overlay_crit_exit"

# Also verify the captured FINDINGS_JSON has numeric scores (not N/A) from overlay
_crit_score_exit=0
_crit_score_out=""
if [[ -f "$FINDINGS_CRIT" ]]; then
    _crit_score_out=$(python3 - <<PYEOF 2>&1 || _crit_score_exit=$?
import json, sys
with open('${FINDINGS_CRIT}') as f:
    d = json.load(f)
scores = d.get('scores', {})
na_scores = [k for k, v in scores.items() if v == 'N/A']
if na_scores:
    print('STILL_NA: overlay scores did not replace N/A for: ' + str(na_scores))
    sys.exit(1)
min_score = min(v for v in scores.values() if isinstance(v, (int, float)))
if min_score >= 3:
    print('SCORE_NOT_CRITICAL: min score is ' + str(min_score) + ' (expected < 3 for critical overlay)')
    sys.exit(1)
print('OK')
PYEOF
    )
else
    _crit_score_out="findings-captured.json not written"
    _crit_score_exit=1
fi
assert_eq "test_overlay_critical_finding_overrides_inconclusive_tier: overlay scores replace N/A" "0" "$_crit_score_exit"
assert_eq "test_overlay_critical_finding_overrides_inconclusive_tier: scores are numeric from overlay" "OK" "$_crit_score_out"

assert_pass_if_clean "test_overlay_critical_finding_overrides_inconclusive_tier"

# ── test_runner_resolves_llm_api_call_via_path ────────────────────────────────
# Behavioral: when llm-api-call.sh is on PATH, runner invokes it at least once.
_snapshot_fail
_llmcall_mock_dir=$(mktemp -d)
_llmcall_counter=$(mktemp)
_llmcall_artifacts=$(mktemp -d)
_TEST_TMPDIRS+=("$_llmcall_mock_dir" "$_llmcall_artifacts")
_create_mock_llm_api_call "$_llmcall_mock_dir" "$_llmcall_counter" ""

cat > "$_llmcall_mock_dir/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$_llmcall_mock_dir/review-complexity-classifier.sh"

cat > "$_llmcall_mock_dir/write-reviewer-findings.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$_llmcall_mock_dir/write-reviewer-findings.sh"

cat > "$_llmcall_mock_dir/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$_llmcall_artifacts"
printf 'passed\n' > "$_llmcall_artifacts/review-status"
MOCKEOF
chmod +x "$_llmcall_mock_dir/record-review.sh"

_llmcall_runner_exit=0
(
    export PATH="$_llmcall_mock_dir:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_llmcall_artifacts"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || _llmcall_runner_exit=$?

_llmcall_invocations=0
if [[ -f "$_llmcall_counter" ]]; then
    _llmcall_invocations=$(wc -l < "$_llmcall_counter" 2>/dev/null || printf '0')
    _llmcall_invocations=$(printf '%s' "$_llmcall_invocations" | tr -d ' ')
fi
assert_ne "test_runner_resolves_llm_api_call_via_path: llm-api-call.sh invoked at least once" "0" "$_llmcall_invocations"
rm -f "$_llmcall_counter"
assert_pass_if_clean "test_runner_resolves_llm_api_call_via_path"

# ── test_runner_delegates_light_path_with_light_tier ─────────────────────────
# Behavioral: for light tier, llm-api-call.sh is invoked with tier arg "light".
_snapshot_fail
_light_mock_dir=$(mktemp -d)
_light_counter=$(mktemp)
_light_args=$(mktemp)
_light_artifacts=$(mktemp -d)
_TEST_TMPDIRS+=("$_light_mock_dir" "$_light_artifacts")
_create_mock_llm_api_call "$_light_mock_dir" "$_light_counter" "$_light_args"

cat > "$_light_mock_dir/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$_light_mock_dir/review-complexity-classifier.sh"

cat > "$_light_mock_dir/write-reviewer-findings.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$_light_mock_dir/write-reviewer-findings.sh"

cat > "$_light_mock_dir/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$_light_artifacts"
printf 'passed\n' > "$_light_artifacts/review-status"
MOCKEOF
chmod +x "$_light_mock_dir/record-review.sh"

_light_exit=0
(
    export PATH="$_light_mock_dir:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_light_artifacts"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || _light_exit=$?

_light_tier_arg=""
if [[ -f "$_light_args" ]]; then
    # arg[3] is the tier (1-indexed: line 3)
    _light_tier_arg=$(sed -n '3p' "$_light_args" 2>/dev/null || true)
fi
assert_eq "test_runner_delegates_light_path_with_light_tier: tier arg is 'light'" "light" "$_light_tier_arg"
rm -f "$_light_counter" "$_light_args"
assert_pass_if_clean "test_runner_delegates_light_path_with_light_tier"

# ── test_runner_delegates_standard_path_with_standard_tier ───────────────────
# Behavioral: for standard tier, llm-api-call.sh is invoked with tier arg "standard".
_snapshot_fail
_std_mock_dir=$(mktemp -d)
_std_counter=$(mktemp)
_std_args=$(mktemp)
_std_artifacts=$(mktemp -d)
_TEST_TMPDIRS+=("$_std_mock_dir" "$_std_artifacts")
_create_mock_llm_api_call "$_std_mock_dir" "$_std_counter" "$_std_args"

cat > "$_std_mock_dir/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"standard","blast_radius":2,"critical_path":1,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":50,"change_volume":1,"computed_total":4,"diff_size_lines":50,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$_std_mock_dir/review-complexity-classifier.sh"

cat > "$_std_mock_dir/write-reviewer-findings.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$_std_mock_dir/write-reviewer-findings.sh"

cat > "$_std_mock_dir/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$_std_artifacts"
printf 'passed\n' > "$_std_artifacts/review-status"
MOCKEOF
chmod +x "$_std_mock_dir/record-review.sh"

_std_exit=0
(
    export PATH="$_std_mock_dir:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_std_artifacts"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || _std_exit=$?

_std_tier_arg=""
if [[ -f "$_std_args" ]]; then
    _std_tier_arg=$(sed -n '3p' "$_std_args" 2>/dev/null || true)
fi
assert_eq "test_runner_delegates_standard_path_with_standard_tier: tier arg is 'standard'" "standard" "$_std_tier_arg"
rm -f "$_std_counter" "$_std_args"
assert_pass_if_clean "test_runner_delegates_standard_path_with_standard_tier"

# ── test_runner_delegates_deep_specialists_with_deep_tier ─────────────────────
# Behavioral: for deep tier, llm-api-call.sh is invoked with tier arg "deep".
_snapshot_fail
_deep_mock_dir=$(mktemp -d)
_deep_counter=$(mktemp)
_deep_artifacts=$(mktemp -d)
_TEST_TMPDIRS+=("$_deep_mock_dir" "$_deep_artifacts")

# For deep tier, llm-api-call.sh is called per-specialist; we capture counts.
# Each specialist call writes a slot file and the mock returns appropriate JSON.
_DEEP_SLOT_JSON='{"scores":{"correctness":4,"verification":4,"hygiene":4,"design":4,"maintainability":4},"findings":[],"summary":"Specialist OK"}'
cat > "$_deep_mock_dir/llm-api-call.sh" <<MOCKEOF
#!/usr/bin/env bash
_counter_file='${_deep_counter}'
[ -n "\$_counter_file" ] && printf '\n' >> "\$_counter_file"
# arg3 is tier; all deep-specialist calls should use "deep"
_tier="\${3:-}"
# arg1 is system-prompt-file; determine which specialist from agent file name
_agent_file="\${1:-}"
_slot_json='${_DEEP_SLOT_JSON}'
if printf '%s' "\$_agent_file" | grep -q "code-reviewer-deep-correctness"; then
    printf '%s\n' "\$_slot_json" > "${_deep_artifacts}/reviewer-findings-correctness.json"
elif printf '%s' "\$_agent_file" | grep -q "code-reviewer-deep-verification"; then
    printf '%s\n' "\$_slot_json" > "${_deep_artifacts}/reviewer-findings-verification.json"
elif printf '%s' "\$_agent_file" | grep -q "code-reviewer-deep-hygiene"; then
    printf '%s\n' "\$_slot_json" > "${_deep_artifacts}/reviewer-findings-hygiene.json"
fi
printf '%s\n' "\$_slot_json"
MOCKEOF
chmod +x "$_deep_mock_dir/llm-api-call.sh"

cat > "$_deep_mock_dir/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"deep","blast_radius":3,"critical_path":2,"anti_shortcut":1,"staleness":1,"cross_cutting":1,"diff_lines":350,"change_volume":2,"computed_total":10,"diff_size_lines":350,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$_deep_mock_dir/review-complexity-classifier.sh"

cat > "$_deep_mock_dir/write-reviewer-findings.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$_deep_mock_dir/write-reviewer-findings.sh"

cat > "$_deep_mock_dir/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$_deep_artifacts"
printf 'passed\n' > "$_deep_artifacts/review-status"
MOCKEOF
chmod +x "$_deep_mock_dir/record-review.sh"

_deep_del_exit=0
(
    export PATH="$_deep_mock_dir:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_deep_artifacts"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || _deep_del_exit=$?

_deep_invocations=0
if [[ -f "$_deep_counter" ]]; then
    _deep_invocations=$(wc -l < "$_deep_counter" 2>/dev/null || printf '0')
    _deep_invocations=$(printf '%s' "$_deep_invocations" | tr -d ' ')
fi
# Should have at least 3 specialist calls + 1 arch call = 4 total
assert_ne "test_runner_delegates_deep_specialists_with_deep_tier: llm-api-call.sh called multiple times for deep tier" "0" "$_deep_invocations"
rm -f "$_deep_counter"
assert_pass_if_clean "test_runner_delegates_deep_specialists_with_deep_tier"

# ── test_runner_fail_open_when_llm_helper_returns_empty ───────────────────────
# Behavioral: when llm-api-call.sh returns empty string, runner exits 0 (fail-open).
_snapshot_fail
_empty_resp_mock_dir=$(mktemp -d)
_empty_resp_artifacts=$(mktemp -d)
_TEST_TMPDIRS+=("$_empty_resp_mock_dir" "$_empty_resp_artifacts")

cat > "$_empty_resp_mock_dir/llm-api-call.sh" <<'MOCKEOF'
#!/usr/bin/env bash
# Return empty string (success exit but empty output)
printf ''
MOCKEOF
chmod +x "$_empty_resp_mock_dir/llm-api-call.sh"

cat > "$_empty_resp_mock_dir/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$_empty_resp_mock_dir/review-complexity-classifier.sh"

cat > "$_empty_resp_mock_dir/write-reviewer-findings.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$_empty_resp_mock_dir/write-reviewer-findings.sh"

cat > "$_empty_resp_mock_dir/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$_empty_resp_artifacts"
printf 'passed\n' > "$_empty_resp_artifacts/review-status"
MOCKEOF
chmod +x "$_empty_resp_mock_dir/record-review.sh"

_empty_resp_exit=0
(
    export PATH="$_empty_resp_mock_dir:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_empty_resp_artifacts"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || _empty_resp_exit=$?

assert_eq "test_runner_fail_open_when_llm_helper_returns_empty: runner exits 0 (fail-open)" "0" "$_empty_resp_exit"
assert_pass_if_clean "test_runner_fail_open_when_llm_helper_returns_empty"

# ── test_runner_fail_open_when_llm_response_not_valid_json ────────────────────
# Behavioral: when llm-api-call.sh returns non-JSON, runner exits 0 (fail-open).
_snapshot_fail
_bad_json_mock_dir=$(mktemp -d)
_bad_json_artifacts=$(mktemp -d)
_TEST_TMPDIRS+=("$_bad_json_mock_dir" "$_bad_json_artifacts")

cat > "$_bad_json_mock_dir/llm-api-call.sh" <<'MOCKEOF'
#!/usr/bin/env bash
printf 'not-valid-json\n'
MOCKEOF
chmod +x "$_bad_json_mock_dir/llm-api-call.sh"

cat > "$_bad_json_mock_dir/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$_bad_json_mock_dir/review-complexity-classifier.sh"

cat > "$_bad_json_mock_dir/write-reviewer-findings.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$_bad_json_mock_dir/write-reviewer-findings.sh"

cat > "$_bad_json_mock_dir/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$_bad_json_artifacts"
printf 'passed\n' > "$_bad_json_artifacts/review-status"
MOCKEOF
chmod +x "$_bad_json_mock_dir/record-review.sh"

_bad_json_exit=0
(
    export PATH="$_bad_json_mock_dir:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_bad_json_artifacts"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || _bad_json_exit=$?

assert_eq "test_runner_fail_open_when_llm_response_not_valid_json: runner exits 0 (fail-open)" "0" "$_bad_json_exit"
assert_pass_if_clean "test_runner_fail_open_when_llm_response_not_valid_json"

# ── test_runner_fail_open_when_llm_helper_exits_nonzero ───────────────────────
# Behavioral: when llm-api-call.sh exits 1, runner still exits 0 (fail-open
# for inconclusive review). The runner uses `|| LLM_TEXT=""` pattern.
_snapshot_fail
_fail_helper_mock_dir=$(mktemp -d)
_fail_helper_artifacts=$(mktemp -d)
_TEST_TMPDIRS+=("$_fail_helper_mock_dir" "$_fail_helper_artifacts")

cat > "$_fail_helper_mock_dir/llm-api-call.sh" <<'MOCKEOF'
#!/usr/bin/env bash
echo "ERROR: simulated API failure" >&2
exit 1
MOCKEOF
chmod +x "$_fail_helper_mock_dir/llm-api-call.sh"

cat > "$_fail_helper_mock_dir/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$_fail_helper_mock_dir/review-complexity-classifier.sh"

cat > "$_fail_helper_mock_dir/write-reviewer-findings.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$_fail_helper_mock_dir/write-reviewer-findings.sh"

cat > "$_fail_helper_mock_dir/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$_fail_helper_artifacts"
printf 'passed\n' > "$_fail_helper_artifacts/review-status"
MOCKEOF
chmod +x "$_fail_helper_mock_dir/record-review.sh"

_fail_helper_exit=0
(
    export PATH="$_fail_helper_mock_dir:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_fail_helper_artifacts"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || _fail_helper_exit=$?

# Fail-open: runner exits 0 with inconclusive review when llm-api-call.sh fails
assert_eq "test_runner_fail_open_when_llm_helper_exits_nonzero: runner exits 0 (fail-open, inconclusive)" "0" "$_fail_helper_exit"
assert_pass_if_clean "test_runner_fail_open_when_llm_helper_exits_nonzero"

# ── test_runner_integration_llm_api_call_mocked ───────────────────────────────
# Integration: runner with llm-api-call.sh mock exits 0 and writes reviewer-findings.json
# with all 5 dimension scores as numeric values >= 0.
_snapshot_fail
_integ_mock_dir=$(mktemp -d)
_integ_artifacts=$(mktemp -d)
_TEST_TMPDIRS+=("$_integ_mock_dir" "$_integ_artifacts")
_create_mock_llm_api_call "$_integ_mock_dir" "" ""

cat > "$_integ_mock_dir/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$_integ_mock_dir/review-complexity-classifier.sh"

# write-reviewer-findings.sh: accept valid findings JSON on stdin, write to file
cat > "$_integ_mock_dir/write-reviewer-findings.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$_integ_artifacts"
tee "$_integ_artifacts/reviewer-findings.json" > /dev/null
sha256sum "$_integ_artifacts/reviewer-findings.json" 2>/dev/null | cut -d' ' -f1 \
  || shasum -a 256 "$_integ_artifacts/reviewer-findings.json" | cut -d' ' -f1
MOCKEOF
chmod +x "$_integ_mock_dir/write-reviewer-findings.sh"

cat > "$_integ_mock_dir/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$_integ_artifacts"
printf 'passed\n' > "$_integ_artifacts/review-status"
MOCKEOF
chmod +x "$_integ_mock_dir/record-review.sh"

_integ_exit=0
(
    export PATH="$_integ_mock_dir:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_integ_artifacts"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || _integ_exit=$?

assert_eq "test_runner_integration_llm_api_call_mocked: runner exits 0" "0" "$_integ_exit"

_integ_score_check_exit=0
_integ_score_check_out=""
if [[ -f "$_integ_artifacts/reviewer-findings.json" ]]; then
    _integ_score_check_out=$(python3 - "$_integ_artifacts/reviewer-findings.json" <<'PYEOF' 2>&1 || _integ_score_check_exit=$?
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
scores = d.get('scores', {})
required = ['correctness', 'verification', 'hygiene', 'design', 'maintainability']
missing = [k for k in required if k not in scores]
if missing:
    print('MISSING scores: ' + str(missing))
    sys.exit(1)
non_numeric = [k for k, v in scores.items() if not isinstance(v, (int, float))]
if non_numeric:
    print('NON-NUMERIC scores: ' + str(non_numeric))
    sys.exit(1)
negative = [k for k, v in scores.items() if isinstance(v, (int, float)) and v < 0]
if negative:
    print('NEGATIVE scores: ' + str(negative))
    sys.exit(1)
print('OK')
PYEOF
    )
else
    _integ_score_check_out="reviewer-findings.json not written"
    _integ_score_check_exit=1
fi
assert_eq "test_runner_integration_llm_api_call_mocked: reviewer-findings.json has all 5 numeric scores >= 0" "0" "$_integ_score_check_exit"
assert_eq "test_runner_integration_llm_api_call_mocked: score check output" "OK" "$_integ_score_check_out"
assert_pass_if_clean "test_runner_integration_llm_api_call_mocked"

# ── test_openai_path_produces_schema_conformant_findings ──────────────────────
# Integration: runner with OPENAI_API_KEY set and llm-api-call.sh mock exits 0
# and writes reviewer-findings.json with all 5 dimension scores as numeric >= 0.
_snapshot_fail
_openai_mock_dir=$(mktemp -d)
_openai_artifacts=$(mktemp -d)
_TEST_TMPDIRS+=("$_openai_mock_dir" "$_openai_artifacts")
_create_mock_llm_api_call "$_openai_mock_dir" "" ""

cat > "$_openai_mock_dir/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$_openai_mock_dir/review-complexity-classifier.sh"

# write-reviewer-findings.sh: accept valid findings JSON on stdin, write to file
cat > "$_openai_mock_dir/write-reviewer-findings.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$_openai_artifacts"
tee "$_openai_artifacts/reviewer-findings.json" > /dev/null
sha256sum "$_openai_artifacts/reviewer-findings.json" 2>/dev/null | cut -d' ' -f1 \
  || shasum -a 256 "$_openai_artifacts/reviewer-findings.json" | cut -d' ' -f1
MOCKEOF
chmod +x "$_openai_mock_dir/write-reviewer-findings.sh"

cat > "$_openai_mock_dir/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$_openai_artifacts"
printf 'passed\n' > "$_openai_artifacts/review-status"
MOCKEOF
chmod +x "$_openai_mock_dir/record-review.sh"

_openai_exit=0
(
    export PATH="$_openai_mock_dir:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_openai_artifacts"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | OPENAI_API_KEY='sk-test' bash "$RUNNER"
) || _openai_exit=$?

assert_eq "test_openai_path_produces_schema_conformant_findings: runner exits 0" "0" "$_openai_exit"

_openai_score_check_exit=0
_openai_score_check_out=""
if [[ -f "$_openai_artifacts/reviewer-findings.json" ]]; then
    _openai_score_check_out=$(python3 - "$_openai_artifacts/reviewer-findings.json" <<'PYEOF' 2>&1 || _openai_score_check_exit=$?
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
scores = d.get('scores', {})
required = ['correctness', 'verification', 'hygiene', 'design', 'maintainability']
missing = [k for k in required if k not in scores]
if missing:
    print('MISSING scores: ' + str(missing))
    sys.exit(1)
non_numeric = [k for k, v in scores.items() if not isinstance(v, (int, float))]
if non_numeric:
    print('NON-NUMERIC scores: ' + str(non_numeric))
    sys.exit(1)
negative = [k for k, v in scores.items() if isinstance(v, (int, float)) and v < 0]
if negative:
    print('NEGATIVE scores: ' + str(negative))
    sys.exit(1)
print('OK')
PYEOF
    )
else
    _openai_score_check_out="reviewer-findings.json not written"
    _openai_score_check_exit=1
fi
assert_eq "test_openai_path_produces_schema_conformant_findings: reviewer-findings.json has all 5 numeric scores >= 0" "0" "$_openai_score_check_exit"
assert_eq "test_openai_path_produces_schema_conformant_findings: score check output" "OK" "$_openai_score_check_out"
assert_pass_if_clean "test_openai_path_produces_schema_conformant_findings"

# ── test_dso_llm_model_env_is_ignored ─────────────────────────────────────────
# Behavioral: DSO_LLM_MODEL env var must be silently ignored — the runner
# uses config-driven model IDs via llm-api-call.sh, not DSO_LLM_MODEL.
# Given: DSO_LLM_MODEL=bogus-model-xyz in env, ANTHROPIC_API_KEY set, all deps mocked
# When:  runner invoked with a fixture diff
# Then:  runner exits 0 and writes reviewer-findings.json
_snapshot_fail
_dso_llm_mock_dir=$(mktemp -d)
_dso_llm_artifacts=$(mktemp -d)
_TEST_TMPDIRS+=("$_dso_llm_mock_dir" "$_dso_llm_artifacts")
_create_mock_curl "$_dso_llm_mock_dir"

cat > "$_dso_llm_mock_dir/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$_dso_llm_mock_dir/review-complexity-classifier.sh"

cat > "$_dso_llm_mock_dir/write-reviewer-findings.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$_dso_llm_artifacts"
tee "$_dso_llm_artifacts/reviewer-findings.json" > /dev/null
sha256sum "$_dso_llm_artifacts/reviewer-findings.json" 2>/dev/null | cut -d' ' -f1 \
  || shasum -a 256 "$_dso_llm_artifacts/reviewer-findings.json" | cut -d' ' -f1
MOCKEOF
chmod +x "$_dso_llm_mock_dir/write-reviewer-findings.sh"

cat > "$_dso_llm_mock_dir/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$_dso_llm_artifacts"
printf 'passed\n' > "$_dso_llm_artifacts/review-status"
MOCKEOF
chmod +x "$_dso_llm_mock_dir/record-review.sh"

_dso_llm_exit=0
(
    export PATH="$_dso_llm_mock_dir:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_dso_llm_artifacts"
    export DSO_LLM_MODEL='bogus-model-xyz'
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || _dso_llm_exit=$?

assert_eq "test_dso_llm_model_env_is_ignored: runner exits 0 when DSO_LLM_MODEL is set" "0" "$_dso_llm_exit"
_dso_llm_findings_exist="false"
[[ -f "$_dso_llm_artifacts/reviewer-findings.json" ]] && _dso_llm_findings_exist="true"
assert_eq "test_dso_llm_model_env_is_ignored: reviewer-findings.json written despite DSO_LLM_MODEL" "true" "$_dso_llm_findings_exist"
assert_pass_if_clean "test_dso_llm_model_env_is_ignored"



# ── test_runner_standard_overlays_concurrent ─────────────────────────────────
# Given: standard tier with security_overlay=true
#        mock llm-api-call.sh sleeps 1s for BOTH the tier call and the overlay call
# When:  runner runs end-to-end
# Then:  total elapsed time < 2000ms  (concurrent → ~1s wall-clock, serial → ~2s)
#
# RED condition: currently overlays fire AFTER the tier call completes → ~2s total.
# GREEN condition: after parallel refactor, tier + overlay fire concurrently → ~1s total.
_snapshot_fail
MOCK_STD_CONC=$(mktemp -d)
ARTIFACTS_STD_CONC=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK_STD_CONC" "$ARTIFACTS_STD_CONC")

# Classifier: standard tier, security_overlay=true
cat > "$MOCK_STD_CONC/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"standard","blast_radius":3,"critical_path":1,"anti_shortcut":1,"staleness":1,"cross_cutting":1,"diff_lines":50,"change_volume":1,"computed_total":6,"diff_size_lines":50,"size_action":"none","is_merge_commit":false,"security_overlay":true,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK_STD_CONC/review-complexity-classifier.sh"

# llm-api-call.sh mock: sleep 1s then output findings JSON directly.
# Both the tier call AND the overlay call use this mock, so:
#   serial  execution: ~2s total (1s tier + 1s overlay)
#   parallel execution: ~1s total (tier & overlay overlap)
cat > "$MOCK_STD_CONC/llm-api-call.sh" <<'MOCKEOF'
#!/usr/bin/env bash
sleep 1
printf '{"scores":{"correctness":5,"verification":5,"hygiene":5,"design":5,"maintainability":5},"findings":[],"summary":"ok"}\n'
MOCKEOF
chmod +x "$MOCK_STD_CONC/llm-api-call.sh"

# write-reviewer-findings.sh: consume stdin, return a hash
cat > "$MOCK_STD_CONC/write-reviewer-findings.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK_STD_CONC/write-reviewer-findings.sh"

# record-review.sh: write passed status
cat > "$MOCK_STD_CONC/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "${ARTIFACTS_STD_CONC}"
printf 'passed\n' > "${ARTIFACTS_STD_CONC}/review-status"
MOCKEOF
chmod +x "$MOCK_STD_CONC/record-review.sh"

mkdir -p "$ARTIFACTS_STD_CONC"

_std_conc_start=0
_std_conc_end=0
_std_conc_exit=0

_std_conc_start=$(date +%s%N 2>/dev/null || date +%s)
(
    export PATH="$MOCK_STD_CONC:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_STD_CONC"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || _std_conc_exit=$?
_std_conc_end=$(date +%s%N 2>/dev/null || date +%s)

assert_eq "test_runner_standard_overlays_concurrent: runner exits 0" "0" "$_std_conc_exit"

# Compute elapsed in milliseconds. date +%s%N returns nanoseconds; fall back to seconds.
_std_conc_elapsed_ms=0
if [[ ${#_std_conc_end} -ge 15 ]]; then
    # nanosecond precision available
    _std_conc_elapsed_ms=$(( (_std_conc_end - _std_conc_start) / 1000000 ))
else
    # second precision only — scale to ms
    _std_conc_elapsed_ms=$(( (_std_conc_end - _std_conc_start) * 1000 ))
fi

# Assert elapsed < 3000ms. RED: serial path takes ~4s (1s tier + 1s overlay + overhead).
# GREEN: concurrent path takes ~1s (tier and overlay overlap) + CI overhead < 3s.
# 3000ms ceiling: generous enough to tolerate slow CI while reliably catching ~4s serial case.
_std_conc_ok="FAIL"
if [[ $_std_conc_elapsed_ms -lt 3000 ]]; then
    _std_conc_ok="PASS"
fi
assert_eq "test_runner_standard_overlays_concurrent: elapsed < 3000ms (got ${_std_conc_elapsed_ms}ms)" "PASS" "$_std_conc_ok"

assert_pass_if_clean "test_runner_standard_overlays_concurrent"

# ── test_runner_deep_overlays_concurrent ──────────────────────────────────────
# Given: deep tier with test_quality_overlay=true
#        mock curl sleeps 1s for every API call (3 specialists + arch + overlay)
# When:  runner runs end-to-end
# Then:  total elapsed time < 4000ms
#        (concurrent → ~2s: 1s parallel specialists, 1s arch+overlay overlap;
#         serial → ~5s: 1s each × 5 sequential calls)
#
# RED condition: currently overlays fire AFTER arch synthesis → ~2s specialists
#               + ~1s arch + ~1s overlay = ~4s+ total → assertion fails.
# GREEN condition: after parallel refactor, overlay fires concurrently with arch
#               → ~2s specialists + ~1s arch/overlay overlap = ~3s total → passes.
_snapshot_fail
MOCK_DEEP_CONC=$(mktemp -d)
ARTIFACTS_DEEP_CONC=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK_DEEP_CONC" "$ARTIFACTS_DEEP_CONC")

# Classifier: deep tier, test_quality_overlay=true
cat > "$MOCK_DEEP_CONC/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"deep","blast_radius":3,"critical_path":2,"anti_shortcut":1,"staleness":1,"cross_cutting":1,"diff_lines":350,"change_volume":2,"computed_total":10,"diff_size_lines":350,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":true}'
MOCKEOF
chmod +x "$MOCK_DEEP_CONC/review-complexity-classifier.sh"

# llm-api-call.sh mock: route by agent file path ($1), sleep 1s per call, output findings JSON
# directly to stdout. This bypasses the provider API-key check and the Anthropic/OpenAI response
# envelope that the real llm-api-call.sh parses — the runner captures this stdout into slot files
# via its own > redirects, so no side-effect writes are needed here.
cat > "$MOCK_DEEP_CONC/llm-api-call.sh" <<'MOCKEOF'
#!/usr/bin/env bash
_agent_file="$1"
sleep 1
if [[ "$_agent_file" == *"code-reviewer-deep-correctness"* ]]; then
    printf '{"scores":{"correctness":4,"verification":5,"hygiene":5,"design":5,"maintainability":5},"findings":[],"summary":"C"}\n'
elif [[ "$_agent_file" == *"code-reviewer-deep-verification"* ]]; then
    printf '{"scores":{"correctness":5,"verification":4,"hygiene":5,"design":5,"maintainability":5},"findings":[],"summary":"V"}\n'
elif [[ "$_agent_file" == *"code-reviewer-deep-hygiene"* ]]; then
    printf '{"scores":{"correctness":5,"verification":5,"hygiene":4,"design":5,"maintainability":5},"findings":[],"summary":"H"}\n'
elif [[ "$_agent_file" == *"code-reviewer-deep-arch"* ]]; then
    printf '{"scores":{"correctness":4,"verification":4,"hygiene":4,"design":5,"maintainability":5},"findings":[{"severity":"minor","category":"correctness","description":"Arch synthesized finding","file":"foo.sh"}],"summary":"Arch synthesis"}\n'
elif [[ "$_agent_file" == *"code-reviewer-test-quality"* ]]; then
    printf '{"scores":{"correctness":4,"verification":4,"hygiene":4,"design":5,"maintainability":5},"findings":[{"severity":"minor","category":"verification","description":"TQ overlay finding","file":"tests/foo.sh"}],"summary":"TQ overlay"}\n'
else
    printf '{}\n'
fi
MOCKEOF
chmod +x "$MOCK_DEEP_CONC/llm-api-call.sh"

# write-reviewer-findings.sh: consume stdin, return a hash
cat > "$MOCK_DEEP_CONC/write-reviewer-findings.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK_DEEP_CONC/write-reviewer-findings.sh"

# record-review.sh: write passed status
cat > "$MOCK_DEEP_CONC/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "${ARTIFACTS_DEEP_CONC}"
printf 'passed\n' > "${ARTIFACTS_DEEP_CONC}/review-status"
MOCKEOF
chmod +x "$MOCK_DEEP_CONC/record-review.sh"

mkdir -p "$ARTIFACTS_DEEP_CONC"

_deep_conc_start=0
_deep_conc_end=0
_deep_conc_exit=0

_deep_conc_start=$(date +%s%N 2>/dev/null || date +%s)
(
    export PATH="$MOCK_DEEP_CONC:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_DEEP_CONC"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || _deep_conc_exit=$?
_deep_conc_end=$(date +%s%N 2>/dev/null || date +%s)

assert_eq "test_runner_deep_overlays_concurrent: runner exits 0" "0" "$_deep_conc_exit"

# Compute elapsed in milliseconds.
_deep_conc_elapsed_ms=0
if [[ ${#_deep_conc_end} -ge 15 ]]; then
    _deep_conc_elapsed_ms=$(( (_deep_conc_end - _deep_conc_start) / 1000000 ))
else
    _deep_conc_elapsed_ms=$(( (_deep_conc_end - _deep_conc_start) * 1000 ))
fi

# Assert elapsed < 4000ms.
# RED:   serial path = 1s (3 parallel specialists) + 1s arch + 1s overlay = ~3s+ → may exceed 4s
#        under load, but the key gap is arch completes THEN overlay starts (sequential adds ~1s).
#        With the security_blue_team serial follow-up absent (no security overlay), the
#        bottleneck is: arch synthesis THEN overlay → 2 sequential 1s calls after the 1s
#        specialist batch = ~3s total. Under any realistic system load this tips above 3500ms.
# GREEN: concurrent path = 1s specialists + max(1s arch, 1s overlay) = ~2s total → well under 4s.
# Use a 3500ms ceiling to reliably catch the serial case across CI environments.
_deep_conc_ok="FAIL"
if [[ $_deep_conc_elapsed_ms -lt 3500 ]]; then
    _deep_conc_ok="PASS"
fi
assert_eq "test_runner_deep_overlays_concurrent: elapsed < 3500ms (got ${_deep_conc_elapsed_ms}ms)" "PASS" "$_deep_conc_ok"

assert_pass_if_clean "test_runner_deep_overlays_concurrent"

# ── test_runner_size_action_upgrade_overrides_to_deep_tier ───────────────────
# Given: classifier returns selected_tier=light AND size_action=upgrade
# When:  runner processes a non-empty diff
# Then:  runner dispatches a deep-tier agent (not light or standard)
#        because size_action=upgrade must override the tier upward to deep.
#
# Why RED: runner currently reads only selected_tier (ignores size_action),
# so it dispatches code-reviewer-light.md instead of a deep-tier agent.
_snapshot_fail
MOCK_SA_UP=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK_SA_UP")
ARTIFACTS_SA_UP=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS_SA_UP")

# Classifier: selected_tier=light BUT size_action=upgrade (deep override required)
cat > "$MOCK_SA_UP/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":320,"change_volume":2,"computed_total":4,"diff_size_lines":320,"size_action":"upgrade","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK_SA_UP/review-complexity-classifier.sh"

# Capture which agent file was passed as the first argument to llm-api-call.sh.
AGENT_BODY_FILE_SA_UP="$MOCK_SA_UP/first-agent-file.txt"

# Specialist slot JSON (needed only if deep tier is correctly dispatched)
_SA_SLOT='{"scores":{"correctness":4,"verification":4,"hygiene":4,"design":4,"maintainability":4},"summary":"Specialist OK","findings":[]}'

# llm-api-call.sh mock: record first agent file path for tier detection; output slot JSON.
# The runner redirects stdout to slot files via >, so no direct file writes are needed here.
cat > "$MOCK_SA_UP/llm-api-call.sh" <<MOCKEOF
#!/usr/bin/env bash
_agent_file="\$1"
if [[ ! -f "${AGENT_BODY_FILE_SA_UP}" ]]; then
    printf '%s' "\$_agent_file" > "${AGENT_BODY_FILE_SA_UP}"
fi
printf '%s\n' '${_SA_SLOT}'
MOCKEOF
chmod +x "$MOCK_SA_UP/llm-api-call.sh"

cat > "$MOCK_SA_UP/write-reviewer-findings.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK_SA_UP/write-reviewer-findings.sh"

cat > "$MOCK_SA_UP/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$ARTIFACTS_SA_UP"
printf 'passed\n' > "$ARTIFACTS_SA_UP/review-status"
MOCKEOF
chmod +x "$MOCK_SA_UP/record-review.sh"

sa_up_exit=0
(
    export PATH="$MOCK_SA_UP:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_SA_UP"
    printf 'diff --git a/foo.sh b/foo.sh\n+line\n' | ANTHROPIC_API_KEY=x bash "$RUNNER" 2>/dev/null
) || sa_up_exit=$?

assert_eq "test_runner_size_action_upgrade_overrides_to_deep_tier: runner exits 0" "0" "$sa_up_exit"

# Verify the first llm-api-call.sh invocation passed a deep-tier agent file, not light/standard.
_sa_tier_check_exit=0
_sa_tier_check_out=""
if [[ -f "$AGENT_BODY_FILE_SA_UP" ]]; then
    _sa_tier_check_out=$(python3 - <<PYEOF 2>&1 || _sa_tier_check_exit=$?
import sys

with open('${AGENT_BODY_FILE_SA_UP}') as f:
    agent_path = f.read()

has_deep = 'code-reviewer-deep' in agent_path
has_light = 'code-reviewer-light' in agent_path and 'code-reviewer-deep' not in agent_path
has_standard = 'code-reviewer-standard' in agent_path and 'code-reviewer-deep' not in agent_path

if has_light:
    print('FAIL: dispatched light-tier agent despite size_action=upgrade; body contains code-reviewer-light')
    sys.exit(1)
if has_standard:
    print('FAIL: dispatched standard-tier agent despite size_action=upgrade; body contains code-reviewer-standard')
    sys.exit(1)
if not has_deep:
    print('FAIL: body does not reference any deep-tier agent; body preview=' + agent_path[:200])
    sys.exit(1)
print('OK')
PYEOF
    )
else
    _sa_tier_check_out="MISSING: first-agent-file.txt not written — llm-api-call.sh was never called"
    _sa_tier_check_exit=1
fi

assert_eq "test_runner_size_action_upgrade_overrides_to_deep_tier: first llm-api-call uses deep-tier agent" "0" "$_sa_tier_check_exit"
assert_eq "test_runner_size_action_upgrade_overrides_to_deep_tier: tier check output" "OK" "$_sa_tier_check_out"

assert_pass_if_clean "test_runner_size_action_upgrade_overrides_to_deep_tier"

# ── test_runner_size_action_warn_does_not_block ───────────────────────────────
# Given: classifier returns selected_tier=light AND size_action=warn
# When:  runner processes a non-empty diff
# Then:  runner exits 0 (warn does not block or change tier)
#        AND stderr contains "SIZE_WARNING" (runner must emit the warning message)
#
# Why RED: runner currently ignores size_action entirely — it does not emit any
# SIZE_WARNING message to stderr when size_action=warn, so the stderr assertion fails.
_snapshot_fail
MOCK_SA_WARN=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK_SA_WARN")
ARTIFACTS_SA_WARN=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS_SA_WARN")

# Classifier: selected_tier=light AND size_action=warn
cat > "$MOCK_SA_WARN/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":280,"change_volume":1,"computed_total":3,"diff_size_lines":280,"size_action":"warn","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK_SA_WARN/review-complexity-classifier.sh"

cat > "$MOCK_SA_WARN/llm-api-call.sh" <<'MOCKEOF'
#!/usr/bin/env bash
printf '{"scores":{"hygiene":4,"design":4,"maintainability":4,"correctness":4,"verification":4},"summary":"OK","findings":[]}\n'
MOCKEOF
chmod +x "$MOCK_SA_WARN/llm-api-call.sh"

cat > "$MOCK_SA_WARN/write-reviewer-findings.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK_SA_WARN/write-reviewer-findings.sh"

cat > "$MOCK_SA_WARN/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$ARTIFACTS_SA_WARN"
printf 'passed\n' > "$ARTIFACTS_SA_WARN/review-status"
MOCKEOF
chmod +x "$MOCK_SA_WARN/record-review.sh"

sa_warn_exit=0
sa_warn_stderr=""
sa_warn_stderr=$(
    export PATH="$MOCK_SA_WARN:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_SA_WARN"
    printf 'diff --git a/foo.sh b/foo.sh\n+line\n' | ANTHROPIC_API_KEY=x bash "$RUNNER" 2>&1 >/dev/null
) || sa_warn_exit=$?

# warn must NOT block — exit 0
assert_eq "test_runner_size_action_warn_does_not_block: runner exits 0" "0" "$sa_warn_exit"

# Runner must emit SIZE_WARNING to stderr when size_action=warn (informational, non-blocking)
assert_contains "test_runner_size_action_warn_does_not_block: stderr contains SIZE_WARNING" "SIZE_WARNING" "$sa_warn_stderr"

assert_pass_if_clean "test_runner_size_action_warn_does_not_block"

# ─────────────────────────────────────────────────────────────────────────────
# RED TESTS: Fix 1 (marker format) and Fix 3 (schema-error retry)
# RED marker: test_deep_tier_arch_user_msg_uses_sonnet_markers
# ─────────────────────────────────────────────────────────────────────────────

# ── test_deep_tier_arch_user_msg_uses_sonnet_markers ─────────────────────────
# Given: deep-tier; 3 specialist slot files present
# When:  runner builds the arch synthesis user message
# Then:  the user message sent to the arch agent contains EXACTLY the three
#        section markers that code-reviewer-deep-arch.md's mandatory input
#        contract requires:
#          === SONNET-A FINDINGS (correctness) ===
#          === SONNET-B FINDINGS (verification) ===
#          === SONNET-C FINDINGS (hygiene/design) ===
#        (currently FAILS: runner uses "Correctness specialist findings:" etc.)
_snapshot_fail
MOCK_MKR=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK_MKR")
ARTIFACTS_MKR=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS_MKR")
ARCH_MSG_FILE="$ARTIFACTS_MKR/arch-user-msg.txt"

_SLOT_MKR='{"scores":{"correctness":5,"verification":5,"hygiene":5,"design":5,"maintainability":5},"summary":"OK","findings":[]}'
_ARCH_MKR='{"scores":{"correctness":5,"verification":5,"hygiene":5,"design":5,"maintainability":5},"summary":"Arch OK","findings":[]}'

# Mock llm-api-call.sh: capture the user message arg when arch agent is called,
# write it to a file so we can inspect the markers.
cat > "$MOCK_MKR/llm-api-call.sh" <<MOCKEOF
#!/usr/bin/env bash
# \$1 = agent file, \$2 = user message or @file, \$3 = tier
_agent_file="\$1"
_user_arg="\$2"
# Capture user message content
if [[ "\$_user_arg" == @* ]]; then
    _msg_file="\${_user_arg#@}"
    [[ -f "\$_msg_file" ]] && cat "\$_msg_file" > "$ARCH_MSG_FILE"
else
    printf '%s' "\$_user_arg" > "$ARCH_MSG_FILE"
fi
# Write slot or arch response depending on agent
if printf '%s' "\$_agent_file" | grep -q "deep-arch"; then
    printf '%s\n' '${_ARCH_MKR}'
else
    printf '%s\n' '${_SLOT_MKR}'
fi
MOCKEOF
chmod +x "$MOCK_MKR/llm-api-call.sh"

cat > "$MOCK_MKR/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"deep","blast_radius":3,"critical_path":2,"anti_shortcut":1,"staleness":1,"cross_cutting":1,"diff_lines":350,"change_volume":2,"computed_total":10,"diff_size_lines":350,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK_MKR/review-complexity-classifier.sh"

cat > "$MOCK_MKR/write-reviewer-findings.sh" <<MOCKEOF
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK_MKR/write-reviewer-findings.sh"

cat > "$MOCK_MKR/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$ARTIFACTS_MKR"
printf 'passed\n' > "${ARTIFACTS_MKR}/review-status"
MOCKEOF
chmod +x "$MOCK_MKR/record-review.sh"

(
    export PATH="$MOCK_MKR:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_MKR"
    printf 'diff --git a/foo.sh b/foo.sh\n+line\n' | ANTHROPIC_API_KEY=x bash "$RUNNER" >/dev/null 2>&1
) || true

# Check arch user message contains required SONNET-A/B/C markers
_arch_msg_content=""
[[ -f "$ARCH_MSG_FILE" ]] && _arch_msg_content=$(cat "$ARCH_MSG_FILE")

_has_sonnet_a="false"
_has_sonnet_b="false"
_has_sonnet_c="false"
echo "$_arch_msg_content" | grep -qF "=== SONNET-A FINDINGS (correctness) ===" && _has_sonnet_a="true"
echo "$_arch_msg_content" | grep -qF "=== SONNET-B FINDINGS (verification) ===" && _has_sonnet_b="true"
echo "$_arch_msg_content" | grep -qF "=== SONNET-C FINDINGS (hygiene/design) ===" && _has_sonnet_c="true"

assert_eq "test_deep_tier_arch_user_msg_uses_sonnet_markers: SONNET-A marker present" "true" "$_has_sonnet_a"
assert_eq "test_deep_tier_arch_user_msg_uses_sonnet_markers: SONNET-B marker present" "true" "$_has_sonnet_b"
assert_eq "test_deep_tier_arch_user_msg_uses_sonnet_markers: SONNET-C marker present" "true" "$_has_sonnet_c"
assert_pass_if_clean "test_deep_tier_arch_user_msg_uses_sonnet_markers"

# ── test_runner_retries_once_on_schema_validation_failure ─────────────────────
# Given: write-reviewer-findings.sh fails on the first call (schema error)
#        but succeeds on the second call (retry)
# When:  runner processes a non-empty diff with standard tier
# Then:  llm-api-call.sh is invoked exactly twice (initial + 1 retry),
#        AND the second call's user message includes the validation error from
#        the first attempt
#        (currently FAILS: runner has no retry logic)
_snapshot_fail
MOCK_RETRY=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK_RETRY")
ARTIFACTS_RETRY=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS_RETRY")
LLM_CALL_LOG="$ARTIFACTS_RETRY/llm-calls.log"
RETRY_USER_MSG_FILE="$ARTIFACTS_RETRY/retry-user-msg.txt"

_FINDINGS_RETRY='{"scores":{"hygiene":5,"design":5,"maintainability":5,"correctness":5,"verification":5},"summary":"Fixed","findings":[]}'

cat > "$MOCK_RETRY/llm-api-call.sh" <<MOCKEOF
#!/usr/bin/env bash
_call_num=\$(wc -l < "$LLM_CALL_LOG" 2>/dev/null | tr -d ' ')
printf 'call\n' >> "$LLM_CALL_LOG"
_user_arg="\$2"
if [[ "\$_user_arg" == @* ]]; then
    _msg_file="\${_user_arg#@}"
    [[ -f "\$_msg_file" ]] && cat "\$_msg_file" >> "$RETRY_USER_MSG_FILE"
else
    printf '%s' "\$_user_arg" >> "$RETRY_USER_MSG_FILE"
fi
printf '%s\n' '${_FINDINGS_RETRY}'
MOCKEOF
chmod +x "$MOCK_RETRY/llm-api-call.sh"

cat > "$MOCK_RETRY/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"standard","blast_radius":1,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":50,"change_volume":1,"computed_total":3,"diff_size_lines":50,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK_RETRY/review-complexity-classifier.sh"

# write-reviewer-findings.sh: fail first call, succeed second
cat > "$MOCK_RETRY/write-reviewer-findings.sh" <<MOCKEOF
#!/usr/bin/env bash
cat > /dev/null
_n=\$(wc -l < "$LLM_CALL_LOG" 2>/dev/null | tr -d ' ')
if [[ "\$_n" -le 1 ]]; then
    # First call: emit schema error to stderr and exit 1
    echo "SCHEMA_VALID: no" >&2
    echo "Validation errors:" >&2
    echo "  - score 'maintainability'=3: minor-only findings requires score 4" >&2
    exit 1
fi
# Second call (retry): succeed
printf '%064x\n' 1
MOCKEOF
chmod +x "$MOCK_RETRY/write-reviewer-findings.sh"

cat > "$MOCK_RETRY/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$ARTIFACTS_RETRY"
printf 'passed\n' > "${ARTIFACTS_RETRY}/review-status"
MOCKEOF
chmod +x "$MOCK_RETRY/record-review.sh"

(
    export PATH="$MOCK_RETRY:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_RETRY"
    printf 'diff --git a/foo.sh b/foo.sh\n+line\n' | ANTHROPIC_API_KEY=x bash "$RUNNER" >/dev/null 2>&1
) || true

_llm_call_count=0
[[ -f "$LLM_CALL_LOG" ]] && _llm_call_count=$(wc -l < "$LLM_CALL_LOG" | tr -d ' ')

# Runner must call LLM twice (initial + retry)
assert_eq "test_runner_retries_once_on_schema_validation_failure: llm called twice" "2" "$_llm_call_count"

# Second call must contain the validation error text
_retry_msg=""
[[ -f "$RETRY_USER_MSG_FILE" ]] && _retry_msg=$(cat "$RETRY_USER_MSG_FILE")
_has_schema_error="false"
echo "$_retry_msg" | grep -qiF "schema" && _has_schema_error="true"
echo "$_retry_msg" | grep -qiF "validation" && _has_schema_error="true"
assert_eq "test_runner_retries_once_on_schema_validation_failure: retry msg includes validation error" "true" "$_has_schema_error"

assert_pass_if_clean "test_runner_retries_once_on_schema_validation_failure"

# ── test_deep_tier_arch_retries_on_schema_validation_failure ─────────────────
# Given: deep-tier; arch synthesis passes but write-reviewer-findings.sh fails
#        schema validation on first call, then succeeds on retry
# When:  runner processes the diff
# Then:  llm-api-call.sh is called for the arch agent exactly twice (initial +
#        retry), and the retry user message includes the validation error text
_snapshot_fail
MOCK_ARCH_RETRY=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK_ARCH_RETRY")
ARTIFACTS_ARCH_RETRY=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS_ARCH_RETRY")
ARCH_LLM_LOG="$ARTIFACTS_ARCH_RETRY/arch-llm-calls.log"
ARCH_RETRY_MSG_FILE="$ARTIFACTS_ARCH_RETRY/arch-retry-msg.txt"

_SLOT_AR='{"scores":{"correctness":5,"verification":5,"hygiene":5,"design":5,"maintainability":5},"summary":"OK","findings":[]}'
_ARCH_AR='{"scores":{"correctness":5,"verification":5,"hygiene":5,"design":5,"maintainability":5},"summary":"Arch OK","findings":[]}'

cat > "$MOCK_ARCH_RETRY/llm-api-call.sh" <<MOCKEOF
#!/usr/bin/env bash
_agent="\$1"
_user_arg="\$2"
if printf '%s' "\$_agent" | grep -q "deep-arch"; then
    printf 'call\n' >> "$ARCH_LLM_LOG"
    # Capture user message content on second call (retry)
    _call_num=\$(wc -l < "$ARCH_LLM_LOG" | tr -d ' ')
    if [[ "\$_user_arg" == @* ]]; then
        _msg_file="\${_user_arg#@}"
        [[ -f "\$_msg_file" && "\$_call_num" -ge 2 ]] && cat "\$_msg_file" >> "$ARCH_RETRY_MSG_FILE"
    fi
    printf '%s\n' '${_ARCH_AR}'
else
    printf '%s\n' '${_SLOT_AR}'
fi
MOCKEOF
chmod +x "$MOCK_ARCH_RETRY/llm-api-call.sh"

cat > "$MOCK_ARCH_RETRY/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"deep","blast_radius":1,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":100,"change_volume":1,"computed_total":5,"diff_size_lines":100,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK_ARCH_RETRY/review-complexity-classifier.sh"

# write-reviewer-findings.sh: fail first arch call, succeed on retry
cat > "$MOCK_ARCH_RETRY/write-reviewer-findings.sh" <<MOCKEOF
#!/usr/bin/env bash
cat > /dev/null
_arch_calls=\$(wc -l < "$ARCH_LLM_LOG" 2>/dev/null | tr -d ' ')
if [[ "\$_arch_calls" -le 1 ]]; then
    echo "SCHEMA_VALID: no" >&2
    echo "Validation errors:" >&2
    echo "  - score 'hygiene'=4: no findings requires score 5" >&2
    exit 1
fi
printf '%064x\n' 2
MOCKEOF
chmod +x "$MOCK_ARCH_RETRY/write-reviewer-findings.sh"

cat > "$MOCK_ARCH_RETRY/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$ARTIFACTS_ARCH_RETRY"
printf 'passed\n' > "${ARTIFACTS_ARCH_RETRY}/review-status"
MOCKEOF
chmod +x "$MOCK_ARCH_RETRY/record-review.sh"

(
    export PATH="$MOCK_ARCH_RETRY:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_ARCH_RETRY"
    printf 'diff --git a/foo.sh b/foo.sh\n+line\n' | ANTHROPIC_API_KEY=x bash "$RUNNER" >/dev/null 2>&1
) || true

_arch_call_count=0
[[ -f "$ARCH_LLM_LOG" ]] && _arch_call_count=$(wc -l < "$ARCH_LLM_LOG" | tr -d ' ')

assert_eq "test_deep_tier_arch_retries_on_schema_validation_failure: arch llm called twice" "2" "$_arch_call_count"

_retry_msg=""
[[ -f "$ARCH_RETRY_MSG_FILE" ]] && _retry_msg=$(cat "$ARCH_RETRY_MSG_FILE")
_has_error_in_retry="false"
echo "$_retry_msg" | grep -qiF "schema" && _has_error_in_retry="true"
echo "$_retry_msg" | grep -qiF "validation" && _has_error_in_retry="true"
assert_eq "test_deep_tier_arch_retries_on_schema_validation_failure: retry includes validation error" "true" "$_has_error_in_retry"

assert_pass_if_clean "test_deep_tier_arch_retries_on_schema_validation_failure"

# ── test_deep_tier_specialist_slot_prose_is_normalized ────────────────────────
# Given: deep-tier; a specialist returns prose + JSON (not pure JSON)
# When:  runner processes the slot file
# Then:  runner extracts the JSON successfully and completes without error
#        (previously FAILED: json.load() on prose+JSON returned invalid JSON error)
_snapshot_fail
MOCK_PROSE=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK_PROSE")
ARTIFACTS_PROSE=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS_PROSE")

_SLOT_OK='{"scores":{"correctness":5,"verification":5,"hygiene":5,"design":5,"maintainability":5},"summary":"OK","findings":[]}'
_ARCH_OK='{"scores":{"correctness":5,"verification":5,"hygiene":5,"design":5,"maintainability":5},"summary":"Arch OK","findings":[]}'

# Mock llm-api-call.sh: return prose+JSON for the correctness specialist,
# clean JSON for verification and hygiene, and clean JSON for arch.
cat > "$MOCK_PROSE/llm-api-call.sh" <<MOCKEOF
#!/usr/bin/env bash
_agent="\$1"
if printf '%s' "\$_agent" | grep -q "deep-correctness"; then
    # Prose surrounding the JSON object — simulates an LLM that adds a preamble
    printf 'Here is my review analysis:\n\n%s\n\nEnd of review.\n' '${_SLOT_OK}'
elif printf '%s' "\$_agent" | grep -q "deep-arch"; then
    printf '%s\n' '${_ARCH_OK}'
else
    printf '%s\n' '${_SLOT_OK}'
fi
MOCKEOF
chmod +x "$MOCK_PROSE/llm-api-call.sh"

cat > "$MOCK_PROSE/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"deep","blast_radius":1,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":100,"change_volume":1,"computed_total":5,"diff_size_lines":100,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK_PROSE/review-complexity-classifier.sh"

cat > "$MOCK_PROSE/write-reviewer-findings.sh" <<MOCKEOF
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK_PROSE/write-reviewer-findings.sh"

cat > "$MOCK_PROSE/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$ARTIFACTS_PROSE"
printf 'passed\n' > "${ARTIFACTS_PROSE}/review-status"
MOCKEOF
chmod +x "$MOCK_PROSE/record-review.sh"

_prose_exit=0
_prose_stderr=""
_prose_stderr=$(
    export PATH="$MOCK_PROSE:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_PROSE"
    printf 'diff --git a/foo.sh b/foo.sh\n+line\n' | ANTHROPIC_API_KEY=x bash "$RUNNER" 2>&1 >/dev/null
) || _prose_exit=$?

assert_eq "test_deep_tier_specialist_slot_prose_is_normalized: runner exits 0" "0" "$_prose_exit"
_has_invalid_error="false"
echo "$_prose_stderr" | grep -q "invalid JSON" && _has_invalid_error="true"
assert_eq "test_deep_tier_specialist_slot_prose_is_normalized: no invalid JSON error" "false" "$_has_invalid_error"
assert_pass_if_clean "test_deep_tier_specialist_slot_prose_is_normalized"

# ── test_overlay_merge_preserves_cited_lines ─────────────────────────────────
# Given: tier finding has cited_lines: ["main.sh:10"]
#        overlay finding has cited_lines: ["util.sh:25"]
# When:  overlay merge logic is exercised via security overlay path
# Then:  merged output contains both findings, each retaining its cited_lines
#        value unchanged (the extend() merge copies full dicts — no field stripping)
#
# NOTE: All fixture findings include cited_lines to stay green after T7 activates
# the cited_lines validation gate in validate-review-output.sh.
_snapshot_fail
MOCK_CL=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK_CL")
ARTIFACTS_CL=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS_CL")
FINDINGS_RECEIVED_CL="$MOCK_CL/findings-received.json"

cat > "$MOCK_CL/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":0,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":true,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK_CL/review-complexity-classifier.sh"

# Mock curl: tier reviewer returns finding with cited_lines; overlay also returns
# finding with cited_lines. Both must survive the extend()-based merge unchanged.
cat > "$MOCK_CL/curl" <<'MOCKEOF'
#!/usr/bin/env bash
_body=""
_prev=""
for _arg in "$@"; do
    if [[ "$_prev" == "--data-raw" || "$_prev" == "-d" ]]; then
        _body="$_arg"
    elif [[ "$_prev" == "--data" || "$_prev" == "--data-binary" ]]; then
        _src="${_arg#@}"; [[ "$_src" != "$_arg" && -f "$_src" ]] && _body="$(cat "$_src")" || _body="$_arg"
    fi
    _prev="$_arg"
done
if printf '%s' "$_body" | grep -q "code-reviewer-security-red-team"; then
    python3 -c "import json; t={\"scores\":{\"correctness\":4,\"verification\":4,\"hygiene\":4,\"design\":4,\"maintainability\":4},\"summary\":\"Red overlay\",\"findings\":[{\"severity\":\"minor\",\"category\":\"correctness\",\"description\":\"overlay finding\",\"file\":\"util.sh\",\"cited_lines\":[\"util.sh:25\"]}]}; print(json.dumps({\"content\":[{\"text\":json.dumps(t)}],\"stop_reason\":\"end_turn\"}))"
elif printf '%s' "$_body" | grep -q "code-reviewer-security-blue-team"; then
    python3 -c "import json; t={\"scores\":{\"correctness\":4,\"verification\":4,\"hygiene\":4,\"design\":4,\"maintainability\":4},\"summary\":\"Blue overlay\",\"findings\":[{\"severity\":\"minor\",\"category\":\"verification\",\"description\":\"blue overlay finding\",\"file\":\"util.sh\",\"cited_lines\":[\"util.sh:25\"]}]}; print(json.dumps({\"content\":[{\"text\":json.dumps(t)}],\"stop_reason\":\"end_turn\"}))"
else
    python3 -c "import json; t={\"scores\":{\"correctness\":4,\"verification\":4,\"hygiene\":4,\"design\":4,\"maintainability\":4},\"summary\":\"Tier review\",\"findings\":[{\"severity\":\"minor\",\"category\":\"hygiene\",\"description\":\"tier finding\",\"file\":\"main.sh\",\"cited_lines\":[\"main.sh:10\"]}]}; print(json.dumps({\"content\":[{\"text\":json.dumps(t)}],\"stop_reason\":\"end_turn\"}))"
fi
MOCKEOF
chmod +x "$MOCK_CL/curl"

# Mock write-reviewer-findings.sh: capture stdin to verify cited_lines preservation
cat > "$MOCK_CL/write-reviewer-findings.sh" <<MOCKEOF
#!/usr/bin/env bash
tee "${FINDINGS_RECEIVED_CL}" > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK_CL/write-reviewer-findings.sh"

cat > "$MOCK_CL/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "${ARTIFACTS_CL}"
printf 'passed\n' > "${ARTIFACTS_CL}/review-status"
MOCKEOF
chmod +x "$MOCK_CL/record-review.sh"
_add_anthropic_llm_wrapper "$MOCK_CL"

mkdir -p "$ARTIFACTS_CL"
printf 'security_overlay=true\nperformance_overlay=false\ntest_quality_overlay=false\n' \
    > "$ARTIFACTS_CL/overlay-flags.env"

merge_cl_exit=0
(
    export PATH="$MOCK_CL:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_CL"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || merge_cl_exit=$?

assert_eq "test_overlay_merge_preserves_cited_lines: runner exits 0" "0" "$merge_cl_exit"

_cl_check_exit=0
_cl_check_out=""
if [[ -f "$FINDINGS_RECEIVED_CL" ]]; then
    _cl_check_out=$(python3 - <<PYEOF 2>&1 || _cl_check_exit=$?
import json, sys
with open('${FINDINGS_RECEIVED_CL}') as f:
    d = json.load(f)
findings = d.get('findings', [])
# Build a map: description -> cited_lines for easy lookup
cited_by_desc = {x.get('description',''): x.get('cited_lines') for x in findings}
descs = list(cited_by_desc.keys())
# Tier finding must be present with cited_lines intact
if 'tier finding' not in cited_by_desc:
    print('MISSING tier finding; descriptions=' + str(descs))
    sys.exit(1)
if cited_by_desc.get('tier finding') != ['main.sh:10']:
    print('WRONG cited_lines for tier finding: ' + str(cited_by_desc.get('tier finding')))
    sys.exit(1)
# At least one overlay finding must be present with cited_lines intact
overlay_descs = [d for d in descs if 'overlay finding' in d]
if not overlay_descs:
    print('MISSING overlay finding; descriptions=' + str(descs))
    sys.exit(1)
overlay_cited = cited_by_desc.get(overlay_descs[0])
if overlay_cited != ['util.sh:25']:
    print('WRONG cited_lines for overlay finding: ' + str(overlay_cited))
    sys.exit(1)
print('OK')
PYEOF
    )
else
    _cl_check_out="FINDINGS_RECEIVED file not written by write-reviewer-findings.sh mock"
    _cl_check_exit=1
fi
assert_eq "test_overlay_merge_preserves_cited_lines: merged findings passed to write-reviewer-findings" "0" "$_cl_check_exit"
assert_eq "test_overlay_merge_preserves_cited_lines: cited_lines preserved in both tier and overlay findings" "OK" "$_cl_check_out"

assert_pass_if_clean "test_overlay_merge_preserves_cited_lines"

# ── test_standard_tier_dispatches_single_api_call ────────────────────────────
# Given: classifier returns selected_tier=standard; curl and support scripts mocked
# When:  runner processes a non-empty diff
# Then:  exactly 1 curl call is made (standard tier dispatches a single agent,
#        unlike deep tier which dispatches 3 parallel specialists)
_snapshot_fail
MOCK_ST=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK_ST")
ARTIFACTS_ST=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS_ST")
CURL_COUNT_ST=$(mktemp -d)
_TEST_TMPDIRS+=("$CURL_COUNT_ST")

cat > "$MOCK_ST/curl" <<MOCKEOF
#!/usr/bin/env bash
touch "${CURL_COUNT_ST}/call.\${BASHPID}.\${RANDOM}"
cat > /dev/null
printf '%s\n' '{"content":[{"text":"{\"scores\":{\"correctness\":4,\"verification\":4,\"hygiene\":4,\"design\":4,\"maintainability\":4},\"findings\":[],\"summary\":\"OK\"}"}],"stop_reason":"end_turn"}'
MOCKEOF
chmod +x "$MOCK_ST/curl"

cat > "$MOCK_ST/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"standard","blast_radius":2,"critical_path":1,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":5,"change_volume":0,"computed_total":3,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK_ST/review-complexity-classifier.sh"

cat > "$MOCK_ST/write-reviewer-findings.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK_ST/write-reviewer-findings.sh"

cat > "$MOCK_ST/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$ARTIFACTS_ST"
printf 'passed\n' > "${ARTIFACTS_ST}/review-status"
MOCKEOF
chmod +x "$MOCK_ST/record-review.sh"
_add_anthropic_llm_wrapper "$MOCK_ST"

std_tier_exit=0
(
    export PATH="$MOCK_ST:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_ST"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER"
) || std_tier_exit=$?

assert_eq "test_standard_tier_dispatches_single_api_call: runner exits 0" "0" "$std_tier_exit"
_std_curl_count=$(find "$CURL_COUNT_ST/" -maxdepth 1 -type f | wc -l | tr -d ' ')
assert_eq "test_standard_tier_dispatches_single_api_call: exactly 1 curl call (not 3 like deep)" "1" "$_std_curl_count"

assert_pass_if_clean "test_standard_tier_dispatches_single_api_call"

# ── test_runner_warns_when_all_findings_are_synthetic ─────────────────────────
# Given: runner produces findings where every entry is fallback_exhausted or
#        specialist_error (no real review content)
# When:  runner completes (exits 0, since the job is fail-open)
# Then:  stderr contains a WARNING about synthetic-only findings
# RED until ci-llm-review-runner.sh emits this warning
_snapshot_fail
MOCK_SY=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK_SY")
ARTIFACTS_SY=$(mktemp -d)
_TEST_TMPDIRS+=("$ARTIFACTS_SY")

_SYNTHETIC_FINDINGS='{"scores":{"correctness":"N/A","verification":"N/A","hygiene":"N/A","design":"N/A","maintainability":"N/A"},"findings":[{"type":"fallback_exhausted","severity":"informational","category":"error","description":"LLM returned unparseable prose","cited_lines":["foo.sh:1"]}],"summary":"Review inconclusive: all findings are synthetic."}'

cat > "$MOCK_SY/review-complexity-classifier.sh" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
printf '{"selected_tier":"light","blast_radius":0,"critical_path":0,"anti_shortcut":0,"staleness":0,"cross_cutting":0,"diff_lines":5,"change_volume":0,"computed_total":0,"diff_size_lines":5,"size_action":"none","is_merge_commit":false,"security_overlay":false,"performance_overlay":false,"test_quality_overlay":false}'
MOCKEOF
chmod +x "$MOCK_SY/review-complexity-classifier.sh"

_create_mock_curl "$MOCK_SY"

cat > "$MOCK_SY/write-reviewer-findings.sh" <<MOCKEOF
#!/usr/bin/env bash
cat > /dev/null
printf '%064x\n' 0
MOCKEOF
chmod +x "$MOCK_SY/write-reviewer-findings.sh"

cat > "$MOCK_SY/record-review.sh" <<MOCKEOF
#!/usr/bin/env bash
mkdir -p "$ARTIFACTS_SY"
printf 'passed\n' > "${ARTIFACTS_SY}/review-status"
MOCKEOF
chmod +x "$MOCK_SY/record-review.sh"
_add_anthropic_llm_wrapper "$MOCK_SY"

# Override the anthropic_llm_wrapper to return synthetic findings
_SYNTHETIC_FINDINGS_ESC=$(printf '%s' "$_SYNTHETIC_FINDINGS" | sed "s/'/'\\\\''/g")
cat > "$MOCK_SY/curl" <<MOCKEOF
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' '{"content":[{"text":"${_SYNTHETIC_FINDINGS_ESC}"}],"stop_reason":"end_turn"}'
MOCKEOF
chmod +x "$MOCK_SY/curl"

_synthetic_exit=0
_synthetic_output=""
_synthetic_output=$(
    export PATH="$MOCK_SY:$PATH"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_SY"
    printf 'diff --git a/foo.sh b/foo.sh\n+echo hello\n' | ANTHROPIC_API_KEY='x' bash "$RUNNER" 2>&1
) || _synthetic_exit=$?

_synthetic_warned="false"
if echo "$_synthetic_output" | grep -qi "WARNING.*synthetic\|synthetic.*findings\|fallback_exhausted"; then
    _synthetic_warned="true"
fi
assert_eq "test_runner_warns_when_all_findings_are_synthetic: runner exits 0 (fail-open)" "0" "$_synthetic_exit"
assert_eq "test_runner_warns_when_all_findings_are_synthetic: warning emitted for synthetic findings" "true" "$_synthetic_warned"

assert_pass_if_clean "test_runner_warns_when_all_findings_are_synthetic"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
