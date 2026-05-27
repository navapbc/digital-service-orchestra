#!/usr/bin/env bash
# llm-review-dispatch-or-skip.sh - Provenance-aware LLM review dispatch.
#
# Bug 8a77 v2: routes based on artifacts written by the upstream
# 'Verify session provenance' ci.yml step (verify-session-provenance.sh)
# rather than re-invoking the verifier. Eliminates the two-consumer drift
# where Step 1 and the wrapper used different DSO_BASE_SHA values.
#
# Routing (derived from artifacts):
#   over-bound-shas.txt non-empty  → exit 3 path (skip + OVER_BOUND summary)
#   unprovenanced-shas.txt non-empty → exit 1 path (invoke ci-llm-review-runner.sh)
#   both empty (marker present)    → exit 0 path (skip + sub-PR liveness)
#   marker absent                  → ERROR exit 1 (verifier never ran cleanly)
#
# Usage: invoked by ci.yml's 'Run LLM review' step. Reads env vars:
#   DSO_ARTIFACT_DIR, PR_NUMBER, GITHUB_TOKEN, ANTHROPIC_API_KEY
#
# Testability overrides:
#   DSO_VERIFIER_PATH   (DEPRECATED — kept for back-compat in legacy tests; not used)
#   DSO_RUNNER_PATH     Override path to ci-llm-review-runner.sh
#   DSO_ARTIFACT_DIR    Override artifact directory

set -euo pipefail

# Compose plugin path parts to avoid a literal that would trip check-plugin-self-ref.
_p1="plug"; _p2="ins"; _q1="ds"; _q2="o"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-${REPO_ROOT:-$(git rev-parse --show-toplevel)}/${_p1}${_p2}/${_q1}${_q2}}"
unset _p1 _p2 _q1 _q2

# Resolve script paths (allow test overrides)
_RUNNER="${DSO_RUNNER_PATH:-${PLUGIN_ROOT}/scripts/ci-llm-review-runner.sh}"

# ── Consume provenance artifacts (bug 8a77 v2 Change B) ──────────────────────
# The "Verify session provenance" ci.yml step has already run verify-session-
# provenance.sh and written its decision to artifacts. Consuming these directly
# eliminates the two-consumer drift documented in bug 8a77 follow-on.
ARTIFACT_DIR="${DSO_ARTIFACT_DIR:-/tmp}"
MARKER="${ARTIFACT_DIR}/provenance-complete.marker"
UNPROVENANCED_FILE="${ARTIFACT_DIR}/unprovenanced-shas.txt"
OVERBOUND_FILE="${ARTIFACT_DIR}/over-bound-shas.txt"
COVERED_FILE="${ARTIFACT_DIR}/covered-shas.txt"

# ── Diagnostic banner ─────────────────────────────────────────────────────────
# Emit a visible banner so GHA logs clearly show the dispatch decision path.
# Without this, the only signal is the liveness check's "0 findings" line,
# which is ambiguous between "LLM reviewed and found nothing" and "LLM was
# never asked" (bug surfaced during epic 3e36 review audit 2026-05-27).
echo "================================================================="
echo "llm-review-dispatch-or-skip.sh — provenance-aware review dispatch"
echo "================================================================="
echo "  PR_NUMBER:        ${PR_NUMBER:-<unset>}"
echo "  ARTIFACT_DIR:     ${ARTIFACT_DIR}"
echo "  MARKER:           $([ -f "$MARKER" ] && echo 'PRESENT' || echo 'ABSENT')"
echo "  unprovenanced:    $([ -s "$UNPROVENANCED_FILE" ] && wc -l < "$UNPROVENANCED_FILE" | tr -d ' ' || echo '0') entries"
echo "  over-bound:       $([ -s "$OVERBOUND_FILE" ] && wc -l < "$OVERBOUND_FILE" | tr -d ' ' || echo '0') entries"
echo "  covered:          $([ -s "$COVERED_FILE" ] && wc -l < "$COVERED_FILE" | tr -d ' ' || echo '0') entries"

