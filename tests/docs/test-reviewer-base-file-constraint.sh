#!/usr/bin/env bash
# tests/docs/test-reviewer-base-file-constraint.sh
#
# Architectural contract test: reviewer-base.md must constrain the "file" field
# in findings to only reference files present in the diff being reviewed.
#
# This is a design-contract test (narrow exception per RED test writer policy):
# the prompt text IS the behavioral contract — its presence prevents reviewers
# from citing non-diff files, which causes record-review.sh to reject the review.
#
# RED phase: both tests FAIL because the constraint text does not yet exist.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
ASSERT_LIB="$REPO_ROOT/tests/lib/assert.sh"
# shellcheck source=../lib/assert.sh
source "$ASSERT_LIB"

REVIEWER_BASE="$REPO_ROOT/plugins/dso/docs/workflows/prompts/reviewer-base.md"
REVIEW_WORKFLOW="$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md"

# ---------------------------------------------------------------------------
# test_file_field_constraint
#
# Verifies that reviewer-base.md constrains the "file" field in the findings
# JSON schema to only reference files present in the diff being reviewed.
#
# Observable behavior: a reviewer following this prompt will only cite files
# that appear in the diff, preventing record-review.sh file-overlap rejection.
# ---------------------------------------------------------------------------
echo "=== test_file_field_constraint ==="

reviewer_base_content="$(< "$REVIEWER_BASE")"

# The constraint must associate the "file" field with the diff. We look for
# language that restricts "file" entries to files from the diff. Acceptable
# phrases include "diff", "changed files", "staged files" appearing near a
# description of the file field constraint. We check for a combined signal:
# the word "diff" must appear in a constraint clause about the "file" field.
#
# Strategy: extract the findings schema section (between "findings" and
# "summary") and check that it contains diff-constraining language.

# Use Python for reliable multi-line extraction without awk/sed
findings_section="$(python3 - "$REVIEWER_BASE" <<'PYEOF'
import sys, re
content = open(sys.argv[1]).read()
# Extract the block starting at "findings" array through closing brace of schema
m = re.search(r'"findings".*?"summary"', content, re.DOTALL)
if m:
    print(m.group(0))
PYEOF
)"

# The constraint must mention "diff" in the context of the file field
# (e.g., "must be a file from the diff", "only files in the diff", etc.)
if [[ "$findings_section" == *"diff"* ]]; then
    assert_eq \
        "file field constraint references diff files" \
        "present" \
        "present"
else
    # Provide a diagnostic: show what IS in the findings section
    assert_eq \
        "file field constraint references diff files" \
        "constraint mentioning 'diff' near findings schema" \
        "no such constraint found — file field has no diff restriction"
fi

# Secondary check: the constraint text must appear within 5 lines of the
# "file" field line in the schema. We verify the file field line itself
# is annotated or immediately followed by constraint language.
file_field_context="$(python3 - "$REVIEWER_BASE" <<'PYEOF'
import sys
lines = open(sys.argv[1]).readlines()
for i, line in enumerate(lines):
    if '"file"' in line and 'path/to/file' in line:
        # Grab 3 lines before and 5 lines after
        start = max(0, i - 3)
        end = min(len(lines), i + 6)
        print("".join(lines[start:end]))
        break
PYEOF
)"

if [[ "$file_field_context" == *"diff"* ]]; then
    assert_eq \
        "file field annotation constrains to diff within 5 lines" \
        "present" \
        "present"
else
    assert_eq \
        "file field annotation constrains to diff within 5 lines" \
        "constraint text mentioning 'diff' within 5 lines of file field" \
        "no diff constraint found near file field"
fi

# ---------------------------------------------------------------------------
# test_review_workflow_file_overlap_recovery
#
# Verifies that REVIEW-WORKFLOW.md contains specific recovery guidance for
# the case where record-review.sh rejects due to file-overlap failure
# (findings reference files not present in the diff).
#
# Observable behavior: orchestrators following this workflow can recover from
# file-overlap rejection by re-dispatching the reviewer with corrected context.
# ---------------------------------------------------------------------------
echo ""
echo "=== test_review_workflow_file_overlap_recovery ==="

review_workflow_content="$(< "$REVIEW_WORKFLOW")"

# NOTE: REVIEW-WORKFLOW.md already mentions "file overlap" at line 394 in a
# descriptive context ("checks file overlap with the actual diff"). The bug fix
# must add SPECIFIC recovery guidance for when findings cite non-diff files —
# something the existing generic "fix and retry" does not provide.

