#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031  # PATH/env modifications in subshells are intentional test isolation
# tests/scripts/test-llm-api-call.sh
# Behavioral tests for plugins/dso/scripts/llm-api-call.sh
# Verifies request construction, response normalization, and error handling.
#
# Tests covered:
#   1. test_anthropic_constructs_correct_headers       — curl args contain x-api-key and anthropic-version headers
#   2. test_openai_constructs_correct_headers          — curl args contain Authorization Bearer, NO x-api-key
#   3. test_anthropic_normalizes_response_envelope     — extracts inner text from content[].text envelope
#   4. test_openai_normalizes_response_envelope        — extracts inner content from choices[].message.content
#   5. test_missing_api_key_exits_nonzero              — ANTHROPIC_API_KEY unset → exit non-zero, stderr mentions key
#   6. test_wrong_provider_key_exits_nonzero           — anthropic provider but only OPENAI_API_KEY set → non-zero
#   7. test_4xx_error_surfaces_diagnostic              — 4xx error surfaces provider/tier/model/error on one stderr line
#   8. test_openai_request_body_contains_response_format — request body has response_format.type == "json_object"
#   9. test_markdown_fence_stripping                   — fenced JSON in response is unwrapped to plain JSON on stdout
#  10. test_ci_mode_suffix_appended_to_system_prompt   — request body system field contains CI-PIPELINE CONSTRAINT
#  11. test_ci_context_marker_present_when_github_actions_set — GITHUB_ACTIONS=true → REVIEW_CONTEXT: ci first line of user message
#  12. test_ci_context_marker_absent_when_github_actions_unset — GITHUB_ACTIONS unset → REVIEW_CONTEXT: ci absent from user message
#
# Usage: bash tests/scripts/test-llm-api-call.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

SCRIPT="$REPO_ROOT/plugins/dso/scripts/llm-api-call.sh"

# Track temp dirs for cleanup
_TEST_TMPDIRS=()
cleanup() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap cleanup EXIT

# ── Helper: create a mock curl that captures all args to a file ───────────────
# Usage: _create_mock_curl_args <mock_dir> <args_capture_file> <response_body>
#   mock_dir         — directory where mock curl will be written and made +x
#   args_capture_file — path; all curl arguments are captured (one per line) at runtime
#   response_body     — string; what the mock curl prints to stdout
_create_mock_curl_args() {
    local mock_dir="$1"
    local args_file="$2"
    local response_body="$3"
    local response_file="$mock_dir/curl-response.json"
    printf '%s' "$response_body" > "$response_file"

    cat > "$mock_dir/curl" <<MOCKEOF
#!/usr/bin/env bash
# Capture all args to file for inspection
printf '%s\n' "\$@" > "${args_file}"
cat "${response_file}"
MOCKEOF
    chmod +x "$mock_dir/curl"
}

# ── Helper: create a config-aware mock curl ──────────────────────────────────
# Usage: _create_mock_curl_config_aware <mock_dir> <args_capture_file> <response_body>
# Like _create_mock_curl_args but also expands --config <file> into the captured output.
# After capture, args_capture_file contains CLI args PLUS inline: "=CONFIG: header = ..."
_create_mock_curl_config_aware() {
    local mock_dir="$1"
    local args_file="$2"
    local response_body="$3"
    local response_file="$mock_dir/curl-response.json"
    printf '%s' "$response_body" > "$response_file"

    cat > "$mock_dir/curl" <<MOCKEOF
#!/usr/bin/env bash
prev=""
config_content=""
for arg in "\$@"; do
    if [[ "\$prev" == "--config" ]]; then
        config_content=\$(cat "\$arg" 2>/dev/null || true)
    fi
    prev="\$arg"
done
printf '%s\n' "\$@" > "${args_file}"
if [[ -n "\$config_content" ]]; then
    printf '%s\n' "=CONFIG:" "\$config_content" >> "${args_file}"
fi
cat "${response_file}"
MOCKEOF
    chmod +x "$mock_dir/curl"
}

