#!/usr/bin/env bash
# Structural boundary test for SC coverage prompt files (story 3812-d606)
set -euo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel)
PASS=0; FAIL=0
ok()   { echo "ok - $1"; PASS=$((PASS+1)); }
fail() { echo "not ok - $1"; FAIL=$((FAIL+1)); }

check_file() {
  local file="$1" tier="$2"

  [[ -f "$REPO_ROOT/$file" ]] || { fail "$tier: file exists at $file"; return; }
  ok "$tier: file exists"

  grep -qi "## Input" "$REPO_ROOT/$file" && ok "$tier: has Input section" || fail "$tier: has Input section"
  grep -qiE "## Output" "$REPO_ROOT/$file" && ok "$tier: has Output section" || fail "$tier: has Output section"
  grep -q "sc_id\|sc_text" "$REPO_ROOT/$file" && ok "$tier: has sc_id/sc_text field" || fail "$tier: has sc_id/sc_text field"
  grep -q "verdict" "$REPO_ROOT/$file" && ok "$tier: has verdict field" || fail "$tier: has verdict field"
}

# Haiku checks
check_file "plugins/dso/skills/sprint/prompts/sc-coverage-haiku.md" "haiku"
grep -qiE "cit(e|ation)" "$REPO_ROOT/plugins/dso/skills/sprint/prompts/sc-coverage-haiku.md" 2>/dev/null && ok "haiku: has citation requirement" || fail "haiku: has citation requirement"

# Sonnet checks
check_file "plugins/dso/skills/sprint/prompts/sc-coverage-sonnet.md" "sonnet"
grep -q "UNSURE" "$REPO_ROOT/plugins/dso/skills/sprint/prompts/sc-coverage-sonnet.md" 2>/dev/null && ok "sonnet: has UNSURE verdict" || fail "sonnet: has UNSURE verdict"

# Opus checks
check_file "plugins/dso/skills/sprint/prompts/sc-coverage-opus.md" "opus"
grep -qiE "COVERED.preferred|tie.break|ambiguous" "$REPO_ROOT/plugins/dso/skills/sprint/prompts/sc-coverage-opus.md" 2>/dev/null && ok "opus: has COVERED-preferred/tie-break language" || fail "opus: has COVERED-preferred/tie-break language"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
