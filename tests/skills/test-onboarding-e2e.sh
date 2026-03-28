#!/usr/bin/env bash
# tests/skills/test-onboarding-e2e.sh
# Integration test: verifies onboarding SKILL.md output completeness.
#
# This is a structural validation test — it validates SKILL.md content, not
# runtime behavior (Behavioral Test Requirement exemption).
#
# Assertions (groups a–f):
#   a. dso-config.conf key references — all 8 required keys mentioned
#   b. Hook installation references — pre-commit-test-gate, pre-commit-review-gate, Husky, .git/hooks
#   c. Ticket system init references — orphan, tickets-tracker, smoke test
#   d. CLAUDE.md generation references — ticket commands
#   e. Artifact review references — review before write, diff existing
#   f. Regression — all 42 structural assertions from test-onboarding-skill.sh still pass
#
# Usage: bash tests/skills/test-onboarding-e2e.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
SKILL_MD="$DSO_PLUGIN_DIR/skills/onboarding/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-onboarding-e2e.sh ==="

# ── Group a: dso-config.conf key references ───────────────────────────────────
# All 8 required config keys must be mentioned in SKILL.md

# test_config_key_dso_plugin_root: dso.plugin_root must be referenced
test_config_key_dso_plugin_root() {
    _snapshot_fail
    local found="missing"
    grep -qF "dso.plugin_root" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_config_key_dso_plugin_root" "found" "$found"
    assert_pass_if_clean "test_config_key_dso_plugin_root"
}

# test_config_key_format_extensions: format.extensions must be referenced
test_config_key_format_extensions() {
    _snapshot_fail
    local found="missing"
    grep -qF "format.extensions" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_config_key_format_extensions" "found" "$found"
    assert_pass_if_clean "test_config_key_format_extensions"
}

# test_config_key_format_source_dirs: format.source_dirs must be referenced
test_config_key_format_source_dirs() {
    _snapshot_fail
    local found="missing"
    grep -qF "format.source_dirs" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_config_key_format_source_dirs" "found" "$found"
    assert_pass_if_clean "test_config_key_format_source_dirs"
}

# test_config_key_test_gate_test_dirs: test_gate.test_dirs must be referenced
test_config_key_test_gate_test_dirs() {
    _snapshot_fail
    local found="missing"
    grep -qF "test_gate.test_dirs" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_config_key_test_gate_test_dirs" "found" "$found"
    assert_pass_if_clean "test_config_key_test_gate_test_dirs"
}

# test_config_key_commands_validate: commands.validate must be referenced
test_config_key_commands_validate() {
    _snapshot_fail
    local found="missing"
    grep -qF "commands.validate" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_config_key_commands_validate" "found" "$found"
    assert_pass_if_clean "test_config_key_commands_validate"
}

# test_config_key_tickets_directory: tickets.directory must be referenced
test_config_key_tickets_directory() {
    _snapshot_fail
    local found="missing"
    grep -qF "tickets.directory" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_config_key_tickets_directory" "found" "$found"
    assert_pass_if_clean "test_config_key_tickets_directory"
}

# test_config_key_checkpoint_marker_file: checkpoint.marker_file must be referenced
test_config_key_checkpoint_marker_file() {
    _snapshot_fail
    local found="missing"
    grep -qF "checkpoint.marker_file" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_config_key_checkpoint_marker_file" "found" "$found"
    assert_pass_if_clean "test_config_key_checkpoint_marker_file"
}

# test_config_key_review_behavioral_patterns: review.behavioral_patterns must be referenced
test_config_key_review_behavioral_patterns() {
    _snapshot_fail
    local found="missing"
    grep -qF "review.behavioral_patterns" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_config_key_review_behavioral_patterns" "found" "$found"
    assert_pass_if_clean "test_config_key_review_behavioral_patterns"
}

