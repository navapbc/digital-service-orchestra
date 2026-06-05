#!/usr/bin/env bash
# tests/scripts/test-merge-to-main-prebump-sync.sh — 0f17 DD1/DD2
#
# Unit tests for _phase_prebump_feature_sync in merge-to-main-pr.sh — the pinned
# pre-bump feature-sync that rebases the feature branch onto the staged ref's tip
# (the pinned origin/main SHA) BEFORE the version bump, so PR1's version line is
# single-sided. Sourced with PR_LIB_MODE=1 (library-mode guard) and driven over real
# git fixtures; asserts observable git state (HEAD ancestry / restoration) and exit
# codes — never inspects source text.
#
#   P1 clean rebase: feature off OLD base, pinned=NEW main, origin/<branch> absent
#       -> rebases; pinned becomes an ancestor of HEAD; exit 0.
#   P2 idempotent / in-flight-review guard: origin/<branch> EXISTS -> SKIP (exit 0),
#       HEAD unchanged (never force-push under review), even though pinned is ahead.
#   P3 already based on pinned (pinned is ancestor of HEAD) -> no rebase, exit 0, HEAD
#       unchanged.
#   P4 CODE conflict -> abort + hard-restore (HEAD == pre-rebase), exit 1, emits
#       PREBUMP_SYNC_CONFLICT.
#   P5 empty pinned SHA -> fail closed (exit 1).

set -uo pipefail
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
unset PROJECT_ROOT CLAUDE_PROJECT_DIR _MERGE_STATE_GIT_DIR

REPO_ROOT="$(git rev-parse --show-toplevel)"
PR_SCRIPT="$REPO_ROOT/plugins/dso/scripts/merge-to-main-pr.sh"   # shim-exempt: sources the script under test

# Load function definitions only. The library-mode guard skips the phase pipeline, but
# the top-of-file env resolution still runs on source — it needs PR_LIB_MODE +
# CLAUDE_PLUGIN_ROOT + BRANCH set and a git repo as cwd, else it `exit`s before the
# functions are defined (mirrors test-merge-to-main-pr-title-derivation.sh). Source in
# the parent so the case subshells below inherit the function.
export PR_LIB_MODE=1
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso"
export BRANCH="lib-load-dummy"
# shellcheck disable=SC1090
source "$PR_SCRIPT" >/dev/null 2>&1 || true
unset BRANCH
if ! declare -F _phase_prebump_feature_sync >/dev/null 2>&1; then
    echo "FATAL: _phase_prebump_feature_sync not defined after sourcing (PR_LIB_MODE)"; exit 1
fi

_W="$(mktemp -d "${TMPDIR:-/tmp}/mtm-prebump.XXXXXX")"; trap 'rm -rf "$_W"' EXIT
PASS=0; FAIL=0
_ok() { echo "PASS: $1"; PASS=$((PASS+1)); }
_no() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

# _mkrepo <name> : bare origin + clone with main M0->M1 (M1 = pinned). echoes "<repo> <M1>".
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

# Each case runs in a subshell whose EXIT STATUS is the pass/fail verdict; the parent
# records the count (subshell var increments would not propagate).

# ── P1: clean rebase ─────────────────────────────────────────────────────────
rb="$(_mkrepo p1)"; r="${rb% *}"; M1="${rb#* }"
if ( cd "$r" || exit 1
     git checkout -q -b feature "$M1~1"
     echo feat > featfile.txt; git add featfile.txt; git commit -q -m F1
     BRANCH=feature _DEFAULT_BRANCH=main _phase_prebump_feature_sync "$M1" >/dev/null 2>&1 || exit 1
     git merge-base --is-ancestor "$M1" HEAD 2>/dev/null && [[ -f featfile.txt ]] ); then
    _ok "P1 clean rebase onto pinned main (pinned now ancestor of HEAD)"
else _no "P1 clean rebase" "rebase did not land feature onto pinned main"; fi

# ── P2: idempotent skip when origin/<branch> exists ──────────────────────────
rb="$(_mkrepo p2)"; r="${rb% *}"; M1="${rb#* }"
if ( cd "$r" || exit 1
     git checkout -q -b feature "$M1~1"
     echo feat > featfile.txt; git add featfile.txt; git commit -q -m F1
     git push -q origin feature 2>/dev/null
     before="$(git rev-parse HEAD)"
     BRANCH=feature _DEFAULT_BRANCH=main _phase_prebump_feature_sync "$M1" >/dev/null 2>&1 || exit 1
     after="$(git rev-parse HEAD)"
     [[ "$before" == "$after" ]] && ! git merge-base --is-ancestor "$M1" HEAD 2>/dev/null ); then
    _ok "P2 skip when origin/feature exists (no force-push under review; HEAD unchanged)"
else _no "P2 idempotent skip" "HEAD changed or did not skip"; fi

# ── P3: already based on pinned ──────────────────────────────────────────────
rb="$(_mkrepo p3)"; r="${rb% *}"; M1="${rb#* }"
if ( cd "$r" || exit 1
     git checkout -q -b feature "$M1"
     echo feat > featfile.txt; git add featfile.txt; git commit -q -m F1
     before="$(git rev-parse HEAD)"
     BRANCH=feature _DEFAULT_BRANCH=main _phase_prebump_feature_sync "$M1" >/dev/null 2>&1 || exit 1
     [[ "$before" == "$(git rev-parse HEAD)" ]] ); then
    _ok "P3 already-based: no rebase, HEAD unchanged"
else _no "P3 already-based" "HEAD changed or non-zero"; fi

# ── P4: code conflict -> abort + restore ─────────────────────────────────────
rb="$(_mkrepo p4)"; r="${rb% *}"; M1="${rb#* }"
if ( cd "$r" || exit 1
     git checkout -q -b feature "$M1~1"
     echo "feature version" > mainfile.txt; git add mainfile.txt; git commit -q -m "F1 conflicting"
     before="$(git rev-parse HEAD)"
     out="$(BRANCH=feature _DEFAULT_BRANCH=main _phase_prebump_feature_sync "$M1" 2>&1)"
     rc=$?
     [[ "$rc" == 1 && "$before" == "$(git rev-parse HEAD)" ]] \
       && grep -q "PREBUMP_SYNC_CONFLICT" <<<"$out" \
       && [[ ! -d .git/rebase-merge && ! -d .git/rebase-apply ]] ); then
    _ok "P4 conflict: abort + restore HEAD, exit 1, PREBUMP_SYNC_CONFLICT emitted"
else _no "P4 conflict abort-restore" "did not restore HEAD / wrong rc / no marker / rebase left in progress"; fi

# ── P5: empty pinned -> fail closed ──────────────────────────────────────────
rb="$(_mkrepo p5)"; r="${rb% *}"
if ( cd "$r" || exit 1
     git checkout -q -b feature
     BRANCH=feature _DEFAULT_BRANCH=main _phase_prebump_feature_sync "" >/dev/null 2>&1; [[ $? -eq 1 ]] ); then
    _ok "P5 empty pinned -> fail closed (exit 1)"
else _no "P5 empty pinned" "did not fail closed"; fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]]
