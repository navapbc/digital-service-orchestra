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

# test_code_review_dispatch_with_scores_key_deprecated
# Given: reviewer-findings.json with a scores key present (and valid summary)
# When: validate-review-output.sh code-review-dispatch <file> runs
# Then: exits 0 (scores tolerated during transition), SCHEMA_VALID: yes,
#       and a DEPRECATION WARNING appears on stderr
echo "=== test_code_review_dispatch_with_scores_key_deprecated ==="
FIXTURE_FILE=$(write_fixture "scores-key-present.json" '{"scores":{"hygiene":5,"design":5,"maintainability":5,"correctness":5,"verification":5},"findings":[],"summary":"All checks passed. No issues found."}')
_STDERR_TMP=$(mktemp "${TMPDIR:-/tmp}/test-validate-review-output-stderr.XXXXXX")
EXIT_CODE=0
STDOUT_OUT=$(bash "$SCRIPT" code-review-dispatch "$FIXTURE_FILE" 2>"$_STDERR_TMP") || EXIT_CODE=$?
STDERR_OUT=$(cat "$_STDERR_TMP")
rm -f "$_STDERR_TMP"
assert_eq "test_code_review_dispatch_with_scores_key_deprecated: exits 0 (scores tolerated)" "0" "$EXIT_CODE"
assert_contains "test_code_review_dispatch_with_scores_key_deprecated: stdout contains SCHEMA_VALID: yes" "SCHEMA_VALID: yes" "$STDOUT_OUT"
assert_contains "test_code_review_dispatch_with_scores_key_deprecated: stderr contains DEPRECATION WARNING" "DEPRECATION WARNING" "$STDERR_OUT"

