#!/usr/bin/env bash
# tests/scripts/test-closure-checks-classifier-pass.sh
# Behavioral smoke test for plugins/dso/scripts/closure-checks-classifier-pass.sh
#
# Testing Mode: GREEN — covers the Phase 2 classifier helper added by story
# ad70-f38a-7684-4e00. Focused on entry-point validation, arg parsing, and
# graceful-degradation paths that do not require a live ANTHROPIC_API_KEY.
# Tests are decoupled from specific live tracker tickets: synthetic ticket-ids
# are paired with pre-created snapshot files so the helper's `ticket show`
# fallback is bypassed.
#
# Usage: bash tests/scripts/test-closure-checks-classifier-pass.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
HELPER_SCRIPT="$REPO_ROOT/plugins/dso/scripts/closure-checks-classifier-pass.sh"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "=== test-closure-checks-classifier-pass.sh ==="

# ── Suite-runner guard: skip when script does not exist ──────────────────────
if [ "${_RUN_ALL_ACTIVE:-0}" = "1" ] && [ ! -f "$HELPER_SCRIPT" ]; then
    echo "SKIP: closure-checks-classifier-pass.sh not yet implemented"
    printf "PASSED: 0  FAILED: 0\n"
    exit 0
fi

# ── Per-suite temp state (mktemp-managed) ────────────────────────────────────
# Use a per-suite mktemp directory as the parent for all snapshot subdirs so
# parallel-test runs do not collide. Session IDs are mktemp'd too — see
# always:mktemp-tmp.
_SUITE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-classifier-pass.XXXXXX")
trap 'rm -rf "$_SUITE_TMP"' EXIT

# Synthetic ticket-ids that do not exist in any live tracker. The helper reads
# the snapshot file before falling back to `ticket show`, so these IDs never
# need to resolve via the ticket CLI.
SYNTHETIC_TID_DEGRADE="test-classifier-degrade-0001"
SYNTHETIC_TID_APPLY="test-classifier-apply-0002"

# Test 1: script exists and is executable
if [ -x "$HELPER_SCRIPT" ]; then
    _pass "script exists and is executable"
else
    _fail "script missing or not executable: $HELPER_SCRIPT"
fi

# Test 2: --help renders without error and includes expected sections
help_out=$("$HELPER_SCRIPT" --help 2>&1)
help_rc=$?
if [ "$help_rc" = "0" ] && echo "$help_out" | grep -q "closure-checks-classifier-pass.sh"; then
    _pass "--help exits 0 and prints usage block"
else
    _fail "--help failed (rc=$help_rc) or output missing"
fi

# Test 3: missing required arg (--ticket-id) yields a clear error
err_out=$("$HELPER_SCRIPT" --target /tmp 2>&1)
err_rc=$?
if [ "$err_rc" = "1" ] && echo "$err_out" | grep -qiE "ticket.?id|required"; then
    _pass "missing --ticket-id exits 1 with descriptive error"
else
    _fail "missing --ticket-id did not exit 1 or lacked descriptive error (rc=$err_rc, out='$err_out')"
fi

# Test 4: graceful degradation when ANTHROPIC_API_KEY is unset.
# Use a synthetic ticket-id + pre-supplied snapshot so the helper skips its
# `ticket show` fallback (which would otherwise contact the live tracker).
SESSION_DEGRADE="degrade-$(basename "$_SUITE_TMP")"
DEGRADE_SNAP_DIR="/tmp/migrate-closure-checks-classify.${SESSION_DEGRADE}.snapshot"
mkdir -p "$DEGRADE_SNAP_DIR"
{
    printf '# snapshot_timestamp: %s\n\n' "2026-05-20T00:00:00Z"
    printf '## Success Criteria\n\n- placeholder synthetic item for degradation test\n'
} > "$DEGRADE_SNAP_DIR/${SYNTHETIC_TID_DEGRADE}.txt"

DEGRADE_OUT=$(ANTHROPIC_API_KEY="" "$HELPER_SCRIPT" \
    --ticket-id "$SYNTHETIC_TID_DEGRADE" \
    --target "$REPO_ROOT" \
    --session-id "$SESSION_DEGRADE" \
    --migration-run-id 00000000-0000-0000-0000-000000000000 \
    --remaining-budget 1 \
    --dry-run 2>&1)
DEGRADE_RC=$?
if [ "$DEGRADE_RC" = "0" ] && echo "$DEGRADE_OUT" | grep -q "BUDGET_CONSUMED:"; then
    _pass "no-API-key path exits 0 and emits BUDGET_CONSUMED:"
else
    _fail "no-API-key degradation path failed (rc=$DEGRADE_RC, out tail='$(echo "$DEGRADE_OUT" | tail -3)')"
fi
rm -rf "$DEGRADE_SNAP_DIR"

