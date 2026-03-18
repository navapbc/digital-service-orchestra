#!/usr/bin/env bash
set -uo pipefail
# scripts/bump-version.sh — Increment a semver version in the configured version file.
#
# Usage:
#   bump-version.sh --patch [--config <path>]
#   bump-version.sh --minor [--config <path>]
#   bump-version.sh --major [--config <path>]
#
# Reads version.file_path from workflow-config.conf (via read-config.sh).
# If version.file_path is not set, exits 0 with no changes.
#
# Auto-detects file format by extension:
#   .json        → reads/writes "version" key (JSON object)
#   .toml        → reads/writes top-level `version = "..."` line
#   no extension / .txt → single semver line (entire file content)
#
# Exit codes:
#   0  Success (or no version.file_path configured — clean skip)
#   1  Error: missing/invalid bump flag, file not found, malformed file, etc.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

err() {
    echo "ERROR: $*" >&2
}

usage() {
    echo "Usage: $(basename "$0") --patch|--minor|--major [--config <path>]" >&2
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

BUMP_TYPE=""
CONFIG_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --patch) BUMP_TYPE="patch" ;;
        --minor) BUMP_TYPE="minor" ;;
        --major) BUMP_TYPE="major" ;;
        --config)
            shift
            CONFIG_FILE="${1:-}"
            if [[ -z "$CONFIG_FILE" ]]; then
                err "--config requires a path argument."
                exit 1
            fi
            ;;
        *)
            err "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

if [[ -z "$BUMP_TYPE" ]]; then
    err "Bump type is required: --patch, --minor, or --major"
    usage
    exit 1
fi

# ---------------------------------------------------------------------------
# Locate read-config.sh
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READ_CONFIG="$SCRIPT_DIR/read-config.sh"

if [[ ! -f "$READ_CONFIG" ]]; then
    err "read-config.sh not found at: $READ_CONFIG"
    exit 1
fi

# ---------------------------------------------------------------------------
# Read version.file_path from config
# ---------------------------------------------------------------------------

if [[ -n "$CONFIG_FILE" ]]; then
    VERSION_FILE_PATH=$(bash "$READ_CONFIG" version.file_path "$CONFIG_FILE")
else
    VERSION_FILE_PATH=$(bash "$READ_CONFIG" version.file_path)
fi

# If not configured, exit cleanly with no changes
if [[ -z "$VERSION_FILE_PATH" ]]; then
    exit 0
fi

# Verify the target file exists
if [[ ! -f "$VERSION_FILE_PATH" ]]; then
    err "Version file not found: $VERSION_FILE_PATH"
    exit 1
fi

# ---------------------------------------------------------------------------
# Semver bump logic (pure bash)
# ---------------------------------------------------------------------------

# bump_semver CURRENT_VERSION BUMP_TYPE → prints new version, exits non-zero on invalid input
bump_semver() {
    local version="$1"
    local bump="$2"
    local SEMVER_RE='^([0-9]+)\.([0-9]+)\.([0-9]+)$'

    if ! [[ "$version" =~ $SEMVER_RE ]]; then
        err "Not a valid semver: '$version'"
        return 1
    fi

    local major="${BASH_REMATCH[1]}"
    local minor="${BASH_REMATCH[2]}"
    local patch="${BASH_REMATCH[3]}"

    case "$bump" in
        patch) (( patch++ )) ;;
        minor) (( minor++ )); patch=0 ;;
        major) (( major++ )); minor=0; patch=0 ;;
        *)
            err "Unknown bump type: $bump"
            return 1
            ;;
    esac

    printf '%d.%d.%d\n' "$major" "$minor" "$patch"
}

# ---------------------------------------------------------------------------
# Detect format and parse current version
# ---------------------------------------------------------------------------

extension="${VERSION_FILE_PATH##*.}"
# If the filename has no dot OR the dot is at position 0 (hidden file) or the
# basename equals the extension (e.g. "VERSION"), treat as plaintext.
basename_only="$(basename "$VERSION_FILE_PATH")"
if [[ "$basename_only" == "$extension" || "$basename_only" == ".$extension" ]]; then
    extension=""
fi

