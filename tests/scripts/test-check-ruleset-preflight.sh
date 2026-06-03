#!/usr/bin/env bash
# tests/scripts/test-check-ruleset-preflight.sh

#
# Tests cover the two-tier-promotion GitHub Ruleset validation:
#   - sub-PR ruleset (staged-*) requires review-sub-pr (or check_name from config); no linear_history
#   - main ruleset requires check-staged-head + llm-review, NOT review-sub-pr (deadlock); no linear_history
#

# is implemented.
#
# Usage: bash tests/scripts/test-check-ruleset-preflight.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# Do not use -e; we intentionally test non-zero exits from the script under test.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/plugins/dso/scripts/sprint/check-ruleset-preflight.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-check-ruleset-preflight.sh ==="

# ── Setup: shared temp dir, cleaned on exit ───────────────────────────────────
TMPDIR_BASE="$(mktemp -d "${TMPDIR:-/tmp}/test-ruleset-preflight.XXXXXX")"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Helper: build a stub bin directory with a `gh` stub that returns the given
# JSON from `gh api .../rulesets`. Accepts optional extra JSON to return.
# Usage: _make_stub_bin <stub_name> <gh_api_json>
_make_stub_bin() {
    local name="$1" api_json="$2"
    local stub_bin="$TMPDIR_BASE/stub-bin-$name"
    mkdir -p "$stub_bin"

    cat > "$stub_bin/gh" <<STUB
#!/usr/bin/env bash
# Stub gh that returns fixed JSON for ruleset API calls.
# The fixtures embed full conditions/rules, so the script's _fetch_rulesets
# uses the list response verbatim (no per-id fetch needed in tests).
case "\$*" in
    repo*view*)
        echo "test/repo"
        exit 0
        ;;
    api*rulesets*)
        printf '%s\n' '$api_json'
        exit 0
        ;;
    *)
        echo "STUB: unhandled gh command: \$*" >&2
        exit 1
        ;;
esac
STUB
    chmod +x "$stub_bin/gh"
    echo "$stub_bin"
}

# Helper: run the script under test with the given stub bin in PATH.
# Returns combined stdout+stderr. Caller captures exit code via $?.
_run_script() {
    local stub_bin="$1"; shift
    # remaining args passed to script
    local extra_env="${1:-}"
    local config_file="${2:-}"

    local env_args=()
    if [[ -n "$config_file" ]]; then
        env_args+=(DSO_CONFIG_FILE="$config_file")
    fi

    env PATH="$stub_bin:$PATH" "${env_args[@]+"${env_args[@]}"}" \
        bash "$SCRIPT_UNDER_TEST" 2>&1
}

# ── test_script_exists ────────────────────────────────────────────────────────

echo ""
echo "--- test_script_exists ---"
_snapshot_fail
if [[ -f "$SCRIPT_UNDER_TEST" ]]; then
    (( ++PASS ))
    echo "test_script_exists ... PASS"
else
    (( ++FAIL ))
    printf "FAIL: test_script_exists\n  expected: %s to exist\n  actual:   file not found\n" "$SCRIPT_UNDER_TEST" >&2
fi

# Full two-tier config reused across tests: sub-PR ruleset (staged-*, review-sub-pr)
# + main ruleset (check-staged-head, llm-review). The main ruleset deliberately does
# NOT include review-sub-pr (which would deadlock staged-*→main PRs).
GOOD_RULESETS_JSON='{"rulesets":[{"name":"sub-pr","conditions":{"ref_name":{"include":["refs/heads/staged-*"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"review-sub-pr"}]}}]},{"name":"main","conditions":{"ref_name":{"include":["refs/heads/main"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"check-staged-head"},{"context":"llm-review"}]}}]}]}'

# ── test_no_subpr_ruleset_exits_with_message ──────────────────────────────────
echo ""
echo "--- test_no_subpr_ruleset_exits_with_message ---"
_snapshot_fail

EMPTY_RULESETS_JSON='{"rulesets":[]}'
stub_bin_empty="$(_make_stub_bin "empty" "$EMPTY_RULESETS_JSON")"

no_ruleset_output=""
no_ruleset_exit=0
no_ruleset_output="$(env PATH="$stub_bin_empty:$PATH" bash "$SCRIPT_UNDER_TEST" 2>&1)" || no_ruleset_exit=$?

