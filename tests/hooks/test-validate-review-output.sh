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

# test_code_review_dispatch_with_fallback_hops_passes (bug 284b)
# Given: a code-review-dispatch payload carrying the infra-emitted fallback_hops
#        top-level key (dispatch.py appends it when a provider fallback hop occurs)
# When: validate-review-output.sh code-review-dispatch <file> runs
# Then: exits 0 (fallback_hops is an allowlisted optional key) — a non-zero here is
#       the schema-correction-exhausted fail-closed this regression test guards.
echo "=== test_code_review_dispatch_with_fallback_hops_passes ==="
FALLBACK_HOPS_FIXTURE=$(write_fixture "crd-fallback-hops.json" '{"findings":[],"summary":"All checks passed. No issues found.","fallback_hops":["anthropic->openai: rate_limited"]}')
FALLBACK_HOPS_EXIT=$(run_script code-review-dispatch "$FALLBACK_HOPS_FIXTURE")
assert_eq \
    "test_code_review_dispatch_with_fallback_hops_passes: fallback_hops top-level key is allowlisted, exits 0" \
    "0" \
    "$FALLBACK_HOPS_EXIT"

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
# 5a-2. code-review-dispatch: cited_lines line-range format
# ============================================================
#
# cited_lines entries may use a range (e.g. "file:83-112" or "file:83~112") in
# addition to a single line number ("file:42"). LLMs commonly emit ranges when
# citing a block of code; rejecting them causes unnecessary schema correction
# cycles. See the _CITED_LINE_RE regex in dispatch.py and the _cited_pattern in
# validate-review-output.sh.

# test_cited_lines_dash_range_accepted
# cited_lines entry with a dash-range (file:N-M) should be accepted.
DASH_RANGE_CITED_FILE=$(write_fixture "dash-range-cited.json" '{
  "findings": [
    {
      "severity": "minor",
      "category": "hygiene",
      "description": "Test finding with line range.",
      "file": "src/foo.py",
      "cited_lines": [".github/workflows/per-branch-review.yml:83-112"],
      "cited_excerpt": "def foo():\n    pass\n    more code here"
    }
  ],
  "summary": "Test summary for cited_lines range format."
}')
DASH_RANGE_CITED_EXIT=$(run_script code-review-dispatch "$DASH_RANGE_CITED_FILE")
assert_eq \
    "test_cited_lines_dash_range_accepted: cited_lines with dash range exits 0" \
    "0" \
    "$DASH_RANGE_CITED_EXIT"

# test_cited_lines_tilde_range_accepted
# cited_lines entry with a tilde-range (file:N~M) should be accepted.
TILDE_RANGE_CITED_FILE=$(write_fixture "tilde-range-cited.json" '{
  "findings": [
    {
      "severity": "minor",
      "category": "hygiene",
      "description": "Test finding with tilde line range.",
      "file": "src/dispatch.py",
      "cited_lines": ["plugins/dso/scripts/dso_ci_review/dispatch.py:845~851"],
      "cited_excerpt": "def dispatch_schema_correction(\n    original_findings"
    }
  ],
  "summary": "Test summary for cited_lines tilde-range format."
}')
TILDE_RANGE_CITED_EXIT=$(run_script code-review-dispatch "$TILDE_RANGE_CITED_FILE")
assert_eq \
    "test_cited_lines_tilde_range_accepted: cited_lines with tilde range exits 0" \
    "0" \
    "$TILDE_RANGE_CITED_EXIT"

# test_cited_lines_invalid_format_rejected
# cited_lines entry with no line number at all should still be rejected.
INVALID_CITED_FILE=$(write_fixture "invalid-cited.json" '{
  "findings": [
    {
      "severity": "minor",
      "category": "hygiene",
      "description": "Test finding with bad cited_lines.",
      "file": "src/foo.py",
      "cited_lines": ["src/bad_format_no_line_number"],
      "cited_excerpt": "def foo():\n    pass"
    }
  ],
  "summary": "Test summary for invalid cited_lines format."
}')
INVALID_CITED_EXIT=$(run_script code-review-dispatch "$INVALID_CITED_FILE")
assert_ne \
    "test_cited_lines_invalid_format_rejected: cited_lines without line number exits non-zero" \
    "0" \
    "$INVALID_CITED_EXIT"

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
      "cited_excerpt": "result = data.get(key)"
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

