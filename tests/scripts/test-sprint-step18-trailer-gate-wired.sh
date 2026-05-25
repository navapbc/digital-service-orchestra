#!/usr/bin/env bash
# tests/scripts/test-sprint-step18-trailer-gate-wired.sh
# Structural (non-content-grep) test for F1: Phase F Step 18 wiring.
# Bug db71-e078-ec99-4fbf.
#
# We assert structural invariants — not specific prose — per the
# behavioral-testing-standard rule 5 (no change-detector tests):
#
#   I1: SKILL.md mentions the script verify-story-merge-trailer.sh
#       (presence — anywhere in Phase F Step 18 region).
#   I2: There exists a Phase F Step 18 HARD-GATE block that cites
#       bug db71 (ties the gate to its motivating bug, durable
#       cross-reference rather than reformatable prose).
#   I3: The verify call sits BEFORE the `ticket transition <story-id>
#       closed` invocation (ordering invariant).
#
# These three invariants together are the load-bearing contract: the
# gate is referenced, attributed, and ordered correctly.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-sprint-step18-trailer-gate-wired.sh ==="

# Locate the Step 18 region: from "### Step 18" through the next "### Step 19".
_STEP18_REGION=$(awk '
    /^### Step 18:/ { inside=1 }
    /^### Step 19:/ { inside=0 }
    inside { print }
' "$SKILL")

# I1: script reference present in Step 18 region.
_snapshot_fail
if [[ "$_STEP18_REGION" == *"verify-story-merge-trailer.sh"* ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: I1_step18_references_verify_script" >&2
fi
assert_pass_if_clean "I1_step18_references_verify_script"

# I2: a HARD-GATE block in Step 18 cites bug db71.
_snapshot_fail
# Match HARD-GATE blocks that contain db71 within the Step 18 region.
_HARDGATE_HIT=$(awk '
    /^### Step 18:/ { inside=1 }
    /^### Step 19:/ { inside=0 }
    inside && /<HARD-GATE>/ { in_gate=1; block="" }
    inside && in_gate { block = block "\n" $0 }
    inside && /<\/HARD-GATE>/ {
        in_gate=0
        if (block ~ /db71/) { print "HIT"; exit }
    }
' "$_STEP18_REGION" <<< "$_STEP18_REGION")
# Re-run against file content (awk above had quoting confusion w/ here-string)
_HARDGATE_HIT=$(awk '
    /^### Step 18:/ { inside=1 }
    /^### Step 19:/ { inside=0 }
    inside && /<HARD-GATE>/ { in_gate=1; block="" }
    inside && in_gate { block = block "\n" $0 }
    inside && /<\/HARD-GATE>/ {
        in_gate=0
        if (block ~ /db71/) { print "HIT"; exit }
    }
' "$SKILL")
if [[ "$_HARDGATE_HIT" == "HIT" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: I2_step18_hardgate_cites_db71" >&2
fi
assert_pass_if_clean "I2_step18_hardgate_cites_db71"

# I3: ordering — first occurrence of verify-story-merge-trailer.sh in the
# Step 18 region precedes the first 'ticket transition <story-id> ... closed'.
_snapshot_fail
_VERIFY_LINE=$(awk '
    /^### Step 18:/ { inside=1 }
    /^### Step 19:/ { inside=0 }
    inside && /verify-story-merge-trailer\.sh/ { print NR; exit }
' "$SKILL")
_TRANSITION_LINE=$(awk '
    /^### Step 18:/ { inside=1 }
    /^### Step 19:/ { inside=0 }
    # Match an actual invocation line, not prose describing it. The
    # canonical Phase F transition command starts with `.claude/scripts/dso`.
    inside && /^\.claude\/scripts\/dso ticket transition.*closed/ { print NR; exit }
' "$SKILL")
if [[ -n "$_VERIFY_LINE" && -n "$_TRANSITION_LINE" && "$_VERIFY_LINE" -lt "$_TRANSITION_LINE" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: I3_verify_before_transition  verify_line=$_VERIFY_LINE transition_line=$_TRANSITION_LINE" >&2
fi
assert_pass_if_clean "I3_verify_before_transition"

print_summary
