#!/usr/bin/env bash
# tests/scripts/test-fp-recovery-ledger-write.sh
#
# Behavioral tests for fp-recovery-ledger-write.sh (epic 7412 / task 7eff).
# The ledger writer is invoked by the fp-recovery skill at clearance to record
# the ORIGINAL blocking finding that was overridden as a false positive, plus a
# structured root-cause category and the human rationale — the durable, queryable
# FP audit trail that the 2026-06-08 FP-analysis found missing.
#
# These assert OBSERVABLE BEHAVIOR (the JSONL the script appends, its exit codes),
# not source content. Usage: bash tests/scripts/test-fp-recovery-ledger-write.sh

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/ci/fp-recovery-ledger-write.sh"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

# Each test gets an isolated ledger path under the per-test TMPDIR (CLAUDE.md mktemp rule).
_new_ledger() { mktemp "${TMPDIR:-/tmp}/fp-ledger.XXXXXX"; }

# ---------------------------------------------------------------------------
# A single cleared FP appends exactly one valid JSON line carrying the original
# finding's severity/class/location/summary, the structured category, and rationale.
# ---------------------------------------------------------------------------
t_writes_one_record_with_original_finding() {
    local _ledger; _ledger="$(_new_ledger)"; : > "$_ledger"
    DSO_FP_LEDGER_PATH="$_ledger" bash "$SCRIPT" \
        --pr 712 \
        --neutral-reviewer-hash d9392797 \
        --fp-category T5 \
        --fp-rationale "RETURN trap is the sole cleanup path; post-condition assertion IS the contract" \
        --original-severity critical \
        --original-class verification \
        --original-location "tests/scripts/test-merge-to-main-spent-classifier.sh:406" \
        --original-summary "existence-only assertion would pass even if trap removed" \
        >/dev/null 2>&1

    local _lines; _lines="$(wc -l < "$_ledger" | tr -d ' ')"
    assert_eq "t_ledger_one_line" "1" "$_lines"

    # Valid JSON + fields present (parse with python3, the project's JSON tool).
    local _ok
    _ok="$(python3 -c "
import json,sys
rec=json.loads(open('$_ledger').readline())
of=rec.get('original_finding',{})
ok = (rec.get('pr')==712
      and rec.get('fp_category')=='T5'
      and rec.get('schema','').startswith('fp-recovery-ledger/')
      and of.get('severity')=='critical'
      and of.get('class')=='verification'
      and of.get('location')=='tests/scripts/test-merge-to-main-spent-classifier.sh:406'
      and bool(rec.get('recorded_at'))
      and bool(of.get('fingerprint')))
print('yes' if ok else 'no')
" 2>&1)"
    assert_eq "t_ledger_fields_present" "yes" "$_ok"
}

# ---------------------------------------------------------------------------
# Append-only: a second clearance adds a second line, preserving the first.
# ---------------------------------------------------------------------------
t_append_only() {
    local _ledger; _ledger="$(_new_ledger)"; : > "$_ledger"
    for pr in 100 200; do
        DSO_FP_LEDGER_PATH="$_ledger" bash "$SCRIPT" \
            --pr "$pr" --fp-category T6 --fp-rationale "r" \
            --original-summary "s" >/dev/null 2>&1
    done
    local _lines; _lines="$(wc -l < "$_ledger" | tr -d ' ')"
    assert_eq "t_append_two_lines" "2" "$_lines"
    local _first_pr
    _first_pr="$(python3 -c "import json;print(json.loads(open('$_ledger').readline())['pr'])" 2>&1)"
    assert_eq "t_append_preserves_first" "100" "$_first_pr"
}

# ---------------------------------------------------------------------------
# Rationale/summary with JSON-hostile characters (quotes, backslashes) are safely
# encoded — the line must remain parseable JSON.
# ---------------------------------------------------------------------------
t_special_chars_safely_encoded() {
    local _ledger; _ledger="$(_new_ledger)"; : > "$_ledger"
    DSO_FP_LEDGER_PATH="$_ledger" bash "$SCRIPT" \
        --pr 5 --fp-category T3 \
        --fp-rationale 'has "double" quotes, a \backslash and a newline
second line' \
        --original-summary 'claims `x` is "wrong"' >/dev/null 2>&1
    local _ok
    _ok="$(python3 -c "import json;json.loads(open('$_ledger').readline());print('yes')" 2>&1)"
    assert_eq "t_special_chars_valid_json" "yes" "$_ok"
}

# ---------------------------------------------------------------------------
# Missing a required field (fp-category) → non-zero exit AND nothing appended.
# The ledger write is best-effort for the merge but must fail loudly so the skill
# notices a mis-call rather than silently dropping the audit record.
# ---------------------------------------------------------------------------
t_missing_required_fails_loud() {
    local _ledger; _ledger="$(_new_ledger)"; : > "$_ledger"
    local _rc=0
    DSO_FP_LEDGER_PATH="$_ledger" bash "$SCRIPT" \
        --pr 9 --fp-rationale "r" --original-summary "s" >/dev/null 2>&1 || _rc=$?
    assert_ne "t_missing_required_nonzero" "0" "$_rc"
    local _lines; _lines="$(wc -l < "$_ledger" | tr -d ' ')"
    assert_eq "t_missing_required_no_append" "0" "$_lines"
}

# ---------------------------------------------------------------------------
# Unknown fp-category is rejected (taxonomy guard) so the audit data stays queryable.
# ---------------------------------------------------------------------------
t_unknown_category_rejected() {
    local _ledger; _ledger="$(_new_ledger)"; : > "$_ledger"
    local _rc=0
    DSO_FP_LEDGER_PATH="$_ledger" bash "$SCRIPT" \
        --pr 9 --fp-category ZZZ --fp-rationale "r" --original-summary "s" >/dev/null 2>&1 || _rc=$?
    assert_ne "t_unknown_category_nonzero" "0" "$_rc"
}

# ---------------------------------------------------------------------------
# The ledger directory is created if absent (consuming projects have no docs/audits yet).
# ---------------------------------------------------------------------------
t_creates_missing_dir() {
    local _dir; _dir="$(mktemp -d "${TMPDIR:-/tmp}/fp-ledger-dir.XXXXXX")"
    local _ledger="$_dir/nested/sub/ledger.jsonl"
    DSO_FP_LEDGER_PATH="$_ledger" bash "$SCRIPT" \
        --pr 1 --fp-category T1 --fp-rationale "r" --original-summary "s" >/dev/null 2>&1
    assert_eq "t_creates_missing_dir" "yes" "$([ -f "$_ledger" ] && echo yes || echo no)"
}

t_writes_one_record_with_original_finding
t_append_only
t_special_chars_safely_encoded
t_missing_required_fails_loud
t_unknown_category_rejected
t_creates_missing_dir

print_summary