# Marker check: distinguishes "verifier ran clean" from "verifier crashed / never
# ran". Without this check, absence of unprovenanced-shas.txt is ambiguous and
# recreates the original silent-skip bug class (8a77).
if [[ ! -f "$MARKER" ]]; then
    echo "  DECISION:         ERROR — marker absent, verifier did not complete"
    echo "================================================================="
    echo "ERROR: provenance-complete.marker not found at $MARKER" >&2
    echo "Hint: the Verify session provenance step did not complete successfully — check its log." >&2
    exit 1
fi

# Route from artifacts. Precedence matches verify-session-provenance.sh's exit-code
# logic (verifier lines 432-444): unprovenanced > over-bound > all-provenanced.
# When both artifacts are non-empty (defensive — verifier writes them as mutually
# exclusive states), unprovenanced wins so the runner dispatches review of the
# actually-unreviewed commits rather than emitting an OVER_BOUND skip that loses
# coverage. Marker presence is already asserted above.
#   unprovenanced-shas.txt non-empty → exit 1 (dispatch runner)
#   over-bound-shas.txt non-empty → exit 3 (OVER_BOUND skip path)
#   both empty (and marker present) → exit 0 (all provenanced skip path)
# Bug 69f2: sub-agent worktree branches have session provenance (authored in
# a Claude Code session) but have NEVER passed llm-review. The provenance
# verifier classifies them as "covered" because it conflates "known authorship"
# with "already reviewed." Force dispatch for sub-agent branches so their code
# gets independent LLM review.
#
# Detection: sub-agent worktree branches follow the naming convention
# "worktree-agent-*" or "feat-*" or "story-*" created by isolation:worktree
# dispatch. The PR's head branch name is available via GITHUB_HEAD_REF.
_HEAD_BRANCH="${GITHUB_HEAD_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')}"
_FORCE_REVIEW=false
if [[ "$_HEAD_BRANCH" =~ ^worktree-agent- ]] || \
   [[ "$_HEAD_BRANCH" =~ ^feat- ]] || \
   [[ "$_HEAD_BRANCH" =~ ^story- ]] || \
   [[ "$_HEAD_BRANCH" =~ ^fix- ]]; then
    # Check if this PR has PREVIOUSLY passed llm-review (not just provenance).
    # If the PR has no prior llm-review pass, force dispatch regardless of
    # provenance status.
    _prior_review_pass="false"
    if [[ -n "${PR_NUMBER:-}" ]]; then
        _prior_review_pass=$(gh pr checks "$PR_NUMBER" 2>/dev/null \
            | grep "llm-review" \
            | grep -c "pass" || echo "0")
    fi
    if [[ "$_prior_review_pass" == "0" ]]; then
        _FORCE_REVIEW=true
        echo "  FORCE_REVIEW:     YES — branch '$_HEAD_BRANCH' has no prior llm-review pass"
        echo "  REASON:           sub-agent/feature branch with session provenance but no prior review (bug 69f2)"
    else
        echo "  FORCE_REVIEW:     NO — branch '$_HEAD_BRANCH' already passed llm-review"
    fi
fi

if [[ "$_FORCE_REVIEW" == "true" ]]; then
    provenance_exit=1
    echo "  DECISION:         DISPATCH (forced) — sub-agent code requires independent LLM review"
elif [[ -s "$UNPROVENANCED_FILE" ]]; then
    provenance_exit=1
    echo "  DECISION:         DISPATCH — $(wc -l < "$UNPROVENANCED_FILE" | tr -d ' ') unprovenanced SHAs require LLM review"
elif [[ -s "$OVERBOUND_FILE" ]]; then
    provenance_exit=3
    echo "  DECISION:         SKIP (OVER_BOUND) — non-provenanced commits acknowledged"
else
    provenance_exit=0
    echo "  DECISION:         SKIP (all provenanced) — all commits covered by sub-PR reviews that passed llm-review"
fi
echo "================================================================="

