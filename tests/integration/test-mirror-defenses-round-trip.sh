#!/usr/bin/env bash
# tests/integration/test-mirror-defenses-round-trip.sh
# SDET audit P1-3: mirror-defenses-to-pr round-trip parity test.
#
# Verifies that a defense record written by `mirror-defenses-to-pr.sh` to a
# PR comment can be fetched back and parsed to the same JSON content. Catches
# markdown-escaping / quoting / truncation regressions in the post side that
# the existing tests (write-only) cannot catch.
#
# Stubs `gh` via PATH-prepend so the test never touches GitHub.
#
# Usage: bash tests/integration/test-mirror-defenses-round-trip.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
MIRROR="$REPO_ROOT/plugins/dso/scripts/mirror-defenses-to-pr.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-mirror-defenses-round-trip.sh ==="

if [[ ! -f "$MIRROR" ]]; then
    echo "SKIP: $MIRROR not found"
    printf "PASSED: %d  FAILED: %d\n" "$PASS" "$FAIL"
    exit 0
fi

TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/mirror-rt-XXXXXX")
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# ─── Fake `gh` shim ───────────────────────────────────────────────────────────
# Records every `gh pr comment` invocation's body to TEST_TMPDIR/pr-comments/
# and serves them back for `gh pr view --json comments`.
FAKE_GH_BIN="$TEST_TMPDIR/bin"
mkdir -p "$FAKE_GH_BIN" "$TEST_TMPDIR/pr-comments"

cat > "$FAKE_GH_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
# Minimal `gh` stub for round-trip testing.
set -uo pipefail
_GH_STATE_DIR="$FAKE_GH_STATE_DIR"
mkdir -p "$_GH_STATE_DIR/pr-comments"

case "${1:-}" in
    pr)
        shift
        case "${1:-}" in
            comment)
                shift
                # gh pr comment <number> --body-file <file> OR --body <string>
                body=""
                while [[ $# -gt 0 ]]; do
                    case "$1" in
                        --body-file) body=$(cat "$2"); shift 2 ;;
                        --body)      body="$2"; shift 2 ;;
                        *)           shift ;;
                    esac
                done
                # Append to the comments log in atomic-write fashion.
                _ts=$(date +%s%N 2>/dev/null || date +%s)
                printf '%s' "$body" > "$_GH_STATE_DIR/pr-comments/comment-$_ts.body"
                exit 0
                ;;
            view)
                shift
                # gh pr view <number> --json comments → emit JSON array of bodies
                python3 - "$_GH_STATE_DIR/pr-comments" <<'PYEOF'
import json, os, sys
d = sys.argv[1]
comments = []
if os.path.isdir(d):
    for name in sorted(os.listdir(d)):
        p = os.path.join(d, name)
        if os.path.isfile(p):
            with open(p) as f:
                comments.append({"body": f.read()})
print(json.dumps({"comments": comments}))
PYEOF
                exit 0
                ;;
        esac
        ;;
esac
exit 0
GHEOF
chmod +x "$FAKE_GH_BIN/gh"

export FAKE_GH_STATE_DIR="$TEST_TMPDIR"
export GH_CMD="$FAKE_GH_BIN/gh"
export PATH="$FAKE_GH_BIN:$PATH"

# ─── Defense records to round-trip ────────────────────────────────────────────
# Baseline test: plain-ASCII defense_text values. Exotic-byte stress
# (backticks, pipe chars, code fences, embedded quotes, multibyte UTF-8) is
# covered by test_round_trip_handles_exotic_bytes below — the fix in
# acff-b6eb-a6b7-4828 switched github_defense_store_write from --body argv
# interpolation to --body-file (mktemp-backed) precisely to make this safe.
_make_defense_record() {
    local idx="$1"
    local tricky="$2"
    python3 - "$idx" "$tricky" <<'PYEOF'
import json, sys
record = {
    "prior_finding_id": f"F{sys.argv[1]}",
    "cited_lines_fingerprint": f"{int(sys.argv[1]):064d}",
    "defense_text": f"Round-trip test #{sys.argv[1]}: {sys.argv[2]}",
    "defender": "test:round-trip",
    "cycle_number": 1,
    "timestamp": "2026-05-19T20:00:00Z",
    "severity_history": [{"cycle": 1, "severity": "important", "relation": None}],
    "ticket_id": "round-trip-ticket",
}
print(json.dumps(record))
PYEOF
}

# ─── Test 1 — write 3 defense records, fetch back, JSON survives intact ──────
echo ""
echo "--- test_round_trip_preserves_json_content ---"

