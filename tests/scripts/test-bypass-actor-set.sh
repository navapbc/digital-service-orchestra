#!/usr/bin/env bash
# tests/scripts/test-bypass-actor-set.sh — ADR-0022 identity-based admin exemption
#
# Behavioral tests for the bypass-actor-set resolver. Proves membership is
# fail-closed: only a well-formed numeric id present in the validated set matches;
# null/app/typo ids and an empty/malformed set never match.
#
#   B1  scalar env (DSO_RULESET_BYPASS_USER_ID) -> that id matches, others don't.
#   B2  plural set env (DSO_RULESET_BYPASS_USER_IDS) -> each member matches.
#   B3  plural takes precedence over scalar.
#   B4  null / empty / non-numeric merged_by id -> NOT a bypass actor (fail closed).
#   B5  malformed tokens in the set (trailing comma, blank, typo) are DISCARDED,
#       never widen membership; a non-member still fails.
#   B6  unset env set -> an arbitrary non-configured id never matches (fail closed).

set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/plugins/dso/scripts/lib/bypass-actor-set.sh"  # shim-exempt: test sources the lib under test

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

unset DSO_RULESET_BYPASS_USER_IDS DSO_RULESET_BYPASS_USER_ID

# shellcheck source=/dev/null
source "$LIB"

# _member <ids-env> <ids-scalar-env> <id> -> echoes "yes"|"no". Temporary env
# assignments scope to the function call (no subshell, no leak).
_member() {
    if DSO_RULESET_BYPASS_USER_IDS="$1" DSO_RULESET_BYPASS_USER_ID="$2" bas_is_bypass_actor "$3"; then
        echo yes
    else
        echo no
    fi
}
_assert() { # _assert <name> <got> <want>
    if [[ "$2" == "$3" ]]; then _pass "$1"; else _fail "$1" "got=$2 want=$3"; fi
}

# ── B1: scalar env ───────────────────────────────────────────────────────────
_assert "B1_scalar_env_matches"        "$(_member "" 207596960 207596960)" yes
_assert "B1_scalar_env_rejects_other"  "$(_member "" 207596960 999)"       no

# ── B2: plural set env ───────────────────────────────────────────────────────
_assert "B2_plural_member_100" "$(_member "100,200,300" "" 100)" yes
_assert "B2_plural_member_300" "$(_member "100,200,300" "" 300)" yes
_assert "B2_plural_nonmember"  "$(_member "100,200,300" "" 150)" no

# ── B3: plural precedence over scalar ────────────────────────────────────────
_assert "B3_plural_member"        "$(_member "100,200" 999 100)" yes
_assert "B3_scalar_ignored"       "$(_member "100,200" 999 999)" no

# ── B4: null/empty/non-numeric id fails closed ───────────────────────────────
_assert "B4_empty_id"   "$(_member "100,200" "" "")"    no
_assert "B4_null_id"    "$(_member "100,200" "" null)"  no
_assert "B4_alpha_id"   "$(_member "100,200" "" abc)"   no
_assert "B4_mixed_id"   "$(_member "100,200" "" 10a)"   no

# ── B5: malformed set tokens discarded, do not widen membership ──────────────
_assert "B5_kept_100"      "$(_member "100, ,200,,abc,30x" "" 100)" yes
_assert "B5_kept_200"      "$(_member "100, ,200,,abc,30x" "" 200)" yes
_assert "B5_partial_30"    "$(_member "100, ,200,,abc,30x" "" 30)"  no
_assert "B5_nonmember"     "$(_member "100, ,200,,abc,30x" "" 999)" no
_assert "B5_set_value"     "$(DSO_RULESET_BYPASS_USER_IDS='100, ,200,,abc,30x' bas_bypass_actor_ids)" "100 200"

# ── B6: unset env set -> arbitrary non-configured id never matches ───────────
_assert "B6_unset_fails_closed" "$(_member "" "" 999999999)" no

echo ""
echo "=== test-bypass-actor-set.sh: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
