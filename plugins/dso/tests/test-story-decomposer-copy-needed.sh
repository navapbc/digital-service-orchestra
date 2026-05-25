#!/usr/bin/env bash
# tests/test-story-decomposer-copy-needed.sh
# Behavioral tests for copy-needed tag detection and copy story auto-create
# logic in the story-decomposer agent.
#
# Covers story 0868-ea33-67d0-4f37, task 8517-d221-fe30-4fd8.
# DDs tested:
#   dd-1 (0868): copy-needed tag + populated ## Copy Needs section → exactly one
#                copy story child attached to the epic
#   dd-2 (0868): copy story description references epic Copy Needs stable_ids
#                and gates closure on schema-conforming artifact path
#   dd-3 (0868): epic WITHOUT copy-needed tag → no copy story auto-created
#   dd-4 (0868): re-running on same epic does not create duplicate copy story
#
# Test plan:
#   test_positive        — agent prompt documents copy-needed detection and
#                          auto-create of exactly one copy story
#   test_negative        — agent prompt documents no-op when tag absent
#   test_idempotent      — agent prompt documents idempotency guard (no duplicate)
#   test_coordination    — agent prompt documents coordination-pass DD when
#                          distinct(page) > 1
#   test_stable_ids      — agent prompt documents stable_id reference in copy story
#   test_artifact_gate   — agent prompt documents artifact path gate in DDs
#   test_copy_story_tag  — agent prompt documents copy-story tag for idempotency
#   test_schema_error    — agent prompt documents schema-validation halt on parse error
#   test_rules_copy      — Rules section documents copy-needed enforcement
#   test_rules_idempotent — Rules section documents idempotency rule
#   test_rules_no_tag    — Rules section documents no-copy-story when tag absent

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

AGENT_FILE="$_PLUGIN_ROOT/agents/story-decomposer.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== story-decomposer copy-needed behavioral tests ==="

# ---------------------------------------------------------------------------
# test_positive: copy-needed tag detection and copy story auto-create
# ---------------------------------------------------------------------------
run_test_positive() {
  echo ""
  echo "--- test_positive: copy-needed tag detection + copy story auto-create ---"

  if grep -q 'copy-needed' "$AGENT_FILE"; then
    pass "Agent file documents 'copy-needed' tag"
  else
    fail "Agent file does NOT mention 'copy-needed' tag"
  fi

  if grep -qE 'Apply gov-copy to' "$AGENT_FILE"; then
    pass "Agent file documents copy story title template 'Apply gov-copy to <epic-title>'"
  else
    fail "Agent file does NOT document copy story title template"
  fi

  if grep -qE 'draft-copy' "$AGENT_FILE"; then
    pass "Agent file documents 'draft-copy' temp_id for auto-created copy story"
  else
    fail "Agent file does NOT document draft-copy temp_id"
  fi

  if grep -qE 'exactly one' "$AGENT_FILE"; then
    pass "Agent file documents that exactly one copy story is produced"
  else
    fail "Agent file does NOT assert exactly one copy story"
  fi
}

# ---------------------------------------------------------------------------
# test_negative: no copy story when epic lacks copy-needed tag
# ---------------------------------------------------------------------------
run_test_negative() {
  echo ""
  echo "--- test_negative: no copy story when tag absent ---"

  if grep -qE 'does NOT carry.*copy-needed|NOT carry.*copy-needed' "$AGENT_FILE"; then
    pass "Agent file documents no-op behavior when epic lacks copy-needed tag"
  else
    fail "Agent file does NOT document behavior when copy-needed tag is absent"
  fi

  if grep -qE 'skip this section entirely|do NOT produce a copy story' "$AGENT_FILE"; then
    pass "Agent file instructs: skip copy protocol when tag absent"
  else
    fail "Agent file does NOT instruct skip when tag absent"
  fi
}