# === Absence-Claim Detection & verification_evidence validation ===
#
# These tests are RED before S1 T4 implements absence-claim detection in
# validate-review-output.sh and before S1 T2 creates absence-claim-anchors.json.
#
# Hard-mode sentinel: CLAUDE_PLUGIN_ROOT/contracts/absence-claim-enforcement-v1
# Soft mode (default): validator warns but exits 0.
# Hard mode: validator exits 1 and error message mentions verification_evidence.
#
# The CLAUDE_PLUGIN_ROOT env var is already honoured by validate-review-output.sh
# (line 58: _PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-...}"). Hard-mode tests export a
# temp dir and create the sentinel inside it; they restore the env after.

# test_absence_claim_soft_mode_warns_on_missing_verification_evidence
# Given: finding whose description contains absence language ("does not exist"),
#        no verification_evidence field, and no hard-mode sentinel.
# When:  validate-review-output.sh code-review-dispatch runs.
# Then:  exits 0 (soft mode does not reject) AND combined output contains
#        "WARNING" or "warning".
echo ""
echo "--- test_absence_claim_soft_mode_warns_on_missing_verification_evidence ---"
_snapshot_fail

_ABSENCE_SOFT_FILE=$(write_fixture "absence_soft.json" '{
  "findings": [
    {
      "severity": "minor",
      "category": "correctness",
      "description": "The helper function does not exist in the module",
      "file": "src/utils.py",
      "cited_lines": ["src/utils.py:10"],
      "cited_excerpt": "from utils import helper_fn"
    }
  ],
  "summary": "Absence claim finding without verification evidence."
}')
_ABSENCE_SOFT_TMP=$(mktemp "${TMPDIR:-/tmp}/absence-soft-combined.XXXXXX")
_ABSENCE_SOFT_EXIT=0
_ABSENCE_SOFT_PLUGIN_ROOT=$(mktemp -d)
# Soft mode: sentinel NOT created inside the temp root
CLAUDE_PLUGIN_ROOT="$_ABSENCE_SOFT_PLUGIN_ROOT" bash "$SCRIPT" code-review-dispatch "$_ABSENCE_SOFT_FILE" >"$_ABSENCE_SOFT_TMP" 2>&1 || _ABSENCE_SOFT_EXIT=$?
_ABSENCE_SOFT_OUT=$(cat "$_ABSENCE_SOFT_TMP")
rm -f "$_ABSENCE_SOFT_TMP"
rm -rf "$_ABSENCE_SOFT_PLUGIN_ROOT"
assert_eq \
    "test_absence_claim_soft_mode_warns_on_missing_verification_evidence: exits 0 (soft mode)" \
    "0" \
    "$_ABSENCE_SOFT_EXIT"
assert_contains \
    "test_absence_claim_soft_mode_warns_on_missing_verification_evidence: output contains warning" \
    "ARNING" \
    "$_ABSENCE_SOFT_OUT"

assert_pass_if_clean "test_absence_claim_soft_mode_warns_on_missing_verification_evidence"

# test_absence_claim_hard_mode_errors_on_missing_verification_evidence
# Given: finding whose description contains "function is not defined" (absence trigger),
#        no verification_evidence, and hard-mode sentinel file present.
# When:  validate-review-output.sh code-review-dispatch runs.
# Then:  exits 1 AND combined output mentions "verification_evidence".
echo ""
echo "--- test_absence_claim_hard_mode_errors_on_missing_verification_evidence ---"
_snapshot_fail

