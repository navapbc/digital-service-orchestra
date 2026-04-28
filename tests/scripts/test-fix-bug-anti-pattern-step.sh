#!/usr/bin/env bash
# tests/scripts/test-fix-bug-anti-pattern-step.sh
# Tests: assert fix-bug SKILL.md documents Step 7.5 (anti-pattern scan) and its
# sub-requirements: batch dispatch limit, commit pre-condition, empty scan exit,
# commit pre-condition gate, and observation tracking.
#
# All six tests are intended to FAIL (RED) against the current SKILL.md until
# Step 7.5 is added in the implementation task.
#
# Usage: bash tests/scripts/test-fix-bug-anti-pattern-step.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_MD="$PLUGIN_ROOT/plugins/dso/skills/fix-bug/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-fix-bug-anti-pattern-step.sh ==="
echo ""

skill_content="$(cat "$SKILL_MD")"

# ── test_step_7_5_exists ──────────────────────────────────────────────────────
# SKILL.md must document Step 7.5 — the anti-pattern scan step that follows
# fix verification (Phase E Step 4) and precedes commit (Phase H Step 1).
_snapshot_fail
step_7_5_match=0
grep -qE "Step [0-9]+: Anti-Pattern Scan" "$SKILL_MD" 2>/dev/null && step_7_5_match=1
assert_eq \
    "test_step_7_5_exists: SKILL.md documents Step 7.5" \
    "1" "$step_7_5_match"
assert_pass_if_clean "test_step_7_5_exists"
echo ""

# ── test_batch_dispatch ───────────────────────────────────────────────────────
# Step 7.5 must document that anti-pattern scans are dispatched in batches of
# at most 5 sub-agents (CLAUDE.md rule: never create more than 5 sub-agents at
# a time). SKILL.md must reference "batch" with a limit of 5.
_snapshot_fail
batch_match=0
grep -qiE "batch.{0,20}5|5.{0,20}batch|batches of.{0,10}5" "$SKILL_MD" 2>/dev/null && batch_match=1
assert_eq \
    "test_batch_dispatch: SKILL.md references batch limit of 5" \
    "1" "$batch_match"
assert_pass_if_clean "test_batch_dispatch"
echo ""

# ── test_commit_between_batches ───────────────────────────────────────────────
# SKILL.md must document that results are committed between anti-pattern scan
# batches to avoid losing work (CLAUDE.md rule: never launch new sub-agent
# batch without committing previous batch's results).
_snapshot_fail
commit_batch_match=0
grep -qiE "commit.{0,30}between.{0,30}batch|commit.{0,30}workflow.{0,30}batch|commit.{0,30}batch" "$SKILL_MD" 2>/dev/null && commit_batch_match=1
assert_eq \
    "test_commit_between_batches: SKILL.md documents committing between batches" \
    "1" "$commit_batch_match"
assert_pass_if_clean "test_commit_between_batches"
echo ""

# ── test_empty_scan_exit ──────────────────────────────────────────────────────
# When the anti-pattern scan finds zero candidates, Step 7.5 must document that
# the step exits immediately (no unnecessary sub-agent dispatch).
_snapshot_fail
empty_scan_match=0
grep -qiE "zero.{0,20}candidate|empty.{0,20}scan.{0,20}result|no.{0,20}candidate" "$SKILL_MD" 2>/dev/null && empty_scan_match=1
assert_eq \
    "test_empty_scan_exit: SKILL.md documents early exit on empty scan results" \
    "1" "$empty_scan_match"
assert_pass_if_clean "test_empty_scan_exit"
echo ""

# ── test_commit_precondition ──────────────────────────────────────────────────
# Step 8 (Commit and Close) must document that all GREEN tests must pass before
# committing — i.e., the commit pre-condition requires GREEN status.
_snapshot_fail
precondition_match=0
grep -qiE "pre.condition|GREEN.{0,20}before.{0,20}commit|commit.{0,20}pre.condition" "$SKILL_MD" 2>/dev/null && precondition_match=1
assert_eq \
    "test_commit_precondition: SKILL.md documents GREEN-before-commit pre-condition" \
    "1" "$precondition_match"
assert_pass_if_clean "test_commit_precondition"
echo ""

# ── test_observation_tracking ────────────────────────────────────────────────
# Step 7.5 must document observation tracking across fix-bug sessions to enable
# dogfooding insights — SKILL.md should reference "observation" in proximity to
# session tracking (e.g., "5 sessions" of dogfooding).
_snapshot_fail
observation_match=0
grep -qiE "observation.{0,40}(session|dogfood)|dogfood.{0,40}observation|(5|five).{0,20}session.{0,40}observation" "$SKILL_MD" 2>/dev/null && observation_match=1
assert_eq \
    "test_observation_tracking: SKILL.md documents observation tracking for dogfooding" \
    "1" "$observation_match"
assert_pass_if_clean "test_observation_tracking"
echo ""

print_summary
