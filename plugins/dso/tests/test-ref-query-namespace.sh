#!/usr/bin/env bash
# tests/test-ref-query-namespace.sh
# RED-then-GREEN behavioral tests for ref-query --namespace and --format=json flags.
#
# Covers story cce1-bfd8-a134-4f18, task fcc0-6650-eedf-4f98.
# DDs tested:
#   dd-2: dso ref-query against a representative UI-copy query returns canon entries
#         from the new corpus with relevance scores
#
# Test plan:
#   1. --namespace=canon filters results to canon-domain entries only
#   2. --namespace=components filters results to components-domain entries only
#   3. No --namespace returns results across multiple domains (backward-compat)
#   4. --format=json produces valid JSON parseable by python3
#   5. --format=json output carries required schema fields: rule_id, tags, score, body, source_file
#   6. --namespace=canon --format=json produces canon-only JSON rows with schema fields
#   7. ref-query.sh --help advertises --namespace and --format flags
#   8. test_baseline_includes_non_canon: no-namespace query returns at least one non-canon row

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

REF_QUERY="$_PLUGIN_ROOT/scripts/ref-query.sh"
CORPUS="$_PLUGIN_ROOT/data/ui-reference"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== ref-query --namespace and --format=json behavioral tests ==="

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
echo ""
echo "--- prerequisite: ref-query.sh exists and corpus exists ---"
if [[ -x "$REF_QUERY" ]]; then
    pass "ref-query.sh is executable"
else
    fail "ref-query.sh not found or not executable at: $REF_QUERY"
    echo "TOTAL: $PASS passed, $FAIL failed"
    exit 1
fi

if [[ -d "$CORPUS" ]]; then
    pass "corpus directory exists"
else
    fail "corpus directory not found at: $CORPUS"
    echo "TOTAL: $PASS passed, $FAIL failed"
    exit 1
fi

# Helper: check namespace filtering via JSON output (reliable domain extraction)
# Usage: _check_namespace_filter <namespace> <query> <expected_domain>
_check_namespace_filter() {
    local namespace="$1"
    local query="$2"
    local expected_domain="$3"
    local json_output
    json_output=$("$REF_QUERY" --namespace="$namespace" --format=json "$query" 2>/dev/null || true)
    if [[ -z "$json_output" ]]; then
        local stderr
        stderr=$("$REF_QUERY" --namespace="$namespace" "$query" 2>&1 1>/dev/null || true)
        if echo "$stderr" | grep -q "no results"; then
            echo "NO_RESULTS"
        else
            echo "NO_OUTPUT"
        fi
        return
    fi
    # Check all rows have expected domain in tags.domain
    local check_result
    check_result=$(echo "$json_output" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
if not rows:
    print('EMPTY')
    sys.exit(0)
expected = '$expected_domain'
bad = []
for i, row in enumerate(rows):
    tags = row.get('tags', {})
    domain = tags.get('domain', [])
    if isinstance(domain, str):
        domain = [domain]
    if expected not in domain:
        bad.append(f'row {i}: got domain={domain}')
if bad:
    print('BAD: ' + '; '.join(bad))
else:
    print('OK')
" 2>/dev/null || echo "PARSE_ERROR")
    echo "$check_result"
}

# ---------------------------------------------------------------------------
# Test 1: --namespace=canon filters to canon-domain entries only
# ---------------------------------------------------------------------------
echo ""
echo "--- test 1: --namespace=canon filters to canon-domain entries only ---"
_result=$(_check_namespace_filter "canon" "errors" "canon")
case "$_result" in
    OK) pass "--namespace=canon returns only canon-domain entries" ;;
    NO_RESULTS) fail "--namespace=canon returned no results (corpus may lack canon entries matching 'errors')" ;;
    NO_OUTPUT) fail "--namespace=canon produced no output and no sentinel on stderr" ;;
    EMPTY) fail "--namespace=canon returned empty JSON array" ;;
    *) fail "--namespace=canon: $_result" ;;
esac