# ── Helper: create a mock curl that captures the request body separately ──────
# Usage: _create_mock_curl_body <mock_dir> <body_capture_file> <response_body>
_create_mock_curl_body() {
    local mock_dir="$1"
    local body_file="$2"
    local response_body="$3"
    local response_file="$mock_dir/curl-response.json"
    printf '%s' "$response_body" > "$response_file"

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
    chmod +x "$mock_dir/curl"
}

# ── Helper: write a minimal mock config file ──────────────────────────────────
# Usage: _write_config <path> <provider> <model_key> <model_value>
#   e.g. _write_config /tmp/c.conf anthropic standard claude-sonnet-4-6
_write_config() {
    local path="$1"
    local provider="$2"
    local tier="$3"
    local model="$4"
    printf 'model.provider=%s\nmodel.%s=%s\n' "$provider" "$tier" "$model" > "$path"
}

echo "=== test-llm-api-call.sh ==="

# ── test_anthropic_constructs_correct_headers ─────────────────────────────────
# Given: model.provider=anthropic, ANTHROPIC_API_KEY=test-key
# When:  llm-api-call.sh is invoked with tier=standard
# Then:  captured curl args contain -H "x-api-key: test-key" and -H "anthropic-version: 2023-06-01"
_snapshot_fail
MOCK1=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK1")
ARGS1="$MOCK1/curl-args.txt"
CONF1="$MOCK1/config.conf"
SYSPROMPT1="$MOCK1/system-prompt.md"
printf 'You are a reviewer.\n' > "$SYSPROMPT1"
_write_config "$CONF1" "anthropic" "standard" "claude-sonnet-4-6"
_create_mock_curl_config_aware "$MOCK1" "$ARGS1" \
    '{"content":[{"text":"{\"result\":\"ok\"}"}],"stop_reason":"end_turn"}'

headers_exit=0
(
    export PATH="$MOCK1:$PATH"
    unset OPENAI_API_KEY || true
    ANTHROPIC_API_KEY="test-key" bash "$SCRIPT" "$SYSPROMPT1" "review this" standard "$CONF1"
) > /dev/null 2>&1 || headers_exit=$?

args1_content=""
[[ -f "$ARGS1" ]] && args1_content="$(cat "$ARGS1")"
# Headers now sent via --config file (not CLI args) for security; check config section
assert_contains "test_anthropic_constructs_correct_headers: x-api-key header present in config" \
    "x-api-key: test-key" "$args1_content"
assert_contains "test_anthropic_constructs_correct_headers: anthropic-version header present in config" \
    "anthropic-version: 2023-06-01" "$args1_content"
assert_pass_if_clean "test_anthropic_constructs_correct_headers"

# ── test_openai_constructs_correct_headers ────────────────────────────────────
# Given: model.provider=openai, OPENAI_API_KEY=sk-test
# When:  llm-api-call.sh is invoked with tier=light
# Then:  captured curl args contain "Authorization: Bearer sk-test" and NO "x-api-key"
_snapshot_fail
MOCK2=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK2")
ARGS2="$MOCK2/curl-args.txt"
CONF2="$MOCK2/config.conf"
SYSPROMPT2="$MOCK2/system-prompt.md"
printf 'You are a reviewer.\n' > "$SYSPROMPT2"
_write_config "$CONF2" "openai" "light" "gpt-4o"
_create_mock_curl_config_aware "$MOCK2" "$ARGS2" \
    '{"choices":[{"message":{"content":"{\"result\":\"ok\"}"}}]}'

openai_headers_exit=0
(
    export PATH="$MOCK2:$PATH"
    unset ANTHROPIC_API_KEY || true
    OPENAI_API_KEY="sk-test" bash "$SCRIPT" "$SYSPROMPT2" "review this" light "$CONF2"
) > /dev/null 2>&1 || openai_headers_exit=$?

args2_content=""
[[ -f "$ARGS2" ]] && args2_content="$(cat "$ARGS2")"
# Authorization Bearer now sent via --config file; check config section
assert_contains "test_openai_constructs_correct_headers: Authorization Bearer present in config" \
    "Authorization: Bearer sk-test" "$args2_content"

# Verify x-api-key is NOT present (even in config)
if echo "$args2_content" | grep -q "x-api-key"; then
    assert_eq "test_openai_constructs_correct_headers: x-api-key must NOT appear" \
        "NOT_PRESENT" "PRESENT"
