#!/usr/bin/env bash
# tests/scripts/test-ruleset-design-invariants.sh — PR-R2 / MQ-3 (ADR-0019)
#
# Asserts the live GitHub Rulesets state matches the promotion-gate design
# documented in plugins/dso/docs/contracts/review-defenses.md.
#
# TRANSITION-TOLERANT (dual-mode) — MQ-3, ADR-0019:
# This test is itself a REQUIRED check (ruleset-design-invariants) and reads
# LIVE ruleset state. During the staged→main → GitHub-Merge-Queue migration the
# live ruleset is re-provisioned in a single gated cutover (MQ-6). To avoid
# reddening this required check (which would deadlock EVERY promotion) the test
# must pass against BOTH models and select which to assert from the live state
# itself:
#   - TWO-TIER model (pre-cutover): staged-* sub-PR ruleset + check-staged-head
#     required on main. Invariants I1–I7 below.
#   - MERGE-QUEUE model (post-cutover): a `merge_queue` rule on the MAIN
#     ruleset; check-staged-head retired. Invariants M1/M2 below (+ shared I7).
#
# Mode discriminator (FAIL-CLOSED): MQ mode is selected IFF the MAIN ruleset
# payload contains a `merge_queue` rule. Everything else falls into the two-tier
# branch (the closed default). Rationale: `merge_queue` on main is the single
# defining feature MQ-6 provisions; it does not exist pre-cutover and is NOT one
# of the two-tier invariants, so a genuine two-tier regression (e.g. someone
# drops check-staged-head from the live two-tier ruleset) cannot masquerade as
# "we must be in MQ mode" — absent a merge_queue rule the test stays in the
# two-tier branch and fails loudly on the missing check-staged-head (I6).
#
# Drift detection: if any PR touching provision-ruleset.sh, the workflows
# directory, the runbook, or this test file causes the live ruleset state to
# diverge from the design for the ACTIVE model, this test fails.
#
# Inputs (env vars consumed; gh CLI auth required for the live path):
#   GH_REPO          owner/name of the repo to inspect (default:
#                    navapbc/digital-service-orchestra)
#   DSO_RULESET_FIXTURE_DIR  (test-only) when set, ruleset JSON is read from
#                    $DIR/rulesets.json, $DIR/main.json, $DIR/subpr.json instead
#                    of the live GitHub API. Used by
#                    test-ruleset-design-invariants-modes.sh to exercise both
#                    models + drift cases offline. Never set in CI/production.
#   gh authentication: in CI the gh CLI uses GH_TOKEN (a GitHub Actions
#                    short-lived permission-scoped token); locally it uses
#                    the user's gh auth login state. The Rulesets API
#                    requires `administration: read` on the Actions token,
#                    or `repo` scope on a personal access token.
#
# TWO-TIER invariants asserted (MAIN ruleset has NO merge_queue rule):
#   I1: sub-PR ruleset's include is exactly ["refs/heads/staged-*"]
#   I2: sub-PR ruleset's required check is "review-sub-pr"
#   I3: sub-PR ruleset has do_not_enforce_on_create=true
#   I4: sub-PR ruleset's containment — this identity cannot force-merge
#   I5: sub-PR ruleset enforcement is "active"
#   I6: main ruleset's required_status_checks includes "check-staged-head"
#   I7: main ruleset containment — this identity cannot force-merge
#
# MERGE-QUEUE invariants asserted (MAIN ruleset HAS a merge_queue rule):
#   M1: main ruleset's merge_queue parameters match the ADR-0019 GO-scoped config
#   M2: main ruleset's required_status_checks does NOT include "check-staged-head"
#   I7: main ruleset containment — this identity cannot force-merge (shared)
#   NOTE: the disposition of the sub-PR / session-branch review-sub-pr
#   enforcement ruleset under MQ is finalized by MQ-4/MQ-6 (STORY_PR_BASE move).
#   MQ-6 extends this branch with the final sub-PR-ruleset assertion in lockstep
#   with the live re-provision; MQ-3 deliberately asserts only the unambiguous
#   MAIN-ruleset facts so it cannot bake in a guess about undecided MQ-4 work.
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

# Test-only offline injection. When set, ruleset JSON is read from files rather
# than the live API. Empty in CI/production (the live path runs).
FIXTURE_DIR="${DSO_RULESET_FIXTURE_DIR:-}"
_in_fixture_mode() { [[ -n "$FIXTURE_DIR" ]]; }

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
        # `|| true` is load-bearing here, NOT redundant: cleanup runs under an
        # EXIT trap, where Bash uses the trap's last command status as the
        # script's exit code. A transient `rm -f` failure (permission flake,
        # FS error) would otherwise mask a passing test run with a non-zero
        # exit. The 2>/dev/null + `|| true` pair guarantees the EXIT trap is
        # a no-op for exit-code purposes regardless of cleanup outcome.
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

if ! _in_fixture_mode; then
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
fi