# ---------------------------------------------------------------------------
# test_idempotent: idempotency guard — no duplicate copy story on re-run
# ---------------------------------------------------------------------------
run_test_idempotent() {
  echo ""
  echo "--- test_idempotent: idempotency guard (no duplicate on re-run) ---"

  if grep -qiE 'idempoten' "$AGENT_FILE"; then
    pass "Agent file documents idempotency"
  else
    fail "Agent file does NOT mention idempotency"
  fi

  if grep -qE 'duplicate' "$AGENT_FILE"; then
    pass "Agent file documents duplicate prevention"
  else
    fail "Agent file does NOT mention duplicate prevention"
  fi

  if grep -qE 'copy-story.*tag|tag.*copy-story' "$AGENT_FILE"; then
    pass "Agent file documents 'copy-story' tag as idempotency detection mechanism"
  else
    fail "Agent file does NOT document 'copy-story' tag for idempotency detection"
  fi

  if grep -qE "idempotency guard triggered|duplicate created" "$AGENT_FILE"; then
    pass "Agent file documents idempotency guard note in decomposition_notes"
  else
    fail "Agent file does NOT document idempotency guard note text"
  fi
}

# ---------------------------------------------------------------------------
# test_coordination: coordination-pass DD when distinct(page) > 1
# ---------------------------------------------------------------------------
run_test_coordination() {
  echo ""
  echo "--- test_coordination: coordination-pass DD when distinct(page) > 1 ---"

  if grep -qE 'distinct.*page.*>.*1|distinct\(page\).*>.*1' "$AGENT_FILE"; then
    pass "Agent file documents distinct(page) > 1 condition for coordination-pass"
  else
    fail "Agent file does NOT document distinct(page) > 1 condition"
  fi

  if grep -qE 'coordination-pass' "$AGENT_FILE"; then
    pass "Agent file documents coordination-pass requirement"
  else
    fail "Agent file does NOT document coordination-pass"
  fi

  if grep -qE 'cross-page consistency|cross.page consistency' "$AGENT_FILE"; then
    pass "Agent file documents cross-page consistency goal of coordination-pass"
  else
    fail "Agent file does NOT document cross-page consistency in coordination-pass"
  fi
}

# ---------------------------------------------------------------------------
# test_stable_ids: copy story description references Copy Needs stable_ids
# ---------------------------------------------------------------------------
run_test_stable_ids() {
  echo ""
  echo "--- test_stable_ids: copy story references Copy Needs stable_ids ---"

  if grep -qE 'stable_id' "$AGENT_FILE"; then
    pass "Agent file references stable_id field"
  else
    fail "Agent file does NOT reference stable_id"
  fi

  if grep -qE 'copy_stable_ids' "$AGENT_FILE"; then
    pass "Agent file documents 'copy_stable_ids' collection variable"
  else
    fail "Agent file does NOT document copy_stable_ids variable"
  fi

  if grep -qE 'stable.ids.*description|description.*stable.ids|Scope.*stable_id' "$AGENT_FILE"; then
    pass "Agent file documents stable_ids referenced in copy story description/scope"
  else
    fail "Agent file does NOT document stable_ids in copy story description"
  fi
}

# ---------------------------------------------------------------------------
# test_artifact_gate: copy story DDs gate closure on artifact path
# ---------------------------------------------------------------------------
run_test_artifact_gate() {
  echo ""
  echo "--- test_artifact_gate: copy story gates on artifact at copy.artifact_dir/<epic-id>.yaml ---"

  if grep -qE 'copy\.artifact_dir' "$AGENT_FILE"; then
    pass "Agent file references copy.artifact_dir config key"
  else
    fail "Agent file does NOT reference copy.artifact_dir"
  fi

  if grep -qE '<epic-id>\.yaml' "$AGENT_FILE"; then
    pass "Agent file documents artifact path pattern <copy.artifact_dir>/<epic-id>.yaml"
  else
    fail "Agent file does NOT document artifact path pattern"
  fi

  if grep -qE 'schema-conforming artifact' "$AGENT_FILE"; then
    pass "Agent file documents 'schema-conforming artifact' gate in DDs"
  else
    fail "Agent file does NOT document schema-conforming artifact gate"
  fi
}

# ---------------------------------------------------------------------------
# test_copy_story_tag: copy story is tagged 'copy-story' for future idempotency
# ---------------------------------------------------------------------------
run_test_copy_story_tag() {
  echo ""
  echo "--- test_copy_story_tag: copy story produced with 'copy-story' tag ---"

  if grep -qE '"tags".*copy-story|copy-story.*tag' "$AGENT_FILE"; then
    pass "Agent file documents 'copy-story' tag on produced draft"
  else
    fail "Agent file does NOT document 'copy-story' tag on produced draft"
  fi
}

