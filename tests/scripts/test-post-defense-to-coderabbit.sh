#!/usr/bin/env bash
# tests/scripts/test-post-defense-to-coderabbit.sh
# Behavioral tests for plugins/dso/scripts/post-defense-to-coderabbit.sh
#
# Uses a mock `gh` shim that records every invocation so the test can assert
# (a) author checks happen, (b) the reply body contains the defense text and
# the `@coderabbitai resolve` directive, (c) exit codes match contract.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/post-defense-to-coderabbit.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-post-defense-to-coderabbit.sh ==="

# ── Setup ────────────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/test-post-defense.XXXXXX")"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

MOCK_BIN="$TMPDIR_TEST/bin"
mkdir -p "$MOCK_BIN"
MOCK_LOG="$TMPDIR_TEST/gh.log"

# write_mock_gh <author_login> <reply_html_url>
# Creates a mock `gh` that returns <author_login> for `gh api .../pulls/comments/<id>`
# and posts a fake reply JSON containing <reply_html_url>.
write_mock_gh() {
    local author="$1"
    local reply_url="$2"
    cat > "$MOCK_BIN/gh" <<MOCK
#!/usr/bin/env bash
# Mock gh — records argv + stdin to \$GH_LOG, returns canned outputs.
GH_LOG="${MOCK_LOG}"
{
  echo "---"
  echo "argv: \$*"
  if [[ ! -t 0 ]]; then
    echo "stdin: <<<"
    cat
    echo ">>>"
  fi
} >> "\$GH_LOG"

# Resolve repo (called once)
if [[ "\$1" == "repo" && "\$2" == "view" ]]; then
  echo "navapbc/test-repo"
  exit 0
fi

# Author lookup: gh api repos/.../pulls/comments/<id>
case "\$*" in
  *"pulls/comments/"*"--jq"*)
    echo "${author}"
    exit 0
    ;;
esac

# POST reply: gh api --method POST ... pulls/<pr>/comments/<id>/replies
case "\$*" in
  *"--method"*"POST"*"replies"*)
    echo '{"html_url":"'"${reply_url}"'","id":99999,"body":"reply-body"}'
    exit 0
    ;;
esac

# Unknown invocation — fail loud
echo "mock gh: unknown invocation: \$*" >&2
exit 17
MOCK
    chmod +x "$MOCK_BIN/gh"
}

# write_mock_gh_api_failure — returns nonzero on the reply POST.
write_mock_gh_api_failure() {
    local author="$1"
    cat > "$MOCK_BIN/gh" <<MOCK
#!/usr/bin/env bash
case "\$*" in
  *"repo"*"view"*) echo "navapbc/test-repo"; exit 0 ;;
  *"pulls/comments/"*"--jq"*) echo "${author}"; exit 0 ;;
  *"--method"*"POST"*"replies"*) echo "API error: 422 Unprocessable" >&2; exit 22 ;;
  *) echo "unknown: \$*" >&2; exit 17 ;;
esac
MOCK
    chmod +x "$MOCK_BIN/gh"
}

# ── Test 1: missing required args → exit 2 ──────────────────────────────────
echo "--- test_missing_required_args ---"
"$SCRIPT" >/dev/null 2>&1
rc=$?
assert_eq "test_missing_required_args: exit code is 2" "2" "$rc"

# ── Test 2: non-numeric pr → exit 2 ─────────────────────────────────────────
echo "--- test_non_numeric_pr ---"
"$SCRIPT" --pr abc --comment-id 123 --defense-text x >/dev/null 2>&1
rc=$?
assert_eq "test_non_numeric_pr: exit code is 2" "2" "$rc"

# ── Test 3: wrong author → exit 3, no reply posted ──────────────────────────
echo "--- test_wrong_author_refuses ---"
: > "$MOCK_LOG"
write_mock_gh "some-other-user" "https://example.com/reply/1"
GH_CMD="$MOCK_BIN/gh" "$SCRIPT" --pr 1 --comment-id 100 --defense-text "evidence here" --repo navapbc/test-repo >/dev/null 2>&1
rc=$?
assert_eq "test_wrong_author_refuses: exit code is 3" "3" "$rc"
if grep -q "POST" "$MOCK_LOG"; then
    (( ++FAIL )); echo "FAIL: test_wrong_author_refuses: reply was posted despite wrong author"