assert_ne "test_no_subpr_ruleset_exits_with_message: exits non-zero on empty rulesets" \
    "0" "$no_ruleset_exit"
assert_contains "test_no_subpr_ruleset_exits_with_message: output mentions staged-* ruleset" \
    "staged-*" "$no_ruleset_output"
assert_pass_if_clean "test_no_subpr_ruleset_exits_with_message"

# ── test_subpr_check_missing_exits_with_message ───────────────────────────────
echo ""
echo "--- test_subpr_check_missing_exits_with_message ---"
_snapshot_fail

# staged-* ruleset present but NO review-sub-pr in required_status_checks
MISSING_CHECK_JSON='{"rulesets":[{"name":"sub-pr","conditions":{"ref_name":{"include":["refs/heads/staged-*"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[]}}]}]}'
stub_bin_missing_check="$(_make_stub_bin "missing_check" "$MISSING_CHECK_JSON")"

missing_check_output=""
missing_check_exit=0
missing_check_output="$(env PATH="$stub_bin_missing_check:$PATH" bash "$SCRIPT_UNDER_TEST" 2>&1)" || missing_check_exit=$?

assert_ne "test_subpr_check_missing_exits_with_message: exits non-zero when sub-PR check missing" \
    "0" "$missing_check_exit"
assert_contains "test_subpr_check_missing_exits_with_message: output mentions review-sub-pr" \
    "review-sub-pr" "$missing_check_output"
assert_pass_if_clean "test_subpr_check_missing_exits_with_message"

# ── test_fully_configured_exits_zero ─────────────────────────────────────────
echo ""
echo "--- test_fully_configured_exits_zero ---"
_snapshot_fail

stub_bin_good="$(_make_stub_bin "good" "$GOOD_RULESETS_JSON")"

good_output=""
good_exit=0
good_output="$(env PATH="$stub_bin_good:$PATH" bash "$SCRIPT_UNDER_TEST" 2>&1)" || good_exit=$?

assert_eq "test_fully_configured_exits_zero: exits 0 when two-tier rulesets fully configured" \
    "0" "$good_exit"
assert_contains "test_fully_configured_exits_zero: output contains success message" \
    "success" "$good_output"
assert_pass_if_clean "test_fully_configured_exits_zero"

# ── test_main_requires_subpr_check_is_deadlock ───────────────────────────────
# review-sub-pr on the MAIN ruleset never runs on a staged-*→main PR -> would
# leave PR2 permanently pending. The preflight must reject this.
echo ""
echo "--- test_main_requires_subpr_check_is_deadlock ---"
_snapshot_fail

DEADLOCK_JSON='{"rulesets":[{"name":"sub-pr","conditions":{"ref_name":{"include":["refs/heads/staged-*"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"review-sub-pr"}]}}]},{"name":"main","conditions":{"ref_name":{"include":["refs/heads/main"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"check-staged-head"},{"context":"llm-review"},{"context":"review-sub-pr"}]}}]}]}'
stub_bin_deadlock="$(_make_stub_bin "deadlock" "$DEADLOCK_JSON")"

deadlock_output=""
deadlock_exit=0
deadlock_output="$(env PATH="$stub_bin_deadlock:$PATH" bash "$SCRIPT_UNDER_TEST" 2>&1)" || deadlock_exit=$?

assert_ne "test_main_requires_subpr_check_is_deadlock: exits non-zero when main requires sub-PR check" \
    "0" "$deadlock_exit"
assert_contains "test_main_requires_subpr_check_is_deadlock: output mentions deadlock/pending" \
    "deadlock" "$deadlock_output"
assert_pass_if_clean "test_main_requires_subpr_check_is_deadlock"

# ── test_main_missing_staged_head_exits_nonzero ──────────────────────────────
echo ""
echo "--- test_main_missing_staged_head_exits_nonzero ---"
_snapshot_fail

NO_STAGED_HEAD_JSON='{"rulesets":[{"name":"sub-pr","conditions":{"ref_name":{"include":["refs/heads/staged-*"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"review-sub-pr"}]}}]},{"name":"main","conditions":{"ref_name":{"include":["refs/heads/main"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"llm-review"}]}}]}]}'
stub_bin_nostaged="$(_make_stub_bin "nostaged" "$NO_STAGED_HEAD_JSON")"

