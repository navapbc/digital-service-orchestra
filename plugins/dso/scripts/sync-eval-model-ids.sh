#!/usr/bin/env bash
set -uo pipefail
# scripts/sync-eval-model-ids.sh
# Sync model IDs in promptfooconfig.yaml eval configs from dso-config.conf.
#
# Usage: sync-eval-model-ids.sh <file> [<file> ...]
#
#   Accepts one or more promptfooconfig.yaml file paths.
#   For each file, replaces claude-{tier}-<version> patterns with the
#   canonical model ID from dso-config.conf (via resolve-model-id.sh).
#   Skips lines containing the # model-pin comment.
#
# Output (stdout): Summary of files updated.
# Exit codes:
#   0 — success
#   1 — error resolving model IDs or no files provided

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Resolve model IDs via resolve-model-id.sh ─────────────────────────────────
# Use PATH lookup first (allows test stubs to override), falling back to the
# sibling script by absolute path.
_resolve_model_id() {
    local tier="$1"
    if command -v resolve-model-id.sh >/dev/null 2>&1; then
        resolve-model-id.sh "$tier"
    else
        bash "$SCRIPT_DIR/resolve-model-id.sh" "$tier"
    fi
}

if [[ $# -eq 0 ]]; then
    echo "Error: no files provided" >&2
    exit 1
fi

haiku_id=$(_resolve_model_id "haiku") || { echo "Error: failed to resolve haiku model ID" >&2; exit 1; }
sonnet_id=$(_resolve_model_id "sonnet") || { echo "Error: failed to resolve sonnet model ID" >&2; exit 1; }
opus_id=$(_resolve_model_id "opus") || { echo "Error: failed to resolve opus model ID" >&2; exit 1; }

# ── Process each file ──────────────────────────────────────────────────────────
updated=0
for file in "$@"; do
    if [[ ! -f "$file" ]]; then
        echo "Warning: file not found, skipping: $file" >&2
        continue
    fi

    # Build a Python script that processes the file line by line:
    #  - skip lines containing # model-pin
    #  - replace claude-haiku-<version> with haiku_id
    #  - replace claude-sonnet-<version> with sonnet_id
    #  - replace claude-opus-<version> with opus_id
    # Pattern: claude-{tier}-[0-9]+(-[0-9A-Za-z]+)*
    # This covers: claude-opus-4-5, claude-opus-4-5-20250101, claude-sonnet-4-6-20260320, etc.
    python3 - "$file" "$haiku_id" "$sonnet_id" "$opus_id" <<'PYEOF' || { echo "Error: python3 failed processing: $file" >&2; exit 1; }
import sys, re

filepath = sys.argv[1]
haiku_id = sys.argv[2]
sonnet_id = sys.argv[3]
opus_id = sys.argv[4]

# Pattern: claude-{tier}-\d+(\.\d+)*(-\d+)* — matches versioned and dated model IDs.
# We use a negative lookahead/lookbehind approach: replace the ENTIRE claude-{tier}-... token.
# A token ends at a word boundary (non-alphanumeric-or-hyphen character, or end of string).
haiku_pat  = re.compile(r'claude-haiku-[0-9][0-9A-Za-z.-]*')
sonnet_pat = re.compile(r'claude-sonnet-[0-9][0-9A-Za-z.-]*')
opus_pat   = re.compile(r'claude-opus-[0-9][0-9A-Za-z.-]*')

with open(filepath, 'r') as f:
    lines = f.readlines()

new_lines = []
for line in lines:
    if '# model-pin' in line:
        new_lines.append(line)
    else:
        line = haiku_pat.sub(haiku_id, line)
        line = sonnet_pat.sub(sonnet_id, line)
        line = opus_pat.sub(opus_id, line)
        new_lines.append(line)

with open(filepath, 'w') as f:
    f.writelines(new_lines)
PYEOF

    updated=$((updated + 1))
done

echo "sync-eval-model-ids: updated $updated file(s)"
exit 0
