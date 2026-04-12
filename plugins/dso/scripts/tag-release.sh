#!/usr/bin/env bash
set -euo pipefail
# tag-release.sh — Update plugin version fields and print the git tag command.
#
# Usage:
#   tag-release.sh <VERSION> [--dry-run]
#
# Arguments:
#   VERSION    Semver string WITHOUT the 'v' prefix, e.g. '0.2.0'
#   --dry-run  Print what would be done but do NOT modify any files
#
# Exit codes:
#   0  Success
#   1  Invalid version format or missing argument

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
  echo "Usage: $(basename "$0") <VERSION> [--dry-run]" >&2
  echo "  VERSION  Semver string without 'v' prefix, e.g. '1.2.3'" >&2
}

err() {
  echo "ERROR: $*" >&2
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

VERSION=""
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -*)
      err "Unknown flag: $arg"
      usage
      exit 1
      ;;
    *)
      if [[ -z "$VERSION" ]]; then
        VERSION="$arg"
      else
        err "Unexpected argument: $arg"
        usage
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  err "VERSION argument is required."
  usage
  exit 1
fi

# ---------------------------------------------------------------------------
# Semver validation
# ---------------------------------------------------------------------------

SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+$'

if ! [[ "$VERSION" =~ $SEMVER_RE ]]; then
  err "Invalid version format: '$VERSION'"
  err "Expected MAJOR.MINOR.PATCH (e.g., '1.2.3'). Do NOT include the 'v' prefix."
  exit 1
fi

TAG="v${VERSION}"

# ---------------------------------------------------------------------------
# Locate plugin root (directory containing this script's parent)
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# DIST_ROOT is the repo root — marketplace.json stays at repo root (not inside ${CLAUDE_PLUGIN_ROOT}/)
DIST_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null)"

PLUGIN_JSON="${PLUGIN_ROOT}/.claude-plugin/plugin.json"
MARKETPLACE_JSON="${DIST_ROOT}/.claude-plugin/marketplace.json"

for f in "$PLUGIN_JSON" "$MARKETPLACE_JSON"; do
  if [[ ! -f "$f" ]]; then
    err "Required file not found: $f"
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Show plan
# ---------------------------------------------------------------------------

echo "Version:   ${VERSION}"
echo "Tag:       ${TAG}"
echo "Files:"
echo "  ${PLUGIN_JSON}"
echo "  ${MARKETPLACE_JSON}"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
  echo "[dry-run] Would update 'version' field to '${VERSION}' in both JSON files."
  echo "[dry-run] Would print git tag command (does not execute it)."
  echo ""
  echo "Git tag command (not executed):"
  echo "  git tag -a ${TAG} -m \"Release ${TAG}\""
  exit 0
fi

# ---------------------------------------------------------------------------
# Update version fields
# ---------------------------------------------------------------------------

update_version() {
  local file="$1"
  local new_version="$2"

  # Use Python for reliable JSON field update (avoids sed edge cases)
  python3 - "$file" "$new_version" <<'EOF'
import sys, json

path, version = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)

data["version"] = version

with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print(f"  Updated: {path}")
EOF
}

echo "Updating files..."
update_version "$PLUGIN_JSON" "$VERSION"
update_version "$MARKETPLACE_JSON" "$VERSION"

# ---------------------------------------------------------------------------
# Print the git tag command (does NOT execute it — idempotent dry-run pattern)
# ---------------------------------------------------------------------------

echo ""
echo "Version bumped to ${VERSION}."
echo ""
echo "Next steps:"
echo "  1. Review the changes: git diff ${PLUGIN_JSON} ${MARKETPLACE_JSON}"
echo "  2. Commit: git commit -m \"chore: bump version to ${TAG}\""
echo "  3. Create the tag (copy-paste this command):"
echo ""
echo "     git tag -a ${TAG} -m \"Release ${TAG}\""
echo ""
echo "  4. Push: git push && git push --tags"
