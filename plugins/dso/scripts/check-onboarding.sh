#!/bin/bash
set -euo pipefail
#
# check-onboarding.sh - Check if design and dev onboarding artifacts exist
#
# Checks for:
# - .claude/design-notes.md (produced by /dso:onboarding)
# - ARCH_ENFORCEMENT.md (produced by /dso:architect-foundation)
#
# Usage: ./scripts/check-onboarding.sh [--json]
#
# Exit codes:
#   0 - Both artifacts exist
#   1 - One or more artifacts missing

set -euo pipefail

REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
JSON_OUTPUT=false

for arg in "$@"; do
  case "$arg" in
    --json) JSON_OUTPUT=true ;;
  esac
done

# REVIEW-DEFENSE: The skill names referenced below (/dso:onboarding, /dso:architect-foundation)
# are the NEW canonical names. The OLD skill directories (plugins/dso/skills/design-onboarding/,
# plugins/dso/skills/dev-onboarding/) still exist on disk as redirect stubs — they contain
# SKILL.md files that forward users to the new skill names. This is intentional: the redirect
# stubs preserve backward compatibility during the migration. The migration is NOT incomplete;
# the old directories are redirect artifacts, not active skill directories.

# --- Artifact checks ---

design_notes=""
arch_enforcement=""

# Search for .claude/design-notes.md (canonical location)
for candidate in \
  "$REPO_ROOT/.claude/design-notes.md"; do
  if [[ -f "$candidate" ]]; then
    design_notes="$candidate"
    break
  fi
done

# Search for ARCH_ENFORCEMENT.md (project root or docs/)
for candidate in \
  "$REPO_ROOT/ARCH_ENFORCEMENT.md" \
  "$REPO_ROOT/docs/ARCH_ENFORCEMENT.md"; do
  if [[ -f "$candidate" ]]; then
    arch_enforcement="$candidate"
    break
  fi
done

# --- Output ---

design_pass=$([[ -n "$design_notes" ]] && echo "true" || echo "false")
dev_pass=$([[ -n "$arch_enforcement" ]] && echo "true" || echo "false")

if $JSON_OUTPUT; then
  cat <<EOF
{
  "design_onboarding": {
    "pass": $design_pass,
    "artifact": ".claude/design-notes.md",
    "path": "${design_notes:-not found}",
    "skill": "/dso:onboarding"
  },
  "architect_foundation": {
    "pass": $dev_pass,
    "artifact": "ARCH_ENFORCEMENT.md",
    "path": "${arch_enforcement:-not found}",
    "skill": "/dso:architect-foundation"
  }
}
EOF
else
  echo "=== Onboarding Artifact Check ==="
  if [[ -n "$design_notes" ]]; then
    echo "PASS: .claude/design-notes.md found at $design_notes"
  else
    echo "FAIL: .claude/design-notes.md not found (run /dso:onboarding)"
  fi

  if [[ -n "$arch_enforcement" ]]; then
    echo "PASS: ARCH_ENFORCEMENT.md found at $arch_enforcement"
  else
    echo "FAIL: ARCH_ENFORCEMENT.md not found (run /dso:architect-foundation)"
  fi
fi

# Exit code: 0 if both pass, 1 if any fail
if [[ "$design_pass" == "true" && "$dev_pass" == "true" ]]; then
  exit 0
else
  exit 1
fi
