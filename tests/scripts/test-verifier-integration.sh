#!/usr/bin/env bash
# tests/scripts/test-verifier-integration.sh
# Integration tests for plugins/dso/scripts/check-verifier-verdict.sh
# using REALISTIC completion-verifier output JSON blobs.
#
# Tests cover: schema_version=2 with P1=PASS, P1=FAIL, P1=BLOCKED,
# P1=INCONCLUSIVE, and legacy schema_version=1 (no P1 field) → exit 2.
#
# Usage: bash tests/scripts/test-verifier-integration.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# GREEN STATE: All tests pass because check-verifier-verdict.sh already
# exists (implemented in T2).
# testing-mode: GREEN

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/check-verifier-verdict.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-verifier-integration.sh ==="

# ── test_realistic_p1_pass_exits_0 ────────────────────────────────────────────
# Realistic verifier JSON with schema_version=2, P1=PASS, full criteria_results
# → check-verifier-verdict.sh must exit 0
test_realistic_p1_pass_exits_0() {
    _snapshot_fail
    local rc=0
    cat <<'EOF' | bash "$SCRIPT" 2>/dev/null || rc=$?
{
  "ticket_id": "f9de-b7d9-c23e-4f5b",
  "ticket_type": "story",
  "schema_version": 2,
  "P1": "PASS",
  "overall_verdict": "PASS",
  "criteria_results": [
    {
      "criterion": "check-verifier-verdict.sh exits 0 when P1=PASS",
      "verdict": "PASS",
      "evidence_sought": "Script file exists and is executable",
      "evidence_found": "plugins/dso/scripts/check-verifier-verdict.sh found, chmod +x confirmed"
    },
    {
      "criterion": "Script parses P1 field from completion-verifier JSON output",
      "verdict": "PASS",
      "evidence_sought": "python3 JSON parse logic in script body",
      "evidence_found": "python3 -c 'import json...' block found at line 47"
    }
  ],
  "consumer_smoke_tests": [
    {
      "consumer": "plugins/dso/skills/sprint/SKILL.md",
      "verification_command": "bash plugins/dso/scripts/check-verifier-verdict.sh tests/fixtures/sample-pass.json",
      "exit_code": 0,
      "verdict": "PASS",
      "output_excerpt": ""
    }
  ],
  "remediation_tasks_created": []
}
EOF
    assert_eq "test_realistic_p1_pass_exits_0: exit code is 0 for realistic P1=PASS blob" "0" "$rc"
    assert_pass_if_clean "test_realistic_p1_pass_exits_0"
}

# ── test_realistic_p1_fail_exits_1 ────────────────────────────────────────────
# Realistic verifier JSON with P1=FAIL, criteria_results containing FAIL verdicts
# → check-verifier-verdict.sh must exit 1
test_realistic_p1_fail_exits_1() {
    _snapshot_fail
    local rc=0
    cat <<'EOF' | bash "$SCRIPT" 2>/dev/null || rc=$?
{
  "ticket_id": "bbb5-1435-1983-4676",
  "ticket_type": "story",
  "schema_version": 2,
  "P1": "FAIL",
  "overall_verdict": "FAIL",
  "criteria_results": [
    {
      "criterion": "Integration test file exists at tests/scripts/test-verifier-integration.sh",
      "verdict": "FAIL",
      "evidence_sought": "File at tests/scripts/test-verifier-integration.sh",
      "evidence_found": "File not found — test has not been written yet"
    },
    {
      "criterion": "All 5 integration test cases exit with expected codes",
      "verdict": "FAIL",
      "evidence_sought": "bash tests/scripts/test-verifier-integration.sh output showing PASSED: 5",
      "evidence_found": "Script does not exist; cannot run"
    }
  ],
  "consumer_smoke_tests": [],
  "remediation_tasks_created": [
    {
      "title": "Write test-verifier-integration.sh with 5 realistic JSON test cases",
      "description": "Integration test file is missing. Must cover P1=PASS, FAIL, BLOCKED, INCONCLUSIVE, and legacy schema exit-2 cases with realistic completion-verifier output blobs.",
      "criterion": "Integration test file exists at tests/scripts/test-verifier-integration.sh"
    }
  ]
}
EOF
    assert_eq "test_realistic_p1_fail_exits_1: exit code is 1 for realistic P1=FAIL blob" "1" "$rc"
    assert_pass_if_clean "test_realistic_p1_fail_exits_1"
}