test_round_trip_preserves_json_content() {
    _snapshot_fail

    # Reset the fake GH state.
    rm -rf "$FAKE_GH_STATE_DIR/pr-comments"
    mkdir -p "$FAKE_GH_STATE_DIR/pr-comments"

    local input="$TEST_TMPDIR/defenses-input.jsonl"
    : > "$input"
    # mirror-defenses-to-pr reads stdin line-by-line and expects each line to
    # begin with the `DEFENSE_RECORD: ` prefix before a single-line JSON record.
    # Use plain-ASCII defense_text values for the baseline round-trip — markdown
    # quoting / escaping stress is the subject of a separate follow-up test
    # (audit P1-3 narrow scope: prove the round-trip mechanism, not exhaustive
    # encoding fuzzing).
    printf 'DEFENSE_RECORD: %s\n' "$(_make_defense_record 1 'first defense record')" >> "$input"
    printf 'DEFENSE_RECORD: %s\n' "$(_make_defense_record 2 'second defense record')" >> "$input"
    printf 'DEFENSE_RECORD: %s\n' "$(_make_defense_record 3 'third defense record')" >> "$input"

    # Run the mirror script to post all three.
    PR_NUMBER=1 REPO_SLUG=test/round-trip bash "$MIRROR" 1 test/round-trip < "$input" >/dev/null 2>&1 || true

    # Fetch back what was posted and reconstruct the defense records.
    local fetched
    fetched=$("$FAKE_GH_BIN/gh" pr view 1 --json comments 2>/dev/null)

    # Each DEFENSE_RECORD comment should yield a parseable JSON record whose
    # defense_text matches the original (within the DEFENSE_RECORD: prefix).
    local matched
    matched=$(python3 - "$fetched" <<'PYEOF'
import json, re, sys
data = json.loads(sys.argv[1])
expected = [
    "Round-trip test #1: first defense record",
    "Round-trip test #2: second defense record",
    "Round-trip test #3: third defense record",
]
matched = 0
for c in data.get("comments", []):
    body = c.get("body", "")
    m = re.search(r"DEFENSE_RECORD:\s*(\{.*\})", body, flags=re.DOTALL)
    if not m:
        continue
    try:
        rec = json.loads(m.group(1))
    except Exception:
        continue
    if rec.get("defense_text") in expected:
        matched += 1
print(matched)
PYEOF
)
    assert_eq "round-trip preserves 3 defense records" "3" "$matched"

    assert_pass_if_clean "test_round_trip_preserves_json_content"
}
test_round_trip_preserves_json_content

# ─── Test 2 — exotic-byte defense_text survives round-trip (acff-b6eb fix) ───
echo ""
echo "--- test_round_trip_handles_exotic_bytes ---"

test_round_trip_handles_exotic_bytes() {
    _snapshot_fail

    # Reset the fake GH state.
    rm -rf "$FAKE_GH_STATE_DIR/pr-comments"
    mkdir -p "$FAKE_GH_STATE_DIR/pr-comments"

    local input="$TEST_TMPDIR/defenses-exotic-input.jsonl"
    : > "$input"

    # Three representative exotic-byte payloads:
    #   1. backtick-rich markdown payload (code fences + inline backticks)
    #   2. double-quote-rich JSON-in-text payload (embedded quotes)
    #   3. multibyte-UTF-8 payload (em-dashes, smart quotes, non-ASCII)
    # shellcheck disable=SC2016  # literal backticks intentional for stress test
    local payload1='```bash rm -rf / # `do not run` ```'
    local payload2='He said "hello" and {"key":"val with \"escaped\" quotes"}'
    local payload3='résumé — “smart quotes” • ✓ é → ∞ 日本語'

    printf 'DEFENSE_RECORD: %s\n' "$(_make_defense_record 1 "$payload1")" >> "$input"
    printf 'DEFENSE_RECORD: %s\n' "$(_make_defense_record 2 "$payload2")" >> "$input"
    printf 'DEFENSE_RECORD: %s\n' "$(_make_defense_record 3 "$payload3")" >> "$input"

    PR_NUMBER=1 REPO_SLUG=test/round-trip bash "$MIRROR" 1 test/round-trip < "$input" >/dev/null 2>&1 || true

    local fetched
    fetched=$("$FAKE_GH_BIN/gh" pr view 1 --json comments 2>/dev/null)

    local matched
    matched=$(python3 - "$fetched" "$payload1" "$payload2" "$payload3" <<'PYEOF'
import json, re, sys
data = json.loads(sys.argv[1])
expected = {
    f"Round-trip test #1: {sys.argv[2]}",
    f"Round-trip test #2: {sys.argv[3]}",
    f"Round-trip test #3: {sys.argv[4]}",
}
matched = 0
seen = set()
for c in data.get("comments", []):
    body = c.get("body", "")
    m = re.search(r"DEFENSE_RECORD:\s*(\{.*\})", body, flags=re.DOTALL)
    if not m:
        continue
    try:
        rec = json.loads(m.group(1))
    except Exception:
        continue
    dt = rec.get("defense_text")
    if dt in expected and dt not in seen:
        seen.add(dt)
        matched += 1
print(matched)
PYEOF
)
    assert_eq "round-trip preserves 3 exotic-byte defense records" "3" "$matched"

    assert_pass_if_clean "test_round_trip_handles_exotic_bytes"
}
test_round_trip_handles_exotic_bytes

print_summary
