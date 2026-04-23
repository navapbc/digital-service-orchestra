#!/usr/bin/env bash
# tests/test-doc-links.sh
# Automated link-check script that scans README.md and the root INSTALL.md
# for broken hyperlinks (markdown links and bare URLs).
#
# Checks:
#   - External URLs (http/https): HEAD request, accept HTTP < 400; fail on 5xx or connection error
#   - Internal relative paths: file must exist in repo
#   - Anchor fragments (#section): target file must contain a matching heading
#
# OPT-OUT LIST — add volatile/rate-limited URLs here (one per line, no trailing slash variation):
# Format: OPT_OUT_URLS+=("https://example.com/volatile-url")
# ---- BEGIN OPT-OUT ----
OPT_OUT_URLS=(
    # Returns 403 on HEAD requests (CDN/WAF blocks non-browser requests); URL is valid
    "https://acli.atlassian.com"
    # Returns 403 on HEAD requests (same reason); URL is valid — Claude Code install page
    "https://claude.ai/code"
    # Placeholder example URL shown in INSTALL.md ("your-org" is a literal placeholder token)
    "https://your-org.atlassian.net"
)
# ---- END OPT-OUT ----

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

FAILURES=0
TESTS=0

pass() { TESTS=$((TESTS + 1)); echo "  PASS: $1"; }
fail() { TESTS=$((TESTS + 1)); FAILURES=$((FAILURES + 1)); echo "  FAIL: $1"; }

# Files to scan (relative to REPO_ROOT)
SCAN_FILES=(
    "README.md"
    "INSTALL.md"
)

# Check if a URL is in the opt-out list
_is_opted_out() {
    local url="$1"
    for opt_url in "${OPT_OUT_URLS[@]:-}"; do
        if [[ "$url" == "$opt_url" ]]; then
            return 0
        fi
    done
    return 1
}

# Extract markdown links [text](url) and bare http/https URLs from a file
_extract_links() {
    local file="$1"
    # Markdown links: [text](url) — capture the URL part
    grep -oE '\[([^]]*)\]\(([^)]+)\)' "$file" | sed 's/\[.*\](\(.*\))/\1/' || true
    # Bare URLs not already in markdown link syntax
    # Exclude chars that typically end a URL: ) space > " ` | , ; backtick
    grep -oE '(^|[^(])(https?://[^)[:space:]>"`|,;]+)' "$file" | grep -oE 'https?://[^)[:space:]>"`|,;]+' || true
}

# Check an external URL via HEAD request
_check_external_url() {
    local url="$1"
    # Strip trailing punctuation that may have been captured
    url="${url%[.,;:\"\'!]}"

    if _is_opted_out "$url"; then
        echo "  SKIP (opt-out): $url"
        return 0
    fi

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -I --max-time 10 --location "$url" 2>/dev/null || echo "000")
    # Normalize: strip non-numeric chars (handles edge cases where curl appends extra output)
    http_code=$(echo "$http_code" | grep -oE '^[0-9]+' | head -1 || echo "0")
    http_code="${http_code:-0}"

    if [[ "$http_code" -le 0 ]]; then
        fail "Connection error for external URL: $url"
        return 1
    elif [[ "$http_code" -ge 500 ]]; then
        fail "Server error ($http_code) for external URL: $url"
        return 1
    elif [[ "$http_code" -ge 400 ]]; then
        fail "Client error ($http_code) for external URL: $url"
        return 1
    else
        pass "External URL OK ($http_code): $url"
        return 0
    fi
}

