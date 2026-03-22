#!/usr/bin/env bash
# tests/scripts/test-tk-close-red-marker.sh
#
# Tests for `tk close` RED marker check in .test-index.
#
# When closing an epic, tk close must scan .test-index for entries with
# [marker] syntax. If any are found, the close is blocked with a clear
# error message listing the stale markers.
#
# Usage: bash tests/scripts/test-tk-close-red-marker.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
TK_SCRIPT="$DSO_PLUGIN_DIR/scripts/tk"

source "$SCRIPT_DIR/../lib/run_test.sh"

echo "=== test-tk-close-red-marker.sh ==="

# ── Helpers ──────────────────────────────────────────────────────────────────

make_epic() {
    local dir="$1"
    local id="$2"
    local status="${3:-open}"
    cat > "$dir/${id}.md" <<EOF
---
id: ${id}
status: ${status}
title: Epic ${id}
deps: []
links: []
created: 2026-03-08T00:00:00Z
type: epic
priority: 2
---
# Epic ${id}
EOF
}

make_task() {
    local dir="$1"
    local id="$2"
    local status="${3:-open}"
    cat > "$dir/${id}.md" <<EOF
---
id: ${id}
status: ${status}
title: Task ${id}
deps: []
links: []
created: 2026-03-08T00:00:00Z
type: task
priority: 2
---
# Task ${id}
EOF
}

make_test_index_with_markers() {
    local dir="$1"
    cat > "$dir/.test-index" <<'EOF'
# .test-index — test fixture with RED markers
plugins/dso/scripts/some-script.sh: tests/scripts/test-some-script.sh [test_red_marker], tests/scripts/test-other.sh
plugins/dso/hooks/some-hook.sh: tests/hooks/test-some-hook.sh [test_another_red]
EOF
}

make_test_index_no_markers() {
    local dir="$1"
    cat > "$dir/.test-index" <<'EOF'
# .test-index — test fixture with no RED markers
plugins/dso/scripts/some-script.sh: tests/scripts/test-some-script.sh, tests/scripts/test-other.sh
plugins/dso/hooks/some-hook.sh: tests/hooks/test-some-hook.sh
EOF
}

make_test_index_comments_only() {
    local dir="$1"
    cat > "$dir/.test-index" <<'EOF'
# .test-index — comments only, no entries
# This line has [brackets] but is a comment — should be ignored
EOF
}

# ── Test 1: tk close epic BLOCKS when .test-index has RED markers ─────────────

echo "Test 1: tk close epic blocks when .test-index has RED markers"
TMPDIR_T1=$(mktemp -d)
export TICKETS_DIR="$TMPDIR_T1"

make_epic "$TMPDIR_T1" "epic-aaa"
make_test_index_with_markers "$TMPDIR_T1"

output=$(TK_REPO_ROOT="$TMPDIR_T1" "$TK_SCRIPT" close epic-aaa --reason="done" 2>&1)
exit_code=$?

if [[ "$exit_code" -ne 0 ]] && echo "$output" | grep -qi "red.*marker\|marker.*red\|\[.*\].*test-index\|test-index.*\["; then
    echo "  PASS: tk close epic blocked with RED marker error"
    (( PASS++ ))
else
    echo "  FAIL: expected non-zero exit and RED marker error message" >&2
    echo "  exit=$exit_code output: $output" >&2
    (( FAIL++ ))
fi

rm -rf "$TMPDIR_T1"

# ── Test 2: error message lists stale marker entries ─────────────────────────

echo "Test 2: error message lists the stale marker entries"
TMPDIR_T2=$(mktemp -d)
export TICKETS_DIR="$TMPDIR_T2"

make_epic "$TMPDIR_T2" "epic-bbb"
make_test_index_with_markers "$TMPDIR_T2"

output=$(TK_REPO_ROOT="$TMPDIR_T2" "$TK_SCRIPT" close epic-bbb --reason="done" 2>&1)
exit_code=$?

# Error message must contain the marker names from the test-index
if [[ "$exit_code" -ne 0 ]] && \
   echo "$output" | grep -q "test_red_marker" && \
   echo "$output" | grep -q "test_another_red"; then
    echo "  PASS: error message lists all stale marker names"
    (( PASS++ ))
else
    echo "  FAIL: expected error listing test_red_marker and test_another_red" >&2
    echo "  exit=$exit_code output: $output" >&2
    (( FAIL++ ))
fi

rm -rf "$TMPDIR_T2"

# ── Test 3: tk close epic SUCCEEDS when no RED markers in .test-index ─────────

echo "Test 3: tk close epic succeeds when .test-index has no RED markers"
TMPDIR_T3=$(mktemp -d)
export TICKETS_DIR="$TMPDIR_T3"

make_epic "$TMPDIR_T3" "epic-ccc"
make_test_index_no_markers "$TMPDIR_T3"

output=$(TK_REPO_ROOT="$TMPDIR_T3" "$TK_SCRIPT" close epic-ccc --reason="done" 2>&1)
exit_code=$?