_ABSENCE_HARD_FILE=$(write_fixture "absence_hard.json" '{
  "findings": [
    {
      "severity": "minor",
      "category": "correctness",
      "description": "The callback function is not defined anywhere in the codebase",
      "file": "src/app.py",
      "cited_lines": ["src/app.py:55"],
      "cited_excerpt": "register_callback(on_event)"
    }
  ],
  "summary": "Absence claim finding in hard mode without verification evidence."
}')
_ABSENCE_HARD_TMP=$(mktemp "${TMPDIR:-/tmp}/absence-hard-combined.XXXXXX")
_ABSENCE_HARD_EXIT=0
_ABSENCE_HARD_PLUGIN_ROOT=$(mktemp -d)
mkdir -p "$_ABSENCE_HARD_PLUGIN_ROOT/contracts"
touch "$_ABSENCE_HARD_PLUGIN_ROOT/contracts/absence-claim-enforcement-v1"
CLAUDE_PLUGIN_ROOT="$_ABSENCE_HARD_PLUGIN_ROOT" bash "$SCRIPT" code-review-dispatch "$_ABSENCE_HARD_FILE" >"$_ABSENCE_HARD_TMP" 2>&1 || _ABSENCE_HARD_EXIT=$?
_ABSENCE_HARD_OUT=$(cat "$_ABSENCE_HARD_TMP")
rm -f "$_ABSENCE_HARD_TMP"
rm -rf "$_ABSENCE_HARD_PLUGIN_ROOT"
assert_ne \
    "test_absence_claim_hard_mode_errors_on_missing_verification_evidence: exits non-zero (hard mode)" \
    "0" \
    "$_ABSENCE_HARD_EXIT"
assert_contains \
    "test_absence_claim_hard_mode_errors_on_missing_verification_evidence: output mentions verification_evidence" \
    "verification_evidence" \
    "$_ABSENCE_HARD_OUT"

assert_pass_if_clean "test_absence_claim_hard_mode_errors_on_missing_verification_evidence"

# test_absence_claim_no_warning_when_evidence_present
# Given: finding with absence language AND verification_evidence (command + output fields),
#        in hard mode.
# When:  validate-review-output.sh code-review-dispatch runs.
# Then:  exits 0.
echo ""
echo "--- test_absence_claim_no_warning_when_evidence_present ---"
_snapshot_fail

_ABSENCE_EVIDENCE_FILE=$(write_fixture "absence_with_evidence.json" '{
  "findings": [
    {
      "severity": "minor",
      "category": "correctness",
      "description": "The helper module does not exist at the import path",
      "file": "src/app.py",
      "cited_lines": ["src/app.py:3"],
      "cited_excerpt": "from helpers import process_data",
      "verification_evidence": {
        "command": "ls src/helpers.py",
        "output": "ls: src/helpers.py: No such file or directory"
      }
    }
  ],
  "summary": "Absence claim with verification evidence provided."
}')
_ABSENCE_EVIDENCE_TMP=$(mktemp "${TMPDIR:-/tmp}/absence-evidence-combined.XXXXXX")
_ABSENCE_EVIDENCE_EXIT=0
_ABSENCE_EVIDENCE_PLUGIN_ROOT=$(mktemp -d)
mkdir -p "$_ABSENCE_EVIDENCE_PLUGIN_ROOT/contracts"
touch "$_ABSENCE_EVIDENCE_PLUGIN_ROOT/contracts/absence-claim-enforcement-v1"
CLAUDE_PLUGIN_ROOT="$_ABSENCE_EVIDENCE_PLUGIN_ROOT" bash "$SCRIPT" code-review-dispatch "$_ABSENCE_EVIDENCE_FILE" >"$_ABSENCE_EVIDENCE_TMP" 2>&1 || _ABSENCE_EVIDENCE_EXIT=$?
rm -f "$_ABSENCE_EVIDENCE_TMP"
rm -rf "$_ABSENCE_EVIDENCE_PLUGIN_ROOT"
assert_eq \
    "test_absence_claim_no_warning_when_evidence_present: exits 0 when evidence provided" \
    "0" \
    "$_ABSENCE_EVIDENCE_EXIT"

assert_pass_if_clean "test_absence_claim_no_warning_when_evidence_present"

# test_non_absence_claim_no_verification_evidence_required
# Given: finding whose description does NOT contain absence language,
#        no verification_evidence, in hard mode.
# When:  validate-review-output.sh code-review-dispatch runs.
# Then:  exits 0 (absence detection does not fire).
echo ""
echo "--- test_non_absence_claim_no_verification_evidence_required ---"
_snapshot_fail

