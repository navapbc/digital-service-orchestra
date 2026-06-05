#!/usr/bin/env bash
# tests/scripts/test-merge-to-main-pr-linear-sync.sh — cca8 (linear-history cutover, DD1)
#
# Behavioral tests for _sync_branch_against_default in merge-to-main-pr.sh — the
# pre-push sync that brings the session/staged branch up to date with the default
# branch BEFORE the push. cca8 switches this from `git merge --no-edit
# origin/<default>` (which created a merge commit on the branch head) to a REBASE,
# so the head stays LINEAR and GitHub's `gh pr merge --rebase` accepts the PR under
# required_linear_history.
#
# Sourced with PR_LIB_MODE=1 (library-mode guard) and driven over real git
# fixtures; asserts observable git state (ancestry / linearity / restoration), the
# _SYNCED_VIA_REBASE signal, and exit codes — never inspects source text.
#
#   D1 behind default: rebases; origin/<default> becomes an ancestor of HEAD; the
#       range origin/<default>..HEAD contains ZERO merge commits; _SYNCED_VIA_REBASE=1.
#   D2 up to date (origin/<default> already an ancestor) -> no rebase, HEAD
#       unchanged, _SYNCED_VIA_REBASE=0, exit 0.
#   D3 conflict -> abort + restore HEAD, exit 1, no rebase left in progress.
#   D4 unrelated histories (no common ancestor) -> skip, HEAD unchanged, exit 0.
#   D5 _publish_rebased_branch force-publishes the rewritten head to origin.
#   D6 _publish_rebased_branch's explicit lease detects a concurrent writer and
#       refuses the force-push (origin not clobbered) — guards the gitar finding
#       that a fetch-before-bare-lease degrades to an unconditional --force.

set -uo pipefail
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
unset PROJECT_ROOT CLAUDE_PROJECT_DIR _MERGE_STATE_GIT_DIR

REPO_ROOT="$(git rev-parse --show-toplevel)"
PR_SCRIPT="$REPO_ROOT/plugins/dso/scripts/merge-to-main-pr.sh"   # shim-exempt: sources the script under test

export PR_LIB_MODE=1
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso"
export BRANCH="lib-load-dummy"
# shellcheck disable=SC1090
source "$PR_SCRIPT" >/dev/null 2>&1 || true
unset BRANCH
if ! declare -F _sync_branch_against_default >/dev/null 2>&1; then
    echo "FATAL: _sync_branch_against_default not defined after sourcing (PR_LIB_MODE)"; exit 1
fi
if ! declare -F _publish_rebased_branch >/dev/null 2>&1; then
    echo "FATAL: _publish_rebased_branch not defined after sourcing (PR_LIB_MODE)"; exit 1
fi

_W="$(mktemp -d "${TMPDIR:-/tmp}/mtm-linsync.XXXXXX")"; trap 'rm -rf "$_W"' EXIT
PASS=0; FAIL=0
_ok() { echo "PASS: $1"; PASS=$((PASS+1)); }
_no() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

# _mkrepo <name> : bare origin + clone with main M0->M1. echoes "<repo> <M1>".
_mkrepo() {
    local n="$1" r="$_W/$1" o="$_W/$1.git"
    git init -q --bare "$o"
    git clone -q "$o" "$r" 2>/dev/null
    ( cd "$r" || exit 1
      git config user.email t@e.st; git config user.name t
      echo base > base.txt; git add base.txt; git commit -q -m M0
      git push -q origin HEAD:main 2>/dev/null
      echo "main-change" > mainfile.txt; git add mainfile.txt; git commit -q -m M1
      git push -q origin HEAD:main 2>/dev/null )
    echo "$r $(cd "$r" && git rev-parse HEAD)"
}

# ── D1: branch behind default -> linear rebase, no merge commit ───────────────
rb="$(_mkrepo d1)"; r="${rb% *}"; M1="${rb#* }"
if ( cd "$r" || exit 1
     git checkout -q -b feature "$M1~1"            # off M0, behind origin/main(M1)
     echo feat > featfile.txt; git add featfile.txt; git commit -q -m F1
     _SYNCED_VIA_REBASE=0
     BRANCH=feature _DEFAULT_BRANCH=main _sync_branch_against_default >/dev/null 2>&1 || exit 1
     # origin/main is now an ancestor of HEAD (feature replayed on top of it)…
     git merge-base --is-ancestor "origin/main" HEAD 2>/dev/null \
       && [[ -f featfile.txt && -f mainfile.txt ]] \
       && [[ "$_SYNCED_VIA_REBASE" == "1" ]] \
       && [[ -z "$(git rev-list --merges origin/main..HEAD 2>/dev/null)" ]] ); then
    _ok "D1 behind default: rebased linearly (origin/main ancestor, 0 merge commits, _SYNCED_VIA_REBASE=1)"
else _no "D1 linear rebase" "did not rebase linearly / merge commit present / flag not set"; fi

# ── D2: already up to date -> no rebase, HEAD unchanged, flag 0 ───────────────
rb="$(_mkrepo d2)"; r="${rb% *}"; M1="${rb#* }"
if ( cd "$r" || exit 1
     git checkout -q -b feature "$M1"             # on top of origin/main
     echo feat > featfile.txt; git add featfile.txt; git commit -q -m F1
     before="$(git rev-parse HEAD)"
     _SYNCED_VIA_REBASE=9
     BRANCH=feature _DEFAULT_BRANCH=main _sync_branch_against_default >/dev/null 2>&1 || exit 1
     [[ "$before" == "$(git rev-parse HEAD)" && "$_SYNCED_VIA_REBASE" == "0" ]] ); then
    _ok "D2 up-to-date: no rebase, HEAD unchanged, _SYNCED_VIA_REBASE=0"
