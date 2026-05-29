#!/usr/bin/env bash
# tests/scripts/test-sync-sub-pr-ruleset.sh
# Behavioral tests for plugins/dso/scripts/sync-sub-pr-ruleset.sh.
#
# Coverage:
#   1. test_script_exists
#   2. test_shellcheck_clean
#   3. test_help_outputs_usage
#   4. test_unknown_flag_exits_nonzero
#   5. test_ruleset_not_found_exits_nonzero
#   6. test_dry_run_drift_detected     — allowlist-shaped ruleset → PATCH to negative-list
#   7. test_dry_run_in_sync            — already negative-list → SKIP, no PATCH
#
# Usage: bash tests/scripts/test-sync-sub-pr-ruleset.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/sync-sub-pr-ruleset.sh"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

# Cumulative cleanup — each test appends its temp dirs and the EXIT trap
# removes them all at end-of-run. The earlier per-test `trap ... EXIT`
# overwrote the previous trap, so only the last temp dir got cleaned up
# (gitar-bot finding on PR #442).
_CLEANUP_DIRS=()
_cleanup_all() {
    for _d in "${_CLEANUP_DIRS[@]+"${_CLEANUP_DIRS[@]}"}"; do
        rm -rf "$_d" 2>/dev/null || true
    done
}
trap _cleanup_all EXIT

echo "=== test-sync-sub-pr-ruleset.sh ==="

# ── test_script_exists ────────────────────────────────────────────────────────
_snapshot_fail
if [[ -f "$SCRIPT" && -x "$SCRIPT" ]]; then
    actual_exists="exists"
else
    actual_exists="missing"
fi
assert_eq "test_script_exists: file present and executable" "exists" "$actual_exists"
assert_pass_if_clean "test_script_exists"

# ── test_shellcheck_clean ─────────────────────────────────────────────────────
_snapshot_fail
sc_rc=0
shellcheck "$SCRIPT" >/dev/null 2>&1 || sc_rc=$?
assert_eq "test_shellcheck_clean: shellcheck exits 0" "0" "$sc_rc"
assert_pass_if_clean "test_shellcheck_clean"

# ── test_help_outputs_usage ───────────────────────────────────────────────────
_snapshot_fail
help_out="$(bash "$SCRIPT" -h 2>&1)"
help_rc=$?
assert_eq "test_help_outputs_usage: exit 0" "0" "$help_rc"
assert_contains "test_help_outputs_usage: includes 'Usage:'" "Usage:" "$help_out"
assert_contains "test_help_outputs_usage: documents --dry-run" "--dry-run" "$help_out"
assert_pass_if_clean "test_help_outputs_usage"

# ── test_unknown_flag_exits_nonzero ───────────────────────────────────────────
_snapshot_fail
unk_rc=0
bash "$SCRIPT" --not-a-real-flag >/dev/null 2>&1 || unk_rc=$?
assert_ne "test_unknown_flag_exits_nonzero: exit non-zero" "0" "$unk_rc"
assert_pass_if_clean "test_unknown_flag_exits_nonzero"

# ── test_ruleset_not_found_exits_nonzero ──────────────────────────────────────
# gh stub returns empty ruleset list → script must exit 1 with a clear error.
_snapshot_fail
nf_tmp="$(mktemp -d "${TMPDIR:-/tmp}/sync-sub-pr-ruleset-not-found.XXXXXX")"
_CLEANUP_DIRS+=("$nf_tmp")
nf_stub="$nf_tmp/gh"
cat > "$nf_stub" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" && "${2:-}" =~ /rulesets$ ]]; then echo "[]"; exit 0; fi
exit 0
STUB
chmod +x "$nf_stub"
nf_rc=0
nf_out="$(PATH="$nf_tmp:$PATH" bash "$SCRIPT" --repo test/repo 2>&1)" || nf_rc=$?
assert_eq "test_ruleset_not_found_exits_nonzero: exit 1" "1" "$nf_rc"
assert_contains "test_ruleset_not_found_exits_nonzero: mentions ruleset not found" \
    "not found" "$nf_out"
assert_pass_if_clean "test_ruleset_not_found_exits_nonzero"

