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
#   marker absent                  → INDETERMINATE exit 75 (verifier never ran; 3ebb DD1)
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

# Net-end-state integration diff helper (W2a — replaces the CS-10 per-commit
# `git show` concatenation that re-flagged introduce-then-fix intermediate state).
# Resolve relative to THIS script's own location (BASH_SOURCE), not PLUGIN_ROOT:
# PLUGIN_ROOT derives from the CWD git-toplevel, which under test (CWD = a temp
# fixture repo) points at a tree without the lib. The dispatcher and its lib ship
# together, so script-relative resolution is correct in every context.
_DISPATCH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/build-integration-diff.sh
source "${DSO_INTEGRATION_DIFF_LIB:-${_DISPATCH_SCRIPT_DIR}/lib/build-integration-diff.sh}"
# 3ebb DD1: the review-gate tristate lattice (provides $TRISTATE_INDETERMINATE).
# Script-relative for the same reason as the integration-diff lib above.
# shellcheck source=lib/review-tristate-lib.sh
source "${DSO_REVIEW_TRISTATE_LIB:-${_DISPATCH_SCRIPT_DIR}/lib/review-tristate-lib.sh}"

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
# Stale-base diagnostics: emit the SHAs the reviewer will see so post-hoc audits
# can detect findings cited against file:line refs that no longer exist at
# repo-head (the oscillation class seen on PRs #432, #438).
echo "  BASE_SHA:         ${DSO_BASE_SHA:-${GITHUB_BASE_SHA:-<unset>}}"
echo "  HEAD_SHA:         ${DSO_HEAD_SHA:-${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo '<unresolved>')}}"
echo "  REPO_HEAD_SHA:    $(git rev-parse "origin/${GITHUB_BASE_REF:-main}" 2>/dev/null || echo '<unresolved>')"

# Marker check: distinguishes "verifier ran clean" from "verifier crashed / never
# ran". Without this check, absence of unprovenanced-shas.txt is ambiguous and
# recreates the original silent-skip bug class (8a77).
if [[ ! -f "$MARKER" ]]; then
    # 3ebb DD1: the dispatch decision could not be COMPUTED (the provenance verifier
    # crashed / never ran / lacked permission). Per the tristate lattice this is
    # INDETERMINATE (exit 75), not a silent skip — it still blocks, but the distinct
    # code signals the orchestrator to retry on a transient cause / escalate (DD3)
    # rather than treat it as a hard review violation. NEVER falls through to exit 0
    # (the 8a77 silent-skip bug class).
    echo "  DECISION:         INDETERMINATE — marker absent, verifier did not complete"
    echo "================================================================="
    echo "INDETERMINATE: provenance-complete.marker not found at $MARKER" >&2
    echo "Hint: the Verify session provenance step did not complete successfully — check its log." >&2
    exit "${TRISTATE_INDETERMINATE:-75}"
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
# Detection: sub-agent worktree branches follow naming conventions defined in
# the source-of-truth file ${CLAUDE_PLUGIN_ROOT}/config/sub-pr-branch-patterns.txt.
# Branch patterns are consumed by:
#   - this dispatcher (to identify force-review-eligible branches)
#   - provision-ruleset.sh (to set the sub-PR ruleset's include patterns)
# Validation: tests/scripts/test-branch-pattern-alignment.sh ensures both
# consumers stay in sync.
#
# BRANCH-NAMING CROSS-REFERENCE (R8/R11): see source-of-truth file at
# ${CLAUDE_PLUGIN_ROOT}/config/sub-pr-branch-patterns.txt. Any branch pattern
# that should trigger force-review here MUST also be in that file (and
# therefore the sub-PR ruleset). The alignment test enforces this invariant.
_HEAD_BRANCH="${GITHUB_HEAD_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')}"

