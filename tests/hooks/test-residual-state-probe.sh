#!/usr/bin/env bash
# tests/hooks/test-residual-state-probe.sh
# Structural boundary test: asserts Part B of epic-scrutiny-pipeline.md
# contains a residual-state probe section identified by its canonical marker phrase.
#
# Per behavioral-testing-standard.md Rule 5 — for non-executable instruction files,
# test the structural boundary (section/contract marker exists), not prose content.
#
# Tests:
#   test_part_b_contains_residual_state_probe
#
# Usage: bash tests/hooks/test-residual-state-probe.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
LIB_DIR="$SCRIPT_DIR/../lib"

source "$LIB_DIR/assert.sh"

PIPELINE_MD="${REPO_ROOT}/plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md"

# ---------------------------------------------------------------------------
# test_part_b_contains_residual_state_probe
#
# Given: epic-scrutiny-pipeline.md exists and contains a Part B section
# When:  grep for the residual-state probe canonical marker phrase
#        "deprecate, relocate, or rename any file paths" within Part B
# Then:  the phrase is present (exit 0 from grep)
#
# The canonical phrase is the structural contract for the residual-state probe —
# it identifies the section boundary, not a specific wording choice.
# ---------------------------------------------------------------------------
test_part_b_contains_residual_state_probe() {
  echo "=== test_part_b_contains_residual_state_probe ==="

  if [ ! -f "$PIPELINE_MD" ]; then
    assert_eq "pipeline file exists" "true" "false"
    return
  fi

  # Extract Part B section: from "### Part B:" up to the next "### Part" heading
  local part_b_content
  part_b_content=$(awk '/^### Part B:/{found=1} found && /^### Part [^B]/{exit} found{print}' "$PIPELINE_MD")

  # Assert Part B section exists (non-empty extraction)
  if [ -z "$part_b_content" ]; then
    assert_eq "Part B section exists in pipeline" "non-empty" "empty"
    return
  fi

  # Assert residual-state probe canonical marker is present in Part B
  local probe_present="false"
  if echo "$part_b_content" | grep -q "deprecate, relocate, or rename any file paths"; then
    probe_present="true"
  fi

  assert_eq \
    "Part B contains residual-state probe marker 'deprecate, relocate, or rename any file paths'" \
    "true" \
    "$probe_present"
}

# ---------------------------------------------------------------------------
# Run tests
# ---------------------------------------------------------------------------
test_part_b_contains_residual_state_probe

print_summary
