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
# Inputs (env vars consumed; gh CLI auth required):
#   GH_REPO          owner/name of the repo to inspect (default:
#                    navapbc/digital-service-orchestra)
#   gh authentication: in CI the gh CLI uses GH_TOKEN (a GitHub Actions
#                    short-lived permission-scoped token); locally it uses
#                    the user's gh auth login state. The Rulesets API
#                    requires `administration: read` on the Actions token,
#                    or `repo` scope on a personal access token.
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

# Intentional `set -uo pipefail` (NOT `-e`): every gh api call below is
# followed by an explicit `if [[ $_rc -ne 0 ]]; then _precondition_not_met
# ...; fi` block that surfaces the actual gh error message verbatim.
# Adding `-e` would cause command-substitution failures to exit the script
# BEFORE `$?` capture lines run, swallowing the diagnostic message and
# producing a generic "exited with rc=1" without the operator-facing context.
# The explicit per-call error handlers are the safety net here, not `-e`.
set -uo pipefail

GH_REPO="${GH_REPO:-navapbc/digital-service-orchestra}"

# Ruleset names — intentional coupling with provision-ruleset.sh.
# Verified alignment at the time of writing (PR-R2 cycle 4):
#   - provision-ruleset.sh:297  "name": "DSO CI Enforcement"
#   - provision-ruleset.sh:401  "name": "DSO Sub-PR Review Enforcement"
# If the names ever drift (e.g., UI rename without re-provisioning), this
# test fails with "ruleset not found" — which is the correct signal: live
# state has diverged from the provisioner's expectation. Override via env
# vars for forks / multi-repo deployments.
SUB_PR_RULESET_NAME="${DSO_SUB_PR_RULESET_NAME:-DSO Sub-PR Review Enforcement}"
MAIN_RULESET_NAME="${DSO_MAIN_RULESET_NAME:-DSO CI Enforcement}"

PASS=0
FAIL=0

_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

# All tmp files are tracked in this single list so a single trap on EXIT
# cleans them up regardless of which path the script exits via (success,
# drift, precondition failure, SIGTERM from CI timeout).
_TRACKED_TMP_FILES=()
_track_tmp() { _TRACKED_TMP_FILES+=("$1"); }
_cleanup_tmps() {
    local _f
    for _f in "${_TRACKED_TMP_FILES[@]:-}"; do
        [[ -n "$_f" ]] && rm -f "$_f" 2>/dev/null || true
    done
}
trap _cleanup_tmps EXIT

# ── Preconditions: surface missing tooling / auth as PRECONDITION errors ────
# Distinct exit class from FAIL — operators investigating CI output should
# see "PRECONDITION_NOT_MET: ..." and know it's not a drift failure.
_precondition_not_met() {
    echo "PRECONDITION_NOT_MET: $1" >&2
    echo "    Action: $2" >&2
    exit 78  # EX_CONFIG — distinct from 0 (pass) and 1 (drift detected)
}

if ! command -v python3 >/dev/null 2>&1; then
    _precondition_not_met "python3 not in PATH" \
        "Install python3 on the runner / shim it into PATH."
fi

if ! command -v gh >/dev/null 2>&1; then
    _precondition_not_met "gh CLI not in PATH" \
        "Install GitHub CLI on the runner."
fi

# Two skip paths:
#   1. No GH_TOKEN exported AND no local gh auth → the test isn't expected
#      to run here (generic test runner, no rulesets PAT). Skip with rc=0
#      so generic runners stay green; the dedicated ruleset-invariants
#      workflow sets GH_TOKEN explicitly and won't hit this branch.
#   2. GH_TOKEN exported but gh auth fails → misconfiguration that should
#      fail loudly via _precondition_not_met (rc=78).
if [[ -z "${GH_TOKEN:-}" ]] && ! gh auth status >/dev/null 2>&1; then
    echo "SKIP: no GH_TOKEN and no local gh auth — ruleset-invariants test runs only when token is provided"
    exit 0
fi
if ! gh auth status >/dev/null 2>&1; then
    _precondition_not_met "GH_TOKEN provided but gh auth failed" \
        "Verify secrets.DSO_RULESETS_READ_TOKEN or secrets.GITHUB_TOKEN is valid."
fi

# Validate token scope: ruleset reads require `repo` scope. Check via the
# Authorization header on a low-impact endpoint, surfacing the actual gh
# error if it fails.
_scope_check_stderr=$(mktemp "${TMPDIR:-/tmp}/dso-ruleset-scope.XXXXXX"); _track_tmp "$_scope_check_stderr"
if ! gh api "repos/${GH_REPO}" --jq .id >/dev/null 2>"$_scope_check_stderr"; then
    _scope_err="$(cat "$_scope_check_stderr")"
    rm -f "$_scope_check_stderr"
    _precondition_not_met "gh API call to repos/${GH_REPO} failed: ${_scope_err}" \
        "Verify GITHUB_TOKEN has 'repo' scope and the repo is accessible."
