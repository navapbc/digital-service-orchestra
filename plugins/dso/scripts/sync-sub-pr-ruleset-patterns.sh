#!/usr/bin/env bash
# sync-sub-pr-ruleset-patterns.sh
#
# Idempotently align the live "DSO Sub-PR Review Enforcement" GitHub
# branch ruleset's `conditions.ref_name.include` array with the
# source-of-truth file at <plugin-root>/config/sub-pr-branch-patterns.txt.
#
# Why this script exists: provision-ruleset.sh emits the correct
# include array on initial creation (POST), but never updates an
# existing ruleset. When patterns are added/removed from the
# source-of-truth file after provisioning, the live ruleset silently
# drifts — sub-PR branches matching the new patterns bypass the
# review-sub-pr enforcement even though the workflow trigger fires
# (so the check runs but the ruleset doesn't require it).
#
# Usage:
#   sync-sub-pr-ruleset-patterns.sh [--repo <owner/repo>]
#                                    [--ruleset-name <name>]
#                                    [--patterns-file <path>]
#                                    [--dry-run] [-h|--help]
#
# Exit codes:
#   0 — already in sync, OR PATCH succeeded, OR dry-run complete
#   1 — error (missing tool/file, API failure, invalid args)

set -euo pipefail

# ── Self-location ─────────────────────────────────────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/ → <plugin-root>; resolved via CLAUDE_PLUGIN_ROOT when available.
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$_SCRIPT_DIR/.." 2>/dev/null && pwd || echo '')}"

# ── Defaults ──────────────────────────────────────────────────────────────────
REPO=""
RULESET_NAME="DSO Sub-PR Review Enforcement"
PATTERNS_FILE="${_PLUGIN_ROOT}/config/sub-pr-branch-patterns.txt"
DRY_RUN=0

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
        --patterns-file)
            PATTERNS_FILE="${2:-}"
            shift 2
            ;;
        --patterns-file=*)
            PATTERNS_FILE="${1#--patterns-file=}"
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# ── Validate patterns file ────────────────────────────────────────────────────
if [[ ! -f "$PATTERNS_FILE" ]]; then
    echo "Error: patterns file not found: $PATTERNS_FILE" >&2
    exit 1
fi

set +e
_pattern_count=$(grep -cvE '^[[:space:]]*#|^[[:space:]]*$' "$PATTERNS_FILE" 2>/dev/null)
set -e
_pattern_count="${_pattern_count:-0}"
if (( _pattern_count == 0 )); then
    echo "Error: patterns file contains zero active patterns: $PATTERNS_FILE" >&2
    echo "Error: refusing to PATCH ruleset with empty include array — would silently" >&2
    echo "Error: disable sub-PR review enforcement (empty include matches no branches)" >&2
    exit 1
fi

# ── Build expected include array ──────────────────────────────────────────────
EXPECTED_INCLUDE=$(
    grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$PATTERNS_FILE" \
        | jq -R '"refs/heads/" + .' \
        | jq -s '.'
)

# ── Locate the ruleset by name ────────────────────────────────────────────────
echo "Repo:           $REPO"
echo "Ruleset name:   $RULESET_NAME"
echo "Patterns file:  $PATTERNS_FILE"
echo "Active patterns: ${_pattern_count}"

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
CURRENT_INCLUDE=$(echo "$RULESET_JSON" | jq '.conditions.ref_name.include')

# ── Diff: expected vs current ─────────────────────────────────────────────────
_added=$(jq -n --argjson e "$EXPECTED_INCLUDE" --argjson c "$CURRENT_INCLUDE" '$e - $c')
_removed=$(jq -n --argjson e "$EXPECTED_INCLUDE" --argjson c "$CURRENT_INCLUDE" '$c - $e')
_added_count=$(echo "$_added" | jq 'length')
_removed_count=$(echo "$_removed" | jq 'length')

if (( _added_count == 0 )) && (( _removed_count == 0 )); then
    echo "DECISION: SKIP — ruleset already in sync ($_pattern_count patterns match)"
    exit 0
fi

echo "DECISION: $([ "$DRY_RUN" -eq 1 ] && echo "DRY-RUN PATCH" || echo "PATCH") — drift detected"
if (( _added_count > 0 )); then
    echo "  Patterns to ADD ($_added_count):"
    echo "$_added" | jq -r '.[] | "    + " + .'
fi
if (( _removed_count > 0 )); then
    echo "  Patterns to REMOVE ($_removed_count):"
    echo "$_removed" | jq -r '.[] | "    - " + .'
fi

# ── Build PATCH payload ───────────────────────────────────────────────────────
# Reuse the existing ruleset shape; only mutate conditions.ref_name.include.
PATCH_PAYLOAD=$(echo "$RULESET_JSON" | jq \
    --argjson include "$EXPECTED_INCLUDE" \
    '{
        "name": .name,
        "target": .target,
        "enforcement": .enforcement,
        "conditions": (.conditions | .ref_name.include = $include),
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
POST_INCLUDE=$(gh api "/repos/${REPO}/rulesets/${RULESET_ID}" --jq '.conditions.ref_name.include')
POST_DIFF=$(jq -n --argjson e "$EXPECTED_INCLUDE" --argjson p "$POST_INCLUDE" '($e - $p) + ($p - $e)')
if [[ "$(echo "$POST_DIFF" | jq 'length')" != "0" ]]; then
    echo "Error: post-PATCH verification failed — ruleset still drifted:" >&2
    echo "$POST_DIFF" >&2
    exit 1
fi

echo "OK: ruleset '$RULESET_NAME' (ID $RULESET_ID) now lists ${_pattern_count} patterns"
