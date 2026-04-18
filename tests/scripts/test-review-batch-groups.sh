#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
PASS=0; FAIL=0

test_batch_groups_respects_max_agents_cap() {
    local desc="test_batch_groups_respects_max_agents_cap"
    local files; files=$(printf 'file%d.py\n' {1..10})
    local output; output=$(echo "$files" | MAX_AGENTS=3 bash "$REPO_ROOT/plugins/dso/scripts/review-batch-groups.sh" 2>/dev/null || true)
    local group_count; group_count=$(echo "$output" | grep -c '^GROUP_[0-9]\+:' || true)
    if [ "$group_count" -eq 3 ]; then
        echo "PASS: $desc"; PASS=$((PASS+1))
    else
        echo "FAIL: $desc — expected 3 groups, got $group_count"; FAIL=$((FAIL+1))
    fi
}

test_batch_groups_distributes_evenly() {
    local desc="test_batch_groups_distributes_evenly"
    local files; files=$(printf 'file%d.py\n' {1..6})
    local output; output=$(echo "$files" | MAX_AGENTS=3 bash "$REPO_ROOT/plugins/dso/scripts/review-batch-groups.sh" 2>/dev/null || true)
    local all_correct=1
    while IFS= read -r line; do
        [[ "$line" =~ ^GROUP_[0-9]+: ]] || continue
        local count; count=$(echo "$line" | tr ' ' '\n' | grep -c '\.py$' || true)
        [ "$count" -eq 2 ] || all_correct=0
    done <<< "$output"
    if [ "$all_correct" -eq 1 ]; then
        echo "PASS: $desc"; PASS=$((PASS+1))
    else
        echo "FAIL: $desc — groups not evenly distributed"; FAIL=$((FAIL+1))
    fi
}

test_batch_groups_handles_remainder() {
    local desc="test_batch_groups_handles_remainder"
    local files; files=$(printf 'file%d.py\n' {1..7})
    local output; output=$(echo "$files" | MAX_AGENTS=3 bash "$REPO_ROOT/plugins/dso/scripts/review-batch-groups.sh" 2>/dev/null || true)
    local group_count; group_count=$(echo "$output" | grep -c '^GROUP_[0-9]\+:' || true)
    local total_files; total_files=$(echo "$output" | grep '^GROUP_[0-9]\+:' | tr ' ' '\n' | grep -c '\.py$' || true)
    if [ "$group_count" -eq 3 ] && [ "$total_files" -eq 7 ]; then
        echo "PASS: $desc"; PASS=$((PASS+1))
    else
        echo "FAIL: $desc — expected 3 groups with 7 total files, got group_count=$group_count total_files=$total_files"; FAIL=$((FAIL+1))
    fi
}

test_batch_groups_single_group() {
    local desc="test_batch_groups_single_group"
    local files; files=$(printf 'file%d.py\n' {1..3})
    local output; output=$(echo "$files" | MAX_AGENTS=5 bash "$REPO_ROOT/plugins/dso/scripts/review-batch-groups.sh" 2>/dev/null || true)
    local group_count; group_count=$(echo "$output" | grep -c '^GROUP_[0-9]\+:' || true)
    if [ "$group_count" -eq 3 ]; then
        echo "PASS: $desc"; PASS=$((PASS+1))
    else
        echo "FAIL: $desc — expected 3 groups (min(files,MAX_AGENTS)), got $group_count"; FAIL=$((FAIL+1))
    fi
}

test_batch_groups_exits_0() {
    local desc="test_batch_groups_exits_0"
    local files; files=$(printf 'file%d.py\n' {1..4})
    if echo "$files" | MAX_AGENTS=2 bash "$REPO_ROOT/plugins/dso/scripts/review-batch-groups.sh" >/dev/null 2>&1; then
        echo "PASS: $desc"; PASS=$((PASS+1))
    else
        echo "FAIL: $desc — expected exit 0"; FAIL=$((FAIL+1))
    fi
}

test_batch_groups_respects_max_agents_cap
test_batch_groups_distributes_evenly
test_batch_groups_handles_remainder
test_batch_groups_single_group
test_batch_groups_exits_0

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
