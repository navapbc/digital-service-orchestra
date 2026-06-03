#!/usr/bin/env bash
# tests/scripts/test-closure-checks-migration-preview.sh
# Behavioral smoke test for plugins/dso/scripts/closure-checks-migration-preview.sh
#
# Testing Mode: GREEN — covers the chunk-F preview script added by story
# 5362-7f18-4f37-4fa9. Validates:
#   - --help renders without error
#   - graceful soft-fail (exit 2 with structured preview_error) when
#     ANTHROPIC_API_KEY is unset
#   - parses --limit and --output flags
#
# Usage: bash tests/scripts/test-closure-checks-migration-preview.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
PREVIEW_SCRIPT="$REPO_ROOT/plugins/dso/scripts/closure-checks-migration-preview.sh"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "=== test-closure-checks-migration-preview.sh ==="

if [ "${_RUN_ALL_ACTIVE:-0}" = "1" ] && [ ! -f "$PREVIEW_SCRIPT" ]; then
    echo "SKIP: closure-checks-migration-preview.sh not yet implemented"
    printf "PASSED: 0  FAILED: 0\n"
    exit 0
fi

# Test 1: script exists and is executable
if [ -x "$PREVIEW_SCRIPT" ]; then
    _pass "script exists and is executable"
else
    _fail "script missing or not executable"
fi

# Test 2: --help renders
if "$PREVIEW_SCRIPT" --help >/dev/null 2>&1; then
    _pass "--help exits 0"
else
    _fail "--help failed"
fi

# Test 3: no ANTHROPIC_API_KEY → soft-fail with structured preview_error
TMP_OUT=$(mktemp "${TMPDIR:-/tmp}/test-preview.XXXXXX".json)
trap 'rm -f "$TMP_OUT"' EXIT
out=$(ANTHROPIC_API_KEY="" "$PREVIEW_SCRIPT" --limit 1 --output "$TMP_OUT" 2>&1)
rc=$?
if [ "$rc" = "2" ] && grep -q "preview_error" "$TMP_OUT"; then
    _pass "no-API-key soft-fail produces exit 2 + preview_error JSON"
elif [ "$rc" = "0" ] && grep -q "preview_error" "$TMP_OUT"; then
    # Acceptable variant: exit 0 with preview_error when no closed brainstorm:complete epics exist
    _pass "graceful empty-input path produces exit 0 + structured preview_error"
else
    _fail "no-API-key path: rc=$rc, output: $(cat "$TMP_OUT")"
fi

# Test 4: bad --limit value rejected
err_out=$("$PREVIEW_SCRIPT" --limit abc 2>&1)
err_rc=$?
if [ "$err_rc" = "1" ] && echo "$err_out" | grep -qiE "limit|positive integer"; then
    _pass "non-numeric --limit rejected with clear error"
else
    _fail "non-numeric --limit not rejected properly (rc=$err_rc, out='$err_out')"
fi

# ── Bug 33ad-1ab9-e46f-4888 RED tests ────────────────────────────────────────

# Test 5 (Finding 2): DSO_CLASSIFIER_MODEL env var is honored in classify_one()
# inside migration-preview.sh. Before the fix the function hardcodes the model;
# after the fix it reads CLASSIFIER_MODEL from os.environ.get("DSO_CLASSIFIER_MODEL").
_T5_SCRIPT=$(mktemp "${TMPDIR:-/tmp}/test-preview-model-id.XXXXXX.py")
trap 'rm -f "$TMP_OUT" "$_T5_SCRIPT"' EXIT
cat > "$_T5_SCRIPT" <<'PYEOF'
"""
Verify that classify_one() in migration-preview.sh uses DSO_CLASSIFIER_MODEL.
Monkeypatches urllib.request.urlopen to capture the outbound request body.
"""
import json
import os
import re
import sys
import urllib.request

CAPTURED = {}

