#!/usr/bin/env bash
# tests/workflows/test-review-workflow-classifier-override-prevention.sh
# Asserts that REVIEW-WORKFLOW.md explicitly prevents the orchestrator from
# rationalizing around the classifier tier decision using overhead/cost objections.
#
# Bug 71c1-bbc7: Orchestrator overrides review classifier tier decision instead
# of following it. Observed rationalization: "Deep tier with upgrade — that is a
# lot of review overhead for a commit-and-merge request."
#
# Usage: bash tests/workflows/test-review-workflow-classifier-override-prevention.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-review-workflow-classifier-override-prevention.sh ==="
echo ""

# ── test_anti_rationalization_language_present ────────────────────────────────
# REVIEW-WORKFLOW.md must explicitly prohibit rationalization-based overrides
# of the classifier tier decision (e.g., "overhead", "cost", "time" objections).
echo "--- test_anti_rationalization_language_present ---"
_snapshot_fail

_has_anti_rationalization=0
# Check for language explicitly prohibiting rationalization exemptions
if grep -qiE "rationali[sz]|overhead|cost.*override|override.*cost|no exception" "$WORKFLOW_FILE"; then
    _has_anti_rationalization=1
fi
assert_eq "test_anti_rationalization_language_present: REVIEW-WORKFLOW.md must explicitly block overhead/rationalization exemptions" \
    "1" "$_has_anti_rationalization"
assert_pass_if_clean "test_anti_rationalization_language_present"

# ── test_deep_upgrade_dispatch_is_mandatory ───────────────────────────────────
# When the classifier returns deep+upgrade, REVIEW-WORKFLOW.md must explicitly
# require dispatching the full deep tier (not a lighter substitute).
echo ""
echo "--- test_deep_upgrade_dispatch_is_mandatory ---"
_snapshot_fail

_has_deep_upgrade_mandate=0
# Must have language specifically addressing deep tier + upgrade combination
python3 - "$WORKFLOW_FILE" <<'PYEOF' && _has_deep_upgrade_mandate=1 || true
import re, sys
with open(sys.argv[1]) as f:
    content = f.read()
# Look for a block that mentions both 'deep' tier and 'upgrade' together with mandatory language
has_deep_upgrade = bool(re.search(r'(?i)(deep.*upgrade|upgrade.*deep)', content))
has_mandatory = bool(re.search(r'(?i)(must dispatch|must follow|non-negotiable|mandatory|MUST.*dispatch.*deep|deep.*MUST)', content))
sys.exit(0 if (has_deep_upgrade and has_mandatory) else 1)
PYEOF
assert_eq "test_deep_upgrade_dispatch_is_mandatory: REVIEW-WORKFLOW.md must mandate dispatch of deep+upgrade tier without substitution" \
    "1" "$_has_deep_upgrade_mandate"
assert_pass_if_clean "test_deep_upgrade_dispatch_is_mandatory"

# ── test_no_substitute_agent_for_classifier_tier ─────────────────────────────
# REVIEW-WORKFLOW.md must explicitly state that general-purpose or lighter agents
# cannot substitute for the classifier-selected named review agent.
echo ""
echo "--- test_no_substitute_agent_for_classifier_tier ---"
_snapshot_fail

_has_no_substitute_rule=0
grep -qiE "do not substitute|must not substitute|no substitute|cannot substitute|general.purpose.*not|not.*general.purpose" "$WORKFLOW_FILE" && _has_no_substitute_rule=1 || true
assert_eq "test_no_substitute_agent_for_classifier_tier: REVIEW-WORKFLOW.md must prohibit substituting a lighter/general-purpose agent for the classifier-selected agent" \
    "1" "$_has_no_substitute_rule"
assert_pass_if_clean "test_no_substitute_agent_for_classifier_tier"

# ── test_classifier_failure_standard_tier_invariant ──────────────────────────
# When the classifier fails (exit non-zero or invalid JSON), REVIEW-WORKFLOW.md
# must contain an explicit prose-level instruction (outside any code block)
# mandating standard tier. Bug 22bc-6bab: agent logged "defaulting to standard"
# but dispatched dso:code-reviewer-light for subsequent batches, rationalizing
# that "small diffs don't need full sonnet review."
echo ""
echo "--- test_classifier_failure_standard_tier_invariant ---"
_snapshot_fail

_has_failure_invariant=0
# Must have prose-level language that explicitly mandates standard tier on
# classifier failure — not just inside a code block comment.
# We strip fenced code blocks and then check for the invariant in the remaining prose.
python3 - "$WORKFLOW_FILE" <<'PYEOF' && _has_failure_invariant=1 || true
import re, sys
with open(sys.argv[1]) as f:
    content = f.read()
# Strip fenced code blocks (```...```) to check prose only
prose = re.sub(r'```[^`]*```', '', content, flags=re.DOTALL)
# Look for explicit classifier-failure → standard-tier mandate in prose.
# REVIEW-DEFENSE: Three independent patterns are required (all must match), providing
# defense-in-depth: a false positive on one pattern (e.g., unrelated prose containing
# "fail") does not pass the test unless the other two also match. If the section title
# were renamed, has_failure_mention would still match via the body sentence
# "exits non-zero" and has_anti_rationalization via "Do not downgrade", keeping the
# test meaningful even with cosmetic prose changes.
has_failure_mention = bool(re.search(r'(?i)classifier\s+(fail|error|exit\s+non.zero|invalid)', prose))
has_standard_mandate = bool(re.search(r'(?i)(MUST|mandatory|invariant|required).*standard', prose))
has_anti_rationalization = bool(re.search(r'(?i)(do not downgrade|do not override|not.*rationali[sz]e|not.*lighter)', prose))
sys.exit(0 if (has_failure_mention and has_standard_mandate and has_anti_rationalization) else 1)
PYEOF
assert_eq "test_classifier_failure_standard_tier_invariant: REVIEW-WORKFLOW.md must mandate standard tier on classifier failure with anti-rationalization language in prose (not just in code block)" \
    "1" "$_has_failure_invariant"
assert_pass_if_clean "test_classifier_failure_standard_tier_invariant"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