# code-review-dispatch: valid with findings (2-key schema)
VALID_CRD_WITH_FINDINGS=$(write_fixture "valid-crd-findings.json" '{
  "findings": [
    {
      "severity": "critical",
      "category": "hygiene",
      "description": "Syntax error in module",
      "file": "app/src/broken.py",
      "cited_lines": ["app/src/broken.py:1"],
      "cited_excerpt": "def broken(:\n    pass",
      "reachability": "Module is imported at app startup; the syntax error prevents the process from booting on every run."
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
  "findings": []
}')
MISSING_SUMMARY_EXIT=$(run_script code-review-dispatch "$MISSING_SUMMARY_FILE")
assert_ne \
    "test_code_review_dispatch_missing_summary_fails: missing summary exits non-zero" \
    "0" \
    "$MISSING_SUMMARY_EXIT"

# Unexpected extra top-level key
EXTRA_KEY_FILE=$(write_fixture "extra-key.json" '{
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
# 5a. code-review-dispatch: cited_excerpt enforcement (Approach 1)
# ============================================================
#
# A verbatim code excerpt from the cited file is required on every finding so
# that misreads / hallucinations / stale line refs are visible inside the
# finding itself. See bug d42d-8126-492c-44c4 (PR-80 review round 2: 8 of 11
# findings invalid or overstated severity, 4 of which were misreads of code
# the reviewer cited only by line number).

# test_cited_excerpt_missing_rejected
# Finding without cited_excerpt → rejected.
MISSING_EXCERPT_FILE=$(write_fixture "missing-excerpt.json" '{
  "findings": [
    {
      "severity": "minor",
      "category": "hygiene",
      "description": "Test finding",
      "file": "src/foo.py",
      "cited_lines": ["src/foo.py:42"]
    }
  ],
  "summary": "Test summary for cited_excerpt enforcement."
}')
MISSING_EXCERPT_EXIT=$(run_script code-review-dispatch "$MISSING_EXCERPT_FILE")
assert_ne \
    "test_cited_excerpt_missing_rejected: missing cited_excerpt exits non-zero" \
    "0" \
    "$MISSING_EXCERPT_EXIT"

# test_cited_excerpt_present_accepted
# Finding with a valid cited_excerpt → accepted.
WITH_EXCERPT_FILE=$(write_fixture "with-excerpt.json" '{
  "findings": [
    {
      "severity": "minor",
      "category": "hygiene",
      "description": "Test finding",
      "file": "src/foo.py",
      "cited_lines": ["src/foo.py:42"],
      "cited_excerpt": "def foo():\n    pass"
    }
  ],
  "summary": "Test summary for cited_excerpt enforcement."
}')
WITH_EXCERPT_EXIT=$(run_script code-review-dispatch "$WITH_EXCERPT_FILE")
assert_eq \
    "test_cited_excerpt_present_accepted: valid cited_excerpt exits 0" \
    "0" \
    "$WITH_EXCERPT_EXIT"

# test_cited_excerpt_empty_string_rejected
# Empty cited_excerpt is meaningless — treated the same as missing.
EMPTY_EXCERPT_FILE=$(write_fixture "empty-excerpt.json" '{
  "findings": [
    {
      "severity": "minor",
      "category": "hygiene",
      "description": "Test finding",
      "file": "src/foo.py",
      "cited_lines": ["src/foo.py:42"],
      "cited_excerpt": ""
    }
  ],
  "summary": "Test summary for cited_excerpt enforcement."
}')
EMPTY_EXCERPT_EXIT=$(run_script code-review-dispatch "$EMPTY_EXCERPT_FILE")
assert_ne \
    "test_cited_excerpt_empty_string_rejected: empty cited_excerpt exits non-zero" \
    "0" \
    "$EMPTY_EXCERPT_EXIT"

# test_cited_excerpt_too_short_rejected
# Excerpt < 5 chars cannot meaningfully anchor a finding to file content; reject.
SHORT_EXCERPT_FILE=$(write_fixture "short-excerpt.json" '{
  "findings": [
    {
      "severity": "minor",
      "category": "hygiene",
      "description": "Test finding",
      "file": "src/foo.py",
      "cited_lines": ["src/foo.py:42"],
      "cited_excerpt": "abc"
    }
  ],
  "summary": "Test summary for cited_excerpt enforcement."
}')
SHORT_EXCERPT_EXIT=$(run_script code-review-dispatch "$SHORT_EXCERPT_FILE")
assert_ne \
    "test_cited_excerpt_too_short_rejected: cited_excerpt under 5 chars exits non-zero" \
    "0" \
    "$SHORT_EXCERPT_EXIT"

# test_cited_excerpt_non_string_rejected
# Non-string cited_excerpt (e.g., array, number) must be rejected.
NONSTRING_EXCERPT_FILE=$(write_fixture "nonstring-excerpt.json" '{
  "findings": [
    {
      "severity": "minor",
      "category": "hygiene",
      "description": "Test finding",
      "file": "src/foo.py",
      "cited_lines": ["src/foo.py:42"],
      "cited_excerpt": ["not", "a", "string"]
    }
  ],
  "summary": "Test summary for cited_excerpt enforcement."
}')
NONSTRING_EXCERPT_EXIT=$(run_script code-review-dispatch "$NONSTRING_EXCERPT_FILE")
assert_ne \
    "test_cited_excerpt_non_string_rejected: non-string cited_excerpt exits non-zero" \
    "0" \
    "$NONSTRING_EXCERPT_EXIT"

# ============================================================
# 5b. code-review-dispatch: reachability enforcement (Approach 2)
# ============================================================
#
# Findings with severity in {critical, important, fragile} must include a
# reachability sentence: a one-sentence caller-input → bug-site → observable-harm
# path. This forces the reviewer to demonstrate that the asserted defect is on a
# reachable path before claiming high severity. See bug d42d-8126-492c-44c4
# (PR-80 N1: hypothesized off-by-one impossible by builder construction; N3:
# concurrent-write race ruled out by POSIX PIPE_BUF atomicity). minor and
# suggestion-class findings do not require reachability.

# test_reachability_required_for_critical
# A critical finding without reachability → rejected.
CRITICAL_NO_REACH_FILE=$(write_fixture "critical-no-reach.json" '{
  "findings": [
    {
      "severity": "critical",
      "category": "correctness",
      "description": "Off-by-one in loop",
      "file": "src/foo.py",
      "cited_lines": ["src/foo.py:42"],
      "cited_excerpt": "for i in range(len(arr)):"
    }
  ],
  "summary": "Test summary for reachability enforcement."
}')
CRITICAL_NO_REACH_EXIT=$(run_script code-review-dispatch "$CRITICAL_NO_REACH_FILE")
assert_ne \
    "test_reachability_required_for_critical: critical without reachability exits non-zero" \
    "0" \
    "$CRITICAL_NO_REACH_EXIT"

# test_reachability_required_for_important
# An important finding without reachability → rejected.
IMPORTANT_NO_REACH_FILE=$(write_fixture "important-no-reach.json" '{
  "findings": [
    {
      "severity": "important",
      "category": "correctness",
      "description": "Missing null check",
      "file": "src/foo.py",
      "cited_lines": ["src/foo.py:42"],
      "cited_excerpt": "result = data.get('key')"
    }
  ],
  "summary": "Test summary for reachability enforcement."
}')
IMPORTANT_NO_REACH_EXIT=$(run_script code-review-dispatch "$IMPORTANT_NO_REACH_FILE")
assert_ne \
    "test_reachability_required_for_important: important without reachability exits non-zero" \
    "0" \
    "$IMPORTANT_NO_REACH_EXIT"

# test_reachability_required_for_fragile
# A fragile finding without reachability → rejected (treated like important per CLAUDE.md rule 11).
FRAGILE_NO_REACH_FILE=$(write_fixture "fragile-no-reach.json" '{
  "findings": [
    {
      "severity": "fragile",
      "category": "correctness",
      "description": "Calls a function that may not exist on the target API",
      "file": "src/foo.py",
      "cited_lines": ["src/foo.py:42"],
      "cited_excerpt": "client.unknown_method()"
    }
  ],
  "summary": "Test summary for reachability enforcement."
}')
FRAGILE_NO_REACH_EXIT=$(run_script code-review-dispatch "$FRAGILE_NO_REACH_FILE")
assert_ne \
    "test_reachability_required_for_fragile: fragile without reachability exits non-zero" \
    "0" \
    "$FRAGILE_NO_REACH_EXIT"

# test_reachability_present_critical_passes
# Critical finding WITH a substantive reachability sentence → accepted.
CRITICAL_WITH_REACH_FILE=$(write_fixture "critical-with-reach.json" '{
  "findings": [
    {
      "severity": "critical",
      "category": "correctness",
      "description": "Off-by-one in loop bounds will index past end of array",
      "file": "src/foo.py",
      "cited_lines": ["src/foo.py:42"],
      "cited_excerpt": "for i in range(len(arr) + 1):",
      "reachability": "Public handler accepts user-supplied arr; len+1 indexes past end and raises IndexError on every non-empty input."
    }
  ],
  "summary": "Test summary for reachability enforcement."
}')
CRITICAL_WITH_REACH_EXIT=$(run_script code-review-dispatch "$CRITICAL_WITH_REACH_FILE")
assert_eq \
    "test_reachability_present_critical_passes: critical with reachability exits 0" \
    "0" \
    "$CRITICAL_WITH_REACH_EXIT"

# test_reachability_too_short_rejected
# A reachability under 20 chars cannot articulate a real path; reject.
SHORT_REACH_FILE=$(write_fixture "short-reach.json" '{
  "findings": [
    {
      "severity": "critical",
      "category": "correctness",
      "description": "Off-by-one in loop bounds",
      "file": "src/foo.py",
      "cited_lines": ["src/foo.py:42"],
      "cited_excerpt": "for i in range(len(arr) + 1):",
      "reachability": "bug"
    }
  ],
  "summary": "Test summary for reachability enforcement."
}')
SHORT_REACH_EXIT=$(run_script code-review-dispatch "$SHORT_REACH_FILE")
assert_ne \
    "test_reachability_too_short_rejected: reachability under 20 chars exits non-zero" \
    "0" \
    "$SHORT_REACH_EXIT"

# test_reachability_not_required_for_minor
# A minor finding without reachability → accepted (the field is only required
# for severities that block merge: critical, important, fragile).
MINOR_NO_REACH_FILE=$(write_fixture "minor-no-reach.json" '{
  "findings": [
    {
      "severity": "minor",
      "category": "maintainability",
      "description": "Variable name could be clearer",
      "file": "src/foo.py",
      "cited_lines": ["src/foo.py:42"],
      "cited_excerpt": "x = compute()"
    }
  ],
  "summary": "Test summary for reachability enforcement."
}')
MINOR_NO_REACH_EXIT=$(run_script code-review-dispatch "$MINOR_NO_REACH_FILE")
assert_eq \
    "test_reachability_not_required_for_minor: minor without reachability exits 0" \
    "0" \
    "$MINOR_NO_REACH_EXIT"

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
# 12. Missing required key 'findings': rejected
# ============================================================

MISSING_FINDINGS_CRD_FILE=$(write_fixture "missing-findings-crd.json" '{
  "summary": "No findings array present — should fail validation."
}')

MISSING_FINDINGS_CRD_EXIT=$(run_script code-review-dispatch "$MISSING_FINDINGS_CRD_FILE")
assert_ne \
    "test_missing_findings_key_rejected: missing findings key exits non-zero" \
    "0" \
    "$MISSING_FINDINGS_CRD_EXIT"

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
# Tests: review_tier field acceptance in code-review-dispatch schema (f493-bf4e)
#
# These tests use the 2-key schema (findings + summary).
# test_review_tier_valid_value_passes asserts exit 0 with review_tier present.
# test_review_tier_invalid_value_fails asserts exit non-zero for bad enum value.
# =============================================================================

# Test: findings JSON with review_tier field (valid value) should pass schema validation
echo ""
echo "--- test_review_tier_valid_value_passes ---"
_snapshot_fail

_REVIEW_TIER_VALID_FILE=$(write_fixture "review_tier_valid.json" '{
  "findings": [],
  "summary": "No issues found. Code is well-structured and tests are adequate.",
  "review_tier": "standard"
}')
_REVIEW_TIER_VALID_EXIT=$(run_script code-review-dispatch "$_REVIEW_TIER_VALID_FILE")
assert_eq "test_review_tier_valid_value_passes" "0" "$_REVIEW_TIER_VALID_EXIT"

assert_pass_if_clean "test_review_tier_valid_value_passes"

# Test: findings JSON with review_tier=invalid_value should fail schema validation
echo ""
echo "--- test_review_tier_invalid_value_fails ---"
_snapshot_fail

_REVIEW_TIER_INVALID_FILE=$(write_fixture "review_tier_invalid.json" '{
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
# These pass once fragile is added to valid_severities.
# All fixtures use 2-key schema (findings + summary).
# =============================================================================

# Test: fragile finding passes code-review-dispatch validation
# RED: current valid_severities excludes fragile → exits non-zero; test asserts exit 0
echo ""
echo "--- test_fragile_severity_passes_crd_validation ---"
_snapshot_fail

_FRAGILE_VALID_FILE=$(write_fixture "fragile_valid.json" '{
  "findings": [
    {"severity": "fragile", "category": "correctness", "description": "Edge case in error path not covered by tests.", "file": "app/src/handler.py", "cited_lines": ["app/src/handler.py:42"], "cited_excerpt": "raise UnknownError()", "reachability": "Error path triggered by malformed user input; no test exercises this branch so a regression here ships silently."}
  ],
  "summary": "One fragile finding in correctness dimension."
}')
_FRAGILE_VALID_EXIT=$(run_script code-review-dispatch "$_FRAGILE_VALID_FILE")
assert_eq "test_fragile_severity_passes_crd_validation" "0" "$_FRAGILE_VALID_EXIT"

assert_pass_if_clean "test_fragile_severity_passes_crd_validation"

# Test: fragile finding passes validation (2-key schema)
# RED: current validator rejects fragile as an invalid severity; test asserts exit 0
echo ""
echo "--- test_fragile_finding_passes_validation ---"
_snapshot_fail

_FRAGILE_SCORE_3_FILE=$(write_fixture "fragile_score_3.json" '{
  "findings": [
    {"severity": "fragile", "category": "correctness", "description": "Brittle assumption about input ordering in merge logic.", "file": "app/src/merge.py", "cited_lines": ["app/src/merge.py:17"], "cited_excerpt": "merged = sorted(a + b)", "reachability": "Merge function is called by the public batch endpoint; out-of-order inputs from real producers will produce wrong results."}
  ],
  "summary": "Fragile finding in correctness dimension."
}')
_FRAGILE_SCORE_3_EXIT=$(run_script code-review-dispatch "$_FRAGILE_SCORE_3_FILE")
assert_eq "test_fragile_finding_passes_validation" "0" "$_FRAGILE_SCORE_3_EXIT"

assert_pass_if_clean "test_fragile_finding_passes_validation"

# Test: integration — fragile finding piped through write-reviewer-findings.sh succeeds
# RED: write-reviewer-findings.sh calls validate-review-output.sh code-review-dispatch,
# which rejects fragile → exit 1; test asserts exit 0 and a hash on stdout
echo ""
echo "--- test_fragile_severity_write_reviewer_findings_integration ---"
_snapshot_fail

WRITE_SCRIPT="$DSO_PLUGIN_DIR/scripts/write-reviewer-findings.sh"
_FRAGILE_INTEGRATION_FILE=$(write_fixture "fragile_integration.json" '{
  "findings": [
    {"severity": "fragile", "category": "correctness", "description": "Brittle assumption in retry logic; may fail under concurrent load.", "file": "app/src/retry.py", "cited_lines": ["app/src/retry.py:88"], "cited_excerpt": "retries = global_counter", "reachability": "Retry path runs from any background worker and reads a shared mutable global; concurrent dispatch corrupts the counter."}
  ],
  "summary": "One fragile correctness finding; all other dimensions are clean."
}')
_FRAGILE_INTEGRATION_EXIT=0
_FRAGILE_INTEGRATION_OUTPUT=$(cat "$_FRAGILE_INTEGRATION_FILE" | bash "$WRITE_SCRIPT" --output "$TMP_DIR/fragile-findings-out.json" 2>/dev/null) || _FRAGILE_INTEGRATION_EXIT=$?
assert_eq "test_fragile_severity_write_reviewer_findings_integration" "0" "$_FRAGILE_INTEGRATION_EXIT"

assert_pass_if_clean "test_fragile_severity_write_reviewer_findings_integration"

# ============================================================
# Tests: escalate_review optional field validation
# All fixtures use 2-key schema (findings + summary).
# ============================================================

# Test: findings JSON with valid escalate_review array passes validation
# RED: current validator rejects escalate_review as an unexpected top-level key → exits 1.
# After GREEN: escalate_review is in optional_top, valid array with required fields → exit 0.
echo ""
echo "--- test_escalate_review_valid_array_passes_validation ---"
_snapshot_fail

_ESC_VALID_FILE=$(write_fixture "escalate_review_valid.json" '{
  "findings": [{"severity": "minor", "category": "correctness", "file": "src/foo.py", "description": "uncertain severity assignment", "cited_lines": ["src/foo.py:5"], "cited_excerpt": "value = compute_thing()"}],
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
  "findings": [],
  "summary": "No approach_viability_concern field present at all."
}')
_AVC_ABSENT_EXIT=0
bash "$SCRIPT" code-review-dispatch "$_AVC_ABSENT_FILE" >/dev/null 2>&1 || _AVC_ABSENT_EXIT=$?
assert_eq \
    "test_approach_viability_concern_absent_passes" \
    "0" \
    "$_AVC_ABSENT_EXIT"

# ============================================================
# review-protocol: status="pass" / status="fail" rejected (3e37-80ba)
# ============================================================
# Sub-agents have drifted into emitting `"status": "pass"` (or "fail") on
# review-protocol output. The schema only allows "reviewed" or "not_applicable";
# pass/fail is computed by the caller from dimension scores. The validator
# must reject the out-of-schema status with a specific diagnostic so the
# caller can re-dispatch instead of silently misinterpreting the verdict.
INVALID_STATUS_PASS_FILE=$(write_fixture "rp-status-pass.json" '{
  "subject": "Implementation Plan for: story X",
  "reviews": [
    {
      "perspective": "Dependencies",
      "status": "pass",
      "dimensions": {"dag_validity": 5, "no_coupling": 3},
      "findings": []
    }
  ],
  "conflicts": []
}')
INVALID_STATUS_PASS_EXIT=$(run_script review-protocol "$INVALID_STATUS_PASS_FILE")
assert_ne \
    "test_review_protocol_status_pass_rejected: status='pass' exits non-zero" \
    "0" \
    "$INVALID_STATUS_PASS_EXIT"
INVALID_STATUS_PASS_OUT=$(bash "$SCRIPT" review-protocol "$INVALID_STATUS_PASS_FILE" 2>&1 || true)
assert_contains \
    "test_review_protocol_status_pass_rejected: cites valid status values" \
    "must be 'reviewed' or 'not_applicable'" \
    "$INVALID_STATUS_PASS_OUT"

print_summary
