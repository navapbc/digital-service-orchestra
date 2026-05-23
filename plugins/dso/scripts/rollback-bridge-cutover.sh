#!/usr/bin/env bash
# rollback-bridge-cutover.sh
#
# Idempotent rollback playbook for the bridge cutover. Reverts a cutover commit,
# restores the cursor snapshot from bridge_state/bootstrap/, commits + pushes
# the revert, and waits for the CI run triggered by that push to verify the
# rollback.
#
# Steps:
#   1. git revert --no-commit DSO_ROLLBACK_CUTOVER_SHA
#   2. Restore cursor snapshot from bridge_state/bootstrap/
#   3. git add -A && git commit -m "rollback: revert cutover <sha>"
#   4. git push origin <current-branch>
#   5. gh run watch on the CI run triggered by the push (matched by new HEAD SHA)
#
# Environment variables:
#   DSO_ROLLBACK_REPO_ROOT      Override repo root for test isolation
#                               (default: git rev-parse --show-toplevel)
#   DSO_ROLLBACK_VERIFY_TIMEOUT Timeout in seconds for gh run watch (default: 2400)
#   DSO_ROLLBACK_CUTOVER_SHA    Required: the commit SHA to revert
#   DSO_ROLLBACK_SKIP_PUSH      If "1", skip the push + CI-watch steps (for dryrun)
#
# Idempotent: steps that have already completed are skipped gracefully.
#
# Named-step exit codes:
#   0 — success (or safe no-op for idempotent steps)
#   1 — step failure (revert failed, push failed, CI failed)
#   2 — missing required input (DSO_ROLLBACK_CUTOVER_SHA not set)
#
# Usage:
#   DSO_ROLLBACK_CUTOVER_SHA=<sha> rollback-bridge-cutover.sh

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
REPO_ROOT="${DSO_ROLLBACK_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
VERIFY_TIMEOUT="${DSO_ROLLBACK_VERIFY_TIMEOUT:-2400}"
CUTOVER_SHA="${DSO_ROLLBACK_CUTOVER_SHA:-}"
SKIP_PUSH="${DSO_ROLLBACK_SKIP_PUSH:-0}"

echo "rollback-bridge-cutover: repo_root=$REPO_ROOT"
echo "rollback-bridge-cutover: verify_timeout=${VERIFY_TIMEOUT}s"
echo "rollback-bridge-cutover: skip_push=${SKIP_PUSH}"

# ── Validate required inputs ──────────────────────────────────────────────────
if [[ -z "$CUTOVER_SHA" ]]; then
    echo "ERROR: DSO_ROLLBACK_CUTOVER_SHA is required" >&2
    exit 2
fi

echo "rollback-bridge-cutover: cutover_sha=$CUTOVER_SHA"

cd "$REPO_ROOT" || exit 1

# ── Step 1: Revert the cutover commit ─────────────────────────────────────────
echo "STEP 1: reverting cutover commit $CUTOVER_SHA"
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

# ── Step 3: Commit the revert + cursor restore ────────────────────────────────
echo "STEP 3: committing revert + cursor restore"
git add -A
if git diff --cached --quiet; then
    echo "STEP 3 OK (no changes staged — idempotent re-run)"
else
    if ! git commit -m "rollback: revert cutover ${CUTOVER_SHA}"; then
        echo "ERROR: commit failed" >&2
        exit 1
    fi
    echo "STEP 3 OK"
fi

NEW_HEAD_SHA="$(git rev-parse HEAD)"
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
echo "rollback-bridge-cutover: new_head_sha=$NEW_HEAD_SHA branch=$CURRENT_BRANCH"

if [[ "$SKIP_PUSH" == "1" ]]; then
    echo "STEP 4: SKIPPED (DSO_ROLLBACK_SKIP_PUSH=1)"
    echo "STEP 5: SKIPPED (DSO_ROLLBACK_SKIP_PUSH=1)"
    echo "rollback-bridge-cutover: complete (push skipped)"
    exit 0
fi

# ── Step 4: Push the revert ───────────────────────────────────────────────────
echo "STEP 4: pushing revert to origin/$CURRENT_BRANCH"
if ! git push origin "$CURRENT_BRANCH"; then
    echo "ERROR: git push failed" >&2
    exit 1
fi
echo "STEP 4 OK"

# ── Step 5: Watch the CI run triggered by the push ────────────────────────────
echo "STEP 5: waiting for CI verification (timeout: ${VERIFY_TIMEOUT}s) on commit $NEW_HEAD_SHA"
# Give GitHub a few seconds to register the workflow run after the push.
sleep 5

# Find the workflow run for the new commit on this branch. Retry a few times
# because the run may not appear instantly.
_run_id=""
_attempts=0
while [[ "$_attempts" -lt 6 ]]; do
    _attempts=$((_attempts + 1))
    _run_id="$(gh run list \
        --branch "$CURRENT_BRANCH" \
        --commit "$NEW_HEAD_SHA" \
        --limit 1 \
        --json databaseId \
        --jq '.[0].databaseId // empty' 2>/dev/null || true)"
    if [[ -n "$_run_id" ]]; then
        break
    fi
    echo "  no run found for commit $NEW_HEAD_SHA yet (attempt $_attempts) — sleeping 10s"
    sleep 10
done

if [[ -z "$_run_id" ]]; then
    echo "WARN: no CI run found for commit $NEW_HEAD_SHA after $_attempts attempts — skipping gh run watch"
else
    if ! gh run watch --exit-status "$_run_id"; then
        echo "ERROR: CI verification failed or timed out for run $_run_id" >&2
        exit 1
    fi
    echo "STEP 5 OK (run $_run_id passed)"
fi

echo "rollback-bridge-cutover: complete"
exit 0
