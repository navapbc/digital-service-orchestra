#!/usr/bin/env bash
# no-dormant-security-check.sh — fail-closed audit for built-but-unwired security checks.
#
# THE PATTERN THIS GUARDS (epic 588e, override-propagation / DD4): this project
# repeatedly ships a security check whose MECHANISM lands (script + tests, often
# a CLOSED story) but whose ACTIVATION — a single env var, a required-checks
# entry, a workflow wiring line — is never done. The activation step is itself an
# unguarded silent-skip: under warn-mode rollout the dormant check is invisible,
# and at the enforce-flip it surfaces as a team-wide wedge or, worse, a silent
# coverage hole. The canonical instance: the admin-exemption ledger (story 2730)
# built `ael_append`/`ael_sha_is_exempt`, but review-coverage-invariant.yml never
# set DSO_ADMIN_EXEMPTION_LEDGER, so the consult path was dead in CI.
#
# THIS AUDIT makes "is every built security check actually wired?" a machine gate.
# It is the enforce-flip (story 3ee4) prerequisite P8: 3ee4 MUST NOT flip while
# this audit is red. It runs warn during rollout and enforce at go-live, mirroring
# the other 588e checks.
#
# Predicates (each = one built check + its required activation):
#   P-AEL  admin-exemption consult path is LIVE: review-coverage-invariant.yml
#          sets DSO_ADMIN_EXEMPTION_LEDGER (else ael_sha_is_exempt is unreachable
#          in CI — the dead-on-both-ends gap DD4 closes). HARD.
#   P-CONV review-convergence-check.sh, if present, is a required check (bug 2195).
#          ADVISORY today (the wiring is owned by 2195); emitted as a ::warning::
#          so this audit can go green on the DD4 wiring alone while 2195 lands.
#
# Inputs (env):
#   DSO_DORMANT_MODE          enforce | warn (default warn)
#   DSO_COVERAGE_YML          override path (tests). Default: the repo workflow.
#   DSO_REQUIRED_CHECKS_FILE  override path (tests). Default: .github/required-checks.txt
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
_CI_YML="${DSO_CI_YML:-$_ROOT/.github/workflows/ci.yml}"
_REQUIRED="${DSO_REQUIRED_CHECKS_FILE:-$_ROOT/.github/required-checks.txt}"

[[ -f "$_COVERAGE_YML" ]] || _precondition_not_met "coverage workflow not found: $_COVERAGE_YML"

_dormant=""   # accumulates HARD dormant findings
_warned=0

# Extract the (non-empty) value DSO_ADMIN_EXEMPTION_LEDGER is set to in a workflow
# file, or empty if unset/empty. Both consumers' guards are `[[ -n "$..." ]]`, so
# a bare `DSO_ADMIN_EXEMPTION_LEDGER:` or `: ""` is effectively unset — the audit
# must report DORMANT for those too (else it fails OPEN, the silent-skip class it
# exists to catch). Strips trailing comments + surrounding quotes.
_ael_ledger_value() {
    grep -E '^[[:space:]]*DSO_ADMIN_EXEMPTION_LEDGER[[:space:]]*:' "$1" 2>/dev/null \
        | head -1 \
        | sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]+#.*$//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'\''//; s/'\''$//'
}

# ── P-AEL (HARD): the COVERAGE consumer must wire the ledger ──────────────────
# review-coverage-invariant.sh consults ael_sha_is_exempt only when the workflow
# sets DSO_ADMIN_EXEMPTION_LEDGER non-empty; else the consult path is dead and an
# admin-bypassed (FP-recovered) SHA re-wedges every later PR under enforce.
if [[ -z "$(_ael_ledger_value "$_COVERAGE_YML")" ]]; then
    _dormant+="  P-AEL: admin-exemption ledger consult path is DORMANT — "
    _dormant+="${_COVERAGE_YML##*/} does not set DSO_ADMIN_EXEMPTION_LEDGER to a "
    _dormant+="non-empty value, so review-coverage-invariant.sh:ael_sha_is_exempt "
    _dormant+="is unreachable in CI."$'\n'
fi

# ── P-AEL-PROVENANCE (HARD, 3ebb DD4 unit 5/C4): the PROVENANCE consumer too ──
# verify-session-provenance.sh (drives the llm-review DISPATCH) also consults the
# ledger; if the ci.yml "Verify session provenance" step never sets the env, an
# FP-recovered SHA re-dispatches llm-review on the downstream PR — the SECOND
# override DD4 unit 5 exists to remove. Require ci.yml to set it non-empty.
if [[ -f "$_CI_YML" ]] && [[ -z "$(_ael_ledger_value "$_CI_YML")" ]]; then
    _dormant+="  P-AEL-PROVENANCE: provenance consult path is DORMANT — "
    _dormant+="${_CI_YML##*/} does not set DSO_ADMIN_EXEMPTION_LEDGER, so "
    _dormant+="verify-session-provenance.sh:ael_sha_is_exempt is unreachable in CI "
    _dormant+="(FP-recovered SHAs re-dispatch llm-review = a second override)."$'\n'
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
