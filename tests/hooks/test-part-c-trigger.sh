#!/usr/bin/env bash
# tests/hooks/test-part-c-trigger.sh
#
# Structural boundary test: Part C trigger in epic-scrutiny-pipeline.md must
# mention deprecating/relocating/renaming paths as trigger conditions.
#
# Rule 5 compliance: tests the structural contract of an instruction file
# (the trigger condition is the behavioral interface that controls pipeline
# activation — not arbitrary wording).
#
# RED: fails until GREEN task (8da5-1555) extends Part C trigger with
# deprecation/relocation/rename language.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PIPELINE_MD="${REPO_ROOT}/plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md"

# Source shared assert library
# shellcheck source=tests/lib/assert.sh
source "${REPO_ROOT}/tests/lib/assert.sh"

# ---------------------------------------------------------------------------
# test_part_c_contains_deprecation_trigger
#
# Given: Part C section exists in epic-scrutiny-pipeline.md
# When:  The Part C trigger condition text is extracted
# Then:  The trigger mentions at least one of: deprecat, relocat, renam
#        (keywords that indicate path deprecation/relocation/rename as triggers)
# ---------------------------------------------------------------------------
test_part_c_contains_deprecation_trigger() {
  if [ ! -f "$PIPELINE_MD" ]; then
    assert_eq "pipeline file must exist" "exists" "missing"
    return
  fi

  # Extract the Part C section: lines from "### Part C" up to (but not
  # including) the next "### Part" or "---" section boundary.
  local part_c_text
  part_c_text="$(awk '
    /^### Part C/ { in_section=1 }
    in_section && /^### Part [^C]/ { in_section=0 }
    in_section && /^---/ { in_section=0 }
    in_section { print }
  ' "$PIPELINE_MD")"

  if [ -z "$part_c_text" ]; then
    assert_eq "Part C section must be present in pipeline" "non-empty" "empty"
    return
  fi

  # Assert that the Part C trigger text contains at least one of the required
  # deprecation/relocation/rename keywords (case-insensitive).
  local has_keyword=false
  if echo "$part_c_text" | grep -qiE "deprecat|relocat|renam"; then
    has_keyword=true
  fi

  assert_eq \
    "Part C trigger must mention deprecating/relocating/renaming as a trigger condition" \
    "true" \
    "$has_keyword"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
test_part_c_contains_deprecation_trigger

print_summary
