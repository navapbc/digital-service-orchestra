#!/usr/bin/env bash
# tests/hooks/test-validate-review-output.sh
# Tests for scripts/validate-review-output.sh
#
# validate-review-output.sh validates review agent output against expected
# schemas for prompt IDs: code-review-dispatch, review-protocol, plan-review.
# Supports --list, --list-callers, and --caller flags.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$DSO_PLUGIN_DIR/scripts/validate-review-output.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Temporary directory for test fixture files
TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Helper: run the script with given args
# Usage: run_script [args...]
# Returns exit code (stdout from script is suppressed)
run_script() {
    local exit_code=0
    bash "$SCRIPT" "$@" >/dev/null 2>&1 || exit_code=$?
    echo "$exit_code"
}

# Helper: run the script and capture stdout
# Returns stdout output; caller should also check exit code separately
run_script_output() {
    bash "$SCRIPT" "$@" 2>/dev/null
}

# Helper: write a temp fixture file and return its path
write_fixture() {
    local name="$1"
    local content="$2"
    local path="$TMP_DIR/$name"
    printf '%s' "$content" > "$path"
    echo "$path"
}

# ============================================================
# 1. Script existence and executability
# ============================================================

assert_eq \
    "test_script_exists_in_plugin: validate-review-output.sh is present in scripts/" \
    "yes" \
    "$(test -f "$SCRIPT" && echo yes || echo no)"

assert_eq \
    "test_script_is_executable: validate-review-output.sh is executable" \
    "yes" \
    "$(test -x "$SCRIPT" && echo yes || echo no)"

# ============================================================
# 2. --list and --list-callers flags
# ============================================================

LIST_OUTPUT=$(run_script_output --list 2>/dev/null)

assert_contains \
    "test_list_shows_code_review_dispatch: --list includes code-review-dispatch" \
    "code-review-dispatch" \
    "$LIST_OUTPUT"

assert_contains \
    "test_list_shows_review_protocol: --list includes review-protocol" \
    "review-protocol" \
    "$LIST_OUTPUT"

assert_contains \
    "test_list_shows_plan_review: --list includes plan-review" \
    "plan-review" \
    "$LIST_OUTPUT"

LIST_EXIT=$(run_script --list)
assert_eq \
    "test_list_exits_zero: --list exits 0" \
    "0" \
    "$LIST_EXIT"

CALLERS_OUTPUT=$(run_script_output --list-callers 2>/dev/null)

assert_contains \
    "test_list_callers_shows_roadmap: --list-callers includes roadmap" \
    "roadmap" \
    "$CALLERS_OUTPUT"

assert_contains \
    "test_list_callers_shows_implementation_plan: --list-callers includes implementation-plan" \
    "implementation-plan" \
    "$CALLERS_OUTPUT"

assert_contains \
    "test_list_callers_shows_ui_designer: --list-callers includes ui-designer" \
    "ui-designer" \
    "$CALLERS_OUTPUT"

assert_contains \
    "test_list_callers_shows_retro: --list-callers includes retro" \
    "retro" \
    "$CALLERS_OUTPUT"

assert_contains \
    "test_list_callers_shows_dev_onboarding: --list-callers includes dev-onboarding" \
    "dev-onboarding" \
    "$CALLERS_OUTPUT"

assert_contains \
    "test_list_callers_shows_architect_foundation: --list-callers includes architect-foundation" \
    "architect-foundation" \
    "$CALLERS_OUTPUT"

assert_contains \
    "test_list_callers_shows_preplanning: --list-callers includes preplanning" \
    "preplanning" \
    "$CALLERS_OUTPUT"

assert_contains \
    "test_list_callers_shows_ui_designer: --list-callers includes ui-designer" \
    "ui-designer" \
    "$CALLERS_OUTPUT"

CALLERS_EXIT=$(run_script --list-callers)
assert_eq \
    "test_list_callers_exits_zero: --list-callers exits 0" \
    "0" \
    "$CALLERS_EXIT"

# ============================================================
# 3. Error handling: missing/malformed input
# ============================================================

# No arguments → exit 2
NO_ARGS_EXIT=$(run_script)
assert_ne \
    "test_no_args_exits_nonzero: no args exits non-zero" \
    "0" \
    "$NO_ARGS_EXIT"

# Only prompt-id, no file → exit 2
ONE_ARG_EXIT=$(run_script code-review-dispatch)
assert_ne \
    "test_one_arg_exits_nonzero: only prompt-id, no file arg exits non-zero" \
    "0" \
    "$ONE_ARG_EXIT"

# Unknown prompt-id → exit 2
UNKNOWN_PROMPT_EXIT=$(run_script unknown-prompt-id /dev/null)
assert_ne \
    "test_unknown_prompt_id_exits_nonzero: unknown prompt-id exits non-zero" \
    "0" \
    "$UNKNOWN_PROMPT_EXIT"

# File does not exist → exit 1
MISSING_FILE_EXIT=$(run_script code-review-dispatch /nonexistent/file.json)
assert_ne \
    "test_missing_file_exits_nonzero: non-existent output file exits non-zero" \
    "0" \
    "$MISSING_FILE_EXIT"

# Empty file → exit 1
EMPTY_FILE=$(write_fixture "empty.json" "")
EMPTY_FILE_EXIT=$(run_script code-review-dispatch "$EMPTY_FILE")
assert_ne \
    "test_empty_file_exits_nonzero: empty output file exits non-zero" \
    "0" \
    "$EMPTY_FILE_EXIT"

# Malformed JSON → exit 1
BAD_JSON_FILE=$(write_fixture "bad.json" "not valid json {{{{")
BAD_JSON_EXIT=$(run_script code-review-dispatch "$BAD_JSON_FILE")
assert_ne \
    "test_malformed_json_exits_nonzero: malformed JSON exits non-zero" \
    "0" \
    "$BAD_JSON_EXIT"

# --caller used with non-review-protocol prompt → exit 2
CALLER_WRONG_PROMPT_EXIT=$(run_script code-review-dispatch "$BAD_JSON_FILE" --caller roadmap)
assert_ne \
    "test_caller_with_wrong_prompt_exits_nonzero: --caller only valid with review-protocol" \
    "0" \
    "$CALLER_WRONG_PROMPT_EXIT"