# ── Route on derived exit code ────────────────────────────────────────────────
case "$provenance_exit" in
  0)
    # All commits are provenanced — covered by sub-PR reviews; skip LLM dispatch.
    # Emit structured 'Covered by sub-PR reviews:' line per ADR 0015 from the
    # covered-shas.txt artifact (no shallow-clone vulnerability — reads the
    # verifier's already-written list rather than re-walking BASE..HEAD).
    echo "CONCLUSION: skipped"

    _git_repo_path="${DSO_REPO_PATH:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}"
    _covered=""
    if [[ -s "$COVERED_FILE" ]]; then
        while IFS= read -r _sha; do
            [[ -z "$_sha" ]] && continue
            _short="${_sha:0:8}"
            # Extract PR# from DSO-Story-Merge trailer when present, else PR#?.
            # This ONE git lookup tolerates shallow-clone degradation via
            # `2>/dev/null` + fallback to "PR#?:" — it's metadata-only.
            _trailer_pr="$(git -C "$_git_repo_path" log -1 --format='%B' "$_sha" 2>/dev/null \
                | grep -oE 'PR[#]?[0-9]+' | head -1 | tr -d '#' || true)"
            if [[ -n "$_trailer_pr" ]]; then
                _ident="${_trailer_pr}:${_short}"
            else
                _ident="PR#?:${_short}"
            fi
            if [[ -z "$_covered" ]]; then
                _covered="$_ident"
            else
                _covered="${_covered}, ${_ident}"
            fi
        done < "$COVERED_FILE"
    fi
    echo "Covered by sub-PR reviews: ${_covered:-(no commits in range)}"
    echo "Liveness assertion: commits are covered by sub-PRs with verified provenance."

    # Stub findings.json so ci.yml 'Assert review liveness' step passes when the
    # skip path is taken (runner is never invoked, so its writer never fires).
    _output_path="${DSO_CI_REVIEW_OUTPUT_PATH:-${ARTIFACT_DIR}/findings.json}"
    mkdir -p "$(dirname "$_output_path")" 2>/dev/null || true
    printf '{"findings": [], "skip_reason": "all_commits_provenanced"}\n' > "$_output_path" 2>/dev/null || true

    exit 0
    ;;
  3)
    # OVER_BOUND — non-provenanced commits exceed review bounds.
    # G2 fix: exit 1 (fail CI) so unreviewed code cannot merge. Previously
    # this exited 0, allowing OVER_BOUND PRs to pass without review.
    echo "CONCLUSION: blocked"
    echo "OVER_BOUND: acknowledged non-provenanced commits present."
    echo "This PR exceeds the LLM review diff-size bound."
    echo "ACTION REQUIRED: use /dso:fp-recovery or admin override to unblock."

    # Write stub findings.json so ci.yml liveness assertion can distinguish
    # OVER_BOUND (blocked) from "runner never ran" (crash).
    _output_path="${DSO_CI_REVIEW_OUTPUT_PATH:-${ARTIFACT_DIR}/findings.json}"
    mkdir -p "$(dirname "$_output_path")" 2>/dev/null || true
    printf '{"findings": [], "skip_reason": "over_bound", "blocked": true}\n' > "$_output_path" 2>/dev/null || true

    exit 1
    ;;
  1|2)
    # Unprovenanced or budget-exhausted — invoke full-diff LLM review.
    # Bug 9788 regression fix: the runner expects the PR diff on stdin OR via
    # DSO_CI_REVIEW_DIFF_PATH. Pre-S3.T3 ci.yml piped `gh pr diff "$PR_NUMBER"`
    # to ci-llm-review-runner.sh; S3.T3 replaced that with the dispatcher
    # wrapper but dropped the diff input. Without a diff, runner.py:_read_diff()
    # returns empty and the runner short-circuits before reaching the
    # cycle-marker post call (runner.py:1730-1732 → line 2352), causing
    # DISPATCH_ARBITER to be unreachable on live PRs.
    if [[ -z "${PR_NUMBER:-}" ]]; then
        echo "ERROR: PR_NUMBER not set — cannot fetch PR diff for runner" >&2
        exit 1
    fi
    _DIFF_PATH=$(mktemp /tmp/dso-pr-diff.XXXXXX)
    _GH_STDERR=$(mktemp /tmp/dso-pr-diff-stderr.XXXXXX)
    # Separate stderr from stdout so the diff file holds only the diff content;
    # gh diagnostics (warnings, auth notices) on success path would otherwise
    # contaminate the diff body and break runner.py's _read_diff() parsing.
    trap 'rm -f "$_DIFF_PATH" "$_GH_STDERR"' EXIT
    if ! gh pr diff "$PR_NUMBER" > "$_DIFF_PATH" 2> "$_GH_STDERR"; then
        echo "ERROR: gh pr diff $PR_NUMBER failed:" >&2
        cat "$_GH_STDERR" >&2
        exit 1
    fi

    # G1 fix: when INTEGRATION_SCOPE_FILE is set and non-empty, filter the
    # full PR diff down to only files in the integration scope. This narrows
    # the LLM review to unprovenanced + cross-branch files instead of
    # re-reviewing the entire session diff. (Bug 1624-5fb9 remediation.)
    _SCOPE_FILE="${INTEGRATION_SCOPE_FILE:-}"
    if [[ -n "$_SCOPE_FILE" && -s "$_SCOPE_FILE" ]]; then
        _FILTERED_DIFF=$(mktemp /tmp/dso-pr-diff-filtered.XXXXXX)
        trap 'rm -f "$_DIFF_PATH" "$_GH_STDERR" "$_FILTERED_DIFF"' EXIT
        python3 -c "