# ── Ruleset payload fetch (fixture-aware) ────────────────────────────────────
# In fixture mode, read JSON from files; otherwise hit the live API with the
# existing explicit error handling. Both paths populate the same variables.
if _in_fixture_mode; then
    if [[ ! -f "$FIXTURE_DIR/rulesets.json" ]]; then
        _precondition_not_met "fixture mode: $FIXTURE_DIR/rulesets.json missing" \
            "Provide rulesets.json (the list) in the fixture directory."
    fi
    RULESETS_JSON="$(cat "$FIXTURE_DIR/rulesets.json")"
else
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
fi

# Parse with explicit error surfacing.
if ! echo "$RULESETS_JSON" | python3 -c "import sys,json; json.load(sys.stdin)" >/dev/null 2>&1; then
    _precondition_not_met "rulesets response is not valid JSON" \
        "Inspect the raw response: gh api repos/${GH_REPO}/rulesets"
fi

# ── Resolve a ruleset ID by name from the list (rc 0 found / 3 not-found) ────
_resolve_ruleset_id() {
    local target="$1"
    echo "$RULESETS_JSON" | DSO_RULESET_NAME="$target" python3 -c "
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
"
}

# ── Fetch a full ruleset payload by id+kind (fixture-aware) ──────────────────
# kind ∈ {main, subpr} → fixture file name. Echoes the payload on stdout; rc
# from source. On a live gh failure the captured gh stderr is surfaced to the
# script's stderr (fd 2) BEFORE returning, so callers' PRECONDITION_NOT_MET
# messages don't lose the underlying diagnostic (403 / network / malformed body).
_fetch_ruleset_payload() {
    local id="$1" kind="$2"
    if _in_fixture_mode; then
        local f="$FIXTURE_DIR/${kind}.json"
        [[ -f "$f" ]] || { echo "fixture mode: $f missing" >&2; return 1; }
        cat "$f"
        return 0
    fi
    local _stderr
    _stderr=$(mktemp "${TMPDIR:-/tmp}/dso-ruleset-${kind}.XXXXXX"); _track_tmp "$_stderr"
    local _payload _rc
    _payload="$(gh api "repos/${GH_REPO}/rulesets/${id}" 2>"$_stderr")"; _rc=$?
    if [[ $_rc -ne 0 ]]; then
        echo "gh api repos/${GH_REPO}/rulesets/${id} failed (rc=${_rc}): $(cat "$_stderr")" >&2
        rm -f "$_stderr"
        return "$_rc"
    fi
    rm -f "$_stderr"
    echo "$_payload"
}

# Validate a fetched ruleset payload is parseable JSON; PRECONDITION on failure.
# Guards against a non-JSON gh error page silently flowing into the mode
# discriminator / assertions as confusing empty-field failures.
_require_json() {
    local payload="$1" label="$2" hint="$3"
    if ! echo "$payload" | python3 -c "import sys,json; json.load(sys.stdin)" >/dev/null 2>&1; then
        _precondition_not_met "${label} payload is not valid JSON" "$hint"
    fi
}

# ── Resolve + fetch the MAIN ruleset (required in BOTH models) ───────────────
_extract_stderr=$(mktemp "${TMPDIR:-/tmp}/dso-ruleset-extract.XXXXXX"); _track_tmp "$_extract_stderr"
MAIN_ID="$(_resolve_ruleset_id "$MAIN_RULESET_NAME" 2>"$_extract_stderr")"
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
_pass "test_main_ruleset_exists"

MAIN_FULL="$(_fetch_ruleset_payload "$MAIN_ID" main)"; _main_fetch_rc=$?
if [[ $_main_fetch_rc -ne 0 ]] || [[ -z "$MAIN_FULL" ]]; then
    _precondition_not_met "fetching main ruleset payload failed (id=${MAIN_ID})" \
        "Verify the ruleset ID ${MAIN_ID} is accessible (or fixture main.json present)."
fi
_require_json "$MAIN_FULL" "main ruleset" \
    "Inspect: gh api repos/${GH_REPO}/rulesets/${MAIN_ID}"

# ── Mode discriminator: MQ iff MAIN ruleset has a merge_queue rule ───────────
if echo "$MAIN_FULL" | python3 -c "
import json,sys
d = json.load(sys.stdin)
sys.exit(0 if any(r.get('type')=='merge_queue' for r in d.get('rules',[])) else 1)
"; then
    MODE="mq"
else
    MODE="two_tier"
fi
echo "MODE: $MODE"

# ── I7 (shared): main-ruleset containment — this identity cannot force-merge ─
# Outcome-based: asserts the *running token's* bypass capability, so the check
# must run as the non-admin CI/agent identity (DSO_RULESETS_READ_TOKEN). A human
# bypass actor running it locally will correctly see they CAN bypass and the
# check will fail — that is expected; the invariant is about the enforcement
# identity. We deliberately do NOT introspect bypass_actors (admin-read-only).
_assert_main_containment() {
    local main_cub
    main_cub="$(echo "$MAIN_FULL" | python3 -c "import json,sys; print(json.load(sys.stdin).get('current_user_can_bypass'))")"
    if [[ "$main_cub" == "never" ]]; then
        _pass "I7_main_not_force_mergeable_by_this_identity"
    else
        _fail "I7_main_not_force_mergeable_by_this_identity" \
            "current_user_can_bypass=$main_cub (expected 'never' — this token can force-merge to main)"
    fi
}

