#!/usr/bin/env bash
# lockpick-workflow/scripts/check-plugin-test-needed.sh
# Determines whether plugin tests should run based on the list of changed files.
#
# Usage: git diff HEAD --name-only | bash check-plugin-test-needed.sh
# Reads file list from stdin, one file per line.
# Exits 0 if any changed file matches a plugin-relevant pattern (tests needed).
# Exits 1 if no changed file matches (tests not needed).
#
# Patterns (extracted from COMMIT-WORKFLOW.md Step 1.75):
#   lockpick-workflow/hooks/*
#   lockpick-workflow/scripts/*
#   lockpick-workflow/skills/*
#   scripts/*
#   .pre-commit-config.yaml
#   Makefile
#   app/Makefile

set -uo pipefail

PLUGIN_CHANGED=false

while IFS= read -r f; do
    case "$f" in
        lockpick-workflow/hooks/*|lockpick-workflow/scripts/*|lockpick-workflow/skills/*|scripts/*|.pre-commit-config.yaml|Makefile|app/Makefile)
            PLUGIN_CHANGED=true; break ;;
    esac
done

if [ "$PLUGIN_CHANGED" = "true" ]; then
    exit 0
else
    exit 1
fi
