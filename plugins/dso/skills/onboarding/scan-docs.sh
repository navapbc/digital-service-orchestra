#!/usr/bin/env bash
# scan-docs.sh — file-type guard for onboarding doc scanning.
#
# Usage: scan-docs.sh <doc_folder>
#
# Scans files in <doc_folder> (non-recursive), skipping binary files and
# files > 500KB. Outputs JSON to stdout on success.
#
# Exit codes:
#   0 — success (even if all files skipped)
#   1 — invalid/missing argument, path traversal, or unreadable directory
#
# Stderr: SKIP:<reason> <filename> for each skipped file
#         WARNING:file_cap_reached if more than 50 files exist
#         ERROR:path_traversal if path contains ..
#         ERROR:not_found if directory doesn't exist or isn't readable

set -uo pipefail

# Resolve plugin root via BASH_SOURCE
_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ── Argument validation ──────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
    echo "ERROR: usage: scan-docs.sh <doc_folder>" >&2
    exit 1
fi

DOC_FOLDER="$1"

# Reject path traversal
if [[ "$DOC_FOLDER" == *".."* ]]; then
    echo "ERROR:path_traversal path contains '..' which is not allowed: $DOC_FOLDER" >&2
    exit 1
fi

# Verify directory exists and is readable
if [[ ! -d "$DOC_FOLDER" ]] || [[ ! -r "$DOC_FOLDER" ]]; then
    echo "ERROR:not_found directory not found or not readable: $DOC_FOLDER" >&2
    exit 1
fi

# ── File scanning ────────────────────────────────────────────────────────────

# Constants
readonly MAX_SIZE_BYTES=$(( 500 * 1024 ))  # 500KB
readonly MAX_FILES=50

# Check if `file` command is available
_have_file_cmd=0
if command -v file >/dev/null 2>&1; then
    _have_file_cmd=1
fi

# Helper: detect binary via null bytes in first 512 bytes (fallback)
_is_binary_fallback() {
    local filepath="$1"
    if LC_ALL=C dd if="$filepath" bs=512 count=1 2>/dev/null | grep -qP '\x00'; then
        return 0  # binary
    fi
    # Also check for high-bit bytes that aren't valid UTF-8
    if LC_ALL=C dd if="$filepath" bs=512 count=1 2>/dev/null | grep -qP '[\x80-\xFF]'; then
        return 0  # binary
    fi
    return 1  # not binary
}

# Collect files (non-recursive, skip subdirectories)
facts_json="[]"
skipped_json="[]"

file_count=0
total_files=0

# Count all files first to check cap
while IFS= read -r -d '' f; do
    [[ -f "$f" ]] || continue
    (( total_files++ )) || true
done < <(find "$DOC_FOLDER" -maxdepth 1 -mindepth 1 -type f -print0 2>/dev/null)

if [[ "$total_files" -gt "$MAX_FILES" ]]; then
    echo "WARNING:file_cap_reached" >&2
fi

# Process files up to cap
while IFS= read -r -d '' filepath; do
    [[ -f "$filepath" ]] || continue

    if [[ "$file_count" -ge "$MAX_FILES" ]]; then
        break
    fi

    filename="$(basename "$filepath")"

    # Size check
    file_size=0
    if command -v stat >/dev/null 2>&1; then
        # macOS/BSD stat
        file_size=$(stat -f%z "$filepath" 2>/dev/null || stat -c%s "$filepath" 2>/dev/null || echo 0)
    fi

    if [[ "$file_size" -gt "$MAX_SIZE_BYTES" ]]; then
        echo "SKIP:size $filename" >&2
        skipped_json="$(python3 -c "
import json, sys
arr = json.loads(sys.argv[1])
arr.append('size:' + sys.argv[2])
print(json.dumps(arr))
" "$skipped_json" "$filename")"
        (( file_count++ )) || true
        continue
    fi

    # Binary check
    is_binary=0
    if [[ "$_have_file_cmd" -eq 1 ]]; then
        mime_type="$(file --mime-type -b "$filepath" 2>/dev/null || true)"
        case "$mime_type" in
            application/*|image/*|audio/*|video/*)
                is_binary=1
                ;;
        esac
    else
        if _is_binary_fallback "$filepath"; then
            is_binary=1
        fi
    fi

    # Also check for non-UTF8 bytes when file command says text
    if [[ "$is_binary" -eq 0 ]]; then
        if LC_ALL=C head -c 512 "$filepath" 2>/dev/null | python3 -c "
import sys
data = sys.stdin.buffer.read()
# Check for null bytes or bytes that look non-UTF-8 in a simple heuristic
if b'\\x00' in data:
    sys.exit(0)
try:
    data.decode('utf-8')
except UnicodeDecodeError:
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
            is_binary=1
        fi
    fi

    if [[ "$is_binary" -eq 1 ]]; then
        echo "SKIP:binary $filename" >&2
        skipped_json="$(python3 -c "
import json, sys
arr = json.loads(sys.argv[1])
arr.append('binary:' + sys.argv[2])
print(json.dumps(arr))
" "$skipped_json" "$filename")"
        (( file_count++ )) || true
        continue
    fi

    # File passed all checks — add to facts (placeholder, content scanning TBD)
    (( file_count++ )) || true

done < <(find "$DOC_FOLDER" -maxdepth 1 -mindepth 1 -type f -print0 2>/dev/null)

# ── Output JSON ──────────────────────────────────────────────────────────────

python3 -c "
import json, sys
facts = json.loads(sys.argv[1])
skipped = json.loads(sys.argv[2])
print(json.dumps({'facts': facts, 'skipped': skipped}))
" "$facts_json" "$skipped_json"

exit 0