# The recovery guidance must specifically address the case where findings cite
# files NOT in the diff. The existing text says "If it rejects, fix and retry"
# which is too generic. The approved fix adds explicit guidance for the
# file-overlap rejection case with instructions to re-dispatch the reviewer.
#
# We require: language that specifically addresses files "not in the diff"
# OR "non-diff files" in the context of a record-review.sh rejection recovery
# step. This distinguishes specific guidance from the existing generic "retry".
file_overlap_specific="$(python3 - "$REVIEW_WORKFLOW" <<'PYEOF'
import sys
content = open(sys.argv[1]).read()
# Look for explicit mention of files being outside/not-in the diff
# in the context of record-review.sh rejection recovery
patterns = [
    'not in the diff',
    'not in diff',
    'outside the diff',
    'non-diff file',
    'files not present in the diff',
    'findings reference files',
    'file field.*diff',
    'diff.*file field',
]
import re
for pattern in patterns:
    if re.search(pattern, content, re.IGNORECASE):
        print(f"FOUND: {pattern}")
        break
PYEOF
)"

if [[ -n "$file_overlap_specific" ]]; then
    assert_eq \
        "REVIEW-WORKFLOW.md has specific guidance for non-diff file references causing rejection" \
        "present" \
        "present"
else
    assert_eq \
        "REVIEW-WORKFLOW.md has specific guidance for non-diff file references causing rejection" \
        "explicit guidance for when findings reference files not in the diff" \
        "no specific guidance found — only generic 'fix and retry' exists"
fi

# The specific recovery step must include re-dispatch of the reviewer
# (not just a vague "retry"). We check for "re-dispatch" within context
# that also mentions the file-overlap / non-diff-file condition.
file_overlap_redispatch="$(python3 - "$REVIEW_WORKFLOW" <<'PYEOF'
import sys, re
content = open(sys.argv[1]).read()
lines = content.splitlines()
# Find lines mentioning non-diff file overlap issue specifically
target_patterns = [
    r'not in the diff',
    r'non-diff file',
    r'outside the diff',
    r'findings reference files',
    r'file.*not.*diff',
]
for i, line in enumerate(lines):
    for pat in target_patterns:
        if re.search(pat, line, re.IGNORECASE):
            start = max(0, i - 5)
            end = min(len(lines), i + 15)
            window = "\n".join(lines[start:end])
            # Check if re-dispatch or specific recovery is nearby
            if re.search(r're-dispatch|redispatch|re-run reviewer|dispatch.*reviewer', window, re.IGNORECASE):
                print("FOUND_REDISPATCH")
            break
PYEOF
)"

if [[ "$file_overlap_redispatch" == *"FOUND_REDISPATCH"* ]]; then
    assert_eq \
        "REVIEW-WORKFLOW.md file-overlap recovery includes re-dispatch of reviewer" \
        "present" \
        "present"
else
    assert_eq \
        "REVIEW-WORKFLOW.md file-overlap recovery includes re-dispatch of reviewer" \
        "re-dispatch guidance within file-overlap recovery section" \
        "no re-dispatch instruction found near file-overlap recovery guidance"
fi

# test_output_contract_section_heading
# Given: plugins/dso/docs/workflows/prompts/reviewer-base.md
# When: inspect document structure for the Mandatory Output Contract section
# Then: the section heading must exist as a structural anchor
#
# Structural contract check (Rule 5): section heading is the deterministic
# interface boundary — its presence guarantees the contract block exists and
# is reachable by reviewers following the document structure.
echo ""
echo "=== test_output_contract_section_heading ==="
if grep -q '^## Mandatory Output Contract' "$REVIEWER_BASE"; then
    assert_eq "## Mandatory Output Contract section heading present" "present" "present"
else
    assert_eq "## Mandatory Output Contract section heading present" \
        "section heading '## Mandatory Output Contract'" \
        "heading not found — output contract section is missing or renamed"
fi

