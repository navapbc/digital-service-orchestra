#!/usr/bin/env bash
# tests/plugin/test-debug-everything-readonly-enforcement.sh
# Validates the READ-ONLY ENFORCEMENT reference chain:
# Each debug-everything prompt file must reference the shared enforcement file,
# and the shared file must exist with the required content.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROMPTS_DIR="$PLUGIN_ROOT/plugins/dso/skills/debug-everything/prompts"
SHARED_FILE="$PROMPTS_DIR/shared/read-only-enforcement.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== debug-everything read-only enforcement reference chain ==="

# Test A: shared enforcement file exists
assert_eq "shared/read-only-enforcement.md exists" "true" \
    "$(test -f "$SHARED_FILE" && echo true || echo false)"

# Test B: shared file contains required prohibitions
assert_eq "shared file prohibits Edit tool" "true" \
    "$(grep -qi 'Edit' "$SHARED_FILE" 2>/dev/null && echo true || echo false)"
assert_eq "shared file prohibits Write tool" "true" \
    "$(grep -qi 'Write' "$SHARED_FILE" 2>/dev/null && echo true || echo false)"
assert_eq "shared file uses hard-stop framing" "true" \
    "$(grep -qiE 'STOP|must not' "$SHARED_FILE" 2>/dev/null && echo true || echo false)"

# Test C: each prompt file references the shared enforcement file
for prompt_file in \
    "$PROMPTS_DIR/full-validation.md" \
    "$PROMPTS_DIR/post-batch-validation.md" \
    "$PROMPTS_DIR/tier-transition-validation.md" \
    "$PROMPTS_DIR/critic-review.md" \
    "$PROMPTS_DIR/diagnostic-and-cluster.md"; do
    filename="$(basename "$prompt_file")"
    assert_eq "$filename references shared enforcement" "true" \
        "$(grep -qi 'read-only-enforcement' "$prompt_file" 2>/dev/null && echo true || echo false)"
done

print_summary