case "$extension" in
    json)
        # Read current version from JSON using Python
        current_version=$(python3 - "$VERSION_FILE_PATH" <<'PYEOF'
import sys, json
path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except Exception as e:
    print(f"PARSE_ERROR: {e}", file=sys.stderr)
    sys.exit(1)
if "version" not in data:
    print("ERROR: 'version' key not found in JSON", file=sys.stderr)
    sys.exit(2)
print(data["version"])
PYEOF
        ) || {
            err "Failed to read version from JSON file: $VERSION_FILE_PATH"
            exit 1
        }
        ;;
    toml)
        # Read current version from TOML: find line matching `version = "X.Y.Z"`
        current_version=$(grep -m1 '^version = ' "$VERSION_FILE_PATH" | sed 's/^version = "\(.*\)"/\1/')
        if [[ -z "$current_version" ]]; then
            err "Could not find 'version = \"...\"' line in TOML file: $VERSION_FILE_PATH"
            exit 1
        fi
        # Validate it looks like a semver
        SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+$'
        if ! [[ "$current_version" =~ $SEMVER_RE ]]; then
            err "TOML version field is not a valid semver: '$current_version'"
            exit 1
        fi
        ;;
    txt|"")
        # Plaintext: entire file is a single semver line
        current_version=$(tr -d '[:space:]' < "$VERSION_FILE_PATH")
        SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+$'
        if ! [[ "$current_version" =~ $SEMVER_RE ]]; then
            err "Plaintext version file does not contain a valid semver: '$current_version'"
            exit 1
        fi
        ;;
    *)
        # Unknown extension — treat as plaintext
        current_version=$(tr -d '[:space:]' < "$VERSION_FILE_PATH")
        SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+$'
        if ! [[ "$current_version" =~ $SEMVER_RE ]]; then
            err "Version file does not contain a valid semver: '$current_version'"
            exit 1
        fi
        ;;
esac

# ---------------------------------------------------------------------------
# Calculate new version
# ---------------------------------------------------------------------------

new_version=$(bump_semver "$current_version" "$BUMP_TYPE") || exit 1

# ---------------------------------------------------------------------------
# Write new version back (atomically via tmp file to prevent corruption)
# ---------------------------------------------------------------------------

case "$extension" in
    json)
        # Use Python for reliable JSON write — preserves structure and other fields
        python3 - "$VERSION_FILE_PATH" "$new_version" <<'PYEOF'
import sys, json

path, new_ver = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)

data["version"] = new_ver

import tempfile, os
dirpath = os.path.dirname(path)
fd, tmp_path = tempfile.mkstemp(dir=dirpath)
try:
    with os.fdopen(fd, 'w') as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp_path, path)
except Exception as e:
    os.unlink(tmp_path)
    print(f"ERROR writing file: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
        ;;
    toml)
        # Replace only the first `version = "..."` line; preserve everything else.
        # NOTE: Uses grep/regex matching on `^version = "..."` (bare top-level key).
        # This handles common TOML conventions (pyproject.toml [project], [tool.poetry],
        # Cargo.toml [package]). It does NOT handle version keys nested inside
        # [dependencies] or other sub-tables — for those cases, use a TOML-aware tool.
        #
        # Atomic write: temp file is created in same directory as target to ensure
        # mv is an in-filesystem rename, not a cross-device copy.
        tmp_file="$(mktemp "$(dirname "$VERSION_FILE_PATH")/bump-version.XXXXXX")"
        trap 'rm -f "$tmp_file"' EXIT
        # Use Python for reliable in-place substitution
        python3 - "$VERSION_FILE_PATH" "$new_version" "$tmp_file" <<'PYEOF'
import sys, re

src, new_ver, dst = sys.argv[1], sys.argv[2], sys.argv[3]
replaced = False
lines = []
with open(src) as f:
    for line in f:
        if not replaced and re.match(r'^version\s*=\s*"', line):
            lines.append(f'version = "{new_ver}"\n')
            replaced = True
        else:
            lines.append(line)

with open(dst, 'w') as f:
    f.writelines(lines)
PYEOF
        mv "$tmp_file" "$VERSION_FILE_PATH" || { err "Failed to replace version file: $VERSION_FILE_PATH"; exit 1; }
        ;;
    txt|""|*)
        # Plaintext: write just the new version with a trailing newline
        printf '%s\n' "$new_version" > "$VERSION_FILE_PATH"
        ;;
esac

echo "Version bumped: $current_version → $new_version ($VERSION_FILE_PATH)"