nostaged_output=""
nostaged_exit=0
nostaged_output="$(env PATH="$stub_bin_nostaged:$PATH" bash "$SCRIPT_UNDER_TEST" 2>&1)" || nostaged_exit=$?

assert_ne "test_main_missing_staged_head_exits_nonzero: exits non-zero when main lacks check-staged-head" \
    "0" "$nostaged_exit"
assert_contains "test_main_missing_staged_head_exits_nonzero: output mentions check-staged-head" \
    "check-staged-head" "$nostaged_output"
assert_pass_if_clean "test_main_missing_staged_head_exits_nonzero"

# ── test_reads_check_name_from_config ────────────────────────────────────────
echo ""
echo "--- test_reads_check_name_from_config ---"
_snapshot_fail

# Write a dso-config.conf with a custom sub-PR check_name
custom_config="$TMPDIR_BASE/dso-config.conf"
printf 'dso.review.check_name=My_Custom_Check\n' > "$custom_config"

# staged-* ruleset uses the custom name from config; main ruleset complete
CUSTOM_CHECK_JSON='{"rulesets":[{"name":"sub-pr","conditions":{"ref_name":{"include":["refs/heads/staged-*"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"My_Custom_Check"}]}}]},{"name":"main","conditions":{"ref_name":{"include":["refs/heads/main"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"check-staged-head"},{"context":"llm-review"}]}}]}]}'
stub_bin_custom="$(_make_stub_bin "custom" "$CUSTOM_CHECK_JSON")"

custom_output=""
custom_exit=0
custom_output="$(env PATH="$stub_bin_custom:$PATH" DSO_CONFIG_FILE="$custom_config" bash "$SCRIPT_UNDER_TEST" 2>&1)" || custom_exit=$?

assert_eq "test_reads_check_name_from_config: exits 0 with custom sub-PR check_name from config" \
    "0" "$custom_exit"
assert_contains "test_reads_check_name_from_config: output contains success message" \
    "success" "$custom_output"
assert_pass_if_clean "test_reads_check_name_from_config"

# ═════════════════════════════════════════════════════════════════════════════
# MQ-5 (ADR-0019): dual-mode / transition-tolerant preflight.
# The preflight runs at sprint Phase A and is `set -euo pipefail`. During the
# merge-queue migration the live ruleset is re-provisioned in a single gated
# cutover (MQ-6); the preflight must pass against BOTH models and select which to
# assert from the live state — a hard flip to MQ-only would fail every sprint
# Phase A in the window between MQ-5 landing and the MQ-6 live cutover.
# Discriminator (FAIL-CLOSED): MQ mode iff the MAIN ruleset carries a merge_queue
# rule; otherwise the two-tier assertions run (the closed default).
# ═════════════════════════════════════════════════════════════════════════════

# Shared MQ fixture: MAIN ruleset has a merge_queue rule + llm-review (NO
# check-staged-head); a sub-PR ruleset still requires review-sub-pr.
_MQ_MAIN_RULE='{"type":"merge_queue","parameters":{"merge_method":"MERGE","max_entries_to_build":1,"max_entries_to_merge":1,"min_entries_to_merge":1,"min_entries_to_merge_wait_minutes":5,"check_response_timeout_minutes":60,"grouping_strategy":"ALLGREEN"}}'

# ── test_mq_model_exits_zero ─────────────────────────────────────────────────
echo ""
echo "--- test_mq_model_exits_zero ---"
_snapshot_fail
MQ_GOOD_JSON='{"rulesets":[{"name":"sub-pr","conditions":{"ref_name":{"include":["refs/heads/staged-*"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"review-sub-pr"}]}}]},{"name":"main","conditions":{"ref_name":{"include":["refs/heads/main"]}},"rules":['"$_MQ_MAIN_RULE"',{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"llm-review"}]}}]}]}'
stub_bin_mq_good="$(_make_stub_bin "mq_good" "$MQ_GOOD_JSON")"
mq_good_output=""; mq_good_exit=0
mq_good_output="$(env PATH="$stub_bin_mq_good:$PATH" bash "$SCRIPT_UNDER_TEST" 2>&1)" || mq_good_exit=$?
assert_eq "test_mq_model_exits_zero: exits 0 when MAIN has merge_queue + llm-review, no check-staged-head" \
    "0" "$mq_good_exit"
