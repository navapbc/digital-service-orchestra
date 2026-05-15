#!/usr/bin/env bash
# test-defense-matcher.sh
# Structural test: verifies that REVIEW-WORKFLOW.md contains the cited_lines
# injection instruction in the defense record assembly (R5) section.
# Testing Mode: UPDATE — test is written first (fails), then the doc is updated
# to make it pass.

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
WORKFLOW_FILE="$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md"

pass=0
fail=0
errors=()

# ── Test 1: cited_lines injection instruction appears in R5 defense section ───
# The R5 rule is the defense mechanism section. After the doc update, it should
# contain a cited_lines copy instruction with a python code snippet showing
# defense_json["cited_lines"] = finding.get("cited_lines", [])
if grep -q 'defense_json\["cited_lines"\]' "$WORKFLOW_FILE" || \
   grep -q 'defense_json\[.cited_lines.\]' "$WORKFLOW_FILE"; then
    echo "PASS: cited_lines injection instruction (defense_json[\"cited_lines\"]) found in REVIEW-WORKFLOW.md"
    ((pass++))
else
    echo "FAIL: cited_lines injection instruction not found in REVIEW-WORKFLOW.md"
    errors+=("defense_json[\"cited_lines\"] = ... instruction missing from REVIEW-WORKFLOW.md")
    ((fail++))
fi

# ── Test 2: prior_finding_id and cited_lines appear together in the defense
#    record assembly section — both should be referenced in the R5 context. ────
# The R5 rule section describes defense_json assembly; after the update it
# should reference prior_finding_id (from the example record) and cited_lines
# within close proximity (within 20 lines of each other in the R5 block).
R5_CONTEXT=$(grep -A50 'R5 - Defense mechanism' "$WORKFLOW_FILE" 2>/dev/null || true)

HAS_PRIOR_FINDING_ID=false
HAS_CITED_LINES=false

if echo "$R5_CONTEXT" | grep -q 'prior_finding_id'; then
    HAS_PRIOR_FINDING_ID=true
fi

if echo "$R5_CONTEXT" | grep -q 'cited_lines'; then
    HAS_CITED_LINES=true
fi

if [[ "$HAS_PRIOR_FINDING_ID" == "true" && "$HAS_CITED_LINES" == "true" ]]; then
    echo "PASS: R5 section references both 'prior_finding_id' and 'cited_lines'"
    ((pass++))
else
    echo "FAIL: R5 section missing co-location of 'prior_finding_id' and 'cited_lines'"
    echo "  HAS_PRIOR_FINDING_ID=$HAS_PRIOR_FINDING_ID"
    echo "  HAS_CITED_LINES=$HAS_CITED_LINES"
    errors+=("R5 defense assembly section must reference both prior_finding_id and cited_lines")
    ((fail++))
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $pass passed, $fail failed"

if [[ ${#errors[@]} -gt 0 ]]; then
    echo ""
    echo "Failures:"
    for err in "${errors[@]}"; do
        echo "  - $err"
    done
    exit 1
fi

exit 0
