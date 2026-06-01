#!/usr/bin/env bash
# scripts/ci/assert-review-liveness.sh (under the DSO plugin root)
#
# F3 fix: the prior "Assert review liveness" step in ci.yml was gated on
# `if: needs.changes.outputs.code_changed == 'true'`. This meant the very
# safety net designed to catch silent-no-review regressions was itself
# silent when the upstream classifier said "no reviewable changes." A bug
# (or path-allowlist drift) in skip-review-check.sh could let reviewable
# code merge with `llm-review` reporting success and zero actual review.
#
# This script makes the liveness assertion run UNCONDITIONALLY and verify
# one of two states is true at job-end:
#
#   - code_changed=true → findings.json exists, is non-empty, contains a
#     `findings` key whose value is an array. (Existing logic.)
#
#   - code_changed=false → re-run skip-review-check.sh independently on
#     the actual PR diff and CONFIRM the upstream "all allowlisted"
#     classification. If skip-review-check.sh disagrees (returns exit 1,
#     meaning reviewable files exist), the upstream was wrong and the
#     script fails — the `llm-review` job reports failure to the required
#     check context, blocking the merge.
#
# Inputs (env vars):
#   DSO_CI_REVIEW_FINDINGS_PATH — path to the findings.json the runner
#                                  was supposed to write (required when
#                                  CODE_CHANGED=true).
#   CODE_CHANGED                  — "true" | "false". Defaults to "true"
#                                   (fail-closed) if unset.
#   GITHUB_BASE_REF, GITHUB_HEAD_REF, GITHUB_EVENT_NAME — used to compute
#                                   the diff for the cross-check path.
#
# Exit codes:
#   0 — liveness invariant holds (review ran OR diff is genuinely allowlist-only)
#   1 — invariant violated (review missing, or cross-check disagrees)

set -uo pipefail

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# CLAUDE_PLUGIN_ROOT or BASH_SOURCE fallback for portable resolution.
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$_DIR/../.." 2>/dev/null && pwd)}"

CODE_CHANGED="${CODE_CHANGED:-true}"

# ── Path A: upstream classifier said reviewable code is present ─────────────
# Existing contract — runner must have produced findings.json.
if [[ "$CODE_CHANGED" == "true" ]]; then
    F="${DSO_CI_REVIEW_FINDINGS_PATH:-}"
    if [[ -z "$F" ]]; then
        echo "ERROR [liveness]: DSO_CI_REVIEW_FINDINGS_PATH not set" >&2
        exit 1
    fi
    if [ ! -s "$F" ]; then
        echo "ERROR [liveness]: $F missing or empty — runner did not produce review output" >&2
        exit 1
    fi
    # Validate shape via python3 (no jq per plugin-script convention).
    if ! python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    sys.stderr.write(f'JSON parse error: {e}\n')
    sys.exit(1)
if not isinstance(d, dict) or 'findings' not in d or not isinstance(d['findings'], list):
    sys.exit(1)
print(len(d['findings']))
" "$F" 2>/tmp/liveness-parse-err.$$; then
        echo "ERROR [liveness]: $F malformed — 'findings' missing, not an array, or invalid JSON" >&2
        cat /tmp/liveness-parse-err.$$ 2>/dev/null >&2 || true
        rm -f /tmp/liveness-parse-err.$$
        head -c 500 "$F" 2>/dev/null | sed 's/^/  | /' >&2 || true
        exit 1
    fi
    rm -f /tmp/liveness-parse-err.$$

    # TS-1: reject the laundering skip stub. `all_scope_already_merged` means the
    # dispatcher SKIPPED review because every in-scope SHA was filtered out as
    # reachable-from-origin/main (the `comm -23` scope filter) — and reachability
    # is NOT review evidence (P9). Liveness cannot itself confirm coverage, so it
    # FAILS CLOSED here; the independent `review-coverage-invariant` check is the
    # positive coverage confirmation. NOTE: `all_commits_provenanced` is NOT
    # rejected — it comes from the verifier's G3 covering-PR review-check
    # verification, which is genuine review evidence.
    _SKIP_REASON=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(''); sys.exit(0)
