#!/usr/bin/env bash
# tests/scripts/test-verifier-trailer-awareness.sh
# Structural test for F4: completion-verifier agent has DSO-Story-Merge
# trailer awareness at the epic-level dispatch path.
# Bug db71-e078-ec99-4fbf.
#
# Structural invariants (not change-detector content grep):
#   I1: The agent file references the trailer 'DSO-Story-Merge' somewhere
#       (presence of the concept).
#   I2: The agent file contains a check stanza that ties trailer scanning
#       to closed child stories at the EPIC level (epic-only gating).
#       Approximated by: a section that mentions both 'DSO-Story-Merge'
#       and the epic-level concept in close textual proximity, AND
#       references `git log` (the mechanism).
#   I3: The check is wired into `closure_checks_results` (the emission
#       contract verifiers use to surface FAIL entries).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFIER="$REPO_ROOT/plugins/dso/agents/completion-verifier.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-verifier-trailer-awareness.sh ==="

# I1: agent mentions DSO-Story-Merge.
_snapshot_fail
if grep -q "DSO-Story-Merge" "$VERIFIER"; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: I1_verifier_mentions_trailer" >&2
fi
assert_pass_if_clean "I1_verifier_mentions_trailer"

# I2: a stanza ties trailer scanning to epic-level + uses git log.
# Search for any 60-line window that contains all three concepts.
_snapshot_fail
_HIT=$(awk '
    { lines[NR]=$0 }
    END {
        for (i=1; i<=NR; i++) {
            window=""
            end = (i+60 > NR) ? NR : i+60
            for (j=i; j<=end; j++) window = window "\n" lines[j]
            if (window ~ /DSO-Story-Merge/ \
                && window ~ /[Ee]pic/ \
                && window ~ /git log/) {
                print "HIT"; exit
            }
        }
    }
' "$VERIFIER")
if [[ "$_HIT" == "HIT" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: I2_verifier_epic_trailer_stanza_with_git_log" >&2
fi
assert_pass_if_clean "I2_verifier_epic_trailer_stanza_with_git_log"

# I3: stanza wires into closure_checks_results.
_snapshot_fail
_HIT3=$(awk '
    { lines[NR]=$0 }
    END {
        for (i=1; i<=NR; i++) {
            window=""
            end = (i+80 > NR) ? NR : i+80
            for (j=i; j<=end; j++) window = window "\n" lines[j]
            if (window ~ /DSO-Story-Merge/ && window ~ /closure_checks_results/) {
                print "HIT"; exit
            }
        }
    }
' "$VERIFIER")
if [[ "$_HIT3" == "HIT" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: I3_verifier_emits_to_closure_checks_results" >&2
fi
assert_pass_if_clean "I3_verifier_emits_to_closure_checks_results"

print_summary