# test_all_8_config_keys_present: all 8 required config keys found (summary assertion)
test_all_8_config_keys_present() {
    _snapshot_fail
    local keys_found=0 keys_missing=""
    local required_keys=(
        "dso.plugin_root"
        "format.extensions"
        "format.source_dirs"
        "test_gate.test_dirs"
        "commands.validate"
        "tickets.directory"
        "checkpoint.marker_file"
        "review.behavioral_patterns"
    )
    for key in "${required_keys[@]}"; do
        if grep -qF "$key" "$SKILL_MD" 2>/dev/null; then
            (( keys_found++ ))
        else
            keys_missing="$keys_missing $key"
        fi
    done
    if [[ "$keys_found" -eq 8 ]]; then
        assert_eq "test_all_8_config_keys_present" "8" "$keys_found"
    else
        assert_eq "test_all_8_config_keys_present" "8 config keys" "$keys_found keys found (missing:$keys_missing)"
    fi
    assert_pass_if_clean "test_all_8_config_keys_present"
}

# ── Group b: Hook installation references ─────────────────────────────────────

# test_hook_ref_pre_commit_test_gate: pre-commit-test-gate must be mentioned
test_hook_ref_pre_commit_test_gate() {
    _snapshot_fail
    local found="missing"
    grep -q "pre-commit-test-gate" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_hook_ref_pre_commit_test_gate" "found" "$found"
    assert_pass_if_clean "test_hook_ref_pre_commit_test_gate"
}

# test_hook_ref_pre_commit_review_gate: pre-commit-review-gate must be mentioned
test_hook_ref_pre_commit_review_gate() {
    _snapshot_fail
    local found="missing"
    grep -q "pre-commit-review-gate" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_hook_ref_pre_commit_review_gate" "found" "$found"
    assert_pass_if_clean "test_hook_ref_pre_commit_review_gate"
}

# test_hook_ref_husky: Husky hook manager must be mentioned
test_hook_ref_husky() {
    _snapshot_fail
    local found="missing"
    grep -q "Husky" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_hook_ref_husky" "found" "$found"
    assert_pass_if_clean "test_hook_ref_husky"
}

# test_hook_ref_git_hooks_dir: .git/hooks directory installation must be mentioned
test_hook_ref_git_hooks_dir() {
    _snapshot_fail
    local found="missing"
    grep -qE "\.git/hooks" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_hook_ref_git_hooks_dir" "found" "$found"
    assert_pass_if_clean "test_hook_ref_git_hooks_dir"
}

# test_hook_idempotency: hook installation must mention idempotency (no duplicates on re-run)
test_hook_idempotency() {
    _snapshot_fail
    local found="missing"
    grep -qiE "idempoten|grep.*before.*append|check.*before.*append" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_hook_idempotency" "found" "$found"
    assert_pass_if_clean "test_hook_idempotency"
}

# test_hook_all_refs_present: summary — all 4 hook refs present together
test_hook_all_refs_present() {
    _snapshot_fail
    local test_gate review_gate husky git_hooks result
    test_gate="no"; review_gate="no"; husky="no"; git_hooks="no"
    grep -q "pre-commit-test-gate"    "$SKILL_MD" 2>/dev/null && test_gate="yes"
    grep -q "pre-commit-review-gate"  "$SKILL_MD" 2>/dev/null && review_gate="yes"
    grep -q "Husky"                   "$SKILL_MD" 2>/dev/null && husky="yes"
    grep -qE "\.git/hooks"            "$SKILL_MD" 2>/dev/null && git_hooks="yes"
    if [[ "$test_gate:$review_gate:$husky:$git_hooks" == "yes:yes:yes:yes" ]]; then
        result="found"
    else
        result="missing (test_gate=$test_gate review_gate=$review_gate husky=$husky git_hooks=$git_hooks)"
    fi
    assert_eq "test_hook_all_refs_present" "found" "$result"
    assert_pass_if_clean "test_hook_all_refs_present"
}

# ── Group c: Ticket system init references ────────────────────────────────────

