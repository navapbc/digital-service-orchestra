#!/usr/bin/env bash
# tests/scripts/test-red-team-reviewer-dispatch-mode.sh
# RED tests asserting that all dispatch sites for dso:red-team-reviewer
# specify a mode: parameter. Tests FAIL until dispatch sites are updated.
#
# Story: 18b0-7c5d (inference-challenge mode for red-team-reviewer)
# Testing mode: RED (new behavior — mode: parameter not present at dispatch sites)
#
# Usage: bash tests/scripts/test-red-team-reviewer-dispatch-mode.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

PREPLANNING_SKILL="$REPO_ROOT/plugins/dso/skills/preplanning/SKILL.md"
SKILLS_DIR="$REPO_ROOT/plugins/dso/skills"

# ---------------------------------------------------------------------------
# test_preplanning_dispatch_has_mode
# Expect: preplanning/SKILL.md has a dso:red-team-reviewer dispatch with mode: nearby
# RED: mode: is not present at the dispatch site yet
# ---------------------------------------------------------------------------
test_preplanning_dispatch_has_mode() {
    # Find line numbers where dso:red-team-reviewer appears
    local dispatch_lines
    dispatch_lines=$(grep -n 'dso:red-team-reviewer' "$PREPLANNING_SKILL" 2>/dev/null || true)

    if [[ -z "$dispatch_lines" ]]; then
        # No dispatch found at all — counts as missing mode
        assert_eq "preplanning/SKILL.md dispatches dso:red-team-reviewer with mode:" \
            "present" "missing"
        return
    fi

    # For each dispatch line, check the surrounding 5 lines for mode:
    local found_mode=0
    while IFS= read -r line_entry; do
        local lineno
        lineno=$(echo "$line_entry" | cut -d: -f1)
        local start=$(( lineno - 2 ))
        local end=$(( lineno + 5 ))
        [[ $start -lt 1 ]] && start=1
        # Extract surrounding context and check for mode:
        if sed -n "${start},${end}p" "$PREPLANNING_SKILL" | grep -q 'mode:'; then
            found_mode=1
            break
        fi
    done <<< "$dispatch_lines"

    if [[ "$found_mode" -eq 1 ]]; then
        actual=present
    else
        actual=missing
    fi
    assert_eq "preplanning/SKILL.md dispatches dso:red-team-reviewer with mode: nearby" \
        "present" "$actual"
}

# ---------------------------------------------------------------------------
# test_no_dispatch_without_mode
# Expect: every occurrence of dso:red-team-reviewer in plugins/dso/skills/
#         has mode: within 5 lines
# RED: at least one dispatch site is missing mode: (fails until all updated)
# ---------------------------------------------------------------------------
test_no_dispatch_without_mode() {
    local missing_count=0
    local checked_count=0

    # Find all files under skills/ that reference dso:red-team-reviewer
    while IFS= read -r filepath; do
        # Get all line numbers with dispatch references
        while IFS= read -r line_entry; do
            [[ -z "$line_entry" ]] && continue
            local lineno
            lineno=$(echo "$line_entry" | cut -d: -f1)
            local start=$(( lineno - 2 ))
            local end=$(( lineno + 5 ))
            [[ $start -lt 1 ]] && start=1
            checked_count=$(( checked_count + 1 ))
            # Check surrounding lines for mode:
            if ! sed -n "${start},${end}p" "$filepath" | grep -q 'mode:'; then
                missing_count=$(( missing_count + 1 ))
            fi
        done < <(grep -n 'dso:red-team-reviewer' "$filepath" 2>/dev/null || true)
    done < <(grep -rl 'dso:red-team-reviewer' "$SKILLS_DIR" 2>/dev/null || true)

    # If no dispatch sites found at all, or any are missing mode:, fail RED
    if [[ "$checked_count" -eq 0 ]]; then
        # No dispatch sites found — the mode: requirement cannot be verified
        assert_eq "all dso:red-team-reviewer dispatch sites in skills/ have mode: (found dispatch sites)" \
            "present" "missing"
    elif [[ "$missing_count" -gt 0 ]]; then
        assert_eq "all dso:red-team-reviewer dispatch sites in skills/ have mode: ($missing_count missing)" \
            "0" "$missing_count"
    else
        assert_eq "all dso:red-team-reviewer dispatch sites in skills/ have mode:" \
            "0" "0"
    fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_preplanning_dispatch_has_mode
test_no_dispatch_without_mode

print_summary