_NON_ABSENCE_FILE=$(write_fixture "non_absence.json" '{
  "findings": [
    {
      "severity": "minor",
      "category": "hygiene",
      "description": "Variable name could be more descriptive for clarity",
      "file": "src/utils.py",
      "cited_lines": ["src/utils.py:22"],
      "cited_excerpt": "x = compute()"
    }
  ],
  "summary": "Non-absence finding does not require verification evidence."
}')
_NON_ABSENCE_EXIT=0
_NON_ABSENCE_PLUGIN_ROOT=$(mktemp -d)
mkdir -p "$_NON_ABSENCE_PLUGIN_ROOT/contracts"
touch "$_NON_ABSENCE_PLUGIN_ROOT/contracts/absence-claim-enforcement-v1"
CLAUDE_PLUGIN_ROOT="$_NON_ABSENCE_PLUGIN_ROOT" bash "$SCRIPT" code-review-dispatch "$_NON_ABSENCE_FILE" >/dev/null 2>&1 || _NON_ABSENCE_EXIT=$?
rm -rf "$_NON_ABSENCE_PLUGIN_ROOT"
assert_eq \
    "test_non_absence_claim_no_verification_evidence_required: exits 0 for non-absence finding" \
    "0" \
    "$_NON_ABSENCE_EXIT"

assert_pass_if_clean "test_non_absence_claim_no_verification_evidence_required"

# test_verification_evidence_missing_command_field_rejected
# Given: finding with verification_evidence present but missing the 'command' sub-field.
# When:  validate-review-output.sh code-review-dispatch runs (any mode).
# Then:  exits non-zero (malformed verification_evidence is invalid).
echo ""
echo "--- test_verification_evidence_missing_command_field_rejected ---"
_snapshot_fail

_VE_NO_CMD_FILE=$(write_fixture "ve_missing_command.json" '{
  "findings": [
    {
      "severity": "minor",
      "category": "correctness",
      "description": "The referenced function does not exist in scope",
      "file": "src/app.py",
      "cited_lines": ["src/app.py:10"],
      "cited_excerpt": "call_missing()",
      "verification_evidence": {
        "output": "NameError: name call_missing is not defined"
      }
    }
  ],
  "summary": "Verification evidence missing command field."
}')
_VE_NO_CMD_EXIT=0
_VE_NO_CMD_PLUGIN_ROOT=$(mktemp -d)
mkdir -p "$_VE_NO_CMD_PLUGIN_ROOT/contracts"
touch "$_VE_NO_CMD_PLUGIN_ROOT/contracts/absence-claim-enforcement-v1"
CLAUDE_PLUGIN_ROOT="$_VE_NO_CMD_PLUGIN_ROOT" bash "$SCRIPT" code-review-dispatch "$_VE_NO_CMD_FILE" >/dev/null 2>&1 || _VE_NO_CMD_EXIT=$?
rm -rf "$_VE_NO_CMD_PLUGIN_ROOT"
assert_ne \
    "test_verification_evidence_missing_command_field_rejected: exits non-zero when command missing" \
    "0" \
    "$_VE_NO_CMD_EXIT"

assert_pass_if_clean "test_verification_evidence_missing_command_field_rejected"

# test_verification_evidence_missing_output_field_rejected
# Given: finding with verification_evidence present but missing the 'output' sub-field.
# When:  validate-review-output.sh code-review-dispatch runs (any mode).
# Then:  exits non-zero (malformed verification_evidence is invalid).
echo ""
echo "--- test_verification_evidence_missing_output_field_rejected ---"
_snapshot_fail

