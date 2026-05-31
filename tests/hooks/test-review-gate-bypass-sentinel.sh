#!/usr/bin/env bash
# tests/hooks/test-review-gate-bypass-sentinel.sh
# Tests for the review-gate bypass sentinel hook function.
#
# The bypass sentinel detects commands that attempt to circumvent the review gate
# (e.g., --no-verify, core.hooksPath override, git plumbing commands).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"

# Set enforcement strategy to local for test isolation.
# Without this, enforcement-gate.sh reads the real dso-config.conf at source time.
# When enforcement.strategy=ci (as in this repo after the 8e5f story), hook_review_bypass_sentinel()
# returns 0 immediately, breaking all block tests. Tests that check ci behavior use
# call_sentinel_with_config() which manages WORKFLOW_CONFIG_FILE independently.
_TEST_ISOLATION_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sentinel-test-isolation.XXXXXX")
printf 'enforcement.strategy=local\n' > "$_TEST_ISOLATION_DIR/dso-config.conf"
WORKFLOW_CONFIG_FILE="$_TEST_ISOLATION_DIR/dso-config.conf"
trap 'rm -rf "$_TEST_ISOLATION_DIR"' EXIT

source "$DSO_PLUGIN_DIR/hooks/lib/review-gate-bypass-sentinel.sh"

# call_sentinel: invoke hook_review_bypass_sentinel() directly (no subprocess).
# Returns the exit code on stdout.
call_sentinel() {
    local input="$1"
    local exit_code=0
    hook_review_bypass_sentinel "$input" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# ============================================================
# Block tests (should return exit 2)
# ============================================================

# test_sentinel_blocks_no_verify
INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit --no-verify -m msg"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_sentinel_blocks_no_verify" "2" "$EXIT_CODE"

# test_sentinel_blocks_short_n_flag
INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -n -m msg"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_sentinel_blocks_short_n_flag" "2" "$EXIT_CODE"

# test_sentinel_blocks_n_flag_at_end_of_command
INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -m msg -n"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_sentinel_blocks_n_flag_at_end_of_command" "2" "$EXIT_CODE"

# test_sentinel_blocks_hooks_path_override
INPUT='{"tool_name":"Bash","tool_input":{"command":"git -c core.hooksPath=/dev/null commit -m msg"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_sentinel_blocks_hooks_path_override" "2" "$EXIT_CODE"

# test_sentinel_blocks_commit_tree
INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit-tree abc123 -m msg"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_sentinel_blocks_commit_tree" "2" "$EXIT_CODE"

# test_sentinel_blocks_update_ref
INPUT='{"tool_name":"Bash","tool_input":{"command":"git update-ref refs/heads/main abc123"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_sentinel_blocks_update_ref" "2" "$EXIT_CODE"

# test_sentinel_blocks_git_hooks_write
INPUT='{"tool_name":"Bash","tool_input":{"command":"echo bypass > .git/hooks/pre-commit"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_sentinel_blocks_git_hooks_write" "2" "$EXIT_CODE"

# test_sentinel_blocks_no_verify_in_and_chain
INPUT='{"tool_name":"Bash","tool_input":{"command":"make test && git commit --no-verify -m msg"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_sentinel_blocks_no_verify_in_and_chain" "2" "$EXIT_CODE"

# test_sentinel_blocks_hooks_path_in_semicolon_chain
INPUT='{"tool_name":"Bash","tool_input":{"command":"cd app; git -c core.hooksPath=/tmp commit -m msg"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_sentinel_blocks_hooks_path_in_semicolon_chain" "2" "$EXIT_CODE"

# test_sentinel_blocks_no_verify_in_subshell
INPUT='{"tool_name":"Bash","tool_input":{"command":"(git commit -n -m msg)"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_sentinel_blocks_no_verify_in_subshell" "2" "$EXIT_CODE"

# ============================================================
# Allow tests (should return exit 0)
# ============================================================

# test_sentinel_allows_normal_git_commit
INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -m normal commit"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_sentinel_allows_normal_git_commit" "0" "$EXIT_CODE"

# test_sentinel_allows_non_commit_bash
INPUT='{"tool_name":"Bash","tool_input":{"command":"echo hello"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_sentinel_allows_non_commit_bash" "0" "$EXIT_CODE"

# test_sentinel_allows_non_bash_tool
INPUT='{"tool_name":"Read","tool_input":{"file_path":"/tmp/test.py"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_sentinel_allows_non_bash_tool" "0" "$EXIT_CODE"

# test_sentinel_allows_update_ref_in_merge_script
INPUT='{"tool_name":"Bash","tool_input":{"command":"scripts/merge-to-main.sh --branch feature"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_sentinel_allows_update_ref_in_merge_script" "0" "$EXIT_CODE"

# test_sentinel_allows_git_hooks_read
INPUT='{"tool_name":"Bash","tool_input":{"command":"cat .git/hooks/pre-commit"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_sentinel_allows_git_hooks_read" "0" "$EXIT_CODE"

# test_sentinel_allows_wip_commit
INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -m WIP: save progress"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_sentinel_allows_wip_commit" "0" "$EXIT_CODE"

# test_sentinel_blocks_no_verify_with_wip_substring (e.g., "wiper" is not WIP)
INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit --no-verify -m \"fix wiper module\""}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_sentinel_blocks_no_verify_with_wip_substring" "2" "$EXIT_CODE"