else
    assert_eq "test_openai_constructs_correct_headers: x-api-key must NOT appear" \
        "NOT_PRESENT" "NOT_PRESENT"
fi
assert_pass_if_clean "test_openai_constructs_correct_headers"

# ── test_anthropic_normalizes_response_envelope ───────────────────────────────
# Given: model.provider=anthropic, mock curl returns {"content":[{"text":"{\"foo\":1}"}],...}
# When:  llm-api-call.sh is invoked
# Then:  stdout contains {"foo":1} (extracted from content[].text)
_snapshot_fail
MOCK3=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK3")
CONF3="$MOCK3/config.conf"
SYSPROMPT3="$MOCK3/system-prompt.md"
printf 'You are a reviewer.\n' > "$SYSPROMPT3"
_write_config "$CONF3" "anthropic" "standard" "claude-sonnet-4-6"
_create_mock_curl_args "$MOCK3" "$MOCK3/args.txt" \
    '{"content":[{"text":"{\"foo\":1}"}],"stop_reason":"end_turn"}'

anthr_env_output=""
anthr_env_exit=0
anthr_env_output=$(
    export PATH="$MOCK3:$PATH"
    unset OPENAI_API_KEY || true
    ANTHROPIC_API_KEY="test-key" bash "$SCRIPT" "$SYSPROMPT3" "review this" standard "$CONF3" 2>/dev/null
) || anthr_env_exit=$?
assert_contains "test_anthropic_normalizes_response_envelope: stdout contains {\"foo\":1}" \
    '{"foo":1}' "$anthr_env_output"
assert_pass_if_clean "test_anthropic_normalizes_response_envelope"

# ── test_openai_normalizes_response_envelope ──────────────────────────────────
# Given: model.provider=openai, mock curl returns {"choices":[{"message":{"content":"{\"foo\":2}"}}]}
# When:  llm-api-call.sh is invoked
# Then:  stdout contains {"foo":2}
_snapshot_fail
MOCK4=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK4")
CONF4="$MOCK4/config.conf"
SYSPROMPT4="$MOCK4/system-prompt.md"
printf 'You are a reviewer.\n' > "$SYSPROMPT4"
_write_config "$CONF4" "openai" "standard" "gpt-4o"
_create_mock_curl_args "$MOCK4" "$MOCK4/args.txt" \
    '{"choices":[{"message":{"content":"{\"foo\":2}"}}]}'

openai_env_output=""
openai_env_exit=0
openai_env_output=$(
    export PATH="$MOCK4:$PATH"
    unset ANTHROPIC_API_KEY || true
    OPENAI_API_KEY="sk-test" bash "$SCRIPT" "$SYSPROMPT4" "review this" standard "$CONF4" 2>/dev/null
) || openai_env_exit=$?
assert_contains "test_openai_normalizes_response_envelope: stdout contains {\"foo\":2}" \
    '{"foo":2}' "$openai_env_output"
assert_pass_if_clean "test_openai_normalizes_response_envelope"

# ── test_missing_api_key_exits_nonzero ────────────────────────────────────────
# Given: model.provider=anthropic, ANTHROPIC_API_KEY unset
# When:  llm-api-call.sh is invoked
# Then:  exit code is non-zero and stderr contains "ANTHROPIC_API_KEY"
_snapshot_fail
MOCK5=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK5")
CONF5="$MOCK5/config.conf"
SYSPROMPT5="$MOCK5/system-prompt.md"
printf 'You are a reviewer.\n' > "$SYSPROMPT5"
_write_config "$CONF5" "anthropic" "standard" "claude-sonnet-4-6"

missing_key_exit=0
missing_key_stderr=""
missing_key_stderr=$(
    export PATH="$MOCK5:$PATH"
    unset ANTHROPIC_API_KEY || true
    unset OPENAI_API_KEY || true
    bash "$SCRIPT" "$SYSPROMPT5" "review this" standard "$CONF5" 2>&1 >/dev/null
) || missing_key_exit=$?

assert_ne "test_missing_api_key_exits_nonzero: exit code is non-zero" \
    "0" "$missing_key_exit"
assert_contains "test_missing_api_key_exits_nonzero: stderr mentions ANTHROPIC_API_KEY" \
    "ANTHROPIC_API_KEY" "$missing_key_stderr"
