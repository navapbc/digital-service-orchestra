#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel)
source "$REPO_ROOT/tests/lib/assert.sh"

test_curator_agent_has_required_frontmatter() {
  local f="$REPO_ROOT/plugins/dso/agents/inference-incident-curator.md"
  if test -f "$f"; then actual_exists="present"; else actual_exists="missing"; fi
  assert_eq "inference-incident-curator.md exists" "present" "$actual_exists"
  if grep -q '^name:' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has name field" "present" "$actual"
  if grep -q '^model: opus' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "model is opus" "present" "$actual"
  if grep -q '^description:' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has description field" "present" "$actual"
  if grep -q '^color:' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has color field" "present" "$actual"
}

test_curator_agent_references_corpus_insufficient_signal() {
  local f="$REPO_ROOT/plugins/dso/agents/inference-incident-curator.md"
  if test -f "$f"; then actual_exists="present"; else actual_exists="missing"; fi
  assert_eq "inference-incident-curator.md exists" "present" "$actual_exists"
  if grep -q '^## CORPUS_INSUFFICIENT' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has CORPUS_INSUFFICIENT section" "present" "$actual"
}

test_curator_agent_has_required_frontmatter
test_curator_agent_references_corpus_insufficient_signal
print_summary