# Unknown caller-id → exit 2
BASE_RP_FILE=$(write_fixture "rp-base.json" '{
  "subject": "Test subject",
  "reviews": [
    {
      "perspective": "Test Perspective",
      "status": "reviewed",
      "dimensions": {"dim1": 4},
      "findings": []
    }
  ],
  "conflicts": []
}')
UNKNOWN_CALLER_EXIT=$(run_script review-protocol "$BASE_RP_FILE" --caller unknown-caller-id)
assert_ne \
    "test_unknown_caller_id_exits_nonzero: unknown caller-id exits non-zero" \
    "0" \
    "$UNKNOWN_CALLER_EXIT"

# ============================================================
# 4. code-review-dispatch: valid JSON passes
# ============================================================

VALID_CRD_FILE=$(write_fixture "valid-crd.json" '{
  "scores": {
    "hygiene": 5,
    "design": 5,
    "maintainability": 5,
    "correctness": 5,
    "verification": 5
  },
  "findings": [],
  "summary": "Code is well-structured and tests are adequate."
}')

VALID_CRD_EXIT=$(run_script code-review-dispatch "$VALID_CRD_FILE")
assert_eq \
    "test_code_review_dispatch_valid_passes: valid code-review-dispatch JSON exits 0" \
    "0" \
    "$VALID_CRD_EXIT"

VALID_CRD_OUTPUT=$(run_script_output code-review-dispatch "$VALID_CRD_FILE")
assert_contains \
    "test_code_review_dispatch_valid_schema_valid_yes: output contains SCHEMA_VALID: yes" \
    "SCHEMA_VALID: yes" \
    "$VALID_CRD_OUTPUT"

# code-review-dispatch: valid with N/A scores and findings
VALID_CRD_WITH_FINDINGS=$(write_fixture "valid-crd-findings.json" '{
  "scores": {
    "hygiene": 1,
    "design": 5,
    "maintainability": 5,
    "correctness": 5,
    "verification": "N/A"
  },
  "findings": [
    {
      "severity": "critical",
      "category": "hygiene",
      "description": "Syntax error in module",
      "file": "app/src/broken.py"
    }
  ],
  "summary": "Critical build failure requires immediate attention."
}')

VALID_CRD_FINDINGS_EXIT=$(run_script code-review-dispatch "$VALID_CRD_WITH_FINDINGS")
assert_eq \
    "test_code_review_dispatch_with_findings_passes: code-review-dispatch with findings exits 0" \
    "0" \
    "$VALID_CRD_FINDINGS_EXIT"

# ============================================================
# 5. code-review-dispatch: invalid JSON fails
# ============================================================

# Missing required top-level key 'summary'
MISSING_SUMMARY_FILE=$(write_fixture "missing-summary.json" '{
  "scores": {
    "hygiene": 5,
    "design": 5,
    "maintainability": 5,
    "correctness": 5,
    "verification": 5
  },
  "findings": []
}')
MISSING_SUMMARY_EXIT=$(run_script code-review-dispatch "$MISSING_SUMMARY_FILE")
assert_ne \
    "test_code_review_dispatch_missing_summary_fails: missing summary exits non-zero" \
    "0" \
    "$MISSING_SUMMARY_EXIT"

# Missing required score dimension
MISSING_DIM_FILE=$(write_fixture "missing-dim.json" '{
  "scores": {
    "hygiene": 5,
    "maintainability": 5,
    "correctness": 5,
    "verification": 5
  },
  "findings": [],
  "summary": "A sufficiently long summary string here."
}')
MISSING_DIM_EXIT=$(run_script code-review-dispatch "$MISSING_DIM_FILE")
assert_ne \
    "test_code_review_dispatch_missing_dimension_fails: missing score dimension exits non-zero" \
    "0" \
    "$MISSING_DIM_EXIT"

# Score out of valid range (1-5)
OUT_OF_RANGE_FILE=$(write_fixture "out-of-range.json" '{
  "scores": {
    "hygiene": 6,
    "design": 5,
    "maintainability": 5,
    "correctness": 5,
    "verification": 5
  },
  "findings": [],
  "summary": "A sufficiently long summary string here."
}')
OUT_OF_RANGE_EXIT=$(run_script code-review-dispatch "$OUT_OF_RANGE_FILE")
assert_ne \
    "test_code_review_dispatch_score_out_of_range_fails: score out of range exits non-zero" \
    "0" \
    "$OUT_OF_RANGE_EXIT"

# Unexpected extra top-level key
EXTRA_KEY_FILE=$(write_fixture "extra-key.json" '{
  "scores": {
    "hygiene": 5,
    "design": 5,
    "maintainability": 5,
    "correctness": 5,
    "verification": 5
  },
  "findings": [],
  "summary": "A sufficiently long summary string here.",
  "unexpected_key": "not allowed"
}')
EXTRA_KEY_EXIT=$(run_script code-review-dispatch "$EXTRA_KEY_FILE")
assert_ne \
    "test_code_review_dispatch_extra_key_fails: unexpected extra key exits non-zero" \
    "0" \
    "$EXTRA_KEY_EXIT"

# ============================================================
# 6. plan-review: valid structured text passes
# ============================================================

