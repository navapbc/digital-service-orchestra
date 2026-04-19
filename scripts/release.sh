#!/usr/bin/env bash
set -euo pipefail
# scripts/release.sh — Automated release script with sequential precondition gating.
#
# Usage:
#   scripts/release.sh [<VERSION>] [--yes]
#
# Arguments:
#   VERSION  Semver string WITHOUT the 'v' prefix, e.g. '1.2.3'
#            If omitted, defaults to the version in plugins/dso/.claude-plugin/plugin.json
#   --yes    Skip interactive confirmation prompt (required for non-TTY invocation)
#
# Preconditions (checked in order):
#   1. VERSION argument present and valid semver (MAJOR.MINOR.PATCH)
#   2. gh CLI authenticated (gh auth status)
#   3. Tag v<VERSION> does not already exist
#   4. On main branch
#   5. Working tree is clean
#   6. Up-to-date with origin/main
#   7. CI is green on HEAD SHA
#   8. validate.sh --ci passes
#   9. .claude-plugin/marketplace.json is valid JSON
#  10. Confirmation (interactive or --yes flag)
#
# Then:
#   - Delegates version bump to plugins/dso/scripts/tag-release.sh
#   - Creates git tag v<VERSION>
#   - Pushes tag and branch to origin

# ---------------------------------------------------------------------------
# Script location (for finding sibling plugin scripts)
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

VERSION=""
YES_FLAG=false

for arg in "$@"; do
    case "$arg" in
        --yes) YES_FLAG=true ;;
        -*)
            echo "ERROR: Unknown flag: $arg" >&2
            echo "Usage: $(basename "$0") [<VERSION>] [--yes]" >&2
            exit 1
            ;;
        *)
            if [[ -z "$VERSION" ]]; then
                VERSION="$arg"
            else
                echo "ERROR: Unexpected argument: $arg" >&2
                exit 1
            fi
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Precondition 1: VERSION argument and semver validation
# ---------------------------------------------------------------------------

if [[ -z "$VERSION" ]]; then
    _plugin_json="$SCRIPT_DIR/../plugins/dso/.claude-plugin/plugin.json"
    if [[ -f "$_plugin_json" ]]; then
        VERSION="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$_plugin_json" 2>/dev/null || echo "")"
    fi
    if [[ -z "$VERSION" ]]; then
        echo "ERROR: VERSION argument is required (e.g. 1.2.3) and could not be read from plugin.json" >&2
        echo "Usage: $(basename "$0") [<VERSION>] [--yes]" >&2
        exit 1
    fi
    echo "Using version from plugin.json: $VERSION" >&2
fi

SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+$'
if ! [[ "$VERSION" =~ $SEMVER_RE ]]; then
    echo "ERROR: Invalid semver format: '$VERSION' — expected MAJOR.MINOR.PATCH (e.g. 1.2.3)" >&2
    exit 1
fi

TAG="v${VERSION}"

# ---------------------------------------------------------------------------
# Precondition 2: gh CLI authenticated
# ---------------------------------------------------------------------------

if ! gh auth status >/dev/null 2>&1; then
    echo "ERROR: gh CLI is not authenticated — run 'gh auth login' first" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Derive repo root (with fallback to pwd for test contexts)
# ---------------------------------------------------------------------------

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
REPO_ROOT="${REPO_ROOT:-$(pwd)}"

# ---------------------------------------------------------------------------
# Precondition 3: Tag uniqueness (early check before any mutations)
# ---------------------------------------------------------------------------

if git tag -l "$TAG" 2>/dev/null | grep -q "^${TAG}$"; then
    echo "ERROR: Tag $TAG already exists — aborting release" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Precondition 4: On main branch
# ---------------------------------------------------------------------------

CURRENT_BRANCH="$(git branch --show-current 2>/dev/null)"
if [[ "$CURRENT_BRANCH" != "main" ]]; then
    echo "ERROR: Not on main branch (currently on '$CURRENT_BRANCH') — aborting release" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Precondition 5: Working tree is clean
# ---------------------------------------------------------------------------

DIRTY="$(git status --porcelain 2>/dev/null)"
if [[ -n "$DIRTY" ]]; then
    echo "ERROR: working tree is dirty — commit or stash changes before releasing" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Precondition 6: Up-to-date with origin/main
# ---------------------------------------------------------------------------

git fetch >/dev/null 2>&1 || echo "WARNING: git fetch failed — up-to-date check may be unreliable" >&2
# shellcheck disable=SC1083  # @{upstream} is git reflog syntax, not shell brace expansion
if ! git rev-parse --abbrev-ref HEAD@{upstream} >/dev/null 2>&1; then
    echo "ERROR: No upstream tracking branch configured — run 'git branch --set-upstream-to=origin/main main' — aborting release" >&2
    exit 1
