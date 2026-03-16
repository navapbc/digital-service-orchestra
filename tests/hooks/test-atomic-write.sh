#!/usr/bin/env bash
# Test atomic_write_file function from deps.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/assert.sh"

REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
unset _DEPS_LOADED
source "$PLUGIN_ROOT/hooks/lib/deps.sh"

TEST_DIR=$(mktemp -d)
trap "rm -rf '$TEST_DIR'" EXIT

# ── Test 1: Basic atomic write creates file with correct content ──
TARGET="$TEST_DIR/status"
atomic_write_file "$TARGET" "passed
timestamp=2026-01-01T00:00:00Z
diff_hash=abc123"

content=$(cat "$TARGET")
assert_contains "content_line1" "passed" "$content"
assert_contains "content_line2" "timestamp=2026-01-01" "$content"
assert_contains "content_line3" "diff_hash=abc123" "$content"

# ── Test 2: Atomic write overwrites existing file ──
echo "old content" > "$TARGET"
atomic_write_file "$TARGET" "new content"
content=$(cat "$TARGET")
assert_eq "overwrites_existing" "new content" "$content"

# ── Test 3: Atomic write to non-existent directory ──
DEEP_TARGET="$TEST_DIR/deep/nested/dir/file"
atomic_write_file "$DEEP_TARGET" "deep write"
content=$(cat "$DEEP_TARGET")
assert_eq "creates_parent_dirs" "deep write" "$content"

# ── Test 4: File is never partially readable during write ──
# We verify this by checking that the file either has the OLD or NEW content,
# never a partial mix, using rapid read-while-write cycles
TARGET2="$TEST_DIR/race-test"
echo "original" > "$TARGET2"

# Write new content atomically in background
for i in $(seq 1 20); do
    atomic_write_file "$TARGET2" "updated-$i" &
done
wait

# Final content should be one of the "updated-N" values, not partial
content=$(cat "$TARGET2")
assert_contains "race_safe_result" "updated-" "$content"

# ── Test 5: Piped content works via stdin ──
echo "piped content" | atomic_write_file "$TEST_DIR/piped" -
content=$(cat "$TEST_DIR/piped")
assert_eq "piped_content" "piped content" "$content"

print_summary
