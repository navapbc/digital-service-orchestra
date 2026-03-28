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

# ── Test 5: built agents contain security overlay classification item ─────────
#
# RED: security_overlay_warranted is not yet present in any delta or base file.
# GREEN: after classification checklist items are added to source files, each
#        built agent will contain the item as part of its composed content.

test_built_agents_contain_security_overlay_item() {
    _snapshot_fail

    if [[ ! -x "$BUILD_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_built_agents_contain_security_overlay_item\n  build script not found or not executable: %s\n" "$BUILD_SCRIPT" >&2
        assert_pass_if_clean "test_built_agents_contain_security_overlay_item"
        return
    fi

    local prompts_dir="$DSO_PLUGIN_DIR/docs/workflows/prompts"
    local out_dir
    out_dir="$(mktemp -d)"

    bash "$BUILD_SCRIPT" \
        --base "$prompts_dir/reviewer-base.md" \
        --deltas "$prompts_dir" \
        --output "$out_dir" 2>/dev/null

    # Every generated agent file must contain the security overlay classification item
    local agent_file
    for agent_file in \
        "$out_dir/code-reviewer-light.md" \
        "$out_dir/code-reviewer-standard.md" \
        "$out_dir/code-reviewer-deep-arch.md" \
        "$out_dir/code-reviewer-deep-correctness.md" \
        "$out_dir/code-reviewer-deep-hygiene.md" \
        "$out_dir/code-reviewer-deep-verification.md"
    do
        local agent_name
        agent_name="$(basename "$agent_file")"
        local content
        content="$(cat "$agent_file" 2>/dev/null || echo "")"
        assert_contains "${agent_name}_has_security_overlay_item" \
            "security_overlay_warranted" \
            "$content"
    done

    rm -rf "$out_dir"
    assert_pass_if_clean "test_built_agents_contain_security_overlay_item"
}

# ── Test 6: built agents contain performance overlay classification item ───────
#
# RED: performance_overlay_warranted is not yet present in any delta or base file.
# GREEN: after classification checklist items are added to source files, each
#        built agent will contain the item as part of its composed content.

test_built_agents_contain_performance_overlay_item() {
    _snapshot_fail

    if [[ ! -x "$BUILD_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_built_agents_contain_performance_overlay_item\n  build script not found or not executable: %s\n" "$BUILD_SCRIPT" >&2
        assert_pass_if_clean "test_built_agents_contain_performance_overlay_item"
        return
    fi

    local prompts_dir="$DSO_PLUGIN_DIR/docs/workflows/prompts"
    local out_dir
    out_dir="$(mktemp -d)"

    bash "$BUILD_SCRIPT" \
        --base "$prompts_dir/reviewer-base.md" \
        --deltas "$prompts_dir" \
        --output "$out_dir" 2>/dev/null

    # Every generated agent file must contain the performance overlay classification item
    local agent_file
    for agent_file in \
        "$out_dir/code-reviewer-light.md" \
        "$out_dir/code-reviewer-standard.md" \
        "$out_dir/code-reviewer-deep-arch.md" \
        "$out_dir/code-reviewer-deep-correctness.md" \
        "$out_dir/code-reviewer-deep-hygiene.md" \
        "$out_dir/code-reviewer-deep-verification.md"
    do
        local agent_name
        agent_name="$(basename "$agent_file")"
        local content
        content="$(cat "$agent_file" 2>/dev/null || echo "")"
        assert_contains "${agent_name}_has_performance_overlay_item" \
            "performance_overlay_warranted" \
            "$content"
    done

    rm -rf "$out_dir"
    assert_pass_if_clean "test_built_agents_contain_performance_overlay_item"
}

# ── Test 7: security-red-team agent file is generated ────────────────────────
#
# RED: reviewer-delta-security-red-team.md does not exist and _model_for_tier()
#      has no entry for security-red-team, so the build script will not produce
#      code-reviewer-security-red-team.md.
# GREEN: after adding the delta file and tier mappings, this file is generated.

test_security_red_team_agent_file_is_generated() {
    _snapshot_fail

    if [[ ! -x "$BUILD_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_security_red_team_agent_file_is_generated\n  build script not found or not executable: %s\n" "$BUILD_SCRIPT" >&2
        assert_pass_if_clean "test_security_red_team_agent_file_is_generated"
        return
    fi

    local prompts_dir="$DSO_PLUGIN_DIR/docs/workflows/prompts"
    local out_dir
    out_dir="$(mktemp -d)"

    bash "$BUILD_SCRIPT" \
        --base "$prompts_dir/reviewer-base.md" \
        --deltas "$prompts_dir" \
        --output "$out_dir" 2>/dev/null || true

    local target_file="$out_dir/code-reviewer-security-red-team.md"
    local file_exists="no"
    [[ -f "$target_file" ]] && file_exists="yes"
    assert_eq "security_red_team_agent_file_generated" "yes" "$file_exists"

    rm -rf "$out_dir"
    assert_pass_if_clean "test_security_red_team_agent_file_is_generated"
}

# ── Test 8: security-red-team agent frontmatter declares model: opus ─────────
#
# RED: the tier has no _model_for_tier() entry, so no file is generated and no
#      "model: opus" line can appear in its frontmatter.
# GREEN: after _model_for_tier() maps security-red-team → opus, the generated
#        file's YAML frontmatter contains "model: opus".

test_security_red_team_agent_has_opus_model() {
    _snapshot_fail

    if [[ ! -x "$BUILD_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_security_red_team_agent_has_opus_model\n  build script not found or not executable: %s\n" "$BUILD_SCRIPT" >&2
        assert_pass_if_clean "test_security_red_team_agent_has_opus_model"
        return
    fi

    local prompts_dir="$DSO_PLUGIN_DIR/docs/workflows/prompts"
    local out_dir
    out_dir="$(mktemp -d)"

    bash "$BUILD_SCRIPT" \
        --base "$prompts_dir/reviewer-base.md" \
        --deltas "$prompts_dir" \
        --output "$out_dir" 2>/dev/null || true

    local target_file="$out_dir/code-reviewer-security-red-team.md"
    local model_line=""
    if [[ -f "$target_file" ]]; then
        # Extract the model: line from the YAML frontmatter (between the two --- delimiters)
        model_line=$(awk '/^---/{f++; next} f==1 && /^model:/{print; exit}' "$target_file")
    fi
    assert_eq "security_red_team_model_is_opus" "model: opus" "$model_line"

    rm -rf "$out_dir"
    assert_pass_if_clean "test_security_red_team_agent_has_opus_model"
}

# ── Test 9: security-red-team agent body contains tier identity text ──────────
#
# RED: the delta file does not exist, so the generated agent body has no
#      security-red-team tier identity section.
# GREEN: after the delta file is created with a Tier Identity section referencing
#        "security-red-team", this assertion passes.

test_security_red_team_agent_contains_tier_identity() {
    _snapshot_fail

    if [[ ! -x "$BUILD_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_security_red_team_agent_contains_tier_identity\n  build script not found or not executable: %s\n" "$BUILD_SCRIPT" >&2
        assert_pass_if_clean "test_security_red_team_agent_contains_tier_identity"
        return
    fi

    local prompts_dir="$DSO_PLUGIN_DIR/docs/workflows/prompts"
    local out_dir
    out_dir="$(mktemp -d)"

    bash "$BUILD_SCRIPT" \
        --base "$prompts_dir/reviewer-base.md" \
        --deltas "$prompts_dir" \
        --output "$out_dir" 2>/dev/null || true

    local target_file="$out_dir/code-reviewer-security-red-team.md"
    local agent_content=""
    [[ -f "$target_file" ]] && agent_content="$(cat "$target_file")"
    assert_contains "security_red_team_tier_identity_present" "security-red-team" "$agent_content"

    rm -rf "$out_dir"
    assert_pass_if_clean "test_security_red_team_agent_contains_tier_identity"
}

# ── Test 10: security-red-team agent contains authorization keyword ───────────
#
# RED: delta file absent; no security criteria keywords appear in the output.
# GREEN: delta file includes "authorization" in its security criteria section.

test_security_red_team_agent_contains_authorization_keyword() {
    _snapshot_fail

    if [[ ! -x "$BUILD_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_security_red_team_agent_contains_authorization_keyword\n  build script not found or not executable: %s\n" "$BUILD_SCRIPT" >&2
        assert_pass_if_clean "test_security_red_team_agent_contains_authorization_keyword"
        return
    fi

    local prompts_dir="$DSO_PLUGIN_DIR/docs/workflows/prompts"
    local out_dir
    out_dir="$(mktemp -d)"

    bash "$BUILD_SCRIPT" \
        --base "$prompts_dir/reviewer-base.md" \
        --deltas "$prompts_dir" \
        --output "$out_dir" 2>/dev/null || true

    local target_file="$out_dir/code-reviewer-security-red-team.md"
    local agent_content=""
    [[ -f "$target_file" ]] && agent_content="$(cat "$target_file")"
    assert_contains "security_red_team_has_authorization_keyword" "authorization" "$agent_content"

    rm -rf "$out_dir"
    assert_pass_if_clean "test_security_red_team_agent_contains_authorization_keyword"
}

# ── Test 11: security-red-team agent contains data flow keyword ───────────────
#
# RED: delta file absent; "data flow" does not appear in the output.
# GREEN: delta file includes "data flow" in its security criteria section.

test_security_red_team_agent_contains_data_flow_keyword() {
    _snapshot_fail

    if [[ ! -x "$BUILD_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_security_red_team_agent_contains_data_flow_keyword\n  build script not found or not executable: %s\n" "$BUILD_SCRIPT" >&2
        assert_pass_if_clean "test_security_red_team_agent_contains_data_flow_keyword"
        return
    fi

    local prompts_dir="$DSO_PLUGIN_DIR/docs/workflows/prompts"
    local out_dir
    out_dir="$(mktemp -d)"

    bash "$BUILD_SCRIPT" \
        --base "$prompts_dir/reviewer-base.md" \
        --deltas "$prompts_dir" \
        --output "$out_dir" 2>/dev/null || true

    local target_file="$out_dir/code-reviewer-security-red-team.md"
    local agent_content=""
    [[ -f "$target_file" ]] && agent_content="$(cat "$target_file")"
    assert_contains "security_red_team_has_data_flow_keyword" "data flow" "$agent_content"

    rm -rf "$out_dir"
    assert_pass_if_clean "test_security_red_team_agent_contains_data_flow_keyword"
}

# ── Test 12: security-red-team agent contains TOCTOU keyword ─────────────────
#
# RED: delta file absent; "TOCTOU" does not appear in the output.
# GREEN: delta file includes "TOCTOU" in its security criteria section.

test_security_red_team_agent_contains_toctou_keyword() {
    _snapshot_fail

    if [[ ! -x "$BUILD_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_security_red_team_agent_contains_toctou_keyword\n  build script not found or not executable: %s\n" "$BUILD_SCRIPT" >&2
        assert_pass_if_clean "test_security_red_team_agent_contains_toctou_keyword"
        return
    fi

    local prompts_dir="$DSO_PLUGIN_DIR/docs/workflows/prompts"
    local out_dir
    out_dir="$(mktemp -d)"

    bash "$BUILD_SCRIPT" \
        --base "$prompts_dir/reviewer-base.md" \
        --deltas "$prompts_dir" \
        --output "$out_dir" 2>/dev/null || true

    local target_file="$out_dir/code-reviewer-security-red-team.md"
    local agent_content=""
    [[ -f "$target_file" ]] && agent_content="$(cat "$target_file")"
    assert_contains "security_red_team_has_toctou_keyword" "TOCTOU" "$agent_content"

    rm -rf "$out_dir"
    assert_pass_if_clean "test_security_red_team_agent_contains_toctou_keyword"
}

# ── Performance reviewer tier — fixture setup ─────────────────────────────────
#
# A separate fixture dir augments the standard 6 deltas with a
# reviewer-delta-performance.md so the build script has something to compose.
# The performance tier does not yet exist in build-review-agents.sh:
#   - _model_for_tier("performance") falls through to the error branch
#   - No code-reviewer-performance.md is written
#
# RED marker: test_performance_reviewer_builds_with_opus_model

PERF_FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$PERF_FIXTURE_DIR"' EXIT

cp "$FIXTURE_DIR/reviewer-base.md" "$PERF_FIXTURE_DIR/"
for _pn in "${DELTA_NAMES[@]}"; do
    cp "$FIXTURE_DIR/reviewer-delta-${_pn}.md" "$PERF_FIXTURE_DIR/"
done

cat > "$PERF_FIXTURE_DIR/reviewer-delta-performance.md" <<'PERF_DELTA'
# Code Reviewer — Performance Tier Delta

**Tier**: performance

## Performance Review Focus

This reviewer evaluates performance-critical code paths, algorithmic complexity,
and runtime efficiency. Severity ratings follow bright-line criteria:

- **critical**: a change where it breaks existing latency SLOs or introduces
  O(N^2)+ complexity — e.g., it breaks guaranteed throughput bounds or
  it scales poorly under realistic production load.
- **important**: unnecessary allocations in hot paths, missing indexes, N+1
  queries, synchronous I/O where async is expected.
- **minor**: micro-optimisations with marginal impact.

All findings must use the standard REVIEW_RESULT output contract.
PERF_DELTA

# ── Test 13: performance reviewer agent file is generated ────────────────────
#
# RED: _model_for_tier("performance") errors → build exits non-zero →
#      code-reviewer-performance.md is never written.
# GREEN: after adding the performance case to _model_for_tier() and
#        _description_for_tier(), the file is generated.

test_performance_reviewer_builds_with_opus_model() {
    _snapshot_fail

    if [[ ! -x "$BUILD_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_performance_reviewer_builds_with_opus_model\n  build script not found or not executable: %s\n" "$BUILD_SCRIPT" >&2
        assert_pass_if_clean "test_performance_reviewer_builds_with_opus_model"
        return
    fi

    local out_dir
    out_dir="$(mktemp -d)"

    # Run build with the augmented fixture dir (6 standard deltas + performance).
    # The build must exit 0 and produce code-reviewer-performance.md.
    local rc=0
    bash "$BUILD_SCRIPT" \
        --base "$PERF_FIXTURE_DIR/reviewer-base.md" \
        --deltas "$PERF_FIXTURE_DIR" \
        --output "$out_dir" 2>/dev/null || rc=$?

    assert_eq "performance_build_exits_zero" "0" "$rc"

    local agent_file="$out_dir/code-reviewer-performance.md"
    local file_exists="no"
    [[ -f "$agent_file" ]] && file_exists="yes"
    assert_eq "performance_agent_file_generated" "yes" "$file_exists"

    # Frontmatter must declare model: opus
    local file_content=""
    [[ -f "$agent_file" ]] && file_content="$(cat "$agent_file")"
    assert_contains "performance_agent_model_is_opus" "model: opus" "$file_content"

    rm -rf "$out_dir"
    assert_pass_if_clean "test_performance_reviewer_builds_with_opus_model"
}

# ── Test 14: performance agent contains bright-line severity keywords ─────────
#
# RED: file not generated (tier unknown), so content is empty and all keyword
#      assertions fail.
# GREEN: after delta file and tier mappings exist, the composed file contains
#        the five bright-line terms from the delta.

test_performance_reviewer_contains_bright_line_severity_keywords() {
    _snapshot_fail

    if [[ ! -x "$BUILD_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_performance_reviewer_contains_bright_line_severity_keywords\n  build script not found or not executable: %s\n" "$BUILD_SCRIPT" >&2
        assert_pass_if_clean "test_performance_reviewer_contains_bright_line_severity_keywords"
        return
    fi

    local out_dir
    out_dir="$(mktemp -d)"

    bash "$BUILD_SCRIPT" \
        --base "$PERF_FIXTURE_DIR/reviewer-base.md" \
        --deltas "$PERF_FIXTURE_DIR" \
        --output "$out_dir" 2>/dev/null || true

    local agent_file="$out_dir/code-reviewer-performance.md"
    local file_content=""
    [[ -f "$agent_file" ]] && file_content="$(cat "$agent_file")"

    assert_contains "performance_agent_contains_critical"  "critical"  "$file_content"
    assert_contains "performance_agent_contains_important" "important" "$file_content"
    assert_contains "performance_agent_contains_minor"     "minor"     "$file_content"
    assert_contains "performance_agent_contains_it_breaks" "it breaks" "$file_content"
    assert_contains "performance_agent_contains_it_scales" "it scales" "$file_content"

    rm -rf "$out_dir"
    assert_pass_if_clean "test_performance_reviewer_contains_bright_line_severity_keywords"
}

# ── Test 15: performance tier is counted in total output ─────────────────────
#
# RED: build fails on unknown tier → 0 files produced → count assertion fails.
# GREEN: 6 standard tiers + 1 performance = 7 agent files.

test_performance_reviewer_counted_in_total_agents() {
    _snapshot_fail

    if [[ ! -x "$BUILD_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_performance_reviewer_counted_in_total_agents\n  build script not found or not executable: %s\n" "$BUILD_SCRIPT" >&2
        assert_pass_if_clean "test_performance_reviewer_counted_in_total_agents"
        return
    fi

    local out_dir
    out_dir="$(mktemp -d)"

    bash "$BUILD_SCRIPT" \
        --base "$PERF_FIXTURE_DIR/reviewer-base.md" \
        --deltas "$PERF_FIXTURE_DIR" \
        --output "$out_dir" 2>/dev/null || true

    # Expect exactly 7 files: 6 original tiers + performance
    local count
    count=$(find "$out_dir" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d ' ')
    assert_eq "performance_tier_raises_agent_count_to_7" "7" "$count"

    rm -rf "$out_dir"
    assert_pass_if_clean "test_performance_reviewer_counted_in_total_agents"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

test_build_produces_6_agent_files
test_build_agent_list_matches_delta_files
test_build_atomic_write_on_failure
test_build_embeds_content_hash
test_built_agents_contain_security_overlay_item
test_built_agents_contain_performance_overlay_item
test_security_red_team_agent_file_is_generated
test_security_red_team_agent_has_opus_model
test_security_red_team_agent_contains_tier_identity
test_security_red_team_agent_contains_authorization_keyword
test_security_red_team_agent_contains_data_flow_keyword
test_security_red_team_agent_contains_toctou_keyword
test_performance_reviewer_builds_with_opus_model
test_performance_reviewer_contains_bright_line_severity_keywords
test_performance_reviewer_counted_in_total_agents

print_summary