print(d.get('skip_reason', '') if isinstance(d, dict) else '')
" "$F" 2>/dev/null || echo "")
    if [[ "$_SKIP_REASON" == "all_scope_already_merged" ]]; then
        echo "ERROR [liveness]: findings.json is a laundering skip stub (skip_reason=all_scope_already_merged)." >&2
        echo "ERROR [liveness]: review was SKIPPED because in-scope SHAs were filtered as reachable-from-main — reachability is NOT review (P9). Failing closed." >&2
        echo "ERROR [liveness]: the review-coverage-invariant check provides the independent coverage confirmation." >&2
        exit 1
    fi

    _COUNT=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['findings']))" "$F" 2>/dev/null || echo "?")
    echo "review liveness: ok (${_COUNT} findings)"
    exit 0
fi

# ── Path B: upstream classifier said no reviewable changes ──────────────────
# Trust-but-verify. Re-run skip-review-check.sh on the actual PR diff.
# If skip-review-check returns exit 1 here, it means at least one
# reviewable file IS in the diff — the upstream decision was wrong, and a
# review SHOULD have run. Fail loud.
echo "review liveness: code_changed=false — running independent cross-check"

# Determine the diff. Prefer PR event SHAs if available; fall back to
# GITHUB_BASE_REF / HEAD_REF.
_BASE_SHA="${DSO_BASE_SHA:-}"
_HEAD_SHA="${DSO_SESSION_HEAD:-}"
if [[ -z "$_BASE_SHA" || -z "$_HEAD_SHA" ]]; then
    if [[ -n "${GITHUB_BASE_REF:-}" ]]; then
        _BASE_SHA=$(git rev-parse "origin/${GITHUB_BASE_REF}" 2>/dev/null || echo "")
    fi
    if [[ -z "$_HEAD_SHA" ]]; then
        _HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")
    fi
fi
if [[ -z "$_BASE_SHA" || -z "$_HEAD_SHA" ]]; then
    echo "ERROR [liveness]: cannot determine BASE/HEAD SHAs for cross-check" >&2
    echo "ERROR [liveness]: DSO_BASE_SHA=${DSO_BASE_SHA:-<unset>}, DSO_SESSION_HEAD=${DSO_SESSION_HEAD:-<unset>}, GITHUB_BASE_REF=${GITHUB_BASE_REF:-<unset>}" >&2
    exit 1
fi

_CHANGED=$(git diff --name-only "${_BASE_SHA}" "${_HEAD_SHA}" 2>/dev/null || true)
if [[ -z "$_CHANGED" ]]; then
    echo "review liveness: ok (code_changed=false, diff is empty between $_BASE_SHA and $_HEAD_SHA)"
    exit 0
fi

# Run skip-review-check.sh — it exits 0 if all files are allowlisted, 1
# otherwise. Use the same DSO_FORCE_LOCAL_REVIEW=1 env the CI workflow uses
# to bypass the auto-detect-CI short-circuit.
_SKIP_SCRIPT="${_PLUGIN_ROOT}/scripts/skip-review-check.sh"
if [[ ! -x "$_SKIP_SCRIPT" ]]; then
    echo "ERROR [liveness]: skip-review-check.sh not found at $_SKIP_SCRIPT" >&2
    exit 1
fi
_SKIP_RC=0
echo "$_CHANGED" | DSO_FORCE_LOCAL_REVIEW=1 bash "$_SKIP_SCRIPT" >/dev/null 2>&1 || _SKIP_RC=$?

if [[ "$_SKIP_RC" -eq 0 ]]; then
    echo "review liveness: ok (code_changed=false confirmed — all $(echo "$_CHANGED" | wc -l | tr -d ' ') changed file(s) classified as allowlisted)"
    exit 0
fi
if [[ "$_SKIP_RC" -eq 1 ]]; then
    echo "ERROR [liveness]: upstream code_changed=false but cross-check says reviewable files are present" >&2
    echo "ERROR [liveness]: skip-review-check.sh exited 1 — at least one changed file is NOT allowlisted." >&2
    echo "Changed files:" >&2
    # Indent each line by 2 spaces without invoking sed (SC2001).
    printf '  %s\n' "${_CHANGED//$'\n'/$'\n  '}" >&2
    exit 1
fi
echo "ERROR [liveness]: skip-review-check.sh exited $_SKIP_RC (expected 0 or 1)" >&2
exit 1