# test_output_contract_required_fields
# Given: plugins/dso/docs/workflows/prompts/reviewer-base.md
# When: extract the code fence block within the ## Mandatory Output Contract section
# Then: the fence must define all three required contract fields:
#       REVIEWER_HASH, FINDING_COUNT, FILES
#
# Structural contract check (Rule 5): the code fence is the formal contract
# specification — checking for required field names within the section-scoped
# fence tests the mandatory fields boundary, not wording within prose.
echo ""
echo "=== test_output_contract_required_fields ==="
output_contract_fields="$(python3 - "$REVIEWER_BASE" <<'PYEOF'
import sys, re
content = open(sys.argv[1]).read()
# Extract the ## Mandatory Output Contract section up to the next ## heading
m = re.search(r'^## Mandatory Output Contract\s*\n(.*?)(?=^## |\Z)', content, re.DOTALL | re.MULTILINE)
if not m:
    print("MISSING_SECTION")
    sys.exit(0)
section = m.group(1)
# Extract the first code fence in the section
fence = re.search(r'```[^\n]*\n(.*?)```', section, re.DOTALL)
if not fence:
    print("MISSING_FENCE")
    sys.exit(0)
fence_content = fence.group(1)
found = []
if 'REVIEWER_HASH' in fence_content:
    found.append('REVIEWER_HASH')
if 'FINDING_COUNT' in fence_content:
    found.append('FINDING_COUNT')
if 'FILES' in fence_content:
    found.append('FILES')
# Report deprecated fields present in the fence (structural regression guard)
deprecated = []
if 'REVIEW_RESULT' in fence_content:
    deprecated.append('REVIEW_RESULT')
if 'MIN_SCORE' in fence_content:
    deprecated.append('MIN_SCORE')
print(f"FOUND:{','.join(found)} DEPRECATED:{','.join(deprecated)}")
PYEOF
)"
required_fields_present=true
deprecated_fields_present=false
if [[ "$output_contract_fields" == *"MISSING_SECTION"* ]]; then
    required_fields_present=false
elif [[ "$output_contract_fields" == *"MISSING_FENCE"* ]]; then
    required_fields_present=false
else
    for field in REVIEWER_HASH FINDING_COUNT FILES; do
        if [[ "$output_contract_fields" != *"$field"* ]]; then
            required_fields_present=false
        fi
    done
    if [[ "$output_contract_fields" == *"DEPRECATED:"*"REVIEW_RESULT"* ]] || \
       [[ "$output_contract_fields" == *"DEPRECATED:"*"MIN_SCORE"* ]]; then
        deprecated_fields_present=true
    fi
fi

if $required_fields_present; then
    assert_eq "output contract code fence defines required fields (REVIEWER_HASH, FINDING_COUNT, FILES)" \
        "all three fields present" "all three fields present"
else
    assert_eq "output contract code fence defines required fields (REVIEWER_HASH, FINDING_COUNT, FILES)" \
        "REVIEWER_HASH + FINDING_COUNT + FILES in output contract code fence" \
        "one or more required fields missing — fence: $output_contract_fields"
fi

if $deprecated_fields_present; then
    assert_eq "output contract code fence must not contain deprecated fields (REVIEW_RESULT, MIN_SCORE)" \
        "no deprecated fields in fence" \
        "deprecated field(s) found in output contract fence — $output_contract_fields"
else
    assert_eq "output contract code fence must not contain deprecated fields (REVIEW_RESULT, MIN_SCORE)" \
        "no deprecated fields in fence" "no deprecated fields in fence"
fi

# test_two_key_json_schema
echo ""
echo "=== test_two_key_json_schema ==="
# The JSON schema must specify exactly two required top-level keys: findings and summary
# (no scores key in required)
schema_section="$(python3 - "$REVIEWER_BASE" <<'PYEOF'
import sys, re
content = open(sys.argv[1]).read()
# Look for "EXACTLY two top-level keys" on a SINGLE LINE (not cross-section DOTALL match).
# The current reviewer-base.md says "EXACTLY three top-level keys" — this test should fail until
# that is updated to "EXACTLY two top-level keys". Using re.MULTILINE (not DOTALL) so the
# match cannot span multiple lines and pick up unrelated "findings" and "summary" sections.
m = re.search(r'EXACTLY two top-level keys|two required top-level keys|required.*two.*keys', content, re.IGNORECASE)
if m:
    print("two_key_found")
PYEOF
)"
if [[ "$schema_section" == *"two_key_found"* ]]; then
    assert_eq "JSON schema specifies 2-key schema (EXACTLY two top-level keys: findings + summary)" "present" "present"
else
    assert_eq "JSON schema specifies 2-key schema (findings + summary, no scores)" \
        "2-key schema specification (findings + summary)" \
        "2-key schema language not found — still using 3-key schema?"
fi

print_summary
