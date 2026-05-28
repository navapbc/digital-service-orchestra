#!/usr/bin/env bash
# tests/test-corpus-schema-canon.sh
# RED-then-GREEN behavioral tests for canon domain + hard_constraint schema extension.
#
# Covers story cce1-bfd8-a134-4f18, task 5ad4-6e86-8fce-4293.
# DDs tested:
#   dd-3: each canon entry carries a hard_constraint boolean
#   dd-5: hard_constraint=true immutability semantic is defined and enforced
#   dd-6: unit tests written and passing for all new or modified logic
#
# Test plan:
#   1. Canon YAML with hard_constraint:true validates clean (GREEN)
#   2. _overview.yaml sibling is skipped by check-corpus-schema.py (GREEN)
#   3. Backward-compat: existing non-canon YAML validates clean (GREEN)
#   4. Unknown field 'hard_constraint' in a schema WITHOUT the extension fails (RED gate)
#   5. Unknown domain 'canon' in a schema WITHOUT the extension fails (RED gate)

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/../../plugins/dso" && pwd)"

VALIDATOR="$_PLUGIN_ROOT/scripts/check-corpus-schema.py"
SCHEMA="$_PLUGIN_ROOT/data/ui-reference/_schema.yaml"
REAL_CORPUS="$_PLUGIN_ROOT/data/ui-reference"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== corpus schema canon + hard_constraint tests ==="

# ---------------------------------------------------------------------------
# Prerequisite: validator script exists
# ---------------------------------------------------------------------------
echo ""
echo "--- prerequisite: validator exists ---"
if [[ -f "$VALIDATOR" ]]; then
    pass "check-corpus-schema.py exists"
else
    fail "check-corpus-schema.py not found at: $VALIDATOR"
    echo "TOTAL: $PASS passed, $FAIL failed"
    exit 1
fi

# ---------------------------------------------------------------------------
# Helper: create a temp fixture directory with the real schema
# ---------------------------------------------------------------------------
_make_fixture_dir() {
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/canon-schema-test.XXXXXX")
    cp "$SCHEMA" "$tmpdir/_schema.yaml"
    echo "$tmpdir"
}

# ---------------------------------------------------------------------------
# Test 1: canon YAML with hard_constraint:true validates clean
# ---------------------------------------------------------------------------
echo ""
echo "--- test 1: canon YAML with hard_constraint:true validates clean ---"
_tmpdir=$(_make_fixture_dir)
cat > "$_tmpdir/canon-entry.yaml" <<'YAML'
id: CANON-001
title: Hard constraint canon rule
domain: canon
hard_constraint: true
YAML

if python3 "$VALIDATOR" "$_tmpdir" >/dev/null 2>&1; then
    pass "canon YAML with hard_constraint:true validates clean"
else
    fail "canon YAML with hard_constraint:true unexpectedly failed validation"
    python3 "$VALIDATOR" "$_tmpdir" 2>&1 | sed 's/^/    /'
fi
rm -rf "$_tmpdir"

# ---------------------------------------------------------------------------
# Test 2: canon YAML with hard_constraint:false validates clean
# ---------------------------------------------------------------------------
echo ""
echo "--- test 2: canon YAML with hard_constraint:false validates clean ---"
_tmpdir=$(_make_fixture_dir)
cat > "$_tmpdir/canon-entry-false.yaml" <<'YAML'
id: CANON-002
title: Non-hard-constraint canon rule
domain: canon
hard_constraint: false
YAML

if python3 "$VALIDATOR" "$_tmpdir" >/dev/null 2>&1; then
    pass "canon YAML with hard_constraint:false validates clean"
else
    fail "canon YAML with hard_constraint:false unexpectedly failed validation"
    python3 "$VALIDATOR" "$_tmpdir" 2>&1 | sed 's/^/    /'
fi
rm -rf "$_tmpdir"

# ---------------------------------------------------------------------------
# Test 3: _overview.yaml sibling is skipped (not treated as corpus entry)
# ---------------------------------------------------------------------------
echo ""
echo "--- test 3: _overview.yaml is skipped by validator ---"
_tmpdir=$(_make_fixture_dir)
# Write a canon entry that is valid
cat > "$_tmpdir/canon-entry.yaml" <<'YAML'
id: CANON-003
title: Another canon rule
domain: canon
hard_constraint: true
YAML
# Write an _overview.yaml that would fail validation if parsed (missing required fields)
cat > "$_tmpdir/_overview.yaml" <<'YAML'
# This is a human-readable overview file, not a corpus entry.
description: >
  Overview of the canon namespace.
YAML

if python3 "$VALIDATOR" "$_tmpdir" >/dev/null 2>&1; then
    pass "_overview.yaml is skipped (validator exits 0)"
else
    fail "_overview.yaml was NOT skipped (validator failed when it should have skipped it)"
    python3 "$VALIDATOR" "$_tmpdir" 2>&1 | sed 's/^/    /'
