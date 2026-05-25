#!/usr/bin/env bash
# emit-missing-trailer-warning.sh — Phase F advisory warning.
#
# Emits a GitHub Actions `::warning::` line on stdout when an empty
# INTEGRATION_SCOPE on a multi-commit pull_request indicates likely-missing
# DSO-Story-Merge trailers (bug db71-e078-ec99-4fbf).
#
# Extracted from .github/workflows/ci.yml so the behavior is testable in
# isolation (cycle-2 llm-review finding 3/4: the inline form had only
# structural test coverage, no behavioral coverage).
#
# Inputs (env vars):
#   EVENT_NAME   github.event_name. Warning is suppressed unless this is
#                "pull_request" — on push events head_ref/base_ref are
#                empty and the signal is not meaningful.
#   BASE_REF     github.base_ref. Empty on push; required for the
#                origin/${BASE_REF}..HEAD range. Warning is suppressed if
#                empty.
#   HEAD_REF     github.head_ref. Used only in the warning message.
#   SCOPE_EMPTY  "true" when ci.yml's INTEGRATION_SCOPE is empty. Warning
#                is suppressed unless this is "true".
#
# Exit: always 0. Warnings are advisory; a non-zero exit here would block
# the CI umbrella, which is the opposite of the intent.
#
# Stderr / stdout:
#   - Diagnostic messages and the actual `::warning::` line are printed to
#     stdout so they reach the GitHub Actions log.
#   - git stderr is captured and surfaced in the diagnostic warning rather
#     than swallowed via 2>/dev/null (cycle-2 llm-review finding 2/4).

set -uo pipefail

_EVENT_NAME="${EVENT_NAME:-}"
_BASE_REF="${BASE_REF:-}"
_HEAD_REF="${HEAD_REF:-}"
_SCOPE_EMPTY="${SCOPE_EMPTY:-}"

# Suppression gates. Each returns 0 (success, no warning) when the signal
# is not applicable.
[[ "$_SCOPE_EMPTY" != "true" ]] && exit 0
[[ "$_EVENT_NAME" != "pull_request" ]] && exit 0
[[ -z "$_BASE_REF" ]] && exit 0

# Capture git stderr alongside stdout so a failure leaves an explanation
# in the CI log, not a silent dropped warning.
_GIT_OUT=$(git log "origin/${_BASE_REF}..HEAD" --no-merges --format=%H 2>&1)
_GIT_EXIT=$?

if [[ $_GIT_EXIT -ne 0 ]]; then
    echo "::warning::Could not enumerate non-merge commits in origin/${_BASE_REF}..HEAD (git exit=${_GIT_EXIT}): ${_GIT_OUT}. Trailer-presence advisory skipped. See bug db71-e078-ec99-4fbf."
    exit 0
fi

# Count lines that look like commit SHAs (40 hex chars). Filtering on the
# SHA shape rather than `wc -l` avoids counting a stray blank line as a
# commit when the range is empty.
_COUNT=$(printf '%s\n' "$_GIT_OUT" | grep -Ec '^[0-9a-f]{7,40}$' || true)

if [[ "${_COUNT:-0}" -gt 1 ]]; then
    echo "::warning::No per-story DSO-Story-Merge trailers found on ${_HEAD_REF}; llm-review will run against the full diff. See bug db71-e078-ec99-4fbf."
fi

exit 0
