#!/usr/bin/env bash
# Parity test: shell --reconstruct-from-pr and Python reconstruct_from_pr_comments
# produce identical cycle-ledger.json output from the same PR-comment input.
#
# This test exercises the post-unification contract from task b1df-18c6-6ac8-4b39:
# the shell --reconstruct-from-pr handler MUST delegate to the Python CLI so
# that no second regex/grammar lives in the shell. Failure means the shell has
# regressed to a divergent inline parser — Step 4.75 parity is broken.
#
# Test mode: positional `--reconstruct-from-pr <PR_NUM> <REPO>` for pure
# reconstruction (no new cycle appended). The shell's output ledger MUST equal
# the Python CLI's stdout ledger byte-for-byte (after normalizing volatile
# fields like timestamps that the Python pure-reconstruction path does not set).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-recon-parity.XXXXXX")
MOCK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mock-gh.XXXXXX")
trap 'rm -rf "$TEST_DIR" "$MOCK_DIR"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Mock gh CLI: returns a canned PR-comments JSON array.
#
# The mock must satisfy BOTH access patterns:
#  - Python:  gh api repos/<repo>/pulls/<pr>/comments --paginate  (expects JSON)
#  - Shell (legacy, pre-unification): gh pr view <pr> --json comments --jq ...
#
# After unification the shell delegates to Python, so only the `api` form is
# exercised. We still support both in the mock so existing shell B5/B6 tests
# that don't go through this script don't break if they happen to share PATH.
# ─────────────────────────────────────────────────────────────────────────────
cat > "$MOCK_DIR/gh" << 'MOCK_GH'
#!/usr/bin/env bash
# Mock gh: return canned JSON for `gh api .../comments`, canned text for `gh pr view`.
case "$1" in
    api)
        # $2 is e.g. "repos/owner/repo/pulls/42/comments"
        cat <<'JSON'
[
  {"body": "Cycle 1\nDSO-Review-Cycle: 1 commit_sha=abc123 findings_hash=h1 tuples=[[\"src/x.py\",\"10-20\",\"correctness\"]]"},
  {"body": "Cycle 2\nDSO-Review-Cycle: 2 commit_sha=def456 findings_hash=h2 tuples=[[\"src/y.py\",\"5\",\"security\"]]"}
]
JSON
        exit 0
        ;;
    pr)
        # `gh pr view <pr> --json comments --jq ".comments[].body"`
        echo "Cycle 1"
        echo "DSO-Review-Cycle: 1 commit_sha=abc123 findings_hash=h1 tuples=[[\"src/x.py\",\"10-20\",\"correctness\"]]"
        echo "Cycle 2"
        echo "DSO-Review-Cycle: 2 commit_sha=def456 findings_hash=h2 tuples=[[\"src/y.py\",\"5\",\"security\"]]"
        exit 0
        ;;
    *)
        echo "mock gh: unsupported invocation: $*" >&2
        exit 1
        ;;
esac
MOCK_GH
chmod +x "$MOCK_DIR/gh"

export PATH="$MOCK_DIR:$PATH"

# ─────────────────────────────────────────────────────────────────────────────
# Run shell reconstruction via the positional --reconstruct-from-pr form.
# Output lands in $WORKFLOW_PLUGIN_ARTIFACTS_DIR/cycle-ledger.json.
# ─────────────────────────────────────────────────────────────────────────────
SHELL_ARTIFACTS="$TEST_DIR/shell"
mkdir -p "$SHELL_ARTIFACTS"
WORKFLOW_PLUGIN_ARTIFACTS_DIR="$SHELL_ARTIFACTS" \
    bash "$REPO_ROOT/plugins/dso/scripts/write-cycle-ledger.sh" \
        --reconstruct-from-pr 42 owner/repo \
        > "$TEST_DIR/shell.stdout" 2> "$TEST_DIR/shell.stderr"
shell_rc=$?
if [[ $shell_rc -ne 0 ]]; then
    echo "FAIL: shell --reconstruct-from-pr exited with code $shell_rc" >&2
    echo "stdout: $(cat "$TEST_DIR/shell.stdout")" >&2
    echo "stderr: $(cat "$TEST_DIR/shell.stderr")" >&2
    exit 1
fi
SHELL_OUT="$SHELL_ARTIFACTS/cycle-ledger.json"
if [[ ! -f "$SHELL_OUT" ]]; then
    echo "FAIL: shell did not write cycle-ledger.json to $SHELL_OUT" >&2
    echo "stdout: $(cat "$TEST_DIR/shell.stdout")" >&2
    echo "stderr: $(cat "$TEST_DIR/shell.stderr")" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Run Python reconstruction via the module CLI.
# ─────────────────────────────────────────────────────────────────────────────
PY_OUT="$TEST_DIR/python.json"
PYTHONPATH="$REPO_ROOT/plugins/dso/scripts" \
    python3 -m dso_ci_review.cycle_ledger reconstruct-from-pr 42 owner/repo \
        > "$PY_OUT" 2> "$TEST_DIR/python.stderr"
py_rc=$?
if [[ $py_rc -ne 0 ]]; then
    echo "FAIL: python -m dso_ci_review.cycle_ledger reconstruct-from-pr exited with code $py_rc" >&2
    echo "stderr: $(cat "$TEST_DIR/python.stderr")" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Compare structures. Normalize for volatile fields (timestamps).
# ─────────────────────────────────────────────────────────────────────────────
if python3 - "$SHELL_OUT" "$PY_OUT" <<'PYEOF'; then
import json
import sys

shell = json.load(open(sys.argv[1]))
py    = json.load(open(sys.argv[2]))

def normalize(led):
    for c in led.get("cycles", []):
        c.pop("timestamp_utc", None)
    return led

n_shell = normalize(shell)
n_py    = normalize(py)
if n_shell != n_py:
    sys.stderr.write(f"MISMATCH:\n  shell={json.dumps(n_shell, sort_keys=True)}\n  python={json.dumps(n_py, sort_keys=True)}\n")
    sys.exit(1)
sys.exit(0)
PYEOF
    echo "PASS: shell and Python reconstruction produce identical output"
    exit 0
else
    echo "FAIL: shell and Python reconstruction diverged" >&2
    echo "--- shell output ---" >&2
    python3 -m json.tool "$SHELL_OUT" >&2 || cat "$SHELL_OUT" >&2
    echo "--- python output ---" >&2
    python3 -m json.tool "$PY_OUT" >&2 || cat "$PY_OUT" >&2
    exit 1
fi