fi
rm -f "$_scope_check_stderr"

# ── Resolve ruleset IDs by name ──────────────────────────────────────────────
# Capture stderr from gh so a 403 / network error / invalid response is
# surfaced explicitly rather than silently producing an empty result.
_rulesets_stderr=$(mktemp "${TMPDIR:-/tmp}/dso-ruleset-list.XXXXXX"); _track_tmp "$_rulesets_stderr"
RULESETS_JSON="$(gh api "repos/${GH_REPO}/rulesets" 2>"$_rulesets_stderr")"
_gh_rc=$?
_rulesets_err="$(cat "$_rulesets_stderr")"
rm -f "$_rulesets_stderr"

if [[ $_gh_rc -ne 0 ]]; then
    _precondition_not_met "gh api rulesets call failed (rc=${_gh_rc}): ${_rulesets_err}" \
        "Verify network connectivity and token scope."
fi

if [[ -z "$RULESETS_JSON" ]]; then
    _precondition_not_met "gh api rulesets returned empty body" \
        "Verify the repo has rulesets enabled and the token has scope."
fi

# Parse with explicit error surfacing.
if ! echo "$RULESETS_JSON" | python3 -c "import sys,json; json.load(sys.stdin)" >/dev/null 2>&1; then
    _precondition_not_met "rulesets response is not valid JSON" \
        "Inspect the raw response: gh api repos/${GH_REPO}/rulesets"
fi

# Extract IDs, surfacing parse errors instead of empty fallthrough.
_extract_stderr=$(mktemp "${TMPDIR:-/tmp}/dso-ruleset-extract.XXXXXX"); _track_tmp "$_extract_stderr"
SUB_PR_ID="$(echo "$RULESETS_JSON" | DSO_RULESET_NAME="$SUB_PR_RULESET_NAME" python3 -c "
import json,os,sys
target = os.environ['DSO_RULESET_NAME']
try:
    data = json.load(sys.stdin)
except Exception as exc:
    print(f'PARSE_ERROR: {type(exc).__name__}: {exc}', file=sys.stderr)
    sys.exit(2)
for r in data:
    if r.get('name') == target:
        print(r.get('id', ''))
        sys.exit(0)
# Distinct exit code: not-found vs parse-error vs JSON shape error.
print(f'NOT_FOUND: ruleset named {target!r}', file=sys.stderr)
sys.exit(3)
" 2>"$_extract_stderr")"
_sub_pr_extract_rc=$?
_sub_pr_extract_err="$(cat "$_extract_stderr")"
rm -f "$_extract_stderr"

case "$_sub_pr_extract_rc" in
  0) ;;
  2) _precondition_not_met "sub-PR ruleset JSON parse failed: ${_sub_pr_extract_err}" \
        "Inspect: gh api repos/${GH_REPO}/rulesets" ;;
  3) _precondition_not_met "no ruleset named '${SUB_PR_RULESET_NAME}' on ${GH_REPO}" \
        "Run provision-ruleset.sh to (re-)create the ruleset, or override DSO_SUB_PR_RULESET_NAME if the name has changed." ;;
  *) _precondition_not_met "sub-PR ruleset extraction failed (rc=${_sub_pr_extract_rc}): ${_sub_pr_extract_err}" \
        "Check the JSON shape returned by gh api repos/${GH_REPO}/rulesets" ;;
esac

_extract_stderr=$(mktemp "${TMPDIR:-/tmp}/dso-ruleset-extract.XXXXXX"); _track_tmp "$_extract_stderr"
MAIN_ID="$(echo "$RULESETS_JSON" | DSO_RULESET_NAME="$MAIN_RULESET_NAME" python3 -c "
import json,os,sys
target = os.environ['DSO_RULESET_NAME']
try:
    data = json.load(sys.stdin)
except Exception as exc:
    print(f'PARSE_ERROR: {type(exc).__name__}: {exc}', file=sys.stderr)
    sys.exit(2)
for r in data:
    if r.get('name') == target:
        print(r.get('id', ''))
        sys.exit(0)
print(f'NOT_FOUND: ruleset named {target!r}', file=sys.stderr)
sys.exit(3)
" 2>"$_extract_stderr")"
_main_extract_rc=$?
_main_extract_err="$(cat "$_extract_stderr")"
rm -f "$_extract_stderr"

case "$_main_extract_rc" in
  0) ;;
  2) _precondition_not_met "main ruleset JSON parse failed: ${_main_extract_err}" \
        "Inspect: gh api repos/${GH_REPO}/rulesets" ;;
  3) _precondition_not_met "no ruleset named '${MAIN_RULESET_NAME}' on ${GH_REPO}" \
        "Run provision-ruleset.sh, or override DSO_MAIN_RULESET_NAME if the name has changed." ;;
  *) _precondition_not_met "main ruleset extraction failed (rc=${_main_extract_rc}): ${_main_extract_err}" \
        "Check the JSON shape returned by gh api repos/${GH_REPO}/rulesets" ;;