# test_sentinel_allows_wip_with_colon (common format: "WIP:")
INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit --no-verify -m \"WIP: checkpoint\""}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_sentinel_allows_wip_with_colon" "0" "$EXIT_CODE"

# test_sentinel_allows_lowercase_wip
INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit --no-verify -m \"wip save\""}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_sentinel_allows_lowercase_wip" "0" "$EXIT_CODE"

# ============================================================
# Pattern g/h: test-gate-status bypass protection
# ============================================================

# call_sentinel_with_stderr: like call_sentinel but also captures stderr.
# Returns "exit_code|stderr_text" on stdout.
call_sentinel_with_stderr() {
    local input="$1"
    local exit_code=0
    local stderr_output
    stderr_output=$(hook_review_bypass_sentinel "$input" 2>&1 1>/dev/null) || exit_code=$?
    echo "${exit_code}|${stderr_output}"
}

# test_test_gate_status_direct_write_blocked
# A command writing to test-gate-status must be blocked (Pattern g).
INPUT='{"tool_name":"Bash","tool_input":{"command":"echo passed > /tmp/workflow-plugin-xxx/test-gate-status"}}'
RESULT=$(call_sentinel_with_stderr "$INPUT")
EXIT_CODE="${RESULT%%|*}"
STDERR="${RESULT#*|}"
assert_eq "test_test_gate_status_direct_write_blocked" "2" "$EXIT_CODE"
assert_contains "test_test_gate_status_direct_write_blocked_msg_status" "test-gate-status" "$STDERR"
assert_contains "test_test_gate_status_direct_write_blocked_msg_script" "record-test-status.sh" "$STDERR"

# test_test_gate_status_rm_blocked
# A command deleting test-gate-status must be blocked (Pattern h).
INPUT='{"tool_name":"Bash","tool_input":{"command":"rm /tmp/workflow-plugin-xxx/test-gate-status"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_test_gate_status_rm_blocked" "2" "$EXIT_CODE"

# test_record_test_status_sh_not_blocked
# A command calling record-test-status.sh must NOT be blocked.
INPUT='{"tool_name":"Bash","tool_input":{"command":"bash plugins/dso/hooks/record-test-status.sh"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_record_test_status_sh_not_blocked" "0" "$EXIT_CODE"

# test_test_gate_status_read_not_blocked
# A read-only command on test-gate-status must NOT be blocked.
INPUT='{"tool_name":"Bash","tool_input":{"command":"cat /tmp/workflow-plugin-xxx/test-gate-status"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_test_gate_status_read_not_blocked" "0" "$EXIT_CODE"