class FakeResponse:
    def __init__(self):
        self._data = json.dumps({
            "content": [{"type": "text", "text": "end-state"}]
        }).encode("utf-8")
    def read(self):
        return self._data
    def __enter__(self):
        return self
    def __exit__(self, *a):
        pass

def mock_urlopen(req, **kwargs):
    body = json.loads(req.data.decode("utf-8"))
    CAPTURED["model"] = body.get("model")
    return FakeResponse()

urllib.request.urlopen = mock_urlopen

SCRIPT_PATH = os.environ.get("PREVIEW_SCRIPT", "")
if not SCRIPT_PATH:
    print("ERROR: PREVIEW_SCRIPT env var required", file=sys.stderr)
    sys.exit(2)

with open(SCRIPT_PATH) as f:
    script_src = f.read()

# Extract the classify_one function from the PYEOF heredoc in migration-preview.sh
m = re.search(r"def classify_one\(item_text\):.*?(?=\ndef |\nresults\b|\nfor epic)", script_src, re.DOTALL)
if not m:
    print("ERROR: could not locate classify_one in preview script", file=sys.stderr)
    sys.exit(2)

classify_src = m.group(0)
sentinel = os.environ.get("DSO_CLASSIFIER_MODEL", "claude-haiku-4-5-20251001")
exec_ns = {
    "json": json,
    "os": os,
    "re": re,
    "sys": sys,
    "urllib": urllib,
    "API_KEY": "fake-key-for-test",
    "ANTHROPIC_API_URL": "https://api.anthropic.com/v1/messages",
    "ANTHROPIC_VERSION": "2023-06-01",
    "CLASSIFIER_PROMPT": "Classify: ",
    "CLASSIFIER_MODEL": sentinel,
}

try:
    exec(compile(classify_src, "<classify_one_preview>", "exec"), exec_ns)
except SyntaxError as e:
    print(f"ERROR: compile failed: {e}", file=sys.stderr)
    sys.exit(2)

classify_fn = exec_ns.get("classify_one")
if classify_fn is None:
    print("ERROR: classify_one not found in exec namespace", file=sys.stderr)
    sys.exit(2)

result = classify_fn("the system supports OAuth")
used_model = CAPTURED.get("model", "<none>")

if used_model == sentinel:
    print(f"OK: model={used_model}")
    sys.exit(0)
else:
    print(f"FAIL: expected model={sentinel!r} but got model={used_model!r}", file=sys.stderr)
    sys.exit(1)
PYEOF

T5_OUT=$(DSO_CLASSIFIER_MODEL="sentinel-model-id-preview-test" \
         ANTHROPIC_API_KEY="fake-key-for-test" \
         PREVIEW_SCRIPT="$PREVIEW_SCRIPT" \
         python3 "$_T5_SCRIPT" 2>&1)
T5_RC=$?
if [ "$T5_RC" = "0" ] && echo "$T5_OUT" | grep -q "sentinel-model-id-preview-test"; then
    _pass "DSO_CLASSIFIER_MODEL env var is used in classify_one in preview script (Finding 2)"
else
    _fail "DSO_CLASSIFIER_MODEL not honored in preview: rc=$T5_RC out='$T5_OUT' (Finding 2 — RED before fix)"
fi

# Test 6 (Finding 1): open() calls in Python heredoc use encoding='utf-8'.
OPEN_WITHOUT_ENCODING=$(python3 - "$PREVIEW_SCRIPT" <<'PYEOF'
import re, sys

script_path = sys.argv[1]
with open(script_path) as f:
    src = f.read()

heredoc_blocks = re.findall(r"<<'PYEOF'\n(.*?)\nPYEOF", src, re.DOTALL)

bad_opens = []
for i, block in enumerate(heredoc_blocks):
    for lineno, line in enumerate(block.split("\n"), 1):
        m = re.search(r"\bopen\s*\(", line)
        if m and "encoding=" not in line and "# no-encoding" not in line:
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
