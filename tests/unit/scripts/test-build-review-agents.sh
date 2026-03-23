#!/usr/bin/env bash
# tests/unit/scripts/test-build-review-agents.sh
# TDD RED tests for plugins/dso/scripts/build-review-agents.sh
#
# Tests verify the build script:
#   1. Produces 6 agent files (one per delta)
#   2. Agent list matches delta files on disk
#   3. Atomic write: missing delta causes no partial output
#   4. Embeds content hash of source inputs in each generated file
#
# Approach: fixture dir with minimal reviewer-base.md and 6 reviewer-delta-*.md;
# run build script against temp output dir; assert expected outcomes.
#
# Usage: bash tests/unit/scripts/test-build-review-agents.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
BUILD_SCRIPT="$DSO_PLUGIN_DIR/scripts/build-review-agents.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-build-review-agents.sh ==="

# ── Fixtures ──────────────────────────────────────────────────────────────────
FIXTURE_DIR="$(mktemp -d)"
OUTPUT_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR" "$OUTPUT_DIR"' EXIT

# Create minimal reviewer-base.md fixture
cat > "$FIXTURE_DIR/reviewer-base.md" <<'BASE'
# Code Reviewer — Universal Base Guidance

This is the base fragment shared by all review agents.

## Mandatory Output Contract

REVIEW_RESULT: {passed|failed}
BASE

# Create 6 reviewer-delta-*.md fixtures matching real delta file names
DELTA_NAMES=(light standard deep-correctness deep-verification deep-hygiene deep-arch)

for name in "${DELTA_NAMES[@]}"; do
    cat > "$FIXTURE_DIR/reviewer-delta-${name}.md" <<DELTA
# Code Reviewer — ${name} Tier Delta

**Tier**: ${name}

This delta file is composed with reviewer-base.md by build-review-agents.sh.
DELTA
done

# ── Test 1: build produces 6 agent files ─────────────────────────────────────

