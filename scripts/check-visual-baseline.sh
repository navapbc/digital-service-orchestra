#!/usr/bin/env bash
# lockpick-workflow/scripts/check-visual-baseline.sh
# Checks the visual regression baseline state before running browser-based tests.
#
# Extracted from lockpick-workflow/skills/validate-work/SKILL.md Step 2b.
#
# Env vars (or positional args):
#   VISUAL_BASELINE_PATH  — relative path (from repo root) to the baseline snapshots dir
#   TEST_VISUAL_CMD       — command to run visual regression comparison on Linux/CI
#
# Outputs one of:
#   VISUAL_REGRESSION=skipped_macos (...)   — macOS, path configured but no baselines
#   VISUAL_REGRESSION=no_baselines (...)    — macOS, path configured, no PNG baselines
#   VISUAL_REGRESSION=skipped_macos (...)   — macOS, no path configured
#   VISUAL_REGRESSION=skipped (...)         — Linux, no TEST_VISUAL_CMD configured
#   <visual test output>                    — Linux, TEST_VISUAL_CMD ran
#
# Always exits 0 (output is informational, not a pass/fail gate).

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)

if [ "$(uname)" = "Darwin" ]; then
    # macOS: visual tests skip by design (font rendering differs ~11%)
    # Check if baselines exist using the configured path (or skip if not configured)
    if [ -n "${VISUAL_BASELINE_PATH:-}" ]; then
        BASELINE_COUNT=$(ls "$REPO_ROOT/$VISUAL_BASELINE_PATH"*.png 2>/dev/null | wc -l | tr -d ' ')
        if [ "$BASELINE_COUNT" -gt 0 ]; then
            echo "VISUAL_REGRESSION=skipped_macos (${BASELINE_COUNT} baselines exist, verified on CI only)"
        else
            echo "VISUAL_REGRESSION=no_baselines (run the visual baseline workflow to generate them)"
        fi
    else
        echo "VISUAL_REGRESSION=skipped_macos (no visual.baseline_directory configured)"
    fi
else
    # Linux/CI: run the actual comparison if configured
    if [ -n "${TEST_VISUAL_CMD:-}" ]; then
        cd "$REPO_ROOT" && eval "$TEST_VISUAL_CMD" 2>&1
    else
        echo "VISUAL_REGRESSION=skipped (no test_visual command configured)"
    fi
fi

exit 0
