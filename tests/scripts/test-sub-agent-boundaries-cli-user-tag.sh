#!/usr/bin/env bash
# tests/scripts/test-sub-agent-boundaries-cli-user-tag.sh
#
# Structural contract test: SUB-AGENT-BOUNDARIES.md must explicitly prohibit
# sub-agents from using --tags CLI_user on autonomously-discovered bug tickets.
#
# This is a design-contract test (narrow exception per RED test writer policy):
# the prohibition text IS the behavioral contract — its presence prevents
# sub-agents from applying CLI_user tag to tickets they create autonomously,
# which would misrepresent the ticket's provenance (machine-created vs human-requested).
#
# RED phase: both tests FAIL because SUB-AGENT-BOUNDARIES.md does not yet
# mention CLI_user or the prohibition context.
#
# Usage: bash tests/scripts/test-sub-agent-boundaries-cli-user-tag.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
ASSERT_LIB="$REPO_ROOT/tests/lib/assert.sh"
# shellcheck source=../lib/assert.sh
source "$ASSERT_LIB"

BOUNDARIES_FILE="$REPO_ROOT/plugins/dso/docs/SUB-AGENT-BOUNDARIES.md"

# ---------------------------------------------------------------------------
# test_cli_user_tag_mentioned
#
# Verifies that SUB-AGENT-BOUNDARIES.md mentions CLI_user at all, establishing
# that the tag's semantics (human-requested vs autonomously created) are addressed.
# ---------------------------------------------------------------------------
echo "=== test_cli_user_tag_mentioned ==="

if grep -q "CLI_user" "$BOUNDARIES_FILE"; then
    assert_eq \
        "SUB-AGENT-BOUNDARIES.md mentions CLI_user tag" \
        "present" \
        "present"
else
    assert_eq \
        "SUB-AGENT-BOUNDARIES.md mentions CLI_user tag" \
        "CLI_user mentioned in boundaries doc" \
        "CLI_user not found in SUB-AGENT-BOUNDARIES.md"
fi

# ---------------------------------------------------------------------------
# test_cli_user_tag_prohibited_for_autonomous_bugs
#
# Verifies that SUB-AGENT-BOUNDARIES.md contains language that explicitly
# prohibits using --tags CLI_user on autonomously-created bug tickets.
# Acceptable forms include "must NOT", "MUST NOT", "do not use", "never use",
# "prohibited", or "not permitted" appearing in proximity to "CLI_user".
# ---------------------------------------------------------------------------
echo ""
echo "=== test_cli_user_tag_prohibited_for_autonomous_bugs ==="

prohibition_found="$(python3 - "$BOUNDARIES_FILE" <<'PYEOF'
import sys, re

content = open(sys.argv[1]).read()

# Find lines containing CLI_user
lines = content.splitlines()
cli_user_lines = [(i, line) for i, line in enumerate(lines) if 'CLI_user' in line]

if not cli_user_lines:
    print("NOT_FOUND")
    sys.exit(0)

# For each CLI_user occurrence, check surrounding context (5 lines before/after)
# for prohibition language
prohibition_patterns = [
    r'must\s+not',
    r'MUST\s+NOT',
    r'do\s+not\s+use',
    r'never\s+use',
    r'prohibited',
    r'not\s+permitted',
    r'never\s+add',
    r'must\s+never',
]

for idx, _ in cli_user_lines:
    start = max(0, idx - 5)
    end = min(len(lines), idx + 6)
    window = "\n".join(lines[start:end])
    for pat in prohibition_patterns:
        if re.search(pat, window, re.IGNORECASE):
            print("PROHIBITION_FOUND")
            sys.exit(0)

print("NO_PROHIBITION")
PYEOF
)"

if [[ "$prohibition_found" == "PROHIBITION_FOUND" ]]; then
    assert_eq \
        "SUB-AGENT-BOUNDARIES.md prohibits --tags CLI_user on autonomous bug tickets" \
        "present" \
        "present"
else
    assert_eq \
        "SUB-AGENT-BOUNDARIES.md prohibits --tags CLI_user on autonomous bug tickets" \
        "prohibition language (must NOT / never use / prohibited) near CLI_user" \
        "no prohibition context found near CLI_user in SUB-AGENT-BOUNDARIES.md (result: $prohibition_found)"
fi

print_summary
