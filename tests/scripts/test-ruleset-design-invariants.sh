#!/usr/bin/env bash
# tests/scripts/test-ruleset-design-invariants.sh — PR-R2
#
# Asserts the live GitHub Rulesets state matches the two-tier promotion gate
# design documented in plugins/dso/docs/contracts/review-defenses.md.
#
# Drift detection: if any PR touching provision-ruleset.sh, the workflows
# directory, the runbook, or this test file causes the live ruleset state to
# diverge from the design, this test fails.
#
# Required env:
#   GH_REPO          owner/name of the repo to inspect (default:
#                    navapbc/digital-service-orchestra)
#   GITHUB_TOKEN     gh CLI auth token; must have `repo` scope to read ruleset
#                    metadata. CI provides this via actions/checkout.
#
# Invariants asserted:
#   I1: sub-PR ruleset's include is exactly ["refs/heads/staged-*"]
#   I2: sub-PR ruleset's required check is "review-sub-pr"
#   I3: sub-PR ruleset has do_not_enforce_on_create=true
#   I4: sub-PR ruleset's bypass_mode is "pull_request"
#   I5: sub-PR ruleset enforcement is "active"
#   I6: main ruleset's required_status_checks includes "check-staged-head"
#   I7: main ruleset's bypass_mode is "pull_request"
#
# Ruleset IDs are looked up by NAME at runtime (not hardcoded) so the test
# survives ruleset recreation. If the names change, both this test and the
# provisioner break in lockstep — that's the intended coupling.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
GH_REPO="${GH_REPO:-navapbc/digital-service-orchestra}"

PASS=0
FAIL=0

_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

# Skip silently when gh isn't authenticated. The test is meant to run in CI
# where gh has secrets.GITHUB_TOKEN injected; running locally without auth is
# a no-op so this test doesn't block dev iteration.
if ! gh auth status >/dev/null 2>&1; then
    echo "SKIP: gh not authenticated; ruleset-invariants test is CI-only"
    exit 0
fi

# ── Resolve ruleset IDs by name ──────────────────────────────────────────────
RULESETS_JSON="$(gh api "repos/${GH_REPO}/rulesets" 2>/dev/null)"
if [[ -z "$RULESETS_JSON" ]] || ! echo "$RULESETS_JSON" | python3 -c "import sys,json; json.load(sys.stdin)" >/dev/null 2>&1; then
    echo "ERROR: could not fetch rulesets list from ${GH_REPO}; aborting"
    exit 1
fi

SUB_PR_ID="$(echo "$RULESETS_JSON" | python3 -c "
import json,sys
for r in json.load(sys.stdin):
    if r.get('name') == 'DSO Sub-PR Review Enforcement':
        print(r.get('id', '')); sys.exit(0)
")"
MAIN_ID="$(echo "$RULESETS_JSON" | python3 -c "
import json,sys
for r in json.load(sys.stdin):
    if r.get('name') == 'DSO CI Enforcement':
        print(r.get('id', '')); sys.exit(0)
")"

if [[ -z "$SUB_PR_ID" ]]; then
    _fail "test_sub_pr_ruleset_exists" "no ruleset named 'DSO Sub-PR Review Enforcement' on ${GH_REPO}"
else
    _pass "test_sub_pr_ruleset_exists"
fi
if [[ -z "$MAIN_ID" ]]; then
    _fail "test_main_ruleset_exists" "no ruleset named 'DSO CI Enforcement' on ${GH_REPO}"
else
    _pass "test_main_ruleset_exists"
fi

# ── Fetch full ruleset payloads ──────────────────────────────────────────────
SUB_PR_FULL="$(gh api "repos/${GH_REPO}/rulesets/${SUB_PR_ID}" 2>/dev/null)"
MAIN_FULL="$(gh api "repos/${GH_REPO}/rulesets/${MAIN_ID}" 2>/dev/null)"

# ── Invariant assertions ─────────────────────────────────────────────────────