fi
# shellcheck disable=SC1083  # @{u} is git reflog syntax, not shell brace expansion
BEHIND="$(git rev-list HEAD..@{u} --count 2>/dev/null || echo "0")"
if [[ "$BEHIND" -ne 0 ]]; then
    echo "ERROR: Not up-to-date with origin/main — run 'git pull' first (${BEHIND} commit(s) behind) — aborting release" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Precondition 7: CI is green on HEAD SHA
# ---------------------------------------------------------------------------

HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || echo "")"
_ci_get_status() {
    gh run list --commit "$HEAD_SHA" --limit 1 --json status,conclusion 2>/dev/null \
        | python3 -c '
import json, sys
runs = json.load(sys.stdin)
if not runs:
    print("no_runs")
else:
    r = runs[0]
    print(r["conclusion"] if r["conclusion"] else r["status"])
' 2>/dev/null || echo ""
}
CI_STATUS="$(_ci_get_status)"
while [[ "$CI_STATUS" == "in_progress" || "$CI_STATUS" == "queued" || "$CI_STATUS" == "waiting" || "$CI_STATUS" == "requested" || "$CI_STATUS" == "pending" ]]; do
    echo "CI is ${CI_STATUS} on HEAD ($HEAD_SHA) — rechecking in 30s..." >&2
    sleep 30
    CI_STATUS="$(_ci_get_status)"
done
CI_CONCLUSION="$CI_STATUS"
if [[ "$CI_CONCLUSION" != "success" ]]; then
    echo "ERROR: CI is not green on HEAD ($HEAD_SHA) — conclusion: '${CI_CONCLUSION:-unknown}' — aborting release" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Precondition 8: validate.sh --ci passes
# ---------------------------------------------------------------------------

if ! "$REPO_ROOT/.claude/scripts/dso" validate.sh --ci >/dev/null 2>&1; then
    echo "ERROR: Validation (validate.sh --ci) failed — aborting release" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Precondition 9: marketplace.json is valid JSON
# ---------------------------------------------------------------------------

MARKETPLACE_JSON="${REPO_ROOT}/.claude-plugin/marketplace.json"
if ! python3 -m json.tool "$MARKETPLACE_JSON" >/dev/null 2>&1; then
    echo "ERROR: marketplace.json would be invalid JSON — aborting release" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Precondition 10: Confirmation
# ---------------------------------------------------------------------------

if [[ "$YES_FLAG" != "true" ]]; then
    if ! [[ -t 0 ]]; then
        echo "ERROR: Interactive confirmation required — use --yes flag for non-interactive invocation" >&2
        exit 1
    fi
    read -r -p "Release $TAG to origin/main? [y/N] " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "Aborted." >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Delegate version bump to tag-release.sh (best-effort)
# ---------------------------------------------------------------------------

TAG_RELEASE_SCRIPT="$SCRIPT_DIR/../plugins/dso/scripts/tag-release.sh"
if [[ -x "$TAG_RELEASE_SCRIPT" ]]; then
    _TAG_RELEASE_STDERR="$(mktemp /tmp/tag-release-stderr.XXXXXX)"
    # shellcheck disable=SC2064  # _TAG_RELEASE_STDERR must expand now so the trap captures the specific file
    trap "rm -f '$_TAG_RELEASE_STDERR'" EXIT
    TAG_RELEASE_EXIT=0
    "$TAG_RELEASE_SCRIPT" "$VERSION" 2>"$_TAG_RELEASE_STDERR" || TAG_RELEASE_EXIT=$?
    if [[ "$TAG_RELEASE_EXIT" -ne 0 ]]; then
        echo "WARNING: tag-release.sh exited $TAG_RELEASE_EXIT — proceeding with tagging" >&2
        cat "$_TAG_RELEASE_STDERR" >&2 2>/dev/null || true
    fi
    rm -f "$_TAG_RELEASE_STDERR"
    trap - EXIT
    # Commit version bump files before creating the tag so the tag lands on the
    # bump commit, not the pre-bump HEAD. plugin.json and marketplace.json are in
    # review-gate-allowlist.conf so this commit does not require a review pass.
    BUMP_DIRTY="$(git status --porcelain 2>/dev/null)"
    if [[ -n "$BUMP_DIRTY" ]]; then
        _UNEXPECTED=$(echo "$BUMP_DIRTY" | grep -v 'plugin\.json\|marketplace\.json' || true)
        if [[ -n "$_UNEXPECTED" ]]; then
            echo "WARNING: tag-release.sh left unexpected dirty files (not committed):" >&2
            echo "$_UNEXPECTED" >&2
        fi
        git add "plugins/dso/.claude-plugin/plugin.json" ".claude-plugin/marketplace.json" 2>/dev/null || true
        git commit -m "chore: bump version to $TAG"
    fi
fi

# ---------------------------------------------------------------------------
# Create tag and push
# ---------------------------------------------------------------------------

git tag -a "$TAG" -m "Release $TAG"
git push --follow-tags