if [[ "$MODE" == "mq" ]]; then
    # ── MERGE-QUEUE model assertions ─────────────────────────────────────────

    # M1: merge_queue parameters match the ADR-0019 GO-scoped config exactly
    # (same shape locked by R11 in test-ruleset-provisioner-roundtrip.sh).
    if echo "$MAIN_FULL" | python3 -c "
import json,sys
d = json.load(sys.stdin)
mq = next((r for r in d.get('rules', []) if r.get('type')=='merge_queue'), None)
params = mq.get('parameters') if mq else None
want = {'merge_method':'MERGE','max_entries_to_build':1,'max_entries_to_merge':1,
        'min_entries_to_merge':1,'min_entries_to_merge_wait_minutes':5,
        'check_response_timeout_minutes':60,'grouping_strategy':'ALLGREEN'}
# Explicit malformed-guard: a present-but-malformed merge_queue rule (params
# missing / not a dict) must FAIL, never silently compare-equal. isinstance
# makes the None/non-dict case unambiguous rather than relying on None!=want.
sys.exit(0 if isinstance(params, dict) and params == want else 1)
"; then
        _pass "M1_main_has_merge_queue_rule"
    else
        _fail "M1_main_has_merge_queue_rule" \
            "merge_queue rule absent or parameters diverge from the ADR-0019 GO-scoped config"
    fi

    # M2: check-staged-head is RETIRED — must NOT be a required check on main.
    if echo "$MAIN_FULL" | python3 -c "
import json,sys
d = json.load(sys.stdin)
for r in d.get('rules', []):
    if r.get('type') == 'required_status_checks':
        checks = [c.get('context') for c in r.get('parameters', {}).get('required_status_checks', [])]
        sys.exit(1 if 'check-staged-head' in checks else 0)
sys.exit(0)
"; then
        _pass "M2_main_no_check_staged_head"
    else
        _fail "M2_main_no_check_staged_head" \
            "check-staged-head is still required on main under the MQ model (retire it in the cutover)"
    fi

    _assert_main_containment
else
    # ── TWO-TIER model assertions (pre-cutover) ──────────────────────────────
    # Resolve + fetch the sub-PR ruleset (required only in the two-tier model).
    _extract_stderr=$(mktemp "${TMPDIR:-/tmp}/dso-ruleset-extract.XXXXXX"); _track_tmp "$_extract_stderr"
    SUB_PR_ID="$(_resolve_ruleset_id "$SUB_PR_RULESET_NAME" 2>"$_extract_stderr")"
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
    _pass "test_sub_pr_ruleset_exists"

    SUB_PR_FULL="$(_fetch_ruleset_payload "$SUB_PR_ID" subpr)"; _sub_fetch_rc=$?
    if [[ $_sub_fetch_rc -ne 0 ]] || [[ -z "$SUB_PR_FULL" ]]; then
        _precondition_not_met "fetching sub-PR ruleset payload failed (id=${SUB_PR_ID})" \
            "Verify the ruleset ID ${SUB_PR_ID} is accessible (or fixture subpr.json present)."
    fi
    _require_json "$SUB_PR_FULL" "sub-PR ruleset" \
        "Inspect: gh api repos/${GH_REPO}/rulesets/${SUB_PR_ID}"

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

    # I4 (outcome-based): verify the CONTAINMENT OUTCOME, not the bypass-actor
    # config. `current_user_can_bypass` reports what the *running token* may do.
    # Asserting "never" proves THIS identity cannot force-merge past the sub-PR
    # gate. Run as the non-admin CI/agent identity (DSO_RULESETS_READ_TOKEN).
    sub_cub="$(echo "$SUB_PR_FULL" | python3 -c "import json,sys; print(json.load(sys.stdin).get('current_user_can_bypass'))")"
    if [[ "$sub_cub" == "never" ]]; then
        _pass "I4_sub_pr_not_force_mergeable_by_this_identity"
    else
        _fail "I4_sub_pr_not_force_mergeable_by_this_identity" \
            "current_user_can_bypass=$sub_cub (expected 'never' — this token can force-merge into staged-*)"
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

    _assert_main_containment
fi

# (Bypass-actor *identity* introspection intentionally omitted: bypass_actors is
# admin-read-only, so a least-privilege CI token cannot see it. Per design we
# verify the no-force-merge OUTCOME via current_user_can_bypass (I4/I7) rather
# than the specific actor config. The named-human bypass actor is set by the
# provisioner from ruleset.bypass_user_id; its correctness is an admin-run /
# provisioning-time concern, not a per-PR CI check.)

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