# ── test_dry_run_drift_detected ───────────────────────────────────────────────
# Mock gh: live ruleset is the old allowlist shape → script detects drift,
# emits DECISION: DRY-RUN PATCH, includes ~ALL in expected include, exits 0.
_snapshot_fail
dr_tmp="$(mktemp -d "${TMPDIR:-/tmp}/sync-sub-pr-ruleset-drift.XXXXXX")"
_CLEANUP_DIRS+=("$dr_tmp")
dr_stub="$dr_tmp/gh"
cat > "$dr_stub" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" && "${2:-}" =~ /rulesets$ ]]; then
    echo '[{"id": 42, "name": "DSO Sub-PR Review Enforcement"}]'
    exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" =~ /rulesets/42$ ]]; then
    cat <<'JSON'
{
  "id": 42,
  "name": "DSO Sub-PR Review Enforcement",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/heads/session/**","refs/heads/worktree-**"], "exclude": []}},
  "bypass_actors": [],
  "rules": []
}
JSON
    exit 0
fi
exit 0
STUB
chmod +x "$dr_stub"
dr_rc=0
dr_out="$(PATH="$dr_tmp:$PATH" bash "$SCRIPT" --repo test/repo --dry-run 2>&1)" || dr_rc=$?
assert_eq "test_dry_run_drift_detected: exit 0" "0" "$dr_rc"
assert_contains "test_dry_run_drift_detected: DECISION DRY-RUN PATCH" \
    "DECISION: DRY-RUN PATCH" "$dr_out"
assert_contains "test_dry_run_drift_detected: expected include ~ALL" \
    '"~ALL"' "$dr_out"
assert_contains "test_dry_run_drift_detected: expected exclude refs/heads/main" \
    '"refs/heads/main"' "$dr_out"
# Negative: dry-run MUST NOT actually PATCH.
_patched="no"
if echo "$dr_out" | grep -q "Applying PATCH to ruleset"; then _patched="yes"; fi
assert_eq "test_dry_run_drift_detected: no live PATCH applied" "no" "$_patched"
assert_pass_if_clean "test_dry_run_drift_detected"

# ── test_dry_run_in_sync ──────────────────────────────────────────────────────
# Mock gh: live ruleset already matches negative-list shape → SKIP.
_snapshot_fail
sy_tmp="$(mktemp -d "${TMPDIR:-/tmp}/sync-sub-pr-ruleset-insync.XXXXXX")"
_CLEANUP_DIRS+=("$sy_tmp")
sy_stub="$sy_tmp/gh"
cat > "$sy_stub" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" && "${2:-}" =~ /rulesets$ ]]; then
    echo '[{"id": 42, "name": "DSO Sub-PR Review Enforcement"}]'
    exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" =~ /rulesets/42$ ]]; then
    cat <<'JSON'
{
  "id": 42,
  "name": "DSO Sub-PR Review Enforcement",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~ALL"], "exclude": ["refs/heads/main"]}},
  "bypass_actors": [],
  "rules": []
}
JSON
    exit 0
fi
exit 0
STUB
chmod +x "$sy_stub"
sy_rc=0
sy_out="$(PATH="$sy_tmp:$PATH" bash "$SCRIPT" --repo test/repo --dry-run 2>&1)" || sy_rc=$?
assert_eq "test_dry_run_in_sync: exit 0" "0" "$sy_rc"
assert_contains "test_dry_run_in_sync: DECISION SKIP" "DECISION: SKIP" "$sy_out"
assert_pass_if_clean "test_dry_run_in_sync"

# ── test_default_branch_env_override ──────────────────────────────────────────
# Hosts with non-main default branches set DSO_DEFAULT_BRANCH; the sync script
# must use that value in the expected exclude list rather than hardcoding
# "refs/heads/main".
_snapshot_fail
db_tmp="$(mktemp -d "${TMPDIR:-/tmp}/sync-sub-pr-ruleset-env.XXXXXX")"
_CLEANUP_DIRS+=("$db_tmp")
db_stub="$db_tmp/gh"
cat > "$db_stub" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" && "${2:-}" =~ /rulesets$ ]]; then
    echo '[{"id": 42, "name": "DSO Sub-PR Review Enforcement"}]'
    exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" =~ /rulesets/42$ ]]; then
    cat <<'JSON'
{
  "id": 42,
  "name": "DSO Sub-PR Review Enforcement",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/heads/session/**"], "exclude": []}},
  "bypass_actors": [],
  "rules": []
}
JSON
    exit 0
fi
exit 0
STUB
chmod +x "$db_stub"
db_rc=0
db_out="$(DSO_DEFAULT_BRANCH=trunk PATH="$db_tmp:$PATH" bash "$SCRIPT" --repo test/repo --dry-run 2>&1)" || db_rc=$?
assert_eq "test_default_branch_env_override: exit 0" "0" "$db_rc"
assert_contains "test_default_branch_env_override: expected exclude refs/heads/trunk" \
    '"refs/heads/trunk"' "$db_out"
# Negative: must NOT fall back to refs/heads/main.
_main_absent="yes"
if echo "$db_out" | grep -q '"refs/heads/main"'; then _main_absent="no"; fi
assert_eq "test_default_branch_env_override: refs/heads/main absent" "yes" "$_main_absent"
assert_pass_if_clean "test_default_branch_env_override"

# ── test_default_branch_gh_repo_view_path ─────────────────────────────────────
# When no env override is set, the script asks `gh repo view <REPO> --json
# defaultBranchRef` for the host's default branch. Mock gh to return "trunk"
# and assert the script uses it.
_snapshot_fail
gh_tmp="$(mktemp -d "${TMPDIR:-/tmp}/sync-sub-pr-ruleset-gh.XXXXXX")"
_CLEANUP_DIRS+=("$gh_tmp")
gh_stub="$gh_tmp/gh"
# Realistic gh stub: when called with `--json defaultBranchRef -q
# '.defaultBranchRef.name'`, return the same plain string the real gh would
# print (gh's -q flag applies a jq path expression to the JSON response,
# emitting only the scalar value). This makes the stub honor the contract
# the production gh exposes, instead of returning plain text and having the
# script silently fall back to a different tier (llm-review critical
# finding on PR #442 ec091b28). Other gh subcommands (api /rulesets etc.)
# pass through to their existing handlers below.
cat > "$gh_stub" <<'STUB'
#!/usr/bin/env bash
# Parse: gh repo view <REPO> --json <fields> -q '<jq>'
if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
    # Find -q value (if present) to honor the contract the script relies on.
    _q=""
    _i=4
    while [[ $_i -le $# ]]; do
        if [[ "${!_i}" == "-q" ]]; then
            _ni=$((_i+1))
            _q="${!_ni}"
            break
        fi
        _i=$((_i+1))
    done
    # JSON shape gh would return for --json defaultBranchRef.
    _JSON='{"defaultBranchRef":{"name":"trunk"}}'
    if [[ -n "$_q" ]]; then
        # Apply the jq path expression. The script invokes -q '.defaultBranchRef.name'
        # so we emit the scalar string the production gh would emit. Use python3
        # (not jq — plugin-script convention forbids jq, ref .coderabbit.yaml).
        printf '%s\n' "$_JSON" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
expr = sys.argv[1].lstrip('.')
for k in expr.split('.'):
    if not k: continue
    if isinstance(d, dict):
        d = d.get(k, '')
    else:
        d = ''
        break
print(d)
" "$_q"
    else
        printf '%s\n' "$_JSON"
    fi
    exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" =~ /rulesets$ ]]; then
    echo '[{"id": 42, "name": "DSO Sub-PR Review Enforcement"}]'
    exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" =~ /rulesets/42$ ]]; then
    cat <<'JSON'
{"id":42,"name":"DSO Sub-PR Review Enforcement","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["refs/heads/session/**"],"exclude":[]}},"bypass_actors":[],"rules":[]}
JSON
    exit 0
fi
exit 0
STUB
chmod +x "$gh_stub"
gh_rc=0
# Clear env override so script falls through to gh repo view path.
gh_out="$(env -u DSO_DEFAULT_BRANCH PATH="$gh_tmp:$PATH" bash "$SCRIPT" --repo test/repo --dry-run 2>&1)" || gh_rc=$?
assert_eq "test_default_branch_gh_repo_view_path: exit 0" "0" "$gh_rc"
assert_contains "test_default_branch_gh_repo_view_path: uses gh-resolved 'trunk'" \
    '"refs/heads/trunk"' "$gh_out"
assert_pass_if_clean "test_default_branch_gh_repo_view_path"

# ── test_default_branch_hardcoded_main_fallback ───────────────────────────────
# When DSO_DEFAULT_BRANCH is unset AND gh repo view returns empty AND git
# symbolic-ref refs/remotes/origin/HEAD is unavailable (no remote HEAD in
# cwd), the script must fall back to the hardcoded literal "main". We force
# this path by running in a temp directory with no git remote and stubbing
# gh repo view to return empty.
_snapshot_fail
fb_tmp="$(mktemp -d "${TMPDIR:-/tmp}/sync-sub-pr-ruleset-fbstub.XXXXXX")"
_CLEANUP_DIRS+=("$fb_tmp")
fb_stub="$fb_tmp/gh"
cat > "$fb_stub" <<'STUB'
#!/usr/bin/env bash
# Repo-view query returns empty (simulates failure / no defaultBranchRef).
if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
    echo ""
    exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" =~ /rulesets$ ]]; then
    echo '[{"id": 42, "name": "DSO Sub-PR Review Enforcement"}]'
    exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" =~ /rulesets/42$ ]]; then
    cat <<'JSON'
{"id":42,"name":"DSO Sub-PR Review Enforcement","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["refs/heads/session/**"],"exclude":[]}},"bypass_actors":[],"rules":[]}
JSON
    exit 0
fi
exit 0
STUB
chmod +x "$fb_stub"
# Run in a temp git repo with no remote so symbolic-ref refs/remotes/origin/HEAD
# fails, exercising the literal-"main" fallback.
fb_repo="$(mktemp -d "${TMPDIR:-/tmp}/sync-sub-pr-ruleset-fbrepo.XXXXXX")"
_CLEANUP_DIRS+=("$fb_repo")
(cd "$fb_repo" && git init -q && git config user.email t@t.local && git config user.name t \
    && touch a && git add a && git commit -q -m seed)
fb_rc=0
fb_out="$(cd "$fb_repo" && env -u DSO_DEFAULT_BRANCH PATH="$fb_tmp:$PATH" bash "$SCRIPT" --repo test/repo --dry-run 2>&1)" || fb_rc=$?
assert_eq "test_default_branch_hardcoded_main_fallback: exit 0" "0" "$fb_rc"
assert_contains "test_default_branch_hardcoded_main_fallback: uses literal 'main'" \
    '"refs/heads/main"' "$fb_out"
assert_pass_if_clean "test_default_branch_hardcoded_main_fallback"

# ── test_live_patch_post_verify_success ──────────────────────────────────────
# Exercise the non-dry-run PATCH + post-verify code path (lines ~148-167 of
# sync-sub-pr-ruleset.sh) with a mocked gh that accepts the PUT and reports
# the expected post-PATCH state. Asserts the script exits 0 with the "OK"
# success message. This closes the dry-run-only test-coverage gap flagged by
# llm-review on PR #442.
_snapshot_fail
pv_tmp="$(mktemp -d "${TMPDIR:-/tmp}/sync-sub-pr-ruleset-patchok.XXXXXX")"
_CLEANUP_DIRS+=("$pv_tmp")
# Track PUT count via a touch file the stub creates on PUT.
pv_put_marker="$pv_tmp/put-called"
pv_stub="$pv_tmp/gh"
cat > "$pv_stub" <<STUB
#!/usr/bin/env bash
# Ruleset list (lookup by name).
if [[ "\${1:-}" == "api" && "\${2:-}" =~ /rulesets$ ]] && [[ "\${1:-}\${2:-}\${3:-}" != *"--method"* ]]; then
    echo '[{"id": 42, "name": "DSO Sub-PR Review Enforcement"}]'
    exit 0
fi
# PUT to /rulesets/42 — accept, mark called, no output.
if [[ "\${1:-}" == "api" && "\${2:-}" == "--method" && "\${3:-}" == "PUT" ]]; then
    touch "${pv_put_marker}"
    exit 0
fi
# GET /rulesets/42 — return SHAPE depending on whether PUT has been called.
# Pre-PATCH: old allowlist shape (drift). Post-PATCH: new ~ALL shape.
if [[ "\${1:-}" == "api" && "\${2:-}" =~ /rulesets/42 ]]; then
    if [[ -e "${pv_put_marker}" ]]; then
        # Post-PATCH GET (or post-PATCH --jq) — return new shape.
        if [[ "\${3:-}" == "--jq" ]]; then
            case "\${4:-}" in
                *include*) echo '["~ALL"]' ;;
                *exclude*) echo '["refs/heads/main"]' ;;
                *) echo '' ;;
            esac
            exit 0
        fi
        cat <<'JSON'
{"id":42,"name":"DSO Sub-PR Review Enforcement","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~ALL"],"exclude":["refs/heads/main"]}},"bypass_actors":[],"rules":[]}
JSON
        exit 0
    fi
    # Pre-PATCH — drifted allowlist shape.
    cat <<'JSON'
{"id":42,"name":"DSO Sub-PR Review Enforcement","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["refs/heads/session/**"],"exclude":[]}},"bypass_actors":[],"rules":[]}
JSON
    exit 0
fi
exit 0
STUB
chmod +x "$pv_stub"
pv_rc=0
pv_out="$(DSO_DEFAULT_BRANCH=main PATH="$pv_tmp:$PATH" bash "$SCRIPT" --repo test/repo 2>&1)" || pv_rc=$?
assert_eq "test_live_patch_post_verify_success: exit 0" "0" "$pv_rc"
assert_contains "test_live_patch_post_verify_success: applies PATCH" \
    "Applying PATCH to ruleset" "$pv_out"
assert_contains "test_live_patch_post_verify_success: post-verify success message" \
    "now matches negative-list shape" "$pv_out"
_pv_called="no"
[[ -e "$pv_put_marker" ]] && _pv_called="yes"
assert_eq "test_live_patch_post_verify_success: gh PUT invoked" "yes" "$_pv_called"
assert_pass_if_clean "test_live_patch_post_verify_success"

# ── test_live_patch_post_verify_failure ──────────────────────────────────────
# Inverse of the above: gh PUT succeeds but the post-PATCH GET returns the
# OLD shape (simulating a write that didn't take effect, or a logic error in
# the verify block). Script must exit 1 with the "post-PATCH verification
# failed" error so operators see drift instead of a misleading success.
_snapshot_fail
pf_tmp="$(mktemp -d "${TMPDIR:-/tmp}/sync-sub-pr-ruleset-patchfail.XXXXXX")"
_CLEANUP_DIRS+=("$pf_tmp")
pf_stub="$pf_tmp/gh"
cat > "$pf_stub" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" && "${2:-}" =~ /rulesets$ ]] && [[ "${1:-}${2:-}${3:-}" != *"--method"* ]]; then
    echo '[{"id": 42, "name": "DSO Sub-PR Review Enforcement"}]'
    exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "--method" && "${3:-}" == "PUT" ]]; then
    exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" =~ /rulesets/42 ]]; then
    # ALWAYS return the OLD drifted shape — simulates PUT not taking effect.
    if [[ "${3:-}" == "--jq" ]]; then
        case "${4:-}" in
            *include*) echo '["refs/heads/session/**"]' ;;
            *exclude*) echo '[]' ;;
            *) echo '' ;;
        esac
        exit 0
    fi
    cat <<'JSON'
{"id":42,"name":"DSO Sub-PR Review Enforcement","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["refs/heads/session/**"],"exclude":[]}},"bypass_actors":[],"rules":[]}
JSON
    exit 0
fi
exit 0
STUB
chmod +x "$pf_stub"
pf_rc=0
pf_out="$(DSO_DEFAULT_BRANCH=main PATH="$pf_tmp:$PATH" bash "$SCRIPT" --repo test/repo 2>&1)" || pf_rc=$?
assert_eq "test_live_patch_post_verify_failure: exit 1" "1" "$pf_rc"
assert_contains "test_live_patch_post_verify_failure: post-verify failure message" \
    "post-PATCH verification failed" "$pf_out"
assert_pass_if_clean "test_live_patch_post_verify_failure"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