# ---------------------------------------------------------------------------
# test_schema_error: agent halts with error when Copy Needs section is malformed
# ---------------------------------------------------------------------------
run_test_schema_error() {
  echo ""
  echo "--- test_schema_error: halt on malformed Copy Needs (missing schema_version) ---"

  if grep -qE 'MISSING_SCHEMA_VERSION' "$AGENT_FILE"; then
    pass "Agent file documents MISSING_SCHEMA_VERSION error code"
  else
    fail "Agent file does NOT document MISSING_SCHEMA_VERSION error"
  fi

  if grep -qE 'MISSING_REQUIRED_FIELD' "$AGENT_FILE"; then
    pass "Agent file documents MISSING_REQUIRED_FIELD error code"
  else
    fail "Agent file does NOT document MISSING_REQUIRED_FIELD error"
  fi

  if grep -qE 'copy_needs_schema_invalid' "$AGENT_FILE"; then
    pass "Agent file documents copy_needs_schema_invalid halt behavior"
  else
    fail "Agent file does NOT document copy_needs_schema_invalid halt"
  fi
}

# ---------------------------------------------------------------------------
# test_rules_copy: Rules section documents copy-needed enforcement
# ---------------------------------------------------------------------------
run_test_rules_copy() {
  echo ""
  echo "--- test_rules_copy: Rules section documents copy-needed enforcement ---"

  if grep -qE 'copy-needed tag.*Copy-Needed Auto-Create Protocol|Copy-Needed Auto-Create Protocol.*copy-needed tag' "$AGENT_FILE"; then
    pass "Rules section references copy-needed tag and Copy-Needed Auto-Create Protocol"
  else
    fail "Rules section does NOT reference copy-needed enforcement"
  fi
}

# ---------------------------------------------------------------------------
# test_rules_idempotent: Rules section documents idempotency rule
# ---------------------------------------------------------------------------
run_test_rules_idempotent() {
  echo ""
  echo "--- test_rules_idempotent: Rules section documents idempotency ---"

  if grep -qE '\*\*Idempotency\*\*|Idempotency.*Never produce a duplicate' "$AGENT_FILE"; then
    pass "Rules section documents Idempotency rule"
  else
    fail "Rules section does NOT document Idempotency rule"
  fi
}

# ---------------------------------------------------------------------------
# test_rules_no_tag: Rules section documents no copy story when tag absent
# ---------------------------------------------------------------------------
run_test_rules_no_tag() {
  echo ""
  echo "--- test_rules_no_tag: Rules section documents no copy story when tag absent ---"

  if grep -qE 'Absent copy-needed tag|does NOT carry.*copy-needed' "$AGENT_FILE"; then
    pass "Rules section documents no copy story when tag absent"
  else
    fail "Rules section does NOT document no-op when tag absent"
  fi
}

# ---------------------------------------------------------------------------
# test_multi_page_coordination_task: multi-page → coordination-pass task child
# Covers dd-1 (c5ef): coordination-pass task attached when distinct(page) > 1
# ---------------------------------------------------------------------------
run_test_multi_page_coordination_task() {
  echo ""
  echo "--- test_multi_page_coordination_task: multi-page → coordination-pass task present ---"

  # Step C3 must instruct the agent to add a child_tasks entry when distinct(page) > 1
  if grep -qE 'child_tasks' "$AGENT_FILE"; then
    pass "Agent file documents child_tasks field for coordination-pass task"
  else
    fail "Agent file does NOT document child_tasks field for coordination-pass task"
  fi

  # The coordination-pass task DD must mention the artifact path contract
  if grep -qE 'coordination-pass dispatch produces an updated artifact' "$AGENT_FILE"; then
    pass "Agent file documents coordination-pass task DD: 'dispatch produces an updated artifact'"
  else
    fail "Agent file does NOT document coordination-pass task DD with artifact dispatch text"
  fi

  # The DD must mention hard-constraint immutability
  if grep -qE 'hard-constraint items remain immutable' "$AGENT_FILE"; then
    pass "Agent file documents hard-constraint immutability in coordination-pass task DD"
  else
    fail "Agent file does NOT document hard-constraint immutability in coordination-pass task DD"
  fi

  # The DD must mention cross-page voice consistency
  if grep -qE 'cross-page voice is consistent' "$AGENT_FILE"; then
    pass "Agent file documents cross-page voice consistency in coordination-pass task DD"
  else
    fail "Agent file does NOT document cross-page voice consistency in coordination-pass task DD"
  fi

  # When distinct(page) == 1, the child_tasks coordination-pass task must NOT be added
  if grep -qE 'distinct.*page.*==.*1|single.page.*no coordination|distinct.*page.*1.*no.*child_task' "$AGENT_FILE"; then
    pass "Agent file documents no coordination-pass child task when distinct(page) == 1"
  else
    fail "Agent file does NOT explicitly document single-page exclusion for coordination-pass child task"
  fi
}