# Test 5: --apply-from-plan with a synthesized empty plan should succeed without classifier dispatch.
# Uses mktemp-managed plan/decisions files + a synthetic ticket-id + pre-created snapshot.
TMP_PLAN=$(mktemp "${TMPDIR:-/tmp}/test-classifier-plan.XXXXXX".json)
TMP_DEC=$(mktemp "${TMPDIR:-/tmp}/test-classifier-dec.XXXXXX".json)
# Note: TMP_PLAN/TMP_DEC are cleaned by the suite-level trap that removes
# $_SUITE_TMP — but they live outside that dir, so clean them explicitly too.
trap 'rm -rf "$_SUITE_TMP"; rm -f "$TMP_PLAN" "$TMP_DEC"' EXIT
cat > "$TMP_PLAN" <<EOF
{
  "schema_version": 1,
  "ticket_id": "$SYNTHETIC_TID_APPLY",
  "snapshot_timestamp": "2026-05-20T00:00:00Z",
  "migration_run_id": "00000000-0000-0000-0000-000000000000",
  "items": []
}
EOF
echo '{"decisions": []}' > "$TMP_DEC"

SESSION_APPLY="apply-$(basename "$_SUITE_TMP")"
APPLY_SNAP_DIR="/tmp/migrate-closure-checks-classify.${SESSION_APPLY}.snapshot"
mkdir -p "$APPLY_SNAP_DIR"
{
    printf '# snapshot_timestamp: %s\n\n' "2026-05-20T00:00:00Z"
    printf '## Success Criteria\n\n- placeholder synthetic item for apply test\n'
} > "$APPLY_SNAP_DIR/${SYNTHETIC_TID_APPLY}.txt"

APPLY_OUT=$("$HELPER_SCRIPT" \
    --ticket-id "$SYNTHETIC_TID_APPLY" \
    --target "$REPO_ROOT" \
    --session-id "$SESSION_APPLY" \
    --migration-run-id 00000000-0000-0000-0000-000000000000 \
    --remaining-budget 5 \
    --apply-from-plan "$TMP_PLAN" \
    --decisions-file "$TMP_DEC" \
    --dry-run 2>&1)
APPLY_RC=$?
if [ "$APPLY_RC" = "0" ] && echo "$APPLY_OUT" | grep -q "BUDGET_CONSUMED:"; then
    _pass "--apply-from-plan with empty plan exits 0"
else
    _fail "--apply-from-plan with empty plan failed (rc=$APPLY_RC, out='$APPLY_OUT')"
fi
rm -rf "$APPLY_SNAP_DIR"

# Test 6: --apply-from-plan without --decisions-file should error
ERR_OUT=$("$HELPER_SCRIPT" \
    --ticket-id "$SYNTHETIC_TID_APPLY" \
    --target "$REPO_ROOT" \
    --session-id "$SESSION_APPLY" \
    --migration-run-id 00000000-0000-0000-0000-000000000000 \
    --apply-from-plan "$TMP_PLAN" 2>&1)
ERR_RC=$?
if [ "$ERR_RC" = "1" ] && echo "$ERR_OUT" | grep -qiE "decisions.?file|required"; then
    _pass "--apply-from-plan without --decisions-file exits 1 with descriptive error"
else
    _fail "missing --decisions-file did not exit 1 with proper error (rc=$ERR_RC, out='$ERR_OUT')"
fi

# ── Bug 33ad-1ab9-e46f-4888 RED tests ────────────────────────────────────────

# Test 7 (Finding 2): DSO_CLASSIFIER_MODEL env var is honored in classify_one().
# Strategy: wrap urllib.request.urlopen via sys.modules injection in a subprocess
# that replays the classify_one() function extracted from the script. Before the
# fix the function always uses the hardcoded literal; after the fix it reads
# CLASSIFIER_MODEL which inherits DSO_CLASSIFIER_MODEL.
_T7_SCRIPT=$(mktemp "${TMPDIR:-/tmp}/test-model-id.XXXXXX.py")
trap 'rm -rf "$_SUITE_TMP"; rm -f "$TMP_PLAN" "$TMP_DEC" "$_T7_SCRIPT"' EXIT
cat > "$_T7_SCRIPT" <<'PYEOF'
"""
Verify that classify_one() uses DSO_CLASSIFIER_MODEL env var, not the hardcoded literal.
Monkeypatches urllib.request.urlopen to capture the outbound request body without
making a real network call.
"""
import json
import os
import re
import sys
import types
import urllib.request

CAPTURED = {}

class FakeResponse:
    def __init__(self):
        # Return a valid classifier response
        self._data = json.dumps({
            "content": [{"type": "text", "text": '{"label":"end-state","ranking":5,"rationale":"test"}'}]
        }).encode("utf-8")
    def read(self):
        return self._data
    def __enter__(self):
        return self
    def __exit__(self, *a):
        pass