_VE_NO_OUT_FILE=$(write_fixture "ve_missing_output.json" '{
  "findings": [
    {
      "severity": "minor",
      "category": "correctness",
      "description": "The config key does not exist in the registry",
      "file": "src/config.py",
      "cited_lines": ["src/config.py:5"],
      "cited_excerpt": "value = registry[\"missing_key\"]",
      "verification_evidence": {
        "command": "python3 -c \"from src.config import registry; print(registry)\""
      }
    }
  ],
  "summary": "Verification evidence missing output field."
}')
_VE_NO_OUT_EXIT=0
_VE_NO_OUT_PLUGIN_ROOT=$(mktemp -d)
mkdir -p "$_VE_NO_OUT_PLUGIN_ROOT/contracts"
touch "$_VE_NO_OUT_PLUGIN_ROOT/contracts/absence-claim-enforcement-v1"
CLAUDE_PLUGIN_ROOT="$_VE_NO_OUT_PLUGIN_ROOT" bash "$SCRIPT" code-review-dispatch "$_VE_NO_OUT_FILE" >/dev/null 2>&1 || _VE_NO_OUT_EXIT=$?
rm -rf "$_VE_NO_OUT_PLUGIN_ROOT"
assert_ne \
    "test_verification_evidence_missing_output_field_rejected: exits non-zero when output missing" \
    "0" \
    "$_VE_NO_OUT_EXIT"

assert_pass_if_clean "test_verification_evidence_missing_output_field_rejected"

# test_anchors_json_valid_structure
# Given: plugins/dso/docs/contracts/absence-claim-anchors.json exists.
# When:  loaded via python3 and structure validated.
# Then:  exits 0 — valid JSON with 'anchors' key containing >= 14 patterns.
# RED: fails before S1 T2 creates the JSON file.
echo ""
echo "--- test_anchors_json_valid_structure ---"
_snapshot_fail

_ANCHORS_JSON="$PLUGIN_ROOT/plugins/dso/docs/contracts/absence-claim-anchors.json"
_ANCHORS_EXIT=0
python3 -c "
import json, sys
try:
    with open('$_ANCHORS_JSON') as f:
        d = json.load(f)
    assert 'anchors' in d, 'missing anchors key'
    assert isinstance(d['anchors'], list), 'anchors must be a list'
    assert len(d['anchors']) >= 14, f'expected >= 14 anchors, got {len(d[\"anchors\"])}'
    sys.exit(0)
except (FileNotFoundError, json.JSONDecodeError, AssertionError) as e:
    print(f'FAIL: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null || _ANCHORS_EXIT=$?
assert_eq \
    "test_anchors_json_valid_structure: absence-claim-anchors.json is valid JSON with >= 14 anchors" \
    "0" \
    "$_ANCHORS_EXIT"

assert_pass_if_clean "test_anchors_json_valid_structure"

# test_anchors_json_missing_or_malformed_fails_closed
# AC amendment: when absence-claim-anchors.json is absent or malformed,
# validate-review-output.sh exits non-zero with a clear stderr message.
# RED: fails before S1 T4 implements the fail-closed anchor-load behavior.
echo ""
echo "--- test_anchors_json_missing_or_malformed_fails_closed ---"
_snapshot_fail

_ABSENT_ANCHORS_PLUGIN_ROOT=$(mktemp -d)
# Empty temp dir — anchors JSON does not exist inside it.
# Use DSO_ANCHORS_PLUGIN_ROOT (not CLAUDE_PLUGIN_ROOT) so that sentinel and
# anchors roots can be controlled independently (T4 separation).
_ABSENT_ANCHORS_FILE=$(write_fixture "absence_trigger_for_failclosed.json" '{
  "findings": [
    {
      "severity": "minor",
      "category": "correctness",
      "description": "The referenced symbol does not exist",
      "file": "src/app.py",
      "cited_lines": ["src/app.py:1"],
      "cited_excerpt": "from missing import symbol"
    }
  ],
  "summary": "Absence claim, anchors file absent from plugin root."
}')
_ABSENT_EXIT=0
DSO_ANCHORS_PLUGIN_ROOT="$_ABSENT_ANCHORS_PLUGIN_ROOT" bash "$SCRIPT" code-review-dispatch "$_ABSENT_ANCHORS_FILE" >/dev/null 2>&1 || _ABSENT_EXIT=$?
rm -rf "$_ABSENT_ANCHORS_PLUGIN_ROOT"
assert_ne \
    "test_anchors_json_missing_or_malformed_fails_closed: exits non-zero when anchors JSON absent" \
    "0" \
    "$_ABSENT_EXIT"

assert_pass_if_clean "test_anchors_json_missing_or_malformed_fails_closed"

print_summary