# ============================================================
# Pattern i: test-exemptions bypass protection
# ============================================================

# test_test_exemptions_direct_write_blocked
# A command writing to test-exemptions must be blocked.
INPUT='{"tool_name":"Bash","tool_input":{"command":"echo node_id > /tmp/workflow-plugin-xxx/test-exemptions"}}'
RESULT=$(call_sentinel_with_stderr "$INPUT")
EXIT_CODE="${RESULT%%|*}"
STDERR="${RESULT#*|}"
assert_eq "test_test_exemptions_direct_write_blocked" "2" "$EXIT_CODE"
assert_contains "test_test_exemptions_direct_write_blocked_msg" "test-exemption" "$STDERR"

# test_test_exemptions_rm_blocked
# A command deleting test-exemptions must be blocked.
INPUT='{"tool_name":"Bash","tool_input":{"command":"rm /tmp/workflow-plugin-xxx/test-exemptions"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_test_exemptions_rm_blocked" "2" "$EXIT_CODE"

# test_test_exemptions_tee_blocked
# A tee command writing to test-exemptions must be blocked.
INPUT='{"tool_name":"Bash","tool_input":{"command":"printf \"node_id\ttest::slow\n\" | tee /tmp/workflow-plugin-xxx/test-exemptions"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_test_exemptions_tee_blocked" "2" "$EXIT_CODE"

# test_record_test_exemption_sh_not_blocked
# A command calling record-test-exemption.sh must NOT be blocked.
INPUT='{"tool_name":"Bash","tool_input":{"command":"bash plugins/dso/hooks/record-test-exemption.sh tests/unit/test_foo.py::test_slow"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_record_test_exemption_sh_not_blocked" "0" "$EXIT_CODE"

# test_test_exemptions_read_not_blocked
# A read-only command on test-exemptions must NOT be blocked.
INPUT='{"tool_name":"Bash","tool_input":{"command":"cat /tmp/workflow-plugin-xxx/test-exemptions"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_test_exemptions_read_not_blocked" "0" "$EXIT_CODE"

# ── Pattern k: .tickets-tracker/ protection ──────────────────────────────────

# test_tickets_tracker_direct_rm_blocked
# A rm command targeting .tickets-tracker/ must be blocked.
INPUT='{"tool_name":"Bash","tool_input":{"command":"rm -f /path/to/repo/.tickets-tracker/abc123/1234-CREATE.json"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_tickets_tracker_direct_rm_blocked" "2" "$EXIT_CODE"

# test_tickets_tracker_index_lock_rm_blocked
# Deleting the git worktree index.lock must be blocked.
INPUT='{"tool_name":"Bash","tool_input":{"command":"rm -f /path/to/repo/.git/worktrees/-tickets-tracker/index.lock"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_tickets_tracker_index_lock_rm_blocked" "2" "$EXIT_CODE"

# test_tickets_tracker_redirect_write_blocked
# A redirect write into .tickets-tracker/ must be blocked.
INPUT='{"tool_name":"Bash","tool_input":{"command":"echo event_data > /path/to/repo/.tickets-tracker/abc123/fake-CREATE.json"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_tickets_tracker_redirect_write_blocked" "2" "$EXIT_CODE"

# test_tickets_tracker_ticket_create_sh_not_blocked
# Commands running ticket-create.sh are authorized writers.
INPUT='{"tool_name":"Bash","tool_input":{"command":"bash plugins/dso/scripts/ticket-create.sh bug \"title\" && cat .tickets-tracker/abc/123-CREATE.json"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_tickets_tracker_ticket_create_sh_not_blocked" "0" "$EXIT_CODE"

