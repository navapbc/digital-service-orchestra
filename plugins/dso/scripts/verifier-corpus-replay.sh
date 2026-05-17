#!/usr/bin/env bash
# verifier-corpus-replay.sh
# Cross-path replay harness for verifier regression fixtures.
# Usage: bash "${CLAUDE_PLUGIN_ROOT}/scripts/verifier-corpus-replay.sh" [--dry-run]
#
# Modes (bug 7423-eff5):
#   * Wiring mode (default): mocks _call_verifier_agent to return each
#     fixture's expected_ruling and asserts the dispatcher plumbs it
#     through. This is a DISPATCHER-WIRING test — it cannot catch a
#     regression in verifier-agent judgment because the agent is never
#     invoked. Useful as a PR-time CI signal that dispatcher routing is
#     intact.
#   * Integration mode (DSO_VERIFIER_INTEGRATION=1): leaves
#     _call_verifier_agent un-mocked. Real LLM calls run against each
#     fixture's finding.json; the LLM response is compared to
#     expected_ruling.json. Exercises actual verifier judgment.
#     Requires ANTHROPIC_API_KEY; skips gracefully when absent.
#
# Reads each fixture directory from tests/fixtures/verifier-corpus/ and
# replays through the CI path (dso_ci_review.verifier.dispatch_verifier).
# Reports cross-path equivalence (≥95% threshold).

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(git -C "$_SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "${CLAUDE_PLUGIN_ROOT}")")"
_CORPUS_DIR="$_REPO_ROOT/tests/fixtures/verifier-corpus"
_VERIFIER_MODULE_DIR="$_SCRIPT_DIR/dso_ci_review"

DRY_RUN=0
for arg in "$@"; do
    if [[ "$arg" == "--dry-run" ]]; then
        DRY_RUN=1
    fi
done

if [[ ! -d "$_CORPUS_DIR" ]]; then
    echo "ERROR: corpus directory not found: $_CORPUS_DIR" >&2
    exit 1
fi

_total=0
_matched=0
_failed=0

for _fixture_dir in "$_CORPUS_DIR"/*/; do
    [[ -d "$_fixture_dir" ]] || continue
    _name="$(basename "$_fixture_dir")"
    _finding_file="$_fixture_dir/finding.json"
    _expected_file="$_fixture_dir/expected_ruling.json"

    if [[ ! -f "$_finding_file" || ! -f "$_expected_file" ]]; then
        echo "SKIP: $_name — missing finding.json or expected_ruling.json" >&2
        continue
    fi

    _total=$(( _total + 1 ))
    _expected_ruling=$(python3 -c "import json; d=json.load(open('$_expected_file')); print(d['ruling'])" 2>/dev/null)

    if [[ -z "$_expected_ruling" ]]; then
        echo "ERROR: $_name — cannot parse expected_ruling.json" >&2
        _failed=$(( _failed + 1 ))
        continue
    fi

    # Two modes (bug 7423-eff5):
    #   integration: DSO_VERIFIER_INTEGRATION=1 → real LLM verifier judgment
    #   wiring (default): mock _call_verifier_agent → dispatcher routing test
    _ci_ruling=$(DSO_VERIFIER_EXPECTED="$_expected_ruling" \
                 DSO_VERIFIER_FINDING_FILE="$_finding_file" \
                 DSO_VERIFIER_MODULE_DIR="$_VERIFIER_MODULE_DIR" \
                 python3 - <<'PYEOF'
import sys, json, os
sys.path.insert(0, os.environ['DSO_VERIFIER_MODULE_DIR'] + '/..')
from dso_ci_review.verifier import dispatch_verifier, VerifierResult

with open(os.environ['DSO_VERIFIER_FINDING_FILE']) as f:
    finding = json.load(f)
expected = os.environ['DSO_VERIFIER_EXPECTED']

_integration = os.environ.get('DSO_VERIFIER_INTEGRATION', '') == '1'

if _integration:
    # Integration mode — real LLM call. Skip when no API key (caller decides).
    if not os.environ.get('ANTHROPIC_API_KEY'):
        print('skip-no-api-key')
        sys.exit(0)
    from unittest.mock import patch
    # Only force the enable flag; leave _call_verifier_agent un-patched so
    # the real LLM path executes and the fixture's finding.json drives the
    # actual prompt template.
    with patch('dso_ci_review.verifier._is_verifier_enabled', return_value=True):
        results = dispatch_verifier([finding], reviewed_sha='replay-test')
else:
    # Wiring mode — mock the agent to return the expected ruling.
    # NOTE: this is a DISPATCHER-WIRING TEST, NOT a verifier-judgment test.
    # The mock removes any possibility of the verifier agent being exercised.
    # Use DSO_VERIFIER_INTEGRATION=1 to exercise real verifier judgment.
    from unittest.mock import patch
    mock_result = VerifierResult(
        finding_id=finding.get('finding_id', 'test'),
        ruling=expected,
        fingerprint='test:0-0',
        verifier_status='ok',
        evidence_invalidated=False,
        rationale='Replay harness mock (wiring mode)',
    )
    with patch('dso_ci_review.verifier._is_verifier_enabled', return_value=True), \
         patch('dso_ci_review.verifier._call_verifier_agent', return_value=mock_result):
        results = dispatch_verifier([finding], reviewed_sha='replay-test')

if not results:
    print('drop')
elif results[0].get('severity') == 'minor' and finding.get('severity') != 'minor':
    print('downgrade-to-minor')
else:
    print('confirm')
PYEOF
    )

    # Integration mode without API key — treat as skip, do not penalize
    if [[ "$_ci_ruling" == "skip-no-api-key" ]]; then
        echo "SKIP: $_name — DSO_VERIFIER_INTEGRATION=1 but ANTHROPIC_API_KEY absent"
        _total=$(( _total - 1 ))
        continue
    fi

    if [[ -z "$_ci_ruling" ]]; then
        echo "FAIL: $_name — CI path error" >&2
        _failed=$(( _failed + 1 ))
        continue
    fi

    if [[ "$_ci_ruling" == "$_expected_ruling" ]]; then
        _matched=$(( _matched + 1 ))
        echo "PASS: $_name — ruling=$_ci_ruling (matches expected)"
    else
        echo "MISMATCH: $_name — CI=$_ci_ruling expected=$_expected_ruling"
    fi
done

_equiv=0
if [[ $_total -gt 0 ]]; then
    _equiv=$(( _matched * 100 / _total ))
fi

_mode="wiring (mocked agent — dispatcher routing test)"
[[ "${DSO_VERIFIER_INTEGRATION:-}" == "1" ]] && _mode="integration (real LLM verifier judgment)"

echo ""
echo "=== Verifier Corpus Replay Summary ==="
echo "Mode: $_mode"
echo "Total fixtures: $_total"
echo "Matched: $_matched"
echo "Failed to run: $_failed"
echo "Cross-path equivalence: ${_equiv}%"
echo "Threshold: 95%"

if [[ $_total -eq 0 ]]; then
    echo "WARN: no fixtures found — nothing to replay"
    exit 0
fi

if [[ $_equiv -ge 95 ]] || [[ $DRY_RUN -eq 1 ]]; then
    echo "RESULT: PASS (equivalence=${_equiv}%)"
    exit 0
else
    echo "RESULT: FAIL (equivalence=${_equiv}% < 95%)"
    exit 1
fi