test_build_produces_6_agent_files() {
    _snapshot_fail
    local out_dir
    out_dir="$(mktemp -d)"

    # Build script must exist and be executable
    if [[ ! -x "$BUILD_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_build_produces_6_agent_files\n  build script not found or not executable: %s\n" "$BUILD_SCRIPT" >&2
        rm -rf "$out_dir"
        assert_pass_if_clean "test_build_produces_6_agent_files"
        return
    fi

    # Run build script with fixture inputs and temp output dir
    bash "$BUILD_SCRIPT" \
        --base "$FIXTURE_DIR/reviewer-base.md" \
        --deltas "$FIXTURE_DIR" \
        --output "$out_dir" 2>/dev/null

    # Count generated agent files
    local count
    count=$(find "$out_dir" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d ' ')
    assert_eq "agent_file_count" "6" "$count"

    rm -rf "$out_dir"
    assert_pass_if_clean "test_build_produces_6_agent_files"
}

# ── Test 2: agent list matches delta files ────────────────────────────────────

test_build_agent_list_matches_delta_files() {
    _snapshot_fail

    if [[ ! -x "$BUILD_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_build_agent_list_matches_delta_files\n  build script not found or not executable: %s\n" "$BUILD_SCRIPT" >&2
        assert_pass_if_clean "test_build_agent_list_matches_delta_files"
        return
    fi

    # Extract the declared agent list from the build script.
    # Expect the script to declare a list of agent/tier names that corresponds
    # to the delta files on disk. We verify the script's internal list against
    # actual delta files in the prompts directory.
    local prompts_dir="$DSO_PLUGIN_DIR/docs/workflows/prompts"
    local delta_count
    delta_count=$(find "$prompts_dir" -maxdepth 1 -name 'reviewer-delta-*.md' -type f | wc -l | tr -d ' ')

    local out_dir
    out_dir="$(mktemp -d)"

    bash "$BUILD_SCRIPT" \
        --base "$prompts_dir/reviewer-base.md" \
        --deltas "$prompts_dir" \
        --output "$out_dir" 2>/dev/null

    local built_count
    built_count=$(find "$out_dir" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d ' ')
    assert_eq "built_matches_delta_count" "$delta_count" "$built_count"

    rm -rf "$out_dir"
    assert_pass_if_clean "test_build_agent_list_matches_delta_files"
}

# ── Test 3: atomic write on failure ───────────────────────────────────────────

test_build_atomic_write_on_failure() {
    _snapshot_fail

    if [[ ! -x "$BUILD_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_build_atomic_write_on_failure\n  build script not found or not executable: %s\n" "$BUILD_SCRIPT" >&2
        assert_pass_if_clean "test_build_atomic_write_on_failure"
        return
    fi

    # Create a broken fixture dir: base exists but one delta is missing
    local broken_dir
    broken_dir="$(mktemp -d)"
    cp "$FIXTURE_DIR/reviewer-base.md" "$broken_dir/"
    # Only copy 5 of 6 deltas — omit one to simulate a missing delta
    for name in light standard deep-correctness deep-verification deep-hygiene; do
        cp "$FIXTURE_DIR/reviewer-delta-${name}.md" "$broken_dir/"
    done
    # Add a reference to the missing delta (deep-arch) so the build script
    # attempts to compose it and fails
    # The build script should discover deltas by globbing reviewer-delta-*.md,
    # but we also need it to expect all 6. We simulate by removing a file
    # that would normally be there.

    local out_dir
    out_dir="$(mktemp -d)"

    # Run build with the broken fixture dir; expect non-zero exit
    local rc=0
    bash "$BUILD_SCRIPT" \
        --base "$broken_dir/reviewer-base.md" \
        --deltas "$broken_dir" \
        --output "$out_dir" \
        --expect-count 6 2>/dev/null || rc=$?

    # On failure, no partial output files should exist
    local file_count
    file_count=$(find "$out_dir" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d ' ')
    assert_eq "no_partial_output_on_failure" "0" "$file_count"

    rm -rf "$broken_dir" "$out_dir"
    assert_pass_if_clean "test_build_atomic_write_on_failure"
}

# ── Test 4: embeds content hash ───────────────────────────────────────────────

test_build_embeds_content_hash() {
    _snapshot_fail

    if [[ ! -x "$BUILD_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_build_embeds_content_hash\n  build script not found or not executable: %s\n" "$BUILD_SCRIPT" >&2
        assert_pass_if_clean "test_build_embeds_content_hash"
        return
    fi

    local out_dir
    out_dir="$(mktemp -d)"

    bash "$BUILD_SCRIPT" \
        --base "$FIXTURE_DIR/reviewer-base.md" \
        --deltas "$FIXTURE_DIR" \
        --output "$out_dir" 2>/dev/null

    # Each generated file should contain a content hash line
    # Expected format: <!-- content-hash: <sha256hex> -->
    local missing_hash=0
    local file
    for file in "$out_dir"/*.md; do
        [ -f "$file" ] || continue
        if ! grep -q 'content-hash:' "$file"; then
            (( missing_hash++ ))
            printf "  missing content-hash in: %s\n" "$(basename "$file")" >&2
        fi
    done
    assert_eq "all_files_have_content_hash" "0" "$missing_hash"

    # Verify hash is deterministic: rebuild and compare
    local out_dir2
    out_dir2="$(mktemp -d)"
    bash "$BUILD_SCRIPT" \
        --base "$FIXTURE_DIR/reviewer-base.md" \
        --deltas "$FIXTURE_DIR" \
        --output "$out_dir2" 2>/dev/null

    local hash_mismatch=0
    for file in "$out_dir"/*.md; do
        [ -f "$file" ] || continue
        local basename_f
        basename_f="$(basename "$file")"
        local hash1 hash2
        hash1=$(grep 'content-hash:' "$file" | head -1)
        hash2=$(grep 'content-hash:' "$out_dir2/$basename_f" | head -1)
        if [[ "$hash1" != "$hash2" ]]; then
            (( hash_mismatch++ ))
            printf "  hash mismatch for: %s\n" "$basename_f" >&2
        fi
    done
    assert_eq "content_hash_deterministic" "0" "$hash_mismatch"

    rm -rf "$out_dir" "$out_dir2"
    assert_pass_if_clean "test_build_embeds_content_hash"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

test_build_produces_6_agent_files
test_build_agent_list_matches_delta_files
test_build_atomic_write_on_failure
test_build_embeds_content_hash

print_summary