assert_pass_if_clean "test_missing_api_key_exits_nonzero"

# ── test_wrong_provider_key_exits_nonzero ─────────────────────────────────────
# Given: model.provider=anthropic, only OPENAI_API_KEY set (ANTHROPIC_API_KEY unset)
# When:  llm-api-call.sh is invoked
# Then:  exit code is non-zero (wrong-provider key does not substitute)
_snapshot_fail
MOCK6=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK6")
CONF6="$MOCK6/config.conf"
SYSPROMPT6="$MOCK6/system-prompt.md"
printf 'You are a reviewer.\n' > "$SYSPROMPT6"
_write_config "$CONF6" "anthropic" "standard" "claude-sonnet-4-6"

wrong_key_exit=0
(
    export PATH="$MOCK6:$PATH"
    unset ANTHROPIC_API_KEY || true
    OPENAI_API_KEY="sk-irrelevant" bash "$SCRIPT" "$SYSPROMPT6" "review this" standard "$CONF6"
) > /dev/null 2>&1 || wrong_key_exit=$?

assert_ne "test_wrong_provider_key_exits_nonzero: exit code is non-zero" \
    "0" "$wrong_key_exit"
assert_pass_if_clean "test_wrong_provider_key_exits_nonzero"

# ── test_4xx_error_surfaces_diagnostic ───────────────────────────────────────
# Given: model.provider=anthropic, mock curl writes HTTP 400 error JSON and exits 22
# When:  llm-api-call.sh is invoked with tier=standard and model.standard=invalid-model
# Then:  exit code is non-zero and stderr contains a single line with provider, tier,
#        model ID, and error text
_snapshot_fail
MOCK7=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK7")
CONF7="$MOCK7/config.conf"
SYSPROMPT7="$MOCK7/system-prompt.md"
printf 'You are a reviewer.\n' > "$SYSPROMPT7"
_write_config "$CONF7" "anthropic" "standard" "invalid-model"

# Mock curl: return error JSON, exit 22 (simulates HTTP 4xx with --fail)
local_response_file7="$MOCK7/curl-response.json"
printf '%s' '{"error":{"type":"invalid_request_error","message":"model not found"}}' \
    > "$local_response_file7"
cat > "$MOCK7/curl" <<MOCKEOF7
#!/usr/bin/env bash
cat "${local_response_file7}"
exit 22
MOCKEOF7
chmod +x "$MOCK7/curl"

err4xx_exit=0
err4xx_stderr=""
err4xx_stderr=$(
    export PATH="$MOCK7:$PATH"
    ANTHROPIC_API_KEY="test-key" bash "$SCRIPT" "$SYSPROMPT7" "review this" standard "$CONF7" 2>&1 >/dev/null
) || err4xx_exit=$?

assert_ne "test_4xx_error_surfaces_diagnostic: exit code is non-zero" \
    "0" "$err4xx_exit"
assert_contains "test_4xx_error_surfaces_diagnostic: stderr contains provider 'anthropic'" \
    "anthropic" "$err4xx_stderr"
assert_contains "test_4xx_error_surfaces_diagnostic: stderr contains tier 'standard'" \
    "standard" "$err4xx_stderr"
assert_contains "test_4xx_error_surfaces_diagnostic: stderr contains model 'invalid-model'" \
    "invalid-model" "$err4xx_stderr"
assert_contains "test_4xx_error_surfaces_diagnostic: stderr contains error text 'model not found'" \
    "model not found" "$err4xx_stderr"
assert_pass_if_clean "test_4xx_error_surfaces_diagnostic"

# ── test_openai_request_body_contains_response_format ────────────────────────
# Given: model.provider=openai, OPENAI_API_KEY=sk-test, captured curl body
# When:  llm-api-call.sh is invoked
# Then:  captured request body JSON contains response_format.type == "json_object"
_snapshot_fail
MOCK8=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK8")
BODY8="$MOCK8/curl-body.json"
CONF8="$MOCK8/config.conf"
SYSPROMPT8="$MOCK8/system-prompt.md"
printf 'You are a reviewer.\n' > "$SYSPROMPT8"
_write_config "$CONF8" "openai" "standard" "gpt-4o"
_create_mock_curl_body "$MOCK8" "$BODY8" \
    '{"choices":[{"message":{"content":"{\"result\":\"ok\"}"}}]}'

