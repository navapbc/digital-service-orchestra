#!/usr/bin/env bash
# tests/scripts/test-staged-not-force-review.sh
#
# Invariant for 3ebb DD4 unit 5 (C5): a two-tier PR2 head branch (`staged-*`)
# must NOT match the force-review regex that llm-review-dispatch-or-skip.sh builds
# from config/sub-pr-branch-patterns.txt. force-review re-dispatches llm-review on
# its own check-run history INDEPENDENT of provenance/the admin-exemption ledger;
# if `staged-*` matched, PR2 would re-wedge regardless of unit 5's provenance
# consult, reintroducing the second override. This catches a future regression
# (e.g. someone adding `staged-**` to the patterns file).
#
# The regex build mirrors the dispatcher: strip a trailing /** -** _** glob from
# each pattern -> literal prefix; union; match `^(<prefixes>)([-/_]|$)`.

set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
PATTERNS="$REPO_ROOT/plugins/dso/config/sub-pr-branch-patterns.txt"  # shim-exempt: test reads the source-of-truth patterns

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

[[ -f "$PATTERNS" ]] || { echo "FAIL: patterns file not found: $PATTERNS"; exit 1; }

# Build the force-review prefix-union regex the same way the dispatcher does.
_regex=""
while IFS= read -r pat; do
    [[ -z "$pat" || "$pat" == \#* ]] && continue
    pref="${pat%/\*\*}"; pref="${pref%-\*\*}"; pref="${pref%_\*\*}"
    [[ -n "$_regex" ]] && _regex+="|"
    _regex+="$(printf '%s' "$pref" | sed -E 's/[.[\(\)*+?{}^$|\\]/\\&/g')"
done < "$PATTERNS"

_matches() { [[ "$1" =~ ^(${_regex})([-/_]|$) ]]; }

# A real two-tier PR2 head branch.
if ! _matches "staged-6804f9385db1-1780561991"; then _pass "C5_staged_not_force_review"; else _fail "C5_staged_not_force_review" "staged-* matched force-review regex: ${_regex}"; fi
if ! _matches "staged-abc"; then _pass "C5_staged_prefix_not_force_review"; else _fail "C5_staged_prefix_not_force_review" "staged- matched"; fi
# Sanity: a genuine sub-PR branch DOES match (proves the regex is built correctly,
# so the negative assertions above aren't vacuous).
if _matches "feat-foo" && _matches "story/588e/bar"; then _pass "C5_sanity_subpr_matches"; else _fail "C5_sanity_subpr_matches" "regex did not match a known sub-PR branch: ${_regex}"; fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