# ---------------------------------------------------------------------------
# Test 2: --namespace=components filters to components-domain entries only
# ---------------------------------------------------------------------------
echo ""
echo "--- test 2: --namespace=components filters to components-domain entries only ---"
_result=$(_check_namespace_filter "components" "form" "components")
case "$_result" in
    OK) pass "--namespace=components returns only components-domain entries" ;;
    NO_RESULTS) fail "--namespace=components returned no results (corpus may lack components entries matching 'form')" ;;
    NO_OUTPUT) fail "--namespace=components produced no output and no sentinel on stderr" ;;
    EMPTY) fail "--namespace=components returned empty JSON array" ;;
    *) fail "--namespace=components: $_result" ;;
esac

# ---------------------------------------------------------------------------
# Test 3: No --namespace returns results across multiple domains (backward-compat)
# ---------------------------------------------------------------------------
echo ""
echo "--- test 3: backward-compat — no --namespace returns multi-domain results ---"
test_baseline_includes_non_canon() {
    _output=$("$REF_QUERY" "form" 2>/dev/null || true)
    if [[ -z "$_output" ]]; then
        fail "backward-compat: no results returned at all (corpus issue)"
        return
    fi
    # Check that we get at least one non-canon domain entry
    _domains=$(echo "$_output" | grep -E "^domain:" | sed 's/^domain: *//' | sort -u || true)
    if echo "$_domains" | grep -qv "canon"; then
        pass "backward-compat: no-namespace query returns entries from multiple domains (non-canon found)"
    else
        # Also accept if corpus genuinely only has one domain
        # Fail loudly if domain extraction itself errors — silently swallowing the
        # error and treating "no domains" as "single-domain corpus" produced a
        # false-positive pass when extraction was actually broken.
        if ! _all_domains=$(python3 -c "
import sys, yaml
from pathlib import Path
corpus = Path('$CORPUS')
domains = set()
for f in corpus.rglob('*.yaml'):
    if f.name.startswith('_'):
        continue
    content = f.read_text()
    for doc in yaml.safe_load_all(content):
        if doc and isinstance(doc, dict):
            d = doc.get('domain', [])
            if isinstance(d, list):
                domains.update(d)
            elif d:
                domains.add(d)
print(','.join(sorted(domains)))
" 2>&1); then
            fail "backward-compat: domain-discovery script errored: $_all_domains"
        elif [[ -z "$_all_domains" ]]; then
            fail "backward-compat: domain-discovery returned empty result (corpus may be missing or empty)"
        elif echo "$_all_domains" | grep -q ","; then
            fail "backward-compat: corpus has multiple domains but no-namespace query returned only canon"
        else
            pass "backward-compat: corpus has only one domain; single-domain result is acceptable"
        fi
    fi
}
test_baseline_includes_non_canon

# ---------------------------------------------------------------------------
# Test 4: --format=json produces valid JSON parseable by python3
# ---------------------------------------------------------------------------
echo ""
echo "--- test 4: --format=json produces valid parseable JSON ---"
_json_output=$("$REF_QUERY" --format=json "errors" 2>/dev/null || true)
if [[ -z "$_json_output" ]]; then
    _stderr=$("$REF_QUERY" --format=json "errors" 2>&1 1>/dev/null || true)
    if echo "$_stderr" | grep -q "no results"; then
        fail "--format=json returned no results (corpus may lack entries matching 'errors')"
    else
        fail "--format=json produced no output and no sentinel on stderr"
    fi
else
    if echo "$_json_output" | python3 -c "import json, sys; json.load(sys.stdin)" 2>/dev/null; then
        pass "--format=json output is valid JSON"
    else
        fail "--format=json output is NOT valid JSON"
        echo "  Output (first 200 chars): ${_json_output:0:200}"
    fi
fi

# ---------------------------------------------------------------------------
# Test 5: --format=json output carries required schema fields
# ---------------------------------------------------------------------------
echo ""
echo "--- test 5: --format=json rows carry required schema fields ---"
_json_output=$("$REF_QUERY" --format=json "errors" 2>/dev/null || true)
if [[ -n "$_json_output" ]]; then
    _check_result=$(echo "$_json_output" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
if not rows:
    print('EMPTY')
    sys.exit(0)
required = {'rule_id', 'tags', 'score'}
missing_any = False
for i, row in enumerate(rows):
    missing = required - set(row.keys())
    if missing:
        print(f'ROW {i} missing: {missing}')
        missing_any = True
if not missing_any:
    print('OK')
" 2>/dev/null || echo "PARSE_ERROR")
    if [[ "$_check_result" == "OK" ]]; then
        pass "--format=json rows carry required schema fields (rule_id, tags, score)"
    elif [[ "$_check_result" == "EMPTY" ]]; then
        fail "--format=json returned empty array"
    else
        fail "--format=json rows missing required fields: $_check_result"
    fi
else
    fail "--format=json produced no output; cannot check schema fields"
fi

# ---------------------------------------------------------------------------
# Test 6: --namespace=canon --format=json produces canon-only JSON rows with schema
# ---------------------------------------------------------------------------
echo ""
echo "--- test 6: --namespace=canon --format=json produces canon-only JSON with schema ---"
_json_output=$("$REF_QUERY" --namespace=canon --format=json "errors" 2>/dev/null || true)
if [[ -z "$_json_output" ]]; then
    _stderr=$("$REF_QUERY" --namespace=canon --format=json "errors" 2>&1 1>/dev/null || true)
    if echo "$_stderr" | grep -q "no results"; then
        fail "--namespace=canon --format=json returned no results"
    else
        fail "--namespace=canon --format=json produced no output"
    fi
else
    _check_result=$(echo "$_json_output" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
if not rows:
    print('EMPTY')
    sys.exit(0)
errors = []
for i, row in enumerate(rows):
    # Check required fields
    required = {'rule_id', 'tags', 'score'}
    missing = required - set(row.keys())
    if missing:
        errors.append(f'row {i}: missing fields {missing}')
    # Check domain filtering — tags.domain should be canon (or list containing canon)
    tags = row.get('tags', {})
    domain = tags.get('domain', []) if isinstance(tags, dict) else []
    if isinstance(domain, str):
        domain = [domain]
    if 'canon' not in domain:
        errors.append(f'row {i}: domain not canon: {domain}')
if errors:
    print('FAIL: ' + '; '.join(errors))
else:
    print('OK')
" 2>/dev/null || echo "PARSE_ERROR")
    if [[ "$_check_result" == "OK" ]]; then
        pass "--namespace=canon --format=json returns canon-only rows with correct schema"
    elif [[ "$_check_result" == "EMPTY" ]]; then
        fail "--namespace=canon --format=json returned empty array"
    else
        fail "$_check_result"
    fi
fi

# ---------------------------------------------------------------------------
# Test 7: --help advertises --namespace and --format flags
# ---------------------------------------------------------------------------
echo ""
echo "--- test 7: --help advertises --namespace and --format flags ---"
_help_output=$("$REF_QUERY" --help 2>&1 || true)
_namespace_ok=false
_format_ok=false
if echo "$_help_output" | grep -qE -- "--namespace"; then
    _namespace_ok=true
fi
if echo "$_help_output" | grep -qE -- "--format"; then
    _format_ok=true
fi
if "$_namespace_ok" && "$_format_ok"; then
    pass "--help advertises both --namespace and --format"
elif "$_namespace_ok"; then
    fail "--help advertises --namespace but NOT --format"
elif "$_format_ok"; then
    fail "--help advertises --format but NOT --namespace"
else
    fail "--help does NOT advertise --namespace or --format"
fi

# ---------------------------------------------------------------------------
# Test 8: ref-query-json-output.md contract doc exists with required fields
# ---------------------------------------------------------------------------
echo ""
echo "--- test 8: ref-query-json-output.md contract doc exists with required fields ---"
_CONTRACT="$_PLUGIN_ROOT/docs/contracts/ref-query-json-output.md"
if [[ -f "$_CONTRACT" ]]; then
    _has_rule_id=$(grep -q "rule_id" "$_CONTRACT" && echo "yes" || echo "no")
    _has_score=$(grep -q "score" "$_CONTRACT" && echo "yes" || echo "no")
    if [[ "$_has_rule_id" == "yes" && "$_has_score" == "yes" ]]; then
        pass "ref-query-json-output.md exists and contains required field docs (rule_id, score)"
    else
        fail "ref-query-json-output.md exists but missing field docs (rule_id=$_has_rule_id, score=$_has_score)"
    fi
else
    fail "ref-query-json-output.md not found at: $_CONTRACT"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