# ---------------------------------------------------------------------------
# test_single_page_no_coordination_task: single-page → no coordination-pass task
# Covers dd-2 (c5ef): no coordination-pass task when distinct(page) == 1
# ---------------------------------------------------------------------------
run_test_single_page_no_coordination_task() {
  echo ""
  echo "--- test_single_page_no_coordination_task: single-page → no coordination-pass task ---"

  # Must explicitly state the single-page exclusion for the child task
  if grep -qE 'distinct.*page.*==.*1.*no.*child_task|single.*page.*omit.*coordination|When distinct.*page.*==.*1.*no coordination-pass task' "$AGENT_FILE"; then
    pass "Agent file explicitly excludes coordination-pass child task when distinct(page) == 1"
  else
    fail "Agent file does NOT explicitly exclude coordination-pass task for single-page case"
  fi
}

# ---------------------------------------------------------------------------
# test_hard_constraint_immutability: coordination-pass spec mentions hard-constraint
# Covers: hard-constraint items remain immutable in the coordination-pass task DD
# ---------------------------------------------------------------------------
run_test_hard_constraint_immutability() {
  echo ""
  echo "--- test_hard_constraint_immutability: hard-constraint immutability in coordination-pass spec ---"

  if grep -qE 'hard-constraint items remain immutable' "$AGENT_FILE"; then
    pass "Agent file coordination-pass task DD includes hard-constraint immutability language"
  else
    fail "Agent file coordination-pass task DD does NOT include hard-constraint immutability language"
  fi

  # The artifact path pattern must be present in the coordination-pass task DD
  if grep -qE 'copy\.artifact_dir.*epic-id.*yaml|<copy\.artifact_dir>/<epic-id>\.yaml' "$AGENT_FILE"; then
    pass "Agent file coordination-pass task DD references artifact path <copy.artifact_dir>/<epic-id>.yaml"
  else
    fail "Agent file coordination-pass task DD does NOT reference correct artifact path"
  fi
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

# Verify agent file exists first
if [[ ! -f "$AGENT_FILE" ]]; then
  echo "FATAL: agent file not found at $AGENT_FILE"
  exit 1
fi

# Run all tests or a specific test if passed as argument
TARGET="${1:-all}"

case "$TARGET" in
  test_positive)    run_test_positive ;;
  test_negative)    run_test_negative ;;
  test_idempotent)  run_test_idempotent ;;
  test_coordination) run_test_coordination ;;
  test_stable_ids)  run_test_stable_ids ;;
  test_artifact_gate) run_test_artifact_gate ;;
  test_copy_story_tag) run_test_copy_story_tag ;;
  test_schema_error) run_test_schema_error ;;
  test_rules_copy)  run_test_rules_copy ;;
  test_rules_idempotent) run_test_rules_idempotent ;;
  test_rules_no_tag) run_test_rules_no_tag ;;
  test_multi_page_coordination_task) run_test_multi_page_coordination_task ;;
  test_single_page_no_coordination_task) run_test_single_page_no_coordination_task ;;
  test_hard_constraint_immutability) run_test_hard_constraint_immutability ;;
  all)
    run_test_positive
    run_test_negative
    run_test_idempotent
    run_test_coordination
    run_test_stable_ids
    run_test_artifact_gate
    run_test_copy_story_tag
    run_test_schema_error
    run_test_rules_copy
    run_test_rules_idempotent
    run_test_rules_no_tag
    run_test_multi_page_coordination_task
    run_test_single_page_no_coordination_task
    run_test_hard_constraint_immutability
    ;;
  *)
    echo "Unknown test target: $TARGET"
    echo "Valid targets: test_positive test_negative test_idempotent test_coordination test_stable_ids test_artifact_gate test_copy_story_tag test_schema_error test_rules_copy test_rules_idempotent test_rules_no_tag test_multi_page_coordination_task test_single_page_no_coordination_task test_hard_constraint_immutability all"
    exit 1
    ;;
esac

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