# test_tickets_tracker_ticket_graph_py_not_blocked
# Commands running ticket-graph.py are authorized writers.
INPUT='{"tool_name":"Bash","tool_input":{"command":"python3 plugins/dso/scripts/ticket-graph.py --link abc def relates_to && cat .tickets-tracker/abc/123-LINK.json"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_tickets_tracker_ticket_graph_py_not_blocked" "0" "$EXIT_CODE"

# test_tickets_tracker_read_not_blocked
# Read-only commands on .tickets-tracker/ must NOT be blocked.
INPUT='{"tool_name":"Bash","tool_input":{"command":"cat .tickets-tracker/abc123/1234-CREATE.json"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_tickets_tracker_read_not_blocked" "0" "$EXIT_CODE"

# test_tickets_tracker_find_not_blocked
# find commands for .tickets-tracker/ must NOT be blocked.
INPUT='{"tool_name":"Bash","tool_input":{"command":"find .tickets-tracker/ -name \"*-CREATE.json\""}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_tickets_tracker_find_not_blocked" "0" "$EXIT_CODE"

# ============================================================
# Pattern g extension: python3/scripting interpreter write to test-gate-status (4600-02a3)
# ============================================================

# test_python3_open_write_to_test_gate_status_blocked
# A python3 command using open().write() to test-gate-status must be blocked.
INPUT='{"tool_name":"Bash","tool_input":{"command":"python3 -c \"open(\"/tmp/workflow-plugin-xxx/test-gate-status\", \"w\").write(\"passed\\n\")\""}}'
RESULT=$(call_sentinel_with_stderr "$INPUT")
EXIT_CODE="${RESULT%%|*}"
STDERR="${RESULT#*|}"
assert_eq "test_python3_open_write_to_test_gate_status_blocked" "2" "$EXIT_CODE"
assert_contains "test_python3_open_write_to_test_gate_status_blocked_msg" "test-gate-status" "$STDERR"

# test_python3_with_record_test_status_not_blocked
# A python3 command that also invokes record-test-status.sh must NOT be blocked.
INPUT='{"tool_name":"Bash","tool_input":{"command":"python3 something.py && bash record-test-status.sh --source-file test-gate-status"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_python3_with_record_test_status_not_blocked" "0" "$EXIT_CODE"

# ============================================================
# False positive fix (63a6-50e8): quoted description strings must not trigger patterns
# ============================================================

# test_ticket_create_desc_no_verify_not_blocked
# ticket create with --no-verify in a quoted description must NOT be blocked.
# The description is JSON-encoded so quotes appear as \" in the command field.
INPUT='{"tool_name":"Bash","tool_input":{"command":".claude/scripts/dso ticket create bug \"--no-verify bypass risk\" --description \"--no-verify flag\""}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_ticket_create_desc_no_verify_not_blocked" "0" "$EXIT_CODE"

# test_ticket_create_desc_test_gate_status_not_blocked
# ticket create with test-gate-status in a quoted description must NOT be blocked.
INPUT='{"tool_name":"Bash","tool_input":{"command":".claude/scripts/dso ticket create bug \"test-gate-status file issue\" --description \"writes to test-gate-status dir\""}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_ticket_create_desc_test_gate_status_not_blocked" "0" "$EXIT_CODE"

# test_ticket_create_desc_core_hookspath_not_blocked
# ticket create with core.hooksPath= in a quoted description must NOT be blocked.
INPUT='{"tool_name":"Bash","tool_input":{"command":".claude/scripts/dso ticket create bug \"core.hooksPath= override\" --description \"attacker sets core.hooksPath=/dev/null\""}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_ticket_create_desc_core_hookspath_not_blocked" "0" "$EXIT_CODE"

# test_ticket_create_desc_tickets_tracker_not_blocked
# ticket create with .tickets-tracker/ in a quoted description must NOT be blocked.
INPUT='{"tool_name":"Bash","tool_input":{"command":".claude/scripts/dso ticket create bug \"bad write to .tickets-tracker/\" --description \"script writes directly to .tickets-tracker/\""}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_ticket_create_desc_tickets_tracker_not_blocked" "0" "$EXIT_CODE"