# test_ticket_init_orphan_branch: must mention orphan branch creation
test_ticket_init_orphan_branch() {
    _snapshot_fail
    local found="missing"
    grep -q "orphan" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_ticket_init_orphan_branch" "found" "$found"
    assert_pass_if_clean "test_ticket_init_orphan_branch"
}

# test_ticket_init_tickets_tracker: must reference .tickets-tracker/ directory
test_ticket_init_tickets_tracker() {
    _snapshot_fail
    local found="missing"
    grep -q "tickets-tracker" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_ticket_init_tickets_tracker" "found" "$found"
    assert_pass_if_clean "test_ticket_init_tickets_tracker"
}

# test_ticket_init_smoke_test: must instruct a ticket smoke test after init
test_ticket_init_smoke_test() {
    _snapshot_fail
    local found="missing"
    grep -qiE "smoke.*test|create.*read.*ticket" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_ticket_init_smoke_test" "found" "$found"
    assert_pass_if_clean "test_ticket_init_smoke_test"
}

# test_ticket_init_push_verification: must verify push success after init
test_ticket_init_push_verification() {
    _snapshot_fail
    local found="missing"
    grep -qiE "push.*verif|push.*fail|push.*warn" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_ticket_init_push_verification" "found" "$found"
    assert_pass_if_clean "test_ticket_init_push_verification"
}

# test_ticket_init_all_refs_present: summary — orphan + tickets-tracker + smoke test all present
test_ticket_init_all_refs_present() {
    _snapshot_fail
    local orphan tickets_tracker smoke result
    orphan="no"; tickets_tracker="no"; smoke="no"
    grep -q "orphan"         "$SKILL_MD" 2>/dev/null && orphan="yes"
    grep -q "tickets-tracker" "$SKILL_MD" 2>/dev/null && tickets_tracker="yes"
    grep -qiE "smoke.*test"  "$SKILL_MD" 2>/dev/null && smoke="yes"
    if [[ "$orphan:$tickets_tracker:$smoke" == "yes:yes:yes" ]]; then
        result="found"
    else
        result="missing (orphan=$orphan tickets-tracker=$tickets_tracker smoke=$smoke)"
    fi
    assert_eq "test_ticket_init_all_refs_present" "found" "$result"
    assert_pass_if_clean "test_ticket_init_all_refs_present"
}

# ── Group d: CLAUDE.md generation references ──────────────────────────────────

# test_claude_md_ref: SKILL.md must mention generating CLAUDE.md
test_claude_md_ref() {
    _snapshot_fail
    local found="missing"
    grep -q "CLAUDE.md" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_claude_md_ref" "found" "$found"
    assert_pass_if_clean "test_claude_md_ref"
}

# test_claude_md_ticket_commands: CLAUDE.md generation must reference ticket commands
test_claude_md_ticket_commands() {
    _snapshot_fail
    local found="missing"
    grep -qiE "ticket.*command" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_claude_md_ticket_commands" "found" "$found"
    assert_pass_if_clean "test_claude_md_ticket_commands"
}

# test_claude_md_generate_skill: must reference /dso:generate-claude-md skill
test_claude_md_generate_skill() {
    _snapshot_fail
    local found="missing"
    grep -q "/dso:generate-claude-md" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_claude_md_generate_skill" "found" "$found"
    assert_pass_if_clean "test_claude_md_generate_skill"
}

# test_claude_md_host_project: must specify CLAUDE.md goes to HOST PROJECT root
test_claude_md_host_project() {
    _snapshot_fail
    local found="missing"
    grep -qiE "HOST PROJECT|host project" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_claude_md_host_project" "found" "$found"
    assert_pass_if_clean "test_claude_md_host_project"
}

