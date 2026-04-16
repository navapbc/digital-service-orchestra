#!/usr/bin/env bash
# scan-docs.sh — file-type guard and text extraction for onboarding doc scanning.
#
# Usage: scan-docs.sh <doc_folder> [--context-file=<path>]
#
# Scans files in <doc_folder> (non-recursive), skipping binary files and
# files > 500KB. Extracts facts (app_name, stack, wcag_level, framework)
# from text files. Optionally elevates a CONFIDENCE_CONTEXT JSON file.
#
# Exit codes:
#   0 — success (even if all files skipped)
#   1 — invalid/missing argument, path traversal, or unreadable directory
#
# Stderr: SKIP:<reason> <filename> for each skipped file
#         WARNING:file_cap_reached if more than 50 files exist
#         ERROR:path_traversal if path contains ..
#         ERROR:not_found if directory doesn't exist or isn't readable

set -euo pipefail

# ── Argument validation ──────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
    echo "ERROR: usage: scan-docs.sh <doc_folder> [--context-file=<path>]" >&2
    exit 1
fi

DOC_FOLDER="$1"
CONTEXT_FILE=""

# Parse optional arguments
for arg in "${@:2}"; do
    case "$arg" in
        --context-file=*)
            CONTEXT_FILE="${arg#--context-file=}"
            ;;
        *)
            echo "ERROR: unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

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
readonly MAX_READ_BYTES=$(( 50 * 1024 ))   # 50KB per file for extraction
readonly MAX_FILES=50

# Check if `file` command is available
_have_file_cmd=0
if command -v file >/dev/null 2>&1; then
    _have_file_cmd=1
fi