# test_no_verify_outside_quotes_still_blocked
# --no-verify outside quotes (real bypass attempt) must still be BLOCKED even when
# the command also has a quoted description containing innocuous text.
INPUT='{"tool_name":"Bash","tool_input":{"command":".claude/scripts/dso ticket create bug \"some title\" && git commit --no-verify -m msg"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_no_verify_outside_quotes_still_blocked" "2" "$EXIT_CODE"

# ============================================================
# enforcement.strategy=ci bypass (RED tests — require implementation)
# ============================================================

# call_sentinel_with_config: invoke hook_review_bypass_sentinel in a subprocess with
# a custom WORKFLOW_CONFIG_FILE. Returns the exit code on stdout.
# Uses a subprocess so WORKFLOW_CONFIG_FILE is picked up by enforcement-gate.sh at
# source time (the in-process call_sentinel() helper cannot isolate env-var reads).
call_sentinel_with_config() {
    local input="$1" config_file="$2"
    local exit_code=0
    # INPUT_JSON is set as a prefix env var so the bash -c subprocess inherits it.
    # \$INPUT_JSON (backslash-escaped dollar) in the bash -c body defers expansion
    # to the subprocess context — the outer shell sees a literal '$' and does NOT
    # expand INPUT_JSON at bash -c string construction time.  Inside the subprocess,
    # "$INPUT_JSON" is then expanded from the inherited environment, preserving
    # the full JSON value including any spaces or special characters. This is the
    # correct pattern for passing structured data into a bash -c subshell.
    INPUT_JSON="$input" WORKFLOW_CONFIG_FILE="$config_file" bash -c "
        REPO_ROOT=\"\$(git rev-parse --show-toplevel)\"
        source \"\$REPO_ROOT/plugins/dso/hooks/lib/deps.sh\"
        source \"\$REPO_ROOT/plugins/dso/hooks/lib/review-gate-bypass-sentinel.sh\"
        hook_review_bypass_sentinel \"\$INPUT_JSON\"
    " 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# call_sentinel_with_config_stderr: like call_sentinel_with_config but also captures stderr.
# Returns "exit_code|stderr_text" on stdout.
call_sentinel_with_config_stderr() {
    local input="$1" config_file="$2"
    local exit_code=0
    local stderr_output
    # Same \$INPUT_JSON deferral pattern as call_sentinel_with_config above.
    # INPUT_JSON is exported to the subprocess; \$INPUT_JSON in the body defers
    # expansion so the subprocess reads the full JSON from its environment.
    stderr_output=$(INPUT_JSON="$input" WORKFLOW_CONFIG_FILE="$config_file" bash -c "
        REPO_ROOT=\"\$(git rev-parse --show-toplevel)\"
        source \"\$REPO_ROOT/plugins/dso/hooks/lib/deps.sh\"
        source \"\$REPO_ROOT/plugins/dso/hooks/lib/review-gate-bypass-sentinel.sh\"
        hook_review_bypass_sentinel \"\$INPUT_JSON\"
    " 2>&1 1>/dev/null) || exit_code=$?
    echo "${exit_code}|${stderr_output}"
}

# test_sentinel_allows_noverify_under_ci_strategy
# When dso.workflow=ci-pr, hook_review_bypass_sentinel should return 0 (allow)
# even for --no-verify commands — the CI enforcement strategy short-circuits before
# pattern matching.
_CI_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/sentinel-ci-test.XXXXXX")
mkdir -p "$_CI_TMPDIR/.claude"
printf 'dso.workflow=ci-pr\n' > "$_CI_TMPDIR/.claude/dso-config.conf"
INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit --no-verify -m msg"}}'
EXIT_CODE=$(call_sentinel_with_config "$INPUT" "$_CI_TMPDIR/.claude/dso-config.conf")
assert_eq "test_sentinel_allows_noverify_under_ci_strategy" "0" "$EXIT_CODE"
rm -rf "$_CI_TMPDIR"

# test_sentinel_emits_hook_gate_skipped_under_ci_strategy
# When dso.workflow=ci-pr, stderr must contain the canonical HOOK_GATE message.
_CI_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/sentinel-ci-test.XXXXXX")
mkdir -p "$_CI_TMPDIR/.claude"
printf 'dso.workflow=ci-pr\n' > "$_CI_TMPDIR/.claude/dso-config.conf"
INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit --no-verify -m msg"}}'
RESULT=$(call_sentinel_with_config_stderr "$INPUT" "$_CI_TMPDIR/.claude/dso-config.conf")
EXIT_CODE_CI="${RESULT%%|*}"
STDERR_CI="${RESULT#*|}"
assert_contains "test_sentinel_emits_hook_gate_skipped_under_ci_strategy" "HOOK_GATE: skipped reason=dso.workflow=ci-pr" "$STDERR_CI"
rm -rf "$_CI_TMPDIR"

# test_sentinel_blocks_noverify_under_local_strategy
# Regression test: dso.workflow=local must still block --no-verify (return 2).
# GREEN: existing behavior — verifies the ci-pr path doesn't accidentally affect local.
_LOCAL_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/sentinel-ci-test.XXXXXX")
mkdir -p "$_LOCAL_TMPDIR/.claude"
printf 'dso.workflow=local\n' > "$_LOCAL_TMPDIR/.claude/dso-config.conf"
INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit --no-verify -m msg"}}'
EXIT_CODE=$(call_sentinel_with_config "$INPUT" "$_LOCAL_TMPDIR/.claude/dso-config.conf")
assert_eq "test_sentinel_blocks_noverify_under_local_strategy" "2" "$EXIT_CODE"
rm -rf "$_LOCAL_TMPDIR"


# ============================================================
# Item 1: fail-closed on unparsable command (was allow-on-empty)
# ============================================================
# Under local enforcement a Bash call whose command cannot be parsed must NOT be
# waved through unchecked — that would skip every bypass pattern. The sentinel
# recovers via json.loads when the pure-bash parser returns empty, and blocks
# only when the command is genuinely unparsable/absent.

# test_sentinel_blocks_bash_call_with_no_command (fail-closed)
INPUT='{"tool_name":"Bash","tool_input":{}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_sentinel_blocks_bash_call_with_no_command" "2" "$EXIT_CODE"

# test_sentinel_blocks_bash_call_with_empty_command (fail-closed)
INPUT='{"tool_name":"Bash","tool_input":{"command":""}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_sentinel_blocks_bash_call_with_empty_command" "2" "$EXIT_CODE"

# test_sentinel_recovers_and_blocks_bypass_when_bash_parser_fails
# The leading "x":"}" value breaks the pure-bash object parser's brace counting
# so parse_json_field returns empty; json.loads must recover the real command
# and the --no-verify bypass must still be BLOCKED (closes the unparsed-skip hole).
INPUT='{"tool_name":"Bash","tool_input":{"x":"}","command":"git commit --no-verify -m x"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_sentinel_recovers_and_blocks_bypass_when_bash_parser_fails" "2" "$EXIT_CODE"

# test_sentinel_recovers_and_allows_benign_when_bash_parser_fails
# Same parser-defeating shape, but a benign command — recovery must NOT cause a
# false denial (no bypass pattern -> allow).
INPUT='{"tool_name":"Bash","tool_input":{"x":"}","command":"echo hello"}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_sentinel_recovers_and_allows_benign_when_bash_parser_fails" "0" "$EXIT_CODE"

# test_sentinel_allows_non_bash_with_no_command (regression: only Bash fail-closes)
INPUT='{"tool_name":"Read","tool_input":{}}'
EXIT_CODE=$(call_sentinel "$INPUT")
assert_eq "test_sentinel_allows_non_bash_with_no_command" "0" "$EXIT_CODE"

print_summary
