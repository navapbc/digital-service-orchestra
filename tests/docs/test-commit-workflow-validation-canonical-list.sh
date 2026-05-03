#!/usr/bin/env bash
# tests/docs/test-commit-workflow-validation-canonical-list.sh
#
# Architectural contract test (audit closeout for story ae24-9a90):
# Locks in the canonical Always-On vs Gated Hooks list documented in
# plugins/dso/docs/workflows/commit-workflow-validation.md.
#
# Why this is a doc-content test (narrow exception per behavioral testing
# standard rule 5): the canonical list IS the structural boundary. The
# documented invariants (which hooks are always-on, which are gated, the
# network-partition caveat) are what audit criteria A (no enforcement bypass)
# and B (no unnecessary friction) certify against. If the list silently
# regresses — a hook is dropped, miscategorized, or the caveat is stripped —
# the audit closeout becomes meaningless. This test fails loudly on any such
# regression.
#
# RED-first reasoning: before the canonical list landed in
# commit-workflow-validation.md (prior batch tasks 73af/6534/267e/b00e/0af7),
# the file had no "Always-On vs Gated Hooks" section, no enumerated hook
# names, and no network-partition caveat. Every assertion below would have
# failed in that prior state. The test is RED-relative-to-prior-state; it
# now passes against the documented invariants.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
ASSERT_LIB="$REPO_ROOT/tests/lib/assert.sh"
# shellcheck source=../lib/assert.sh
source "$ASSERT_LIB"

DOC="$REPO_ROOT/plugins/dso/docs/workflows/commit-workflow-validation.md"

if [[ ! -f "$DOC" ]]; then
    assert_eq "commit-workflow-validation.md exists" "present" "missing"
    print_summary
    exit 1
fi

content="$(< "$DOC")"

# ---------------------------------------------------------------------------
# test_section_header_present
#
# The "Always-On vs Gated Hooks" section header anchors the canonical list.
# Without the section, the rest of the contract has no documented home.
# ---------------------------------------------------------------------------
echo "=== test_section_header_present ==="

if grep -Eq '^##[[:space:]]+Always-On vs Gated Hooks' "$DOC"; then
    assert_eq "Always-On vs Gated Hooks section header" "present" "present"
else
    assert_eq "Always-On vs Gated Hooks section header" \
        "## Always-On vs Gated Hooks header line" \
        "section header missing"
fi

# ---------------------------------------------------------------------------
# test_always_on_hooks_canonical_list
#
# All 6 always-on hook names must be enumerated in the document. These hooks
# enforce structural invariants and run on every commit regardless of
# enforcement.strategy. Audit criterion A depends on this list being intact.
# ---------------------------------------------------------------------------
echo ""
echo "=== test_always_on_hooks_canonical_list ==="

ALWAYS_ON_HOOKS=(
    "check-portability.sh"
    "check-shim-refs.sh"
    "check-contract-schemas.sh"
    "check-referential-integrity.sh"
    "check-plugin-self-ref.sh"
    "pre-commit-enforcement-boundary-check.sh"
)

for hook in "${ALWAYS_ON_HOOKS[@]}"; do
    if [[ "$content" == *"$hook"* ]]; then
        assert_eq "always-on hook documented: $hook" "present" "present"
    else
        assert_eq "always-on hook documented: $hook" "present" "missing"
    fi
done

# ---------------------------------------------------------------------------
# test_gated_hooks_canonical_list
#
# All 3 gated hook names must be enumerated. These hooks honor
# enforcement.strategy and may be deferred to CI. Audit criterion B
# (no unnecessary friction) depends on this categorization being explicit.
# ---------------------------------------------------------------------------
echo ""
echo "=== test_gated_hooks_canonical_list ==="

GATED_HOOKS=(
    "pre-commit-test-gate.sh"
    "pre-commit-review-gate.sh"
    "pre-commit-test-quality-gate.sh"
)

for hook in "${GATED_HOOKS[@]}"; do
    if [[ "$content" == *"$hook"* ]]; then
        assert_eq "gated hook documented: $hook" "present" "present"
    else
        assert_eq "gated hook documented: $hook" "present" "missing"
    fi
done

# ---------------------------------------------------------------------------
# test_network_partition_caveat
#
# The network-partition caveat documents the residual risk when
# enforcement.strategy=ci is chosen. Without this caveat, operators may
# silently accept risk they did not consent to. Required for audit closeout.
# ---------------------------------------------------------------------------
echo ""
echo "=== test_network_partition_caveat ==="

# Look for "network partition" phrase combined with the strategy=ci risk
# context. Both must be present and reasonably co-located.
if grep -iq 'network partition' "$DOC"; then
    assert_eq "network partition phrase present" "present" "present"
else
    assert_eq "network partition phrase present" "present" "missing"
fi

# The caveat must explicitly tie the partition risk to enforcement.strategy=ci
caveat_context="$(python3 - "$DOC" <<'PYEOF'
import sys, re
content = open(sys.argv[1]).read()
# Find a window of text mentioning both "network partition" and "ci"
m = re.search(r'network partition.{0,500}', content, re.IGNORECASE | re.DOTALL)
if m and re.search(r'enforcement\.strategy\s*=\s*ci|strategy=ci', m.group(0), re.IGNORECASE):
    print("LINKED")
PYEOF
)"

if [[ "$caveat_context" == *"LINKED"* ]]; then
    assert_eq "network partition caveat linked to enforcement.strategy=ci" \
        "present" "present"
else
    assert_eq "network partition caveat linked to enforcement.strategy=ci" \
        "caveat tying network partition risk to enforcement.strategy=ci" \
        "caveat exists but is not linked to enforcement.strategy=ci"
fi

# ---------------------------------------------------------------------------
# test_hook_counts_explicit
#
# The section header sub-headings should call out the counts (6 always-on,
# 3 gated). This is the documented contract — if a hook is added or removed
# without updating the count, the categorization drifts silently.
# ---------------------------------------------------------------------------
echo ""
echo "=== test_hook_counts_explicit ==="

if grep -Eq 'Always-On Hooks[[:space:]]*\(6\)' "$DOC"; then
    assert_eq "Always-On Hooks count (6) declared" "present" "present"
else
    assert_eq "Always-On Hooks count (6) declared" \
        "'Always-On Hooks (6)' subheading" \
        "count missing or mismatched"
fi

if grep -Eq 'Gated Hooks[[:space:]]*\(3\)' "$DOC"; then
    assert_eq "Gated Hooks count (3) declared" "present" "present"
else
    assert_eq "Gated Hooks count (3) declared" \
        "'Gated Hooks (3)' subheading" \
        "count missing or mismatched"
fi

print_summary