fi
rm -rf "$_tmpdir"

# ---------------------------------------------------------------------------
# Test 4: Backward-compat — existing non-canon domains still validate
# ---------------------------------------------------------------------------
echo ""
echo "--- test 4: backward-compat regression (non-canon domains) ---"
_tmpdir=$(_make_fixture_dir)
cat > "$_tmpdir/components-entry.yaml" <<'YAML'
id: COMP-001
title: USWDS Button test entry
domain: components
component: uswds-v3
action: design
YAML

if python3 "$VALIDATOR" "$_tmpdir" >/dev/null 2>&1; then
    pass "backward-compat: non-canon YAML (components domain) validates clean"
else
    fail "backward-compat: non-canon YAML unexpectedly failed validation"
    python3 "$VALIDATOR" "$_tmpdir" 2>&1 | sed 's/^/    /'
fi
rm -rf "$_tmpdir"

# ---------------------------------------------------------------------------
# Test 5: Backward-compat — real corpus directory validates clean
# ---------------------------------------------------------------------------
echo ""
echo "--- test 5: real corpus directory validates clean ---"
if [[ -d "$REAL_CORPUS" ]]; then
    if python3 "$VALIDATOR" "$REAL_CORPUS" >/dev/null 2>&1; then
        pass "real corpus validates clean with updated schema"
    else
        fail "real corpus failed validation after schema update"
        python3 "$VALIDATOR" "$REAL_CORPUS" 2>&1 | sed 's/^/    /'
    fi
else
    fail "real corpus directory not found at: $REAL_CORPUS"
fi

# ---------------------------------------------------------------------------
# Test 6: Schema has 'hard_constraint' in optional_fields
# ---------------------------------------------------------------------------
echo ""
echo "--- test 6: schema file has hard_constraint in optional_fields ---"
if python3 -c "
import yaml, sys
s = yaml.safe_load(open('$SCHEMA'))
assert 'hard_constraint' in s.get('optional_fields', []), \
    'hard_constraint not found in optional_fields'
print('ok')
" 2>/dev/null | grep -q "ok"; then
    pass "schema has 'hard_constraint' in optional_fields"
else
    fail "schema does NOT have 'hard_constraint' in optional_fields"
fi

# ---------------------------------------------------------------------------
# Test 7: Schema has 'canon' in tag_vocabulary.domain
# ---------------------------------------------------------------------------
echo ""
echo "--- test 7: schema file has canon in tag_vocabulary.domain ---"
if python3 -c "
import yaml, sys
s = yaml.safe_load(open('$SCHEMA'))
domains = s.get('tag_vocabulary', {}).get('domain', [])
assert 'canon' in domains, 'canon not found in tag_vocabulary.domain'
print('ok')
" 2>/dev/null | grep -q "ok"; then
    pass "schema has 'canon' in tag_vocabulary.domain"
else
    fail "schema does NOT have 'canon' in tag_vocabulary.domain"
fi

# ---------------------------------------------------------------------------
# Test 8: check-corpus-schema.py _SKIP_NAMES includes _overview.yaml
# ---------------------------------------------------------------------------
echo ""
echo "--- test 8: check-corpus-schema.py skips _overview.yaml by name ---"
if grep -qE "'_overview\.yaml'|\"_overview\.yaml\"" "$_PLUGIN_ROOT/scripts/check-corpus-schema.py"; then
    pass "check-corpus-schema.py _SKIP_NAMES includes _overview.yaml"
else
    fail "check-corpus-schema.py does NOT include _overview.yaml in _SKIP_NAMES"
fi

# ---------------------------------------------------------------------------
# Test 9: ref-query.py SKIP_NAMES includes _overview.yaml
# ---------------------------------------------------------------------------
echo ""
echo "--- test 9: ref-query.py SKIP_NAMES includes _overview.yaml ---"
if grep -qE "'_overview\.yaml'|\"_overview\.yaml\"" "$_PLUGIN_ROOT/scripts/ref-query.py"; then
    pass "ref-query.py SKIP_NAMES includes _overview.yaml"
else
    fail "ref-query.py does NOT include _overview.yaml in SKIP_NAMES"
fi

# ---------------------------------------------------------------------------
# Test 10: immutability contract doc exists and contains verbatim semantic
# ---------------------------------------------------------------------------
echo ""
echo "--- test 10: ui-reference-corpus-schema.md has immutability semantic ---"
_CONTRACT="$_PLUGIN_ROOT/docs/contracts/ui-reference-corpus-schema.md"
if [[ -f "$_CONTRACT" ]] && grep -q "immutable to coordination-pass mutation" "$_CONTRACT"; then
    pass "contract doc exists and contains verbatim immutability semantic"
else
    fail "contract doc missing or does not contain 'immutable to coordination-pass mutation'"
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
