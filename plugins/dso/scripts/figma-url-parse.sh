#!/usr/bin/env bash
# plugins/dso/scripts/figma-url-parse.sh
# Extract a Figma file key from a Figma URL.
#
# Usage: figma-url-parse.sh <url>
#
# Supported URL formats:
#   https://www.figma.com/design/<key>/...
#   https://www.figma.com/file/<key>/...
#   https://www.figma.com/proto/<key>/...
#
# Outputs the file key to stdout and exits 0 on success.
# Exits 1 with an error message on stderr for invalid URLs.

set -euo pipefail

url="${1:-}"

if [[ -z "$url" ]]; then
    printf 'Error: no URL provided\nUsage: %s <figma-url>\n' "$(basename "$0")" >&2
    exit 1
fi

# Validate Figma domain
if ! printf '%s' "$url" | grep -qE '^https?://(www\.)?figma\.com/'; then
    printf 'Error: not a Figma URL: %s\n' "$url" >&2
    exit 1
fi

# Extract file key from supported path prefixes: /design/, /file/, /proto/
# Use bash regex to avoid sed portability issues across macOS/Linux
if [[ "$url" =~ ^https?://(www\.)?figma\.com/(design|file|proto)/([^/?]+) ]]; then
    file_key="${BASH_REMATCH[3]}"
else
    file_key=""
fi

if [[ -z "$file_key" ]]; then
    printf 'Error: unsupported Figma URL format or no file key found: %s\n' "$url" >&2
    exit 1
fi

printf '%s\n' "$file_key"
