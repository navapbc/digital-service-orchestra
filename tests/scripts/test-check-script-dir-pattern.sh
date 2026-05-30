#!/usr/bin/env bash
# Regression test for bug 8229: pre-commit hook that catches the
# REPO_ROOT=$SCRIPT_DIR/.. anti-pattern in plugin scripts.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/.claude/hooks/pre-commit/check-script-dir-pattern.sh"
PASS=0
FAIL=0

_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

# Set up a throwaway repo so we can stage fixture files without touching
# the real index. The hook calls `git diff --cached --name-only` against
# whatever working dir we're in — so we cd into the fixture repo.
FIX_REPO=$(mktemp -d -t dso-8229-fixture-XXXXXX)
# shellcheck disable=SC2064  # intentional: bind FIX_REPO at trap-set time
trap "rm -rf '$FIX_REPO'" EXIT

git -C "$FIX_REPO" init -q
git -C "$FIX_REPO" config user.email "test@example.com"
git -C "$FIX_REPO" config user.name "test"
mkdir -p "$FIX_REPO/plugins/dso/scripts"

# ── Test 1: anti-pattern in staged script is flagged ─────────────────────────
cat > "$FIX_REPO/plugins/dso/scripts/buggy.sh" <<'BUGGY'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
echo "$REPO_ROOT"
BUGGY
git -C "$FIX_REPO" add plugins/dso/scripts/buggy.sh

exit_code=0
output=$(cd "$FIX_REPO" && bash "$HOOK" 2>&1) || exit_code=$?
if [[ $exit_code -ne 0 ]] && echo "$output" | grep -q "buggy.sh:3"; then
    _pass "test_anti_pattern_in_staged_script_is_flagged"
else
    _fail "test_anti_pattern_in_staged_script_is_flagged" \
          "exit=$exit_code output=${output:0:300}"
fi

# ── Test 2: suppression marker on same line is respected ─────────────────────
cat > "$FIX_REPO/plugins/dso/scripts/buggy.sh" <<'SUPPRESSED'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"  # script-dir-pattern-ok: plugin-internal smoke-test
echo "$REPO_ROOT"
SUPPRESSED
git -C "$FIX_REPO" add plugins/dso/scripts/buggy.sh

exit_code=0
output=$(cd "$FIX_REPO" && bash "$HOOK" 2>&1) || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    _pass "test_suppression_marker_on_same_line_is_respected"
else
    _fail "test_suppression_marker_on_same_line_is_respected" \
          "exit=$exit_code output=${output:0:300}"
fi

# ── Test 3: canonical pattern is NOT flagged ─────────────────────────────────
cat > "$FIX_REPO/plugins/dso/scripts/buggy.sh" <<'CANONICAL'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
if [[ -z "$REPO_ROOT" ]]; then
  echo "ERROR: cannot resolve REPO_ROOT" >&2
  exit 1
fi
echo "$REPO_ROOT"
CANONICAL
git -C "$FIX_REPO" add plugins/dso/scripts/buggy.sh

exit_code=0
output=$(cd "$FIX_REPO" && bash "$HOOK" 2>&1) || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    _pass "test_canonical_pattern_is_not_flagged"
else
    _fail "test_canonical_pattern_is_not_flagged" \
          "exit=$exit_code output=${output:0:300}"
fi

# ── Test 4: brace-variant anti-pattern is flagged ────────────────────────────
cat > "$FIX_REPO/plugins/dso/scripts/buggy.sh" <<'BRACED'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
echo "$REPO_ROOT"
BRACED
git -C "$FIX_REPO" add plugins/dso/scripts/buggy.sh

exit_code=0
output=$(cd "$FIX_REPO" && bash "$HOOK" 2>&1) || exit_code=$?
if [[ $exit_code -ne 0 ]]; then
    _pass "test_brace_variant_anti_pattern_is_flagged"
else
    _fail "test_brace_variant_anti_pattern_is_flagged" \
          "exit=$exit_code output=${output:0:300}"
fi

# ── Test 5: default-assignment variant (a530-style) is flagged ───────────────
cat > "$FIX_REPO/plugins/dso/scripts/buggy.sh" <<'DEFAULTED'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${REPO_ROOT:=$(cd "$SCRIPT_DIR/.." && pwd)}"
echo "$REPO_ROOT"
DEFAULTED
git -C "$FIX_REPO" add plugins/dso/scripts/buggy.sh

exit_code=0
output=$(cd "$FIX_REPO" && bash "$HOOK" 2>&1) || exit_code=$?
if [[ $exit_code -ne 0 ]]; then
    _pass "test_default_assignment_variant_is_flagged"
else
    _fail "test_default_assignment_variant_is_flagged" \
          "exit=$exit_code output=${output:0:300}"
fi

# ── Test 6: pattern in a comment line is NOT flagged ─────────────────────────
cat > "$FIX_REPO/plugins/dso/scripts/buggy.sh" <<'COMMENTED'
#!/usr/bin/env bash
# Documentation example: DO NOT use REPO_ROOT="$SCRIPT_DIR/.." — broken on hosts.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
echo "$REPO_ROOT"
COMMENTED
git -C "$FIX_REPO" add plugins/dso/scripts/buggy.sh

exit_code=0
output=$(cd "$FIX_REPO" && bash "$HOOK" 2>&1) || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    _pass "test_pattern_in_comment_is_not_flagged"
else
    _fail "test_pattern_in_comment_is_not_flagged" \
          "exit=$exit_code output=${output:0:300}"
fi

# ── Test 7: non-plugin scripts are ignored ───────────────────────────────────
mkdir -p "$FIX_REPO/tests/scripts"
cat > "$FIX_REPO/tests/scripts/some-test.sh" <<'NONPLUGIN'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
echo "$REPO_ROOT"
NONPLUGIN
# Reset staged plugin script to canonical so only the non-plugin one matters.
cat > "$FIX_REPO/plugins/dso/scripts/buggy.sh" <<'CANONICAL'
#!/usr/bin/env bash
REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
echo "$REPO_ROOT"
CANONICAL
git -C "$FIX_REPO" add plugins/dso/scripts/buggy.sh tests/scripts/some-test.sh

exit_code=0
output=$(cd "$FIX_REPO" && bash "$HOOK" 2>&1) || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    _pass "test_non_plugin_scripts_are_ignored"
else
    _fail "test_non_plugin_scripts_are_ignored" \
          "exit=$exit_code output=${output:0:300}"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