# ── test_realistic_p1_blocked_exits_1 ─────────────────────────────────────────
# Realistic verifier JSON with P1=BLOCKED (observable-behavior criterion blocked
# on live environment requirement) → check-verifier-verdict.sh must exit 1
test_realistic_p1_blocked_exits_1() {
    _snapshot_fail
    local rc=0
    cat <<'EOF' | bash "$SCRIPT" 2>/dev/null || rc=$?
{
  "ticket_id": "c23e-4f5b-1234-abcd",
  "ticket_type": "epic",
  "schema_version": 2,
  "P1": "BLOCKED",
  "overall_verdict": "BLOCKED",
  "criteria_results": [
    {
      "criterion": "SC1: Sprint orchestrator dispatches verifier sub-agent at story closure",
      "verdict": "PASS",
      "evidence_sought": "dso:completion-verifier dispatch call in sprint SKILL.md Phase G",
      "evidence_found": "Dispatch block found at plugins/dso/skills/sprint/SKILL.md line 412"
    },
    {
      "criterion": "SC2: End-to-end sprint run with live Claude Code session completes without error",
      "verdict": "FAIL",
      "evidence_sought": "Execution trace of full sprint run in interactive session",
      "evidence_found": "Execution required but not performed — cannot verify without live run (observable-behavior criterion)"
    }
  ],
  "consumer_smoke_tests": [
    {
      "consumer": "plugins/dso/skills/sprint/SKILL.md",
      "verification_command": ".claude/scripts/dso ticket list-epics --help 2>&1",
      "exit_code": 0,
      "verdict": "PASS",
      "output_excerpt": "Usage: dso ticket list-epics [--all] [--has-tag=TAG]"
    }
  ],
  "remediation_tasks_created": [
    {
      "title": "Obtain execution trace for SC2 observable-behavior criterion",
      "description": "SC2 requires a live interactive session run. Schedule an end-to-end sprint smoke test with a human operator to capture the trace.",
      "criterion": "SC2: End-to-end sprint run with live Claude Code session"
    }
  ]
}
EOF
    assert_eq "test_realistic_p1_blocked_exits_1: exit code is 1 for realistic P1=BLOCKED blob" "1" "$rc"
    assert_pass_if_clean "test_realistic_p1_blocked_exits_1"
}

# ── test_realistic_p1_inconclusive_exits_1 ────────────────────────────────────
# Realistic verifier JSON with schema_version=2 and P1=INCONCLUSIVE
# → check-verifier-verdict.sh must exit 1
test_realistic_p1_inconclusive_exits_1() {
    _snapshot_fail
    local rc=0
    cat <<'EOF' | bash "$SCRIPT" 2>/dev/null || rc=$?
{
  "ticket_id": "1851-b416-0c5e-44c2",
  "ticket_type": "task",
  "schema_version": 2,
  "P1": "INCONCLUSIVE",
  "overall_verdict": "INCONCLUSIVE",
  "criteria_results": [
    {
      "criterion": "DD1: check-verifier-verdict.sh exits 0 for P1=PASS",
      "verdict": "PASS",
      "evidence_sought": "Script exists and exit-0 behavior confirmed",
      "evidence_found": "Script at plugins/dso/scripts/check-verifier-verdict.sh, bash test exits 0"
    },
    {
      "criterion": "DD2: SC9 coverage gate reports >= 100 preventions",
      "verdict": "PENDING",
      "evidence_sought": "Output of preconditions-coverage-harness --dry-run --output json",
      "evidence_found": "Script exited 127 (not found) — coverage harness not yet available in this worktree"
    }
  ],
  "consumer_smoke_tests": [
    {
      "consumer": "plugins/dso/hooks/post-commit",
      "verification_command": "bash plugins/dso/hooks/post-commit --dry-run 2>&1 | head -3",
      "exit_code": 0,
      "verdict": "PASS",
      "output_excerpt": "post-commit: dry-run mode, skipping artifact verification"
    }
  ],
  "remediation_tasks_created": [
    {
      "title": "Install preconditions-coverage-harness before epic closure",
      "description": "SC9 coverage gate could not be evaluated because the harness script was not found (exit 127). Must be available before final epic closure.",
      "criterion": "DD2: SC9 coverage gate reports >= 100 preventions"
    }
  ]
}
EOF
    assert_eq "test_realistic_p1_inconclusive_exits_1: exit code is 1 for realistic P1=INCONCLUSIVE blob" "1" "$rc"
    assert_pass_if_clean "test_realistic_p1_inconclusive_exits_1"
}

# ── test_legacy_schema_no_p1_exits_2 ──────────────────────────────────────────
# Realistic verifier JSON using OLD schema (schema_version absent/1, no P1 field)
# with only overall_verdict → check-verifier-verdict.sh must exit 2 (P1 absent)
test_legacy_schema_no_p1_exits_2() {
    _snapshot_fail
    local rc=0
    cat <<'EOF' | bash "$SCRIPT" 2>/dev/null || rc=$?
{
  "ticket_id": "dead-beef-0000-0001",
  "ticket_type": "story",
  "overall_verdict": "PASS",
  "criteria_results": [
    {
      "criterion": "DD1: Script exits 0 for PASS verdict",
      "verdict": "PASS",
      "evidence_sought": "Script file at plugins/dso/scripts/check-verifier-verdict.sh",
      "evidence_found": "File found and executable"
    },
    {
      "criterion": "DD2: Script exits 1 for FAIL verdict",
      "verdict": "PASS",
      "evidence_sought": "FAIL branch in case statement",
      "evidence_found": "FAIL|BLOCKED|INCONCLUSIVE branch exits 1 at line 71"
    }
  ],
  "consumer_smoke_tests": [],
  "remediation_tasks_created": []
}
EOF
    assert_eq "test_legacy_schema_no_p1_exits_2: exit code is 2 for legacy schema (no P1 field)" "2" "$rc"
    assert_pass_if_clean "test_legacy_schema_no_p1_exits_2"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
test_realistic_p1_pass_exits_0
test_realistic_p1_fail_exits_1
test_realistic_p1_blocked_exits_1
test_realistic_p1_inconclusive_exits_1
test_legacy_schema_no_p1_exits_2

print_summary