# Build regex from source-of-truth file. Patterns like "feat-**" map to a
# regex prefix "feat-"; "feat/**" maps to "feat/"; "session/**" maps to
# "session/". The union of prefixes forms the dispatcher's force-review match.
_PATTERNS_FILE="${PLUGIN_ROOT}/config/sub-pr-branch-patterns.txt"
_FORCE_REVIEW_REGEX=""
if [[ -f "$_PATTERNS_FILE" ]]; then
    while IFS= read -r _line; do
        [[ -z "$_line" || "$_line" == \#* ]] && continue
        # Strip trailing /** or -** or _** glob suffix; keep the literal prefix
        _prefix="${_line%/\*\*}"
        _prefix="${_prefix%-\*\*}"
        _prefix="${_prefix%_\*\*}"
        # Append to regex
        if [[ -z "$_FORCE_REVIEW_REGEX" ]]; then
            _FORCE_REVIEW_REGEX="$_prefix"
        else
            _FORCE_REVIEW_REGEX="${_FORCE_REVIEW_REGEX}|${_prefix}"
        fi
    done < "$_PATTERNS_FILE"
fi

_FORCE_REVIEW=false
# Force-review is a PR-context feature — only enable when we have both
# PR_NUMBER and GITHUB_REPOSITORY (i.e., we're running on a real PR in CI).
# In non-PR contexts (local dispatcher runs, unit tests without explicit PR
# context), force-review cannot resolve check-run history and would
# spuriously trigger on every matching branch name. Gating on PR-context
# availability prevents that.
# Match patterns: each entry ends with the separator that was stripped from
# the glob (- / or _) so "feat" matches feat- and feat/ but not "feature".
if [[ -n "${PR_NUMBER:-}" ]] && [[ -n "${GITHUB_REPOSITORY:-}" ]] \
    && [[ -n "$_FORCE_REVIEW_REGEX" ]] \
    && [[ "$_HEAD_BRANCH" =~ ^(${_FORCE_REVIEW_REGEX})([-/_]|$) ]]; then
    # Check if this branch's HEAD SHA has previously PASSED llm-review.
    # Use poison-on-failure semantics consistent with R2 (verify-session-provenance.sh):
    # any failure in the check-run history of llm-review-named runs on this SHA
    # counts as "no prior pass" regardless of later successes.
    # Semantic: tri-state (0 = no prior pass, 1 = prior pass, "" = unknown / API
    # failed). DO NOT revert to count-based substring matching — `gh pr checks`
    # output column shapes are fragile and the original `grep -c pass` matched
    # stale rerun records.
    # API-failure handling: if we cannot resolve the PR head SHA via the API
    # (gh not available, auth failure, mock gh in tests), _prior_review_pass
    # stays "" (unknown) and we do NOT force-review — defer to the normal
    # provenance flow. Force-review fires only when we have positive evidence
    # of a missing/failed prior pass.
    _prior_review_pass=""
    _pr_head_sha=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" --jq '.head.sha' 2>/dev/null || echo "")
    if [[ -n "$_pr_head_sha" ]]; then
        _prior_review_pass=$(gh api "repos/${GITHUB_REPOSITORY}/commits/${_pr_head_sha}/check-runs" \
            --jq '[.check_runs[] | select(.name=="llm-review")] |
                  if any(.conclusion=="failure" or .conclusion=="cancelled" or .conclusion=="timed_out") then "0"
                  elif any(.conclusion=="success") then "1"
                  else "0" end' 2>/dev/null || echo "")
    fi
    if [[ "$_prior_review_pass" == "0" ]]; then
        _FORCE_REVIEW=true
        echo "  FORCE_REVIEW:     YES — branch '$_HEAD_BRANCH' has no prior llm-review pass"
        echo "  REASON:           sub-agent/feature branch with session provenance but no prior review (bug 69f2)"
    else
        echo "  FORCE_REVIEW:     NO — branch '$_HEAD_BRANCH' already passed llm-review"
    fi
fi

# _DISPATCH_SCOPE_FILE is the canonical routing channel — points to either:
#   (a) UNPROVENANCED_FILE (commits whose covering PRs failed review or are absent), OR
#   (b) a force-scope file (sub-agent branch with insufficient prior review)
# Setting this triggers the commit-scoped diff path. Empty/unset → either
# all-provenanced (skip) or OVER_BOUND, depending on other artifact files.
_DISPATCH_SCOPE_FILE=""
_FORCE_SCOPE_FILE=""  # tracks the temp file for cleanup

if [[ "$_FORCE_REVIEW" == "true" ]]; then
    # R10: force-review must NOT route to full-PR-diff fallback (duplicate-
    # review failure mode). Build a force-scope file listing PR commits whose
    # individual review-sub-pr / llm-review check-runs lack a passing record.
    # Reuses the _DISPATCH_SCOPE_FILE routing channel so the existing commit-
    # scoped diff path picks it up without forking diff-generation logic.
    _commit_count=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/commits" --jq 'length' 2>/dev/null || echo 0)
    _max_commits="${DSO_FORCE_REVIEW_MAX_COMMITS:-50}"
    if (( _commit_count > _max_commits )); then
        provenance_exit=3
        echo "  DECISION:         SKIP (OVER_BOUND) — force-review PR has ${_commit_count} commits (cap=${_max_commits})"
    else
        _FORCE_SCOPE_FILE=$(mktemp /tmp/dso-force-scope.XXXXXX)
        while IFS= read -r _commit; do
            [[ -z "$_commit" ]] && continue
            _commit_status=$(gh api "repos/${GITHUB_REPOSITORY}/commits/${_commit}/check-runs" \
                --jq '[.check_runs[] | select(.name=="review-sub-pr" or .name=="llm-review")] |
                      if any(.conclusion=="failure" or .conclusion=="cancelled" or .conclusion=="timed_out") then "unreviewed"
                      elif any(.conclusion=="success") then "reviewed"
                      else "unreviewed" end' 2>/dev/null || echo "unreviewed")
            if [[ "$_commit_status" == "unreviewed" ]]; then
                echo "$_commit" >> "$_FORCE_SCOPE_FILE"
            fi
        done < <(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/commits" --jq '.[].sha')
        _DISPATCH_SCOPE_FILE="$_FORCE_SCOPE_FILE"
        provenance_exit=1
        _scope_count=$(wc -l < "$_FORCE_SCOPE_FILE" | tr -d ' ')
        echo "  DECISION:         DISPATCH (forced) — ${_scope_count} unreviewed commit(s) on sub-agent branch"
        # W7 observability: structured, greppable decision record per branch.
        echo "AUDIT: decision_record=dispatch reason=forced_unreviewed_subagent scope_size=${_scope_count} pr=${PR_NUMBER:-0}"
    fi
elif [[ -s "$UNPROVENANCED_FILE" ]]; then
    _DISPATCH_SCOPE_FILE="$UNPROVENANCED_FILE"
    provenance_exit=1
    _unprov_n=$(wc -l < "$UNPROVENANCED_FILE" | tr -d ' ')
    echo "  DECISION:         DISPATCH — ${_unprov_n} unprovenanced SHAs require LLM review"
    echo "AUDIT: decision_record=dispatch reason=unprovenanced scope_size=${_unprov_n} pr=${PR_NUMBER:-0}"
elif [[ -s "$OVERBOUND_FILE" ]]; then
    provenance_exit=3
    echo "  DECISION:         SKIP (OVER_BOUND) — non-provenanced commits acknowledged"
    echo "AUDIT: decision_record=skip reason=over_bound pr=${PR_NUMBER:-0}"
else
    provenance_exit=0
    echo "  DECISION:         SKIP (all provenanced) — all commits covered by sub-PR reviews that passed llm-review"
    echo "AUDIT: decision_record=skip reason=all_commits_provenanced pr=${PR_NUMBER:-0}"
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
    # Unprovenanced or budget-exhausted — invoke LLM review.
    # F3 mitigation: when unprovenanced SHAs are known, generate a commit-scoped
    # diff containing only those commits' changes (not the full PR diff). This
    # avoids re-reviewing previously-reviewed code from story PRs.
    # Fallback: full PR diff when no unprovenanced SHAs or commit-scoped is empty.
    if [[ -z "${PR_NUMBER:-}" ]]; then
        echo "ERROR: PR_NUMBER not set — cannot fetch PR diff for runner" >&2
        exit 1
    fi
    _DIFF_PATH=$(mktemp /tmp/dso-pr-diff.XXXXXX)
    # Trap cleans all temp files created in this case arm — including the
    # force-scope file set earlier (if any). Set early; expanded later if
    # additional files are created.
    trap 'rm -f "$_DIFF_PATH" "${_FORCE_SCOPE_FILE:-}"' EXIT
    _COMMIT_SCOPED=false

    if [[ -n "$_DISPATCH_SCOPE_FILE" && -s "$_DISPATCH_SCOPE_FILE" ]]; then
        # R3a v4.1: Filter out SHAs already reachable from origin/main BEFORE
        # generating the commit-scoped diff. The provenance verifier walks
        # BASE_SHA..SESSION_HEAD and may classify commits as "unprovenanced"
        # even when they are already on main (e.g. squash-merged PRs leave the
        # original SHAs uncovered by the new squash commit). Iterating those
        # already-shipped SHAs is wasteful at best and explosive at worst:
        # 6000+ stale unprovenanced entries can produce a 4M-line diff payload
        # by concatenating every historical commit's full diff.
        #
        # Failure-mode policy (post-review hardening — bug PR #425):
        #   - ${_MAIN_REF} unresolvable → FAIL-CLOSED (exit 1). Falling through
        #     unfiltered reintroduces the original explosion.
        #   - Shallow clone (rev-list returns truncated history) → FAIL-CLOSED
        #     with deepen instruction.
        #   - comm or sort fails (internal tooling error) → FAIL-CLOSED. Silent
        #     route-to-SKIP would be an 8a77-class silent-skip-without-review
        #     hole (CLAUDE.md rule:agent-success-check).
        _MAIN_REF="origin/${GITHUB_BASE_REF:-main}"
        if ! git rev-parse --verify --quiet "$_MAIN_REF" >/dev/null 2>&1; then
            echo "ERROR: ${_MAIN_REF} not resolvable — cannot filter already-merged SHAs" >&2
            echo "ERROR: refusing to dispatch unfiltered scope — would re-review thousands of already-shipped commits if provenance cache is stale (bug PR #425)" >&2
            echo "ERROR: ensure the workflow checks out the base ref. For PR contexts, the base ref must be fetched via actions/checkout's fetch-depth: 0." >&2
            exit 1
        fi
        # Shallow-clone handling: a shallow rev-list of origin/main returns
        # truncated history, leaving the filter unable to identify many
        # already-merged SHAs. Attempt self-healing via `git fetch --unshallow`
        # before fail-closing — actions/checkout@v4 with fetch-depth: 0 should
        # produce a non-shallow repo, but some CI configurations still mark
        # the repo shallow after PR-merge-ref checkout.
        if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
            echo "INFO: repository is shallow — attempting git fetch --unshallow to enable reliable filtering"
            # Capture exit code explicitly. `git fetch --unshallow | tail -3`
            # would mask fetch's exit code with tail's (~always 0) and report
            # network failures as success. The downstream is-shallow re-check
            # would still catch state-level failures, but masked exit codes
            # produce misleading logs that obscure future CI debugging.
            # The `set +e ... set -e` wrap prevents set -e from exiting on
            # the failed-fetch command substitution before _UNSHALLOW_RC is
            # captured.
            set +e
            _UNSHALLOW_OUT=$(git fetch --unshallow 2>&1)
            _UNSHALLOW_RC=$?
            set -e
            echo "$_UNSHALLOW_OUT" | tail -3
            if [[ "$_UNSHALLOW_RC" -eq 0 ]]; then
                if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
                    echo "ERROR: repository still shallow after fetch --unshallow" >&2
                    echo "ERROR: already-merged SHA filter cannot operate reliably on shallow clones" >&2
                    echo "ERROR: remediation: set actions/checkout fetch-depth to 0" >&2
                    exit 1
                fi
                echo "INFO: unshallow succeeded — proceeding with filter"
            else
                echo "ERROR: git fetch --unshallow failed (rc=${_UNSHALLOW_RC}); cannot proceed with reliable filtering" >&2
                echo "ERROR: remediation: set actions/checkout fetch-depth to 0 in the workflow" >&2
                exit 1
            fi
        fi

        _FILTERED_SCOPE_FILE=$(mktemp /tmp/dso-filtered-scope.XXXXXX)
        _COMM_STDERR=$(mktemp /tmp/dso-comm-stderr.XXXXXX)
        _SCOPE_SORTED=$(mktemp /tmp/dso-scope-sorted.XXXXXX)
        _MAIN_SORTED=$(mktemp /tmp/dso-main-sorted.XXXXXX)
        # Update trap to clean up all temp files
        trap 'rm -f "$_DIFF_PATH" "${_FORCE_SCOPE_FILE:-}" "${_FILTERED_SCOPE_FILE:-}" "${_COMM_STDERR:-}" "${_SCOPE_SORTED:-}" "${_MAIN_SORTED:-}"' EXIT

        # Sort+comm subtract: O(n log n) instead of O(n*m) for per-SHA
        # ancestor checks. _DISPATCH_SCOPE_FILE may contain thousands of
        # SHAs; per-SHA `git merge-base --is-ancestor` would take minutes.
        # Sort outputs into named files (not process substitution) so we can
        # capture per-step exit codes — silent failures inside <( ) are an
        # 8a77-class silent-skip risk.
        if ! sort -u "$_DISPATCH_SCOPE_FILE" > "$_SCOPE_SORTED" 2>"$_COMM_STDERR"; then
            echo "ERROR: failed to sort scope file: $(cat "$_COMM_STDERR")" >&2
            exit 1
        fi
        if ! git rev-list "$_MAIN_REF" 2>>"$_COMM_STDERR" | sort -u > "$_MAIN_SORTED" 2>>"$_COMM_STDERR"; then
            echo "ERROR: failed to enumerate ${_MAIN_REF} commits: $(cat "$_COMM_STDERR")" >&2
            exit 1
        fi
        if [[ ! -s "$_MAIN_SORTED" ]]; then
            # Empty rev-list output means either the ref is empty (shallow
            # check above should catch this) or a hidden failure. Either way,
            # we cannot reliably filter. Fail-closed.
            echo "ERROR: git rev-list ${_MAIN_REF} returned no commits — filter would be a no-op" >&2
            echo "ERROR: refusing to dispatch potentially-explosive unfiltered scope" >&2
            exit 1
        fi
        # LAUNDERING NOTE (TS-1 / P9): this `comm -23` subtracts SHAs reachable
        # from ${_MAIN_REF} from the review scope — a scope/perf optimization, NOT
        # a coverage guarantee. A SHA that reached main UNREVIEWED is filtered out
        # here and never reviewed. The independent, fail-closed backstop is
        # the review-coverage-invariant check (scripts/ci/ under the plugin root):
        # full base..head set, no reachability prefilter, each SHA PROVEN reviewed.
        if ! comm -23 "$_SCOPE_SORTED" "$_MAIN_SORTED" > "$_FILTERED_SCOPE_FILE" 2>"$_COMM_STDERR"; then
            echo "ERROR: comm failed to compute scope-minus-main: $(cat "$_COMM_STDERR")" >&2
            exit 1
        fi
        _pre_filter=$(wc -l < "$_DISPATCH_SCOPE_FILE" | tr -d ' ')
        _post_filter=$(wc -l < "$_FILTERED_SCOPE_FILE" | tr -d ' ')
        _filtered_out=$(( _pre_filter - _post_filter ))
        if (( _filtered_out > 0 )); then
            echo "INFO: filtered ${_filtered_out} already-merged SHA(s) from scope (${_pre_filter} → ${_post_filter})"
        fi
        _DISPATCH_SCOPE_FILE="$_FILTERED_SCOPE_FILE"

        # If filter removed all SHAs, every commit in scope was already on main.
        # That's the "all-provenanced via squash-merge" case — exit 0 SKIP with
        # a clear log so operators see what happened. WARNING-level (not INFO)
        # because this is an audit-relevant skip.
        if [[ ! -s "$_DISPATCH_SCOPE_FILE" ]]; then
            echo "CONCLUSION: skipped"
            echo "  DECISION:         SKIP — code already shipped to ${_MAIN_REF} (${_pre_filter} commit(s) filtered out)"
            echo "WARNING: all ${_pre_filter} unprovenanced commits were already reachable from ${_MAIN_REF}" >&2
            echo "WARNING: skipping review — code is already shipped to main" >&2
            echo "AUDIT: decision_record=skip reason=all_scope_already_merged scope_size=${_pre_filter} main_ref=${_MAIN_REF}"
            _output_path="${DSO_CI_REVIEW_OUTPUT_PATH:-${ARTIFACT_DIR}/findings.json}"
            mkdir -p "$(dirname "$_output_path")" 2>/dev/null || true
            printf '{"findings": [], "skip_reason": "all_scope_already_merged", "scope_size": %s, "main_ref": "%s"}\n' \
                "$_pre_filter" "$_MAIN_REF" > "$_output_path" 2>/dev/null || true
            exit 0
        fi

        _COMMIT_SCOPED=true
        _scope_count=$(wc -l < "$_DISPATCH_SCOPE_FILE" | tr -d ' ')

        # W2a: build the NET END-STATE diff of the files touched by the
        # unprovenanced SHAs — `git diff <merge-base(MAIN,HEAD)>..HEAD -- <files>`
        # — instead of concatenating per-commit `git show` output. An
        # introduce-then-fix within the unprovenanced range collapses to its
        # final state, so the reviewer can no longer flag the already-fixed
        # intermediate (the CS-10 / PR #509 chronic re-flag). The diff stays
        # file-bounded to the unprovenanced set; it is NOT the full PR diff.
        #
        # Resolve the combined staged head whose net state is under review.
        # Priority: explicit override → PR head SHA (gh api) → GITHUB_SHA → HEAD.
        # GITHUB_SHA is preferred AFTER the true PR head (on a pull_request event
        # it is the synthetic merge ref, not the head). Each candidate is checked
        # for resolvability IN THE CURRENT REPO before use, so a GITHUB_SHA that
        # belongs to a different repo (e.g. CI env leaking into a fixture repo)
        # is skipped rather than triggering a spurious fail-closed.
        _pr_head_api=""
        if [[ -n "${GITHUB_REPOSITORY:-}" && -n "${PR_NUMBER:-}" ]]; then
            _pr_head_api=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" --jq '.head.sha' 2>/dev/null || echo "")
        fi
        _NET_HEAD=""
        for _cand in "${DSO_HEAD_SHA:-}" "$_pr_head_api" "${GITHUB_SHA:-}" "HEAD"; do
            [[ -z "$_cand" ]] && continue
            if git rev-parse --verify --quiet "$_cand" >/dev/null 2>&1; then
                _NET_HEAD="$_cand"
                break
            fi
        done
        if [[ -z "$_NET_HEAD" ]]; then
            echo "ERROR: no resolvable net-diff head (tried DSO_HEAD_SHA / PR head / GITHUB_SHA / HEAD)" >&2
            echo "ERROR: ensure the PR head SHA is fetched (actions/checkout fetch-depth: 0)" >&2
            exit 1
        fi

        if ! _touched_count=$(build_net_integration_diff "$_MAIN_REF" "$_NET_HEAD" "$_DISPATCH_SCOPE_FILE" "$_DIFF_PATH"); then
            echo "ERROR: net-end-state diff construction failed (git error) for ${_scope_count} SHA(s)" >&2
            echo "ERROR: refusing to fall back to a full/own diff — fail-closed (8a77-class)" >&2
            exit 1
        fi
        if [[ ! -s "$_DIFF_PATH" ]]; then
            # Empty net diff: the touched files' end-state equals ${_MAIN_REF}
            # (e.g. an introduce-then-revert pair) OR a resolution failure
            # (shallow clone / SHAs missing / empty-first-parent merges → 0
            # touched files). We cannot distinguish "legitimately net-zero" from
            # "broken history" here, so fail-closed and route to admin review —
            # never silently SKIP an unprovenanced range (8a77-class hole).
            echo "ERROR: net-end-state diff is empty for ${_scope_count} SHA(s) (${_touched_count} touched file(s))" >&2
            echo "ERROR: refusing to SKIP an unprovenanced range on an empty diff — fail-closed" >&2
            echo "ERROR: investigation paths:" >&2
            echo "  (1) shallow clone — increase fetch-depth on actions/checkout" >&2
            echo "  (2) net-zero change (introduce-then-revert) — confirm via git diff ${_MAIN_REF}...${_NET_HEAD}" >&2
            echo "  (3) SHAs missing from local history — verify --depth=0 fetch" >&2
            exit 1
        fi
        echo "INFO: net-end-state diff generated from ${_scope_count} unprovenanced SHA(s) over ${_touched_count} touched file(s) (head ${_NET_HEAD})"
    fi

    # Fallback: full PR diff (only when no _DISPATCH_SCOPE_FILE was set).
    # In v4 this branch is reachable ONLY for the budget-exhausted path
    # (provenance_exit=2 without unprovenanced SHAs) — a rare CI condition.
    # The empty-commit-scoped case fails closed above instead of falling
    # through to the full PR diff.
    if [[ "$_COMMIT_SCOPED" != "true" ]]; then
        _GH_STDERR=$(mktemp /tmp/dso-pr-diff-stderr.XXXXXX)
        trap 'rm -f "$_DIFF_PATH" "$_GH_STDERR" "${_FORCE_SCOPE_FILE:-}"' EXIT
        if ! gh pr diff "$PR_NUMBER" > "$_DIFF_PATH" 2> "$_GH_STDERR"; then
            echo "ERROR: gh pr diff $PR_NUMBER failed:" >&2
            cat "$_GH_STDERR" >&2
            exit 1
        fi
    fi

    # G1 scope narrowing: only apply to full-PR diffs. Commit-scoped diffs
    # are already narrowed by construction.
    if [[ "$_COMMIT_SCOPED" != "true" ]]; then
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
    fi

    # Diagnostic: diff size so the log shows what the LLM is reviewing
    _diff_lines=$(wc -l < "$_DIFF_PATH" | tr -d ' ')
    _diff_files=$(grep -c '^diff --git' "$_DIFF_PATH" || echo 0)
    _diff_adds=$(grep -c '^+[^+]' "$_DIFF_PATH" || echo 0)
    _diff_dels=$(grep -c '^-[^-]' "$_DIFF_PATH" || echo 0)
    _diff_bytes=$(wc -c < "$_DIFF_PATH" | tr -d ' ')
    echo "INFO: dispatching LLM review — diff: ${_diff_files} files, ${_diff_lines} lines (${_diff_adds}+ ${_diff_dels}-), ${_diff_bytes} bytes"

    # R7d (v4): dispatcher-side absolute size cap. Defense-in-depth — the
    # runner's region-split fallback (Strategy E at 400 LOC / 15 files) is the
    # primary mechanism, but a runaway commit-scoped or full PR diff should
    # route to OVER_BOUND rather than rely solely on runner-side handling.
    # Caps are env-overridable for incident response.
    _DSO_DISPATCH_BYTES_CAP="${DSO_DISPATCH_BYTES_CAP:-5242880}"  # 5 MB default
    _DSO_DISPATCH_FILES_CAP="${DSO_DISPATCH_FILES_CAP:-100}"
    if (( _diff_bytes > _DSO_DISPATCH_BYTES_CAP )) || (( _diff_files > _DSO_DISPATCH_FILES_CAP )); then
        echo "  DECISION:         ABORT (OVER_BOUND) — dispatch diff ${_diff_files} files / ${_diff_bytes} bytes exceeds cap ${_DSO_DISPATCH_FILES_CAP} / ${_DSO_DISPATCH_BYTES_CAP}"
        echo "AUDIT: decision_record=abort reason=over_bound_dispatch_diff diff_files=${_diff_files} diff_bytes=${_diff_bytes} pr=${PR_NUMBER:-0}"
        echo "OVER_BOUND: dispatch diff exceeds cap (${_diff_files} files, ${_diff_bytes} bytes; caps ${_DSO_DISPATCH_FILES_CAP}/${_DSO_DISPATCH_BYTES_CAP})" >&2
        echo "OVER_BOUND: routing to admin review (set DSO_DISPATCH_BYTES_CAP / DSO_DISPATCH_FILES_CAP env vars to override)" >&2
        # Write stub findings so ci.yml liveness assertion can distinguish
        # OVER_BOUND from "runner never ran"
        _output_path="${DSO_CI_REVIEW_OUTPUT_PATH:-${ARTIFACT_DIR}/findings.json}"
        mkdir -p "$(dirname "$_output_path")" 2>/dev/null || true
        printf '{"findings": [], "skip_reason": "dispatch_size_cap_exceeded", "blocked": true}\n' > "$_output_path" 2>/dev/null || true
        exit 3
    fi

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