else _no "D2 up-to-date" "HEAD changed or flag not reset to 0"; fi

# ── D3: rebase conflict -> abort + restore HEAD, exit 1 ───────────────────────
rb="$(_mkrepo d3)"; r="${rb% *}"; M1="${rb#* }"
if ( cd "$r" || exit 1
     git checkout -q -b feature "$M1~1"
     echo "feature version" > mainfile.txt; git add mainfile.txt; git commit -q -m "F1 conflicting"
     before="$(git rev-parse HEAD)"
     BRANCH=feature _DEFAULT_BRANCH=main _sync_branch_against_default >/dev/null 2>&1
     rc=$?
     # Observable outcome (not git-internal state dirs): exit 1, HEAD restored to
     # the pre-rebase commit, AND we are back on the feature branch — a rebase left
     # in progress would leave HEAD detached, so symbolic-ref resolving to "feature"
     # confirms the rebase was fully aborted and the branch restored.
     [[ "$rc" == 1 && "$before" == "$(git rev-parse HEAD)" ]] \
       && [[ "$(git symbolic-ref --short -q HEAD)" == "feature" ]] ); then
    _ok "D3 conflict: abort + restore HEAD on feature branch, exit 1, rebase terminated"
else _no "D3 conflict abort-restore" "did not restore HEAD / wrong rc / rebase left in progress"; fi

# ── D4: unrelated histories -> skip (no common ancestor), HEAD unchanged ──────
rb="$(_mkrepo d4)"; r="${rb% *}"
if ( cd "$r" || exit 1
     git checkout -q --orphan unrelated
     git rm -rfq . 2>/dev/null || true
     echo x > x.txt; git add x.txt; git commit -q -m U0
     before="$(git rev-parse HEAD)"
     # Seed a sentinel so we can prove the function actually executed its skip
     # path (which resets the flag to 0) rather than the assertion passing by
     # accident on a pre-set value.
     _SYNCED_VIA_REBASE=9
     # orphan branch has NO common ancestor with origin/main -> _sync must skip:
     # return 0, leave HEAD untouched, and never set _SYNCED_VIA_REBASE=1.
     BRANCH=unrelated _DEFAULT_BRANCH=main _sync_branch_against_default >/dev/null 2>&1
     rc=$?
     [[ "$rc" == 0 && "$before" == "$(git rev-parse HEAD)" && "$_SYNCED_VIA_REBASE" == "0" ]] ); then
    _ok "D4 unrelated histories: no common ancestor -> skip (rc=0, HEAD unchanged, flag reset to 0)"
else _no "D4 unrelated histories" "rebased unrelated history or non-zero exit"; fi

# ── D5: rebased publish -> explicit lease force-publishes rewritten head ──────
rb="$(_mkrepo d5)"; r="${rb% *}"; M1="${rb#* }"
if ( cd "$r" || exit 1
     git checkout -q -b feature "$M1"
     echo feat > featfile.txt; git add featfile.txt; git commit -q -m F1
     git push -q -u origin feature 2>/dev/null            # origin/feature == F1; tracking ref set
     git commit -q --amend -m "F1 rewritten"              # diverge from origin (post-rebase head)
     rewritten="$(git rev-parse HEAD)"
     _publish_rebased_branch feature >/dev/null 2>&1 || exit 1
     # observable: origin/feature now holds our rewritten head
     [[ "$(git ls-remote origin refs/heads/feature 2>/dev/null | cut -f1)" == "$rewritten" ]] ); then
    _ok "D5 rebased publish: explicit-lease force-push updates origin to rewritten head"
else _no "D5 rebased publish" "did not publish rewritten head to origin"; fi

# ── D6: concurrent writer on origin -> explicit lease refuses, no clobber ─────
rb="$(_mkrepo d6)"; r="${rb% *}"; M1="${rb#* }"; o="$r.git"
if ( cd "$r" || exit 1
     git checkout -q -b feature "$M1"
     echo feat > featfile.txt; git add featfile.txt; git commit -q -m F1
     git push -q -u origin feature 2>/dev/null            # tracking ref origin/feature == F1
     # concurrent writer advances origin/feature via a second clone; we never fetch,
     # so our tracking ref stays at F1 (the stale lease basis).
     c2="$_W/d6-c2"; git clone -q "$o" "$c2" 2>/dev/null
     ( cd "$c2" || exit 1; git config user.email t@e.st; git config user.name t
       git checkout -q feature
       echo concurrent > conc.txt; git add conc.txt; git commit -q -m C1
       git push -q origin feature 2>/dev/null )
     concurrent_tip="$(git ls-remote origin refs/heads/feature 2>/dev/null | cut -f1)"
     git commit -q --amend -m "F1 rewritten"              # our diverged post-rebase head
     # explicit lease basis = stale F1, but origin is at C1 -> push MUST be refused
     _publish_rebased_branch feature >/dev/null 2>&1 && exit 1   # push succeeding here = the bug
     # observable: origin/feature is untouched (still the concurrent writer's commit)
     [[ "$(git ls-remote origin refs/heads/feature 2>/dev/null | cut -f1)" == "$concurrent_tip" ]] ); then
    _ok "D6 concurrent writer: explicit lease refuses force-push, origin not clobbered"
else _no "D6 concurrent writer" "lease did not detect concurrent writer / origin clobbered"; fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]]
