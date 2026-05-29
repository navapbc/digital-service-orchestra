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
DEFAULT_BRANCH_OVERRIDE="${DSO_DEFAULT_BRANCH:-}"

# Include is fixed by the negative-list design ("~ALL"). Exclude is computed
# at runtime from the host's default branch (resolved below after REPO).
EXPECTED_INCLUDE='["~ALL"]'

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
# JSON parsing is done via python3 per plugin-script convention (no jq —
# see .coderabbit.yaml and reviewer-delta-standard.md).
for _tool in gh python3; do
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

# ── Resolve default branch via shared helper ─────────────────────────────────
# Four-tier fallback implemented in lib/default-branch.sh — kept identical
# to provision-ruleset.sh by sourcing the same library.
_SYNC_DEFAULT_BRANCH_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd || echo '')/default-branch.sh"
# shellcheck source=lib/default-branch.sh
source "$_SYNC_DEFAULT_BRANCH_LIB"
DEFAULT_BRANCH=$(DSO_DEFAULT_BRANCH="$DEFAULT_BRANCH_OVERRIDE" _dso_resolve_default_branch "$REPO")
EXPECTED_EXCLUDE="[\"refs/heads/${DEFAULT_BRANCH}\"]"

# ── Locate the ruleset by name ────────────────────────────────────────────────
echo "Repo:           $REPO"
echo "Ruleset name:   $RULESET_NAME"

RULESET_ID=$(gh api "/repos/${REPO}/rulesets" 2>/dev/null \
    | python3 -c "
import json, sys
name = sys.argv[1]
data = json.loads(sys.stdin.read() or '[]')
for r in data:
    if isinstance(r, dict) and r.get('name') == name:
        print(r.get('id', ''))
        break
" "$RULESET_NAME")

if [[ -z "$RULESET_ID" ]]; then
    echo "Error: ruleset '$RULESET_NAME' not found on $REPO" >&2
    echo "Hint:  run provision-ruleset.sh first to create the ruleset." >&2
    exit 1
fi
echo "Ruleset ID:     $RULESET_ID"

# ── Fetch current state ───────────────────────────────────────────────────────
RULESET_JSON=$(gh api "/repos/${REPO}/rulesets/${RULESET_ID}")
CURRENT_INCLUDE=$(echo "$RULESET_JSON" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print(json.dumps(d.get('conditions', {}).get('ref_name', {}).get('include', [])))
")
CURRENT_EXCLUDE=$(echo "$RULESET_JSON" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print(json.dumps(d.get('conditions', {}).get('ref_name', {}).get('exclude', [])))
")

# ── Diff: expected vs current (symmetric-difference cardinality) ─────────────
_inc_drift=$(python3 -c "
import json, sys
a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2])
print(len(set(a) ^ set(b)))
" "$EXPECTED_INCLUDE" "$CURRENT_INCLUDE")
_exc_drift=$(python3 -c "
import json, sys
a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2])
print(len(set(a) ^ set(b)))
" "$EXPECTED_EXCLUDE" "$CURRENT_EXCLUDE")

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
PATCH_PAYLOAD=$(echo "$RULESET_JSON" | python3 -c "
import json, sys
base = json.loads(sys.stdin.read())
include = json.loads(sys.argv[1])
exclude = json.loads(sys.argv[2])
conditions = dict(base.get('conditions', {}))
ref_name = dict(conditions.get('ref_name', {}))
ref_name['include'] = include
ref_name['exclude'] = exclude
conditions['ref_name'] = ref_name
print(json.dumps({
    'name': base.get('name'),
    'target': base.get('target'),
    'enforcement': base.get('enforcement'),
    'conditions': conditions,
    'bypass_actors': base.get('bypass_actors') or [],
    'rules': base.get('rules') or [],
}, indent=2))
" "$EXPECTED_INCLUDE" "$EXPECTED_EXCLUDE")

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo ""
    echo "--- Dry-run PATCH payload (not sent) ---"
    echo "$PATCH_PAYLOAD"
    exit 0
fi

# ── Apply ─────────────────────────────────────────────────────────────────────
TMPFILE=$(mktemp "${TMPDIR:-/tmp}/sync-sub-pr-ruleset.XXXXXX")
trap 'rm -f "$TMPFILE"' EXIT
echo "$PATCH_PAYLOAD" > "$TMPFILE"

echo ""
echo "Applying PATCH to ruleset $RULESET_ID ..."
gh api --method PUT "/repos/${REPO}/rulesets/${RULESET_ID}" --input "$TMPFILE" >/dev/null

# ── Verify ────────────────────────────────────────────────────────────────────
POST_RULESET=$(gh api "/repos/${REPO}/rulesets/${RULESET_ID}")
POST_INCLUDE=$(echo "$POST_RULESET" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print(json.dumps(d.get('conditions', {}).get('ref_name', {}).get('include', [])))
")
POST_EXCLUDE=$(echo "$POST_RULESET" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print(json.dumps(d.get('conditions', {}).get('ref_name', {}).get('exclude', [])))
")
_post_inc_drift=$(python3 -c "
import json, sys
a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2])
print(len(set(a) ^ set(b)))
" "$EXPECTED_INCLUDE" "$POST_INCLUDE")
_post_exc_drift=$(python3 -c "
import json, sys
a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2])
print(len(set(a) ^ set(b)))
" "$EXPECTED_EXCLUDE" "$POST_EXCLUDE")
if (( _post_inc_drift != 0 )) || (( _post_exc_drift != 0 )); then
    echo "Error: post-PATCH verification failed — ruleset still drifted" >&2
    echo "  include: $POST_INCLUDE (expected $EXPECTED_INCLUDE)" >&2
    echo "  exclude: $POST_EXCLUDE (expected $EXPECTED_EXCLUDE)" >&2
    exit 1
fi

echo "OK: ruleset '$RULESET_NAME' (ID $RULESET_ID) now matches negative-list shape"