VALID_PLAN_REVIEW=$(write_fixture "valid-plan-review.txt" 'VERDICT: PASS

SCORES:
  - feasibility: 4/5
  - completeness: 4/5
  - yagni: 5/5
  - codebase_alignment: 4/5

FINDINGS:
No critical issues found.

SUGGESTION: None required.
')

VALID_PLAN_EXIT=$(run_script plan-review "$VALID_PLAN_REVIEW")
assert_eq \
    "test_plan_review_valid_passes: valid plan-review structured text exits 0" \
    "0" \
    "$VALID_PLAN_EXIT"

VALID_PLAN_OUTPUT=$(run_script_output plan-review "$VALID_PLAN_REVIEW")
assert_contains \
    "test_plan_review_valid_schema_valid_yes: plan-review output contains SCHEMA_VALID: yes" \
    "SCHEMA_VALID: yes" \
    "$VALID_PLAN_OUTPUT"

# plan-review with REVISE verdict and findings
VALID_PLAN_REVISE=$(write_fixture "valid-plan-revise.txt" 'VERDICT: REVISE

SCORES:
  - feasibility: 2/5
  - completeness: 3/5
  - yagni: 4/5
  - codebase_alignment: 3/5

FINDINGS:
FINDING: [feasibility] [severity: critical]
The approach relies on unproven technology choices.
SUGGESTION: Consider using existing stable libraries instead.
')

VALID_PLAN_REVISE_EXIT=$(run_script plan-review "$VALID_PLAN_REVISE")
assert_eq \
    "test_plan_review_revise_with_findings_passes: plan-review REVISE with FINDING exits 0" \
    "0" \
    "$VALID_PLAN_REVISE_EXIT"

# ============================================================
# 7. plan-review: invalid structured text fails
# ============================================================

# Missing VERDICT line
MISSING_VERDICT=$(write_fixture "missing-verdict.txt" 'SCORES:
  - feasibility: 4/5
  - completeness: 4/5
  - yagni: 5/5
  - codebase_alignment: 4/5

FINDINGS:
No issues.
')
MISSING_VERDICT_EXIT=$(run_script plan-review "$MISSING_VERDICT")
assert_ne \
    "test_plan_review_missing_verdict_fails: missing VERDICT: line exits non-zero" \
    "0" \
    "$MISSING_VERDICT_EXIT"

# Invalid VERDICT value
INVALID_VERDICT=$(write_fixture "invalid-verdict.txt" 'VERDICT: MAYBE

SCORES:
  - feasibility: 4/5
  - completeness: 4/5
  - yagni: 5/5
  - codebase_alignment: 4/5

FINDINGS:
No issues.
')
INVALID_VERDICT_EXIT=$(run_script plan-review "$INVALID_VERDICT")
assert_ne \
    "test_plan_review_invalid_verdict_fails: invalid VERDICT value exits non-zero" \
    "0" \
    "$INVALID_VERDICT_EXIT"

# Missing SCORES section
MISSING_SCORES=$(write_fixture "missing-scores.txt" 'VERDICT: PASS

FINDINGS:
No issues.
')
MISSING_SCORES_EXIT=$(run_script plan-review "$MISSING_SCORES")
assert_ne \
    "test_plan_review_missing_scores_fails: missing SCORES: section exits non-zero" \
    "0" \
    "$MISSING_SCORES_EXIT"

# Missing FINDINGS section
MISSING_FINDINGS=$(write_fixture "missing-findings.txt" 'VERDICT: PASS

SCORES:
  - feasibility: 4/5
  - completeness: 4/5
  - yagni: 5/5
  - codebase_alignment: 4/5
')
MISSING_FINDINGS_EXIT=$(run_script plan-review "$MISSING_FINDINGS")
assert_ne \
    "test_plan_review_missing_findings_fails: missing FINDINGS: section exits non-zero" \
    "0" \
    "$MISSING_FINDINGS_EXIT"

# ============================================================
# 8. review-protocol: valid base schema passes
# ============================================================

VALID_RP_FILE=$(write_fixture "valid-rp.json" '{
  "subject": "PR #42: Add caching layer",
  "reviews": [
    {
      "perspective": "Architecture",
      "status": "reviewed",
      "dimensions": {
        "scalability": 4,
        "maintainability": 3
      },
      "findings": [
        {
          "dimension": "maintainability",
          "severity": "minor",
          "description": "Consider extracting cache logic into a separate module.",
          "suggestion": "Move cache operations to app/src/cache.py"
        }
      ]
    }
  ],
  "conflicts": []
}')

VALID_RP_EXIT=$(run_script review-protocol "$VALID_RP_FILE")
assert_eq \
    "test_review_protocol_valid_passes: valid review-protocol JSON exits 0" \
    "0" \
    "$VALID_RP_EXIT"

VALID_RP_OUTPUT=$(run_script_output review-protocol "$VALID_RP_FILE")
assert_contains \
    "test_review_protocol_valid_schema_valid_yes: review-protocol output contains SCHEMA_VALID: yes" \
    "SCHEMA_VALID: yes" \
    "$VALID_RP_OUTPUT"

# ============================================================
# 9. review-protocol: invalid base schema fails
# ============================================================

# Missing 'subject' key
MISSING_SUBJECT_FILE=$(write_fixture "rp-missing-subject.json" '{
  "reviews": [
    {
      "perspective": "Architecture",
      "status": "reviewed",
      "dimensions": {},
      "findings": []
    }
  ],
  "conflicts": []
}')
MISSING_SUBJECT_EXIT=$(run_script review-protocol "$MISSING_SUBJECT_FILE")
assert_ne \
    "test_review_protocol_missing_subject_fails: missing subject exits non-zero" \
    "0" \
    "$MISSING_SUBJECT_EXIT"

# Empty reviews array
EMPTY_REVIEWS_FILE=$(write_fixture "rp-empty-reviews.json" '{
  "subject": "Test PR",
  "reviews": [],
  "conflicts": []
}')
EMPTY_REVIEWS_EXIT=$(run_script review-protocol "$EMPTY_REVIEWS_FILE")
assert_ne \
    "test_review_protocol_empty_reviews_fails: empty reviews array exits non-zero" \
    "0" \
    "$EMPTY_REVIEWS_EXIT"

# Invalid finding severity
INVALID_SEVERITY_FILE=$(write_fixture "rp-invalid-severity.json" '{
  "subject": "Test PR",
  "reviews": [
    {
      "perspective": "Architecture",
      "status": "reviewed",
      "dimensions": {"scalability": 3},
      "findings": [
        {
          "dimension": "scalability",
          "severity": "blocker",
          "description": "This is not a valid severity.",
          "suggestion": "Use a valid severity."
        }
      ]
    }
  ],
  "conflicts": []
}')
INVALID_SEVERITY_EXIT=$(run_script review-protocol "$INVALID_SEVERITY_FILE")
assert_ne \
    "test_review_protocol_invalid_severity_fails: invalid finding severity exits non-zero" \
    "0" \
    "$INVALID_SEVERITY_EXIT"

# ============================================================
# 10. review-protocol: --caller flag (roadmap caller)
# ============================================================

VALID_RP_ROADMAP=$(write_fixture "valid-rp-roadmap.json" '{
  "subject": "Roadmap review Q1",
  "reviews": [
    {
      "perspective": "Agent Clarity",
      "status": "reviewed",
      "dimensions": {
        "self_contained": 4,
        "success_measurable": 4
      },
      "findings": []
    },
    {
      "perspective": "Scope",
      "status": "reviewed",
      "dimensions": {
        "right_sized": 3,
        "no_overlap": 4,
        "dependency_aware": 4
      },
      "findings": []
    },
    {
      "perspective": "Value",
      "status": "reviewed",
      "dimensions": {
        "user_impact": 4,
        "validation_signal": 3
      },
      "findings": []
    }
  ],
  "conflicts": []
}')

VALID_RP_ROADMAP_EXIT=$(run_script review-protocol "$VALID_RP_ROADMAP" --caller roadmap)
assert_eq \
    "test_review_protocol_caller_roadmap_valid_passes: valid roadmap caller schema exits 0" \
    "0" \
    "$VALID_RP_ROADMAP_EXIT"

VALID_RP_ROADMAP_OUTPUT=$(run_script_output review-protocol "$VALID_RP_ROADMAP" --caller roadmap)
assert_contains \
    "test_review_protocol_caller_roadmap_schema_valid_yes: roadmap caller output contains SCHEMA_VALID: yes" \
    "SCHEMA_VALID: yes" \
    "$VALID_RP_ROADMAP_OUTPUT"

assert_contains \
    "test_review_protocol_caller_roadmap_output_includes_caller: output includes caller=roadmap" \
    "caller=roadmap" \
    "$VALID_RP_ROADMAP_OUTPUT"

# Missing required perspective for roadmap → exits non-zero
MISSING_PERSPECTIVE_FILE=$(write_fixture "rp-missing-perspective.json" '{
  "subject": "Roadmap review Q1",
  "reviews": [
    {
      "perspective": "Agent Clarity",
      "status": "reviewed",
      "dimensions": {
        "self_contained": 4,
        "success_measurable": 4
      },
      "findings": []
    }
  ],
  "conflicts": []
}')
MISSING_PERSPECTIVE_EXIT=$(run_script review-protocol "$MISSING_PERSPECTIVE_FILE" --caller roadmap)
assert_ne \
    "test_review_protocol_caller_roadmap_missing_perspective_fails: missing required perspective exits non-zero" \
    "0" \
    "$MISSING_PERSPECTIVE_EXIT"

# ============================================================
# 11. review-protocol: not_applicable status handling
# ============================================================

NOT_APPLICABLE_FILE=$(write_fixture "rp-not-applicable.json" '{
  "subject": "Plan review",
  "reviews": [
    {
      "perspective": "Agent Clarity",
      "status": "not_applicable",
      "rationale": "Not relevant for this type of plan.",
      "dimensions": {},
      "findings": []
    },
    {
      "perspective": "Scope",
      "status": "reviewed",
      "dimensions": {
        "right_sized": 4,
        "no_overlap": 4,
        "dependency_aware": 4
      },
      "findings": []
    },
    {
      "perspective": "Value",
      "status": "reviewed",
      "dimensions": {
        "user_impact": 4,
        "validation_signal": 3
      },
      "findings": []
    }
  ],
  "conflicts": []
}')

NOT_APPLICABLE_EXIT=$(run_script review-protocol "$NOT_APPLICABLE_FILE" --caller roadmap)
assert_eq \
    "test_review_protocol_not_applicable_perspective_passes: not_applicable perspective is accepted" \
    "0" \
    "$NOT_APPLICABLE_EXIT"

# not_applicable without rationale → exits non-zero
NOT_APPLICABLE_NO_RATIONALE=$(write_fixture "rp-not-applicable-no-rationale.json" '{
  "subject": "Plan review",
  "reviews": [
    {
      "perspective": "Architecture",
      "status": "not_applicable",
      "dimensions": {},
      "findings": []
    }
  ],
  "conflicts": []
}')
NOT_APPLICABLE_NO_RATIONALE_EXIT=$(run_script review-protocol "$NOT_APPLICABLE_NO_RATIONALE")
assert_ne \
    "test_review_protocol_not_applicable_without_rationale_fails: not_applicable without rationale exits non-zero" \
    "0" \
    "$NOT_APPLICABLE_NO_RATIONALE_EXIT"

# ============================================================
# 12. NEW dimension names: accepted (RED — fails until w22-4391)
# ============================================================

NEW_DIM_VALID_FILE=$(write_fixture "new-dim-valid.json" '{
  "scores": {
    "correctness": 5,
    "verification": 5,
    "hygiene": 5,
    "design": 5,
    "maintainability": 5
  },
  "findings": [],
  "summary": "All new dimension names present and scores are valid."
}')

NEW_DIM_VALID_EXIT=$(run_script code-review-dispatch "$NEW_DIM_VALID_FILE")
assert_eq \
    "test_new_dimension_names_accepted: new dimension names (correctness/verification/hygiene/design/maintainability) are valid" \
    "0" \
    "$NEW_DIM_VALID_EXIT"

# ============================================================
# 13. OLD dimension names: rejected (RED — fails until w22-4391)
# ============================================================

OLD_DIM_FILE=$(write_fixture "old-dim.json" '{
  "scores": {
    "invalid_dim_a": 4,
    "invalid_dim_b": 3,
    "invalid_dim_c": 4,
    "invalid_dim_d": 4,
    "invalid_dim_e": 5
  },
  "findings": [],
  "summary": "Unknown dimension names should be rejected by the validator."
}')

OLD_DIM_EXIT=$(run_script code-review-dispatch "$OLD_DIM_FILE")
assert_ne \
    "test_old_dimension_names_rejected: unknown dimension names are rejected" \
    "0" \
    "$OLD_DIM_EXIT"

# ============================================================
# 14. brainstorm caller: accepted with same schema as roadmap
# ============================================================

# brainstorm uses the same perspectives as roadmap (Agent Clarity, Scope, Value)
VALID_RP_BRAINSTORM=$(write_fixture "rp-brainstorm-valid.json" '{
  "subject": "Brainstorm epic review",
  "reviews": [
    {
      "perspective": "Agent Clarity",
      "status": "reviewed",
      "dimensions": {
        "self_contained": 4,
        "success_measurable": 4
      },
      "findings": []
    },
    {
      "perspective": "Scope",
      "status": "reviewed",
      "dimensions": {
        "right_sized": 4,
        "no_overlap": 4,
        "dependency_aware": 4
      },
      "findings": []
    },
    {
      "perspective": "Value",
      "status": "reviewed",
      "dimensions": {
        "user_impact": 4,
        "validation_signal": 4
      },
      "findings": []
    }
  ],
  "conflicts": []
}')

VALID_RP_BRAINSTORM_EXIT=$(run_script review-protocol "$VALID_RP_BRAINSTORM" --caller brainstorm)
assert_eq \
    "test_review_protocol_caller_brainstorm_valid_passes: valid brainstorm caller schema exits 0" \
    "0" \
    "$VALID_RP_BRAINSTORM_EXIT"

VALID_RP_BRAINSTORM_OUTPUT=$(run_script_output review-protocol "$VALID_RP_BRAINSTORM" --caller brainstorm)
assert_contains \
    "test_review_protocol_caller_brainstorm_schema_valid_yes: brainstorm caller output contains SCHEMA_VALID: yes" \
    "SCHEMA_VALID: yes" \
    "$VALID_RP_BRAINSTORM_OUTPUT"

assert_contains \
    "test_review_protocol_caller_brainstorm_output_includes_caller: output includes caller=brainstorm" \
    "caller=brainstorm" \
    "$VALID_RP_BRAINSTORM_OUTPUT"

# ============================================================
# 15. architect-foundation caller: accepted with its schema
# ============================================================

# architect-foundation uses perspectives: Failure Modes, Hardening, Scalability
VALID_RP_ARCHITECT_FOUNDATION=$(write_fixture "rp-architect-foundation-valid.json" '{
  "subject": "Architect foundation review",
  "reviews": [
    {
      "perspective": "Failure Modes",
      "status": "reviewed",
      "dimensions": {
        "resource_boundaries": 4,
        "failure_isolation": 4,
        "recovery_by_design": 3,
        "degradation_paths": 4
      },
      "findings": [
        {
          "dimension": "recovery_by_design",
          "severity": "minor",
          "description": "No explicit retry policy defined for upstream calls.",
          "suggestion": "Add exponential backoff with jitter to HTTP client config.",
          "failure_scenario": "Upstream service returns 503 under load"
        }
      ]
    },
    {
      "perspective": "Hardening",
      "status": "reviewed",
      "dimensions": {
        "secure_by_default": 4,
        "observable_by_default": 4
      },
      "findings": [
        {
          "dimension": "secure_by_default",
          "severity": "minor",
          "description": "Default token expiry not documented.",
          "suggestion": "Document token TTL in ARCH_ENFORCEMENT.md.",
          "risk_category": "auth_default"
        }
      ]
    },
    {
      "perspective": "Scalability",
      "status": "reviewed",
      "dimensions": {
        "stateless_by_default": 4,
        "data_patterns": 4
      },
      "findings": [
        {
          "dimension": "data_patterns",
          "severity": "minor",
          "description": "No caching strategy specified for read-heavy endpoints.",
          "suggestion": "Add cache-aside pattern guidance.",
          "growth_constraint": "Unbounded DB reads under fan-out"
        }
      ]
    }
  ],
  "conflicts": []
}')

VALID_RP_ARCHITECT_FOUNDATION_EXIT=$(run_script review-protocol "$VALID_RP_ARCHITECT_FOUNDATION" --caller architect-foundation)
assert_eq \
    "test_review_protocol_caller_architect_foundation_valid_passes: valid architect-foundation caller schema exits 0" \
    "0" \
    "$VALID_RP_ARCHITECT_FOUNDATION_EXIT"

VALID_RP_ARCHITECT_FOUNDATION_OUTPUT=$(run_script_output review-protocol "$VALID_RP_ARCHITECT_FOUNDATION" --caller architect-foundation)
assert_contains \
    "test_review_protocol_caller_architect_foundation_schema_valid_yes: architect-foundation caller output contains SCHEMA_VALID: yes" \
    "SCHEMA_VALID: yes" \
    "$VALID_RP_ARCHITECT_FOUNDATION_OUTPUT"

assert_contains \
    "test_review_protocol_caller_architect_foundation_output_includes_caller: output includes caller=architect-foundation" \
    "caller=architect-foundation" \
    "$VALID_RP_ARCHITECT_FOUNDATION_OUTPUT"

# Missing required perspective for architect-foundation → exits non-zero
MISSING_AF_PERSPECTIVE_FILE=$(write_fixture "rp-architect-foundation-missing-perspective.json" '{
  "subject": "Architect foundation review",
  "reviews": [
    {
      "perspective": "Failure Modes",
      "status": "reviewed",
      "dimensions": {
        "resource_boundaries": 4,
        "failure_isolation": 4,
        "recovery_by_design": 4,
        "degradation_paths": 4
      },
      "findings": []
    }
  ],
  "conflicts": []
}')
MISSING_AF_PERSPECTIVE_EXIT=$(run_script review-protocol "$MISSING_AF_PERSPECTIVE_FILE" --caller architect-foundation)
assert_ne \
    "test_review_protocol_caller_architect_foundation_missing_perspective_fails: missing required perspective exits non-zero" \
    "0" \
    "$MISSING_AF_PERSPECTIVE_EXIT"

# Hardening finding with invalid risk_category enum value → exits non-zero
INVALID_RISK_CATEGORY_FILE=$(write_fixture "rp-architect-foundation-invalid-risk-category.json" '{
  "subject": "Architect foundation review",
  "reviews": [
    {
      "perspective": "Failure Modes",
      "status": "reviewed",
      "dimensions": {
        "resource_boundaries": 4,
        "failure_isolation": 4,
        "recovery_by_design": 4,
        "degradation_paths": 4
      },
      "findings": []
    },
    {
      "perspective": "Hardening",
      "status": "reviewed",
      "dimensions": {
        "secure_by_default": 4,
        "observable_by_default": 4
      },
      "findings": [
        {
          "dimension": "secure_by_default",
          "severity": "minor",
          "description": "Placeholder hardening finding.",
          "suggestion": "Fix it.",
          "risk_category": "invalid_value"
        }
      ]
    },
    {
      "perspective": "Scalability",
      "status": "reviewed",
      "dimensions": {
        "stateless_by_default": 4,
        "data_patterns": 4
      },
      "findings": []
    }
  ],
  "conflicts": []
}')
INVALID_RISK_CATEGORY_EXIT=$(run_script review-protocol "$INVALID_RISK_CATEGORY_FILE" --caller architect-foundation)
assert_ne \
    "test_review_protocol_caller_architect_foundation_invalid_risk_category_fails: Hardening finding with invalid risk_category enum value exits non-zero" \
    "0" \
    "$INVALID_RISK_CATEGORY_EXIT"

INVALID_RISK_CATEGORY_OUTPUT=$(bash "$SCRIPT" review-protocol "$INVALID_RISK_CATEGORY_FILE" --caller architect-foundation 2>&1 || true)
assert_contains \
    "test_review_protocol_caller_architect_foundation_invalid_risk_category_schema_invalid: Hardening finding with invalid risk_category reports SCHEMA_VALID: no" \
    "SCHEMA_VALID: no" \
    "$INVALID_RISK_CATEGORY_OUTPUT"

# =============================================================================
# Test: no-findings dimension with low score should be rejected (6d83-b949)
# Scoring rules: no findings → score must be 5; score 4 requires findings.
# A dimension with zero findings and score < 5 is a scoring error.
# =============================================================================
echo ""
echo "--- test_no_findings_dimension_low_score_rejected ---"
_snapshot_fail

_NO_FINDINGS_LOW_SCORE_FILE=$(write_fixture "no_findings_low_score.json" '{
  "scores": {"hygiene": 5, "design": 5, "maintainability": 5, "correctness": 2, "verification": 4},
  "findings": [
    {"severity": "minor", "category": "verification", "description": "Minor test coverage gap", "file": "a.sh"}
  ],
  "summary": "All findings are minor but correctness scored low with no correctness findings."
}')
_NO_FINDINGS_LOW_SCORE_EXIT=$(run_script code-review-dispatch "$_NO_FINDINGS_LOW_SCORE_FILE")
assert_ne "test_no_findings_dimension_low_score_rejected" "0" "$_NO_FINDINGS_LOW_SCORE_EXIT"
_NO_FINDINGS_LOW_SCORE_OUTPUT=$(bash "$SCRIPT" code-review-dispatch "$_NO_FINDINGS_LOW_SCORE_FILE" 2>&1 || true)
assert_contains "test_no_findings_dimension_low_score_error_message" "no findings" "$_NO_FINDINGS_LOW_SCORE_OUTPUT"

assert_pass_if_clean "test_no_findings_dimension_low_score_rejected"

# =============================================================================
# Test: no-findings with score=4 should be rejected (score 4 was valid under
# old "Minor only or no findings → score 4-5" rule; now invalid — no findings
# requires score=5).
# =============================================================================
echo ""
echo "--- test_no_findings_score_4_rejected ---"
_snapshot_fail

_NO_FINDINGS_SCORE_4_FILE=$(write_fixture "no_findings_score_4.json" '{
  "scores": {"hygiene": 5, "design": 5, "maintainability": 5, "correctness": 4, "verification": 5},
  "findings": [],
  "summary": "No findings but correctness scored 4 instead of 5."
}')
_NO_FINDINGS_SCORE_4_EXIT=$(run_script code-review-dispatch "$_NO_FINDINGS_SCORE_4_FILE")
assert_ne "test_no_findings_score_4_rejected" "0" "$_NO_FINDINGS_SCORE_4_EXIT"

assert_pass_if_clean "test_no_findings_score_4_rejected"

# =============================================================================
# Test: important finding with score 3 is accepted (6d83-b949)
# Scoring rule: "important (no critical) → score 3"
# =============================================================================
echo ""
echo "--- test_important_finding_score_3_accepted ---"
_snapshot_fail

_IMPORTANT_SCORE_3_FILE=$(write_fixture "important_score_3.json" '{
  "scores": {"correctness": 3, "verification": 5, "hygiene": 5, "design": 5, "maintainability": 5},
  "findings": [
    {"severity": "important", "category": "correctness", "description": "Logic error in edge case handling", "file": "app/src/handler.py"}
  ],
  "summary": "One important finding in correctness dimension, score correctly set to 3."
}')
_IMPORTANT_SCORE_3_EXIT=$(run_script code-review-dispatch "$_IMPORTANT_SCORE_3_FILE")
assert_eq "test_important_finding_score_3_accepted" "0" "$_IMPORTANT_SCORE_3_EXIT"

assert_pass_if_clean "test_important_finding_score_3_accepted"

# =============================================================================
# Test: important finding with wrong score is rejected (6d83-b949)
# Score 4 with an important finding should fail (requires score 3)
# =============================================================================
echo ""
echo "--- test_important_finding_wrong_score_rejected ---"
_snapshot_fail

_IMPORTANT_WRONG_SCORE_FILE=$(write_fixture "important_wrong_score.json" '{
  "scores": {"correctness": 4, "verification": 5, "hygiene": 5, "design": 5, "maintainability": 5},
  "findings": [
    {"severity": "important", "category": "correctness", "description": "Logic error in edge case handling", "file": "app/src/handler.py"}
  ],
  "summary": "One important finding in correctness dimension but score is incorrectly 4 instead of 3."
}')
_IMPORTANT_WRONG_SCORE_EXIT=$(run_script code-review-dispatch "$_IMPORTANT_WRONG_SCORE_FILE")
assert_ne "test_important_finding_wrong_score_rejected" "0" "$_IMPORTANT_WRONG_SCORE_EXIT"

assert_pass_if_clean "test_important_finding_wrong_score_rejected"

# =============================================================================
# Test: minor-only dimension scored 5 should be rejected
# Scoring rule: "minor only → score 4" (deterministic; score 5 requires no findings)
# =============================================================================
echo ""
echo "--- test_minor_only_score_5_rejected ---"
_snapshot_fail

_MINOR_ONLY_SCORE_5_FILE=$(write_fixture "minor_only_score_5.json" '{
  "scores": {"hygiene": 5, "design": 5, "maintainability": 5, "correctness": 5, "verification": 5},
  "findings": [
    {"severity": "minor", "category": "hygiene", "description": "Minor style inconsistency in variable naming.", "file": "app/src/util.py"}
  ],
  "summary": "One minor hygiene finding but hygiene scored 5 instead of required 4."
}')
_MINOR_ONLY_SCORE_5_EXIT=$(run_script code-review-dispatch "$_MINOR_ONLY_SCORE_5_FILE")
assert_ne "test_minor_only_score_5_rejected" "0" "$_MINOR_ONLY_SCORE_5_EXIT"

assert_pass_if_clean "test_minor_only_score_5_rejected"

# =============================================================================
# Tests: review_tier field acceptance in code-review-dispatch schema (f493-bf4e)
#
# These tests are RED against the current schema — validate-review-output.sh
# currently requires EXACTLY 3 top-level keys (scores, findings, summary) and
# rejects review_tier as an unexpected extra key. Once SC2 of epic b430-9eb3
# is implemented (validate-review-output.sh accepts the extended schema),
# test_review_tier_valid_value_passes will turn GREEN and
# test_review_tier_invalid_value_fails will remain RED (then GREEN once enum
# validation is in place).
# =============================================================================

# Test: findings JSON with review_tier field (valid value) should pass schema validation
# RED: current schema rejects review_tier as an unexpected top-level key
echo ""
echo "--- test_review_tier_valid_value_passes ---"
_snapshot_fail

_REVIEW_TIER_VALID_FILE=$(write_fixture "review_tier_valid.json" '{
  "scores": {
    "hygiene": 5,
    "design": 5,
    "maintainability": 5,
    "correctness": 5,
    "verification": 5
  },
  "findings": [],
  "summary": "No issues found. Code is well-structured and tests are adequate.",
  "review_tier": "standard"
}')
_REVIEW_TIER_VALID_EXIT=$(run_script code-review-dispatch "$_REVIEW_TIER_VALID_FILE")
assert_eq "test_review_tier_valid_value_passes" "0" "$_REVIEW_TIER_VALID_EXIT"

assert_pass_if_clean "test_review_tier_valid_value_passes"

# Test: findings JSON with review_tier=invalid_value should fail schema validation
# RED: currently fails for wrong reason (unexpected key), should fail due to enum check
echo ""
echo "--- test_review_tier_invalid_value_fails ---"
_snapshot_fail

_REVIEW_TIER_INVALID_FILE=$(write_fixture "review_tier_invalid.json" '{
  "scores": {
    "hygiene": 5,
    "design": 5,
    "maintainability": 5,
    "correctness": 5,
    "verification": 5
  },
  "findings": [],
  "summary": "No issues found. Code is well-structured and tests are adequate.",
  "review_tier": "ultra_deep"
}')
_REVIEW_TIER_INVALID_EXIT=$(run_script code-review-dispatch "$_REVIEW_TIER_INVALID_FILE")
assert_ne "test_review_tier_invalid_value_fails" "0" "$_REVIEW_TIER_INVALID_EXIT"

assert_pass_if_clean "test_review_tier_invalid_value_fails"

# =============================================================================
# Tests: fragile severity support in code-review-dispatch (3b1c-1323)
#
# RED tests — fail against current validate-review-output.sh because
# valid_severities = {"critical", "important", "minor"} does not include "fragile".
# These pass once fragile is added to valid_severities with score mapping score=3.
# =============================================================================

# Test: fragile finding passes code-review-dispatch validation
# RED: current valid_severities excludes fragile → exits non-zero; test asserts exit 0
echo ""
echo "--- test_fragile_severity_passes_crd_validation ---"
_snapshot_fail

_FRAGILE_VALID_FILE=$(write_fixture "fragile_valid.json" '{
  "scores": {"hygiene": 5, "design": 5, "maintainability": 5, "correctness": 3, "verification": 5},
  "findings": [
    {"severity": "fragile", "category": "correctness", "description": "Edge case in error path not covered by tests.", "file": "app/src/handler.py"}
  ],
  "summary": "One fragile finding in correctness dimension; score correctly set to 3."
}')
_FRAGILE_VALID_EXIT=$(run_script code-review-dispatch "$_FRAGILE_VALID_FILE")
assert_eq "test_fragile_severity_passes_crd_validation" "0" "$_FRAGILE_VALID_EXIT"

assert_pass_if_clean "test_fragile_severity_passes_crd_validation"

# Test: fragile finding with score 3 passes score-severity consistency
# RED: current validator rejects fragile as an invalid severity before reaching
# score-consistency checks; test asserts exit 0
echo ""
echo "--- test_fragile_finding_score_3_passes_consistency ---"
_snapshot_fail

_FRAGILE_SCORE_3_FILE=$(write_fixture "fragile_score_3.json" '{
  "scores": {"hygiene": 5, "design": 5, "maintainability": 5, "correctness": 3, "verification": 5},
  "findings": [
    {"severity": "fragile", "category": "correctness", "description": "Brittle assumption about input ordering in merge logic.", "file": "app/src/merge.py"}
  ],
  "summary": "Fragile finding in correctness dimension with score 3 as required by fragile severity rule."
}')
_FRAGILE_SCORE_3_EXIT=$(run_script code-review-dispatch "$_FRAGILE_SCORE_3_FILE")
assert_eq "test_fragile_finding_score_3_passes_consistency" "0" "$_FRAGILE_SCORE_3_EXIT"

assert_pass_if_clean "test_fragile_finding_score_3_passes_consistency"

# Test: fragile finding with score 4 fails score-severity consistency
# RED: current validator rejects fragile as an invalid severity (not a score-consistency
# error); test asserts the output contains a score-consistency message about score=4,
# which is only emitted once fragile is a valid severity and triggers the consistency check
echo ""
echo "--- test_fragile_finding_score_4_fails_consistency ---"
_snapshot_fail

_FRAGILE_SCORE_4_FILE=$(write_fixture "fragile_score_4.json" '{
  "scores": {"hygiene": 5, "design": 5, "maintainability": 5, "correctness": 4, "verification": 5},
  "findings": [
    {"severity": "fragile", "category": "correctness", "description": "Brittle assumption about input ordering that may fail under load.", "file": "app/src/merge.py"}
  ],
  "summary": "Fragile finding in correctness dimension with incorrectly high score of 4."
}')
_FRAGILE_SCORE_4_OUTPUT=$(bash "$SCRIPT" code-review-dispatch "$_FRAGILE_SCORE_4_FILE" 2>&1 || true)
assert_contains "test_fragile_finding_score_4_fails_consistency_score_msg" "score 'correctness'=4" "$_FRAGILE_SCORE_4_OUTPUT"
_FRAGILE_SCORE_4_EXIT=$(run_script code-review-dispatch "$_FRAGILE_SCORE_4_FILE")
assert_ne "test_fragile_finding_score_4_fails_consistency_nonzero" "0" "$_FRAGILE_SCORE_4_EXIT"

assert_pass_if_clean "test_fragile_finding_score_4_fails_consistency"

# Test: integration — fragile finding piped through write-reviewer-findings.sh succeeds
# RED: write-reviewer-findings.sh calls validate-review-output.sh code-review-dispatch,
# which rejects fragile → exit 1; test asserts exit 0 and a hash on stdout
echo ""
echo "--- test_fragile_severity_write_reviewer_findings_integration ---"
_snapshot_fail

WRITE_SCRIPT="$DSO_PLUGIN_DIR/scripts/write-reviewer-findings.sh"
_FRAGILE_INTEGRATION_FILE=$(write_fixture "fragile_integration.json" '{
  "scores": {"hygiene": 5, "design": 5, "maintainability": 5, "correctness": 3, "verification": 5},
  "findings": [
    {"severity": "fragile", "category": "correctness", "description": "Brittle assumption in retry logic; may fail under concurrent load.", "file": "app/src/retry.py"}
  ],
  "summary": "One fragile correctness finding; all other dimensions are clean."
}')
_FRAGILE_INTEGRATION_EXIT=0
_FRAGILE_INTEGRATION_OUTPUT=$(cat "$_FRAGILE_INTEGRATION_FILE" | bash "$WRITE_SCRIPT" --output "$TMP_DIR/fragile-findings-out.json" 2>/dev/null) || _FRAGILE_INTEGRATION_EXIT=$?
assert_eq "test_fragile_severity_write_reviewer_findings_integration" "0" "$_FRAGILE_INTEGRATION_EXIT"

assert_pass_if_clean "test_fragile_severity_write_reviewer_findings_integration"

# ============================================================
# Tests: escalate_review optional field validation
# ============================================================

# Test: findings JSON with valid escalate_review array passes validation
# RED: current validator rejects escalate_review as an unexpected top-level key → exits 1.
# After GREEN: escalate_review is in optional_top, valid array with required fields → exit 0.
echo ""
echo "--- test_escalate_review_valid_array_passes_validation ---"
_snapshot_fail

_ESC_VALID_FILE=$(write_fixture "escalate_review_valid.json" '{
  "scores": {
    "hygiene": 5,
    "design": 5,
    "maintainability": 5,
    "correctness": 4,
    "verification": 5
  },
  "findings": [{"severity": "minor", "category": "correctness", "file": "src/foo.py", "description": "uncertain severity assignment"}],
  "summary": "One finding with uncertain severity; escalation requested.",
  "escalate_review": [{"finding_index": 0, "reason": "uncertain severity"}]
}')
_ESC_VALID_EXIT=$(run_script code-review-dispatch "$_ESC_VALID_FILE")
assert_eq "test_escalate_review_valid_array_passes_validation" "0" "$_ESC_VALID_EXIT"

assert_pass_if_clean "test_escalate_review_valid_array_passes_validation"

# Test: findings JSON without escalate_review field passes (field is optional)
# This is a behavioral GREEN test confirming the absence of escalate_review is accepted.
# Placed here as documentation of the contract; no _snapshot_fail needed.
_ESC_ABSENT_FILE=$(write_fixture "escalate_review_absent.json" '{
  "scores": {
    "hygiene": 5,
    "design": 5,
    "maintainability": 5,
    "correctness": 5,
    "verification": 5
  },
  "findings": [],
  "summary": "All dimensions clean; no escalation field present."
}')
_ESC_ABSENT_EXIT=$(run_script code-review-dispatch "$_ESC_ABSENT_FILE")
assert_eq \
    "test_escalate_review_absent_passes_validation: no escalate_review field is accepted" \
    "0" \
    "$_ESC_ABSENT_EXIT"

# Test: findings JSON with escalate_review as a string (not array) fails validation
# RED: current validator raises "unexpected top-level keys" error, which does not contain
# the content-validation message "'escalate_review' must be an array". After GREEN, the
# field is recognized and content-validation emits that specific message → assertion passes.
echo ""
echo "--- test_escalate_review_string_fails_with_type_error_message ---"
_snapshot_fail

_ESC_STRING_FILE=$(write_fixture "escalate_review_string.json" '{
  "scores": {
    "hygiene": 5,
    "design": 5,
    "maintainability": 5,
    "correctness": 5,
    "verification": 5
  },
  "findings": [],
  "summary": "All dimensions clean but escalate_review is malformed as a string.",
  "escalate_review": "uncertain severity"
}')
_ESC_STRING_OUTPUT=$(bash "$SCRIPT" code-review-dispatch "$_ESC_STRING_FILE" 2>&1 || true)
assert_contains \
    "test_escalate_review_string_fails_with_type_error_message" \
    "'escalate_review' must be an array" \
    "$_ESC_STRING_OUTPUT"

assert_pass_if_clean "test_escalate_review_string_fails_with_type_error_message"

# Test: findings JSON with escalate_review element missing finding_index fails validation
# RED: current validator raises "unexpected top-level keys" error, which does not contain
# the content-validation message "missing required field 'finding_index'". After GREEN,
# the field is recognized and per-element validation emits that specific message.
echo ""
echo "--- test_escalate_review_element_missing_finding_index_fails_validation ---"
_snapshot_fail

_ESC_MISSING_IDX_FILE=$(write_fixture "escalate_review_missing_index.json" '{
  "scores": {
    "hygiene": 5,
    "design": 5,
    "maintainability": 5,
    "correctness": 5,
    "verification": 5
  },
  "findings": [],
  "summary": "All dimensions clean but escalate_review element is missing finding_index.",
  "escalate_review": [{"reason": "uncertain severity"}]
}')
_ESC_MISSING_IDX_OUTPUT=$(bash "$SCRIPT" code-review-dispatch "$_ESC_MISSING_IDX_FILE" 2>&1 || true)
assert_contains \
    "test_escalate_review_element_missing_finding_index_fails_validation" \
    "missing required field 'finding_index'" \
    "$_ESC_MISSING_IDX_OUTPUT"

assert_pass_if_clean "test_escalate_review_element_missing_finding_index_fails_validation"

# ============================================================
# approach_viability_concern: summary-embedded boolean signal
# (follows *_warranted pattern — not a top-level JSON key)
# No schema validation tests needed since it's parsed from summary text.
# ============================================================

# Test: findings JSON without approach_viability_concern passes (optional field)
# This test is GREEN immediately: absent optional fields are not flagged as errors.
_AVC_ABSENT_FILE=$(write_fixture "approach_viability_concern_absent.json" '{
  "scores": {
    "hygiene": 5,
    "design": 5,
    "maintainability": 5,
    "correctness": 5,
    "verification": 5
  },
  "findings": [],
  "summary": "No approach_viability_concern field present at all."
}')
_AVC_ABSENT_EXIT=0
bash "$SCRIPT" code-review-dispatch "$_AVC_ABSENT_FILE" >/dev/null 2>&1 || _AVC_ABSENT_EXIT=$?
assert_eq \
    "test_approach_viability_concern_absent_passes" \
    "0" \
    "$_AVC_ABSENT_EXIT"

print_summary