assert_contains "test_mq_model_exits_zero: output names the merge-queue model" \
    "merge queue" "$mq_good_output"
assert_pass_if_clean "test_mq_model_exits_zero"

# ── test_mq_main_still_has_staged_head_fails ─────────────────────────────────
# Under MQ, check-staged-head must be RETIRED from main. If the cutover left it,
# the preflight must flag it (else a context nothing emits would block).
echo ""
echo "--- test_mq_main_still_has_staged_head_fails ---"
_snapshot_fail
MQ_STAGED_HEAD_JSON='{"rulesets":[{"name":"sub-pr","conditions":{"ref_name":{"include":["refs/heads/staged-*"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"review-sub-pr"}]}}]},{"name":"main","conditions":{"ref_name":{"include":["refs/heads/main"]}},"rules":['"$_MQ_MAIN_RULE"',{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"check-staged-head"},{"context":"llm-review"}]}}]}]}'
stub_bin_mq_sh="$(_make_stub_bin "mq_staged_head" "$MQ_STAGED_HEAD_JSON")"
mq_sh_output=""; mq_sh_exit=0
mq_sh_output="$(env PATH="$stub_bin_mq_sh:$PATH" bash "$SCRIPT_UNDER_TEST" 2>&1)" || mq_sh_exit=$?
assert_ne "test_mq_main_still_has_staged_head_fails: exits non-zero when check-staged-head lingers under MQ" \
    "0" "$mq_sh_exit"
assert_contains "test_mq_main_still_has_staged_head_fails: output mentions check-staged-head" \
    "check-staged-head" "$mq_sh_output"
assert_pass_if_clean "test_mq_main_still_has_staged_head_fails"

# ── test_mq_missing_subpr_review_fails ───────────────────────────────────────
# The sub-PR LLM review must survive under MQ (every commit reviewed at sub-PR).
echo ""
echo "--- test_mq_missing_subpr_review_fails ---"
_snapshot_fail
MQ_NO_SUBPR_JSON='{"rulesets":[{"name":"main","conditions":{"ref_name":{"include":["refs/heads/main"]}},"rules":['"$_MQ_MAIN_RULE"',{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"llm-review"}]}}]}]}'
stub_bin_mq_nosub="$(_make_stub_bin "mq_nosub" "$MQ_NO_SUBPR_JSON")"
mq_nosub_output=""; mq_nosub_exit=0
mq_nosub_output="$(env PATH="$stub_bin_mq_nosub:$PATH" bash "$SCRIPT_UNDER_TEST" 2>&1)" || mq_nosub_exit=$?
assert_ne "test_mq_missing_subpr_review_fails: exits non-zero when no ruleset requires review-sub-pr under MQ" \
    "0" "$mq_nosub_exit"
assert_contains "test_mq_missing_subpr_review_fails: output mentions review-sub-pr" \
    "review-sub-pr" "$mq_nosub_output"
assert_pass_if_clean "test_mq_missing_subpr_review_fails"

# ── test_two_tier_still_passes_after_mq_support (regression) ──────────────────
# The fail-closed default: a ruleset set with NO merge_queue rule must still be
# validated under the two-tier assertions (GOOD_RULESETS_JSON has no merge_queue).
echo ""
echo "--- test_two_tier_still_passes_after_mq_support ---"
_snapshot_fail
stub_bin_tt="$(_make_stub_bin "two_tier_regress" "$GOOD_RULESETS_JSON")"
tt_output=""; tt_exit=0
tt_output="$(env PATH="$stub_bin_tt:$PATH" bash "$SCRIPT_UNDER_TEST" 2>&1)" || tt_exit=$?
assert_eq "test_two_tier_still_passes_after_mq_support: two-tier still exits 0 (fail-closed default)" \
    "0" "$tt_exit"
assert_contains "test_two_tier_still_passes_after_mq_support: output names the two-tier model" \
    "two-tier" "$tt_output"
assert_pass_if_clean "test_two_tier_still_passes_after_mq_support"

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary
