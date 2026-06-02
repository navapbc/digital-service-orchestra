#!/usr/bin/env bash
# tests/scripts/test-ruleset-design-invariants-modes.sh — MQ-3 (ADR-0019)
#
# Behavioral meta-test for the TRANSITION-TOLERANT (dual-mode) rewrite of
# test-ruleset-design-invariants.sh. The invariant test reads LIVE GitHub
# ruleset state and is itself a REQUIRED check (ruleset-design-invariants), so
# during the staged→main → merge-queue migration it MUST pass against BOTH:
#   - the current two-tier model (staged-* sub-PR ruleset + check-staged-head on
#     main), AND
#   - the post-cutover merge-queue model (merge_queue rule on main; no
#     check-staged-head).
# Flipping the assertions to MQ-only before the live ruleset is re-provisioned
# (MQ-6) would red the required check and deadlock every promotion. This test
# locks in the dual-mode contract so that regression can't be reintroduced.
#
# Mechanism: the invariant script accepts DSO_RULESET_FIXTURE_DIR pointing at a
# directory containing rulesets.json (the list), main.json (the MAIN ruleset
# payload), and optionally subpr.json (the sub-PR ruleset payload). When set,
# the script reads those instead of calling the live GitHub API — letting us
# drive deterministic two-tier / MQ / drift scenarios offline.
#
# Mode discriminator (fail-closed): the script selects MQ mode iff the MAIN
# ruleset payload contains a `merge_queue` rule; otherwise it asserts the
# two-tier invariants. This test proves the fail-closed property: a two-tier
# ruleset that has lost check-staged-head but has NOT gained a merge_queue rule
# must FAIL (not be waved through as "MQ mode").

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/tests/scripts/test-ruleset-design-invariants.sh"

PASS=0
FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL + 1)); }

if ! command -v python3 >/dev/null 2>&1; then
    echo "PRECONDITION_NOT_MET: python3 not in PATH" >&2
    exit 78
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dso-invariants-modes.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ── Fixture builders ─────────────────────────────────────────────────────────
# Sub-PR ruleset payload (two-tier): staged-* include, review-sub-pr required,
# do_not_enforce_on_create, bypass never, active.
_write_subpr_two_tier() {
    cat >"$1" <<'JSON'
{
  "name": "DSO Sub-PR Review Enforcement",
  "enforcement": "active",
  "current_user_can_bypass": "never",
  "conditions": { "ref_name": { "include": ["refs/heads/staged-*"], "exclude": [] } },
  "rules": [
    { "type": "required_status_checks",
      "parameters": {
        "do_not_enforce_on_create": true,
        "required_status_checks": [ { "context": "review-sub-pr" } ] } }
  ]
}
JSON
}

# MAIN ruleset payload (two-tier): required checks include check-staged-head,
# NO merge_queue rule, bypass never.
_write_main_two_tier() {
    cat >"$1" <<'JSON'
{
  "name": "DSO CI Enforcement",
  "enforcement": "active",
  "current_user_can_bypass": "never",
  "rules": [
    { "type": "pull_request", "parameters": {} },
    { "type": "non_fast_forward", "parameters": {} },
    { "type": "required_status_checks",
      "parameters": { "required_status_checks": [
        { "context": "Actionlint" },
        { "context": "ShellCheck" },
        { "context": "check-staged-head" },
        { "context": "ruleset-design-invariants" } ] } }
  ]
}
JSON
}

# MAIN ruleset payload (MQ): merge_queue rule with the ADR-0019 GO-scoped
# params, required checks WITHOUT check-staged-head, bypass never.
_write_main_mq() {
    cat >"$1" <<'JSON'
{
  "name": "DSO CI Enforcement",
  "enforcement": "active",
  "current_user_can_bypass": "never",
  "rules": [
    { "type": "pull_request", "parameters": {} },
    { "type": "non_fast_forward", "parameters": {} },
    { "type": "merge_queue",
      "parameters": {
        "merge_method": "MERGE",
        "max_entries_to_build": 1,
        "max_entries_to_merge": 1,
        "min_entries_to_merge": 1,
        "min_entries_to_merge_wait_minutes": 5,
        "check_response_timeout_minutes": 60,
        "grouping_strategy": "ALLGREEN" } },
    { "type": "required_status_checks",
      "parameters": { "required_status_checks": [
        { "context": "Actionlint" },
        { "context": "ShellCheck" },
        { "context": "ruleset-design-invariants" } ] } }
  ]
}
JSON
}

_write_rulesets_list() {
    # $1 = output file; $2 = include sub-PR ruleset? (1/0)
    if [[ "$2" == "1" ]]; then
        cat >"$1" <<'JSON'
[ { "id": 15629023, "name": "DSO CI Enforcement" },
  { "id": 16961402, "name": "DSO Sub-PR Review Enforcement" } ]
JSON
    else
        cat >"$1" <<'JSON'
[ { "id": 15629023, "name": "DSO CI Enforcement" } ]
JSON
    fi
}

# Run the invariant script against a fixture dir; echo rc.
_run_fixture() {
    local dir="$1"
    DSO_RULESET_FIXTURE_DIR="$dir" bash "$SCRIPT" >"$dir/out.txt" 2>&1
    echo $?
}

# ── Scenario 1: two-tier model → PASS (exit 0), I1/I2/I6 asserted ────────────
S1="$WORK/two_tier"; mkdir -p "$S1"
_write_rulesets_list "$S1/rulesets.json" 1
_write_main_two_tier "$S1/main.json"
_write_subpr_two_tier "$S1/subpr.json"
rc1="$(_run_fixture "$S1")"
if [[ "$rc1" == "0" ]]; then
    _pass "two_tier_model_passes"
else
    _fail "two_tier_model_passes" "expected exit 0, got $rc1; out=$(cat "$S1/out.txt")"
fi
if grep -q "I6_main_ruleset_requires_check_staged_head" "$S1/out.txt" 2>/dev/null; then
    _pass "two_tier_asserts_I6"
else
    _fail "two_tier_asserts_I6" "I6 assertion not emitted in two-tier mode; out=$(cat "$S1/out.txt")"
fi

# ── Scenario 2: MQ model → PASS (exit 0), MQ assertions, no two-tier I6 ──────
S2="$WORK/mq"; mkdir -p "$S2"
_write_rulesets_list "$S2/rulesets.json" 0
_write_main_mq "$S2/main.json"
rc2="$(_run_fixture "$S2")"
if [[ "$rc2" == "0" ]]; then
    _pass "mq_model_passes"
else
    _fail "mq_model_passes" "expected exit 0, got $rc2; out=$(cat "$S2/out.txt")"
fi
# In MQ mode the two-tier check-staged-head assertion must NOT be evaluated.
if grep -q "I6_main_ruleset_requires_check_staged_head" "$S2/out.txt" 2>/dev/null; then
    _fail "mq_skips_two_tier_I6" "two-tier I6 wrongly evaluated under MQ mode; out=$(cat "$S2/out.txt")"
else
    _pass "mq_skips_two_tier_I6"
fi
# MQ mode must positively assert the merge_queue rule + absence of check-staged-head.
if grep -q "M1_main_has_merge_queue_rule" "$S2/out.txt" 2>/dev/null \
    && grep -q "M2_main_no_check_staged_head" "$S2/out.txt" 2>/dev/null; then
    _pass "mq_asserts_positive_shape"
else
    _fail "mq_asserts_positive_shape" "M1/M2 assertions not emitted under MQ mode; out=$(cat "$S2/out.txt")"
fi

# ── Scenario 3 (fail-closed): two-tier ruleset that LOST check-staged-head but
#    has NO merge_queue rule → must FAIL (not be waved through as MQ). ─────────
S3="$WORK/drift_two_tier"; mkdir -p "$S3"
_write_rulesets_list "$S3/rulesets.json" 1
# main payload: two-tier shape but check-staged-head removed, no merge_queue.
cat >"$S3/main.json" <<'JSON'
{
  "name": "DSO CI Enforcement",
  "enforcement": "active",
  "current_user_can_bypass": "never",
  "rules": [
    { "type": "pull_request", "parameters": {} },
    { "type": "required_status_checks",
      "parameters": { "required_status_checks": [
        { "context": "Actionlint" },
        { "context": "ruleset-design-invariants" } ] } }
  ]
}
JSON
_write_subpr_two_tier "$S3/subpr.json"
rc3="$(_run_fixture "$S3")"
if [[ "$rc3" == "1" ]]; then
    _pass "fail_closed_lost_check_staged_head_no_mq"
else
    _fail "fail_closed_lost_check_staged_head_no_mq" \
        "expected exit 1 (drift), got $rc3 — discriminator is NOT fail-closed; out=$(cat "$S3/out.txt")"
fi

# ── Scenario 4 (MQ drift): merge_queue present BUT check-staged-head still
#    required on main → must FAIL (M2 violated). ──────────────────────────────
S4="$WORK/drift_mq"; mkdir -p "$S4"
_write_rulesets_list "$S4/rulesets.json" 0
cat >"$S4/main.json" <<'JSON'
{
  "name": "DSO CI Enforcement",
  "enforcement": "active",
  "current_user_can_bypass": "never",
  "rules": [
    { "type": "merge_queue",
      "parameters": {
        "merge_method": "MERGE",
        "max_entries_to_build": 1,
        "max_entries_to_merge": 1,
        "min_entries_to_merge": 1,
        "min_entries_to_merge_wait_minutes": 5,
        "check_response_timeout_minutes": 60,
        "grouping_strategy": "ALLGREEN" } },
    { "type": "required_status_checks",
      "parameters": { "required_status_checks": [
        { "context": "check-staged-head" },
        { "context": "ruleset-design-invariants" } ] } }
  ]
}
JSON
rc4="$(_run_fixture "$S4")"
if [[ "$rc4" == "1" ]]; then
    _pass "mq_drift_check_staged_head_still_present_fails"
else
    _fail "mq_drift_check_staged_head_still_present_fails" \
        "expected exit 1 (M2 drift), got $rc4; out=$(cat "$S4/out.txt")"
fi

# ── Scenario 5 (MQ drift): merge_queue present but params diverge from ADR →
#    must FAIL (M1 params violated). ───────────────────────────────────────────
S5="$WORK/drift_mq_params"; mkdir -p "$S5"
_write_rulesets_list "$S5/rulesets.json" 0
cat >"$S5/main.json" <<'JSON'
{
  "name": "DSO CI Enforcement",
  "enforcement": "active",
  "current_user_can_bypass": "never",
  "rules": [
    { "type": "merge_queue",
      "parameters": {
        "merge_method": "SQUASH",
        "max_entries_to_build": 5,
        "max_entries_to_merge": 5,
        "min_entries_to_merge": 1,
        "min_entries_to_merge_wait_minutes": 5,
        "check_response_timeout_minutes": 60,
        "grouping_strategy": "ALLGREEN" } },
    { "type": "required_status_checks",
      "parameters": { "required_status_checks": [
        { "context": "ruleset-design-invariants" } ] } }
  ]
}
JSON
rc5="$(_run_fixture "$S5")"
if [[ "$rc5" == "1" ]]; then
    _pass "mq_drift_params_diverge_fails"
else
    _fail "mq_drift_params_diverge_fails" \
        "expected exit 1 (M1 params drift), got $rc5; out=$(cat "$S5/out.txt")"
fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