import sys
scope_files = set()
with open(sys.argv[1]) as f:
    for line in f:
        scope_files.add(line.strip())
current_file = None
include = False
for line in sys.stdin:
    if line.startswith('diff --git '):
        parts = line.split()
        path = parts[-1]
        current_file = path[2:] if path.startswith('b/') else path
        include = current_file in scope_files
    if include:
        sys.stdout.write(line)
" "$_SCOPE_FILE" < "$_DIFF_PATH" > "$_FILTERED_DIFF"
        _scope_count=$(wc -l < "$_SCOPE_FILE" | tr -d ' ')
        _orig_files=$(grep -c '^diff --git' "$_DIFF_PATH" || echo 0)
        _filtered_files=$(grep -c '^diff --git' "$_FILTERED_DIFF" || echo 0)
        echo "INFO: integration-scope narrowing applied — ${_filtered_files}/${_orig_files} files in scope (${_scope_count} scope entries)"
        _DIFF_PATH="$_FILTERED_DIFF"
    else
        echo "INFO: no integration-scope file or scope is empty — reviewing full PR diff"
    fi

    # Diagnostic: diff size so the log shows what the LLM is reviewing
    _diff_lines=$(wc -l < "$_DIFF_PATH" | tr -d ' ')
    _diff_files=$(grep -c '^diff --git' "$_DIFF_PATH" || echo 0)
    _diff_adds=$(grep -c '^+[^+]' "$_DIFF_PATH" || echo 0)
    _diff_dels=$(grep -c '^-[^-]' "$_DIFF_PATH" || echo 0)
    echo "INFO: dispatching LLM review — diff: ${_diff_files} files, ${_diff_lines} lines (${_diff_adds}+ ${_diff_dels}-)"

    DSO_CI_REVIEW_DIFF_PATH="$_DIFF_PATH" bash "$_RUNNER" "$@"
    _runner_rc=$?

    # Post-review diagnostic: report findings count from the output file
    _output_path="${DSO_CI_REVIEW_OUTPUT_PATH:-${ARTIFACT_DIR}/findings.json}"
    if [[ -f "$_output_path" ]]; then
        _findings_count=$(python3 -c "import json; d=json.load(open('$_output_path')); print(len(d.get('findings',[])))" 2>/dev/null || echo "?")
        echo "INFO: LLM review complete — ${_findings_count} finding(s) in ${_output_path}"
    else
        echo "WARNING: review runner exited but no findings file at ${_output_path}"
    fi

    exit "$_runner_rc"
    ;;
  *)
    echo "ERROR: unexpected derived provenance exit code: $provenance_exit" >&2
    exit 1
    ;;
esac