# Helper: detect binary via null bytes in first 512 bytes (fallback when `file` unavailable).
# Uses portable tr-based byte counting — avoids grep -qP which is not available on macOS BSD grep.
_is_binary_fallback() {
    local filepath="$1"
    # Check for null bytes (portable: keep only null bytes and count them)
    local _nulls
    _nulls=$(LC_ALL=C dd if="$filepath" bs=512 count=1 2>/dev/null | LC_ALL=C tr -cd '\000' | wc -c)
    if [[ "${_nulls// /}" -gt 0 ]]; then
        return 0  # binary
    fi
    # Also check for high-bit bytes that aren't valid UTF-8
    local _high
    _high=$(LC_ALL=C dd if="$filepath" bs=512 count=1 2>/dev/null | LC_ALL=C tr -cd '\200-\377' | wc -c)
    if [[ "${_high// /}" -gt 0 ]]; then
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

    # File passed all checks — extract facts from text content
    facts_json="$(python3 -c "
import json, re, sys

filepath = sys.argv[1]
filename = sys.argv[2]
max_bytes = int(sys.argv[3])
existing_facts_json = sys.argv[4]

existing_facts = json.loads(existing_facts_json)

# Read up to max_bytes of file content
try:
    with open(filepath, 'r', encoding='utf-8', errors='replace') as fh:
        content = fh.read(max_bytes)
except Exception:
    print(existing_facts_json)
    sys.exit(0)

new_facts = []

# ── app_name extraction ──────────────────────────────────────────────────────
app_name_pattern = re.compile(
    r'(?:app\s+name|application|project)\s*:\s*([^\n]+)',
    re.IGNORECASE
)
app_name_matches = app_name_pattern.findall(content)
if app_name_matches:
    # Take the first word/phrase on the matched line (strip trailing whitespace)
    values = [m.strip().split()[0] if m.strip() else m.strip() for m in app_name_matches if m.strip()]
    unique_values = list(dict.fromkeys(values))  # preserve order, deduplicate
    if unique_values:
        value = unique_values[0]
        confidence = 'high' if len(unique_values) == 1 else 'medium'
        new_facts.append({
            'key': 'app_name',
            'value': value,
            'confidence': confidence,
            'source_file': filename
        })

# ── stack extraction ─────────────────────────────────────────────────────────
stack_keywords = [
    'python', 'node', 'react', 'rails', 'django', 'flask',
    'nextjs', 'vue', 'angular', 'spring', 'go', 'rust', 'java'
]
found_stacks = []
for kw in stack_keywords:
    if re.search(r'\b' + re.escape(kw) + r'\b', content, re.IGNORECASE):
        found_stacks.append(kw)

if found_stacks:
    value = ','.join(found_stacks)
    confidence = 'high' if len(found_stacks) == 1 else 'medium'
    new_facts.append({
        'key': 'stack',
        'value': value,
        'confidence': confidence,
        'source_file': filename
    })

# ── wcag_level extraction ────────────────────────────────────────────────────
wcag_pattern = re.compile(r'\bWCAG\s+(AAA|AA|A)\b', re.IGNORECASE)
wcag_matches = wcag_pattern.findall(content)
if wcag_matches:
    unique_levels = list(dict.fromkeys([m.upper() for m in wcag_matches]))
    value = unique_levels[0]
    confidence = 'high' if len(unique_levels) == 1 else 'medium'
    new_facts.append({
        'key': 'wcag_level',
        'value': value,
        'confidence': confidence,
        'source_file': filename
    })

# ── framework extraction ─────────────────────────────────────────────────────
framework_pattern = re.compile(r'framework\s*:\s*([^\n]+)', re.IGNORECASE)
framework_matches = framework_pattern.findall(content)
if framework_matches:
    values = [m.strip() for m in framework_matches if m.strip()]
    unique_values = list(dict.fromkeys(values))
    if unique_values:
        value = unique_values[0]
        confidence = 'high' if len(unique_values) == 1 else 'medium'
        new_facts.append({
            'key': 'framework',
            'value': value,
            'confidence': confidence,
            'source_file': filename
        })

# Merge new facts into existing (per-key: keep first occurrence per key)
existing_keys = {f['key'] for f in existing_facts if isinstance(f, dict)}
for fact in new_facts:
    if fact['key'] not in existing_keys:
        existing_facts.append(fact)
        existing_keys.add(fact['key'])
    else:
        # Key already exists from a previous file — update confidence to medium (conflict)
        for ef in existing_facts:
            if isinstance(ef, dict) and ef['key'] == fact['key']:
                if ef.get('value') != fact['value']:
                    ef['confidence'] = 'medium'
                break

print(json.dumps(existing_facts))
" "$filepath" "$filename" "$MAX_READ_BYTES" "$facts_json")"

    (( file_count++ )) || true

done < <(find "$DOC_FOLDER" -maxdepth 1 -mindepth 1 -type f -print0 2>/dev/null)

# ── Confidence Context Elevation ─────────────────────────────────────────────

elevated_json="{}"

if [[ -n "$CONTEXT_FILE" ]] && [[ -f "$CONTEXT_FILE" ]]; then
    elevated_json="$(python3 -c "
import json, sys

context_file = sys.argv[1]
facts_json_str = sys.argv[2]

# Confidence level ordering
LEVEL_ORDER = {'low': 0, 'medium': 1, 'high': 2, 'unknown': -1}

try:
    with open(context_file, 'r', encoding='utf-8') as fh:
        context = json.load(fh)
except Exception:
    print('{}')
    sys.exit(0)

facts = json.loads(facts_json_str)

# Support both flat format: {\"stack\": \"low\", ...}
# and nested format: {\"dimensions\": {\"stack\": {\"confidence\": \"low\"}, ...}}
def get_existing_level(context, key):
    # Try flat format first
    if key in context and isinstance(context[key], str):
        return context[key]
    # Try nested dimensions format
    dims = context.get('dimensions', {})
    if key in dims:
        dim = dims[key]
        if isinstance(dim, str):
            return dim
        if isinstance(dim, dict):
            return dim.get('confidence', 'low')
    return None

elevated = {}

for fact in facts:
    if not isinstance(fact, dict):
        continue
    key = fact.get('key')
    proposed_level = fact.get('confidence', 'medium')

    if not key:
        continue

    existing_level = get_existing_level(context, key)
    if existing_level is None:
        # Key not in context — skip elevation for this key
        continue

    existing_order = LEVEL_ORDER.get(existing_level, -1)
    proposed_order = LEVEL_ORDER.get(proposed_level, -1)

    # Elevation-only, step-up by one level at a time:
    # A proposed level higher than existing elevates by exactly one step.
    # This prevents jumping directly from low to high on a single signal.
    # Never lower a dimension.
    if proposed_order > existing_order:
        # Step up by exactly one level
        LEVEL_UP = {0: 'medium', 1: 'high'}  # low→medium, medium→high
        new_level = LEVEL_UP.get(existing_order, proposed_level)
        elevated[key] = new_level
    # Never lower — if proposed <= existing, no change recorded

print(json.dumps(elevated))
" "$CONTEXT_FILE" "$facts_json")"
fi

# ── Output JSON ──────────────────────────────────────────────────────────────

python3 -c "
import json, sys
facts = json.loads(sys.argv[1])
skipped = json.loads(sys.argv[2])
elevated = json.loads(sys.argv[3])
result = {'facts': facts, 'skipped': skipped}
if elevated:
    result['elevated_dimensions'] = elevated
print(json.dumps(result))
" "$facts_json" "$skipped_json" "$elevated_json"

exit 0
