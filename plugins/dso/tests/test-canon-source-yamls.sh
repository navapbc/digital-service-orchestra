#!/usr/bin/env bash
# tests/test-canon-source-yamls.sh
# Behavioral tests for 6 federal-style canon YAML entries.
#
# Covers story cce1-bfd8-a134-4f18, task edfd-57a0-9dca-4acb.
# DDs tested:
#   dd-1: canon entries from USWDS, GOV.UK, VA.gov, 18F, FPL, CDC exist with stable rule_ids
#   dd-3: each canon entry carries a hard_constraint boolean
#
# Test plan:
#   1. All 6 required canon YAML files exist
#   2. Each YAML is valid YAML (parseable)
#   3. Each YAML has domain: canon
#   4. Each YAML has source provenance (url, retrieval_date, license, version_pin)
#   5. hard_constraint:true entries exist (errors/validation rules)
#   6. hard_constraint:false entries exist (stylistic rules)
#   7. rule_ids are namespaced per source prefix
#   8. Full corpus validates via check-corpus-schema.py

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

CANON_DIR="$_PLUGIN_ROOT/data/ui-reference/canon"
VALIDATOR="$_PLUGIN_ROOT/scripts/check-corpus-schema.py"
SCHEMA="$_PLUGIN_ROOT/data/ui-reference/_schema.yaml"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== canon source YAML behavioral tests ==="

# Required file list
REQUIRED_FILES=(
    "uswds-forms"
    "govuk-errors-forms"
    "vagov-error-anatomy"
    "eighteen-f-content"
    "federal-plain-language"
    "cdc-reading-level"
)

# ---------------------------------------------------------------------------
# Test 1: All 6 required canon YAML files exist
# ---------------------------------------------------------------------------
echo ""
echo "--- test 1: all 6 canon YAML files exist ---"
all_exist=true
for f in "${REQUIRED_FILES[@]}"; do
    if [[ -f "$CANON_DIR/${f}.yaml" ]]; then
        pass "exists: ${f}.yaml"
    else
        fail "missing: $CANON_DIR/${f}.yaml"
        all_exist=false
    fi
done

if [[ "$all_exist" == "false" ]]; then
    echo "TOTAL: $PASS passed, $FAIL failed"
    exit 1
fi

# ---------------------------------------------------------------------------
# Test 2: Each YAML parses as valid YAML
# ---------------------------------------------------------------------------
echo ""
echo "--- test 2: each YAML parses as valid YAML ---"
for f in "${REQUIRED_FILES[@]}"; do
    path="$CANON_DIR/${f}.yaml"
    if python3 -c "import yaml; yaml.safe_load(open('$path'))" 2>/dev/null; then
        pass "valid YAML: ${f}.yaml"
    else
        fail "YAML parse error: ${f}.yaml"
    fi
done

# ---------------------------------------------------------------------------
# Test 3: Each YAML declares domain: canon
# ---------------------------------------------------------------------------
echo ""
echo "--- test 3: each YAML declares domain: canon ---"
for f in "${REQUIRED_FILES[@]}"; do
    path="$CANON_DIR/${f}.yaml"
    result=$(python3 -c "
import yaml, sys
d = yaml.safe_load(open('$path'))
dom = d.get('domain', '')
if dom == 'canon' or 'canon' in (dom if isinstance(dom, list) else []):
    print('ok')
else:
    print(f'got: {dom}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)
    if [[ "$result" == "ok" ]]; then
        pass "domain==canon: ${f}.yaml"
    else
        fail "domain!=canon: ${f}.yaml"
    fi
done

# ---------------------------------------------------------------------------
# Test 4: Each YAML has source provenance (url, retrieval_date, license, version_pin)
# ---------------------------------------------------------------------------
echo ""
echo "--- test 4: each YAML has source provenance fields ---"
for f in "${REQUIRED_FILES[@]}"; do
    path="$CANON_DIR/${f}.yaml"
    result=$(python3 -c "
import yaml, sys
d = yaml.safe_load(open('$path'))
src = d.get('source', None)
if not isinstance(src, dict):
    print(f'source is not a dict: {type(src).__name__}', file=sys.stderr)
    sys.exit(1)
missing = [k for k in ['url', 'retrieval_date', 'license', 'version_pin'] if k not in src]
if missing:
    print(f'missing source keys: {missing}', file=sys.stderr)
    sys.exit(1)
print('ok')
" 2>/dev/null)
    if [[ "$result" == "ok" ]]; then
        pass "source provenance complete: ${f}.yaml"
    else
        fail "source provenance incomplete: ${f}.yaml"
    fi
done

# ---------------------------------------------------------------------------
# Test 5: hard_constraint:true entries exist in the corpus
# ---------------------------------------------------------------------------
echo ""
echo "--- test 5: hard_constraint:true entries exist ---"
if grep -rq 'hard_constraint: true' "$CANON_DIR/"; then
    pass "hard_constraint:true found in canon corpus"
else
    fail "hard_constraint:true NOT found in canon corpus"
fi

# ---------------------------------------------------------------------------
# Test 6: hard_constraint:false entries exist in the corpus
# ---------------------------------------------------------------------------
echo ""
echo "--- test 6: hard_constraint:false entries exist ---"
if grep -rq 'hard_constraint: false' "$CANON_DIR/"; then
    pass "hard_constraint:false found in canon corpus"
else
    fail "hard_constraint:false NOT found in canon corpus"
fi

# ---------------------------------------------------------------------------
# Test 7: rule_ids are namespaced per source prefix
# ---------------------------------------------------------------------------
echo ""
echo "--- test 7: rule_ids are namespaced per source prefix ---"

declare -A PREFIXES=(
    ["uswds-forms"]="uswds-forms\\."
    ["govuk-errors-forms"]="govuk\\."
    ["vagov-error-anatomy"]="vagov\\."
    ["eighteen-f-content"]="eighteen-f\\."
    ["federal-plain-language"]="fpl\\."
    ["cdc-reading-level"]="cdc\\."
)

for f in "${REQUIRED_FILES[@]}"; do
    path="$CANON_DIR/${f}.yaml"
    prefix="${PREFIXES[$f]}"
    if grep -qE "$prefix" "$path"; then
        pass "rule_id namespace '${prefix//\\/}' found in ${f}.yaml"
    else
        fail "rule_id namespace '${prefix//\\/}' NOT found in ${f}.yaml"
    fi
done

# ---------------------------------------------------------------------------
# Test 8: canon directory validates via check-corpus-schema.py
# ---------------------------------------------------------------------------
echo ""
echo "--- test 8: canon directory validates via check-corpus-schema.py ---"
if python3 "$VALIDATOR" "$CANON_DIR" --schema "$SCHEMA" >/dev/null 2>&1; then
    pass "canon directory validates clean via check-corpus-schema.py"
else
    fail "canon directory failed schema validation"
    python3 "$VALIDATOR" "$CANON_DIR" --schema "$SCHEMA" 2>&1 | sed 's/^/    /'
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
