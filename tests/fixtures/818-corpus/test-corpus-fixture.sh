#!/usr/bin/env bash
# tests/fixtures/818-corpus/test-corpus-fixture.sh
# RED tests for tests/fixtures/818-corpus/generate-corpus-fixture.sh
# These tests fail RED until generate-corpus-fixture.sh is implemented.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GENERATOR="$REPO_ROOT/tests/fixtures/818-corpus/generate-corpus-fixture.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

test_corpus_fixture_generates_valid_json() {
    # RED: generate-corpus-fixture.sh does not exist yet
    if [[ ! -f "$GENERATOR" ]]; then
        (( ++FAIL ))
        printf "FAIL: %s\n  expected: generate-corpus-fixture.sh to exist at %s\n  actual:   file not found\n" \
            "corpus_fixture_generates_valid_json" "$GENERATOR" >&2
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    local tmp_output="$tmpdir/sample-bugs.json"

    # Run with an overridden output path
    CORPUS_OUTPUT="$tmp_output" bash "$GENERATOR"
    local exit_code=$?
    assert_eq "generator exits 0" "0" "$exit_code"

    # Output must be valid JSON array
    if [[ -f "$tmp_output" ]]; then
        local is_valid
        is_valid=$(python3 -c "import json,sys; data=json.load(open('$tmp_output')); print('array' if isinstance(data,list) else 'not-array')" 2>/dev/null || echo "invalid")
        assert_eq "output is a JSON array" "array" "$is_valid"
    else
        (( ++FAIL ))
        printf "FAIL: %s\n  expected: output file at %s\n  actual:   file not created\n" \
            "corpus_fixture_generates_valid_json" "$tmp_output" >&2
    fi

    rm -rf "$tmpdir"
}

test_corpus_has_required_bug_fields() {
    # RED: generate-corpus-fixture.sh does not exist yet
    if [[ ! -f "$GENERATOR" ]]; then
        (( ++FAIL ))
        printf "FAIL: %s\n  expected: generate-corpus-fixture.sh to exist at %s\n  actual:   file not found\n" \
            "corpus_has_required_bug_fields" "$GENERATOR" >&2
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    local tmp_output="$tmpdir/sample-bugs.json"

    CORPUS_OUTPUT="$tmp_output" bash "$GENERATOR"

    if [[ -f "$tmp_output" ]]; then
        # Each record must have id, description, type, severity
        local missing_fields
        # shellcheck disable=SC2016
        missing_fields=$(python3 -c "
import json, sys
with open('$tmp_output') as f:
    data = json.load(f)
missing = []
for i, rec in enumerate(data):
    for field in ['id', 'description', 'type', 'severity']:
        if field not in rec:
            missing.append(f'record[{i}] missing field \"{field}\"')
if missing:
    print('\n'.join(missing[:5]))
else:
    print('ok')
" 2>/dev/null || echo "parse-error")

        assert_eq "all records have required fields" "ok" "$missing_fields"
    else
        (( ++FAIL ))
        printf "FAIL: %s\n  expected: output file created\n  actual:   file not found\n" \
            "corpus_has_required_bug_fields" >&2
    fi

    rm -rf "$tmpdir"
}

test_corpus_fixture_generates_valid_json
test_corpus_has_required_bug_fields

print_summary
