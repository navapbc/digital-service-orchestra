#!/usr/bin/env bash
# sync-sub-pr-ruleset.sh
#
# Idempotently align the live "DSO Sub-PR Review Enforcement" GitHub
# branch ruleset's `conditions.ref_name` shape with the canonical
# negative-list design: include=["~ALL"], exclude=["refs/heads/main"].
#
# Why this script exists: provision-ruleset.sh emits the correct ruleset
# shape on initial creation (POST), but never updates an existing ruleset.
# When the ruleset was provisioned under an older allowlist design (or
# drifted via manual API edits), the live ruleset silently allows PRs to
# bypass sub-PR review enforcement. This helper brings the live ruleset
# back in sync, idempotent and safe to re-run.
#
# Usage:
#   sync-sub-pr-ruleset.sh [--repo <owner/repo>]
#                          [--ruleset-name <name>]
#                          [--dry-run] [-h|--help]
#
# Exit codes:
#   0 — already in sync, OR PATCH succeeded, OR dry-run complete
#   1 — error (missing tool, API failure, invalid args, ruleset not found)

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
REPO=""
RULESET_NAME="DSO Sub-PR Review Enforcement"
DRY_RUN=0

# The canonical negative-list scope (matches provision-ruleset.sh).
EXPECTED_INCLUDE='["~ALL"]'
EXPECTED_EXCLUDE='["refs/heads/main"]'

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            REPO="${2:-}"
            shift 2
            ;;
        --repo=*)
            REPO="${1#--repo=}"
            shift
            ;;
        --ruleset-name)
            RULESET_NAME="${2:-}"
            shift 2
            ;;
        --ruleset-name=*)
            RULESET_NAME="${1#--ruleset-name=}"
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Error: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# ── Tool checks ───────────────────────────────────────────────────────────────
for _tool in gh jq; do
    if ! command -v "$_tool" >/dev/null 2>&1; then
        echo "Error: required tool not found: $_tool" >&2
        exit 1
    fi
done

# ── Resolve repo ──────────────────────────────────────────────────────────────
if [[ -z "$REPO" ]]; then
    REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
    if [[ -z "$REPO" ]]; then
        echo "Error: --repo not provided and could not auto-detect from git remote" >&2
        exit 1
    fi
fi

# ── Locate the ruleset by name ────────────────────────────────────────────────
echo "Repo:           $REPO"
echo "Ruleset name:   $RULESET_NAME"

RULESET_ID=$(gh api "/repos/${REPO}/rulesets" 2>/dev/null \
    | jq -r --arg name "$RULESET_NAME" '.[] | select(.name == $name) | .id' \
    | head -1)

if [[ -z "$RULESET_ID" ]]; then
    echo "Error: ruleset '$RULESET_NAME' not found on $REPO" >&2
    echo "Hint:  run provision-ruleset.sh first to create the ruleset." >&2
    exit 1
fi
echo "Ruleset ID:     $RULESET_ID"

# ── Fetch current state ───────────────────────────────────────────────────────
RULESET_JSON=$(gh api "/repos/${REPO}/rulesets/${RULESET_ID}")
CURRENT_INCLUDE=$(echo "$RULESET_JSON" | jq -c '.conditions.ref_name.include')
CURRENT_EXCLUDE=$(echo "$RULESET_JSON" | jq -c '.conditions.ref_name.exclude')

# ── Diff: expected vs current ─────────────────────────────────────────────────
_inc_drift=$(jq -n --argjson e "$EXPECTED_INCLUDE" --argjson c "$CURRENT_INCLUDE" '($e - $c) + ($c - $e) | length')
_exc_drift=$(jq -n --argjson e "$EXPECTED_EXCLUDE" --argjson c "$CURRENT_EXCLUDE" '($e - $c) + ($c - $e) | length')

if (( _inc_drift == 0 )) && (( _exc_drift == 0 )); then
    echo "DECISION: SKIP — ruleset already matches negative-list shape"
    exit 0
fi

echo "DECISION: $([ "$DRY_RUN" -eq 1 ] && echo "DRY-RUN PATCH" || echo "PATCH") — drift detected"
echo "  current include: $CURRENT_INCLUDE"
echo "  expected include: $EXPECTED_INCLUDE"
echo "  current exclude: $CURRENT_EXCLUDE"
echo "  expected exclude: $EXPECTED_EXCLUDE"

# ── Build PATCH payload ───────────────────────────────────────────────────────
PATCH_PAYLOAD=$(echo "$RULESET_JSON" | jq \
    --argjson include "$EXPECTED_INCLUDE" \
    --argjson exclude "$EXPECTED_EXCLUDE" \
    '{
        "name": .name,
        "target": .target,
        "enforcement": .enforcement,
        "conditions": (.conditions | .ref_name.include = $include | .ref_name.exclude = $exclude),
        "bypass_actors": (.bypass_actors // []),
        "rules": .rules
    }')

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo ""
    echo "--- Dry-run PATCH payload (not sent) ---"
    echo "$PATCH_PAYLOAD"
    exit 0
fi

# ── Apply ─────────────────────────────────────────────────────────────────────
TMPFILE=$(mktemp /tmp/sync-sub-pr-ruleset.XXXXXX)
trap 'rm -f "$TMPFILE"' EXIT
echo "$PATCH_PAYLOAD" > "$TMPFILE"

echo ""
echo "Applying PATCH to ruleset $RULESET_ID ..."
gh api --method PUT "/repos/${REPO}/rulesets/${RULESET_ID}" --input "$TMPFILE" >/dev/null

# ── Verify ────────────────────────────────────────────────────────────────────
POST_INCLUDE=$(gh api "/repos/${REPO}/rulesets/${RULESET_ID}" --jq '.conditions.ref_name.include' | jq -c '.')
POST_EXCLUDE=$(gh api "/repos/${REPO}/rulesets/${RULESET_ID}" --jq '.conditions.ref_name.exclude' | jq -c '.')
_post_inc_drift=$(jq -n --argjson e "$EXPECTED_INCLUDE" --argjson p "$POST_INCLUDE" '($e - $p) + ($p - $e) | length')
_post_exc_drift=$(jq -n --argjson e "$EXPECTED_EXCLUDE" --argjson p "$POST_EXCLUDE" '($e - $p) + ($p - $e) | length')
if (( _post_inc_drift != 0 )) || (( _post_exc_drift != 0 )); then
    echo "Error: post-PATCH verification failed — ruleset still drifted" >&2
    echo "  include: $POST_INCLUDE (expected $EXPECTED_INCLUDE)" >&2
    echo "  exclude: $POST_EXCLUDE (expected $EXPECTED_EXCLUDE)" >&2
    exit 1
fi

echo "OK: ruleset '$RULESET_NAME' (ID $RULESET_ID) now matches negative-list shape"