# I1: sub-PR include
include="$(echo "$SUB_PR_FULL" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(json.dumps(sorted(d.get('conditions', {}).get('ref_name', {}).get('include', []))))
")"
if [[ "$include" == '["refs/heads/staged-*"]' ]]; then
    _pass "I1_sub_pr_include_is_staged_only"
else
    _fail "I1_sub_pr_include_is_staged_only" \
        "expected [\"refs/heads/staged-*\"], got $include"
fi

# I2 + I3: sub-PR rule type + required check + do_not_enforce_on_create
rsc_info="$(echo "$SUB_PR_FULL" | python3 -c "
import json,sys
d = json.load(sys.stdin)
for r in d.get('rules', []):
    if r.get('type') == 'required_status_checks':
        p = r.get('parameters', {})
        checks = sorted([c.get('context') for c in p.get('required_status_checks', [])])
        print(json.dumps({'checks': checks, 'do_not_enforce_on_create': p.get('do_not_enforce_on_create', False)}))
        sys.exit(0)
print(json.dumps({'checks': [], 'do_not_enforce_on_create': False}))
")"
if echo "$rsc_info" | python3 -c "
import json,sys
d = json.loads(sys.stdin.read())
sys.exit(0 if 'review-sub-pr' in d.get('checks', []) else 1)
"; then
    _pass "I2_sub_pr_required_check_is_review_sub_pr"
else
    _fail "I2_sub_pr_required_check_is_review_sub_pr" "rsc_info=$rsc_info"
fi
if echo "$rsc_info" | python3 -c "
import json,sys
d = json.loads(sys.stdin.read())
sys.exit(0 if d.get('do_not_enforce_on_create') is True else 1)
"; then
    _pass "I3_sub_pr_do_not_enforce_on_create"
else
    _fail "I3_sub_pr_do_not_enforce_on_create" "rsc_info=$rsc_info"
fi

# I4: sub-PR bypass_mode
bypass_mode="$(echo "$SUB_PR_FULL" | python3 -c "
import json,sys
d = json.load(sys.stdin)
for a in d.get('bypass_actors', []):
    print(a.get('bypass_mode', '')); break
")"
if [[ "$bypass_mode" == "pull_request" ]]; then
    _pass "I4_sub_pr_bypass_mode_pull_request"
else
    _fail "I4_sub_pr_bypass_mode_pull_request" "expected pull_request, got $bypass_mode"
fi

# I5: sub-PR enforcement
enforcement="$(echo "$SUB_PR_FULL" | python3 -c "import json,sys; print(json.load(sys.stdin).get('enforcement'))")"
if [[ "$enforcement" == "active" ]]; then
    _pass "I5_sub_pr_enforcement_active"
else
    _fail "I5_sub_pr_enforcement_active" "expected active, got $enforcement"
fi

# I6: main ruleset required_status_checks includes check-staged-head
if echo "$MAIN_FULL" | python3 -c "
import json,sys
d = json.load(sys.stdin)
for r in d.get('rules', []):
    if r.get('type') == 'required_status_checks':
        checks = [c.get('context') for c in r.get('parameters', {}).get('required_status_checks', [])]
        sys.exit(0 if 'check-staged-head' in checks else 1)
sys.exit(1)
"; then
    _pass "I6_main_ruleset_requires_check_staged_head"
else
    _fail "I6_main_ruleset_requires_check_staged_head" \
        "check-staged-head not in main ruleset required_status_checks"
fi

# I7: main ruleset bypass_mode
main_bypass="$(echo "$MAIN_FULL" | python3 -c "
import json,sys
d = json.load(sys.stdin)
for a in d.get('bypass_actors', []):
    print(a.get('bypass_mode', '')); break
")"
if [[ "$main_bypass" == "pull_request" ]]; then
    _pass "I7_main_bypass_mode_pull_request"
else
    _fail "I7_main_bypass_mode_pull_request" "expected pull_request, got $main_bypass"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
