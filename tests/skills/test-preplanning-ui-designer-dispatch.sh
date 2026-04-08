#!/usr/bin/env bash
# tests/skills/test-preplanning-ui-designer-dispatch.sh
# RED tests for the preplanning/ui-designer integration.
#
# Validates that:
#   1. validate-review-output.sh --list-callers includes ui-designer
#   2. validate-review-output.sh accepts --caller ui-designer for review-protocol
#   3. preplanning/SKILL.md dispatches dso:ui-designer (not /dso:design-wireframe)
#
# All three assertions FAIL (RED) until the implementation is complete:
#   - validate-review-output.sh is not yet updated to register ui-designer
#   - preplanning/SKILL.md still references /dso:design-wireframe
#
# Usage: bash tests/skills/test-preplanning-ui-designer-dispatch.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

VALIDATE_SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/validate-review-output.sh"
PREPLANNING_SKILL="$PLUGIN_ROOT/plugins/dso/skills/preplanning/SKILL.md"

# Cleanup temp directories on exit
_TEST_TMPDIRS=()
trap 'rm -rf "${_TEST_TMPDIRS[@]}"' EXIT

TMP_DIR="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMP_DIR")

# ============================================================
# Test 1: validate-review-output.sh --list-callers includes ui-designer
#
# Observable behavior: the script's stdout when called with --list-callers
# must contain the string "ui-designer".
# RED: ui-designer is not yet registered as a caller.
# ============================================================

test_validate_lists_ui_designer() {
    local callers_output
    callers_output=$(bash "$VALIDATE_SCRIPT" --list-callers 2>/dev/null)
    local exit_code=$?

    assert_eq \
        "test_validate_lists_ui_designer: --list-callers exits 0" \
        "0" \
        "$exit_code"

    assert_contains \
        "test_validate_lists_ui_designer: --list-callers output includes ui-designer" \
        "ui-designer" \
        "$callers_output"
}

test_validate_lists_ui_designer

# ============================================================
# Test 2: validate-review-output.sh accepts --caller ui-designer
#
# Observable behavior: the script exits 0 when given a valid review-protocol
# fixture and --caller ui-designer.
# RED: ui-designer is not a known caller; the script exits non-zero (exit 2)
# with "unknown caller-id" on stderr.
#
# Fixture uses the 4 perspectives defined in the ui-designer-payload contract:
#   Product Management, Design Systems, Accessibility, Frontend Engineering
# ============================================================

test_validate_accepts_ui_designer_review() {
    local fixture_file="$TMP_DIR/ui-designer-r2-fixture.json"
    cat > "$fixture_file" <<'EOF'
{
  "subject": "UI story wireframe review",
  "reviews": [
    {
      "perspective": "Product Management",
      "status": "reviewed",
      "dimensions": {"feasibility": 4, "scope": 4},
      "findings": []
    },
    {
      "perspective": "Design Systems",
      "status": "reviewed",
      "dimensions": {"consistency": 4, "components": 4},
      "findings": []
    },
    {
      "perspective": "Accessibility",
      "status": "reviewed",
      "dimensions": {"wcag": 4, "keyboard": 4},
      "findings": []
    },
    {
      "perspective": "Frontend Engineering",
      "status": "reviewed",
      "dimensions": {"implementation": 4, "performance": 4},
      "findings": []
    }
  ],
  "conflicts": []
}
EOF

    local exit_code=0
    bash "$VALIDATE_SCRIPT" review-protocol "$fixture_file" --caller ui-designer \
        >/dev/null 2>&1 || exit_code=$?

    assert_eq \
        "test_validate_accepts_ui_designer_review: validate-review-output.sh exits 0 with --caller ui-designer" \
        "0" \
        "$exit_code"
}

test_validate_accepts_ui_designer_review

# ============================================================
# Test 3: preplanning/SKILL.md dispatches dso:ui-designer
#
# Observable behavior: the SKILL.md instruction file must reference
# dso:ui-designer (Agent tool dispatch) rather than /dso:design-wireframe
# in its UI story dispatch section.
#
# RED: SKILL.md still references /dso:design-wireframe; dso:ui-designer
# dispatch has not been added.
#
# Note: This tests the LLM instruction contract — SKILL.md is the executable
# specification consumed by the preplanning orchestrator. The presence of
# dso:ui-designer in SKILL.md IS the behavioral artifact: without it, the
# preplanning orchestrator will not dispatch dso:ui-designer.
# ============================================================

test_preplanning_dispatches_ui_designer() {
    local skill_content
    skill_content=$(< "$PREPLANNING_SKILL")

    # SKILL.md must reference dso:ui-designer dispatch
    local has_ui_designer=0
    if (echo "$skill_content" | grep -qF "dso:ui-designer" ||         echo "$skill_content" | grep -qF "ui-designer") &&        ! echo "$skill_content" | grep -qE "^#.*ui-designer"; then
        has_ui_designer=1
    fi

    assert_eq \
        "test_preplanning_dispatches_ui_designer: SKILL.md contains dso:ui-designer dispatch reference" \
        "1" \
        "$has_ui_designer"

    # SKILL.md must reference UI_DESIGNER_PAYLOAD signal
    local has_payload_signal=0
    if echo "$skill_content" | grep -qF "UI_DESIGNER_PAYLOAD"; then
        has_payload_signal=1
    fi

    assert_eq \
        "test_preplanning_dispatches_ui_designer: SKILL.md contains UI_DESIGNER_PAYLOAD consumption" \
        "1" \
        "$has_payload_signal"
}

test_preplanning_dispatches_ui_designer

# ============================================================
# Summary
# ============================================================

print_summary
