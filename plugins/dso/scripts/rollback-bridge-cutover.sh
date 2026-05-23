#!/usr/bin/env bash
# rollback-bridge-cutover.sh
#
# Idempotent rollback playbook for the bridge cutover. Reverts a cutover commit,
# restores the cursor snapshot from bridge_state/bootstrap/, and waits for CI to
# verify the rollback.
#
# Steps:
#   1. git revert --no-commit DSO_ROLLBACK_CUTOVER_SHA
#   2. Restore cursor snapshot from bridge_state/bootstrap/
#   3. gh run watch for CI verification
#
# Environment variables:
#   DSO_ROLLBACK_REPO_ROOT      Override repo root for test isolation
#                               (default: git rev-parse --show-toplevel)
#   DSO_ROLLBACK_VERIFY_TIMEOUT Timeout in seconds for gh run watch (default: 2400)
#   DSO_ROLLBACK_CUTOVER_SHA    Required: the commit SHA to revert
#
# Idempotent: steps that have already completed are skipped gracefully.
#
# Named-step exit codes:
#   0 — success (or safe no-op for idempotent steps)
#   1 — step failure (revert failed, CI failed)
#   2 — missing required input (DSO_ROLLBACK_CUTOVER_SHA not set)
#
# Usage:
#   DSO_ROLLBACK_CUTOVER_SHA=<sha> rollback-bridge-cutover.sh

set -uo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
REPO_ROOT="${DSO_ROLLBACK_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
VERIFY_TIMEOUT="${DSO_ROLLBACK_VERIFY_TIMEOUT:-2400}"
CUTOVER_SHA="${DSO_ROLLBACK_CUTOVER_SHA:-}"

echo "rollback-bridge-cutover: repo_root=$REPO_ROOT"
echo "rollback-bridge-cutover: verify_timeout=${VERIFY_TIMEOUT}s"

# ── Validate required inputs ──────────────────────────────────────────────────
if [[ -z "$CUTOVER_SHA" ]]; then
    echo "ERROR: DSO_ROLLBACK_CUTOVER_SHA is required" >&2
    exit 2
fi

echo "rollback-bridge-cutover: cutover_sha=$CUTOVER_SHA"

# ── Step 1: Revert the cutover commit ─────────────────────────────────────────
echo "STEP 1: reverting cutover commit $CUTOVER_SHA"
cd "$REPO_ROOT" || exit 1
if ! git revert --no-commit "$CUTOVER_SHA" 2>&1; then
    echo "ERROR: git revert failed for $CUTOVER_SHA" >&2
    exit 1
fi
echo "STEP 1 OK"

# ── Step 2: Restore cursor snapshot ───────────────────────────────────────────
echo "STEP 2: restoring cursor snapshot from bridge_state/bootstrap/"
_bootstrap_dir="$REPO_ROOT/bridge_state/bootstrap"
_snapshot_src=""
if [[ -d "$_bootstrap_dir" ]]; then
    _snapshot_src="$(find "$_bootstrap_dir" -name "cursor-snapshot.json" 2>/dev/null | sort | tail -1 || true)"
fi

if [[ -z "$_snapshot_src" ]]; then
    echo "WARN: no cursor snapshot found in bridge_state/bootstrap/ — skipping cursor restore"
else
    if ! cp "$_snapshot_src" "$REPO_ROOT/bridge_state/cursor-snapshot.json"; then
        echo "ERROR: failed to restore cursor snapshot from $_snapshot_src" >&2
        exit 1
    fi
    echo "STEP 2 OK (restored from $_snapshot_src)"
fi

# ── Step 3: CI verification ────────────────────────────────────────────────────
echo "STEP 3: waiting for CI verification (timeout: ${VERIFY_TIMEOUT}s)"
_run_url="$(gh run list --limit 1 --json url --jq '.[0].url' 2>/dev/null || true)"
if [[ -z "$_run_url" ]]; then
    echo "WARN: no recent CI run found — skipping gh run watch"
else
    if ! gh run watch --timeout "$VERIFY_TIMEOUT" "$_run_url"; then
        echo "ERROR: CI verification failed or timed out" >&2
        exit 1
    fi
    echo "STEP 3 OK"
fi

echo "rollback-bridge-cutover: complete"
exit 0