esac

# Both IDs guaranteed non-empty here — the case blocks above exit early on
# any failure path. _pass for symmetry with the rest of the test output.
_pass "test_sub_pr_ruleset_exists"
_pass "test_main_ruleset_exists"

# ── Fetch full ruleset payloads (with explicit error handling) ──────────────
_sub_pr_stderr=$(mktemp "${TMPDIR:-/tmp}/dso-ruleset-subpr.XXXXXX"); _track_tmp "$_sub_pr_stderr"
SUB_PR_FULL="$(gh api "repos/${GH_REPO}/rulesets/${SUB_PR_ID}" 2>"$_sub_pr_stderr")"
_sub_pr_rc=$?
_sub_pr_err="$(cat "$_sub_pr_stderr")"
rm -f "$_sub_pr_stderr"
if [[ $_sub_pr_rc -ne 0 ]] || [[ -z "$SUB_PR_FULL" ]]; then
    _precondition_not_met "fetching sub-PR ruleset payload failed (rc=${_sub_pr_rc}): ${_sub_pr_err}" \
        "Verify the ruleset ID ${SUB_PR_ID} is accessible."
fi

_main_stderr=$(mktemp "${TMPDIR:-/tmp}/dso-ruleset-main.XXXXXX"); _track_tmp "$_main_stderr"
MAIN_FULL="$(gh api "repos/${GH_REPO}/rulesets/${MAIN_ID}" 2>"$_main_stderr")"
_main_rc=$?
_main_err="$(cat "$_main_stderr")"
rm -f "$_main_stderr"
if [[ $_main_rc -ne 0 ]] || [[ -z "$MAIN_FULL" ]]; then
    _precondition_not_met "fetching main ruleset payload failed (rc=${_main_rc}): ${_main_err}" \
        "Verify the ruleset ID ${MAIN_ID} is accessible."
fi

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

# I4: ALL sub-PR bypass actors must have bypass_mode=pull_request.
# Iterates every actor in the list (a permissive 'always' on a second
# actor would otherwise pass the test while breaking the security
# invariant; cycle-2 review finding).
i4_violations="$(echo "$SUB_PR_FULL" | python3 -c "
import json,sys
d = json.load(sys.stdin)
violations = []
actors = d.get('bypass_actors', []) or []
if not actors:
    print('NO_ACTORS')
    sys.exit(0)
for a in actors:
    if not isinstance(a, dict):
        violations.append(f'non-dict actor: {a!r}')
        continue
    mode = a.get('bypass_mode', '')
    if mode != 'pull_request':
        violations.append(f'actor_id={a.get(\"actor_id\", \"?\")} type={a.get(\"actor_type\", \"?\")} bypass_mode={mode!r}')
print(','.join(violations))
")"
if [[ "$i4_violations" == "NO_ACTORS" ]]; then
    # Vacuously true: the invariant is "every bypass actor uses
    # pull_request mode". No actors means no bypass possible — which
    # satisfies the security goal even if it removes the admin-merge
    # escape valve. The design doc (review-defenses.md § Two-Tier
    # Promotion Gate) requires `bypass_mode: pull_request` for admin
    # bypass to remain a possibility but does not mandate the bypass
    # actors list be non-empty (cycle-4 review).
    _pass "I4_sub_pr_bypass_mode_pull_request (no actors — vacuously true)"
elif [[ -z "$i4_violations" ]]; then
    _pass "I4_sub_pr_bypass_mode_pull_request"
else
    _fail "I4_sub_pr_bypass_mode_pull_request" \
        "actor(s) with bypass_mode != pull_request: $i4_violations"
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

# I7: ALL main ruleset bypass actors must have bypass_mode=pull_request.
# Same all-actors iteration as I4.
i7_violations="$(echo "$MAIN_FULL" | python3 -c "
import json,sys
d = json.load(sys.stdin)
violations = []
actors = d.get('bypass_actors', []) or []
if not actors:
    print('NO_ACTORS')
    sys.exit(0)
for a in actors:
    if not isinstance(a, dict):
        violations.append(f'non-dict actor: {a!r}')
        continue
    mode = a.get('bypass_mode', '')
    if mode != 'pull_request':
        violations.append(f'actor_id={a.get(\"actor_id\", \"?\")} type={a.get(\"actor_type\", \"?\")} bypass_mode={mode!r}')
print(','.join(violations))
")"
if [[ "$i7_violations" == "NO_ACTORS" ]]; then
    # Vacuously true — see I4 rationale above.
    _pass "I7_main_bypass_mode_pull_request (no actors — vacuously true)"
elif [[ -z "$i7_violations" ]]; then
    _pass "I7_main_bypass_mode_pull_request"
else
    _fail "I7_main_bypass_mode_pull_request" \
        "actor(s) with bypass_mode != pull_request: $i7_violations"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
