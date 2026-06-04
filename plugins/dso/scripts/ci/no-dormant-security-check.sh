#!/usr/bin/env bash
# no-dormant-security-check.sh — fail-closed audit for built-but-unwired security checks.
#
# THE PATTERN THIS GUARDS (epic 588e, override-propagation / DD4): this project
# repeatedly ships a security check whose MECHANISM lands (script + tests, often
# a CLOSED story) but whose ACTIVATION — a single env var, a required-checks
# entry, a workflow wiring line — is never done. The activation step is itself an
# unguarded silent-skip: under warn-mode rollout the dormant check is invisible,
# and at the enforce-flip it surfaces as a team-wide wedge or, worse, a silent
# coverage hole. The canonical historical instance: the admin-exemption ledger
# (story 2730) shipped a full HMAC sign/verify mechanism, but the workflow env that
# would have made it reachable in CI was never wired, so the consult path was dead.
# (That ledger was later superseded by identity-based exemption — ADR-0022.)
#
# THIS AUDIT makes "is every built security check actually wired?" a machine gate.
# It is the enforce-flip (story 3ee4) prerequisite P8: 3ee4 MUST NOT flip while
# this audit is red. It runs warn during rollout and enforce at go-live, mirroring
# the other 588e checks.
#
# Predicates (each = one built check + its required activation):
#   P-IDENTITY-EXEMPT  identity-based admin exemption is LIVE (ADR-0022, supersedes
#          the HMAC ledger): a designated bypass-actor resolves from
#          ruleset.bypass_user_ids / bypass_user_id, so a covering PR merged by an
#          admin counts as reviewed-equivalent in BOTH gates. If none resolves the
#          exemption is dormant (every admin bypass re-wedges the next PR). HARD.
#   P-CONV review-convergence-check.sh, if present, is a required check (bug 2195).
#          ADVISORY today (the wiring is owned by 2195); emitted as a ::warning::
#          so this audit can go green while 2195 lands.
#
# Inputs (env):
#   DSO_DORMANT_MODE          enforce | warn (default warn)
#   DSO_COVERAGE_YML          override path (tests). Default: the repo workflow.
#   DSO_REQUIRED_CHECKS_FILE  override path (tests). Default: .github/required-checks.txt
#   DSO_BYPASS_CONFIG_FILE    override config for bypass-actor resolution (tests).
#
# Exit codes:
#   0  no dormant HARD predicate (or warn mode)
#   1  a HARD predicate is dormant (enforce mode) — built check is unwired
#   78 precondition not met (a file the audit needs is missing)

set -uo pipefail

_precondition_not_met() { echo "PRECONDITION_NOT_MET: $1" >&2; exit 78; }

MODE="${DSO_DORMANT_MODE:-warn}"
_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # for sibling-script presence checks
_COVERAGE_YML="${DSO_COVERAGE_YML:-$_ROOT/.github/workflows/review-coverage-invariant.yml}"
_REQUIRED="${DSO_REQUIRED_CHECKS_FILE:-$_ROOT/.github/required-checks.txt}"

[[ -f "$_COVERAGE_YML" ]] || _precondition_not_met "coverage workflow not found: $_COVERAGE_YML"

_dormant=""   # accumulates HARD dormant findings
_warned=0

# ── P-IDENTITY-EXEMPT (HARD, ADR-0022): a bypass-actor must be configured ─────
# Admin exemption is identity-based (supersedes the HMAC ledger): a covering PR
# merged by a designated bypass-actor (ruleset.bypass_user_ids / bypass_user_id) is
# reviewed-equivalent in BOTH gates (review-coverage-invariant + verify-session-
# provenance, via rc_sha_is_reviewed / the G3 loop). If NO bypass-actor resolves,
# the exemption path is DORMANT — every admin web-UI bypass re-wedges the next PR
# under enforce (a second override), the exact silent-skip this audit exists to
# catch. Require a non-empty, VALIDATED bypass-actor set (the helper drops
# malformed tokens, so this also catches an all-garbage config).
_bas_lib="$_SELF_DIR/../lib/bypass-actor-set.sh"
_bypass_ids=""
if [[ -f "$_bas_lib" ]]; then
    # shellcheck source=../lib/bypass-actor-set.sh
    source "$_bas_lib"
    _bypass_ids="$(bas_bypass_actor_ids 2>/dev/null || true)"
fi
if [[ -z "$_bypass_ids" ]]; then
    _dormant+="  P-IDENTITY-EXEMPT: identity-based admin exemption is DORMANT — no "
    _dormant+="bypass-actor resolves from ruleset.bypass_user_ids / bypass_user_id, so "
    _dormant+="a covering PR merged by an admin is never recognized as reviewed-"
    _dormant+="equivalent — FP-recovered SHAs re-wedge every later PR (a second override)."$'\n'
fi

# ── P-CONV (ADVISORY): review-convergence-check.sh should be a required check ──
# Built by the workflow-stability work but wired nowhere (bug 2195). Advisory
# until 2195 lands so this audit can pass on the DD4 wiring alone.
if [[ -f "$_SELF_DIR/review-convergence-check.sh" ]]; then
    if [[ ! -f "$_REQUIRED" ]] || ! grep -qE '(^|[[:space:]])review-convergence' "$_REQUIRED" 2>/dev/null; then
        echo "::warning::no-dormant-security-check: review-convergence-check.sh is present but not in required-checks (bug 2195) — review-loop oscillation has no enforced brake" >&2
        _warned=1
    fi
fi

if [[ -z "$_dormant" ]]; then
    [[ "$_warned" -eq 1 ]] && echo "no-dormant-security-check: ok (no HARD dormant check; 1 advisory warning above)" \
                          || echo "no-dormant-security-check: ok (all built security checks are wired)"
    exit 0
fi

echo "ERROR [no-dormant-security-check]: a built security check is UNWIRED (dormant) — it will not run/enforce despite existing:" >&2
printf '%s' "$_dormant" >&2
if [[ "$MODE" == "warn" ]]; then
    echo "::warning::no-dormant-security-check found a dormant security check — MODE=warn (not blocking this run)"
    exit 0
fi
exit 1
