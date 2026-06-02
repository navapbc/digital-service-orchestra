#!/usr/bin/env bash
# tests/scripts/test-recover-reaped-worktree.sh
#
# Behavioral test for plugins/dso/scripts/recover-reaped-worktree.sh
# (bug 3ba5-0a11-02b8-483d — tiered recovery for reaped worktrees).
#
# Each case EXECUTES the script in an isolated temp git repo and asserts on
# the observable exit code + stdout token. Tier 2 additionally asserts that the
# reported file is actually staged afterward. This is a behavioral test — it
# never inspects the script source.
#
# Usage: bash tests/scripts/test-recover-reaped-worktree.sh

set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/recover-reaped-worktree.sh"

# shellcheck source=tests/lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

# mk_repo <dir> — initialize a quiet git repo with one commit on a stable branch
mk_repo() {
    local dir="$1"
    git -C "$dir" init -q
    git -C "$dir" config user.email test@example.com
    git -C "$dir" config user.name "Test"
    git -C "$dir" checkout -q -b main 2>/dev/null || true
    echo "seed" > "$dir/seed.txt"
    git -C "$dir" add seed.txt
    git -C "$dir" commit -q -m "seed"
}

# ── Tier 1: recoverable via local branch ─────────────────────────────────────
echo "--- Tier 1: recoverable via branch ---"
T1=$(mktemp -d "${TMPDIR:-/tmp}/recover.XXXXXX")
mk_repo "$T1"
git -C "$T1" branch wt/feature-1
OUT=$(cd "$T1" && bash "$SCRIPT" "wt/feature-1" "$T1"); RC=$?
assert_eq "Tier1 exit code 0" "0" "$RC"
assert_contains "Tier1 stdout token" "RECOVERABLE_VIA_BRANCH" "$OUT"

# ── Tier 2: recoverable from session leak (untracked file) ───────────────────
echo "--- Tier 2: recoverable from session leak ---"
T2=$(mktemp -d "${TMPDIR:-/tmp}/recover.XXXXXX")
mk_repo "$T2"
mkdir -p "$T2/src"
echo "leaked work" > "$T2/src/leaked.py"   # untracked, non-empty
OUT=$(cd "$T2" && bash "$SCRIPT" "wt/no-such-branch" "$T2" "src/leaked.py"); RC=$?
assert_eq "Tier2 exit code 0" "0" "$RC"
assert_contains "Tier2 stdout token" "RECOVERED_FROM_SESSION" "$OUT"
STAGED=$(git -C "$T2" diff --cached --name-only)
assert_contains "Tier2 file staged" "src/leaked.py" "$STAGED"

# ── Tier 2b: leaked path containing regex metacharacters (PR #534 regression) ─
# A path like 'src/mod.v2[beta].py' contains '.', '[' — under the old
# `grep -qE "$f"` these were treated as regex (over-match or grep error → silent
# recovery failure). The literal string match must recover it correctly.
echo "--- Tier 2b: metacharacter path matched literally ---"
T2B=$(mktemp -d "${TMPDIR:-/tmp}/recover.XXXXXX")
mk_repo "$T2B"
mkdir -p "$T2B/src"
echo "leaked work" > "$T2B/src/mod.v2[beta].py"   # untracked, non-empty, regex metachars
OUT=$(cd "$T2B" && bash "$SCRIPT" "wt/no-such-branch" "$T2B" "src/mod.v2[beta].py"); RC=$?
assert_eq "Tier2b exit code 0" "0" "$RC"
assert_contains "Tier2b stdout token" "RECOVERED_FROM_SESSION" "$OUT"
STAGED2B=$(git -C "$T2B" diff --cached --name-only)
assert_contains "Tier2b metachar file staged" "src/mod.v2[beta].py" "$STAGED2B"

# ── Tier 2c: leaked path containing spaces (PR #548 regression) ──────────────
# A path like 'src/my work.py' contains a space. The prior staging used an
# unquoted, space-joined `git add -- $RECOVERED`, which word-split such a path
# into 'src/my' and 'work.py' — leaving the real file unstaged. The array-based
# staging must recover and stage it intact.
echo "--- Tier 2c: spaced path staged intact ---"
T2C=$(mktemp -d "${TMPDIR:-/tmp}/recover.XXXXXX")
mk_repo "$T2C"
mkdir -p "$T2C/src"
echo "leaked work" > "$T2C/src/my work.py"   # untracked, non-empty, contains a space
OUT=$(cd "$T2C" && bash "$SCRIPT" "wt/no-such-branch" "$T2C" "src/my work.py"); RC=$?
assert_eq "Tier2c exit code 0" "0" "$RC"
assert_contains "Tier2c stdout token" "RECOVERED_FROM_SESSION" "$OUT"
STAGED2C=$(git -C "$T2C" diff --cached --name-only)
assert_contains "Tier2c spaced file staged intact" "src/my work.py" "$STAGED2C"

# ── Tier err: invalid session_root -> exit 2 (PR #548 finding 6) ─────────────
echo "--- Tier err: invalid session_root -> exit 2 ---"
OUT=$(bash "$SCRIPT" "wt/x" "/nonexistent/session/root/$$/xyz" "f.py" 2>&1); RC=$?
assert_eq "Tier-err exit code 2 on invalid session_root" "2" "$RC"
assert_contains "Tier-err diagnostic" "session_root does not exist" "$OUT"

# ── Tier 3: unrecoverable (no branch, no recoverable files) ──────────────────
echo "--- Tier 3: unrecoverable ---"
T3=$(mktemp -d "${TMPDIR:-/tmp}/recover.XXXXXX")
mk_repo "$T3"
OUT=$(cd "$T3" && bash "$SCRIPT" "wt/gone" "$T3" "src/does-not-exist.py"); RC=$?
assert_eq "Tier3 exit code 3" "3" "$RC"
assert_contains "Tier3 stdout token" "UNRECOVERABLE_REDISPATCH" "$OUT"

# ── Cleanup ──────────────────────────────────────────────────────────────────
rm -rf "$T1" "$T2" "$T2B" "$T2C" "$T3"

print_summary
