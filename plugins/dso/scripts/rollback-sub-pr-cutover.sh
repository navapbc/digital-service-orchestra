#!/usr/bin/env bash
# rollback-sub-pr-cutover.sh
#
# Rolls back the sub-PR cutover migration.
#
# Steps:
#   1. Remove .github/workflows/review-sub-pr.yml (Phase 4 reverse).
#   2. Remove migration-grace labels from open PRs (Phase 1 reverse).
#   3. Read cycle-ledger.json if present; skip ledger steps gracefully on
#      missing or corrupted file (DD5: no v1.2.0 dependency).
#
# Environment variables:
#   DSO_ROLLBACK_REPO_ROOT        Override repo root for test isolation
#                                 (default: git rev-parse --show-toplevel)
#   WORKFLOW_PLUGIN_ARTIFACTS_DIR Override artifacts dir for ledger lookup
#                                 (default: .workflow-plugin-artifacts in repo root)
#
# Idempotent: re-running on an already-rolled-back state exits 0.
#
# Usage:
#   rollback-sub-pr-cutover.sh

set -uo pipefail

# ── Resolve repo root ─────────────────────────────────────────────────────────
if [[ -n "${DSO_ROLLBACK_REPO_ROOT:-}" ]]; then
    _repo_root="$DSO_ROLLBACK_REPO_ROOT"
else
    _repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

# ── Resolve artifacts directory (for ledger) ──────────────────────────────────
if [[ -n "${WORKFLOW_PLUGIN_ARTIFACTS_DIR:-}" ]]; then
    _artifacts_dir="$WORKFLOW_PLUGIN_ARTIFACTS_DIR"
else
    _artifacts_dir="$_repo_root/.workflow-plugin-artifacts"
fi

echo "rollback-sub-pr-cutover: repo_root=$_repo_root"
echo "rollback-sub-pr-cutover: artifacts_dir=$_artifacts_dir"

# ── Step 1: Remove review-sub-pr.yml workflow file (Phase 4 reverse) ─────────
_workflow_file="$_repo_root/.github/workflows/review-sub-pr.yml"
if [[ -f "$_workflow_file" ]]; then
    echo "Removing workflow file: $_workflow_file"
    rm -f "$_workflow_file"
    echo "Removed: $_workflow_file"
else
    echo "Workflow file already absent (already rolled back or never applied): $_workflow_file"
fi

# ── Step 2: Remove migration-grace labels from PRs (Phase 1 reverse) ─────────
echo "Querying for PRs with migration-grace label..."
_pr_json="$(gh pr list --label "migration-grace" --json number 2>/dev/null || true)"

if [[ -z "$_pr_json" ]] || [[ "$_pr_json" == "[]" ]] || [[ "$_pr_json" == "null" ]]; then
    echo "No open PRs with migration-grace label found."
else
    # Extract PR numbers via python3 (jq-free)
    _pr_numbers="$(printf '%s' "$_pr_json" | python3 -c '
import json, sys
try:
    arr = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for entry in (arr if isinstance(arr, list) else []):
    if isinstance(entry, dict) and "number" in entry:
        print(entry["number"])
' 2>/dev/null || true)"

    if [[ -z "$_pr_numbers" ]]; then
        echo "No PR numbers extracted from gh response."
    else
        while IFS= read -r _pr_num; do
            [[ -z "$_pr_num" ]] && continue
            echo "Removing migration-grace label from PR #${_pr_num}"
            gh pr edit "$_pr_num" --remove-label "migration-grace" 2>/dev/null || true
        done <<< "$_pr_numbers"
    fi
fi

# ── Step 3: Inspect cycle-ledger.json (informational only; DD5) ───────────────
# DD5: Rollback MUST NOT depend on v1.2.0 ledger being intact.
# Read ledger for informational logging only; any error is non-fatal.
_ledger_file="$_artifacts_dir/cycle-ledger.json"
if [[ -f "$_ledger_file" ]]; then
    echo "Found cycle-ledger.json at: $_ledger_file"
    _ledger_ver="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get("schema_version", "unknown") if isinstance(d, dict) else "unknown")
except Exception:
    print("corrupted")
' "$_ledger_file" 2>/dev/null || echo "corrupted")"
    echo "Ledger version: $_ledger_ver (informational only — rollback proceeds regardless)"
else
    echo "No cycle-ledger.json found at: $_ledger_file (treating as absent — OK)"
fi

echo "rollback-sub-pr-cutover: complete"
exit 0