_orig_urlopen = urllib.request.urlopen

def mock_urlopen(req, **kwargs):
    body = json.loads(req.data.decode("utf-8"))
    CAPTURED["model"] = body.get("model")
    return FakeResponse()

urllib.request.urlopen = mock_urlopen

# ── Replicate the exact classify_one() from the script ──────────────────────
ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages"
ANTHROPIC_VERSION = "2023-06-01"

API_KEY = os.environ.get("ANTHROPIC_API_KEY", "fake-key-for-test")
CLASSIFIER_PROMPT = "Classify: "

# This mirrors what the FIXED script should do: read DSO_CLASSIFIER_MODEL.
# But we run the UNFIXED code path first by reading what the script ACTUALLY
# does — hardcodes the literal. We detect this by checking if the captured model
# matches the sentinel.
# We dynamically inject the logic from the script to avoid copy-paste drift.
SCRIPT_PATH = os.environ.get("HELPER_SCRIPT", "")
if not SCRIPT_PATH:
    print("ERROR: HELPER_SCRIPT env var required", file=sys.stderr)
    sys.exit(2)

with open(SCRIPT_PATH) as f:
    script_src = f.read()

# Extract the classify_one function from the main Python heredoc (second PYEOF block)
# by searching for the def classify_one(item_text): definition
m = re.search(r"def classify_one\(item_text\):.*?(?=\ndef |\n# Process|\nPLAN_OUTPUT\b)", script_src, re.DOTALL)
if not m:
    print("ERROR: could not locate classify_one in script", file=sys.stderr)
    sys.exit(2)

classify_src = m.group(0)
# Normalise indentation (the function is at module level inside the heredoc)
exec_ns = {
    "json": json,
    "os": os,
    "re": re,
    "sys": sys,
    "urllib": urllib,
    "API_KEY": API_KEY,
    "ANTHROPIC_API_URL": ANTHROPIC_API_URL,
    "ANTHROPIC_VERSION": ANTHROPIC_VERSION,
    "CLASSIFIER_PROMPT": CLASSIFIER_PROMPT,
}
# Before fix: hardcoded model; after fix: reads CLASSIFIER_MODEL from env.
# Inject CLASSIFIER_MODEL into namespace as the fixed code would set it.
sentinel = os.environ.get("DSO_CLASSIFIER_MODEL", "claude-haiku-4-5-20251001")
exec_ns["CLASSIFIER_MODEL"] = sentinel

try:
    exec(compile(classify_src, "<classify_one>", "exec"), exec_ns)
except SyntaxError as e:
    print(f"ERROR: compile failed: {e}", file=sys.stderr)
    sys.exit(2)

classify_fn = exec_ns.get("classify_one")
if classify_fn is None:
    print("ERROR: classify_one not found in exec namespace", file=sys.stderr)
    sys.exit(2)

result = classify_fn("test item text")
used_model = CAPTURED.get("model", "<none>")

if used_model == sentinel:
    print(f"OK: model={used_model}")
    sys.exit(0)
else:
    print(f"FAIL: expected model={sentinel!r} but got model={used_model!r}", file=sys.stderr)
    sys.exit(1)
PYEOF

T7_OUT=$(DSO_CLASSIFIER_MODEL="sentinel-model-id-test" \
         ANTHROPIC_API_KEY="fake-key-for-test" \
         HELPER_SCRIPT="$HELPER_SCRIPT" \
         python3 "$_T7_SCRIPT" 2>&1)
T7_RC=$?
if [ "$T7_RC" = "0" ] && echo "$T7_OUT" | grep -q "sentinel-model-id-test"; then
    _pass "DSO_CLASSIFIER_MODEL env var is used in classify_one (Finding 2)"
else
    _fail "DSO_CLASSIFIER_MODEL not honored: rc=$T7_RC out='$T7_OUT' (Finding 2 — RED before fix)"
fi

# Test 8 (Finding 3): apply-from-plan decisions count mismatch → nonzero exit + stderr message.
# Plan has 3 non-auto items + 1 auto item; decisions file has only 2 decisions.
# Before the fix: silently defers the missing decision and exits 0.
# After the fix: exits 1 with "decisions count mismatch" on stderr.
TMP_PLAN_COUNT=$(mktemp "${TMPDIR:-/tmp}/test-classifier-plan-count.XXXXXX")
TMP_DEC_COUNT=$(mktemp "${TMPDIR:-/tmp}/test-classifier-dec-count.XXXXXX")
trap 'rm -rf "$_SUITE_TMP"; rm -f "$TMP_PLAN" "$TMP_DEC" "$_T7_SCRIPT" "$TMP_PLAN_COUNT" "$TMP_DEC_COUNT"' EXIT

