#!/usr/bin/env bash
# reachability.sh — Shared library: assert_sha_reachable
#
# Source this script and call: assert_sha_reachable <sha> <label> [<repo_path>]
# Returns 4 with descriptive stderr if the SHA is not reachable in the working
# tree at <repo_path>; returns 0 otherwise.
#
# Rationale (bug 8a77 v2): the verifier walk, the dispatcher's cosmetic walk,
# and end-session/check-orphan-epics.sh all need the same reachability guard
# before invoking `git log <a>..<b>`. Extracting prevents future drift and
# centralizes the hint text shown to operators.

assert_sha_reachable() {
    local _sha="${1:?assert_sha_reachable: SHA required as arg 1}"
    local _label="${2:?assert_sha_reachable: label required as arg 2}"
    local _repo="${3:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}"

    if ! git -C "$_repo" rev-parse --verify "${_sha}^{commit}" >/dev/null 2>&1; then
        echo "ERROR: ${_label} ${_sha} is not reachable in working tree at ${_repo}" >&2
        echo "Hint: actions/checkout@v4 defaults to fetch-depth: 1 and lands on refs/pull/N/merge for pull_request events;" >&2
        echo "      pull_request.head.sha is NOT in the local clone without explicit fetch." >&2
        echo "Hint: canonical fix is \`fetch-depth: 0\` on actions/checkout (commitlint/semantic-release pattern)." >&2
        echo "Hint: minimal fix is \`git fetch --no-tags --depth=1 origin ${_sha}\` before invoking this script." >&2
        return 4
    fi
    return 0
}