# test_claude_md_quick_reference_table: must mention a Quick Reference table of ticket commands
test_claude_md_quick_reference_table() {
    _snapshot_fail
    local found="missing"
    grep -qiE "Quick Reference.*ticket|ticket.*Quick Reference" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_claude_md_quick_reference_table" "found" "$found"
    assert_pass_if_clean "test_claude_md_quick_reference_table"
}

# ── Group e: Artifact review references ───────────────────────────────────────

# test_artifact_review_before_write: must require user approval before writing files
test_artifact_review_before_write() {
    _snapshot_fail
    local found="missing"
    grep -qiE "review.*before.*writ|approval.*before.*writ|present.*artifact" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_artifact_review_before_write" "found" "$found"
    assert_pass_if_clean "test_artifact_review_before_write"
}

# test_artifact_fenced_code_block: must instruct presenting artifacts in fenced code blocks
test_artifact_fenced_code_block() {
    _snapshot_fail
    local found="missing"
    grep -qiE "fenced.*code|code.*block" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_artifact_fenced_code_block" "found" "$found"
    assert_pass_if_clean "test_artifact_fenced_code_block"
}

# test_artifact_diff_existing: must instruct showing diff against existing files before overwriting
test_artifact_diff_existing() {
    _snapshot_fail
    local found="missing"
    grep -qiE "diff.*existing|existing.*diff" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_artifact_diff_existing" "found" "$found"
    assert_pass_if_clean "test_artifact_diff_existing"
}

# test_artifact_no_write_without_approval: must explicitly forbid writing without approval
test_artifact_no_write_without_approval() {
    _snapshot_fail
    local found="missing"
    grep -qiE "NOT write.*without|Do NOT write|not.*write.*without.*approval" "$SKILL_MD" 2>/dev/null && found="found"
    assert_eq "test_artifact_no_write_without_approval" "found" "$found"
    assert_pass_if_clean "test_artifact_no_write_without_approval"
}

# test_artifact_review_all_present: summary — all review-before-write criteria present
test_artifact_review_all_present() {
    _snapshot_fail
    local review_before fenced_code diff_existing no_write result
    review_before="no"; fenced_code="no"; diff_existing="no"; no_write="no"
    grep -qiE "review.*before.*writ|approval.*before.*writ|present.*artifact" "$SKILL_MD" 2>/dev/null && review_before="yes"
    grep -qiE "fenced.*code|code.*block" "$SKILL_MD" 2>/dev/null && fenced_code="yes"
    grep -qiE "diff.*existing|existing.*diff" "$SKILL_MD" 2>/dev/null && diff_existing="yes"
    grep -qiE "NOT write.*without|Do NOT write" "$SKILL_MD" 2>/dev/null && no_write="yes"
    if [[ "$review_before:$fenced_code:$diff_existing:$no_write" == "yes:yes:yes:yes" ]]; then
        result="found"
    else
        result="missing (review_before=$review_before fenced_code=$fenced_code diff_existing=$diff_existing no_write=$no_write)"
    fi
    assert_eq "test_artifact_review_all_present" "found" "$result"
    assert_pass_if_clean "test_artifact_review_all_present"
}

# ── Group f: Regression — verify all 42 assertions in test-onboarding-skill.sh pass ──

