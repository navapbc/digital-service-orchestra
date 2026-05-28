#!/usr/bin/env bash
# tests/hooks/test-merge-helpers-pr-repo-cache.sh
# Behavioral test: _pr_repo() must NOT cache an empty result.
#
# Regression for CRITICAL finding on PR #37 — caching an empty value (from a
# failed `gh repo view` call due to auth/network error) poisons downstream
# REST endpoint construction. The fix only populates the cache when the slug
# is non-empty; an empty result must allow the next call to retry.
#
# Usage: bash tests/hooks/test-merge-helpers-pr-repo-cache.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
MERGE_HELPERS_LIB="$DSO_PLUGIN_DIR/hooks/lib/merge-helpers.sh"

# shellcheck source=../lib/assert.sh
source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-merge-helpers-pr-repo-cache.sh ==="

# Sandbox: stub `gh` on PATH to deterministically simulate failure / success.
_TMP_BIN="$(mktemp -d "${TMPDIR:-/tmp}/pr-repo-cache-bin.XXXXXX")"
_GH_CALL_LOG="$(mktemp "${TMPDIR:-/tmp}/pr-repo-cache-calls.XXXXXX")"
_GH_MODE_FILE="$(mktemp "${TMPDIR:-/tmp}/pr-repo-cache-mode.XXXXXX")"

cleanup() {
    rm -rf "$_TMP_BIN" "$_GH_CALL_LOG" "$_GH_MODE_FILE" 2>/dev/null || true
}
trap cleanup EXIT

# Stub `gh`: behavior driven by $_GH_MODE_FILE contents.
#   "fail"    → exit 1, no output (auth/network failure)
#   "ok:<x>"  → print <x>, exit 0
cat >"$_TMP_BIN/gh" <<EOF
#!/usr/bin/env bash
echo "called: \$*" >> "$_GH_CALL_LOG"
mode=\$(cat "$_GH_MODE_FILE" 2>/dev/null || echo fail)
case "\$mode" in
    fail) exit 1 ;;
    ok:*) printf '%s\n' "\${mode#ok:}"; exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$_TMP_BIN/gh"

PATH="$_TMP_BIN:$PATH"
export PATH

# shellcheck source=/dev/null
source "$MERGE_HELPERS_LIB"

# ── Test 1: empty result must NOT be cached ───────────────────────────────────
_PR_REPO_NAME_WITH_OWNER=""
: > "$_GH_CALL_LOG"

echo "fail" > "$_GH_MODE_FILE"
# In-shell call (no subshell) so we can observe cache state directly.
_first_out=$(mktemp)
_pr_repo > "$_first_out"
first=$(cat "$_first_out"); rm -f "$_first_out"
assert_eq "first call returns empty when gh fails" "" "$first"
assert_eq "cache is empty after failed call" "" "$_PR_REPO_NAME_WITH_OWNER"

# Now gh recovers — _pr_repo MUST retry, not return cached empty.
echo "ok:owner/repo" > "$_GH_MODE_FILE"
_second_out=$(mktemp)
_pr_repo > "$_second_out"
second=$(cat "$_second_out"); rm -f "$_second_out"
assert_eq "second call retries and returns slug" "owner/repo" "$second"

calls=$(wc -l < "$_GH_CALL_LOG" | tr -d ' ')
assert_eq "gh invoked twice (no short-circuit on empty cache)" "2" "$calls"

# Call again in current shell (not subshell) so cache is observable.
_pr_repo >/dev/null
assert_eq "cache populated after success (in-shell call)" "owner/repo" "$_PR_REPO_NAME_WITH_OWNER"

# ── Test 2: non-empty result IS cached ────────────────────────────────────────
_PR_REPO_NAME_WITH_OWNER=""
: > "$_GH_CALL_LOG"

echo "ok:foo/bar" > "$_GH_MODE_FILE"
_pr_repo >/dev/null
_pr_repo >/dev/null
_pr_repo >/dev/null

calls=$(wc -l < "$_GH_CALL_LOG" | tr -d ' ')
assert_eq "gh invoked exactly once across 3 calls (cache hit on success)" "1" "$calls"

print_summary