rf_exit=0
(
    export PATH="$MOCK8:$PATH"
    unset ANTHROPIC_API_KEY || true
    OPENAI_API_KEY="sk-test" bash "$SCRIPT" "$SYSPROMPT8" "review this" standard "$CONF8"
) > /dev/null 2>&1 || rf_exit=$?

rf_check_exit=0
rf_check_out=""
if [[ -f "$BODY8" ]]; then
    rf_check_out=$(python3 -c "
import json, sys
with open('$BODY8') as f:
    d = json.load(f)
rf = d.get('response_format', {})
t = rf.get('type', '')
if t != 'json_object':
    print('WRONG_TYPE: response_format.type=' + repr(t))
    sys.exit(1)
print('OK')
" 2>&1) || rf_check_exit=$?
else
    rf_check_out="MISSING_BODY_FILE: curl body was not captured"
    rf_check_exit=1
fi
assert_eq "test_openai_request_body_contains_response_format: body captured and parseable" \
    "0" "$rf_check_exit"
assert_eq "test_openai_request_body_contains_response_format: response_format.type is json_object" \
    "OK" "$rf_check_out"
assert_pass_if_clean "test_openai_request_body_contains_response_format"

# ── test_markdown_fence_stripping ─────────────────────────────────────────────
# Given: model.provider=anthropic, mock curl returns content where text is wrapped in
#        markdown fences (```json\n{...}\n```)
# When:  llm-api-call.sh is invoked
# Then:  stdout contains the unwrapped JSON (fences stripped), not the raw fenced string
_snapshot_fail
MOCK9=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK9")
CONF9="$MOCK9/config.conf"
SYSPROMPT9="$MOCK9/system-prompt.md"
printf 'You are a reviewer.\n' > "$SYSPROMPT9"
_write_config "$CONF9" "anthropic" "standard" "claude-sonnet-4-6"

# Build the mock response: content[].text is ```json\n{"bar":3}\n```
local_response_file9="$MOCK9/curl-response.json"
# \n inside single quotes is intentional: it's the JSON escape sequence for newline,
# not a shell newline. SC2016 is a false positive here — we want literal \n in output.
# shellcheck disable=SC2016
printf '{"content":[{"text":"```json\n{\"bar\":3}\n```"}],"stop_reason":"end_turn"}' \
    > "$local_response_file9"
cat > "$MOCK9/curl" <<MOCKEOF9
#!/usr/bin/env bash
cat "${local_response_file9}"
MOCKEOF9
chmod +x "$MOCK9/curl"

fence_output=""
fence_exit=0
fence_output=$(
    export PATH="$MOCK9:$PATH"
    unset OPENAI_API_KEY || true
    ANTHROPIC_API_KEY="test-key" bash "$SCRIPT" "$SYSPROMPT9" "review this" standard "$CONF9" 2>/dev/null
) || fence_exit=$?

assert_contains "test_markdown_fence_stripping: stdout contains unwrapped JSON {\"bar\":3}" \
    '{"bar":3}' "$fence_output"

# Verify raw fence markers are NOT present in stdout
if echo "$fence_output" | grep -q '```'; then
    assert_eq "test_markdown_fence_stripping: fence markers must NOT appear in stdout" \
        "NOT_PRESENT" "PRESENT"
else
    assert_eq "test_markdown_fence_stripping: fence markers must NOT appear in stdout" \
        "NOT_PRESENT" "NOT_PRESENT"
fi
assert_pass_if_clean "test_markdown_fence_stripping"

# ── test_ci_mode_suffix_appended_to_system_prompt ────────────────────────────
# Given: a system prompt file with generic content
# When:  llm-api-call.sh is invoked
# Then:  the request body's system field contains "CI-PIPELINE CONSTRAINT"
_snapshot_fail
MOCK10=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK10")
CONF10="$MOCK10/config.conf"
SYSPROMPT10="$MOCK10/system-prompt.md"
BODY10="$MOCK10/request-body.json"
printf 'You are a reviewer. Output JSON.\n' > "$SYSPROMPT10"
_write_config "$CONF10" "anthropic" "standard" "claude-sonnet-4-6"
_create_mock_curl_body "$MOCK10" "$BODY10" \
    '{"content":[{"text":"{\"scores\":{},\"findings\":[],\"summary\":\"ok\"}"}],"stop_reason":"end_turn"}'

ci_suffix_output=""
ci_suffix_exit=0
ci_suffix_output=$(
    export PATH="$MOCK10:$PATH"
    unset OPENAI_API_KEY || true
    ANTHROPIC_API_KEY="test-key" bash "$SCRIPT" "$SYSPROMPT10" "review this" standard "$CONF10" 2>/dev/null
) || ci_suffix_exit=$?

# The captured request body must contain the CI-mode constraint phrase
if [[ -f "$BODY10" ]]; then
    if python3 -c "import json,sys; d=json.load(open('$BODY10')); assert 'CI-PIPELINE CONSTRAINT' in d['system'], 'suffix missing'" 2>/dev/null; then
        assert_eq "test_ci_mode_suffix_appended_to_system_prompt: CI-PIPELINE CONSTRAINT present in system" \
            "PRESENT" "PRESENT"
    else
        assert_eq "test_ci_mode_suffix_appended_to_system_prompt: CI-PIPELINE CONSTRAINT present in system" \
            "PRESENT" "ABSENT"
    fi
else
    assert_eq "test_ci_mode_suffix_appended_to_system_prompt: request body captured" \
        "CAPTURED" "MISSING"
fi
assert_pass_if_clean "test_ci_mode_suffix_appended_to_system_prompt"

# ── test_ci_context_marker_present_when_github_actions_set ───────────────────
# Given: model.provider=anthropic, ANTHROPIC_API_KEY set, GITHUB_ACTIONS=true
# When:  llm-api-call.sh is invoked
# Then:  captured request body messages[0].content starts with "REVIEW_CONTEXT: ci\n"
_snapshot_fail
MOCK11=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK11")
CONF11="$MOCK11/config.conf"
SYSPROMPT11="$MOCK11/system-prompt.md"
BODY11="$MOCK11/request-body.json"
printf 'You are a reviewer.\n' > "$SYSPROMPT11"
_write_config "$CONF11" "anthropic" "standard" "claude-sonnet-4-6"
_create_mock_curl_body "$MOCK11" "$BODY11" \
    '{"content":[{"text":"{\"scores\":{},\"findings\":[],\"summary\":\"ok\"}"}],"stop_reason":"end_turn"}'

ci_marker_present_exit=0
(
    export PATH="$MOCK11:$PATH"
    unset OPENAI_API_KEY || true
    ANTHROPIC_API_KEY="test-key" GITHUB_ACTIONS="true" \
        bash "$SCRIPT" "$SYSPROMPT11" "review this diff" standard "$CONF11"
) > /dev/null 2>&1 || ci_marker_present_exit=$?

if [[ -f "$BODY11" ]]; then
    ci_marker_check_out=""
    ci_marker_check_exit=0
    ci_marker_check_out=$(python3 -c "
import json, sys
with open('$BODY11') as f:
    d = json.load(f)
msgs = d.get('messages', [])
if not msgs:
    print('NO_MESSAGES')
    sys.exit(1)
content = msgs[0].get('content', '')
if content.startswith('REVIEW_CONTEXT: ci\n'):
    print('OK')
else:
    print('MISSING: content starts with: ' + repr(content[:40]))
    sys.exit(1)
" 2>&1) || ci_marker_check_exit=$?
    assert_eq "test_ci_context_marker_present_when_github_actions_set: marker is first line" \
        "OK" "$ci_marker_check_out"
else
    assert_eq "test_ci_context_marker_present_when_github_actions_set: request body captured" \
        "CAPTURED" "MISSING"
fi
assert_pass_if_clean "test_ci_context_marker_present_when_github_actions_set"

# ── test_ci_context_marker_absent_when_github_actions_unset ──────────────────
# Given: model.provider=anthropic, ANTHROPIC_API_KEY set, GITHUB_ACTIONS unset
# When:  llm-api-call.sh is invoked
# Then:  captured request body messages[0].content does NOT contain "REVIEW_CONTEXT: ci"
_snapshot_fail
MOCK12=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK12")
CONF12="$MOCK12/config.conf"
SYSPROMPT12="$MOCK12/system-prompt.md"
BODY12="$MOCK12/request-body.json"
printf 'You are a reviewer.\n' > "$SYSPROMPT12"
_write_config "$CONF12" "anthropic" "standard" "claude-sonnet-4-6"
_create_mock_curl_body "$MOCK12" "$BODY12" \
    '{"content":[{"text":"{\"scores\":{},\"findings\":[],\"summary\":\"ok\"}"}],"stop_reason":"end_turn"}'

ci_marker_absent_exit=0
(
    export PATH="$MOCK12:$PATH"
    unset OPENAI_API_KEY || true
    unset GITHUB_ACTIONS || true
    ANTHROPIC_API_KEY="test-key" \
        bash "$SCRIPT" "$SYSPROMPT12" "review this diff" standard "$CONF12"
) > /dev/null 2>&1 || ci_marker_absent_exit=$?

if [[ -f "$BODY12" ]]; then
    ci_absent_check_out=""
    ci_absent_check_exit=0
    ci_absent_check_out=$(python3 -c "
import json, sys
with open('$BODY12') as f:
    d = json.load(f)
msgs = d.get('messages', [])
if not msgs:
    print('NO_MESSAGES')
    sys.exit(1)
content = msgs[0].get('content', '')
if 'REVIEW_CONTEXT: ci' in content:
    print('PRESENT_UNEXPECTEDLY: ' + repr(content[:60]))
    sys.exit(1)
print('OK')
" 2>&1) || ci_absent_check_exit=$?
    assert_eq "test_ci_context_marker_absent_when_github_actions_unset: marker absent" \
        "OK" "$ci_absent_check_out"
else
    assert_eq "test_ci_context_marker_absent_when_github_actions_unset: request body captured" \
        "CAPTURED" "MISSING"
fi
assert_pass_if_clean "test_ci_context_marker_absent_when_github_actions_unset"

# ── test_api_key_not_exposed_in_curl_args ────────────────────────────────────
# RED marker — test_api_key_not_exposed_in_curl_args
# Must FAIL before llm-api-call.sh uses --config for headers.
# Given: model.provider=anthropic, ANTHROPIC_API_KEY=test-secret-key
# When:  llm-api-call.sh is invoked
# Then:  captured curl CLI args do NOT contain the API key value
#        (key is passed via --config file, not -H flag, so not visible in cmdline)
_snapshot_fail
MOCK_SEC=$(mktemp -d)
_TEST_TMPDIRS+=("$MOCK_SEC")
ARGS_SEC="$MOCK_SEC/curl-args.txt"
CONF_SEC="$MOCK_SEC/config.conf"
SYSPROMPT_SEC="$MOCK_SEC/system-prompt.md"
printf 'You are a reviewer.\n' > "$SYSPROMPT_SEC"
_write_config "$CONF_SEC" "anthropic" "standard" "claude-sonnet-4-6"
_create_mock_curl_args "$MOCK_SEC" "$ARGS_SEC" \
    '{"content":[{"text":"{\"result\":\"ok\"}"}],"stop_reason":"end_turn"}'

sec_exit=0
(
    export PATH="$MOCK_SEC:$PATH"
    unset OPENAI_API_KEY || true
    ANTHROPIC_API_KEY="test-secret-key" bash "$SCRIPT" "$SYSPROMPT_SEC" "review this" standard "$CONF_SEC"
) > /dev/null 2>&1 || sec_exit=$?

args_sec_content=""
[[ -f "$ARGS_SEC" ]] && args_sec_content="$(cat "$ARGS_SEC")"

if echo "$args_sec_content" | grep -q "test-secret-key"; then
    assert_eq "test_api_key_not_exposed_in_curl_args: API key must NOT be in curl cmdline" \
        "NOT_PRESENT" "PRESENT_IN_ARGS"
else
    assert_eq "test_api_key_not_exposed_in_curl_args: API key must NOT be in curl cmdline" \
        "NOT_PRESENT" "NOT_PRESENT"
fi
assert_pass_if_clean "test_api_key_not_exposed_in_curl_args"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
