#!/usr/bin/env bash
# scripts/end-session/end-session-cleanup.sh
# Performs end-session cleanup: removes Playwright CLI state directory, kills
# orphaned Chrome/Chromium processes spawned by @playwright/cli during this
# session, and deletes hash-suffixed config-cache files from the workflow
# artifacts directory. The primary `config-cache` file (no suffix) is kept.
#
# Replaces the inline bash block in /dso:end-session Step 13 (Clean Up Artifacts Directory).
#
# Usage:
#   bash scripts/end-session/end-session-cleanup.sh
# Env:
#   ARTIFACTS_DIR — overrides artifacts dir (default: resolved via deps.sh).
#   SKIP_PROCESS_KILL — when "1", skips the pgrep/kill step (used by tests).
# Exit codes:
#   0 — always (cleanup is best-effort; a failure to kill a process or delete a
#       file should not block session close).

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# --- Playwright CLI state directory ---
if [[ -d "$REPO_ROOT/.playwright-cli" ]]; then
    rm -rf "$REPO_ROOT/.playwright-cli"
    echo "Removed .playwright-cli/ state directory"
fi

# --- Orphan Chrome/Chromium processes spawned by @playwright/cli ---
# Uses ERE alternation (bare |, not \|) — macOS pgrep requires ERE syntax.
if [[ "${SKIP_PROCESS_KILL:-0}" != "1" ]]; then
    # Tightly-scoped patterns only — avoid matching unrelated Chrome debug
    # sessions (VSCode debugger, Puppeteer, etc) that also use remote-debugging.
    ORPHAN_CHROME=$(pgrep -u "$(id -u)" -f \
        "playwright.*cli.*chromium|chromium.*playwright.*cli|\.playwright-cli.*chrome|ms-playwright.*chromium" \
        2>/dev/null || true)
    if [[ -n "$ORPHAN_CHROME" ]]; then
        CHROME_COUNT=$(echo "$ORPHAN_CHROME" | wc -l | tr -d ' ')
        echo "$ORPHAN_CHROME" | xargs kill 2>/dev/null || true
        echo "Killed $CHROME_COUNT orphaned Playwright browser process(es)"
    fi
fi

# --- Hash-suffixed config-cache files ---
_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$_PLUGIN_ROOT/hooks/lib/deps.sh" 2>/dev/null || true
if [[ -z "${ARTIFACTS_DIR:-}" ]] && type get_artifacts_dir >/dev/null 2>&1; then
    ARTIFACTS_DIR=$(get_artifacts_dir)
fi

if [[ -n "${ARTIFACTS_DIR:-}" && -d "${ARTIFACTS_DIR}" ]]; then
    CACHE_COUNT=$(find "$ARTIFACTS_DIR" -name 'config-cache-*' -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$CACHE_COUNT" -gt 0 ]]; then
        find "$ARTIFACTS_DIR" -name 'config-cache-*' -type f -delete
        echo "Cleaned up $CACHE_COUNT stale config-cache files from $ARTIFACTS_DIR"
    fi
fi

exit 0