else
    (( ++PASS ))
fi

# ── Test 4: CodeRabbit author + happy path → exit 0, body includes @coderabbitai resolve ──
echo "--- test_coderabbit_happy_path ---"
: > "$MOCK_LOG"
write_mock_gh "coderabbitai[bot]" "https://example.com/reply/2"
out=$(GH_CMD="$MOCK_BIN/gh" "$SCRIPT" --pr 42 --comment-id 200 --defense-text "F1 ships before F2 because cycle gating depends on it" --repo navapbc/test-repo 2>&1)
rc=$?
assert_eq "test_coderabbit_happy_path: exit code is 0" "0" "$rc"
assert_eq "test_coderabbit_happy_path: stdout reports reply URL" "1" "$(grep -cF 'https://example.com/reply/2' <<<"$out" || true)"
# The mock recorded the POST. The body should contain the defense text + the resolve directive.
assert_eq "test_coderabbit_happy_path: POST was issued" "1" "$(grep -c 'replies' "$MOCK_LOG" || true)"
assert_eq "test_coderabbit_happy_path: defense text present in stdin body" "1" "$(grep -cF 'F1 ships before F2' "$MOCK_LOG" || true)"
assert_eq "test_coderabbit_happy_path: resolve directive present" "1" "$(grep -cF '@coderabbitai resolve' "$MOCK_LOG" || true)"

# ── Test 5: --no-resolve → body does NOT contain the directive ─────────────
echo "--- test_no_resolve_flag ---"
: > "$MOCK_LOG"
write_mock_gh "coderabbitai[bot]" "https://example.com/reply/3"
GH_CMD="$MOCK_BIN/gh" "$SCRIPT" --pr 42 --comment-id 200 --defense-text "Only defending" --no-resolve --repo navapbc/test-repo >/dev/null 2>&1
rc=$?
assert_eq "test_no_resolve_flag: exit code is 0" "0" "$rc"
if grep -qF '@coderabbitai resolve' "$MOCK_LOG"; then
    (( ++FAIL )); echo "FAIL: test_no_resolve_flag: resolve directive present despite --no-resolve"
else
    (( ++PASS ))
fi

# ── Test 6: defense via stdin ───────────────────────────────────────────────
echo "--- test_defense_via_stdin ---"
: > "$MOCK_LOG"
write_mock_gh "coderabbitai[bot]" "https://example.com/reply/4"
echo "Defense via stdin works" | GH_CMD="$MOCK_BIN/gh" "$SCRIPT" --pr 42 --comment-id 200 --repo navapbc/test-repo >/dev/null 2>&1
rc=$?
assert_eq "test_defense_via_stdin: exit code is 0" "0" "$rc"
assert_eq "test_defense_via_stdin: stdin content reached the POST body" "1" "$(grep -cF 'Defense via stdin works' "$MOCK_LOG" || true)"

# ── Test 7: --no-author-check bypasses lookup ───────────────────────────────
echo "--- test_no_author_check_bypass ---"
: > "$MOCK_LOG"
write_mock_gh "coderabbitai[bot]" "https://example.com/reply/5"
GH_CMD="$MOCK_BIN/gh" "$SCRIPT" --pr 42 --comment-id 200 --defense-text "bypass" --no-author-check --repo navapbc/test-repo >/dev/null 2>&1
rc=$?
assert_eq "test_no_author_check_bypass: exit code is 0" "0" "$rc"
# The author-lookup API call should NOT have been issued (no --jq .user.login in log).
if grep -q 'pulls/comments/.*--jq' "$MOCK_LOG"; then
    (( ++FAIL )); echo "FAIL: test_no_author_check_bypass: author lookup was issued despite --no-author-check"
else
    (( ++PASS ))
fi

# ── Test 8: API failure on POST → exit 4 ───────────────────────────────────
echo "--- test_api_failure ---"
write_mock_gh_api_failure "coderabbitai[bot]"
GH_CMD="$MOCK_BIN/gh" "$SCRIPT" --pr 42 --comment-id 200 --defense-text "x" --repo navapbc/test-repo >/dev/null 2>&1
rc=$?
assert_eq "test_api_failure: exit code is 4" "4" "$rc"

# ── Summary ─────────────────────────────────────────────────────────────────
print_summary