cat > "$TMP_PLAN_COUNT" <<'EOF'
{
  "schema_version": 1,
  "ticket_id": "test-count-mismatch-0001",
  "snapshot_timestamp": "2026-05-20T00:00:00Z",
  "migration_run_id": "00000000-0000-0000-0000-000000000001",
  "items": [
    {"index": 0, "original_text": "item A", "original_section": "SC",
     "classification": {"label": "uncertain", "ranking": 2, "rationale": "test"},
     "auto_accepted": false, "proposed_target": "SC"},
    {"index": 1, "original_text": "item B", "original_section": "SC",
     "classification": {"label": "uncertain", "ranking": 2, "rationale": "test"},
     "auto_accepted": false, "proposed_target": "SC"},
    {"index": 2, "original_text": "item C", "original_section": "SC",
     "classification": {"label": "uncertain", "ranking": 2, "rationale": "test"},
     "auto_accepted": false, "proposed_target": "SC"},
    {"index": 3, "original_text": "item D auto", "original_section": "SC",
     "classification": {"label": "end-state", "ranking": 5, "rationale": "test"},
     "auto_accepted": true, "proposed_target": "SC"}
  ]
}
EOF
# Only 2 decisions for 3 non-auto items → mismatch
cat > "$TMP_DEC_COUNT" <<'EOF'
{
  "decisions": [
    {"index": 0, "user_decision": "accept"},
    {"index": 1, "user_decision": "defer"}
  ]
}
EOF

SESSION_COUNT="count-$(basename "$_SUITE_TMP")"
COUNT_SNAP_DIR="/tmp/migrate-closure-checks-classify.${SESSION_COUNT}.snapshot"
mkdir -p "$COUNT_SNAP_DIR"
{
    printf '# snapshot_timestamp: %s\n\n' "2026-05-20T00:00:00Z"
    printf '## Success Criteria\n\n- item A\n- item B\n- item C\n- item D auto\n'
} > "$COUNT_SNAP_DIR/test-count-mismatch-0001.txt"

COUNT_OUT=$("$HELPER_SCRIPT" \
    --ticket-id "test-count-mismatch-0001" \
    --target "$REPO_ROOT" \
    --session-id "$SESSION_COUNT" \
    --migration-run-id "00000000-0000-0000-0000-000000000001" \
    --remaining-budget 25 \
    --apply-from-plan "$TMP_PLAN_COUNT" \
    --decisions-file "$TMP_DEC_COUNT" \
    --dry-run 2>&1)
COUNT_RC=$?
rm -rf "$COUNT_SNAP_DIR"

if [ "$COUNT_RC" != "0" ] && echo "$COUNT_OUT" | grep -qi "decisions count mismatch"; then
    _pass "apply-from-plan: decisions count mismatch yields nonzero exit + stderr message (Finding 3)"
else
    _fail "apply-from-plan: expected nonzero exit and mismatch message, got rc=$COUNT_RC out='$COUNT_OUT' (Finding 3 — RED before fix)"
fi

# Test 9 (Finding 1): open() calls use encoding='utf-8'.
# Strategy: inspect the script source for open() calls inside the Python
# heredoc and verify each one specifies encoding='utf-8'.
# Before fix: open() calls lack encoding; after fix: all have encoding='utf-8'.
OPEN_WITHOUT_ENCODING=$(python3 - "$HELPER_SCRIPT" <<'PYEOF'
"""
Find open() calls in Python heredoc blocks inside the script that lack
encoding='utf-8'. Only scan inside PYEOF-delimited heredoc blocks.
"""
import re, sys

script_path = sys.argv[1]
with open(script_path) as f:
    src = f.read()

# Extract content between <<'PYEOF' ... PYEOF markers
heredoc_blocks = re.findall(r"<<'PYEOF'\n(.*?)\nPYEOF", src, re.DOTALL)

bad_opens = []
for i, block in enumerate(heredoc_blocks):
    for lineno, line in enumerate(block.split("\n"), 1):
        # Match open( calls: open(some_var) or open("path") but NOT open(...encoding=...)
        m = re.search(r"\bopen\s*\(", line)
        if m and "encoding=" not in line and "# no-encoding" not in line \
                and "/dev/tty" not in line:
            bad_opens.append(f"block {i+1} line {lineno}: {line.strip()}")

if bad_opens:
    print("\n".join(bad_opens))
    sys.exit(1)
sys.exit(0)
PYEOF
)
OPEN_RC=$?
if [ "$OPEN_RC" = "0" ]; then
    _pass "all open() calls in Python heredocs specify encoding='utf-8' (Finding 1)"
else
    _fail "open() calls without encoding='utf-8' found (Finding 1 — RED before fix):\n$OPEN_WITHOUT_ENCODING"
fi

echo ""
printf "PASSED: %d  FAILED: %d\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
