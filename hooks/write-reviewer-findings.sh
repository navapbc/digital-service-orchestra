#!/usr/bin/env bash
# lockpick-workflow/hooks/write-reviewer-findings.sh
#
# Compatibility shim — delegates to lockpick-workflow/scripts/write-reviewer-findings.sh.
#
# This file exists because orchestrators occasionally resolve the path as hooks/ instead of
# scripts/ when constructing the write-reviewer-findings.sh path from context. Both paths
# now work identically.
#
# Canonical location: lockpick-workflow/scripts/write-reviewer-findings.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/../scripts/write-reviewer-findings.sh" "$@"