status_after=$(grep '^status:' "$TMPDIR_T3/epic-ccc.md" | awk '{print $2}')
if [[ "$exit_code" -eq 0 ]] && [[ "$status_after" == "closed" ]]; then
    echo "  PASS: tk close epic succeeded with no RED markers"
    (( PASS++ ))
else
    echo "  FAIL: expected exit 0 and status=closed, got exit=$exit_code status=$status_after" >&2
    echo "  output: $output" >&2
    (( FAIL++ ))
fi

rm -rf "$TMPDIR_T3"

# ── Test 4: tk close epic SUCCEEDS when .test-index is absent ─────────────────

echo "Test 4: tk close epic succeeds when .test-index is absent"
TMPDIR_T4=$(mktemp -d)
export TICKETS_DIR="$TMPDIR_T4"

make_epic "$TMPDIR_T4" "epic-ddd"
# No .test-index created

output=$(TK_REPO_ROOT="$TMPDIR_T4" "$TK_SCRIPT" close epic-ddd --reason="done" 2>&1)
exit_code=$?

status_after=$(grep '^status:' "$TMPDIR_T4/epic-ddd.md" | awk '{print $2}')
if [[ "$exit_code" -eq 0 ]] && [[ "$status_after" == "closed" ]]; then
    echo "  PASS: tk close epic succeeded with no .test-index"
    (( PASS++ ))
else
    echo "  FAIL: expected exit 0 and status=closed, got exit=$exit_code status=$status_after" >&2
    echo "  output: $output" >&2
    (( FAIL++ ))
fi

rm -rf "$TMPDIR_T4"

# ── Test 5: tk close epic SUCCEEDS when .test-index has only comments ─────────

echo "Test 5: tk close epic succeeds when .test-index has only comments (no entries)"
TMPDIR_T5=$(mktemp -d)
export TICKETS_DIR="$TMPDIR_T5"

make_epic "$TMPDIR_T5" "epic-eee"
make_test_index_comments_only "$TMPDIR_T5"

output=$(TK_REPO_ROOT="$TMPDIR_T5" "$TK_SCRIPT" close epic-eee --reason="done" 2>&1)
exit_code=$?

status_after=$(grep '^status:' "$TMPDIR_T5/epic-eee.md" | awk '{print $2}')
if [[ "$exit_code" -eq 0 ]] && [[ "$status_after" == "closed" ]]; then
    echo "  PASS: tk close epic succeeded with comments-only .test-index"
    (( PASS++ ))
else
    echo "  FAIL: expected exit 0 and status=closed, got exit=$exit_code status=$status_after" >&2
    echo "  output: $output" >&2
    (( FAIL++ ))
fi

rm -rf "$TMPDIR_T5"

# ── Test 6: tk close non-epic (task) is NOT blocked by RED markers ────────────

echo "Test 6: tk close task is not blocked by RED markers (only epics are checked)"
TMPDIR_T6=$(mktemp -d)
export TICKETS_DIR="$TMPDIR_T6"

make_task "$TMPDIR_T6" "task-fff"
make_test_index_with_markers "$TMPDIR_T6"

output=$(TK_REPO_ROOT="$TMPDIR_T6" "$TK_SCRIPT" close task-fff --reason="done" 2>&1)
exit_code=$?

status_after=$(grep '^status:' "$TMPDIR_T6/task-fff.md" | awk '{print $2}')
if [[ "$exit_code" -eq 0 ]] && [[ "$status_after" == "closed" ]]; then
    echo "  PASS: tk close task succeeded even with RED markers (only epics are gated)"
    (( PASS++ ))
else
    echo "  FAIL: expected exit 0 and status=closed for task, got exit=$exit_code status=$status_after" >&2
    echo "  output: $output" >&2
    (( FAIL++ ))
fi

rm -rf "$TMPDIR_T6"

# ── Test 7: epic close not blocked when markers are in comment lines ──────────

echo "Test 7: epic close not blocked by [marker] syntax in comment lines"
TMPDIR_T7=$(mktemp -d)
export TICKETS_DIR="$TMPDIR_T7"

make_epic "$TMPDIR_T7" "epic-ggg"
# [marker] only appears in a comment line — should not trigger block
cat > "$TMPDIR_T7/.test-index" <<'EOF'
# This is a [comment_marker] that should be ignored
plugins/dso/scripts/foo.sh: tests/scripts/test-foo.sh
EOF

output=$(TK_REPO_ROOT="$TMPDIR_T7" "$TK_SCRIPT" close epic-ggg --reason="done" 2>&1)
exit_code=$?

status_after=$(grep '^status:' "$TMPDIR_T7/epic-ggg.md" | awk '{print $2}')
if [[ "$exit_code" -eq 0 ]] && [[ "$status_after" == "closed" ]]; then
    echo "  PASS: comment lines with [marker] syntax do not block epic close"
    (( PASS++ ))
else
    echo "  FAIL: expected exit 0 and status=closed, got exit=$exit_code status=$status_after" >&2
    echo "  output: $output" >&2
    (( FAIL++ ))
fi

rm -rf "$TMPDIR_T7"

# ── Report ────────────────────────────────────────────────────────────────────

print_results