# Check an internal path (optionally with #anchor)
_check_internal_path() {
    local raw_path="$1"
    local base_file="$2"

    # Split on '#' for anchor
    local path_part anchor_part
    path_part="${raw_path%%#*}"
    if [[ "$raw_path" == *#* ]]; then
        anchor_part="${raw_path#*#}"
    else
        anchor_part=""
    fi

    # Resolve path relative to the file's directory, then to repo root
    local resolved
    if [[ -z "$path_part" ]]; then
        # Pure anchor — check within the same file
        resolved="$base_file"
    elif [[ "$path_part" == /* ]]; then
        # Absolute path from repo root
        resolved="$REPO_ROOT$path_part"
    else
        # Relative to the file's directory
        resolved="$(dirname "$base_file")/$path_part"
    fi

    # Normalize (remove /./ and /../ sequences)
    if command -v realpath >/dev/null 2>&1; then
        resolved="$(realpath -m "$resolved" 2>/dev/null || echo "$resolved")"
    fi

    # Check file existence (skip if path_part is empty — pure anchor on same file)
    if [[ -n "$path_part" ]]; then
        if [[ ! -e "$resolved" ]]; then
            fail "Internal path not found: $raw_path (resolved: $resolved) [in $base_file]"
            return 1
        fi
    fi

    # Check anchor if present
    if [[ -n "$anchor_part" ]]; then
        if [[ ! -f "$resolved" ]]; then
            fail "Anchor target file not found for #$anchor_part: $resolved [in $base_file]"
            return 1
        fi
        # GitHub-style anchor: lowercase, spaces→dashes, strip punctuation
        local normalized_anchor
        normalized_anchor=$(echo "$anchor_part" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g' | sed 's/--*/-/g' | sed 's/^-//; s/-$//' || true)

        # Search for heading in the target file (# Heading, ## Heading, etc.)
        local found=false
        while IFS= read -r heading_line; do
            # Strip leading # characters and spaces
            local heading_text
            heading_text=$(echo "$heading_line" | sed 's/^#* *//' | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g' | sed 's/--*/-/g' | sed 's/^-//; s/-$//' || true)
            if [[ "$heading_text" == "$normalized_anchor" ]]; then
                found=true
                break
            fi
        done < <(grep -E '^#{1,6} ' "$resolved" || true)

        if ! $found; then
            fail "Anchor #$anchor_part not found in $resolved [in $base_file]"
            return 1
        fi
    fi

    pass "Internal path OK: $raw_path [in $base_file]"
    return 0
}

echo "=== Doc Link Checker ==="
echo "Scanning: ${SCAN_FILES[*]}"
echo ""

# Deduplicate URLs to avoid redundant external checks
declare -A seen_external=()

for rel_file in "${SCAN_FILES[@]}"; do
    full_path="$REPO_ROOT/$rel_file"

    if [[ ! -f "$full_path" ]]; then
        fail "Source file not found: $rel_file"
        continue
    fi

    echo "--- Checking links in: $rel_file ---"

    # Collect all links from the file
    links=$(_extract_links "$full_path")

    if [[ -z "$links" ]]; then
        echo "  (no links found)"
        continue
    fi

    while IFS= read -r link; do
        [[ -z "$link" ]] && continue

        # Strip trailing punctuation
        link="${link%[.,;:\"\'!]}"
        [[ -z "$link" ]] && continue

        if [[ "$link" == http://* ]] || [[ "$link" == https://* ]]; then
            # External URL
            if [[ -z "${seen_external[$link]+_}" ]]; then
                seen_external[$link]=1
                _check_external_url "$link" || true
                sleep 1
            else
                echo "  DEDUP (already checked): $link"
            fi
        elif [[ "$link" == mailto:* ]]; then
            # Skip mailto links
            echo "  SKIP (mailto): $link"
        elif [[ "$link" == "#"* ]]; then
            # Pure anchor on the same file
            _check_internal_path "$link" "$full_path" || true
        else
            # Internal relative path (with or without anchor)
            _check_internal_path "$link" "$full_path" || true
        fi
    done <<< "$links"

    echo ""
done

echo "=== Results: $((TESTS - FAILURES))/$TESTS passed ==="
if (( FAILURES > 0 )); then
    echo "FAILED: $FAILURES link(s) broken"
    exit 1
else
    echo "All links OK."
    exit 0
fi
