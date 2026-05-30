#!/usr/bin/env bash
# Regression test for bugs 34b2, 3706, a530 — three plugin scripts had
# REPO_ROOT="$SCRIPT_DIR/.." which resolved to the plugin cache root when
# invoked on a host project via the shim. Fix: use PROJECT_ROOT env-var
# override + `git rev-parse --show-toplevel` so host invocations resolve
# REPO_ROOT to the host repo, not the plugin tree.
#
# Bug refs:
#   34b2-5523-0be0-4945 (check-skill-refs.sh — silent PASS on host)
#   3706-ae76-0b07-4dfe (qualify-skill-refs.sh — mutates plugin cache)
#   a530-53cb-c966-4d46 (check-test-isolation.sh — silent PASS on host)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
PASS=0
FAIL=0

_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ── Setup: simulate a host project via a sibling git repo ─────────────────────
HOST_DIR=$(mktemp -d -t dso-host-portability-XXXXXX)
# shellcheck disable=SC2064  # intentional: bind HOST_DIR at trap-set time
trap "rm -rf '$HOST_DIR'" EXIT
git -C "$HOST_DIR" init -q
# Stage a CLAUDE.md WITH a deterministic unqualified `/skill` reference so the
# host check has actual content to find. If the script truly respects
# PROJECT_ROOT, it will detect this reference and report a path under HOST_DIR.
# If it silently scans the plugin tree (the bug), it won't report HOST_DIR.
cat > "$HOST_DIR/CLAUDE.md" <<'HOST'
# Host project CLAUDE.md

This host file has an unqualified reference: /fix-bug used here.
HOST

# ── Test 1: check-skill-refs.sh resolves REPO_ROOT via PROJECT_ROOT override ─
# The fix accepts PROJECT_ROOT as an override. Set it to HOST_DIR and verify
# the script SCANS HOST_DIR (not the plugin tree). Key strict assertion: the
# reported unqualified-reference path must be under HOST_DIR — proving the
# env override actually reached the subprocess.
SCRIPT_TO_TEST="$REPO_ROOT/plugins/dso/scripts/check-skill-refs.sh"

# IMPORTANT: env-var prefix on `output=$(...)` assigns to the OUTER assignment,
# not to the bash invocation inside the command substitution (CodeRabbit PR
# #472 finding). Use explicit `env VAR=val cmd` or `export` to actually pass
# the var to the subprocess.
output=$(env PROJECT_ROOT="$HOST_DIR" bash "$SCRIPT_TO_TEST" 2>&1 || true)
# Strict assertion: the host CLAUDE.md has an unqualified /fix-bug; the
# checker must report a path under HOST_DIR. If it reports a plugin-tree
# path or no path at all, PROJECT_ROOT didn't reach the subprocess (the bug
# the test is supposed to catch).
if echo "$output" | grep -qF "$HOST_DIR/CLAUDE.md"; then
    _pass "test_check_skill_refs_respects_PROJECT_ROOT_override"
else
    _fail "test_check_skill_refs_respects_PROJECT_ROOT_override" \
        "expected $HOST_DIR/CLAUDE.md in output, got: ${output:0:300}"
fi

# ── Test 2: qualify-skill-refs.sh — same PROJECT_ROOT override ───────────────
SCRIPT_TO_TEST="$REPO_ROOT/plugins/dso/scripts/qualify-skill-refs.sh"

# Run on the host fixture (has unqualified /fix-bug). After the mutator runs,
# the host CLAUDE.md should contain /dso:fix-bug (qualified), proving the
# mutator targeted HOST_DIR rather than the plugin tree.
env PROJECT_ROOT="$HOST_DIR" bash "$SCRIPT_TO_TEST" 2>/dev/null || true
if grep -qF "/dso:fix-bug" "$HOST_DIR/CLAUDE.md"; then
    _pass "test_qualify_skill_refs_mutates_host_not_plugin"
else
    _fail "test_qualify_skill_refs_mutates_host_not_plugin" \
        "expected /dso:fix-bug in host CLAUDE.md, got: $(cat "$HOST_DIR/CLAUDE.md")"
fi

# Restore the host CLAUDE.md to its original state for subsequent tests
cat > "$HOST_DIR/CLAUDE.md" <<'HOST'
# Host project CLAUDE.md

This host file has an unqualified reference: /fix-bug used here.
HOST

# ── Test 3: check-test-isolation.sh — PROJECT_ROOT respected ─────────────────
SCRIPT_TO_TEST="$REPO_ROOT/plugins/dso/scripts/check-test-isolation.sh"

# Run --help in HOST_DIR context. Should report the (plugin-shipped) rules
# dir under $CLAUDE_PLUGIN_ROOT, NOT under $HOST_DIR — that was the second
# half of the a530 fix (RULES_DIR resolution).
output=$(env CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso" \
    PROJECT_ROOT="$HOST_DIR" \
    bash "$SCRIPT_TO_TEST" --help 2>&1 || true)
if echo "$output" | grep -qF "$HOST_DIR/scripts/test-isolation-rules"; then
    _fail "test_check_test_isolation_RULES_DIR_resolves_to_plugin_tree" \
        "still resolved to host dir (output: ${output:0:300})"
elif echo "$output" | grep -qF "$REPO_ROOT/plugins/dso/scripts/test-isolation-rules"; then
    _pass "test_check_test_isolation_RULES_DIR_resolves_to_plugin_tree"
else
    _fail "test_check_test_isolation_RULES_DIR_resolves_to_plugin_tree" \
        "no rules-dir path in --help output: ${output:0:300}"
fi

# ── Test 4: hard-error when REPO_ROOT cannot be resolved ─────────────────────
# Run check-skill-refs.sh from /tmp (no git repo, PROJECT_ROOT unset).
# Should exit non-zero with the "cannot resolve REPO_ROOT" message.
TMP_NO_GIT=$(mktemp -d -t dso-no-git-XXXXXX)
# shellcheck disable=SC2064  # intentional: bind both paths at trap-set time
trap "rm -rf '$HOST_DIR' '$TMP_NO_GIT'" EXIT
exit_code=0
output=$(cd "$TMP_NO_GIT" && unset PROJECT_ROOT && \
    bash "$REPO_ROOT/plugins/dso/scripts/check-skill-refs.sh" 2>&1) || exit_code=$?
if [[ $exit_code -ne 0 ]] && echo "$output" | grep -qF "cannot resolve REPO_ROOT"; then
    _pass "test_check_skill_refs_hard_errors_when_REPO_ROOT_unresolved"
else
    _fail "test_check_skill_refs_hard_errors_when_REPO_ROOT_unresolved: exit=$exit_code output=${output:0:200}"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