# test_regression_onboarding_skill_all_pass: run test-onboarding-skill.sh and verify 0 failures
test_regression_onboarding_skill_all_pass() {
    _snapshot_fail
    local regression_script="$SCRIPT_DIR/test-onboarding-skill.sh"
    if [[ ! -f "$regression_script" ]]; then
        assert_eq "test_regression_onboarding_skill_all_pass" "found" "missing (test-onboarding-skill.sh not at $regression_script)"
        assert_pass_if_clean "test_regression_onboarding_skill_all_pass"
        return
    fi
    # Run the regression suite and capture summary line
    local output exit_code
    output=$(bash "$regression_script" 2>&1) || true
    exit_code=$?
    local summary_line
    summary_line=$(printf '%s\n' "$output" | grep -E "^PASSED: [0-9]+  FAILED: [0-9]+$" | tail -1)
    local failed_count
    failed_count=$(printf '%s\n' "$summary_line" | grep -oE "FAILED: [0-9]+" | grep -oE "[0-9]+")
    local passed_count
    passed_count=$(printf '%s\n' "$summary_line" | grep -oE "PASSED: [0-9]+" | grep -oE "[0-9]+")
    if [[ -z "$failed_count" ]]; then
        assert_eq "test_regression_onboarding_skill_all_pass" "FAILED: 0 in summary" "no summary line found (exit=$exit_code)"
    elif [[ "$failed_count" -eq 0 ]]; then
        assert_eq "test_regression_onboarding_skill_all_pass" "0" "$failed_count"
    else
        assert_eq "test_regression_onboarding_skill_all_pass" "FAILED: 0" "FAILED: $failed_count (PASSED: $passed_count)"
    fi
    assert_pass_if_clean "test_regression_onboarding_skill_all_pass"
}

# test_regression_onboarding_skill_42_assertions: exactly 42 assertions must have passed
test_regression_onboarding_skill_42_assertions() {
    _snapshot_fail
    local regression_script="$SCRIPT_DIR/test-onboarding-skill.sh"
    if [[ ! -f "$regression_script" ]]; then
        assert_eq "test_regression_onboarding_skill_42_assertions" "found" "missing"
        assert_pass_if_clean "test_regression_onboarding_skill_42_assertions"
        return
    fi
    local output
    output=$(bash "$regression_script" 2>&1) || true
    local passed_count
    passed_count=$(printf '%s\n' "$output" | grep -E "^PASSED: [0-9]+  FAILED: [0-9]+$" | tail -1 | grep -oE "PASSED: [0-9]+" | grep -oE "[0-9]+")
    if [[ -z "$passed_count" ]]; then
        assert_eq "test_regression_onboarding_skill_42_assertions" "42 passed" "no summary found"
    elif [[ "$passed_count" -ge 42 ]]; then
        assert_eq "test_regression_onboarding_skill_42_assertions" "found" "found"
    else
        assert_eq "test_regression_onboarding_skill_42_assertions" "at least 42 passed" "$passed_count passed"
    fi
    assert_pass_if_clean "test_regression_onboarding_skill_42_assertions"
}

# ── Run all assertions ─────────────────────────────────────────────────────────

echo ""
echo "--- Group a: dso-config.conf key references ---"
test_config_key_dso_plugin_root
test_config_key_format_extensions
test_config_key_format_source_dirs
test_config_key_test_gate_test_dirs
test_config_key_commands_validate
test_config_key_tickets_directory
test_config_key_checkpoint_marker_file
test_config_key_review_behavioral_patterns
test_all_8_config_keys_present

echo ""
echo "--- Group b: Hook installation references ---"
test_hook_ref_pre_commit_test_gate
test_hook_ref_pre_commit_review_gate
test_hook_ref_husky
test_hook_ref_git_hooks_dir
test_hook_idempotency
test_hook_all_refs_present

echo ""
echo "--- Group c: Ticket system init references ---"
test_ticket_init_orphan_branch
test_ticket_init_tickets_tracker
test_ticket_init_smoke_test
test_ticket_init_push_verification
test_ticket_init_all_refs_present

echo ""
echo "--- Group d: CLAUDE.md generation references ---"
test_claude_md_ref
test_claude_md_ticket_commands
test_claude_md_generate_skill
test_claude_md_host_project
test_claude_md_quick_reference_table

echo ""
echo "--- Group e: Artifact review references ---"
test_artifact_review_before_write
test_artifact_fenced_code_block
test_artifact_diff_existing
test_artifact_no_write_without_approval
test_artifact_review_all_present

echo ""
echo "--- Group f: Regression (test-onboarding-skill.sh) ---"
test_regression_onboarding_skill_all_pass
test_regression_onboarding_skill_42_assertions

print_summary
